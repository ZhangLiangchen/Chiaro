import Foundation
import Metal
import simd

public enum CubeLUTError: Error, Sendable, CustomStringConvertible {
    case fileReadFailed(URL)
    case missingDimension
    case unsupportedDimension(Int)
    case entryCountMismatch(expected: Int, actual: Int)
    case invalidEntry(line: Int)
    case invalidDomain

    public var description: String {
        switch self {
        case let .fileReadFailed(url): return "Failed to read .cube LUT at \(url.path)"
        case .missingDimension: return "Missing LUT_1D_SIZE or LUT_3D_SIZE in .cube file"
        case let .unsupportedDimension(size): return "Unsupported .cube LUT size: \(size)"
        case let .entryCountMismatch(expected, actual): return ".cube entry count mismatch: expected \(expected), got \(actual)"
        case let .invalidEntry(line): return "Malformed RGB entry at line \(line) in .cube LUT"
        case .invalidDomain: return "Invalid DOMAIN_MIN/DOMAIN_MAX in .cube LUT"
        }
    }
}

public enum CubeLUTDimension: Sendable, Equatable {
    case oneD(Int)
    case threeD(Int)
}

/// Parses Adobe `.cube` 1D and 3D LUTs and provides the reversible Log Shaper
/// mapping `[-10 EV, +6 EV]` (`[2^-10, 2^6] = [0.0009765625, 64.0]`) ↔ `[0, 1]`.
public struct CubeLUT: Sendable, Equatable {
    public static let shaperMinEV: Float = -10.0
    public static let shaperMaxEV: Float = 6.0
    public static let shaperMinLinear: Float = 0.0009765625 // 2^-10
    public static let shaperMaxLinear: Float = 64.0         // 2^6

    public let title: String?
    public let dimension: CubeLUTDimension
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
    /// Packed RGBA32F floats (A = 1.0). For 3D LUTs, Adobe R-fastest stride matches Metal `(x=R, y=G, z=B)`.
    public let rgbaData: [Float]

    public init(contentsOf url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CubeLUTError.fileReadFailed(url)
        }
        try self.init(parsing: text)
    }

    public init(parsing text: String) throws {
        var title: String?
        var size1D: Int?
        var size3D: Int?
        var dMin = SIMD3<Float>(0, 0, 0)
        var dMax = SIMD3<Float>(1, 1, 1)
        var entries: [Float] = []

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if line.hasPrefix("TITLE") {
                let rest = line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespacesAndNewlines)
                title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if line.hasPrefix("LUT_1D_SIZE") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, let n = Int(parts[1]), n >= 2, n <= 65536 else {
                    throw CubeLUTError.unsupportedDimension(-1)
                }
                size1D = n
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, let n = Int(parts[1]), n >= 2, n <= 129 else {
                    throw CubeLUTError.unsupportedDimension(-1)
                }
                size3D = n
                continue
            }
            if line.hasPrefix("DOMAIN_MIN") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 4,
                      let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]),
                      r.isFinite, g.isFinite, b.isFinite else {
                    throw CubeLUTError.invalidEntry(line: idx + 1)
                }
                dMin = SIMD3<Float>(r, g, b)
                continue
            }
            if line.hasPrefix("DOMAIN_MAX") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 4,
                      let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]),
                      r.isFinite, g.isFinite, b.isFinite else {
                    throw CubeLUTError.invalidEntry(line: idx + 1)
                }
                dMax = SIMD3<Float>(r, g, b)
                continue
            }
            if line.hasPrefix("LUT_1D_INPUT_RANGE") || line.hasPrefix("LUT_3D_INPUT_RANGE") {
                continue
            }

            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]),
                  r.isFinite, g.isFinite, b.isFinite else {
                throw CubeLUTError.invalidEntry(line: idx + 1)
            }
            entries.append(r)
            entries.append(g)
            entries.append(b)
            entries.append(1.0)
        }

        let dim: CubeLUTDimension
        let expected: Int
        if let n3 = size3D {
            dim = .threeD(n3)
            expected = n3 * n3 * n3
        } else if let n1 = size1D {
            dim = .oneD(n1)
            expected = n1
        } else {
            throw CubeLUTError.missingDimension
        }

        let actual = entries.count / 4
        guard actual == expected else {
            throw CubeLUTError.entryCountMismatch(expected: expected, actual: actual)
        }
        guard dMin.x < dMax.x, dMin.y < dMax.y, dMin.z < dMax.z else {
            throw CubeLUTError.invalidDomain
        }

        self.title = title
        self.dimension = dim
        self.domainMin = dMin
        self.domainMax = dMax
        self.rgbaData = entries
    }

    public func makeMetalTexture(device: any MTLDevice) -> (any MTLTexture)? {
        let maxDim = MTLHeapTexturePool.maxTextureDimension(for: device)
        let max3DDim = min(maxDim, 2048)
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba32Float
        desc.usage = .shaderRead
        desc.storageMode = .shared

        switch dimension {
        case let .oneD(n):
            guard n >= 2, n <= maxDim, rgbaData.count >= n * 4 else { return nil }
            desc.textureType = .type2D
            desc.width = n
            desc.height = 1
            desc.depth = 1
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            let bytesPerRow = n * 4 * MemoryLayout<Float>.stride
            rgbaData.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    tex.replace(
                        region: MTLRegionMake2D(0, 0, n, 1),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: bytesPerRow
                    )
                }
            }
            return tex

        case let .threeD(n):
            guard n >= 2, n <= max3DDim else { return nil }
            let (n2, ov1) = n.multipliedReportingOverflow(by: n)
            let (n3, ov2) = n2.multipliedReportingOverflow(by: n)
            let (expectedFloats, ov3) = n3.multipliedReportingOverflow(by: 4)
            guard !ov1, !ov2, !ov3, rgbaData.count >= expectedFloats else { return nil }
            desc.textureType = .type3D
            desc.width = n
            desc.height = n
            desc.depth = n
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            let bytesPerRow = n * 4 * MemoryLayout<Float>.stride
            let bytesPerImage = n * bytesPerRow
            rgbaData.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    tex.replace(
                        region: MTLRegionMake3D(0, 0, 0, n, n, n),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: base,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerImage
                    )
                }
            }
            return tex
        }
    }

    public static func shaperForward(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let clamped = simd_max(rgb, SIMD3<Float>(repeating: shaperMinLinear))
        let ev = SIMD3<Float>(log2(clamped.x), log2(clamped.y), log2(clamped.z))
        let span = shaperMaxEV - shaperMinEV
        return simd_clamp((ev - SIMD3<Float>(repeating: shaperMinEV)) / span, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }

    public static func shaperInverse(_ t: SIMD3<Float>) -> SIMD3<Float> {
        let span = shaperMaxEV - shaperMinEV
        let ev = t * span + SIMD3<Float>(repeating: shaperMinEV)
        return SIMD3<Float>(exp2(ev.x), exp2(ev.y), exp2(ev.z))
    }
}
