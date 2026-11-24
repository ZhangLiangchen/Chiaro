import AVFoundation
import CLibAVIFBridge
import CLibRawBridge
import CUltraHDRBridge
import CoreGraphics
import CoreVideo
import Foundation
@testable import ChiaroAppCore
@testable import ChiaroCore
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import simd

private let t5TangmoDir = TestFixtures.sampleDirectory

private func makeT5TempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func hasT5LeftoverTmpFiles(in dir: URL) throws -> Bool {
    let contents = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil,
        options: []
    )
    return contents.contains { $0.lastPathComponent.contains(".tmp") }
}

private func makeT5Float16Data(width: Int, height: Int, rgba: SIMD4<Float>) -> Data {
    let r = Float16(rgba.x).bitPattern
    let g = Float16(rgba.y).bitPattern
    let b = Float16(rgba.z).bitPattern
    let a = Float16(rgba.w).bitPattern
    var halfs = [UInt16](repeating: 0, count: width * height * 4)
    for idx in stride(from: 0, to: halfs.count, by: 4) {
        halfs[idx + 0] = r
        halfs[idx + 1] = g
        halfs[idx + 2] = b
        halfs[idx + 3] = a
    }
    return halfs.withUnsafeBytes { Data($0) }
}

private func decodeT5HLGCenterYCbCr10(_ pb: CVPixelBuffer) throws -> (y: Int, cb: Int, cr: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let cx = w / 2
    let cy = h / 2

    let yBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 0))
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / MemoryLayout<UInt16>.stride
    let yPtr = yBase.assumingMemoryBound(to: UInt16.self)
    let y10 = Int((yPtr[cy * yStride + cx] >> 6) & 0x3FF)

    let uvBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 1))
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / MemoryLayout<UInt16>.stride
    let uvPtr = uvBase.assumingMemoryBound(to: UInt16.self)
    let uvIdx = (cy / 2) * uvStride + (cx / 2) * 2
    let cb10 = Int((uvPtr[uvIdx + 0] >> 6) & 0x3FF)
    let cr10 = Int((uvPtr[uvIdx + 1] >> 6) & 0x3FF)

    return (y10, cb10, cr10)
}

private func makeT5UntaggedJPEG(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) throws -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: bytes.count, by: 4) {
        bytes[i + 0] = rgb.0
        bytes[i + 1] = rgb.1
        bytes[i + 2] = rgb.2
        bytes[i + 3] = 255
    }
    let ctx = try #require(CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let img = try #require(ctx.makeImage())
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    try #require(CGImageDestinationFinalize(dest))
    return out as Data
}

private func makeT5JPEG(width: Int, height: Int, colorSpace: CFString, rgb: (UInt8, UInt8, UInt8)) throws -> Data {
    let cs = try #require(CGColorSpace(name: colorSpace))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: bytes.count, by: 4) {
        bytes[i + 0] = rgb.0
        bytes[i + 1] = rgb.1
        bytes[i + 2] = rgb.2
        bytes[i + 3] = 255
    }
    let ctx = try #require(CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let img = try #require(ctx.makeImage())
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    try #require(CGImageDestinationFinalize(dest))
    return out as Data
}

private func makeT5SyntheticCGImage(
    width: Int,
    height: Int,
    bitDepth: BitDepth,
    colorSpace: BaseColorSpace
) throws -> CGImage {
    let csName: CFString = (colorSpace == .srgb) ? CGColorSpace.sRGB : CGColorSpace.displayP3
    let cs = try #require(CGColorSpace(name: csName))

    if bitDepth == .bit10 {
        let bpr = width * 8
        var pixels = Data(count: bpr * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
            for y in 0..<height {
                let gVal = UInt16((y * 65535) / max(1, height - 1))
                let rowOff = y * width * 4
                for x in 0..<width {
                    let rVal = UInt16((x * 65535) / max(1, width - 1))
                    let idx = rowOff + x * 4
                    ptr[idx + 0] = rVal
                    ptr[idx + 1] = gVal
                    ptr[idx + 2] = 24576
                    ptr[idx + 3] = 65535
                }
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    } else {
        let bpr = width * 4
        var pixels = Data(count: bpr * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                let gVal = UInt8((y * 255) / max(1, height - 1))
                let rowOff = y * bpr
                for x in 0..<width {
                    let rVal = UInt8((x * 255) / max(1, width - 1))
                    let idx = rowOff + x * 4
                    ptr[idx + 0] = rVal
                    ptr[idx + 1] = gVal
                    ptr[idx + 2] = 96
                    ptr[idx + 3] = 255
                }
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

private func makeT5RenderedFrame(
    width: Int,
    height: Int,
    bitDepth: BitDepth = .bit10,
    baseColorSpace: BaseColorSpace = .displayP3,
    gainMapChannels: GainMapChannels = .rgb3ch,
    gainMapResolution: GainMapResolution = .half,
    gainMapMin: [Double]? = nil,
    gainMapMax: [Double]? = nil,
    gainMapGamma: [Double]? = nil,
    targetHeadroomStops: Double = 2.5
) throws -> RenderedFrame {
    let baseCG = try makeT5SyntheticCGImage(
        width: width,
        height: height,
        bitDepth: bitDepth,
        colorSpace: baseColorSpace
    )
    let gmW = (gainMapResolution == .half) ? max(2, (width + 1) / 2) : width
    let gmH = (gainMapResolution == .half) ? max(2, (height + 1) / 2) : height
    let bpp = (gainMapChannels == .mono1ch) ? 1 : 4
    let gmBPR = gmW * bpp
    var gmBytes = Data(count: gmBPR * gmH)
    gmBytes.withUnsafeMutableBytes { raw in
        guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for y in 0..<gmH {
            for x in 0..<gmW {
                let v = UInt8(((x + y) * 255) / max(1, gmW + gmH - 2))
                let off = y * gmBPR + x * bpp
                if bpp == 1 {
                    ptr[off] = v
                } else {
                    ptr[off + 0] = v
                    ptr[off + 1] = v
                    ptr[off + 2] = v
                    ptr[off + 3] = 255
                }
            }
        }
    }
    let gmBuf = GainMapBuffer(
        width: gmW,
        height: gmH,
        channels: gainMapChannels,
        bytesPerRow: gmBPR,
        data: gmBytes
    )
    let count = (gainMapChannels == .mono1ch) ? 1 : 3
    let minArr = gainMapMin ?? Array(repeating: 0.0, count: count)
    let maxArr = gainMapMax ?? Array(repeating: targetHeadroomStops, count: count)
    let gammaArr = gainMapGamma ?? Array(repeating: 1.0, count: count)
    let offsetArr = Array(repeating: GainMapMetadata.symmetricOffset, count: count)
    let meta = GainMapMetadata(
        gainMapMin: minArr,
        gainMapMax: maxArr,
        gamma: gammaArr,
        baseOffset: offsetArr,
        altOffset: offsetArr,
        baseHeadroom: .sdr,
        alternateHeadroom: HeadroomStops(log2Value: targetHeadroomStops),
        useBaseColorSpace: true
    )
    return RenderedFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/t5_synthetic.arw"),
        width: width,
        height: height,
        baseColorSpace: baseColorSpace,
        sdrCGImage: baseCG,
        sdrLinearTexture: nil,
        hdrLinearTexture: nil,
        hlgPixelBuffer: nil,
        gainMap: GainMapResult(buffer: gmBuf, metadata: meta),
        exif: WhitelistedExif(make: "SONY", model: "ILCE-7CM2", orientation: 1)
    )
}

private func makeT5BigEndianDualIlluminantDCPData() -> Data {
    var data = Data()
    func appendU16BE(_ v: UInt16) {
        var be = v.bigEndian
        data.append(Data(bytes: &be, count: 2))
    }
    func appendU32BE(_ v: UInt32) {
        var be = v.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }
    func appendS32BE(_ v: Int32) {
        var be = v.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }
    func appendF32BE(_ v: Float) {
        var be = v.bitPattern.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }

    // Header: "MM", magic 0x4352 (Adobe DCP), IFD0 at 8
    data.append(contentsOf: [0x4D, 0x4D])
    appendU16BE(0x4352)
    appendU32BE(8)

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let inlineOrData: Data
        let isInline: Bool
    }

    func srat9(_ vals: [Double]) -> Data {
        var d = Data()
        for v in vals {
            let num = Int32((v * 10000.0).rounded())
            var nBE = num.bigEndian
            var denBE = Int32(10000).bigEndian
            d.append(Data(bytes: &nBE, count: 4))
            d.append(Data(bytes: &denBE, count: 4))
        }
        return d
    }

    func u32Arr(_ vals: [UInt32]) -> Data {
        var d = Data()
        for v in vals {
            var be = v.bigEndian
            d.append(Data(bytes: &be, count: 4))
        }
        return d
    }

    func f32Arr(_ vals: [Float]) -> Data {
        var d = Data()
        for v in vals {
            var be = v.bitPattern.bigEndian
            d.append(Data(bytes: &be, count: 4))
        }
        return d
    }

    func inlineU16BE(_ v: UInt16) -> Data {
        var d = Data()
        var be = v.bigEndian
        d.append(Data(bytes: &be, count: 2))
        d.append(contentsOf: [0, 0])
        return d
    }

    // Dual-illuminant matrices (Identity D50-adapted simplified test matrices) + HueSatMap 2x1x2
    let fm1 = srat9([
        0.9642, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 0.8249,
    ])
    let fm2 = srat9([
        0.9642, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 0.8249,
    ])
    let dims = u32Arr([2, 1, 2]) // hueDivs=2, satDivs=1, valDivs=2
    // 2*1*2 = 4 entries * 3 floats (hueShiftDeg, satScale, valScale)
    let hsv1 = f32Arr([
        0.0, 1.05, 1.0,  0.0, 1.05, 1.0,
        0.0, 1.05, 1.0,  0.0, 1.05, 1.0,
    ])
    let hsv2 = f32Arr([
        0.0, 1.15, 1.0,  0.0, 1.15, 1.0,
        0.0, 1.15, 1.0,  0.0, 1.15, 1.0,
    ])

    let entries: [Entry] = [
        Entry(tag: 0xC65A, type: 3, count: 1, inlineOrData: inlineU16BE(17), isInline: true), // StdA 2856K
        Entry(tag: 0xC65B, type: 3, count: 1, inlineOrData: inlineU16BE(21), isInline: true), // D65 6500K
        Entry(tag: 0xC6F9, type: 4, count: 3, inlineOrData: dims, isInline: false),
        Entry(tag: 0xC6FA, type: 11, count: 12, inlineOrData: hsv1, isInline: false),
        Entry(tag: 0xC6FB, type: 11, count: 12, inlineOrData: hsv2, isInline: false),
        Entry(tag: 0xC714, type: 10, count: 9, inlineOrData: fm1, isInline: false),
        Entry(tag: 0xC715, type: 10, count: 9, inlineOrData: fm2, isInline: false),
    ]

    let ifdStart = 8
    let ifdSize = 2 + entries.count * 12 + 4
    var nextDataOffset = ifdStart + ifdSize

    appendU16BE(UInt16(entries.count))
    var externalBlobs = Data()
    for e in entries {
        appendU16BE(e.tag)
        appendU16BE(e.type)
        appendU32BE(e.count)
        if e.isInline {
            data.append(e.inlineOrData)
        } else {
            appendU32BE(UInt32(nextDataOffset))
            externalBlobs.append(e.inlineOrData)
            nextDataOffset += e.inlineOrData.count
        }
    }
    appendU32BE(0)
    data.append(externalBlobs)
    return data
}

private func makeT5BigEndianTIFFWithOrientation(_ orientation: UInt16) -> Data {
    var d = Data()
    func u16(_ v: UInt16) {
        var be = v.bigEndian
        d.append(Data(bytes: &be, count: 2))
    }
    func u32(_ v: UInt32) {
        var be = v.bigEndian
        d.append(Data(bytes: &be, count: 4))
    }
    d.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
    u32(8)
    u16(2)
    // Make = "SONY\0" (5 bytes -> external)
    let makeBytes = Data("SONY\0".utf8)
    let makeOffset: UInt32 = 8 + 2 + 2 * 12 + 4
    u16(0x010F); u16(2); u32(UInt32(makeBytes.count)); u32(makeOffset)
    // Orientation
    u16(0x0112); u16(3); u32(1); u16(orientation); u16(0)
    u32(0)
    d.append(makeBytes)
    return d
}

private func makeT5LittleEndianExifTIFF(orientation: UInt16 = 1, bigEndian: Bool = false) -> Data {
    var d = Data()
    func u16(_ v: UInt16) {
        var x = bigEndian ? v.bigEndian : v.littleEndian
        d.append(Data(bytes: &x, count: 2))
    }
    func u32(_ v: UInt32) {
        var x = bigEndian ? v.bigEndian : v.littleEndian
        d.append(Data(bytes: &x, count: 4))
    }
    if bigEndian {
        d.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
    } else {
        d.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
    }
    u32(8)
    u16(2)
    let makeBytes = Data("SONY\0".utf8)
    let makeOffset: UInt32 = 8 + 2 + 2 * 12 + 4
    u16(0x010F); u16(2); u32(UInt32(makeBytes.count)); u32(makeOffset)
    u16(0x0112); u16(3); u32(1); u16(orientation); u16(0)
    u32(0)
    d.append(makeBytes)
    return d
}

// MARK: - Tier 5 Adversarial Test Suite

extension ChiaroSerializedSuites {

@Suite("Tier5AdversarialTests", .serialized)
struct Tier5AdversarialTests {

    // MARK: - 1. P1/P2 Shared Gap 1: baseColorSpace: .srgb + .hlgMP4 primary matrix parity

    @Test("Gap 1: HLG conversion matrix parity for sRGB vs Display P3 baseColorSpace")
    func testHLGConversionMatrixParityForSRGBAndDisplayP3() async throws {
        let engine = try MetalPipelineEngine()
        let preset = try PresetLoader.loadBuiltIn(id: .douyinHLGMP4)
        let params = EffectiveDevelopParams.resolve(preset: preset)

        // 1) Direct generateHLGPixelBuffer parity: sRGB (1, 0, 0) vs Display P3 equivalent (0.82246, 0.03319, 0.01708)
        do {
            let w = 16
            let h = 16
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: w,
                height: h,
                mipmapped: false
            )
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            let srgbTex = try #require(engine.device.makeTexture(descriptor: desc))
            let p3Tex = try #require(engine.device.makeTexture(descriptor: desc))
            let srgbData = makeT5Float16Data(width: w, height: h, rgba: SIMD4<Float>(1.0, 0.0, 0.0, 1.0))
            let p3Equiv = ColorTransforms.rec2020ToDisplayP3 * (ColorTransforms.srgbToRec2020 * SIMD3<Double>(1.0, 0.0, 0.0))
            let p3Data = makeT5Float16Data(
                width: w,
                height: h,
                rgba: SIMD4<Float>(Float(p3Equiv.x), Float(p3Equiv.y), Float(p3Equiv.z), 1.0)
            )
            srgbData.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    srgbTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: w * 8)
                }
            }
            p3Data.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    p3Tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: w * 8)
                }
            }
            let pbSRGBDirect = try await engine.generateHLGPixelBuffer(
                from: SendableMTLTexture(srgbTex),
                baseColorSpace: .srgb,
                targetDimensions: PixelDimensions(width: 64, height: 64)
            ).buffer
            let pbP3Direct = try await engine.generateHLGPixelBuffer(
                from: SendableMTLTexture(p3Tex),
                baseColorSpace: .displayP3,
                targetDimensions: PixelDimensions(width: 64, height: 64)
            ).buffer
            let yccSRGBDirect = try decodeT5HLGCenterYCbCr10(pbSRGBDirect)
            let yccP3Direct = try decodeT5HLGCenterYCbCr10(pbP3Direct)
            #expect(abs(yccP3Direct.y - yccSRGBDirect.y) <= 1, "Direct HLG Y10 mismatch: P3=\(yccP3Direct) sRGB=\(yccSRGBDirect)")
            #expect(abs(yccP3Direct.cb - yccSRGBDirect.cb) <= 1, "Direct HLG Cb10 mismatch: P3=\(yccP3Direct) sRGB=\(yccSRGBDirect)")
            #expect(abs(yccP3Direct.cr - yccSRGBDirect.cr) <= 1, "Direct HLG Cr10 mismatch: P3=\(yccP3Direct) sRGB=\(yccSRGBDirect)")
        }

        // 2) Full MetalPipelineEngine.render parity for interior sRGB colors (not compressed by soft gamut knee)
        let colorsRec2020: [SIMD3<Double>] = [
            ColorTransforms.srgbToRec2020 * SIMD3<Double>(1.2, 0.45, 0.35),
            ColorTransforms.srgbToRec2020 * SIMD3<Double>(0.35, 0.45, 1.2),
        ]

        for rec2020Color in colorsRec2020 {
            let w = 16
            let h = 16
            let data = makeT5Float16Data(
                width: w,
                height: h,
                rgba: SIMD4<Float>(Float(rec2020Color.x), Float(rec2020Color.y), Float(rec2020Color.z), 1.0)
            )
            let frame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/t5_hlg_srgb.arw"),
                backendUsed: .libraw,
                payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: data),
                visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif(make: "SONY", model: "ILCE-7CM2", orientation: 1)
            )

            let specP3 = RenderOutputSpec(
                targetBitDepth: .bit10,
                baseColorSpace: .displayP3,
                gainMapChannels: .mono1ch,
                gainMapResolution: .half,
                gainMapGamma: 1.0,
                lockLegacyAppleGainMapBounds: false,
                generateHLGTexture: true,
                hlgTargetDimensions: PixelDimensions(width: 64, height: 64)
            )
            let specSRGB = RenderOutputSpec(
                targetBitDepth: .bit10,
                baseColorSpace: .srgb,
                gainMapChannels: .mono1ch,
                gainMapResolution: .half,
                gainMapGamma: 1.0,
                lockLegacyAppleGainMapBounds: false,
                generateHLGTexture: true,
                hlgTargetDimensions: PixelDimensions(width: 64, height: 64)
            )

            let renderedP3 = try await engine.render(frame: frame, params: params, outputSpec: specP3)
            let renderedSRGB = try await engine.render(frame: frame, params: params, outputSpec: specSRGB)

            let pbP3 = try #require(renderedP3.hlgPixelBuffer).buffer
            let pbSRGB = try #require(renderedSRGB.hlgPixelBuffer).buffer
            let yccP3 = try decodeT5HLGCenterYCbCr10(pbP3)
            let yccSRGB = try decodeT5HLGCenterYCbCr10(pbSRGB)

            #expect(abs(yccP3.y - yccSRGB.y) <= 2, "Y10 mismatch: P3=\(yccP3) sRGB=\(yccSRGB)")
            #expect(abs(yccP3.cb - yccSRGB.cb) <= 2, "Cb10 mismatch: P3=\(yccP3) sRGB=\(yccSRGB)")
            #expect(abs(yccP3.cr - yccSRGB.cr) <= 2, "Cr10 mismatch: P3=\(yccP3) sRGB=\(yccSRGB)")

            // Also verify HLGVideoEncoder fallback path when hlgPixelBuffer is nil and hdrLinearTexture is non-nil
            let tmpDir = try makeT5TempDir(prefix: "t5_hlg_srgb_enc")
            defer { try? FileManager.default.removeItem(at: tmpDir) }
            let renderedNoPB = RenderedFrame(
                sourceURL: renderedSRGB.sourceURL,
                width: renderedSRGB.width,
                height: renderedSRGB.height,
                baseColorSpace: .srgb,
                sdrCGImage: renderedSRGB.sdrCGImage,
                sdrLinearTexture: nil,
                hdrLinearTexture: renderedSRGB.hdrLinearTexture,
                hlgPixelBuffer: nil,
                gainMap: renderedSRGB.gainMap,
                exif: renderedSRGB.exif
            )
            let enc = HLGVideoEncoder(metalEngine: engine)
            let mp4URL = tmpDir.appendingPathComponent("srgb_hlg.mp4")
            let opts = HLGVideoOptions(aspect: .portrait3x4, durationSeconds: 3.0, fps: 30, bitrateMbps: 14.0)
            let artifact = try await enc.encodeVideo(frame: renderedNoPB, preset: preset, options: opts, to: mp4URL)
            #expect(FileManager.default.fileExists(atPath: artifact.outputURL.path))
        }
    }

    // MARK: - 2. P1 Gap 2: MetalPipelineEngine zero/negative dimension guards

    @Test("Gap 2: MetalPipelineEngine rejects zero and negative dimensions without SIGTRAP")
    func testMetalPipelineRejectsZeroAndNegativeDimensionsWithoutCrashing() async throws {
        let engine = try MetalPipelineEngine()
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let params = EffectiveDevelopParams.resolve(preset: preset)
        let spec = RenderOutputSpec(
            targetBitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .rgb3ch,
            gainMapResolution: .half,
            gainMapGamma: 1.0,
            lockLegacyAppleGainMapBounds: false,
            generateHLGTexture: false,
            hlgTargetDimensions: nil
        )

        let payloads: [RAWPixelPayload] = [
            .rawBayer(width: 0, height: 10, bitsPerSample: 14, cfa: .rggb, data: Data()),
            .rawBayer(width: 10, height: 0, bitsPerSample: 14, cfa: .rggb, data: Data()),
            .rawBayer(width: -4, height: 4, bitsPerSample: 14, cfa: .rggb, data: Data()),
            .linearRGB16U(width: 0, height: 10, colorSpace: .cameraNative, data: Data()),
            .linearRGB16U(width: 10, height: 0, colorSpace: .cameraNative, data: Data()),
            .linearRGB16U(width: -4, height: 4, colorSpace: .cameraNative, data: Data()),
            .linearRGB16F(width: 0, height: 10, colorSpace: .linearRec2020, data: Data()),
            .linearRGB16F(width: 10, height: 0, colorSpace: .linearRec2020, data: Data()),
            .linearRGB16F(width: -4, height: 4, colorSpace: .linearRec2020, data: Data()),
            .linearRGB16U(width: 8, height: 8, colorSpace: .cameraNative, data: Data(repeating: 0, count: 16)),
        ]

        for payload in payloads {
            let frame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/t5_bad_dim.arw"),
                backendUsed: .libraw,
                payload: payload,
                visibleCrop: SensorCropRect(x: 0, y: 0, width: 10, height: 10),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif(orientation: 1)
            )
            await #expect(throws: MetalPipelineError.self) {
                _ = try await engine.render(frame: frame, params: params, outputSpec: spec)
            }
        }
    }

    @Test("Remaining Gap 1 (P1): Metal texture dimensions > maxDim (16384) rejected cleanly without SIGABRT")
    func testMetalTextureOver16384RejectedCleanlyWithoutSIGABRT() async throws {
        let engine = try MetalPipelineEngine()
        let pool = engine.texturePool
        let overDim = MTLHeapTexturePool.maxTextureDimension(for: engine.device) + 1

        // 1. MTLHeapTexturePool.acquire rejects > maxDim cleanly
        do {
            _ = try pool.acquire(width: overDim, height: 4, pixelFormat: .rgba16Float)
            Issue.record("Expected MTLHeapTexturePoolError.invalidDimensions for width=\(overDim)")
        } catch let error as MTLHeapTexturePoolError {
            if case let .invalidDimensions(w, h) = error {
                #expect(w == overDim && h == 4)
            } else {
                Issue.record("Unexpected MTLHeapTexturePoolError: \(error)")
            }
        }

        do {
            _ = try pool.acquire(width: 4, height: 65536, pixelFormat: .rgba16Float)
            Issue.record("Expected MTLHeapTexturePoolError.invalidDimensions for height=65536")
        } catch let error as MTLHeapTexturePoolError {
            if case let .invalidDimensions(w, h) = error {
                #expect(w == 4 && h == 65536)
            } else {
                Issue.record("Unexpected MTLHeapTexturePoolError: \(error)")
            }
        }

        // 2. MetalPipelineEngine.render rejects > maxDim across .rawBayer, .linearRGB16U, .linearRGB16F
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let params = EffectiveDevelopParams.resolve(preset: preset)
        let spec = RenderOutputSpec(
            targetBitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .rgb3ch,
            gainMapResolution: .half,
            gainMapGamma: 1.0,
            lockLegacyAppleGainMapBounds: false,
            generateHLGTexture: false,
            hlgTargetDimensions: nil
        )

        let overPayloads: [RAWPixelPayload] = [
            .rawBayer(width: overDim, height: 4, bitsPerSample: 14, cfa: .rggb, data: Data()),
            .linearRGB16U(width: overDim, height: 4, colorSpace: .cameraNative, data: Data()),
            .linearRGB16F(width: overDim, height: 4, colorSpace: .linearRec2020, data: Data()),
            .linearRGB16F(width: 4, height: overDim, colorSpace: .linearRec2020, data: Data()),
        ]
        for payload in overPayloads {
            let frame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/t5_over_maxdim.arw"),
                backendUsed: .libraw,
                payload: payload,
                visibleCrop: SensorCropRect(x: 0, y: 0, width: 4, height: 4),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif(orientation: 1)
            )
            do {
                _ = try await engine.render(frame: frame, params: params, outputSpec: spec)
                Issue.record("Expected MetalPipelineError.invalidDimensions for oversized payload")
            } catch let error as MetalPipelineError {
                if case .invalidDimensions = error {
                    // expected
                } else {
                    Issue.record("Expected MetalPipelineError.invalidDimensions, got \(error)")
                }
            }
        }

        // 3. MetalPipelineEngine.generateHLGPixelBuffer rejects > maxDim targetDimensions
        let smallHDR = try pool.acquire(width: 4, height: 4, pixelFormat: .rgba16Float)
        do {
            _ = try await engine.generateHLGPixelBuffer(
                from: smallHDR,
                baseColorSpace: .displayP3,
                targetDimensions: PixelDimensions(width: overDim, height: 4)
            )
            Issue.record("Expected MetalPipelineError.invalidDimensions for generateHLGPixelBuffer")
        } catch let error as MetalPipelineError {
            if case let .invalidDimensions(w, h) = error {
                #expect(w == overDim && h == 4)
            } else {
                Issue.record("Unexpected MetalPipelineError: \(error)")
            }
        }

        // 4. GainMapSynthesizer rejects > maxDim cleanly without Metal assertion
        let oversizedJPEG = try makeT5UntaggedJPEG(width: overDim, height: 4, rgb: (128, 128, 128))
        let meta = GainMapMetadata(
            gainMapMin: [0.0],
            gainMapMax: [2.5],
            gamma: [1.0],
            baseOffset: [GainMapMetadata.symmetricOffset],
            altOffset: [GainMapMetadata.symmetricOffset],
            baseHeadroom: .sdr,
            alternateHeadroom: HeadroomStops(log2Value: 2.5),
            useBaseColorSpace: true
        )
        do {
            _ = try engine.gainMapSynthesizer.recomputeGainMapCompensated(
                commandQueue: engine.commandQueue,
                hdrTexture: smallHDR,
                compressedSDRJPEGData: oversizedJPEG,
                metadata: meta,
                gamma: 1.0,
                channels: .mono1ch,
                resolution: .full
            )
            Issue.record("Expected GainMapSynthesizerError.invalidDimensions for width=\(overDim)")
        } catch let error as GainMapSynthesizerError {
            if case let .invalidDimensions(w, h) = error {
                #expect(w == overDim && h == 4)
            } else {
                Issue.record("Unexpected GainMapSynthesizerError: \(error)")
            }
        }
    }

    // MARK: - 3. P1 Gap 3: MTLHeapTexturePool cold-bucket concurrency race

    @Test("Gap 3: MTLHeapTexturePool handles concurrent cold-bucket acquisitions without spurious budget errors")
    func testMTLHeapTexturePoolConcurrentColdBucketNoSpuriousBudgetError() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 1024,
            height: 1024,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        let sa = device.heapTextureSizeAndAlign(descriptor: desc)
        let align = max(1, sa.align)
        let slotStride = ((max(1, sa.size) + align - 1) / align) * align

        // 20 trials of 2 concurrent cold tasks at exact 2*slotStride budget
        for trial in 0..<20 {
            let pool = MTLHeapTexturePool(device: device, maxPoolBytes: slotStride * 2)
            let held = try await withThrowingTaskGroup(of: SendableMTLTexture.self, returning: [SendableMTLTexture].self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try pool.acquire(width: 1024, height: 1024, pixelFormat: .rgba16Float)
                    }
                }
                var list: [SendableMTLTexture] = []
                for try await tex in group {
                    list.append(tex)
                }
                return list
            }
            #expect(held.count == 2, "Trial \(trial) failed to acquire 2 textures")
            #expect(pool.stats.totalHeapBytes <= pool.maxPoolBytes)
        }

        // 20 trials of 4 concurrent cold tasks at 4*slotStride budget
        for trial in 0..<20 {
            let pool = MTLHeapTexturePool(device: device, maxPoolBytes: slotStride * 4)
            let held = try await withThrowingTaskGroup(of: SendableMTLTexture.self, returning: [SendableMTLTexture].self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        try pool.acquire(width: 1024, height: 1024, pixelFormat: .rgba16Float)
                    }
                }
                var list: [SendableMTLTexture] = []
                for try await tex in group {
                    list.append(tex)
                }
                return list
            }
            #expect(held.count == 4, "Trial \(trial) failed to acquire 4 textures")
            #expect(pool.stats.totalHeapBytes <= pool.maxPoolBytes)
        }

        // Cross-key concurrent 1-slot fallback when budget allows 2*1024 + 1*512 (or 4*512 + 1*1024)
        let desc512 = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 512,
            height: 512,
            mipmapped: false
        )
        desc512.storageMode = .private
        desc512.usage = [.shaderRead, .shaderWrite]
        let sa512 = device.heapTextureSizeAndAlign(descriptor: desc512)
        let align512 = max(1, sa512.align)
        let slotStride512 = ((max(1, sa512.size) + align512 - 1) / align512) * align512
        let poolCross = MTLHeapTexturePool(device: device, maxPoolBytes: slotStride * 2 + slotStride512)
        let crossHeld = try await withThrowingTaskGroup(of: SendableMTLTexture.self, returning: [SendableMTLTexture].self) { group in
            group.addTask {
                try poolCross.acquire(width: 1024, height: 1024, pixelFormat: .rgba16Float)
            }
            group.addTask {
                try poolCross.acquire(width: 512, height: 512, pixelFormat: .rgba16Float)
            }
            var list: [SendableMTLTexture] = []
            for try await tex in group {
                list.append(tex)
            }
            return list
        }
        #expect(crossHeld.count == 2)
        #expect(poolCross.stats.totalHeapBytes <= poolCross.maxPoolBytes)
    }

    // MARK: - 4. P1 Gap 4: recomputeGainMapCompensated forwards midtoneAnchorP & baseColorSpace

    @Test("Gap 4: recomputeGainMapCompensated forwards midtoneAnchorP and baseColorSpace")
    func testRecomputeGainMapCompensatedForwardsMidtoneAnchorAndBaseColorSpace() async throws {
        let engine = try MetalPipelineEngine()
        let w = 32
        let h = 32
        // Non-flat (R, B) gradient HDR texture so sRGB (Rec.709 luma) vs Display P3 luma weights produce measurably distinct gain maps
        var hdrHalfs = [UInt16](repeating: 0, count: w * h * 4)
        var jpegBytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let fy = Float(y) / Float(max(1, h - 1))
            for x in 0..<w {
                let fx = Float(x) / Float(max(1, w - 1))
                let idx = (y * w + x) * 4
                let rLin: Float = 0.6 + 3.4 * fx
                let gLin: Float = 0.4 + 1.2 * (0.5 * (fx + fy))
                let bLin: Float = 0.2 + 2.8 * fy
                hdrHalfs[idx + 0] = Float16(rLin).bitPattern
                hdrHalfs[idx + 1] = Float16(gLin).bitPattern
                hdrHalfs[idx + 2] = Float16(bLin).bitPattern
                hdrHalfs[idx + 3] = Float16(1.0).bitPattern

                jpegBytes[idx + 0] = UInt8(min(255, max(0, Int((80.0 + 160.0 * fx).rounded()))))
                jpegBytes[idx + 1] = UInt8(min(255, max(0, Int((70.0 + 100.0 * 0.5 * (fx + fy)).rounded()))))
                jpegBytes[idx + 2] = UInt8(min(255, max(0, Int((40.0 + 190.0 * fy).rounded()))))
                jpegBytes[idx + 3] = 255
            }
        }
        let hdrData = hdrHalfs.withUnsafeBytes { Data($0) }
        let hdrDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        hdrDesc.storageMode = .shared
        hdrDesc.usage = [.shaderRead, .shaderWrite]
        let hdrTex = try #require(engine.device.makeTexture(descriptor: hdrDesc))
        hdrData.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                hdrTex.replace(
                    region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: w * 8
                )
            }
        }

        let devCS = CGColorSpaceCreateDeviceRGB()
        let jpegCtx = try #require(CGContext(
            data: &jpegBytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: devCS,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let jpegImg = try #require(jpegCtx.makeImage())
        let jpegOut = NSMutableData()
        let jpegDest = try #require(CGImageDestinationCreateWithData(jpegOut, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(jpegDest, jpegImg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        try #require(CGImageDestinationFinalize(jpegDest))
        let untaggedJPEG = jpegOut as Data

        let meta = GainMapMetadata(
            gainMapMin: [0.0],
            gainMapMax: [2.5],
            gamma: [1.0],
            baseOffset: [GainMapMetadata.symmetricOffset],
            altOffset: [GainMapMetadata.symmetricOffset],
            baseHeadroom: .sdr,
            alternateHeadroom: HeadroomStops(log2Value: 2.5),
            useBaseColorSpace: true
        )

        let resSRGB = try await engine.recomputeGainMapCompensated(
            hdrTexture: SendableMTLTexture(hdrTex),
            compressedSDRJPEGData: untaggedJPEG,
            metadata: meta,
            gamma: 1.0,
            channels: .mono1ch,
            resolution: .full,
            midtoneAnchorP: 0.92,
            baseColorSpace: .srgb
        )
        let resP3 = try await engine.recomputeGainMapCompensated(
            hdrTexture: SendableMTLTexture(hdrTex),
            compressedSDRJPEGData: untaggedJPEG,
            metadata: meta,
            gamma: 1.0,
            channels: .mono1ch,
            resolution: .full,
            midtoneAnchorP: 0.68,
            baseColorSpace: .displayP3
        )
        #expect(resSRGB.buffer.width == w && resSRGB.buffer.height == h)
        #expect(resSRGB.metadata.gainMapMax[0] >= resSRGB.metadata.gainMapMin[0])
        #expect(resP3.buffer.width == w && resP3.buffer.height == h)
        #expect(resSRGB.metadata.gainMapMax[0] != resP3.metadata.gainMapMax[0])
        #expect(resSRGB.buffer.data != resP3.buffer.data)
    }

    // MARK: - 5. P1 Gap 5: CLibAVIFBridge zero gain_map dim & GainMapSynthesizer 2x2 .half

    @Test("Gap 5: CLibAVIFBridge rejects 0-dim gain map & GainMapSynthesizer 2x2 half skips skew downsample")
    func testCLibAVIFZeroGainMapDimRejectedAndTiny2x2GainMapNoSkew() throws {
        // 1) CLibAVIFBridge non-null gain_map_pixels with 0x0 dimensions -> HDR_AVIF_ERR_INVALID_DIMENSIONS
        let basePixels = [UInt8](repeating: 128, count: 64 * 64 * 4)
        let gmDummy = [UInt8](repeating: 128, count: 16)
        var outBuf = HDRAVIFBuffer()
        var errBuf = [CChar](repeating: 0, count: 512)
        defer { hdr_libavif_free_buffer(&outBuf) }

        let status: HDRAVIFStatus = basePixels.withUnsafeBytes { bPtr in
            gmDummy.withUnsafeBytes { gPtr in
                var req = HDRAVIFEncodeRequest()
                req.base_pixels = bPtr.bindMemory(to: UInt8.self).baseAddress
                req.base_width = 64
                req.base_height = 64
                req.base_row_bytes = 64 * 4
                req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA8
                req.target_bit_depth = 8
                req.color_primaries = HDR_AVIF_PRIMARIES_DISPLAY_P3
                req.gain_map_pixels = gPtr.bindMemory(to: UInt8.self).baseAddress
                req.gain_map_width = 0
                req.gain_map_height = 0
                req.gain_map_row_bytes = 0
                req.gain_map_pixel_format = HDR_AVIF_PIXFMT_GRAY8
                req.gain_map_channels = 1
                req.codec = HDR_AVIF_CODEC_AOM
                req.quality = 80
                req.gain_map_quality = 80
                req.speed = 6
                req.max_threads = 2
                return hdr_avif_encode(&req, &outBuf, &errBuf, errBuf.count)
            }
        }
        #expect(status == HDR_AVIF_ERR_INVALID_DIMENSIONS)

        // 2) GainMapSynthesizer 2x2 .half vs .full with uniform pixels produces identical bytes
        let engine = try MetalPipelineEngine()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 2,
            height: 2,
            mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        let sdrTex = try #require(engine.device.makeTexture(descriptor: desc))
        let hdrTex = try #require(engine.device.makeTexture(descriptor: desc))
        let sdrData = makeT5Float16Data(width: 2, height: 2, rgba: SIMD4<Float>(0.5, 0.5, 0.5, 1.0))
        let hdrData = makeT5Float16Data(width: 2, height: 2, rgba: SIMD4<Float>(2.0, 2.0, 2.0, 1.0))
        sdrData.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                sdrTex.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: base, bytesPerRow: 16)
            }
        }
        hdrData.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                hdrTex.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: base, bytesPerRow: 16)
            }
        }

        let resHalf = try engine.gainMapSynthesizer.synthesize(
            commandQueue: engine.commandQueue,
            sdrLinearTexture: SendableMTLTexture(sdrTex),
            hdrLinearTexture: SendableMTLTexture(hdrTex),
            baseColorSpace: .displayP3,
            targetHeadroom: HeadroomStops(log2Value: 2.5),
            midtoneAnchorP: 0.80,
            gamma: 1.0,
            channels: .mono1ch,
            resolution: .half,
            lockLegacyBounds: false,
            enableDither: false
        )
        let resFull = try engine.gainMapSynthesizer.synthesize(
            commandQueue: engine.commandQueue,
            sdrLinearTexture: SendableMTLTexture(sdrTex),
            hdrLinearTexture: SendableMTLTexture(hdrTex),
            baseColorSpace: .displayP3,
            targetHeadroom: HeadroomStops(log2Value: 2.5),
            midtoneAnchorP: 0.80,
            gamma: 1.0,
            channels: .mono1ch,
            resolution: .full,
            lockLegacyBounds: false,
            enableDither: false
        )
        #expect(resHalf.buffer.width == 2 && resHalf.buffer.height == 2)
        #expect(resHalf.buffer.data == resFull.buffer.data)
    }

    // MARK: - 6. P2 Gap 2: Duplicate stems across --recursive subdirs under overwrite/skip/autoNumber

    @Test("Gap 2 (P2): Recursive duplicate stems handle overwrite collision safely without data loss or .tmp leaks", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testRecursiveDuplicateStemsConflictHandling() async throws {
        let srcA = t5TangmoDir.appendingPathComponent("DSC02532.ARW")
        let srcB = t5TangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: srcA.path))
        try #require(FileManager.default.fileExists(atPath: srcB.path))

        let tmpRoot = try makeT5TempDir(prefix: "t5_dup_stems")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let subA = tmpRoot.appendingPathComponent("in/subA", isDirectory: true)
        let subB = tmpRoot.appendingPathComponent("in/subB", isDirectory: true)
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        let arwA = subA.appendingPathComponent("SHARED.ARW")
        let arwB = subB.appendingPathComponent("SHARED.ARW")
        try FileManager.default.createSymbolicLink(at: arwA, withDestinationURL: srcA)
        try FileManager.default.createSymbolicLink(at: arwB, withDestinationURL: srcB)

        var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        preset.maxLongEdge = 512

        let pipeline = BoundedBatchPipeline()

        // 1. .skip
        let outSkip = tmpRoot.appendingPathComponent("out_skip", isDirectory: true)
        let skipJobs = [arwA, arwB].map {
            ExportJob(inputURL: $0, outputDirectory: outSkip, preset: preset, conflictPolicy: .skip, verifyAfterExport: true)
        }
        let skipRes = try await pipeline.run(jobs: skipJobs)
        #expect(skipRes.count == 2)
        #expect(skipRes.allSatisfy { $0.errorDescription == nil })
        let skipFiles = try FileManager.default.contentsOfDirectory(at: outSkip, includingPropertiesForKeys: nil)
        #expect(skipFiles.count == 1)
        #expect(!(try hasT5LeftoverTmpFiles(in: outSkip)))

        // 2. .autoNumber
        let outAuto = tmpRoot.appendingPathComponent("out_auto", isDirectory: true)
        let autoJobs = [arwA, arwB].map {
            ExportJob(inputURL: $0, outputDirectory: outAuto, preset: preset, conflictPolicy: .autoNumber, verifyAfterExport: true)
        }
        let autoRes = try await pipeline.run(jobs: autoJobs)
        #expect(autoRes.count == 2)
        #expect(autoRes.allSatisfy { $0.errorDescription == nil })
        let autoFiles = try FileManager.default.contentsOfDirectory(at: outAuto, includingPropertiesForKeys: nil)
        #expect(autoFiles.count == 2)
        #expect(!(try hasT5LeftoverTmpFiles(in: outAuto)))

        // 3. .overwrite on duplicate intra-batch stems: 1 succeeds, 1 rejects intraBatchPathCollision cleanly
        let outOvr = tmpRoot.appendingPathComponent("out_ovr", isDirectory: true)
        let ovrJobs = [arwA, arwB].map {
            ExportJob(inputURL: $0, outputDirectory: outOvr, preset: preset, conflictPolicy: .overwrite, verifyAfterExport: true)
        }
        let ovrRes = try await pipeline.run(jobs: ovrJobs)
        let succeeded = ovrRes.filter { $0.errorDescription == nil }
        let failed = ovrRes.filter { $0.errorDescription != nil }
        #expect(succeeded.count == 1)
        #expect(failed.count == 1)
        #expect(failed.first?.errorDescription?.contains("Intra-batch output path collision") == true)
        let ovrFile = outOvr.appendingPathComponent("SHARED_HDR.heic")
        #expect(FileManager.default.fileExists(atPath: ovrFile.path))
        #expect(!(try hasT5LeftoverTmpFiles(in: outOvr)))

        // 4. Single-job .overwrite against pre-existing file on disk still overwrites normally
        try Data("SENTINEL".utf8).write(to: ovrFile)
        let singleOvrJob = ExportJob(inputURL: arwA, outputDirectory: outOvr, preset: preset, conflictPolicy: .overwrite, verifyAfterExport: true)
        let singleOvrRes = try await pipeline.run(jobs: [singleOvrJob])
        #expect(singleOvrRes.count == 1)
        #expect(singleOvrRes[0].errorDescription == nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: ovrFile.path)
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(fileSize > 1000)
    }

    @Test("Remaining Gap 1 (P2): Recursive case-insensitive duplicate stems (SHARED.ARW vs shared.arw) handled safely on APFS", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testRecursiveCaseInsensitiveDuplicateStemsConflictHandling() async throws {
        let srcA = t5TangmoDir.appendingPathComponent("DSC02532.ARW")
        let srcB = t5TangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: srcA.path))
        try #require(FileManager.default.fileExists(atPath: srcB.path))

        let tmpRoot = try makeT5TempDir(prefix: "t5_case_dup_stems")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let subA = tmpRoot.appendingPathComponent("in/subA", isDirectory: true)
        let subB = tmpRoot.appendingPathComponent("in/subB", isDirectory: true)
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)

        // Distinct real copied files (non-symlinks) with case-differing stems
        let arwUpper = subA.appendingPathComponent("SHARED.ARW")
        let arwLower = subB.appendingPathComponent("shared.arw")
        try FileManager.default.copyItem(at: srcA, to: arwUpper)
        try FileManager.default.copyItem(at: srcB, to: arwLower)

        var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        preset.maxLongEdge = 512

        let pipeline = BoundedBatchPipeline()

        // 1. .overwrite: 1 succeeds, 1 fails with intraBatchPathCollision, 1 file on disk, zero .tmp leaks
        let outOvr = tmpRoot.appendingPathComponent("out_ovr", isDirectory: true)
        let ovrJobs = [arwUpper, arwLower].map {
            ExportJob(inputURL: $0, outputDirectory: outOvr, preset: preset, conflictPolicy: .overwrite, verifyAfterExport: true)
        }
        let ovrRes = try await pipeline.run(jobs: ovrJobs)
        let ovrSucceeded = ovrRes.filter { $0.errorDescription == nil }
        let ovrFailed = ovrRes.filter { $0.errorDescription != nil }
        #expect(ovrSucceeded.count == 1)
        #expect(ovrFailed.count == 1)
        #expect(ovrFailed.first?.errorDescription?.contains("Intra-batch output path collision") == true)
        let ovrFiles = try FileManager.default.contentsOfDirectory(at: outOvr, includingPropertiesForKeys: nil)
        #expect(ovrFiles.count == 1)
        #expect(!(try hasT5LeftoverTmpFiles(in: outOvr)))

        // 2. .autoNumber: 2 succeed and 2 distinct files remain on disk (even on case-insensitive APFS)
        let outAuto = tmpRoot.appendingPathComponent("out_auto", isDirectory: true)
        let autoJobs = [arwUpper, arwLower].map {
            ExportJob(inputURL: $0, outputDirectory: outAuto, preset: preset, conflictPolicy: .autoNumber, verifyAfterExport: true)
        }
        let autoRes = try await pipeline.run(jobs: autoJobs)
        #expect(autoRes.count == 2)
        #expect(autoRes.allSatisfy { $0.errorDescription == nil })
        let autoFiles = try FileManager.default.contentsOfDirectory(at: outAuto, includingPropertiesForKeys: nil)
        #expect(autoFiles.count == 2)
        #expect(!(try hasT5LeftoverTmpFiles(in: outAuto)))

        // 3. .skip: 2 succeed (second job has empty artifacts) and 1 file remains on disk
        let outSkip = tmpRoot.appendingPathComponent("out_skip", isDirectory: true)
        let skipJobs = [arwUpper, arwLower].map {
            ExportJob(inputURL: $0, outputDirectory: outSkip, preset: preset, conflictPolicy: .skip, verifyAfterExport: true)
        }
        let skipRes = try await pipeline.run(jobs: skipJobs)
        #expect(skipRes.count == 2)
        #expect(skipRes.allSatisfy { $0.errorDescription == nil })
        let nonEmptyArtifacts = skipRes.filter { !$0.artifacts.isEmpty }
        let emptyArtifacts = skipRes.filter { $0.artifacts.isEmpty }
        #expect(nonEmptyArtifacts.count == 1)
        #expect(emptyArtifacts.count == 1)
        let skipFiles = try FileManager.default.contentsOfDirectory(at: outSkip, includingPropertiesForKeys: nil)
        #expect(skipFiles.count == 1)
        #expect(!(try hasT5LeftoverTmpFiles(in: outSkip)))
    }

    // MARK: - 7. P2 Gap 3 & Gap 4: AppViewModel delta clearing, queue guards, baseColorSpace & 3ch alert

    @Test("Gap 3 & 4 (P2): AppViewModel clears preset maxLongEdge via delta, guards export queue, syncs baseColorSpace & alerts on 3ch JPEG+XMP")
    @MainActor
    func testAppViewModelPerPhotoDeltaMaxLongEdgeAndExportGuards() throws {
        let vm = AppViewModel()
        let xhs = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
        vm.selectPreset(xhs)

        let fakeA = URL(fileURLWithPath: "/tmp/t5_vm_a.arw")
        let fakeB = URL(fileURLWithPath: "/tmp/t5_vm_b.arw")
        vm.items = [BatchItem(sourceURL: fakeA), BatchItem(sourceURL: fakeB)]
        vm.selectedItemID = vm.items[0].id

        // P2 Gap 3: Clearing preset maxLongEdge (2048) via per-photo delta
        vm.editScope = .perPhotoDelta
        #expect(vm.selectedEffectiveParams.maxLongEdge == 2048)
        vm.updateMaxLongEdge(nil)
        #expect(vm.selectedEffectiveParams.maxLongEdge == nil)
        #expect(vm.perPhotoDeltas[fakeA]?.clearMaxLongEdgeOverride == true)

        // Setting back to preset's 2048 removes redundant override
        vm.updateMaxLongEdge(2048)
        #expect(vm.selectedEffectiveParams.maxLongEdge == 2048)
        #expect(vm.perPhotoDeltas[fakeA] == nil)

        // Backward-compatible JSON decode without clearMaxLongEdgeOverride
        let oldJSON = Data(#"{"exposureEVDelta":0.5,"maxLongEdgeOverride":1024}"#.utf8)
        let decodedOld = try JSONDecoder().decode(PerPhotoDelta.self, from: oldJSON)
        #expect(decodedOld.clearMaxLongEdgeOverride == false)
        #expect(decodedOld.maxLongEdgeOverride == 1024)

        // P2 Gap 4a: Queue mutations blocked while isExporting == true
        vm.isExporting = true
        vm.removeItem(vm.items[0])
        #expect(vm.items.count == 2)
        vm.clearQueue()
        #expect(vm.items.count == 2)
        vm.isExporting = false

        // P2 Gap 4b: baseColorSpace sync
        vm.setBaseColorSpace(.srgb)
        #expect(vm.activePreset.baseColorSpace == .srgb)

        // P2 Gap 4c: 3ch selection on JPEG+XMP surfaces alertMessage instead of silent snap-back
        #expect(vm.isRGB3chGainMapRestricted == true)
        vm.alertMessage = nil
        vm.setGainMapChannels(.rgb3ch)
        #expect(vm.activePreset.gainMapChannels == .mono1ch)
        #expect(vm.alertMessage != nil)

        // Now queue mutations succeed when not exporting
        vm.removeItem(vm.items[0])
        #expect(vm.items.count == 1)
        vm.clearQueue()
        #expect(vm.items.isEmpty)
    }

    // MARK: - 8. P2 Gap 5: ISO21496Probe rejects unexpected legacy HDRGainMap on 1ch HEIC

    @Test("Gap 5 (P2): ISO21496Probe rejects unexpected legacy HDRGainMap on 1ch HEIC")
    func testISO21496ProbeRejectsUnexpectedLegacyGainMapOn1chHEIC() async throws {
        let tmpDir = try makeT5TempDir(prefix: "t5_1ch_legacy_probe")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var compatPreset = try PresetLoader.loadBuiltIn(id: .appleHEICCompat)
        compatPreset.compatOptions.writeLegacyAppleHDRGainMap = true
        let frame = try makeT5RenderedFrame(
            width: 128,
            height: 128,
            bitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .mono1ch,
            gainMapResolution: .half
        )
        let heicURL = tmpDir.appendingPathComponent("compat_1ch.heic")
        _ = try await HEICImageIOEncoder().encode(frame: frame, preset: compatPreset, to: heicURL)

        let probe = ISO21496Probe()
        let reportUnexpected = try await probe.verify(
            url: heicURL,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: HeadroomStops(log2Value: 2.5).toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .mono1ch,
                expectLegacyAppleGainMap: false
            )
        )
        #expect(!reportUnexpected.passed)
        #expect(reportUnexpected.checks.contains { $0.name == "legacy_apple_gain_map" && $0.severity == .fail })
    }

    // MARK: - 9. P2 Gap 6: HLGVideoEncoder maxLongEdge override consistency

    @Test("Gap 6 (P2): BoundedBatchPipeline rejects >1920px HLG MP4 upfront consistently across preset and delta", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testHLGVideoEncoderMaxLongEdgeOverrideConsistency() async throws {
        let src = t5TangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: src.path))

        let tmpDir = try makeT5TempDir(prefix: "t5_hlg_max_edge")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pipeline = BoundedBatchPipeline()

        // Case 1: xiaohongshu_jpg (maxLongEdge = 2048) overridden to [.hlgMP4]
        let xhsPreset = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
        let job1 = ExportJob(
            inputURL: src,
            outputDirectory: tmpDir.appendingPathComponent("case1", isDirectory: true),
            preset: xhsPreset,
            formatOverrides: [.hlgMP4]
        )
        let res1 = try await pipeline.run(jobs: [job1])
        #expect(res1.count == 1)
        #expect(res1[0].errorDescription?.contains("2048") == true)
        #expect(res1[0].artifacts.isEmpty)

        // Case 2: apple_heic (maxLongEdge = nil) + delta.maxLongEdgeOverride = 3840 overridden to [.hlgMP4]
        let heicPreset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let job2 = ExportJob(
            inputURL: src,
            outputDirectory: tmpDir.appendingPathComponent("case2", isDirectory: true),
            preset: heicPreset,
            formatOverrides: [.hlgMP4],
            delta: PerPhotoDelta(maxLongEdgeOverride: 3840)
        )
        let res2 = try await pipeline.run(jobs: [job2])
        #expect(res2.count == 1)
        #expect(res2[0].errorDescription?.contains("3840") == true)
        #expect(res2[0].artifacts.isEmpty)
    }

    // MARK: - 10. P2 Gap 7: JPEGDualEncoder quality schedule strictly decreasing

    @Test("Gap 7 (P2): JPEGDualEncoder.buildQualitySchedule is strictly decreasing across initial qualities")
    func testJPEGDualEncoderQualityScheduleStrictlyDecreasing() {
        for initialQ in [0.95, 0.90, 0.80, 0.70, 0.50, 0.25, 0.10] {
            let schedule = JPEGDualEncoder.buildQualitySchedule(
                initialBaseQ: initialQ,
                initialGMQ: 0.85,
                hasSizeBudget: true
            )
            #expect(!schedule.isEmpty)
            for idx in 1..<schedule.count {
                #expect(
                    schedule[idx].0 < schedule[idx - 1].0,
                    "Schedule not strictly decreasing for initialQ=\(initialQ): \(schedule)"
                )
            }
        }
    }

    // MARK: - 11. P1 Gap 6: LibRawDecoder.decodeBuffer & CLibRawBridge option branches

    @Test("Gap 6 (P1): LibRawDecoder.decodeBuffer and CLibRawBridge option branches", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testLibRawDecoderBufferAndBridgeOptionBranches() async throws {
        let arwURL = t5TangmoDir.appendingPathComponent("DSC02533.ARW")
        try #require(FileManager.default.fileExists(atPath: arwURL.path))
        let arwData = try Data(contentsOf: arwURL)

        let decoder = LibRawDecoder()
        let fullFrame = try await decoder.decodeBuffer(arwData, sourceURL: arwURL, options: .default)
        #expect(fullFrame.visibleCrop.width == 7008)
        #expect(fullFrame.visibleCrop.height == 4672)
        #expect(fullFrame.exif.orientation == 1)

        var proxyOpts = DecodeOptions.default
        proxyOpts.isProxy = true
        let proxyFrame = try await decoder.decodeBuffer(arwData, sourceURL: arwURL, options: proxyOpts)
        #expect(proxyFrame.visibleCrop.width == 3504)
        #expect(proxyFrame.visibleCrop.height == 2336)

        await #expect(throws: RAWDecodeError.self) {
            _ = try await decoder.decodeBuffer(Data(), sourceURL: arwURL, options: .default)
        }

        // CLibRawBridge highlight_mode 0/2/5, apply_inset_crop = 0, PROXY_RGB16 buffer, empty path, ERR_UNPACK
        for hMode: Int32 in [0, 2, 5] {
            var opts = hdr_libraw_default_options()
            opts.highlight_mode = hMode
            var img = HDRLibRawImage()
            defer { hdr_libraw_free_image(&img) }
            let st = hdr_libraw_decode_file(arwURL.path, &opts, &img)
            #expect(st == HDR_LIBRAW_OK)
            #expect(img.width == 7008 && img.height == 4672)
        }

        do {
            var opts = hdr_libraw_default_options()
            opts.apply_inset_crop = 0
            var img = HDRLibRawImage()
            defer { hdr_libraw_free_image(&img) }
            let st = hdr_libraw_decode_file(arwURL.path, &opts, &img)
            #expect(st == HDR_LIBRAW_OK)
            #expect(img.width == 7028 && img.height == 4688)
        }

        do {
            var opts = hdr_libraw_default_options()
            opts.mode = HDR_LIBRAW_MODE_PROXY_RGB16
            opts.output_color_space = HDR_LIBRAW_CS_CAMERA_NATIVE
            var img = HDRLibRawImage()
            defer { hdr_libraw_free_image(&img) }
            let st = arwData.withUnsafeBytes { ptr in
                hdr_libraw_decode_buffer(ptr.baseAddress, ptr.count, &opts, &img)
            }
            #expect(st == HDR_LIBRAW_OK)
            #expect(img.payload_kind == HDR_LIBRAW_PAYLOAD_RGB16U)
            #expect(img.width == 3504 && img.height == 2336)
        }

        do {
            var opts = hdr_libraw_default_options()
            var img = HDRLibRawImage()
            defer { hdr_libraw_free_image(&img) }
            #expect(hdr_libraw_decode_file("", &opts, &img) == HDR_LIBRAW_ERR_INVALID_ARG)
        }

        // Valid TIFF/DNG header with missing strip payload triggers HDR_LIBRAW_ERR_UNPACK or ERR_OPEN
        var badTIFF = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        badTIFF.append(Data(repeating: 0, count: 64))
        do {
            var opts = hdr_libraw_default_options()
            var img = HDRLibRawImage()
            defer { hdr_libraw_free_image(&img) }
            let st = badTIFF.withUnsafeBytes { ptr in
                hdr_libraw_decode_buffer(ptr.baseAddress, ptr.count, &opts, &img)
            }
            #expect(st != HDR_LIBRAW_OK)
        }
    }

    // MARK: - 12. P1 Gap 7: CUltraHDRBridge metadata/EXIF validation & decode edge cases

    @Test("Gap 7 (P1): CUltraHDRBridge metadata validation, EXIF limits, BE EXIF, probe & decode edge cases")
    func testCUltraHDRBridgeMetadataExifAndDecodeEdgeCases() throws {
        let baseJPEG = try makeT5JPEG(width: 64, height: 64, colorSpace: CGColorSpace.displayP3, rgb: (180, 120, 90))
        let gmJPEG = try makeT5JPEG(width: 32, height: 32, colorSpace: CGColorSpace.genericGrayGamma2_2, rgb: (128, 128, 128))

        func defaultMeta() -> HDRUltraHDRGainMapMetadata {
            var m = HDRUltraHDRGainMapMetadata()
            m.max_content_boost = (4.0, 4.0, 4.0)
            m.min_content_boost = (1.0, 1.0, 1.0)
            m.gamma = (1.0, 1.0, 1.0)
            m.offset_sdr = (0.015625, 0.015625, 0.015625)
            m.offset_hdr = (0.015625, 0.015625, 0.015625)
            m.hdr_capacity_min = 1.0
            m.hdr_capacity_max = 4.0
            m.use_base_cg = 1
            return m
        }

        func runEncode(_ meta: HDRUltraHDRGainMapMetadata, exif: Data? = nil) -> Int32 {
            var outBuf = HDRUltraHDRBuffer()
            var errPtr: UnsafeMutablePointer<CChar>? = nil
            defer {
                hdr_ultrahdr_free_buffer(&outBuf)
                if let errPtr { cuhdr_free_error(errPtr) }
            }
            return baseJPEG.withUnsafeBytes { bPtr in
                gmJPEG.withUnsafeBytes { gPtr in
                    let callWithExif: (UnsafePointer<UInt8>?, Int) -> Int32 = { eBase, eCount in
                        var inp = HDRUltraHDREncodeInput()
                        inp.base_jpeg_data = bPtr.bindMemory(to: UInt8.self).baseAddress
                        inp.base_jpeg_size = bPtr.count
                        inp.base_color_gamut = HDR_UHDR_CG_DISPLAY_P3
                        inp.gainmap_jpeg_data = gPtr.bindMemory(to: UInt8.self).baseAddress
                        inp.gainmap_jpeg_size = gPtr.count
                        inp.exif_data = eBase
                        inp.exif_size = eCount
                        inp.metadata = meta
                        return cuhdr_encode_api4(&inp, &outBuf, &errPtr)
                    }
                    if let exif {
                        return exif.withUnsafeBytes { ePtr in
                            callWithExif(ePtr.bindMemory(to: UInt8.self).baseAddress, ePtr.count)
                        }
                    } else {
                        return callWithExif(nil, 0)
                    }
                }
            }
        }

        // Invalid boosts, gamma <= 0, capacity < 1.0
        var mBadBoost = defaultMeta()
        mBadBoost.min_content_boost = (4.0, 4.0, 4.0)
        mBadBoost.max_content_boost = (2.0, 2.0, 2.0)
        #expect(runEncode(mBadBoost) != 0)

        var mBadGamma = defaultMeta()
        mBadGamma.gamma = (0.0, 0.0, 0.0)
        #expect(runEncode(mBadGamma) != 0)

        var mBadCap = defaultMeta()
        mBadCap.hdr_capacity_min = 0.5
        #expect(runEncode(mBadCap) != 0)

        // Invalid EXIF header & > 65533-byte EXIF rejected
        #expect(runEncode(defaultMeta(), exif: Data("BAD!".utf8)) != 0)
        #expect(runEncode(defaultMeta(), exif: Data(repeating: 0x41, count: 65540)) != 0)

        // Big-endian MM\0* EXIF splicing succeeds, probe extract_payloads=0 & decode RGBA_8888_SRGB succeed
        let beExif = makeT5LittleEndianExifTIFF(orientation: 1, bigEndian: true)
        var outUHDR = HDRUltraHDRBuffer()
        var errPtr: UnsafeMutablePointer<CChar>? = nil
        defer {
            hdr_ultrahdr_free_buffer(&outUHDR)
            if let errPtr { cuhdr_free_error(errPtr) }
        }
        let encRC: Int32 = baseJPEG.withUnsafeBytes { bPtr in
            gmJPEG.withUnsafeBytes { gPtr in
                beExif.withUnsafeBytes { ePtr in
                    var inp = HDRUltraHDREncodeInput()
                    inp.base_jpeg_data = bPtr.bindMemory(to: UInt8.self).baseAddress
                    inp.base_jpeg_size = bPtr.count
                    inp.base_color_gamut = HDR_UHDR_CG_DISPLAY_P3
                    inp.gainmap_jpeg_data = gPtr.bindMemory(to: UInt8.self).baseAddress
                    inp.gainmap_jpeg_size = gPtr.count
                    inp.exif_data = ePtr.bindMemory(to: UInt8.self).baseAddress
                    inp.exif_size = ePtr.count
                    inp.metadata = defaultMeta()
                    return cuhdr_encode_api4(&inp, &outUHDR, &errPtr)
                }
            }
        }
        #expect(encRC == 0)

        var probeRes = HDRUltraHDRProbeResult()
        var probeErr: UnsafeMutablePointer<CChar>? = nil
        defer {
            cuhdr_free_probe_result(&probeRes)
            if let probeErr { cuhdr_free_error(probeErr) }
        }
        let probeRC = cuhdr_probe(outUHDR.data, outUHDR.size, 0, &probeRes, &probeErr)
        #expect(probeRC == 0)
        #expect(probeRes.is_valid == 1)
        #expect(probeRes.base_jpeg_size > 0)
        #expect(probeRes.base_jpeg.data == nil)
        #expect(probeRes.exif_size > 0)

        var decImg = HDRUltraHDRDecodedImage()
        var decErr: UnsafeMutablePointer<CChar>? = nil
        defer {
            cuhdr_free_decoded_image(&decImg)
            if let decErr { cuhdr_free_error(decErr) }
        }
        let decRC = cuhdr_decode(outUHDR.data, outUHDR.size, HDR_UHDR_DECODE_RGBA_8888_SRGB, 0.0, &decImg, &decErr)
        #expect(decRC == 0)
        #expect(decImg.width == 64 && decImg.height == 64)
        #expect(decImg.pixels.size == 64 * 64 * 4)

        // Plain non-UltraHDR JPEG decode rejection
        var plainImg = HDRUltraHDRDecodedImage()
        var plainErr: UnsafeMutablePointer<CChar>? = nil
        defer {
            cuhdr_free_decoded_image(&plainImg)
            if let plainErr { cuhdr_free_error(plainErr) }
        }
        let plainRC = baseJPEG.withUnsafeBytes { ptr in
            cuhdr_decode(ptr.bindMemory(to: UInt8.self).baseAddress, ptr.count, HDR_UHDR_DECODE_RGBA_8888_SRGB, 0.0, &plainImg, &plainErr)
        }
        #expect(plainRC != 0)
    }

    // MARK: - 13. P1 Gap 8: CLibAVIFBridge pixel formats, primaries, 8-bit, SDR-only, odd dims & grid errors

    @Test("Gap 8 (P1): CLibAVIFBridge RGBA10_U16, BGRA16, BT709_SRGB, 8-bit, SDR-only, odd 101x101 & grid plan errors")
    func testCLibAVIFPixelFormatsSDROnlyOddDimsAndGridErrors() throws {
        func defaultAVIFMeta() -> HDRAVIFGainMapMetadata {
            var m = HDRAVIFGainMapMetadata()
            m.gain_map_min = (0.0, 0.0, 0.0)
            m.gain_map_max = (2.5, 2.5, 2.5)
            m.gain_map_gamma = (1.0, 1.0, 1.0)
            m.base_offset = (0.015625, 0.015625, 0.015625)
            m.alternate_offset = (0.015625, 0.015625, 0.015625)
            m.base_hdr_headroom_stops = 0.0
            m.alternate_hdr_headroom_stops = 2.5
            m.use_base_color_space = 1
            return m
        }

        // Grid planner error cases
        var plan = HDRAVIFGridPlan()
        var err = [CChar](repeating: 0, count: 256)
        #expect(hdr_avif_plan_grid(64, 64, 32, 32, 2, &plan, &err, err.count) == HDR_AVIF_ERR_INVALID_ARGUMENT)
        #expect(hdr_avif_plan_grid(0, 64, 0, 0, 0, &plan, &err, err.count) == HDR_AVIF_ERR_INVALID_DIMENSIONS)
        #expect(hdr_avif_plan_grid(64, 64, 21, 21, 1, &plan, &err, err.count) == HDR_AVIF_ERR_INVALID_DIMENSIONS)
        #expect(hdr_avif_plan_grid(4098, 2001, 2049, 1000, 1, &plan, &err, err.count) == HDR_AVIF_ERR_INVALID_DIMENSIONS)

        // 1) RGBA10_U16 + BT709_SRGB + 10-bit + SDR-only (no gain map)
        do {
            let pixels10 = [UInt16](repeating: 512, count: 64 * 64 * 4)
            var out = HDRAVIFBuffer()
            defer { hdr_libavif_free_buffer(&out) }
            let st: HDRAVIFStatus = pixels10.withUnsafeBytes { pPtr in
                var req = HDRAVIFEncodeRequest()
                req.base_pixels = pPtr.bindMemory(to: UInt8.self).baseAddress
                req.base_width = 64
                req.base_height = 64
                req.base_row_bytes = 64 * 8
                req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA10_U16
                req.target_bit_depth = 10
                req.color_primaries = HDR_AVIF_PRIMARIES_BT709_SRGB
                req.gain_map_pixels = nil
                req.codec = HDR_AVIF_CODEC_AOM
                req.quality = 80
                req.speed = 6
                req.max_threads = 2
                return hdr_avif_encode(&req, &out, &err, err.count)
            }
            #expect(st == HDR_AVIF_OK)
            #expect(out.size > 0)
        }

        // 2) BGRA16 + 8-bit + BT709_SRGB + 1ch GM
        do {
            let pixels16 = [UInt16](repeating: 32768, count: 64 * 64 * 4)
            let gm8 = [UInt8](repeating: 128, count: 32 * 32)
            var out = HDRAVIFBuffer()
            defer { hdr_libavif_free_buffer(&out) }
            let st: HDRAVIFStatus = pixels16.withUnsafeBytes { pPtr in
                gm8.withUnsafeBytes { gPtr in
                    var req = HDRAVIFEncodeRequest()
                    req.base_pixels = pPtr.bindMemory(to: UInt8.self).baseAddress
                    req.base_width = 64
                    req.base_height = 64
                    req.base_row_bytes = 64 * 8
                    req.base_pixel_format = HDR_AVIF_PIXFMT_BGRA16
                    req.target_bit_depth = 8
                    req.color_primaries = HDR_AVIF_PRIMARIES_BT709_SRGB
                    req.gain_map_pixels = gPtr.bindMemory(to: UInt8.self).baseAddress
                    req.gain_map_width = 32
                    req.gain_map_height = 32
                    req.gain_map_row_bytes = 32
                    req.gain_map_pixel_format = HDR_AVIF_PIXFMT_GRAY8
                    req.gain_map_channels = 1
                    req.gain_map_meta = defaultAVIFMeta()
                    req.codec = HDR_AVIF_CODEC_AOM
                    req.quality = 80
                    req.gain_map_quality = 80
                    req.speed = 6
                    req.max_threads = 2
                    return hdr_avif_encode(&req, &out, &err, err.count)
                }
            }
            #expect(st == HDR_AVIF_OK)
            #expect(out.size > 0)
        }

        // 3) Odd 101x101 with 3ch GM on both SVT-AV1 and libaom
        for codec in [HDR_AVIF_CODEC_SVT, HDR_AVIF_CODEC_AOM] {
            let pixels8 = [UInt8](repeating: 140, count: 101 * 101 * 4)
            let gm8 = [UInt8](repeating: 120, count: 101 * 101 * 4)
            var out = HDRAVIFBuffer()
            defer { hdr_libavif_free_buffer(&out) }
            let st: HDRAVIFStatus = pixels8.withUnsafeBytes { pPtr in
                gm8.withUnsafeBytes { gPtr in
                    var req = HDRAVIFEncodeRequest()
                    req.base_pixels = pPtr.bindMemory(to: UInt8.self).baseAddress
                    req.base_width = 101
                    req.base_height = 101
                    req.base_row_bytes = 101 * 4
                    req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA8
                    req.target_bit_depth = 10
                    req.color_primaries = HDR_AVIF_PRIMARIES_DISPLAY_P3
                    req.gain_map_pixels = gPtr.bindMemory(to: UInt8.self).baseAddress
                    req.gain_map_width = 101
                    req.gain_map_height = 101
                    req.gain_map_row_bytes = 101 * 4
                    req.gain_map_pixel_format = HDR_AVIF_PIXFMT_BGRA8
                    req.gain_map_channels = 3
                    req.gain_map_meta = defaultAVIFMeta()
                    req.codec = codec
                    req.quality = 80
                    req.gain_map_quality = 80
                    req.speed = 6
                    req.max_threads = 2
                    return hdr_avif_encode(&req, &out, &err, err.count)
                }
            }
            #expect(st == HDR_AVIF_OK)
            let data = Data(bytes: try #require(out.data), count: out.size)
            let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            #expect((props?[kCGImagePropertyPixelWidth] as? Int) == 101)
            #expect((props?[kCGImagePropertyPixelHeight] as? Int) == 101)
        }
    }

    // MARK: - 14. P1 Gap 9: PresetLoader errors, CubeLUTError, MM dual DCP & isLosslessMS render

    @Test("Gap 9 (P1): PresetValidationError variants, CubeLUTError cases, MM dual DCP & isLosslessMS render")
    func testPresetValidationRemainingErrorsCubeLUTErrorsMMDualDCPAndLosslessMS() async throws {
        let base = try PresetLoader.loadBuiltIn(id: .appleHEIC)

        var badHeadroom = base; badHeadroom.targetHeadroomStops = 5.0
        #expect(throws: PresetValidationError.targetHeadroomOutOfBounds(5.0)) { try PresetLoader.validate(badHeadroom) }

        var badGamma = base; badGamma.gainMapGamma = 0.1
        #expect(throws: PresetValidationError.gainMapGammaOutOfBounds(0.1)) { try PresetLoader.validate(badGamma) }

        var badGMQ = base; badGMQ.gainMapQuality = 1.5
        #expect(throws: PresetValidationError.gainMapQualityOutOfBounds(1.5)) { try PresetLoader.validate(badGMQ) }

        var badEdge = base; badEdge.maxLongEdge = 63
        #expect(throws: PresetValidationError.invalidMaxLongEdge(63)) { try PresetLoader.validate(badEdge) }

        var badBytes = base; badBytes.targetMaxFileBytes = 0
        #expect(throws: PresetValidationError.invalidTargetMaxFileBytes(0)) { try PresetLoader.validate(badBytes) }

        var badHLG = base; badHLG.outputFormats = [.hlgMP4]; badHLG.hlgVideoOptions = nil
        #expect(throws: PresetValidationError.hlgVideoRequiresOptions) { try PresetLoader.validate(badHLG) }

        #expect(throws: PresetValidationError.builtInPresetNotFound("nonexistent_preset_id")) {
            _ = try PresetLoader.loadBuiltIn(id: "nonexistent_preset_id")
        }

        let tmpDir = try makeT5TempDir(prefix: "t5_preset_lut")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let badPresetFile = tmpDir.appendingPathComponent("malformed.json")
        try Data("{not valid json".utf8).write(to: badPresetFile)
        #expect(throws: DecodingError.self) {
            _ = try PresetLoader.load(from: badPresetFile)
        }

        // All 5 CubeLUTError cases
        #expect(throws: CubeLUTError.self) {
            _ = try CubeLUT(contentsOf: tmpDir.appendingPathComponent("missing.cube"))
        }
        #expect(throws: CubeLUTError.self) {
            _ = try CubeLUT(parsing: "0.0 0.0 0.0\n")
        }
        #expect(throws: CubeLUTError.self) {
            _ = try CubeLUT(parsing: "LUT_3D_SIZE 256\n")
        }
        #expect(throws: CubeLUTError.self) {
            _ = try CubeLUT(parsing: "LUT_1D_SIZE 2\n0.0 0.0 0.0\n")
        }
        #expect(throws: CubeLUTError.self) {
            _ = try CubeLUT(parsing: "LUT_1D_SIZE 2\n0.0 abc 0.0\n1.0 1.0 1.0\n")
        }

        // Big-endian 'MM' dual-illuminant DCPProfile + HDR V=4.0 + isLosslessMS: true render
        let dcpData = makeT5BigEndianDualIlluminantDCPData()
        let dcpURL = tmpDir.appendingPathComponent("be_dual.dcp")
        try dcpData.write(to: dcpURL)
        let dcp = try DCPProfile(contentsOf: dcpURL)
        #expect(abs(dcp.illuminant1Kelvin - 2856.0) < 50.0)
        #expect(dcp.illuminant2Kelvin == 6500.0)
        let interp = try #require(dcp.interpolatedHueSatTable(sceneKelvin: 4000.0))
        let midSat = interp.rgbaFloats[1]
        #expect(midSat > 1.05 && midSat < 1.15)

        let engine = try MetalPipelineEngine()
        let w = 16
        let h = 16
        var u16Bytes = [UInt16](repeating: 0, count: w * h * 3)
        for i in stride(from: 0, to: u16Bytes.count, by: 3) {
            u16Bytes[i + 0] = 32768
            u16Bytes[i + 1] = 16384
            u16Bytes[i + 2] = 8192
        }
        let u16Data = u16Bytes.withUnsafeBytes { Data($0) }
        var dcpParams = EffectiveDevelopParams.resolve(preset: base)
        dcpParams.develop.cameraProfile = .dcp(path: dcpURL.path)
        let msFrame = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/t5_lossless_ms.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16U(width: w, height: h, colorSpace: .cameraNative, data: u16Data),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: CameraColorMatrices(wbMultipliers: [2.0, 1.0, 1.5, 1.0], asShotWBApplied: false),
            isLosslessMS: true,
            exif: WhitelistedExif(orientation: 1)
        )
        let spec = RenderOutputSpec(
            targetBitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .rgb3ch,
            gainMapResolution: .half,
            gainMapGamma: 1.0,
            lockLegacyAppleGainMapBounds: false,
            generateHLGTexture: false,
            hlgTargetDimensions: nil
        )
        let renderedMS = try await engine.render(frame: msFrame, params: dcpParams, outputSpec: spec)
        #expect(renderedMS.width == w && renderedMS.height == h)
    }

    // MARK: - 15. P1 Gap 10: CIRAWv9Decoder BE preflight & ExifWhitelistBuilder boundaries

    @Test("Gap 10 (P1): CIRAWv9Decoder BE/invalid-orientation fallback & ExifWhitelistBuilder GPS/payload bounds")
    func testCIRAWv9PreflightBigEndianAndExifWhitelistBoundaries() async throws {
        let tmpDir = try makeT5TempDir(prefix: "t5_ciraw_be")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Big-endian TIFF with invalid orientation (0 and 9) falls back cleanly via LibRaw or normalizes orientation to 1
        for badOrient: UInt16 in [0, 9] {
            let tiffURL = tmpDir.appendingPathComponent("be_\(badOrient).tiff")
            try makeT5BigEndianTIFFWithOrientation(badOrient).write(to: tiffURL)
            let decoder = CIRAWv9Decoder()
            do {
                let res = try await decoder.decodeFull(url: tiffURL, options: DecodeOptions(backend: .ciraw9))
                #expect((1...8).contains(res.orientation))
            } catch {
                // Synthetic header-only TIFF without image strips fails cleanly without crash
                #expect(error is RAWDecodeError)
            }
        }

        // ExifWhitelistBuilder GPS exact boundaries (±90, ±180, 0) + oversized string truncation under 8192B
        let longStr = String(repeating: "A", count: 10_000)
        let exifMax = WhitelistedExif(
            make: longStr,
            model: longStr,
            lensMake: longStr,
            lensModel: longStr,
            gpsLatitude: -90.0,
            gpsLongitude: 180.0,
            gpsAltitude: 0.0,
            orientation: 6
        )
        let tiffMax = try ExifWhitelistBuilder.buildTIFFData(from: exifMax, customRenderedHDR: true)
        #expect(tiffMax.count <= ExifWhitelistBuilder.maxTIFFPayloadBytes)

        let propsMax = ExifWhitelistBuilder.buildImageIODictionary(from: exifMax, customRenderedHDR: true)
        let gpsDict = try #require(propsMax[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect((gpsDict[kCGImagePropertyGPSLatitudeRef] as? String) == "S")
        #expect((gpsDict[kCGImagePropertyGPSLatitude] as? Double) == 90.0)
        #expect((gpsDict[kCGImagePropertyGPSLongitudeRef] as? String) == "E")
        #expect((gpsDict[kCGImagePropertyGPSLongitude] as? Double) == 180.0)
        #expect((gpsDict[kCGImagePropertyGPSAltitude] as? Double) == 0.0)
        #expect((propsMax[kCGImagePropertyOrientation] as? Int) == 1)

        // Out-of-range / NaN GPS is dropped cleanly
        let exifOOB = WhitelistedExif(
            make: "SONY",
            gpsLatitude: 91.0,
            gpsLongitude: -181.0,
            gpsAltitude: .nan,
            orientation: 1
        )
        let propsOOB = ExifWhitelistBuilder.buildImageIODictionary(from: exifOOB)
        #expect(propsOOB[kCGImagePropertyGPSDictionary] == nil)
    }

    // MARK: - 16. P2 Gap 8: AVIFGridEncoder exact boundaries

    @Test("Gap 8 (P2): AVIFGridEncoder exact boundaries 4096x2176, 4096x2180, 4098x128 1ch, 4097x128, 4096x2178 3ch")
    func testAVIFGridEncoderExactThresholdsAndOddDimensionRejections() async throws {
        let tmpDir = try makeT5TempDir(prefix: "t5_avif_boundaries")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var preset = try PresetLoader.loadBuiltIn(id: .avifArchive)
        preset.avifCodec = .svtAV1
        preset.quality = 0.60
        preset.gainMapQuality = 0.60
        let enc = AVIFGridEncoder(speed: 10, maxThreads: 4)

        // 1) 4096x2176 = 8,912,896 px (exact limit -> usedGridTiling == false)
        do {
            let frame = try makeT5RenderedFrame(width: 4096, height: 2176, bitDepth: .bit10, gainMapChannels: .rgb3ch)
            let art = try await enc.encode(frame: frame, preset: preset, to: tmpDir.appendingPathComponent("b_4096x2176.avif"))
            #expect(art.usedGridTiling == false)
        }

        // 2) 4096x2180 = 8,929,280 px (> 8,912,896 -> usedGridTiling == true)
        do {
            let frame = try makeT5RenderedFrame(width: 4096, height: 2180, bitDepth: .bit10, gainMapChannels: .rgb3ch)
            let art = try await enc.encode(frame: frame, preset: preset, to: tmpDir.appendingPathComponent("b_4096x2180.avif"))
            #expect(art.usedGridTiling == true)
        }

        // 3) 4098x128 1ch (odd half-res GM 2049x64 allowed for 1ch YUV400 gridded)
        do {
            let frame = try makeT5RenderedFrame(width: 4098, height: 128, bitDepth: .bit10, gainMapChannels: .mono1ch)
            let art = try await enc.encode(frame: frame, preset: preset, to: tmpDir.appendingPathComponent("b_4098x128_1ch.avif"))
            #expect(art.usedGridTiling == true)
        }

        // 4) 4097x128 (odd base width > 4096 -> rejected)
        do {
            let frame = try makeT5RenderedFrame(width: 4097, height: 128, bitDepth: .bit10, gainMapChannels: .mono1ch)
            await #expect(throws: AVIFEncodeError.self) {
                _ = try await enc.encode(frame: frame, preset: preset, to: tmpDir.appendingPathComponent("b_4097x128.avif"))
            }
        }

        // 5) 4096x2178 3ch (odd half-res GM height 1089 for 3ch gridded -> rejected)
        do {
            let frame = try makeT5RenderedFrame(width: 4096, height: 2178, bitDepth: .bit10, gainMapChannels: .rgb3ch)
            await #expect(throws: AVIFEncodeError.self) {
                _ = try await enc.encode(frame: frame, preset: preset, to: tmpDir.appendingPathComponent("b_4096x2178_3ch.avif"))
            }
        }
    }

    // MARK: - 17. P2 Gap 9: HEICImageIOEncoder 8-bit & negative/cleanup guardrails

    @Test("Gap 9 (P2): HEICImageIOEncoder 8-bit HEIC and negative/cleanup guardrails")
    func testHEICImageIOEncoder8BitAndNegativeGuardrails() async throws {
        let tmpDir = try makeT5TempDir(prefix: "t5_heic_8bit")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var preset8 = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        preset8.bitDepth = .bit8
        let frame8 = try makeT5RenderedFrame(width: 128, height: 128, bitDepth: .bit8, gainMapChannels: .rgb3ch)
        let out8 = tmpDir.appendingPathComponent("out_8bit.heic")
        let enc = HEICImageIOEncoder()
        _ = try await enc.encode(frame: frame8, preset: preset8, to: out8)
        let report8 = try await ISO21496Probe().verify(
            url: out8,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: HeadroomStops(log2Value: 2.5).toLinear(),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(report8.passed)
        #expect(!(try hasT5LeftoverTmpFiles(in: tmpDir)))

        // Bad min > max
        let badMinMax = try makeT5RenderedFrame(
            width: 64, height: 64, bitDepth: .bit10, gainMapChannels: .rgb3ch,
            gainMapMin: [2.0, 2.0, 2.0], gainMapMax: [1.0, 1.0, 1.0]
        )
        await #expect(throws: HEICEncodeError.self) {
            _ = try await enc.encode(frame: badMinMax, preset: preset8, to: tmpDir.appendingPathComponent("bad_minmax.heic"))
        }

        // Bad gamma <= 0
        let badGamma = try makeT5RenderedFrame(
            width: 64, height: 64, bitDepth: .bit10, gainMapChannels: .rgb3ch,
            gainMapGamma: [0.0, 0.0, 0.0]
        )
        await #expect(throws: HEICEncodeError.self) {
            _ = try await enc.encode(frame: badGamma, preset: preset8, to: tmpDir.appendingPathComponent("bad_gamma.heic"))
        }

        // Non-writable destination (regular file as parent directory) leaves zero .tmp files
        let blockerFile = tmpDir.appendingPathComponent("not_a_dir")
        try Data("x".utf8).write(to: blockerFile)
        await #expect(throws: Error.self) {
            _ = try await enc.encode(frame: frame8, preset: preset8, to: blockerFile.appendingPathComponent("fail.heic"))
        }
        #expect(!(try hasT5LeftoverTmpFiles(in: tmpDir)))
    }

    // MARK: - 18. P2 Gap 10: ChiaroAppCore services & EDR Metal PSO compilation

    @Test("Gap 10 (P2): ChiaroAppCore ARWFileDiscovery, JSON codecs, and edr_preview vertex/fragment PSO")
    func testChiaroAppCoreServicesAndEDRPreviewPSO() throws {
        let tmpDir = try makeT5TempDir(prefix: "t5_app_core")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let subDir = tmpDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let arw1 = tmpDir.appendingPathComponent("IMG_001.ARW")
        let arw2 = subDir.appendingPathComponent("IMG_002.arw")
        let hif = tmpDir.appendingPathComponent("IMG_001.HIF")
        let fakeDir = tmpDir.appendingPathComponent("Folder.ARW", isDirectory: true)
        let symARW = subDir.appendingPathComponent("LINK_001.ARW")
        try Data("a".utf8).write(to: arw1)
        try Data("b".utf8).write(to: arw2)
        try Data("h".utf8).write(to: hif)
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symARW, withDestinationURL: arw1)

        // Non-recursive ignores subdir, .HIF, and Folder.ARW/
        let flat = ARWFileDiscovery.discover(urls: [tmpDir], recursive: false)
        #expect(flat.count == 1)
        #expect(flat[0].lastPathComponent == "IMG_001.ARW")

        // Recursive finds IMG_001.ARW + IMG_002.arw and deduplicates symlink LINK_001.ARW -> IMG_001.ARW
        let rec = ARWFileDiscovery.discover(urls: [tmpDir], recursive: true)
        #expect(rec.count == 2)

        // Launch arguments filter AppKit/Foundation debug flags
        let launch = ARWFileDiscovery.parseLaunchURLs(arguments: [
            "Chiaro",
            "-NSDocumentRevisionsDebugMode", "YES",
            "-AppleLanguages", "(en)",
            "-psn_0_12345",
            arw1.path,
            hif.path,
        ])
        #expect(launch.count == 1)
        #expect(launch[0].lastPathComponent == "IMG_001.ARW")

        // DeltaJSONCodec & PresetJSONCodec round-trips
        let deltaURL = tmpDir.appendingPathComponent("deltas.json")
        let deltaMap = [
            "IMG_001.ARW": PerPhotoDelta(exposureEVDelta: 0.4, clearMaxLongEdgeOverride: true)
        ]
        try DeltaJSONCodec.saveMap(deltaMap, to: deltaURL)
        let loadedMap = try DeltaJSONCodec.loadMap(from: deltaURL)
        let matched = DeltaJSONCodec.matchDelta(in: loadedMap, for: URL(fileURLWithPath: "/any/img_001.arw"))
        #expect(matched?.exposureEVDelta == 0.4)
        #expect(matched?.clearMaxLongEdgeOverride == true)

        let presetURL = tmpDir.appendingPathComponent("preset.json")
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        try PresetJSONCodec.exportPreset(preset, to: presetURL)
        let importedPreset = try PresetJSONCodec.importPreset(from: presetURL)
        #expect(importedPreset.id == preset.id)

        // Runtime edr_preview_vertex + edr_preview_fragment Metal render PSO compilation
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pso = try EDRPreviewShaderSupport.makeRenderPipelineState(device: device, pixelFormat: .rgba16Float)
        #expect(pso.label == "ChiaroEDRPreviewPSO")
    }

    // MARK: - 19. Iter 3 Gap 1: CubeLUT 1D > maxTextureDimension rejected cleanly without SIGABRT

    @Test("Iter 3 Gap 1 (P1): CubeLUT 1D > maxTextureDimension (16385) rejected cleanly without SIGABRT")
    func testCubeLUT1DOverMaxTextureDimensionRejectedCleanlyWithoutSIGABRT() async throws {
        let engine = try MetalPipelineEngine()
        let maxDim = MTLHeapTexturePool.maxTextureDimension(for: engine.device)
        let overDim = maxDim + 1

        var lines: [String] = ["TITLE \"OverMaxDim1DLUT\"", "LUT_1D_SIZE \(overDim)"]
        lines.reserveCapacity(overDim + 2)
        for i in 0..<overDim {
            let v = Float(i) / Float(max(1, overDim - 1))
            lines.append("\(v) \(v) \(v)")
        }
        let cubeText = lines.joined(separator: "\n") + "\n"

        // 1. CubeLUT parses valid LUT_1D_SIZE 16385 cleanly, and makeMetalTexture returns nil instead of SIGABRT
        let parsed = try CubeLUT(parsing: cubeText)
        #expect(parsed.dimension == .oneD(overDim))
        #expect(parsed.makeMetalTexture(device: engine.device) == nil)

        // 2. HSVTable3D > 3D max texture dimension (2048) returns nil cleanly instead of SIGABRT
        let oversizedHSV = HSVTable3D(
            hueDivs: 2049,
            satDivs: 2,
            valDivs: 2,
            rgbaFloats: [Float](repeating: 1.0, count: 2049 * 2 * 2 * 4)
        )
        #expect(oversizedHSV.makeMetalTexture(device: engine.device) == nil)

        // 3. MetalPipelineEngine.render rejects LUT_1D_SIZE 16385 explicitly (does not SIGABRT or silently skip LUT)
        let tmpDir = try makeT5TempDir(prefix: "t5_cubelut_overdim")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lutURL = tmpDir.appendingPathComponent("over_max_1d.cube")
        try Data(cubeText.utf8).write(to: lutURL)

        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        var params = EffectiveDevelopParams.resolve(preset: preset)
        params.develop.cubeLUTPath = lutURL.path
        let spec = RenderOutputSpec(
            targetBitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .rgb3ch,
            gainMapResolution: .half,
            gainMapGamma: 1.0,
            lockLegacyAppleGainMapBounds: false,
            generateHLGTexture: false,
            hlgTargetDimensions: nil
        )
        let frame = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/t5_cubelut_overdim.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16F(
                width: 4,
                height: 4,
                colorSpace: .linearRec2020,
                data: makeT5Float16Data(width: 4, height: 4, rgba: SIMD4<Float>(0.18, 0.18, 0.18, 1.0))
            ),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: 4, height: 4),
            orientation: 1,
            colorMatrices: CameraColorMatrices(),
            isLosslessMS: false,
            exif: WhitelistedExif(orientation: 1)
        )

        do {
            _ = try await engine.render(frame: frame, params: params, outputSpec: spec)
            Issue.record("Expected CubeLUTError.unsupportedDimension(\(overDim)) from MetalPipelineEngine.render")
        } catch let error as CubeLUTError {
            if case let .unsupportedDimension(size) = error {
                #expect(size == overDim)
            } else {
                Issue.record("Expected CubeLUTError.unsupportedDimension(\(overDim)), got \(error)")
            }
        }
    }
}

} // extension ChiaroSerializedSuites
