import Foundation
import Metal
import simd

public enum DCPProfileError: Error, Sendable, CustomStringConvertible {
    case fileReadFailed(URL)
    case invalidTIFFHeader
    case invalidIFD

    public var description: String {
        switch self {
        case let .fileReadFailed(url): return "Failed to read DCP file at \(url.path)"
        case .invalidTIFFHeader: return "Invalid TIFF/DNG header in DCP file"
        case .invalidIFD: return "Malformed IFD structure in DCP file"
        }
    }
}

public struct HSVTable3D: Sendable {
    public let hueDivs: Int
    public let satDivs: Int
    public let valDivs: Int
    /// Flattened `(val * hueDivs * satDivs + hue * satDivs + sat)` * 4 (`hueShiftDeg, satScale, valScale, 0`)
    public let rgbaFloats: [Float]

    public func makeMetalTexture(device: any MTLDevice) -> (any MTLTexture)? {
        let max3DDim = min(MTLHeapTexturePool.maxTextureDimension(for: device), 2048)
        guard hueDivs >= 2, hueDivs <= max3DDim,
              satDivs >= 1, satDivs <= max3DDim,
              valDivs >= 1, valDivs <= max3DDim else {
            return nil
        }
        let (hs, ov1) = hueDivs.multipliedReportingOverflow(by: satDivs)
        let (hsv, ov2) = hs.multipliedReportingOverflow(by: valDivs)
        let (expectedFloats, ov3) = hsv.multipliedReportingOverflow(by: 4)
        guard !ov1, !ov2, !ov3, rgbaFloats.count >= expectedFloats else {
            return nil
        }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width = satDivs
        desc.height = hueDivs
        desc.depth = valDivs
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let bytesPerRow = satDivs * 4 * MemoryLayout<Float>.stride
        let bytesPerImage = hueDivs * bytesPerRow
        rgbaFloats.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                tex.replace(
                    region: MTLRegionMake3D(0, 0, 0, satDivs, hueDivs, valDivs),
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

/// Parses Adobe/DNG `.dcp` camera profiles (TIFF IFD container).
/// - Supports dual-illuminant `ForwardMatrix1/2` (Priority 1) & `ColorMatrix1/2` (Priority 3).
/// - Explicitly skips `ProfileToneCurve` (`0xC6FC`) to preserve HDR linear highlight headroom.
/// - Supports `ProfileHueSatMapData1/2` & `ProfileLookTableData` HSV 3D tables (`V > 1.0` preserved).
public struct DCPProfile: Sendable {
    public let illuminant1Kelvin: Double
    public let illuminant2Kelvin: Double?
    public let colorMatrix1: simd_double3x3?
    public let colorMatrix2: simd_double3x3?
    public let forwardMatrix1: simd_double3x3?
    public let forwardMatrix2: simd_double3x3?
    public let hueSatTable1: HSVTable3D?
    public let hueSatTable2: HSVTable3D?
    public let lookTable: HSVTable3D?

    public init(
        illuminant1Kelvin: Double = 5000.0,
        illuminant2Kelvin: Double? = nil,
        colorMatrix1: simd_double3x3? = nil,
        colorMatrix2: simd_double3x3? = nil,
        forwardMatrix1: simd_double3x3? = nil,
        forwardMatrix2: simd_double3x3? = nil,
        hueSatTable1: HSVTable3D? = nil,
        hueSatTable2: HSVTable3D? = nil,
        lookTable: HSVTable3D? = nil
    ) {
        self.illuminant1Kelvin = illuminant1Kelvin
        self.illuminant2Kelvin = illuminant2Kelvin
        self.colorMatrix1 = colorMatrix1
        self.colorMatrix2 = colorMatrix2
        self.forwardMatrix1 = forwardMatrix1
        self.forwardMatrix2 = forwardMatrix2
        self.hueSatTable1 = hueSatTable1
        self.hueSatTable2 = hueSatTable2
        self.lookTable = lookTable
    }

    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw DCPProfileError.fileReadFailed(url)
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard data.count >= 8 else { throw DCPProfileError.invalidTIFFHeader }
        let b0 = data[0], b1 = data[1]
        let littleEndian: Bool
        if b0 == 0x49 && b1 == 0x49 {
            littleEndian = true
        } else if b0 == 0x4D && b1 == 0x4D {
            littleEndian = false
        } else {
            throw DCPProfileError.invalidTIFFHeader
        }

        let reader = TIFFReader(data: data, littleEndian: littleEndian)
        let magic = try reader.readUInt16(at: 2)
        guard magic == 42 || magic == 0x4352 else { // 42 standard TIFF, 0x4352 Adobe DCP magic
            throw DCPProfileError.invalidTIFFHeader
        }
        let ifdOffset = Int(try reader.readUInt32(at: 4))
        guard ifdOffset >= 8, ifdOffset + 2 <= data.count else {
            throw DCPProfileError.invalidIFD
        }
        let entryCount = Int(try reader.readUInt16(at: ifdOffset))
        guard ifdOffset + 2 + entryCount * 12 <= data.count else {
            throw DCPProfileError.invalidIFD
        }

        var ill1: Double = 5000.0
        var ill2: Double? = nil
        var cm1: simd_double3x3? = nil
        var cm2: simd_double3x3? = nil
        var fm1: simd_double3x3? = nil
        var fm2: simd_double3x3? = nil
        var hueSatDims: [Int]? = nil
        var hueSatRaw1: [Float]? = nil
        var hueSatRaw2: [Float]? = nil
        var lookDims: [Int]? = nil
        var lookRaw: [Float]? = nil

        for idx in 0..<entryCount {
            let base = ifdOffset + 2 + idx * 12
            let tag = try reader.readUInt16(at: base)
            let type = try reader.readUInt16(at: base + 2)
            let count = Int(try reader.readUInt32(at: base + 4))
            let valOffset = base + 8

            switch tag {
            case 0xC6FC:
                // ProfileToneCurve MUST be skipped to preserve HDR linear highlight headroom.
                continue
            case 0xC65A:
                if let code = try reader.readSingleInt(type: type, count: count, valueFieldOffset: valOffset) {
                    ill1 = Self.kelvinForIlluminantCode(code) ?? 5000.0
                }
            case 0xC65B:
                if let code = try reader.readSingleInt(type: type, count: count, valueFieldOffset: valOffset) {
                    ill2 = Self.kelvinForIlluminantCode(code)
                }
            case 0xC621:
                if let vals = try reader.readSRationals(type: type, count: count, valueFieldOffset: valOffset),
                   let m = ColorTransforms.matrixFromRowMajor9(vals) {
                    cm1 = m
                }
            case 0xC622:
                if let vals = try reader.readSRationals(type: type, count: count, valueFieldOffset: valOffset),
                   let m = ColorTransforms.matrixFromRowMajor9(vals) {
                    cm2 = m
                }
            case 0xC714:
                if let vals = try reader.readSRationals(type: type, count: count, valueFieldOffset: valOffset),
                   let m = ColorTransforms.matrixFromRowMajor9(vals) {
                    fm1 = m
                }
            case 0xC715:
                if let vals = try reader.readSRationals(type: type, count: count, valueFieldOffset: valOffset),
                   let m = ColorTransforms.matrixFromRowMajor9(vals) {
                    fm2 = m
                }
            case 0xC6F9:
                hueSatDims = try reader.readUInt32Array(type: type, count: count, valueFieldOffset: valOffset)?.map(Int.init)
            case 0xC6FA:
                hueSatRaw1 = try reader.readFloatArray(type: type, count: count, valueFieldOffset: valOffset)
            case 0xC6FB:
                hueSatRaw2 = try reader.readFloatArray(type: type, count: count, valueFieldOffset: valOffset)
            case 0xC725:
                lookDims = try reader.readUInt32Array(type: type, count: count, valueFieldOffset: valOffset)?.map(Int.init)
            case 0xC726:
                lookRaw = try reader.readFloatArray(type: type, count: count, valueFieldOffset: valOffset)
            default:
                continue
            }
        }

        self.illuminant1Kelvin = ill1
        self.illuminant2Kelvin = ill2
        self.colorMatrix1 = cm1
        self.colorMatrix2 = cm2
        self.forwardMatrix1 = fm1
        self.forwardMatrix2 = fm2
        self.hueSatTable1 = try Self.buildHSVTable(dims: hueSatDims, floats: hueSatRaw1)
        self.hueSatTable2 = try Self.buildHSVTable(dims: hueSatDims, floats: hueSatRaw2)
        self.lookTable = try Self.buildHSVTable(dims: lookDims, floats: lookRaw)
    }

    public func interpolationWeight(sceneKelvin: Double) -> Double {
        guard let t2 = illuminant2Kelvin, abs(t2 - illuminant1Kelvin) > 1.0 else {
            return 1.0
        }
        let m1 = 1.0 / illuminant1Kelvin
        let m2 = 1.0 / t2
        let ms = 1.0 / min(max(sceneKelvin, 2000.0), 15000.0)
        return min(max((ms - m2) / (m1 - m2), 0.0), 1.0)
    }

    public func interpolatedForwardMatrix(sceneKelvin: Double) -> simd_double3x3? {
        switch (forwardMatrix1, forwardMatrix2) {
        case let (fm1?, fm2?):
            let g = interpolationWeight(sceneKelvin: sceneKelvin)
            return blendMatrices(fm2, fm1, weightB: g)
        case let (fm1?, nil):
            return fm1
        case let (nil, fm2?):
            return fm2
        case (nil, nil):
            return nil
        }
    }

    public func interpolatedColorMatrix(sceneKelvin: Double) -> simd_double3x3? {
        switch (colorMatrix1, colorMatrix2) {
        case let (cm1?, cm2?):
            let g = interpolationWeight(sceneKelvin: sceneKelvin)
            return blendMatrices(cm2, cm1, weightB: g)
        case let (cm1?, nil):
            return cm1
        case let (nil, cm2?):
            return cm2
        case (nil, nil):
            return nil
        }
    }

    public func interpolatedHueSatTable(sceneKelvin: Double) -> HSVTable3D? {
        guard let t1 = hueSatTable1 else { return hueSatTable2 }
        guard let t2 = hueSatTable2,
              t1.hueDivs == t2.hueDivs, t1.satDivs == t2.satDivs, t1.valDivs == t2.valDivs else {
            return t1
        }
        let g = Float(interpolationWeight(sceneKelvin: sceneKelvin))
        let blended = zip(t2.rgbaFloats, t1.rgbaFloats).map { $0 * (1.0 - g) + $1 * g }
        return HSVTable3D(hueDivs: t1.hueDivs, satDivs: t1.satDivs, valDivs: t1.valDivs, rgbaFloats: blended)
    }

    /// Built-in Sony Creative Look / color-mode presets (subtle HSV-preserving transforms without clipping HDR > 1.0).
    public static func builtInCreativeLook(named name: String) -> HSVTable3D? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let satScale: Float
        let valScale: Float
        let warmShift: Float
        switch key {
        case "VV", "VIVID":
            satScale = 1.15; valScale = 1.0; warmShift = 0.0
        case "VV2":
            satScale = 1.22; valScale = 1.02; warmShift = 0.0
        case "PT", "PORTRAIT":
            satScale = 0.94; valScale = 1.02; warmShift = 2.0
        case "NT", "NEUTRAL":
            satScale = 0.92; valScale = 1.0; warmShift = 0.0
        case "FL", "FILM":
            satScale = 0.96; valScale = 0.98; warmShift = -3.0
        case "IN", "INSTANT":
            satScale = 0.85; valScale = 0.98; warmShift = 3.0
        case "SH", "SOFT_HIGHKEY":
            satScale = 0.90; valScale = 1.05; warmShift = 0.0
        case "BW", "MONOCHROME":
            satScale = 0.0; valScale = 1.0; warmShift = 0.0
        case "ST", "STANDARD", "":
            return nil
        default:
            return nil
        }

        let hDivs = 6, sDivs = 2, vDivs = 2
        var rgba = [Float](repeating: 0, count: hDivs * sDivs * vDivs * 4)
        for v in 0..<vDivs {
            for h in 0..<hDivs {
                for s in 0..<sDivs {
                    let idx = ((v * hDivs * sDivs) + h * sDivs + s) * 4
                    rgba[idx + 0] = warmShift
                    rgba[idx + 1] = satScale
                    rgba[idx + 2] = valScale
                    rgba[idx + 3] = 0.0
                }
            }
        }
        return HSVTable3D(hueDivs: hDivs, satDivs: sDivs, valDivs: vDivs, rgbaFloats: rgba)
    }

    private func blendMatrices(_ a: simd_double3x3, _ b: simd_double3x3, weightB g: Double) -> simd_double3x3 {
        let wA = 1.0 - g
        return simd_double3x3(
            a.columns.0 * wA + b.columns.0 * g,
            a.columns.1 * wA + b.columns.1 * g,
            a.columns.2 * wA + b.columns.2 * g
        )
    }

    private static func buildHSVTable(dims: [Int]?, floats: [Float]?) throws -> HSVTable3D? {
        guard let dims else { return nil }
        guard dims.count == 3 else { throw DCPProfileError.invalidIFD }
        let hDivs = dims[0], sDivs = dims[1], vDivs = dims[2]
        guard hDivs >= 2, hDivs <= 360,
              sDivs >= 1, sDivs <= 256,
              vDivs >= 1, vDivs <= 256 else {
            throw DCPProfileError.invalidIFD
        }
        let (hs, ov1) = hDivs.multipliedReportingOverflow(by: sDivs)
        let (expectedTriplets, ov2) = hs.multipliedReportingOverflow(by: vDivs)
        let (expectedFloats, ov3) = expectedTriplets.multipliedReportingOverflow(by: 3)
        guard !ov1, !ov2, !ov3 else {
            throw DCPProfileError.invalidIFD
        }
        guard let floats else { return nil }
        guard floats.count >= expectedFloats else {
            throw DCPProfileError.invalidIFD
        }
        var rgba = [Float](repeating: 0, count: expectedTriplets * 4)
        for i in 0..<expectedTriplets {
            rgba[i * 4 + 0] = floats[i * 3 + 0]
            rgba[i * 4 + 1] = floats[i * 3 + 1]
            rgba[i * 4 + 2] = floats[i * 3 + 2]
            rgba[i * 4 + 3] = 0.0
        }
        return HSVTable3D(hueDivs: hDivs, satDivs: sDivs, valDivs: vDivs, rgbaFloats: rgba)
    }

    private static func kelvinForIlluminantCode(_ code: Int) -> Double? {
        switch code {
        case 1, 4, 9, 20: return 5500.0
        case 2: return 4000.0
        case 3, 17: return 2856.0
        case 10, 21: return 6500.0
        case 11, 22: return 7500.0
        case 19, 23: return 5000.0
        case 24: return 3200.0
        default: return nil
        }
    }
}

private struct TIFFReader {
    let data: Data
    let littleEndian: Bool

    func readUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw DCPProfileError.invalidIFD }
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return littleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw DCPProfileError.invalidIFD }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return littleEndian
            ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
            : ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
    }

    func readInt32(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32(at: offset))
    }

    func readSingleInt(type: UInt16, count: Int, valueFieldOffset: Int) throws -> Int? {
        guard count == 1 else { return nil }
        if type == 3 { // SHORT
            return Int(try readUInt16(at: valueFieldOffset))
        } else if type == 4 { // LONG
            return Int(try readUInt32(at: valueFieldOffset))
        }
        return nil
    }

    func dataOffset(typeSize: Int, count: Int, valueFieldOffset: Int) throws -> Int {
        let (total, ov) = typeSize.multipliedReportingOverflow(by: count)
        if ov { throw DCPProfileError.invalidIFD }
        if total <= 4 {
            return valueFieldOffset
        }
        return Int(try readUInt32(at: valueFieldOffset))
    }

    func readUInt32Array(type: UInt16, count: Int, valueFieldOffset: Int) throws -> [UInt32]? {
        guard type == 4 || type == 3, count > 0 else { return nil }
        let elemSize = (type == 3) ? 2 : 4
        let start = try dataOffset(typeSize: elemSize, count: count, valueFieldOffset: valueFieldOffset)
        let (byteCount, ov) = elemSize.multipliedReportingOverflow(by: count)
        guard !ov, start >= 0, start <= data.count, byteCount <= data.count - start else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if elemSize == 2 {
                out.append(UInt32(try readUInt16(at: start + i * 2)))
            } else {
                out.append(try readUInt32(at: start + i * 4))
            }
        }
        return out
    }

    func readSRationals(type: UInt16, count: Int, valueFieldOffset: Int) throws -> [Double]? {
        guard count > 0, (type == 10 || type == 5 || type == 11 || type == 12) else { return nil }
        if type == 11 { // FLOAT
            return try readFloatArray(type: type, count: count, valueFieldOffset: valueFieldOffset)?.map(Double.init)
        }
        let elemSize = 8
        let start = try dataOffset(typeSize: elemSize, count: count, valueFieldOffset: valueFieldOffset)
        guard start >= 0, start + count * elemSize <= data.count else { return nil }
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let off = start + i * 8
            if type == 10 { // SRATIONAL
                let num = Double(try readInt32(at: off))
                let den = Double(try readInt32(at: off + 4))
                out.append(abs(den) > 1e-12 ? num / den : 0.0)
            } else if type == 5 { // RATIONAL
                let num = Double(try readUInt32(at: off))
                let den = Double(try readUInt32(at: off + 4))
                out.append(abs(den) > 1e-12 ? num / den : 0.0)
            } else { // DOUBLE
                let lo = UInt64(try readUInt32(at: off))
                let hi = UInt64(try readUInt32(at: off + 4))
                let bits = littleEndian ? (lo | (hi << 32)) : ((lo << 32) | hi)
                out.append(Double(bitPattern: bits))
            }
        }
        return out
    }

    func readFloatArray(type: UInt16, count: Int, valueFieldOffset: Int) throws -> [Float]? {
        guard type == 11, count > 0 else { return nil }
        let start = try dataOffset(typeSize: 4, count: count, valueFieldOffset: valueFieldOffset)
        guard start >= 0, start + count * 4 <= data.count else { return nil }
        var out: [Float] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let bits = try readUInt32(at: start + i * 4)
            out.append(Float(bitPattern: bits))
        }
        return out
    }
}
