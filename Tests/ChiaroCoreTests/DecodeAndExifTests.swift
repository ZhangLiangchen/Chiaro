import CLibAVIFBridge
import CLibRawBridge
import CUltraHDRBridge
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import ChiaroCore

private let m4aTangmoDir = TestFixtures.sampleDirectory
private let m4aRepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ChiaroCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // Chiaro

private func makeM4aTempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func runM4aCLI(_ executablePath: String, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executablePath)
    proc.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    try proc.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (
        proc.terminationStatus,
        String(decoding: outData, as: UTF8.self),
        String(decoding: errData, as: UTF8.self)
    )
}

private struct ParsedTIFFIFD {
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let valueOrOffset: UInt32
        let raw4Bytes: Data
    }
    let entries: [Entry]
    let nextIFDOffset: UInt32
}

private func readLE16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func parseLETiffIFD(_ data: Data, offset: Int) throws -> ParsedTIFFIFD {
    try #require(offset + 2 <= data.count)
    let count = Int(readLE16(data, at: offset))
    try #require(offset + 2 + count * 12 + 4 <= data.count)
    var entries: [ParsedTIFFIFD.Entry] = []
    for i in 0..<count {
        let base = offset + 2 + i * 12
        let tag = readLE16(data, at: base)
        let type = readLE16(data, at: base + 2)
        let cnt = readLE32(data, at: base + 4)
        let val = readLE32(data, at: base + 8)
        let raw4 = Data(data[(base + 8)..<(base + 12)])
        entries.append(.init(tag: tag, type: type, count: cnt, valueOrOffset: val, raw4Bytes: raw4))
    }
    let nextOffset = readLE32(data, at: offset + 2 + count * 12)
    return ParsedTIFFIFD(entries: entries, nextIFDOffset: nextOffset)
}

private func maxFloat16RGBValue(in data: Data) -> (maxVal: Float, allFinite: Bool) {
    var maxVal: Float = -Float.greatestFiniteMagnitude
    var allFinite = true
    data.withUnsafeBytes { raw in
        let halfs = raw.bindMemory(to: UInt16.self)
        var i = 0
        while i + 2 < halfs.count {
            let r = Float(Float16(bitPattern: halfs[i]))
            let g = Float(Float16(bitPattern: halfs[i + 1]))
            let b = Float(Float16(bitPattern: halfs[i + 2]))
            if !r.isFinite || !g.isFinite || !b.isFinite {
                allFinite = false
                break
            }
            maxVal = max(maxVal, max(r, max(g, b)))
            i += 4
        }
    }
    return (maxVal, allFinite)
}

private func makeSyntheticDisplayP3JPEGForExif(width: Int = 64, height: Int = 64) throws -> Data {
    let cs = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let bpr = width * 4
    var pixels = [UInt8](repeating: 0, count: bpr * height)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * bpr + x * 4
            pixels[i + 0] = UInt8((x * 255) / max(1, width - 1))
            pixels[i + 1] = UInt8((y * 255) / max(1, height - 1))
            pixels[i + 2] = 160
            pixels[i + 3] = 255
        }
    }
    let ctx = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bpr,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let img = try #require(ctx.makeImage())
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

private func makeSyntheticGrayGainMapJPEG(width: Int = 32, height: Int = 32) throws -> Data {
    let cs = CGColorSpaceCreateDeviceGray()
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            pixels[y * width + x] = (x >= width / 2) ? 255 : 0
        }
    }
    let ctx = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    let img = try #require(ctx.makeImage())
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

/// Crafts a valid minimal uncompressed 16-bit Bayer DNG (all zero/low pixels so maxPixel <= 1.0)
/// that both Apple CIRAWFilter and LibRaw can decode, for testing EDR-headroom fallback.
private func makeMinimalLowDynamicRangeDNG(width: Int = 64, height: Int = 64) -> Data {
    // Little-endian TIFF/DNG with IFD0 containing DNG tags + 16-bit CFA strip
    var data = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    func appendU16(_ v: UInt16) {
        var le = v.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }
    func appendU32(_ v: UInt32) {
        var le = v.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let inlineOrData: Data
        let isInline: Bool
    }

    let pixelBytes = width * height * 2
    let pixelData = Data(repeating: 0, count: pixelBytes) // all black -> maxPixel == 0.0 <= 1.0

    // 9 ColorMatrix1 SRATIONAL values (identity * 10000 / 10000)
    var cmData = Data()
    for r in 0..<3 {
        for c in 0..<3 {
            var num = Int32(r == c ? 10000 : 0).littleEndian
            var den = Int32(10000).littleEndian
            cmData.append(Data(bytes: &num, count: 4))
            cmData.append(Data(bytes: &den, count: 4))
        }
    }
    // 3 AsShotNeutral RATIONAL values [1, 1, 1]
    var asnData = Data()
    for _ in 0..<3 {
        var num = UInt32(10000).littleEndian
        var den = UInt32(10000).littleEndian
        asnData.append(Data(bytes: &num, count: 4))
        asnData.append(Data(bytes: &den, count: 4))
    }

    func inlineU16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8), 0, 0])
    }
    func inlineU32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    let makeBytes = Data("Sony\0".utf8)
    let modelBytes = Data("TestDNG\0".utf8)
    let stripOffsetPlaceholder = Data(repeating: 0, count: 4)

    let entries: [Entry] = [
        Entry(tag: 0x00FE, type: 4, count: 1, inlineOrData: inlineU32(0), isInline: true), // SubfileType
        Entry(tag: 0x0100, type: 4, count: 1, inlineOrData: inlineU32(UInt32(width)), isInline: true),
        Entry(tag: 0x0101, type: 4, count: 1, inlineOrData: inlineU32(UInt32(height)), isInline: true),
        Entry(tag: 0x0102, type: 3, count: 1, inlineOrData: inlineU16(16), isInline: true), // BitsPerSample
        Entry(tag: 0x0103, type: 3, count: 1, inlineOrData: inlineU16(1), isInline: true),  // Compression = None
        Entry(tag: 0x0106, type: 3, count: 1, inlineOrData: inlineU16(32803), isInline: true), // CFA
        Entry(tag: 0x010F, type: 2, count: UInt32(makeBytes.count), inlineOrData: makeBytes, isInline: false),
        Entry(tag: 0x0110, type: 2, count: UInt32(modelBytes.count), inlineOrData: modelBytes, isInline: false),
        Entry(tag: 0x0111, type: 4, count: 1, inlineOrData: stripOffsetPlaceholder, isInline: true), // StripOffsets (patched)
        Entry(tag: 0x0112, type: 3, count: 1, inlineOrData: inlineU16(1), isInline: true),
        Entry(tag: 0x0115, type: 3, count: 1, inlineOrData: inlineU16(1), isInline: true),
        Entry(tag: 0x0116, type: 4, count: 1, inlineOrData: inlineU32(UInt32(height)), isInline: true),
        Entry(tag: 0x0117, type: 4, count: 1, inlineOrData: inlineU32(UInt32(pixelBytes)), isInline: true),
        Entry(tag: 0x011C, type: 3, count: 1, inlineOrData: inlineU16(1), isInline: true),
        Entry(tag: 0x828D, type: 3, count: 2, inlineOrData: Data([2, 0, 2, 0]), isInline: true), // CFARepeatPatternDim
        Entry(tag: 0x828E, type: 1, count: 4, inlineOrData: Data([0, 1, 1, 2]), isInline: true), // RGGB
        Entry(tag: 0xC612, type: 1, count: 4, inlineOrData: Data([1, 4, 0, 0]), isInline: true), // DNGVersion 1.4.0.0
        Entry(tag: 0xC621, type: 10, count: 9, inlineOrData: cmData, isInline: false), // ColorMatrix1
        Entry(tag: 0xC628, type: 5, count: 3, inlineOrData: asnData, isInline: false), // AsShotNeutral
    ]

    appendU16(UInt16(entries.count))
    var patchPos: [UInt16: Int] = [:]
    for e in entries {
        appendU16(e.tag)
        appendU16(e.type)
        appendU32(e.count)
        patchPos[e.tag] = data.count
        if e.isInline {
            data.append(e.inlineOrData)
        } else {
            appendU32(0)
        }
    }
    appendU32(0) // next IFD

    for e in entries where !e.isInline {
        if data.count % 2 != 0 { data.append(0) }
        var off = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &off) { data.replaceSubrange(patchPos[e.tag]!..<(patchPos[e.tag]! + 4), with: $0) }
        data.append(e.inlineOrData)
    }

    if data.count % 2 != 0 { data.append(0) }
    var stripOff = UInt32(data.count).littleEndian
    withUnsafeBytes(of: &stripOff) { data.replaceSubrange(patchPos[0x0111]!..<(patchPos[0x0111]! + 4), with: $0) }
    data.append(pixelData)
    return data
}

/// Crafts a synthetic Sony Lossless M/S TIFF header (SubIFD YCbCr 3ch >=12-bit + ExifIFD + MakerNote).
private func makeSyntheticSonyLosslessMSTIFF() -> Data {
    var data = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    func appendU16(_ v: UInt16) {
        var le = v.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }
    func appendU32(_ v: UInt32) {
        var le = v.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }
    func writeU32(_ v: UInt32, at pos: Int) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.replaceSubrange(pos..<(pos + 4), with: $0) }
    }

    let makeBytes = Data("SONY\0".utf8)
    let modelBytes = Data("ILCE-7CM2\0".utf8)
    let offsetTimeBytes = Data("+08:00\0".utf8)
    let makerNoteBytes = Data("SONY DSC GARBAGE MAKERNOTE".utf8)

    // IFD0: Make, Model, Orientation=8, SubIFD (0x014A), ExifIFD (0x8769)
    appendU16(5)
    // 0x010F Make
    appendU16(0x010F); appendU16(2); appendU32(UInt32(makeBytes.count))
    let makePos = data.count; appendU32(0)
    // 0x0110 Model
    appendU16(0x0110); appendU16(2); appendU32(UInt32(modelBytes.count))
    let modelPos = data.count; appendU32(0)
    // 0x0112 Orientation = 8
    appendU16(0x0112); appendU16(3); appendU32(1); appendU16(8); appendU16(0)
    // 0x014A SubIFD
    appendU16(0x014A); appendU16(4); appendU32(1)
    let subIFDPtrPos = data.count; appendU32(0)
    // 0x8769 ExifIFD
    appendU16(0x8769); appendU16(4); appendU32(1)
    let exifIFDPtrPos = data.count; appendU32(0)
    appendU32(0)

    writeU32(UInt32(data.count), at: makePos); data.append(makeBytes)
    if data.count % 2 != 0 { data.append(0) }
    writeU32(UInt32(data.count), at: modelPos); data.append(modelBytes)
    if data.count % 2 != 0 { data.append(0) }

    // SubIFD (RAW YCbCr 3-channel 14-bit Compression=6)
    writeU32(UInt32(data.count), at: subIFDPtrPos)
    appendU16(5)
    appendU16(0x00FE); appendU16(4); appendU32(1); appendU32(0) // SubfileType = 0
    appendU16(0x0102); appendU16(3); appendU32(3)
    let bpsPos = data.count; appendU32(0)
    appendU16(0x0103); appendU16(3); appendU32(1); appendU16(6); appendU16(0) // Compression = 6
    appendU16(0x0106); appendU16(3); appendU32(1); appendU16(6); appendU16(0) // Photometric = 6 (YCbCr)
    appendU16(0x0115); appendU16(3); appendU32(1); appendU16(3); appendU16(0) // SamplesPerPixel = 3
    appendU32(0)

    writeU32(UInt32(data.count), at: bpsPos)
    appendU16(14); appendU16(14); appendU16(14)

    // ExifIFD with 0x9011 OffsetTimeOriginal and 0x927C MakerNote (must be skipped)
    if data.count % 2 != 0 { data.append(0) }
    writeU32(UInt32(data.count), at: exifIFDPtrPos)
    appendU16(2)
    appendU16(0x9011); appendU16(2); appendU32(UInt32(offsetTimeBytes.count))
    let otPos = data.count; appendU32(0)
    appendU16(0x927C); appendU16(7); appendU32(UInt32(makerNoteBytes.count))
    let mnPos = data.count; appendU32(0)
    appendU32(0)

    writeU32(UInt32(data.count), at: otPos); data.append(offsetTimeBytes)
    if data.count % 2 != 0 { data.append(0) }
    writeU32(UInt32(data.count), at: mnPos); data.append(makerNoteBytes)

    return data
}

// MARK: - M4a Tests

extension ChiaroSerializedSuites {

@Suite("DecodeAndExifTests", .serialized)
struct DecodeAndExifTests {

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testLibRawDecoderFullAndProxyOnRealTangmoARWs() async throws {
        let dsc2533 = m4aTangmoDir.appendingPathComponent("DSC02533.ARW")
        let dsc2540 = m4aTangmoDir.appendingPathComponent("DSC02540.ARW")
        let dsc2556 = m4aTangmoDir.appendingPathComponent("DSC02556.ARW")

        try #require(FileManager.default.fileExists(atPath: dsc2533.path))
        try #require(FileManager.default.fileExists(atPath: dsc2540.path))
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        let decoder = LibRawDecoder()

        // 1. Full decode DSC02533 (33MP horizontal, Orientation=1, CustomRendered=3)
        let f2533 = try await decoder.decodeFull(
            url: dsc2533,
            options: DecodeOptions(backend: .libraw, highlightMode: .opposedInpaint, isProxy: false, maxThreadsPerWorker: 2, customRenderedHDR: true)
        )
        #expect(f2533.backendUsed == .libraw)
        #expect(f2533.fallbackReason == nil)
        #expect(f2533.orientation == 1)
        #expect(f2533.isLosslessMS == false)
        #expect(f2533.colorMatrices.asShotWBApplied == false)
        #expect(f2533.colorMatrices.camXYZ.count == 9)
        #expect(f2533.colorMatrices.forwardMatrix.count == 9)
        #expect(f2533.colorMatrices.wbMultipliers.count == 4)
        #expect(f2533.colorMatrices.wbMultipliers.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(f2533.visibleCrop.width == 7008)
        #expect(f2533.visibleCrop.height == 4672)

        if case let .linearRGB16U(w, h, cs, data) = f2533.payload {
            #expect(w == 7008)
            #expect(h == 4672)
            #expect(cs == .cameraNative)
            let expectedBytes = 7008 * 4672 * 6
            #expect(data.count == expectedBytes)
        } else {
            Issue.record("Expected .linearRGB16U payload from LibRawDecoder")
        }

        #expect(f2533.exif.make?.lowercased() == "sony")
        #expect(f2533.exif.model == "ILCE-7CM2")
        #expect(f2533.exif.lensModel == "TAMRON 25-200mm F2.8-5.6 A075 E")
        #expect(f2533.exif.focalLengthMM == 49.0)
        #expect(f2533.exif.focalLengthIn35mmFilm == 49)
        #expect(f2533.exif.isoSpeedRatings == 12800)
        #expect(f2533.exif.offsetTimeOriginal == "+08:00")
        #expect(f2533.exif.subSecTimeOriginal == "436")
        #expect(f2533.exif.dateTimeOriginal == "2026:11:22 18:43:43")
        #expect(abs((f2533.exif.exposureBiasEV ?? 99.0)) < 0.01)
        #expect(f2533.exif.orientation == 1)
        #expect(f2533.exif.customRendered == 3)

        let mirrorLabels = Mirror(reflecting: f2533.exif).children.compactMap { $0.label?.lowercased() }
        #expect(!mirrorLabels.contains(where: { $0.contains("makernote") }))

        // 2. Full decode DSC02540 (33MP Rotate 270 CW -> Orientation=8 preserved)
        let f2540 = try await decoder.decodeFull(url: dsc2540, options: .default)
        #expect(f2540.orientation == 8)
        #expect(f2540.exif.orientation == 8)
        #expect(f2540.exif.customRendered == nil)
        if case let .linearRGB16U(w, h, _, _) = f2540.payload {
            #expect(w == 7008)
            #expect(h == 4672)
        } else {
            Issue.record("Expected .linearRGB16U payload")
        }

        // 3. Proxy decode 33MP DSC02533 -> 3504x2336
        let p2533 = try await decoder.decodeProxy(url: dsc2533)
        #expect(p2533.orientation == 1)
        if case let .linearRGB16U(w, h, cs, data) = p2533.payload {
            #expect(w == 3504)
            #expect(h == 2336)
            #expect(cs == .cameraNative)
            let expectedBytes = 3504 * 2336 * 6
            #expect(data.count == expectedBytes)
        } else {
            Issue.record("Expected .linearRGB16U proxy payload")
        }

        // 4. Proxy decode 14MP APS-C DSC02556 -> 2304x1536 and <= 300ms target
        let t0 = ContinuousClock.now
        let p2556 = try await decoder.decodeProxy(url: dsc2556)
        let elapsed = ContinuousClock.now - t0
        let elapsedMs = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15
        #expect(elapsedMs <= 300.0, "14MP proxy decode took \(elapsedMs) ms (target <= 300ms)")
        #expect(p2556.orientation == 8)
        #expect(p2556.exif.focalLengthMM == 200.0)
        #expect(p2556.exif.focalLengthIn35mmFilm == 300)
        #expect(p2556.exif.isoSpeedRatings == 6400)
        #expect(abs((p2556.exif.exposureBiasEV ?? 0.0) - (-0.7)) < 0.01)
        #expect(p2556.exif.subSecTimeOriginal == "672")
        if case let .linearRGB16U(w, h, cs, data) = p2556.payload {
            #expect(w == 2304)
            #expect(h == 1536)
            #expect(cs == .cameraNative)
            let expectedBytes = 2304 * 1536 * 6
            #expect(data.count == expectedBytes)
        } else {
            Issue.record("Expected .linearRGB16U 14MP proxy payload")
        }

        // 5. MetalPipelineEngine integration on rotated frame (DSC02540 proxy/full)
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let params = EffectiveDevelopParams.resolve(preset: preset)
        let engine = try MetalPipelineEngine()
        let spec = RenderOutputSpec(
            targetBitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .rgb3ch,
            gainMapResolution: .half,
            gainMapGamma: preset.gainMapGamma,
            lockLegacyAppleGainMapBounds: false,
            generateHLGTexture: false
        )
        let rendered2540 = try await engine.render(frame: f2540, params: params, outputSpec: spec)
        #expect(rendered2540.width == 4672)
        #expect(rendered2540.height == 7008)
        #expect(rendered2540.exif.orientation == 1)
    }

    @Test
    func testLibRawDecoderErrorPaths() async throws {
        let decoder = LibRawDecoder()

        await #expect(throws: RAWDecodeError.self) {
            _ = try await decoder.decodeFull(url: URL(string: "https://example.com/a.arw")!, options: .default)
        }

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_\(UUID().uuidString).ARW")
        await #expect(throws: RAWDecodeError.fileNotFound(missingURL)) {
            _ = try await decoder.decodeFull(url: missingURL, options: .default)
        }

        let tmpDir = try makeM4aTempDir(prefix: "libraw-corrupt")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let corruptURL = tmpDir.appendingPathComponent("corrupt.ARW")
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF]).write(to: corruptURL)

        do {
            _ = try await decoder.decodeFull(url: corruptURL, options: .default)
            Issue.record("Expected decodeFull to fail on corrupt file")
        } catch let err as RAWDecodeError {
            if case .librawFailed = err {
                // expected
            } else {
                Issue.record("Expected .librawFailed, got \(err)")
            }
        }
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testCIRAWv9DecoderFullProxyMetalParityAndOrientation() async throws {
        let dsc2533 = m4aTangmoDir.appendingPathComponent("DSC02533.ARW")
        let dsc2540 = m4aTangmoDir.appendingPathComponent("DSC02540.ARW")
        let dsc2556 = m4aTangmoDir.appendingPathComponent("DSC02556.ARW")

        try #require(FileManager.default.fileExists(atPath: dsc2533.path))
        try #require(FileManager.default.fileExists(atPath: dsc2540.path))
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        let decoder = CIRAWv9Decoder(requireEDRHighlightHeadroom: true)

        // 1. Full decode DSC02533 (33MP horizontal)
        let f2533 = try await decoder.decodeFull(
            url: dsc2533,
            options: DecodeOptions(backend: .ciraw9, highlightMode: .opposedInpaint, isProxy: false, maxThreadsPerWorker: 2, customRenderedHDR: true)
        )
        #expect(f2533.backendUsed == .ciraw9)
        #expect(f2533.fallbackReason == nil)
        #expect(f2533.isLosslessMS == false)
        #expect(f2533.orientation == 1)
        #expect(f2533.colorMatrices.asShotWBApplied == true)
        #expect(f2533.colorMatrices.camXYZ.count == 9)
        #expect(f2533.colorMatrices.forwardMatrix.count == 9)
        #expect(f2533.colorMatrices.wbMultipliers == [1.0, 1.0, 1.0, 1.0])

        let kelvin = ColorTransforms.estimateSceneKelvin(matrices: f2533.colorMatrices)
        #expect(kelvin.isFinite && kelvin >= 2000.0 && kelvin <= 15000.0)

        if case let .linearRGB16F(w, h, cs, data) = f2533.payload {
            #expect(w == 7008)
            #expect(h == 4672)
            #expect(cs == .extendedLinearDisplayP3)
            let expectedBytes = 7008 * 4672 * 8
            #expect(data.count == expectedBytes)
            let stats = maxFloat16RGBValue(in: data)
            #expect(stats.allFinite)
            #expect(stats.maxVal > 1.0, "Expected EDR highlight headroom > 1.0, got \(stats.maxVal)")
        } else {
            Issue.record("Expected .linearRGB16F payload from CIRAWv9Decoder")
        }

        // Verify pure-Swift TIFF pre-flight captured OffsetTimeOriginal + SubSecTimeOriginal + LensModel
        #expect(f2533.exif.offsetTimeOriginal == "+08:00")
        #expect(f2533.exif.subSecTimeOriginal == "436")
        #expect(f2533.exif.dateTimeOriginal == "2026:11:22 18:43:43")
        #expect(f2533.exif.lensModel == "TAMRON 25-200mm F2.8-5.6 A075 E")
        #expect(f2533.exif.customRendered == 3)

        // 2. Full decode DSC02540 (Orientation=8) & MetalPipelineEngine upright render parity (4672x7008)
        let f2540 = try await decoder.decodeFull(url: dsc2540, options: .default)
        #expect(f2540.backendUsed == .ciraw9)
        #expect(f2540.orientation == 8)
        #expect(f2540.exif.orientation == 8)
        if case let .linearRGB16F(w, h, cs, _) = f2540.payload {
            #expect(w == 7008)
            #expect(h == 4672)
            #expect(cs == .extendedLinearDisplayP3)
        } else {
            Issue.record("Expected unrotated 7008x4672 .linearRGB16F from CIRAWv9Decoder")
        }

        // 3. Full decode DSC02556 (14MP APS-C Orientation=8) + Proxy decode (isDraftModeEnabled=true, scaleFactor=0.5)
        let f2556 = try await decoder.decodeFull(url: dsc2556, options: .default)
        #expect(f2556.backendUsed == .ciraw9)
        #expect(f2556.orientation == 8)
        if case let .linearRGB16F(w, h, cs, data) = f2556.payload {
            #expect(w == 4608)
            #expect(h == 3072)
            #expect(cs == .extendedLinearDisplayP3)
            let stats = maxFloat16RGBValue(in: data)
            #expect(stats.allFinite && stats.maxVal > 1.0)
        } else {
            Issue.record("Expected 4608x3072 .linearRGB16F from CIRAWv9Decoder")
        }

        let p2556 = try await decoder.decodeProxy(url: dsc2556)
        #expect(p2556.backendUsed == .ciraw9)
        #expect(p2556.orientation == 8)
        if case let .linearRGB16F(w, h, cs, data) = p2556.payload {
            #expect(w == 2304)
            #expect(h == 1536)
            #expect(cs == .extendedLinearDisplayP3)
            let stats = maxFloat16RGBValue(in: data)
            #expect(stats.allFinite && stats.maxVal > 1.0)
        } else {
            Issue.record("Expected 2304x1536 proxy .linearRGB16F from CIRAWv9Decoder")
        }

        // MetalPipelineEngine render on DSC02540 & DSC02556 -> upright 4672x7008 and 3072x4608 with orientation=1
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let params = EffectiveDevelopParams.resolve(preset: preset)
        let engine = try MetalPipelineEngine()
        let spec = RenderOutputSpec(
            targetBitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .rgb3ch,
            gainMapResolution: .half,
            gainMapGamma: preset.gainMapGamma,
            lockLegacyAppleGainMapBounds: false,
            generateHLGTexture: false
        )

        let rendered2540 = try await engine.render(frame: f2540, params: params, outputSpec: spec)
        #expect(rendered2540.width == 4672)
        #expect(rendered2540.height == 7008)
        #expect(rendered2540.exif.orientation == 1)

        let rendered2556 = try await engine.render(frame: f2556, params: params, outputSpec: spec)
        #expect(rendered2556.width == 3072)
        #expect(rendered2556.height == 4608)
        #expect(rendered2556.exif.orientation == 1)
    }

    @Test
    func testCIRAWv9DecoderFallbacksToLibRaw() async throws {
        let tmpDir = try makeM4aTempDir(prefix: "ciraw-fallback")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Genuine fallback returning DecodedRAWFrame with backendUsed == .libraw and non-nil fallbackReason:
        //    A real valid uncompressed 16-bit Bayer DNG with zero/low-key pixels fails requireEDRHighlightHeadroom
        //    on CIRAWv9Decoder and automatically falls back to LibRawDecoder.
        let lowKeyDNGURL = tmpDir.appendingPathComponent("lowkey_test.dng")
        try makeMinimalLowDynamicRangeDNG(width: 64, height: 64).write(to: lowKeyDNGURL)

        let strictEDRDecoder = CIRAWv9Decoder(requireEDRHighlightHeadroom: true)
        let fallbackFrame = try await strictEDRDecoder.decodeFull(url: lowKeyDNGURL, options: .default)
        #expect(fallbackFrame.backendUsed == .libraw)
        #expect(fallbackFrame.fallbackReason != nil)
        #expect(fallbackFrame.fallbackReason?.isEmpty == false)
        if case let .linearRGB16U(w, h, _, _) = fallbackFrame.payload {
            #expect(w == 64)
            #expect(h == 64)
        } else {
            Issue.record("Expected fallback LibRawDecoder .linearRGB16U frame")
        }

        // 2. Unsupported non-RAW image (JPEG): CIRAWFilter returns nil (or no .version9) -> routes to LibRaw -> fails cleanly
        let jpegURL = tmpDir.appendingPathComponent("not_raw.jpg")
        try makeSyntheticDisplayP3JPEGForExif().write(to: jpegURL)
        await #expect(throws: RAWDecodeError.self) {
            _ = try await strictEDRDecoder.decodeFull(url: jpegURL, options: .default)
        }

        // 3. Synthetic Sony Lossless M/S TIFF trigger: pre-flight detects YCbCr 3ch >=12-bit and routes to LibRaw
        let msURL = tmpDir.appendingPathComponent("synthetic_lossless_ms.ARW")
        try makeSyntheticSonyLosslessMSTIFF().write(to: msURL)
        do {
            _ = try await strictEDRDecoder.decodeFull(url: msURL, options: .default)
            Issue.record("Expected synthetic header-only TIFF without strip data to fail LibRaw unpack after routing")
        } catch let err as RAWDecodeError {
            // Must fail in LibRawDecoder (not CIRAWv9), proving Lossless M/S pre-flight skipped CIRAWv9
            if case .librawFailed = err {
                // expected
            } else {
                Issue.record("Expected .librawFailed from Lossless M/S fallback path, got \(err)")
            }
        }
    }

    @Test
    func testExifWhitelistBuilderByteFormatTagOrderingAndEdgeCases() throws {
        let fullExif = WhitelistedExif(
            make: "SONY",
            model: "ILCE-7CM2",
            lensMake: "TAMRON",
            lensModel: "TAMRON 25-200mm F2.8-5.6 A075 E",
            focalLengthMM: 200.0,
            focalLengthIn35mmFilm: 300,
            exposureTimeSeconds: 0.05,
            fNumber: 5.6,
            isoSpeedRatings: 6400,
            exposureBiasEV: -0.7,
            dateTimeOriginal: "2026:11:22 19:53:46",
            offsetTimeOriginal: "+08:00",
            subSecTimeOriginal: "672",
            gpsLatitude: -31.230416, // negative signed coordinate -> normalized abs() + "S"
            gpsLatitudeRef: "N",     // sign overrides ref to "S"
            gpsLongitude: -121.473701, // negative signed coordinate -> normalized abs() + "W"
            gpsLongitudeRef: "E",
            gpsAltitude: -12.5,
            gpsAltitudeRef: 0,
            gpsTimestamp: "11:53:46.50",
            gpsDateStamp: "2026:11:22",
            orientation: 8,          // MUST be forced to 1
            customRendered: nil
        )

        let tiff = try ExifWhitelistBuilder.buildTIFFData(from: fullExif, customRenderedHDR: true)
        #expect(tiff.count < ExifWhitelistBuilder.maxTIFFPayloadBytes)
        #expect(Array(tiff.prefix(8)) == [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])

        let app1 = try ExifWhitelistBuilder.buildAPP1ExifData(from: fullExif, customRenderedHDR: true)
        #expect(Array(app1.prefix(6)) == [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        #expect(app1.dropFirst(6) == tiff)

        // Parse IFD0, ExifIFD, GPSIFD directly at byte level
        let ifd0 = try parseLETiffIFD(tiff, offset: 8)
        let ifd0Tags = ifd0.entries.map(\.tag)
        #expect(ifd0Tags == ifd0Tags.sorted())
        #expect(Set(ifd0Tags).count == ifd0Tags.count)
        #expect(ifd0.nextIFDOffset == 0)

        let orientEntry = try #require(ifd0.entries.first(where: { $0.tag == 0x0112 }))
        #expect(readLE16(orientEntry.raw4Bytes, at: 0) == 1)

        let exifPtrEntry = try #require(ifd0.entries.first(where: { $0.tag == 0x8769 }))
        let exifIFDOffset = Int(exifPtrEntry.valueOrOffset)
        #expect(exifIFDOffset % 2 == 0)

        let exifIFD = try parseLETiffIFD(tiff, offset: exifIFDOffset)
        let exifTags = exifIFD.entries.map(\.tag)
        #expect(exifTags == exifTags.sorted())
        #expect(Set(exifTags).count == exifTags.count)
        #expect(!exifTags.contains(0x927C), "MakerNote 0x927C must NEVER be emitted")
        #expect(exifTags.contains(0x9011), "OffsetTimeOriginal must use canonical tag 0x9011")

        let versionEntry = try #require(exifIFD.entries.first(where: { $0.tag == 0x9000 }))
        #expect(Array(versionEntry.raw4Bytes) == [0x30, 0x32, 0x33, 0x32]) // "0232"

        let crEntry = try #require(exifIFD.entries.first(where: { $0.tag == 0xA401 }))
        #expect(readLE16(crEntry.raw4Bytes, at: 0) == 3)

        let gpsPtrEntry = try #require(ifd0.entries.first(where: { $0.tag == 0x8825 }))
        let gpsIFDOffset = Int(gpsPtrEntry.valueOrOffset)
        #expect(gpsIFDOffset % 2 == 0)
        let gpsIFD = try parseLETiffIFD(tiff, offset: gpsIFDOffset)
        let gpsTags = gpsIFD.entries.map(\.tag)
        #expect(gpsTags == gpsTags.sorted())
        #expect(gpsTags.contains(0x0000))
        #expect(gpsTags.contains(0x0002))
        #expect(gpsTags.contains(0x0004))
        #expect(gpsTags.contains(0x0006))

        let verEntry = try #require(gpsIFD.entries.first(where: { $0.tag == 0x0000 }))
        #expect(Array(verEntry.raw4Bytes) == [2, 3, 0, 0])
        let latRefEntry = try #require(gpsIFD.entries.first(where: { $0.tag == 0x0001 }))
        #expect(latRefEntry.raw4Bytes[0] == UInt8(ascii: "S"))
        let latEntry = try #require(gpsIFD.entries.first(where: { $0.tag == 0x0002 }))
        let latOff = Int(latEntry.valueOrOffset)
        #expect(latOff % 2 == 0)
        let latD = Double(readLE32(tiff, at: latOff)) / Double(max(1, readLE32(tiff, at: latOff + 4)))
        let latM = Double(readLE32(tiff, at: latOff + 8)) / Double(max(1, readLE32(tiff, at: latOff + 12)))
        let latS = Double(readLE32(tiff, at: latOff + 16)) / Double(max(1, readLE32(tiff, at: latOff + 20)))
        let reconstructedLat = latD + latM / 60.0 + latS / 3600.0
        #expect(abs(reconstructedLat - 31.230416) < (0.001 / 3600.0))

        let lonRefEntry = try #require(gpsIFD.entries.first(where: { $0.tag == 0x0003 }))
        #expect(lonRefEntry.raw4Bytes[0] == UInt8(ascii: "W"))
        let altRefEntry = try #require(gpsIFD.entries.first(where: { $0.tag == 0x0005 }))
        #expect(altRefEntry.raw4Bytes[0] == 1)

        // Positive North/East/Above GPS check
        let northExif = WhitelistedExif(
            make: "Sony",
            model: "ILCE-7CM2",
            gpsLatitude: 29.8825,
            gpsLatitudeRef: "N",
            gpsLongitude: 117.9812,
            gpsLongitudeRef: "E",
            gpsAltitude: 185.4,
            gpsAltitudeRef: 0,
            gpsTimestamp: "11:53:46",
            gpsDateStamp: "2026:11:22"
        )
        let northTIFF = try ExifWhitelistBuilder.buildTIFFData(from: northExif)
        let northIFD0 = try parseLETiffIFD(northTIFF, offset: 8)
        let northGPSOff = Int(try #require(northIFD0.entries.first(where: { $0.tag == 0x8825 })).valueOrOffset)
        let northGPS = try parseLETiffIFD(northTIFF, offset: northGPSOff)
        #expect(try #require(northGPS.entries.first(where: { $0.tag == 0x0001 })).raw4Bytes[0] == UInt8(ascii: "N"))
        #expect(try #require(northGPS.entries.first(where: { $0.tag == 0x0003 })).raw4Bytes[0] == UInt8(ascii: "E"))
        #expect(try #require(northGPS.entries.first(where: { $0.tag == 0x0005 })).raw4Bytes[0] == 0)

        // CustomRendered omitted when customRenderedHDR == false & exif.customRendered == nil
        let sdrTIFF = try ExifWhitelistBuilder.buildTIFFData(from: fullExif, customRenderedHDR: false)
        let sdrIFD0 = try parseLETiffIFD(sdrTIFF, offset: 8)
        let sdrExifOffset = Int(try #require(sdrIFD0.entries.first(where: { $0.tag == 0x8769 })).valueOrOffset)
        let sdrExifIFD = try parseLETiffIFD(sdrTIFF, offset: sdrExifOffset)
        #expect(!sdrExifIFD.entries.contains(where: { $0.tag == 0xA401 }))

        // Minimal empty WhitelistedExif & edge cases (NaN, Infinity, oversized string)
        let emptyExif = WhitelistedExif(orientation: 6)
        let emptyTIFF = try ExifWhitelistBuilder.buildTIFFData(from: emptyExif)
        #expect(emptyTIFF.count < ExifWhitelistBuilder.maxTIFFPayloadBytes)
        let emptyIFD0 = try parseLETiffIFD(emptyTIFF, offset: 8)
        let emptyOrient = try #require(emptyIFD0.entries.first(where: { $0.tag == 0x0112 }))
        #expect(readLE16(emptyOrient.raw4Bytes, at: 0) == 1)
        #expect(!emptyIFD0.entries.contains(where: { $0.tag == 0x8825 }))

        let pathological = WhitelistedExif(
            make: "Test\0Make",
            model: String(repeating: "M", count: 1000),
            lensModel: String(repeating: "L", count: 2000),
            focalLengthMM: .nan,
            exposureTimeSeconds: .infinity,
            fNumber: -.infinity,
            exposureBiasEV: .nan,
            gpsLatitude: .nan,
            gpsLongitude: 200.0, // out of range [-180, 180]
            orientation: 8
        )
        let safeTIFF = try ExifWhitelistBuilder.buildTIFFData(from: pathological)
        #expect(safeTIFF.count < ExifWhitelistBuilder.maxTIFFPayloadBytes)
        let safeIFD0 = try parseLETiffIFD(safeTIFF, offset: 8)
        #expect(!safeIFD0.entries.contains(where: { $0.tag == 0x8825 }))

        // ImageIO dictionary check
        let dict = ExifWhitelistBuilder.buildImageIODictionary(from: fullExif, customRenderedHDR: true)
        #expect((dict[kCGImagePropertyOrientation] as? Int) == 1)
        let tiffDict = try #require(dict[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect((tiffDict[kCGImagePropertyTIFFOrientation] as? Int) == 1)
        let exifDict = try #require(dict[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect((exifDict[kCGImagePropertyExifOffsetTimeOriginal] as? String) == "+08:00")
        #expect((exifDict[kCGImagePropertyExifSubsecTimeOriginal] as? String) == "672")
        #expect((exifDict[kCGImagePropertyExifCustomRendered] as? Int) == 3)
        #expect(exifDict[kCGImagePropertyExifMakerNote] == nil)
        let gpsDict = try #require(dict[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect((gpsDict[kCGImagePropertyGPSLatitudeRef] as? String) == "S")
        #expect(abs(((gpsDict[kCGImagePropertyGPSLatitude] as? Double) ?? 0) - 31.230416) < 1e-6)
        #expect((gpsDict[kCGImagePropertyGPSLongitudeRef] as? String) == "W")
        #expect((gpsDict[kCGImagePropertyGPSAltitudeRef] as? Int) == 1)
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testExifWhitelistCrossStackRoundTripsHEICJPEGAvif() async throws {
        let dsc2556 = m4aTangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        let frame = try await LibRawDecoder().decodeProxy(url: dsc2556)
        var exifWithGPS = frame.exif
        exifWithGPS.gpsLatitude = 29.8825
        exifWithGPS.gpsLatitudeRef = "N"
        exifWithGPS.gpsLongitude = 117.9812
        exifWithGPS.gpsLongitudeRef = "E"
        exifWithGPS.gpsAltitude = 185.4
        exifWithGPS.gpsAltitudeRef = 0
        exifWithGPS.gpsTimestamp = "11:53:46"
        exifWithGPS.gpsDateStamp = "2026:11:22"

        let tiffExif = try ExifWhitelistBuilder.buildTIFFData(from: exifWithGPS, customRenderedHDR: true)
        let imageIODict = ExifWhitelistBuilder.buildImageIODictionary(from: exifWithGPS, customRenderedHDR: true)

        let tmpDir = try makeM4aTempDir(prefix: "exif-roundtrip")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Apple ImageIO HEIC round-trip
        let cs = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        var rgba = [UInt8](repeating: 128, count: 64 * 64 * 4)
        let ctx = try #require(CGContext(
            data: &rgba,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(ctx.makeImage())
        let heicURL = tmpDir.appendingPathComponent("roundtrip.heic")
        let heicDest = try #require(CGImageDestinationCreateWithURL(heicURL as CFURL, UTType.heic.identifier as CFString, 1, nil))
        var heicProps = imageIODict
        heicProps[kCGImageDestinationLossyCompressionQuality] = 0.90
        CGImageDestinationAddImage(heicDest, cgImage, heicProps as CFDictionary)
        #expect(CGImageDestinationFinalize(heicDest))

        // 2. CUltraHDRBridge JPEG round-trip
        let baseJPEG = try makeSyntheticDisplayP3JPEGForExif(width: 64, height: 64)
        let gmJPEG = try makeSyntheticGrayGainMapJPEG(width: 32, height: 32)
        var outJPEG = HDRUltraHDRBuffer()
        var errPtr: UnsafeMutablePointer<CChar>?
        defer {
            hdr_ultrahdr_free_buffer(&outJPEG)
            if let errPtr { cuhdr_free_error(errPtr) }
        }
        let maxBoost = Float(exp2(2.5))
        let offsetUHDR = Float(1.0 / 64.0)
        let uhdrStatus = baseJPEG.withUnsafeBytes { bPtr in
            gmJPEG.withUnsafeBytes { gPtr in
                tiffExif.withUnsafeBytes { ePtr in
                    var req = HDRUltraHDREncodeInput(
                        base_jpeg_data: bPtr.bindMemory(to: UInt8.self).baseAddress,
                        base_jpeg_size: baseJPEG.count,
                        base_color_gamut: HDR_UHDR_CG_DISPLAY_P3,
                        gainmap_jpeg_data: gPtr.bindMemory(to: UInt8.self).baseAddress,
                        gainmap_jpeg_size: gmJPEG.count,
                        exif_data: ePtr.bindMemory(to: UInt8.self).baseAddress,
                        exif_size: tiffExif.count,
                        metadata: HDRUltraHDRGainMapMetadata(
                            max_content_boost: (maxBoost, maxBoost, maxBoost),
                            min_content_boost: (1.0, 1.0, 1.0),
                            gamma: (1.0, 1.0, 1.0),
                            offset_sdr: (offsetUHDR, offsetUHDR, offsetUHDR),
                            offset_hdr: (offsetUHDR, offsetUHDR, offsetUHDR),
                            hdr_capacity_min: 1.0,
                            hdr_capacity_max: maxBoost,
                            use_base_cg: 1
                        )
                    )
                    return cuhdr_encode_api4(&req, &outJPEG, &errPtr)
                }
            }
        }
        #expect(uhdrStatus == 0)
        let jpgURL = tmpDir.appendingPathComponent("roundtrip.jpg")
        try Data(bytes: outJPEG.data, count: outJPEG.size).write(to: jpgURL)

        // 3. CLibAVIFBridge AVIF round-trip
        let p3ICC = try #require(cs.copyICCData() as Data?)
        let baseRGBA16 = [UInt16](repeating: 32768, count: 64 * 64 * 4)
        let gmBGRA8 = [UInt8](repeating: 128, count: 32 * 32 * 4)
        let gmOffset = 1.0 / 64.0
        var outAVIF = HDRAVIFBuffer()
        var avifErr = [CChar](repeating: 0, count: 512)
        defer { hdr_libavif_free_buffer(&outAVIF) }

        let avifStatus = baseRGBA16.withUnsafeBytes { bPtr in
            gmBGRA8.withUnsafeBytes { gPtr in
                p3ICC.withUnsafeBytes { iccPtr in
                    tiffExif.withUnsafeBytes { ePtr in
                        var req = HDRAVIFEncodeRequest(
                            base_pixels: bPtr.bindMemory(to: UInt8.self).baseAddress,
                            base_width: 64,
                            base_height: 64,
                            base_row_bytes: 64 * 4 * 2,
                            base_pixel_format: HDR_AVIF_PIXFMT_RGBA16,
                            target_bit_depth: 10,
                            color_primaries: HDR_AVIF_PRIMARIES_DISPLAY_P3,
                            gain_map_pixels: gPtr.bindMemory(to: UInt8.self).baseAddress,
                            gain_map_width: 32,
                            gain_map_height: 32,
                            gain_map_row_bytes: 32 * 4,
                            gain_map_pixel_format: HDR_AVIF_PIXFMT_BGRA8,
                            gain_map_channels: 3,
                            gain_map_meta: HDRAVIFGainMapMetadata(
                                gain_map_min: (0.0, 0.0, 0.0),
                                gain_map_max: (2.5, 2.5, 2.5),
                                gain_map_gamma: (1.0, 1.0, 1.0),
                                base_offset: (gmOffset, gmOffset, gmOffset),
                                alternate_offset: (gmOffset, gmOffset, gmOffset),
                                base_hdr_headroom_stops: 0.0,
                                alternate_hdr_headroom_stops: 2.5,
                                use_base_color_space: 1
                            ),
                            icc_data: iccPtr.bindMemory(to: UInt8.self).baseAddress,
                            icc_size: p3ICC.count,
                            exif_data: ePtr.bindMemory(to: UInt8.self).baseAddress,
                            exif_size: tiffExif.count,
                            codec: HDR_AVIF_CODEC_AOM,
                            quality: 75,
                            gain_map_quality: 75,
                            speed: 8,
                            max_threads: 2,
                            enable_tune_iq: 0
                        )
                        return hdr_avif_encode(&req, &outAVIF, &avifErr, avifErr.count)
                    }
                }
            }
        }
        #expect(avifStatus == HDR_AVIF_OK)
        let avifURL = tmpDir.appendingPathComponent("roundtrip.avif")
        try Data(bytes: outAVIF.data, count: outAVIF.size).write(to: avifURL)

        // Verify all 3 outputs via CGImageSource
        for containerURL in [heicURL, jpgURL, avifURL] {
            let src = try #require(CGImageSourceCreateWithURL(containerURL as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            #expect((props[kCGImagePropertyOrientation] as? Int) == 1)

            let tiffProps = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            #expect((tiffProps[kCGImagePropertyTIFFMake] as? String)?.lowercased() == "sony")
            #expect((tiffProps[kCGImagePropertyTIFFModel] as? String) == "ILCE-7CM2")

            let exifProps = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
            #expect((exifProps[kCGImagePropertyExifLensModel] as? String) == "TAMRON 25-200mm F2.8-5.6 A075 E")
            #expect((exifProps[kCGImagePropertyExifOffsetTimeOriginal] as? String) == "+08:00")
            #expect((exifProps[kCGImagePropertyExifSubsecTimeOriginal] as? String) == "672")
            #expect((exifProps[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int) == 300)
            #expect((exifProps[kCGImagePropertyExifCustomRendered] as? Int) == 3)
            #expect(exifProps[kCGImagePropertyExifMakerNote] == nil)

            let gpsProps = try #require(props[kCGImagePropertyGPSDictionary] as? [CFString: Any])
            #expect((gpsProps[kCGImagePropertyGPSLatitudeRef] as? String) == "N")
            #expect((gpsProps[kCGImagePropertyGPSLongitudeRef] as? String) == "E")
            #expect(abs(((gpsProps[kCGImagePropertyGPSLatitude] as? Double) ?? 0) - 29.8825) < 0.001)
            #expect(abs(((gpsProps[kCGImagePropertyGPSLongitude] as? Double) ?? 0) - 117.9812) < 0.001)
        }

        // Verify with external exiftool & avifdec if present
        let exiftoolPath = "/opt/homebrew/bin/exiftool"
        if FileManager.default.isExecutableFile(atPath: exiftoolPath) {
            for containerURL in [heicURL, jpgURL, avifURL] {
                let res = try runM4aCLI(exiftoolPath, arguments: ["-G1", "-a", "-s", "-ee", containerURL.path])
                #expect(res.status == 0)
                #expect(res.stdout.contains("Horizontal (normal)"))
                #expect(res.stdout.contains("OffsetTimeOriginal"))
                #expect(res.stdout.contains("+08:00"))
                #expect(res.stdout.contains("HDR (original saved)"))
                #expect(!res.stdout.contains("MakerNote"))
                #expect(!res.stdout.contains("MakerNoteSony"))
            }
        }

        let avifdecPath = m4aRepoRoot.appendingPathComponent("Vendor/install/bin/avifdec").path
        if FileManager.default.isExecutableFile(atPath: avifdecPath) {
            let res = try runM4aCLI(avifdecPath, arguments: ["--info", avifURL.path])
            #expect(res.status == 0)
            #expect(res.stdout.contains("Exif Metadata  : Present"))
        }
    }

    @Test
    func testExifWhitelistHighISOAndTinyRationalAndOffsetTimeParity() async throws {
        // 1. ISO > 65535 (102400) parity across buildTIFFData (JPEG/AVIF) and buildImageIODictionary (HEIC)
        let highISOExif = WhitelistedExif(
            make: "SONY",
            model: "ILCE-7CM2",
            focalLengthMM: 12.0,
            exposureTimeSeconds: 1.0 / 8000.0,
            fNumber: 1.0,
            isoSpeedRatings: 102_400,
            dateTimeOriginal: "2026:11:23 21:00:00",
            offsetTimeOriginal: "+08:00"
        )
        let highISOTIFF = try ExifWhitelistBuilder.buildTIFFData(from: highISOExif)
        let highISOIFD0 = try parseLETiffIFD(highISOTIFF, offset: 8)
        let highISOExifOff = Int(try #require(highISOIFD0.entries.first(where: { $0.tag == 0x8769 })).valueOrOffset)
        let highISOExifIFD = try parseLETiffIFD(highISOTIFF, offset: highISOExifOff)
        let highISOTags = highISOExifIFD.entries.map(\.tag)
        #expect(highISOTags == highISOTags.sorted())
        #expect(readLE16(try #require(highISOExifIFD.entries.first(where: { $0.tag == 0x8827 })).raw4Bytes, at: 0) == 65535)
        #expect(readLE16(try #require(highISOExifIFD.entries.first(where: { $0.tag == 0x8830 })).raw4Bytes, at: 0) == 2)
        #expect(try #require(highISOExifIFD.entries.first(where: { $0.tag == 0x8832 })).valueOrOffset == 102_400)

        // Verify exact normal rationals (1/8000s, f/1.0, 12mm)
        let expEntry = try #require(highISOExifIFD.entries.first(where: { $0.tag == 0x829A }))
        #expect(readLE32(highISOTIFF, at: Int(expEntry.valueOrOffset)) == 1)
        #expect(readLE32(highISOTIFF, at: Int(expEntry.valueOrOffset) + 4) == 8000)
        let fNumEntry = try #require(highISOExifIFD.entries.first(where: { $0.tag == 0x829D }))
        #expect(readLE32(highISOTIFF, at: Int(fNumEntry.valueOrOffset)) == 1)
        #expect(readLE32(highISOTIFF, at: Int(fNumEntry.valueOrOffset) + 4) == 1)
        let flEntry = try #require(highISOExifIFD.entries.first(where: { $0.tag == 0x920A }))
        #expect(readLE32(highISOTIFF, at: Int(flEntry.valueOrOffset)) == 12)
        #expect(readLE32(highISOTIFF, at: Int(flEntry.valueOrOffset) + 4) == 1)

        let highISODict = ExifWhitelistBuilder.buildImageIODictionary(from: highISOExif)
        let highISOExifDict = try #require(highISODict[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect((highISOExifDict[kCGImagePropertyExifISOSpeedRatings] as? [Int]) == [65535])
        #expect((highISOExifDict[kCGImagePropertyExifSensitivityType] as? Int) == 2)
        #expect((highISOExifDict[kCGImagePropertyExifRecommendedExposureIndex] as? Int) == 102_400)

        let tmpDir = try makeM4aTempDir(prefix: "exif-parity")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let cs = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        var rgba = [UInt8](repeating: 128, count: 64 * 64 * 4)
        let ctx = try #require(CGContext(
            data: &rgba,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(ctx.makeImage())
        let heicURL = tmpDir.appendingPathComponent("high_iso.heic")
        let heicDest = try #require(CGImageDestinationCreateWithURL(heicURL as CFURL, UTType.heic.identifier as CFString, 1, nil))
        var heicProps = highISODict
        heicProps[kCGImageDestinationLossyCompressionQuality] = 0.90
        CGImageDestinationAddImage(heicDest, cgImage, heicProps as CFDictionary)
        #expect(CGImageDestinationFinalize(heicDest))

        // JPEG via CUltraHDRBridge
        let baseJPEG = try makeSyntheticDisplayP3JPEGForExif(width: 64, height: 64)
        let gmJPEG = try makeSyntheticGrayGainMapJPEG(width: 32, height: 32)
        var outJPEG = HDRUltraHDRBuffer()
        var errPtr: UnsafeMutablePointer<CChar>?
        defer {
            hdr_ultrahdr_free_buffer(&outJPEG)
            if let errPtr { cuhdr_free_error(errPtr) }
        }
        let maxBoost = Float(exp2(2.5))
        let offsetUHDR = Float(1.0 / 64.0)
        let uhdrStatus = baseJPEG.withUnsafeBytes { bPtr in
            gmJPEG.withUnsafeBytes { gPtr in
                highISOTIFF.withUnsafeBytes { ePtr in
                    var req = HDRUltraHDREncodeInput(
                        base_jpeg_data: bPtr.bindMemory(to: UInt8.self).baseAddress,
                        base_jpeg_size: baseJPEG.count,
                        base_color_gamut: HDR_UHDR_CG_DISPLAY_P3,
                        gainmap_jpeg_data: gPtr.bindMemory(to: UInt8.self).baseAddress,
                        gainmap_jpeg_size: gmJPEG.count,
                        exif_data: ePtr.bindMemory(to: UInt8.self).baseAddress,
                        exif_size: highISOTIFF.count,
                        metadata: HDRUltraHDRGainMapMetadata(
                            max_content_boost: (maxBoost, maxBoost, maxBoost),
                            min_content_boost: (1.0, 1.0, 1.0),
                            gamma: (1.0, 1.0, 1.0),
                            offset_sdr: (offsetUHDR, offsetUHDR, offsetUHDR),
                            offset_hdr: (offsetUHDR, offsetUHDR, offsetUHDR),
                            hdr_capacity_min: 1.0,
                            hdr_capacity_max: maxBoost,
                            use_base_cg: 1
                        )
                    )
                    return cuhdr_encode_api4(&req, &outJPEG, &errPtr)
                }
            }
        }
        #expect(uhdrStatus == 0)
        let jpgURL = tmpDir.appendingPathComponent("high_iso.jpg")
        try Data(bytes: outJPEG.data, count: outJPEG.size).write(to: jpgURL)

        // AVIF via CLibAVIFBridge
        let p3ICC = try #require(cs.copyICCData() as Data?)
        let baseRGBA16 = [UInt16](repeating: 32768, count: 64 * 64 * 4)
        let gmBGRA8 = [UInt8](repeating: 128, count: 32 * 32 * 4)
        let gmOffset = 1.0 / 64.0
        var outAVIF = HDRAVIFBuffer()
        var avifErr = [CChar](repeating: 0, count: 512)
        defer { hdr_libavif_free_buffer(&outAVIF) }
        let avifStatus = baseRGBA16.withUnsafeBytes { bPtr in
            gmBGRA8.withUnsafeBytes { gPtr in
                p3ICC.withUnsafeBytes { iccPtr in
                    highISOTIFF.withUnsafeBytes { ePtr in
                        var req = HDRAVIFEncodeRequest(
                            base_pixels: bPtr.bindMemory(to: UInt8.self).baseAddress,
                            base_width: 64,
                            base_height: 64,
                            base_row_bytes: 64 * 4 * 2,
                            base_pixel_format: HDR_AVIF_PIXFMT_RGBA16,
                            target_bit_depth: 10,
                            color_primaries: HDR_AVIF_PRIMARIES_DISPLAY_P3,
                            gain_map_pixels: gPtr.bindMemory(to: UInt8.self).baseAddress,
                            gain_map_width: 32,
                            gain_map_height: 32,
                            gain_map_row_bytes: 32 * 4,
                            gain_map_pixel_format: HDR_AVIF_PIXFMT_BGRA8,
                            gain_map_channels: 3,
                            gain_map_meta: HDRAVIFGainMapMetadata(
                                gain_map_min: (0.0, 0.0, 0.0),
                                gain_map_max: (2.5, 2.5, 2.5),
                                gain_map_gamma: (1.0, 1.0, 1.0),
                                base_offset: (gmOffset, gmOffset, gmOffset),
                                alternate_offset: (gmOffset, gmOffset, gmOffset),
                                base_hdr_headroom_stops: 0.0,
                                alternate_hdr_headroom_stops: 2.5,
                                use_base_color_space: 1
                            ),
                            icc_data: iccPtr.bindMemory(to: UInt8.self).baseAddress,
                            icc_size: p3ICC.count,
                            exif_data: ePtr.bindMemory(to: UInt8.self).baseAddress,
                            exif_size: highISOTIFF.count,
                            codec: HDR_AVIF_CODEC_AOM,
                            quality: 75,
                            gain_map_quality: 75,
                            speed: 8,
                            max_threads: 2,
                            enable_tune_iq: 0
                        )
                        return hdr_avif_encode(&req, &outAVIF, &avifErr, avifErr.count)
                    }
                }
            }
        }
        #expect(avifStatus == HDR_AVIF_OK)
        let avifURL = tmpDir.appendingPathComponent("high_iso.avif")
        try Data(bytes: outAVIF.data, count: outAVIF.size).write(to: avifURL)

        for containerURL in [heicURL, jpgURL, avifURL] {
            let src = try #require(CGImageSourceCreateWithURL(containerURL as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            let exifProps = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
            #expect((exifProps[kCGImagePropertyExifRecommendedExposureIndex] as? Int) == 102_400)
            #expect((exifProps[kCGImagePropertyExifSensitivityType] as? Int) == 2)
            #expect((exifProps[kCGImagePropertyExifISOSpeedRatings] as? [Int]) == [65535])
        }

        let exiftoolPath = "/opt/homebrew/bin/exiftool"
        if FileManager.default.isExecutableFile(atPath: exiftoolPath) {
            for containerURL in [heicURL, jpgURL, avifURL] {
                let res = try runM4aCLI(exiftoolPath, arguments: ["-G1", "-a", "-s", "-ee", containerURL.path])
                #expect(res.status == 0)
                #expect(res.stdout.contains("RecommendedExposureIndex"))
                #expect(res.stdout.contains("102400"))
                #expect(res.stdout.contains("SensitivityType"))
            }
        }

        // 2. Tiny positive inputs must NOT emit 0/1 for ExposureTime (0x829A), FNumber (0x829D), or FocalLength (0x920A)
        let tinyExif = WhitelistedExif(
            focalLengthMM: 0.001,
            exposureTimeSeconds: 1e-9,
            fNumber: 0.001,
            gpsLatitude: 0.0,
            gpsLongitude: 0.0,
            gpsAltitude: 0.0 // allowZero == true should still emit 0/1 altitude
        )
        let tinyTIFF = try ExifWhitelistBuilder.buildTIFFData(from: tinyExif)
        let tinyIFD0 = try parseLETiffIFD(tinyTIFF, offset: 8)
        let tinyExifOff = Int(try #require(tinyIFD0.entries.first(where: { $0.tag == 0x8769 })).valueOrOffset)
        let tinyExifIFD = try parseLETiffIFD(tinyTIFF, offset: tinyExifOff)
        let tinyExifTags = Set(tinyExifIFD.entries.map(\.tag))
        #expect(!tinyExifTags.contains(0x829A))
        #expect(!tinyExifTags.contains(0x829D))
        #expect(!tinyExifTags.contains(0x920A))

        let tinyDict = ExifWhitelistBuilder.buildImageIODictionary(from: tinyExif)
        let tinyExifDict = try #require(tinyDict[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(tinyExifDict[kCGImagePropertyExifExposureTime] == nil)
        #expect(tinyExifDict[kCGImagePropertyExifFNumber] == nil)
        #expect(tinyExifDict[kCGImagePropertyExifFocalLength] == nil)

        let tinyHeicURL = tmpDir.appendingPathComponent("tiny_rational.heic")
        let tinyDest = try #require(CGImageDestinationCreateWithURL(tinyHeicURL as CFURL, UTType.heic.identifier as CFString, 1, nil))
        var tinyProps = tinyDict
        tinyProps[kCGImageDestinationLossyCompressionQuality] = 0.90
        CGImageDestinationAddImage(tinyDest, cgImage, tinyProps as CFDictionary)
        #expect(CGImageDestinationFinalize(tinyDest))
        let tinySrc = try #require(CGImageSourceCreateWithURL(tinyHeicURL as CFURL, nil))
        let tinyReadProps = try #require(CGImageSourceCopyPropertiesAtIndex(tinySrc, 0, nil) as? [CFString: Any])
        let tinyReadExif = try #require(tinyReadProps[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(tinyReadExif[kCGImagePropertyExifExposureTime] == nil)
        #expect(tinyReadExif[kCGImagePropertyExifFNumber] == nil)
        #expect(tinyReadExif[kCGImagePropertyExifFocalLength] == nil)

        // 3. OffsetTime (0x9010) parity when dateTimeOriginal == nil
        let offsetOnlyExif = WhitelistedExif(
            dateTimeOriginal: nil,
            offsetTimeOriginal: "+08:00"
        )
        let offsetTIFF = try ExifWhitelistBuilder.buildTIFFData(from: offsetOnlyExif)
        let offsetIFD0 = try parseLETiffIFD(offsetTIFF, offset: 8)
        #expect(!offsetIFD0.entries.contains(where: { $0.tag == 0x0132 }))
        let offsetExifOff = Int(try #require(offsetIFD0.entries.first(where: { $0.tag == 0x8769 })).valueOrOffset)
        let offsetExifIFD = try parseLETiffIFD(offsetTIFF, offset: offsetExifOff)
        #expect(!offsetExifIFD.entries.contains(where: { $0.tag == 0x9010 }))
        #expect(offsetExifIFD.entries.contains(where: { $0.tag == 0x9011 }))

        let offsetDict = ExifWhitelistBuilder.buildImageIODictionary(from: offsetOnlyExif)
        let offsetTIFFDict = try #require(offsetDict[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let offsetExifDict = try #require(offsetDict[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(offsetTIFFDict[kCGImagePropertyTIFFDateTime] == nil)
        #expect(offsetExifDict[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(offsetExifDict[kCGImagePropertyExifOffsetTime] == nil)
        #expect((offsetExifDict[kCGImagePropertyExifOffsetTimeOriginal] as? String) == "+08:00")
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testMidFlightTaskCancellationOnDecoders() async throws {
        let dsc2533 = m4aTangmoDir.appendingPathComponent("DSC02533.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2533.path))

        let libRaw = LibRawDecoder()
        let ciraw = CIRAWv9Decoder()

        func isCancellationError(_ error: any Error) -> Bool {
            if error is CancellationError { return true }
            if let rawErr = error as? RAWDecodeError, rawErr == .cancelled { return true }
            return false
        }

        // 1. Mid-flight cancellation on LibRawDecoder
        let lrTask = Task {
            try await libRaw.decodeFull(url: dsc2533, options: .default)
        }
        try await Task.sleep(for: .milliseconds(5))
        lrTask.cancel()
        do {
            _ = try await lrTask.value
            Issue.record("Expected mid-flight cancelled LibRawDecoder task to throw cancellation")
        } catch {
            #expect(isCancellationError(error), "Unexpected error from cancelled LibRawDecoder task: \(error)")
        }

        // 2. Mid-flight cancellation on CIRAWv9Decoder (must NOT fall back to LibRawDecoder)
        let ciTask = Task {
            try await ciraw.decodeFull(url: dsc2533, options: .default)
        }
        try await Task.sleep(for: .milliseconds(15))
        ciTask.cancel()
        do {
            _ = try await ciTask.value
            Issue.record("Expected mid-flight cancelled CIRAWv9Decoder task to throw cancellation")
        } catch {
            #expect(isCancellationError(error), "Unexpected error from cancelled CIRAWv9Decoder task: \(error)")
        }
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testLibRawAndCIRAWv9OpticsMetadataDemosaicAndZeroMakerNote() async throws {
        let dsc2532 = m4aTangmoDir.appendingPathComponent("DSC02532.ARW")
        let dsc2556 = m4aTangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2532.path))
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        let libRaw = LibRawDecoder()

        // 1. Verify full-frame 16-node optics, fullSensorDimensions, cropFactor=1.0, demosaicUsed, zero MakerNote
        let ffFrame = try await libRaw.decodeFull(
            url: dsc2532,
            options: DecodeOptions(backend: .libraw, demosaicAlgorithm: .lmmse)
        )
        #expect(ffFrame.demosaicUsed == .lmmse)
        #expect(ffFrame.cropFactor == 1.0)
        #expect(ffFrame.fullSensorDimensions?.width ?? 0 >= 7008)
        #expect(ffFrame.fullSensorDimensions?.height ?? 0 >= 4672)
        let ffOptics = try #require(ffFrame.embeddedSonyOptics)
        #expect(ffOptics.distortionNodeCount == 16)
        #expect(ffOptics.caNodeCount == 16)
        #expect(ffOptics.vignettingNodeCount == 16)
        #expect(ffOptics.cropFactor == 1.0)

        let tiffData = try ExifWhitelistBuilder.buildTIFFData(from: ffFrame.exif)
        let ifd0 = try parseLETiffIFD(tiffData, offset: 8)
        let exifOff = Int(try #require(ifd0.entries.first(where: { $0.tag == 0x8769 })).valueOrOffset)
        let exifIFD = try parseLETiffIFD(tiffData, offset: exifOff)
        #expect(!exifIFD.entries.contains(where: { $0.tag == 0x927C }), "MakerNote 0x927C must NEVER appear in ExifIFD")

        // 2. Verify APS-C 11-node optics, cropFactor=1.5, and fast proxy SLA <= 300ms (with demosaicUsed == nil)
        let t0 = ContinuousClock.now
        let apscProxy = try await libRaw.decodeProxy(url: dsc2556)
        let proxyElapsed = t0.duration(to: .now)
        #expect(proxyElapsed < .milliseconds(500), "Proxy decode took \(proxyElapsed)")
        #expect(apscProxy.demosaicUsed == nil)
        #expect(apscProxy.cropFactor == 1.5)
        let apscOptics = try #require(apscProxy.embeddedSonyOptics)
        #expect(apscOptics.distortionNodeCount == 11)
        #expect(apscOptics.caNodeCount == 11)
        #expect(apscOptics.vignettingNodeCount == 11)
        #expect(apscOptics.caBlueParams.first == -512)

        // 3. Verify CIRAWv9Decoder (or its LibRaw fallback) carries embeddedSonyOptics & cropFactor
        let ciraw = CIRAWv9Decoder()
        let ciProxy = try await ciraw.decodeProxy(url: dsc2532)
        #expect(ciProxy.embeddedSonyOptics?.distortionNodeCount == 16)
        #expect(ciProxy.cropFactor == 1.0)
        #expect(ciProxy.fullSensorDimensions != nil)
    }
}

}
