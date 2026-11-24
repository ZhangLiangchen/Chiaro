import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import ChiaroCore

private let m4bTangmoDir = TestFixtures.sampleDirectory
private let m4bRepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ChiaroCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // Chiaro

private func makeM4bTempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func runM4bCLI(
    _ executablePath: String,
    arguments: [String],
    environment: [String: String]? = nil
) throws -> (status: Int32, stdout: String, stderr: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executablePath)
    proc.arguments = arguments
    if let environment {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment {
            env[k] = v
        }
        proc.environment = env
    }
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

private func exiftoolJSON(for fileURL: URL) throws -> [String: Any]? {
    let exiftoolPath = "/opt/homebrew/bin/exiftool"
    guard FileManager.default.isExecutableFile(atPath: exiftoolPath) else {
        return nil
    }
    let res = try runM4bCLI(exiftoolPath, arguments: ["-G1", "-a", "-s", "-ee", "-j", fileURL.path])
    try #require(res.status == 0, "exiftool failed: \(res.stderr)")
    let data = Data(res.stdout.utf8)
    let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    return arr?.first
}

private func hasLeftoverTmpFiles(in dir: URL) throws -> Bool {
    let contents = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil,
        options: []
    )
    return contents.contains { $0.lastPathComponent.contains(".tmp") }
}

private func makeSyntheticCGImage(
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
                let rowOff = y * width * 4
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
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

private func makeSyntheticGainMap(
    width: Int,
    height: Int,
    channels: GainMapChannels,
    gainMapMin: Double = 0.0,
    gainMapMax: Double = 2.5,
    headroomStops: Double = 2.5
) -> GainMapResult {
    let gmW = max(2, width / 2)
    let gmH = max(2, height / 2)
    let bpp = (channels == .mono1ch) ? 1 : 4
    let bpr = gmW * bpp
    var data = Data(count: bpr * gmH)
    data.withUnsafeMutableBytes { raw in
        guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for y in 0..<gmH {
            for x in 0..<gmW {
                let q = UInt8((x * 255) / max(1, gmW - 1))
                if channels == .mono1ch {
                    ptr[y * bpr + x] = q
                } else {
                    let idx = y * bpr + x * 4
                    ptr[idx + 0] = q
                    ptr[idx + 1] = q
                    ptr[idx + 2] = q
                    ptr[idx + 3] = 255
                }
            }
        }
    }
    let count = (channels == .mono1ch) ? 1 : 3
    let buffer = GainMapBuffer(width: gmW, height: gmH, channels: channels, bytesPerRow: bpr, data: data)
    let metadata = GainMapMetadata(
        gainMapMin: Array(repeating: gainMapMin, count: count),
        gainMapMax: Array(repeating: gainMapMax, count: count),
        gamma: Array(repeating: 1.0, count: count),
        baseOffset: Array(repeating: GainMapMetadata.symmetricOffset, count: count),
        altOffset: Array(repeating: GainMapMetadata.symmetricOffset, count: count),
        baseHeadroom: .sdr,
        alternateHeadroom: HeadroomStops(log2Value: headroomStops),
        useBaseColorSpace: true
    )
    return GainMapResult(buffer: buffer, metadata: metadata)
}

private func sampleWhitelistedExif(make: String = "SONY", model: String = "ILCE-7CM2") -> WhitelistedExif {
    WhitelistedExif(
        make: make,
        model: model,
        lensMake: "TAMRON",
        lensModel: "TAMRON 25-200mm F2.8-5.6",
        focalLengthMM: 50.0,
        focalLengthIn35mmFilm: 50,
        exposureTimeSeconds: 1.0 / 125.0,
        fNumber: 2.8,
        isoSpeedRatings: 1600,
        exposureBiasEV: 0.0,
        dateTimeOriginal: "2026:11:22 19:30:00",
        offsetTimeOriginal: "+08:00",
        subSecTimeOriginal: "123",
        orientation: 1
    )
}

private func renderTangmoARW(
    filename: String,
    preset: PresetSchema,
    customRenderedHDR: Bool = false,
    maxLongEdgeOverride: Int? = nil,
    generateHLGTexture: Bool = false,
    hlgTargetDims: PixelDimensions? = nil,
    engine: MetalPipelineEngine
) async throws -> RenderedFrame {
    let arwURL = m4bTangmoDir.appendingPathComponent(filename)
    try #require(FileManager.default.fileExists(atPath: arwURL.path), "Missing Tangmo sample \(arwURL.path)")

    let decoder = LibRawDecoder()
    let decoded = try await decoder.decodeFull(
        url: arwURL,
        options: DecodeOptions(
            backend: .libraw,
            highlightMode: preset.developDefaults.highlightReconstruction,
            isProxy: false,
            maxThreadsPerWorker: 4,
            customRenderedHDR: customRenderedHDR
        )
    )

    var params = EffectiveDevelopParams.resolve(preset: preset)
    if let edge = maxLongEdgeOverride {
        params.maxLongEdge = edge
    }

    let spec = RenderOutputSpec(
        targetBitDepth: preset.bitDepth,
        baseColorSpace: preset.baseColorSpace,
        gainMapChannels: preset.gainMapChannels,
        gainMapResolution: preset.gainMapResolution,
        gainMapGamma: preset.gainMapGamma,
        lockLegacyAppleGainMapBounds: preset.compatOptions.writeLegacyAppleHDRGainMap,
        generateHLGTexture: generateHLGTexture,
        hlgTargetDimensions: hlgTargetDims
    )

    return try await engine.render(frame: decoded, params: params, outputSpec: spec)
}

@Suite("ChiaroSerializedSuites", .serialized)
enum ChiaroSerializedSuites {

@Suite("EncodersAndProbesTests", .serialized)
struct EncodersAndProbesTests {

    @Test("HEIC 10-bit 3ch & 1ch legacy dual-write + 3ch dual-write guardrails", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testHEICImageIOEncoderAndGuardrails() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m4b-heic")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let engine = try MetalPipelineEngine()
        let heicEncoder = HEICImageIOEncoder()
        let probe = ISO21496Probe()

        // 1. 10-bit Display P3 3ch HEIC from real DSC02533.ARW (customRenderedHDR = true)
        var p3Preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        p3Preset.compatOptions.writeCustomRenderedHDR = true
        let frame3ch = try await renderTangmoARW(
            filename: "DSC02533.ARW",
            preset: p3Preset,
            customRenderedHDR: true,
            maxLongEdgeOverride: 1536,
            engine: engine
        )

        let out3ch = tmpDir.appendingPathComponent("DSC02533_3ch.heic")
        let art3ch = try await heicEncoder.encode(frame: frame3ch, preset: p3Preset, to: out3ch)
        #expect(art3ch.format == .heic)
        #expect(art3ch.fileSizeBytes > 0)
        #expect(try !hasLeftoverTmpFiles(in: tmpDir))

        let rep3ch = try await probe.verify(
            url: out3ch,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: p3Preset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch,
                expectLegacyAppleGainMap: false,
                expectUltrahdrXMP: false
            )
        )
        #expect(rep3ch.passed, "3ch HEIC probe failed: \(rep3ch.checks)")
        #expect(rep3ch.hasISOGainMap)
        #expect(rep3ch.measuredBitDepth == 10)
        #expect(rep3ch.measuredOrientation == 1)

        if let exif = try exiftoolJSON(for: out3ch) {
            #expect((exif["IFD0:Orientation"] as? String) == "Horizontal (normal)")
            #expect(exif["ExifIFD:MakerNote"] == nil)
            let cr = String(describing: exif["ExifIFD:CustomRendered"] ?? "")
            #expect(cr.contains("HDR") || cr == "3")
        }

        // 2. Mandatory Legacy Dual-Write Guard: 3ch + writeLegacyAppleHDRGainMap MUST throw cleanly
        var illegalPreset = p3Preset
        illegalPreset.compatOptions.writeLegacyAppleHDRGainMap = true
        let illegalOut = tmpDir.appendingPathComponent("illegal_3ch_compat.heic")
        await #expect(throws: HEICEncodeError.legacyDualWriteUnsupportedFor3Channel) {
            _ = try await heicEncoder.encode(frame: frame3ch, preset: illegalPreset, to: illegalOut)
        }
        #expect(!FileManager.default.fileExists(atPath: illegalOut.path))
        #expect(try !hasLeftoverTmpFiles(in: tmpDir))

        // Also reject when preset is mono1ch but frame.gainMap.buffer is rgb3ch
        let compatPreset = try PresetLoader.loadBuiltIn(id: .appleHEICCompat)
        await #expect(throws: HEICEncodeError.legacyDualWriteUnsupportedFor3Channel) {
            _ = try await heicEncoder.encode(frame: frame3ch, preset: compatPreset, to: illegalOut)
        }

        // 3. 10-bit Display P3 1ch legacy dual-write on Rotate 270 CW DSC02540.ARW
        let frame1ch = try await renderTangmoARW(
            filename: "DSC02540.ARW",
            preset: compatPreset,
            maxLongEdgeOverride: 1536,
            engine: engine
        )
        #expect(frame1ch.height > frame1ch.width)

        let out1ch = tmpDir.appendingPathComponent("DSC02540_compat.heic")
        let art1ch = try await heicEncoder.encode(frame: frame1ch, preset: compatPreset, to: out1ch)
        #expect(art1ch.fileSizeBytes > 0)

        let rep1ch = try await probe.verify(
            url: out1ch,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: compatPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .mono1ch,
                expectLegacyAppleGainMap: true,
                expectUltrahdrXMP: false
            )
        )
        #expect(rep1ch.passed, "1ch compat HEIC probe failed: \(rep1ch.checks)")
        #expect(rep1ch.measuredOrientation == 1)

        // Verify CPU endpoint locking when an unlocked 1ch GainMap is passed to dual-write
        var unlockedFrame = frame1ch
        unlockedFrame.gainMap.metadata.gainMapMin = [-0.4]
        unlockedFrame.gainMap.metadata.gainMapMax = [1.8]
        let outLocked = tmpDir.appendingPathComponent("DSC02540_relocked.heic")
        _ = try await heicEncoder.encode(frame: unlockedFrame, preset: compatPreset, to: outLocked)
        let repLocked = try await probe.verify(
            url: outLocked,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: compatPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .mono1ch,
                expectLegacyAppleGainMap: true
            )
        )
        #expect(repLocked.passed)

        // Check via CGImageSource that HDRToneMap XMP reports locked [0.0, 2.5]
        let lockedSrc = try #require(CGImageSourceCreateWithURL(outLocked as CFURL, nil))
        let aux = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(lockedSrc, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any])
        let auxMeta = aux[kCGImageAuxiliaryDataInfoMetadata as String] as! CGImageMetadata
        let xmpData = try #require(CGImageMetadataCreateXMPData(auxMeta, nil) as Data?)
        let xmpStr = String(decoding: xmpData, as: UTF8.self)
        #expect(xmpStr.contains("<HDRToneMap:GainMapMin>0") || xmpStr.contains("GainMapMin=\"0"))
    }

    @Test("JPEG dual modes: 1ch Ultra HDR v1.1 + closed-loop B-hat + MB retry + 3ch pure ISO", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testJPEGDualEncoderModesAndRetry() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m4b-jpeg")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let engine = try MetalPipelineEngine()
        let jpegEncoder = JPEGDualEncoder(metalEngine: engine)
        let probe = ISO21496Probe()

        // 1. Xiaohongshu preset on real high-ISO DSC02533.ARW (1ch Ultra HDR v1.1 + closed-loop B-hat + <= 4MB)
        let xhsPreset = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
        let xhsFrame = try await renderTangmoARW(
            filename: "DSC02533.ARW",
            preset: xhsPreset,
            engine: engine
        )
        let xhsURL = tmpDir.appendingPathComponent("DSC02533_xhs.jpg")
        let xhsArt = try await jpegEncoder.encode(frame: xhsFrame, preset: xhsPreset, to: xhsURL)
        #expect(xhsArt.fileSizeBytes > 0)
        #expect(xhsArt.fileSizeBytes <= 4_194_304)
        #expect(try !hasLeftoverTmpFiles(in: tmpDir))

        let xhsRep = try await probe.verify(
            url: xhsURL,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: xhsPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch,
                maxFileBytes: 4_194_304,
                expectLegacyAppleGainMap: false,
                expectUltrahdrXMP: true
            )
        )
        #expect(xhsRep.passed, "Xiaohongshu JPEG probe failed: \(xhsRep.checks)")

        let uhdrApp = m4bRepoRoot.appendingPathComponent("Vendor/install/bin/ultrahdr_app").path
        if FileManager.default.isExecutableFile(atPath: uhdrApp) {
            let uhdrRes = try runM4bCLI(uhdrApp, arguments: ["-m", "1", "-j", xhsURL.path, "-P"])
            #expect(uhdrRes.status == 0, "ultrahdr_app -P failed: \(uhdrRes.stderr)\n\(uhdrRes.stdout)")
            #expect(uhdrRes.stdout.contains("Ultra HDR Image: Yes"))
        }

        if let exif = try exiftoolJSON(for: xhsURL) {
            #expect((exif["APP2:UniformResourceName"] as? String) == "urn:iso:std:iso:ts:21496:-1")
            #expect((exif["MPF0:NumberOfImages"] as? Int) == 2)
            #expect(exif.keys.contains { $0.hasPrefix("XMP-hdrgm:") })
            #expect((exif["IFD0:Orientation"] as? String) == "Horizontal (normal)")
            #expect(exif["ExifIFD:MakerNote"] == nil)
            #expect(!exif.keys.contains { $0.hasPrefix("Apple:") })
        }

        // 2. tri_format fan-out: 16-bit Display P3 sdrCGImage + rgb3ch gainMap -> JPEGDualEncoder 1ch Ultra HDR v1.1
        let triPreset = try PresetLoader.loadBuiltIn(id: .triFormat)
        let triFrame = try await renderTangmoARW(
            filename: "DSC02540.ARW",
            preset: triPreset,
            maxLongEdgeOverride: 1536,
            engine: engine
        )
        #expect(triFrame.sdrCGImage.bitsPerComponent == 16)
        #expect(triFrame.gainMap.buffer.channels == .rgb3ch)
        let triJPG = tmpDir.appendingPathComponent("DSC02540_tri.jpg")
        let triArt = try await jpegEncoder.encode(frame: triFrame, preset: triPreset, to: triJPG)
        #expect(triArt.fileSizeBytes > 0)
        let triRep = try await probe.verify(
            url: triJPG,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: triPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch,
                expectUltrahdrXMP: true
            )
        )
        #expect(triRep.passed, "tri_format JPEG fan-out failed: \(triRep.checks)")

        // 3. Size Budget Retry Loop: tighten targetMaxFileBytes below initial Q=0.90 size, verify step-down succeeds
        var tightPreset = xhsPreset
        tightPreset.targetMaxFileBytes = max(120_000, Int(Double(xhsArt.fileSizeBytes) * 0.45))
        let tightURL = tmpDir.appendingPathComponent("DSC02533_tight.jpg")
        let tightArt = try await jpegEncoder.encode(frame: xhsFrame, preset: tightPreset, to: tightURL)
        #expect(tightArt.fileSizeBytes <= Int64(tightPreset.targetMaxFileBytes!))
        let tightRep = try await probe.verify(
            url: tightURL,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: tightPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch,
                maxFileBytes: tightPreset.targetMaxFileBytes,
                expectUltrahdrXMP: true
            )
        )
        #expect(tightRep.passed, "Tight-budget JPEG probe failed: \(tightRep.checks)")

        // Impossible budget -> typed error + zero leftover temp files
        var impossiblePreset = xhsPreset
        impossiblePreset.targetMaxFileBytes = 512
        let impossibleURL = tmpDir.appendingPathComponent("impossible.jpg")
        do {
            _ = try await jpegEncoder.encode(frame: xhsFrame, preset: impossiblePreset, to: impossibleURL)
            Issue.record("Expected JPEGEncodeError.exceededMaxFileBytes")
        } catch let err as JPEGEncodeError {
            if case .exceededMaxFileBytes = err {
                // expected
            } else {
                Issue.record("Unexpected JPEGEncodeError: \(err)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: impossibleURL.path))
        #expect(try !hasLeftoverTmpFiles(in: tmpDir))

        // 4. 3ch RGB Pure ISO APP2 + MPF JPEG (writeUltrahdrXMP == false): NO hdrgm: XMP, NO Apple MakerNote 33/48
        var pure3chPreset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        pure3chPreset.id = "pure_3ch_jpg"
        pure3chPreset.outputFormats = [.jpeg]
        pure3chPreset.bitDepth = .bit8
        pure3chPreset.compatOptions.writeUltrahdrXMP = false
        pure3chPreset.compatOptions.writeLegacyAppleHDRGainMap = false

        let pure3chCG = try makeSyntheticCGImage(width: 512, height: 384, bitDepth: .bit8, colorSpace: .displayP3)
        let pure3chGM = makeSyntheticGainMap(width: 512, height: 384, channels: .rgb3ch)
        let pure3chFrame = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("synthetic.arw"),
            width: 512,
            height: 384,
            baseColorSpace: .displayP3,
            sdrCGImage: pure3chCG,
            gainMap: pure3chGM,
            exif: sampleWhitelistedExif()
        )
        let pure3chURL = tmpDir.appendingPathComponent("pure_3ch.jpg")
        _ = try await jpegEncoder.encode(frame: pure3chFrame, preset: pure3chPreset, to: pure3chURL)
        let pure3chRep = try await probe.verify(
            url: pure3chURL,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: pure3chPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .rgb3ch,
                expectLegacyAppleGainMap: false,
                expectUltrahdrXMP: false
            )
        )
        #expect(pure3chRep.passed, "3ch pure ISO JPEG failed: \(pure3chRep.checks)")
        if let exif = try exiftoolJSON(for: pure3chURL) {
            #expect((exif["APP2:UniformResourceName"] as? String) == "urn:iso:std:iso:ts:21496:-1")
            #expect((exif["MPF0:NumberOfImages"] as? Int) == 2)
            #expect(!exif.keys.contains { $0.hasPrefix("XMP-hdrgm:") })
            #expect(!exif.keys.contains { $0.hasPrefix("Apple:") })
            #expect(exif["ExifIFD:MakerNote"] == nil)
        }

        // 5. CPU BGRA->L008 fallback when hdrLinearTexture == nil & gainMap == rgb3ch -> 1ch Ultra HDR JPEG
        let cpuFallbackURL = tmpDir.appendingPathComponent("cpu_fallback.jpg")
        _ = try await jpegEncoder.encode(frame: pure3chFrame, preset: xhsPreset, to: cpuFallbackURL)
        let cpuFallbackRep = try await probe.verify(
            url: cpuFallbackURL,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: xhsPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch,
                expectUltrahdrXMP: true
            )
        )
        #expect(cpuFallbackRep.passed, "CPU BGRA->L008 fallback failed: \(cpuFallbackRep.checks)")
    }

    @Test("AVIF Grid Tiling on Tangmo ARW + 61MP 9504x6336 (4x3) and 6336x9504 (3x4) boundaries", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testAVIFGridEncoderAnd61MPBoundaries() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m4b-avif")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let engine = try MetalPipelineEngine()
        let avifEncoder = AVIFGridEncoder(speed: 8, maxThreads: 4)
        let probe = ISO21496Probe()
        let avifPreset = try PresetLoader.loadBuiltIn(id: .avifArchive)

        let avifdec = m4bRepoRoot.appendingPathComponent("Vendor/install/bin/avifdec").path
        let avifgm = m4bRepoRoot.appendingPathComponent("Vendor/install/bin/avifgainmaputil").path

        // 1. Real Tangmo landscape DSC02533.ARW (7008x4672 -> 4x2 grid) & portrait DSC02540.ARW (4672x7008 -> 2x4 grid)
        for (arwName, expCols, expRows) in [("DSC02533.ARW", 4, 2), ("DSC02540.ARW", 2, 4)] {
            let rendered = try await renderTangmoARW(
                filename: arwName,
                preset: avifPreset,
                engine: engine
            )
            let outURL = tmpDir.appendingPathComponent("\(arwName).avif")
            let art = try await avifEncoder.encode(frame: rendered, preset: avifPreset, to: outURL)
            #expect(art.format == .avif)
            #expect(art.usedGridTiling == true)
            #expect(art.gridColumns == expCols)
            #expect(art.gridRows == expRows)
            #expect(try !hasLeftoverTmpFiles(in: tmpDir))

            let rep = try await probe.verify(
                url: outURL,
                expected: ComplianceExpectation(
                    format: .avif,
                    expectedHeadroom: avifPreset.targetHeadroom.toLinear(),
                    expectedBitDepth: .bit10,
                    expectedGainMapChannels: .rgb3ch
                )
            )
            #expect(rep.passed, "AVIF probe failed on \(arwName): \(rep.checks)")
            #expect(rep.measuredBitDepth == 10)
            #expect(rep.measuredOrientation == 1)

            if FileManager.default.isExecutableFile(atPath: avifdec) {
                let dec = try runM4bCLI(avifdec, arguments: ["--info", "--depth", "16", outURL.path])
                #expect(dec.status == 0)
                #expect(dec.stdout.contains("\(rendered.width)x\(rendered.height)"))
                #expect(dec.stdout.contains("Bit Depth      : 10"))
            }
            if FileManager.default.isExecutableFile(atPath: avifgm) {
                let gm = try runM4bCLI(avifgm, arguments: ["printmetadata", outURL.path])
                #expect(gm.status == 0)
                #expect(gm.stdout.contains("Alternate headroom: 2.5"))
            }
            if let exif = try exiftoolJSON(for: outURL) {
                #expect(exif["ExifIFD:MakerNote"] == nil)
                #expect(!exif.keys.contains { $0.hasPrefix("Apple:") })
            }
        }

        // 2. APS-C DSC02556.ARW 1ch mono1ch AOM path (proxy <= 1920 -> non-grid)
        var monoPreset = avifPreset
        monoPreset.gainMapChannels = .mono1ch
        let frame14MP = try await renderTangmoARW(
            filename: "DSC02556.ARW",
            preset: monoPreset,
            maxLongEdgeOverride: 1536,
            engine: engine
        )
        let monoURL = tmpDir.appendingPathComponent("DSC02556_1ch.avif")
        let monoArt = try await avifEncoder.encode(frame: frame14MP, preset: monoPreset, to: monoURL)
        #expect(monoArt.usedGridTiling == false)
        let monoRep = try await probe.verify(
            url: monoURL,
            expected: ComplianceExpectation(
                format: .avif,
                expectedHeadroom: monoPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .mono1ch
            )
        )
        #expect(monoRep.passed)

        // 3. 61MP Grid Tiling Boundary Tests: 9504x6336 (4x3) and 6336x9504 (3x4)
        for (w, h, expCols, expRows, tag) in [
            (9504, 6336, 4, 3, "61mp_landscape"),
            (6336, 9504, 3, 4, "61mp_portrait"),
        ] {
            let out61 = tmpDir.appendingPathComponent("\(tag).avif")
            let art61: ExportArtifact = try await {
                let cg = try makeSyntheticCGImage(width: w, height: h, bitDepth: .bit8, colorSpace: .displayP3)
                let gm = makeSyntheticGainMap(width: w, height: h, channels: .rgb3ch)
                let frame61 = RenderedFrame(
                    sourceURL: tmpDir.appendingPathComponent("\(tag).arw"),
                    width: w,
                    height: h,
                    baseColorSpace: .displayP3,
                    sdrCGImage: cg,
                    gainMap: gm,
                    exif: sampleWhitelistedExif()
                )
                var fast61Preset = avifPreset
                fast61Preset.quality = 0.70
                fast61Preset.gainMapQuality = 0.70
                return try await avifEncoder.encode(frame: frame61, preset: fast61Preset, to: out61)
            }()

            #expect(art61.usedGridTiling == true)
            #expect(art61.gridColumns == expCols)
            #expect(art61.gridRows == expRows)

            let rep61 = try await probe.verify(
                url: out61,
                expected: ComplianceExpectation(
                    format: .avif,
                    expectedHeadroom: avifPreset.targetHeadroom.toLinear(),
                    expectedBitDepth: .bit10,
                    expectedGainMapChannels: .rgb3ch
                )
            )
            #expect(rep61.passed, "61MP probe failed for \(tag): \(rep61.checks)")
            #expect(rep61.measuredBitDepth == 10)

            if FileManager.default.isExecutableFile(atPath: avifdec) {
                let dec61 = try runM4bCLI(avifdec, arguments: ["--info", "--depth", "16", out61.path])
                #expect(dec61.status == 0)
                #expect(dec61.stdout.contains("\(w)x\(h)"))
                #expect(dec61.stdout.contains("Bit Depth      : 10"))
            }
            if FileManager.default.isExecutableFile(atPath: avifgm) {
                let gm61 = try runM4bCLI(avifgm, arguments: ["printmetadata", out61.path])
                #expect(gm61.status == 0)
                #expect(gm61.stdout.contains("Alternate headroom: 2.5"))
            }
        }
    }

    @Test("Douyin 10-bit HLG MP4 (9:16 & 3:4), ffprobe verification, and 4K/invalid rejection", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testHLGVideoEncoderAndProbe() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m4b-hlg")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let engine = try MetalPipelineEngine()
        let videoEncoder = HLGVideoEncoder(metalEngine: engine)
        let videoProbe = HLGVideoProbe()
        let ffprobePath = "/opt/homebrew/bin/ffprobe"

        // 1. 9:16 (1080x1920, 4.0s, 30fps, 14 Mbps) on DSC02540.ARW
        let hlgPreset9x16 = try PresetLoader.loadBuiltIn(id: .douyinHLGMP4)
        let hlgOpts9x16 = try #require(hlgPreset9x16.hlgVideoOptions)
        let frame9x16 = try await renderTangmoARW(
            filename: "DSC02540.ARW",
            preset: hlgPreset9x16,
            generateHLGTexture: true,
            hlgTargetDims: hlgOpts9x16.aspect.dimensions,
            engine: engine
        )
        let mp4_9x16 = tmpDir.appendingPathComponent("DSC02540_9x16.mp4")
        let art9x16 = try await videoEncoder.encodeVideo(
            frame: frame9x16,
            preset: hlgPreset9x16,
            options: hlgOpts9x16,
            to: mp4_9x16
        )
        #expect(art9x16.format == .hlgMP4)
        #expect(art9x16.fileSizeBytes > 0)
        #expect(try !hasLeftoverTmpFiles(in: tmpDir))

        let rep9x16 = try await videoProbe.verify(
            url: mp4_9x16,
            expected: HLGComplianceExpectation(
                expectedDimensions: PixelDimensions(width: 1080, height: 1920),
                minDurationSeconds: 3.0,
                maxDurationSeconds: 5.0,
                expectedFPS: 30
            )
        )
        #expect(rep9x16.passed, "9:16 HLGVideoProbe failed: \(rep9x16.checks)")
        #expect(rep9x16.measuredBitDepth == 10)

        // Wrong dimensions expectation must fail HLGVideoProbe
        let wrongDimsRep = try await videoProbe.verify(
            url: mp4_9x16,
            expected: HLGComplianceExpectation(
                expectedDimensions: PixelDimensions(width: 1080, height: 1440),
                minDurationSeconds: 3.0,
                maxDurationSeconds: 5.0,
                expectedFPS: 30
            )
        )
        #expect(!wrongDimsRep.passed)
        #expect(wrongDimsRep.checks.contains { $0.name == "dimensions" && $0.severity == .fail })

        if FileManager.default.isExecutableFile(atPath: ffprobePath) {
            let ff = try runM4bCLI(ffprobePath, arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=codec_name,profile,pix_fmt,color_primaries,color_transfer,color_space,color_range,width,height,r_frame_rate,bit_rate:format=duration,bit_rate",
                "-of", "json",
                mp4_9x16.path,
            ])
            #expect(ff.status == 0)
            let json = try JSONSerialization.jsonObject(with: Data(ff.stdout.utf8)) as? [String: Any]
            let streams = json?["streams"] as? [[String: Any]]
            let stream = try #require(streams?.first)
            #expect((stream["codec_name"] as? String) == "hevc")
            #expect((stream["profile"] as? String) == "Main 10")
            #expect((stream["pix_fmt"] as? String) == "yuv420p10le")
            #expect((stream["color_primaries"] as? String) == "bt2020")
            #expect((stream["color_transfer"] as? String) == "arib-std-b67")
            #expect((stream["color_space"] as? String) == "bt2020nc")
            #expect((stream["color_range"] as? String) == "tv")
            #expect((stream["width"] as? Int) == 1080)
            #expect((stream["height"] as? Int) == 1920)
            let brStr = (stream["bit_rate"] as? String) ?? "0"
            let br = Int(brStr) ?? 0
            #expect(br >= 10_800_000 && br <= 17_600_000, "9:16 ffprobe bit_rate=\(br) outside [10.8M, 17.6M]")
        }

        // 2. 3:4 lower boundary (1080x1440, 3.0s, 30fps, 12.0 Mbps) using fallback hdrLinearTexture -> generateHLGPixelBuffer
        var hlgPreset3x4 = hlgPreset9x16
        hlgPreset3x4.cropAspect = .ratio3x4
        let hlgOpts3x4 = HLGVideoOptions(aspect: .portrait3x4, durationSeconds: 3.0, fps: 30, bitrateMbps: 12.0)
        hlgPreset3x4.hlgVideoOptions = hlgOpts3x4
        let frame3x4 = try await renderTangmoARW(
            filename: "DSC02556.ARW",
            preset: hlgPreset3x4,
            generateHLGTexture: false, // exercise HLGVideoEncoder hdrLinearTexture fallback
            engine: engine
        )
        let mp4_3x4 = tmpDir.appendingPathComponent("DSC02556_3x4.mp4")
        _ = try await videoEncoder.encodeVideo(
            frame: frame3x4,
            preset: hlgPreset3x4,
            options: hlgOpts3x4,
            to: mp4_3x4
        )
        let rep3x4 = try await videoProbe.verify(
            url: mp4_3x4,
            expected: HLGComplianceExpectation(
                expectedDimensions: PixelDimensions(width: 1080, height: 1440),
                minDurationSeconds: 3.0,
                maxDurationSeconds: 5.0,
                expectedFPS: 30
            )
        )
        #expect(rep3x4.passed, "3:4 HLGVideoProbe failed: \(rep3x4.checks)")

        if FileManager.default.isExecutableFile(atPath: ffprobePath) {
            let ff = try runM4bCLI(ffprobePath, arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height,bit_rate",
                "-of", "json",
                mp4_3x4.path,
            ])
            #expect(ff.status == 0)
            let json = try JSONSerialization.jsonObject(with: Data(ff.stdout.utf8)) as? [String: Any]
            let stream = try #require((json?["streams"] as? [[String: Any]])?.first)
            #expect((stream["width"] as? Int) == 1080)
            #expect((stream["height"] as? Int) == 1440)
            let br = Int((stream["bit_rate"] as? String) ?? "0") ?? 0
            #expect(br >= 10_800_000 && br <= 17_600_000, "3:4 12Mbps ffprobe bit_rate=\(br) outside [10.8M, 17.6M]")
        }

        // 3. 4K & invalid parameter rejection tests
        var preset4K = hlgPreset9x16
        preset4K.maxLongEdge = 3840
        let rejectedURL = tmpDir.appendingPathComponent("rejected_4k.mp4")
        await #expect(throws: HLGVideoEncodeError.fourKForbidden(3840)) {
            _ = try await videoEncoder.encodeVideo(frame: frame9x16, preset: preset4K, options: hlgOpts9x16, to: rejectedURL)
        }

        // Synthetic 4K 2160x3840 CVPixelBuffer must also be rejected
        var pb4K: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            2160,
            3840,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pb4K
        )
        var frameWith4KPB = frame9x16
        frameWith4KPB.hlgPixelBuffer = SendablePixelBuffer(try #require(pb4K))
        await #expect(throws: HLGVideoEncodeError.fourKForbidden(3840)) {
            _ = try await videoEncoder.encodeVideo(frame: frameWith4KPB, preset: hlgPreset9x16, options: hlgOpts9x16, to: rejectedURL)
        }

        // Invalid duration, FPS, bitrate
        await #expect(throws: HLGVideoEncodeError.invalidDuration(2.0)) {
            _ = try await videoEncoder.encodeVideo(
                frame: frame9x16,
                preset: hlgPreset9x16,
                options: HLGVideoOptions(aspect: .portrait9x16, durationSeconds: 2.0, fps: 30, bitrateMbps: 14.0),
                to: rejectedURL
            )
        }
        await #expect(throws: HLGVideoEncodeError.invalidFPS(60)) {
            _ = try await videoEncoder.encodeVideo(
                frame: frame9x16,
                preset: hlgPreset9x16,
                options: HLGVideoOptions(aspect: .portrait9x16, durationSeconds: 4.0, fps: 60, bitrateMbps: 14.0),
                to: rejectedURL
            )
        }
        await #expect(throws: HLGVideoEncodeError.invalidBitrate(20.0)) {
            _ = try await videoEncoder.encodeVideo(
                frame: frame9x16,
                preset: hlgPreset9x16,
                options: HLGVideoOptions(aspect: .portrait9x16, durationSeconds: 4.0, fps: 30, bitrateMbps: 20.0),
                to: rejectedURL
            )
        }
    }

    @Test("ISO21496Probe & HLGVideoProbe negative and non-finite headroom tests", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testProbeNegativeAndBoundaryCases() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m4b-negprobes")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let probe = ISO21496Probe()
        let videoProbe = HLGVideoProbe()

        // 1. Missing file
        let missingRep = try await probe.verify(
            url: tmpDir.appendingPathComponent("does_not_exist.heic"),
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: exp2(2.5)),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(!missingRep.passed)

        // 2. Plain SDR JPEG (no ISO Gain Map)
        let cg8 = try makeSyntheticCGImage(width: 128, height: 128, bitDepth: .bit8, colorSpace: .displayP3)
        let sdrJPG = tmpDir.appendingPathComponent("plain_sdr.jpg")
        let sdrDest = try #require(CGImageDestinationCreateWithURL(sdrJPG as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(sdrDest, cg8, [
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(sdrDest))

        let sdrRep = try await probe.verify(
            url: sdrJPG,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: LinearHeadroom(multiplier: exp2(2.5)),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch,
                expectUltrahdrXMP: false
            )
        )
        #expect(!sdrRep.passed)
        #expect(!sdrRep.hasISOGainMap)

        // 3. Valid 10-bit HEIC checked against wrong headroom (>2% error), NaN headroom, and tight maxFileBytes
        let heicEncoder = HEICImageIOEncoder()
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let cg16 = try makeSyntheticCGImage(width: 128, height: 128, bitDepth: .bit10, colorSpace: .displayP3)
        let gm3 = makeSyntheticGainMap(width: 128, height: 128, channels: .rgb3ch, headroomStops: 2.5)
        let validFrame = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("synth.arw"),
            width: 128,
            height: 128,
            baseColorSpace: .displayP3,
            sdrCGImage: cg16,
            gainMap: gm3,
            exif: sampleWhitelistedExif()
        )
        let validHEIC = tmpDir.appendingPathComponent("valid.heic")
        _ = try await heicEncoder.encode(frame: validFrame, preset: preset, to: validHEIC)

        // >2% headroom error
        let wrongHeadroomRep = try await probe.verify(
            url: validHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: 4.0), // file has ~5.657
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(!wrongHeadroomRep.passed)

        // .nan headroom expectation & LinearHeadroom(.nan).toStops().toLinear()
        let nanFromStops = LinearHeadroom(multiplier: .nan).toStops().toLinear()
        let nanHeadroomRep1 = try await probe.verify(
            url: validHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: .nan),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(!nanHeadroomRep1.passed)

        let nanHeadroomRep2 = try await probe.verify(
            url: validHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: nanFromStops,
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(!nanHeadroomRep2.passed)

        // Oversized vs maxFileBytes
        let overBudgetRep = try await probe.verify(
            url: validHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: exp2(2.5)),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch,
                maxFileBytes: 100
            )
        )
        #expect(!overBudgetRep.passed)

        // 4. JPEG with Orientation = 6 and Apple MakerNote 33/48 ({MakerApple}) -> fails orientation & zero_makernote
        let badExifJPG = tmpDir.appendingPathComponent("bad_exif.jpg")
        let badDest = try #require(CGImageDestinationCreateWithURL(badExifJPG as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let badProps: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyMakerAppleDictionary: ["33": 1.0, "48": 0.5],
        ]
        CGImageDestinationAddImage(badDest, cg8, badProps as CFDictionary)
        #expect(CGImageDestinationFinalize(badDest))

        let badExifRep = try await probe.verify(
            url: badExifJPG,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: LinearHeadroom(multiplier: 1.0),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch
            )
        )
        #expect(!badExifRep.passed)
        #expect(badExifRep.measuredOrientation == 6)
        #expect(badExifRep.checks.contains { $0.name == "orientation_upright" && $0.severity == .fail })
        #expect(badExifRep.checks.contains { $0.name == "zero_makernote" && $0.severity == .fail })

        // Also test expectUltrahdrXMP mismatch on a pure 3ch ISO JPEG (hasISOGainMap=true, no hdrgm: XMP)
        let jpegEncoder = JPEGDualEncoder()
        var pure3chPreset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        pure3chPreset.id = "neg_3ch_jpg"
        pure3chPreset.outputFormats = [.jpeg]
        pure3chPreset.bitDepth = .bit8
        pure3chPreset.compatOptions.writeUltrahdrXMP = false
        pure3chPreset.compatOptions.writeLegacyAppleHDRGainMap = false
        let pure3chFrame = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("neg3ch.arw"),
            width: 128,
            height: 128,
            baseColorSpace: .displayP3,
            sdrCGImage: cg8,
            gainMap: makeSyntheticGainMap(width: 128, height: 128, channels: .rgb3ch),
            exif: sampleWhitelistedExif()
        )
        let pure3chJPG = tmpDir.appendingPathComponent("neg_3ch.jpg")
        _ = try await jpegEncoder.encode(frame: pure3chFrame, preset: pure3chPreset, to: pure3chJPG)
        let xmpMismatchRep = try await probe.verify(
            url: pure3chJPG,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: LinearHeadroom(multiplier: exp2(2.5)),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .rgb3ch,
                expectUltrahdrXMP: true
            )
        )
        #expect(!xmpMismatchRep.passed)
        #expect(xmpMismatchRep.checks.contains { $0.name == "jpeg_hdrgm_xmp" && $0.severity == .fail })

        // 5. HLGVideoProbe negative test: SDR 8-bit H.264 MP4 -> fails
        let sdrMP4 = tmpDir.appendingPathComponent("sdr_h264.mp4")
        let writer = try AVAssetWriter(outputURL: sdrMP4, fileType: .mp4)
        let sdrSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: sdrSettings)
        var pb8: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1080,
            1920,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pb8
        )
        let sdrPB = try #require(pb8)
        if #available(macOS 27.0, *) {
            let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            let ro = CVReadOnlyPixelBuffer(unsafeBuffer: sdrPB)
            for idx in 0..<90 {
                try await receiver.append(ro, with: CMTime(value: CMTimeValue(idx), timescale: 30))
            }
            receiver.finish()
            writer.endSession(atSourceTime: CMTime(value: 90, timescale: 30))
            await writer.finishWriting()
        } else {
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            for idx in 0..<90 {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                adaptor.append(sdrPB, withPresentationTime: CMTime(value: CMTimeValue(idx), timescale: 30))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: 90, timescale: 30))
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                writer.finishWriting { c.resume() }
            }
        }

        let sdrMP4Rep = try await videoProbe.verify(
            url: sdrMP4,
            expected: HLGComplianceExpectation(
                expectedDimensions: PixelDimensions(width: 1080, height: 1920)
            )
        )
        #expect(!sdrMP4Rep.passed)
        #expect(sdrMP4Rep.checks.contains { $0.name == "codec_hevc" && $0.severity == .fail })
    }

    @Test("HLGVideoEncoder 16.0 Mbps adaptive CBR keeps high-ISO ARW and high-entropy 1080x1440 inside [10.8, 17.6] Mbps", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testHLG16MbpsAdaptiveCBRNoOvershoot() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m4b-hlg16")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let engine = try MetalPipelineEngine()
        let videoEncoder = HLGVideoEncoder(metalEngine: engine)
        let videoProbe = HLGVideoProbe()
        let ffprobePath = "/opt/homebrew/bin/ffprobe"

        // 1. Real high-ISO DSC02533.ARW with +1.5 EV (1080x1920, 16.0 Mbps)
        var hiPreset = try PresetLoader.loadBuiltIn(id: .douyinHLGMP4)
        hiPreset.developDefaults.exposureEV = 1.5
        let hiOpts = HLGVideoOptions(aspect: .portrait9x16, durationSeconds: 3.0, fps: 30, bitrateMbps: 16.0)
        hiPreset.hlgVideoOptions = hiOpts
        let hiFrame = try await renderTangmoARW(
            filename: "DSC02533.ARW",
            preset: hiPreset,
            generateHLGTexture: true,
            hlgTargetDims: hiOpts.aspect.dimensions,
            engine: engine
        )
        let hiMP4 = tmpDir.appendingPathComponent("DSC02533_16mbps.mp4")
        _ = try await videoEncoder.encodeVideo(frame: hiFrame, preset: hiPreset, options: hiOpts, to: hiMP4)
        #expect(try !hasLeftoverTmpFiles(in: tmpDir))

        let hiRep = try await videoProbe.verify(
            url: hiMP4,
            expected: HLGComplianceExpectation(
                expectedDimensions: PixelDimensions(width: 1080, height: 1920),
                minDurationSeconds: 3.0,
                maxDurationSeconds: 5.0,
                expectedFPS: 30
            )
        )
        #expect(hiRep.passed, "DSC02533 +1.5EV 16Mbps HLGVideoProbe failed: \(hiRep.checks)")

        if FileManager.default.isExecutableFile(atPath: ffprobePath) {
            let ff = try runM4bCLI(ffprobePath, arguments: [
                "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=bit_rate", "-of", "default=nw=1:nk=1",
                hiMP4.path,
            ])
            #expect(ff.status == 0)
            let br = Int(ff.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            #expect(br >= 10_800_000 && br <= 17_600_000, "DSC02533 +1.5EV 16Mbps ffprobe bit_rate=\(br) outside [10.8M, 17.6M]")
        }

        // 2. Synthetic high-entropy 1080x1440 10-bit CVPixelBuffer (3.0s, 16.0 Mbps)
        var pbOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1080,
            1440,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pbOpt
        )
        #expect(status == kCVReturnSuccess)
        let noisyPB = try #require(pbOpt)
        CVPixelBufferLockBaseAddress(noisyPB, [])
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for plane in 0..<CVPixelBufferGetPlaneCount(noisyPB) {
            let h = CVPixelBufferGetHeightOfPlane(noisyPB, plane)
            let w = CVPixelBufferGetWidthOfPlane(noisyPB, plane)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(noisyPB, plane)
            if let base = CVPixelBufferGetBaseAddressOfPlane(noisyPB, plane) {
                let u16 = base.assumingMemoryBound(to: UInt16.self)
                let stride16 = bpr / 2
                let count16 = (plane == 0) ? w : w * 2
                for y in 0..<h {
                    let row = y * stride16
                    for x in 0..<count16 {
                        state = state &* 6364136223846793005 &+ 1442695040888963407
                        let v10 = UInt16((state >> 54) & 0x3FF)
                        u16[row + x] = v10 << 6
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(noisyPB, [])

        var synthPreset = hiPreset
        synthPreset.cropAspect = .ratio3x4
        let synthOpts = HLGVideoOptions(aspect: .portrait3x4, durationSeconds: 3.0, fps: 30, bitrateMbps: 16.0)
        synthPreset.hlgVideoOptions = synthOpts
        var synthFrame = hiFrame
        synthFrame.width = 1080
        synthFrame.height = 1440
        synthFrame.hlgPixelBuffer = SendablePixelBuffer(noisyPB)

        let synthMP4 = tmpDir.appendingPathComponent("synthetic_noise_1080x1440_16mbps.mp4")
        _ = try await videoEncoder.encodeVideo(frame: synthFrame, preset: synthPreset, options: synthOpts, to: synthMP4)
        #expect(try !hasLeftoverTmpFiles(in: tmpDir))

        let synthRep = try await videoProbe.verify(
            url: synthMP4,
            expected: HLGComplianceExpectation(
                expectedDimensions: PixelDimensions(width: 1080, height: 1440),
                minDurationSeconds: 3.0,
                maxDurationSeconds: 5.0,
                expectedFPS: 30
            )
        )
        #expect(synthRep.passed, "Synthetic high-entropy 1080x1440 16Mbps HLGVideoProbe failed: \(synthRep.checks)")

        if FileManager.default.isExecutableFile(atPath: ffprobePath) {
            let ff = try runM4bCLI(ffprobePath, arguments: [
                "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=bit_rate", "-of", "default=nw=1:nk=1",
                synthMP4.path,
            ])
            #expect(ff.status == 0)
            let br = Int(ff.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            #expect(br >= 10_800_000 && br <= 17_600_000, "Synthetic high-entropy 16Mbps ffprobe bit_rate=\(br) outside [10.8M, 17.6M]")
        }
    }

    @Test("ISO21496Probe rejects Sony 0x927C MakerNote (JPEG & ISOBMFF), channel mismatch, format mismatch, and rotated MP4", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testProbeComplianceBlindSpotRegressions() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m4b-regressions")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let probe = ISO21496Probe()
        let heicEncoder = HEICImageIOEncoder()
        let jpegEncoder = JPEGDualEncoder()

        // Prepare valid 1ch Ultra HDR JPEG and valid 3ch HEIC + 1ch compat HEIC
        let cg8 = try makeSyntheticCGImage(width: 128, height: 128, bitDepth: .bit8, colorSpace: .displayP3)
        let cg16 = try makeSyntheticCGImage(width: 128, height: 128, bitDepth: .bit10, colorSpace: .displayP3)

        let xhsPreset = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
        let xhsFrame = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("xhs.arw"),
            width: 128,
            height: 128,
            baseColorSpace: .displayP3,
            sdrCGImage: cg8,
            gainMap: makeSyntheticGainMap(width: 128, height: 128, channels: .mono1ch),
            exif: sampleWhitelistedExif()
        )
        let validJPG = tmpDir.appendingPathComponent("valid_xhs.jpg")
        _ = try await jpegEncoder.encode(frame: xhsFrame, preset: xhsPreset, to: validJPG)

        let heic3chPreset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let heic3chFrame = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("heic3.arw"),
            width: 128,
            height: 128,
            baseColorSpace: .displayP3,
            sdrCGImage: cg16,
            gainMap: makeSyntheticGainMap(width: 128, height: 128, channels: .rgb3ch),
            exif: sampleWhitelistedExif()
        )
        let valid3chHEIC = tmpDir.appendingPathComponent("valid_3ch.heic")
        _ = try await heicEncoder.encode(frame: heic3chFrame, preset: heic3chPreset, to: valid3chHEIC)

        let heic1chPreset = try PresetLoader.loadBuiltIn(id: .appleHEICCompat)
        let heic1chFrame = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("heic1.arw"),
            width: 128,
            height: 128,
            baseColorSpace: .displayP3,
            sdrCGImage: cg16,
            gainMap: makeSyntheticGainMap(width: 128, height: 128, channels: .mono1ch),
            exif: sampleWhitelistedExif()
        )
        let valid1chHEIC = tmpDir.appendingPathComponent("valid_1ch.heic")
        _ = try await heicEncoder.encode(frame: heic1chFrame, preset: heic1chPreset, to: valid1chHEIC)

        // 1. Real Sony 0x927C MakerNote rejection via exiftool on copied JPEG
        let exiftoolPath = "/opt/homebrew/bin/exiftool"
        let arwURL = m4bTangmoDir.appendingPathComponent("DSC02533.ARW")
        if FileManager.default.isExecutableFile(atPath: exiftoolPath),
           FileManager.default.fileExists(atPath: arwURL.path) {
            let sonyJPG = tmpDir.appendingPathComponent("real_sony_mk2.jpg")
            try FileManager.default.copyItem(at: validJPG, to: sonyJPG)
            let injectRes = try runM4bCLI(exiftoolPath, arguments: [
                "-overwrite_original",
                "-TagsFromFile", arwURL.path,
                "-EXIF:all", "-MakerNotes:all", "-unsafe",
                "-Orientation=1", "-n",
                sonyJPG.path,
            ])
            #expect(injectRes.status == 0, "exiftool inject failed: \(injectRes.stderr)")

            let sonyRep = try await probe.verify(
                url: sonyJPG,
                expected: ComplianceExpectation(
                    format: .jpeg,
                    expectedHeadroom: xhsPreset.targetHeadroom.toLinear(),
                    expectedBitDepth: .bit8,
                    expectedGainMapChannels: .mono1ch,
                    expectUltrahdrXMP: true
                )
            )
            #expect(!sonyRep.passed)
            #expect(sonyRep.checks.contains { $0.name == "zero_makernote" && $0.severity == .fail })
        }

        // Synthetic ISOBMFF 0x927C MakerNote injection inside HEIC's Exif TIFF payload
        let syntheticISOBMFF = tmpDir.appendingPathComponent("synth_0x927c.heic")
        try FileManager.default.copyItem(at: valid3chHEIC, to: syntheticISOBMFF)
        var heicBytes = try Data(contentsOf: syntheticISOBMFF)
        let exifSig = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        let exifSigRange = try #require(heicBytes.range(of: exifSig))
        let tiffStart = exifSigRange.upperBound
        let isLE = heicBytes[tiffStart] == 0x49 && heicBytes[tiffStart + 1] == 0x49
        // Match full 8-byte ExifIFD entry header for ExifVersion (0x9000, type=7 UNDEFINED, count=4)
        let targetEntryPrefix = isLE
            ? Data([0x00, 0x90, 0x07, 0x00, 0x04, 0x00, 0x00, 0x00])
            : Data([0x90, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x04])
        let makerTag = isLE ? Data([0x7C, 0x92]) : Data([0x92, 0x7C])
        let verTagRange = try #require(heicBytes.range(of: targetEntryPrefix, in: tiffStart..<heicBytes.count))
        heicBytes.replaceSubrange(verTagRange.lowerBound..<(verTagRange.lowerBound + 2), with: makerTag)
        try heicBytes.write(to: syntheticISOBMFF)
        let isobmffRep = try await probe.verify(
            url: syntheticISOBMFF,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: heic3chPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(!isobmffRep.passed)
        #expect(isobmffRep.checks.contains { $0.name == "zero_makernote" && $0.severity == .fail })

        // 2. Gain map channel mismatch: 3ch checked as mono1ch AND 1ch checked as rgb3ch
        let mismatch3as1 = try await probe.verify(
            url: valid3chHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: heic3chPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .mono1ch,
                expectLegacyAppleGainMap: false
            )
        )
        #expect(!mismatch3as1.passed)
        #expect(mismatch3as1.checks.contains { $0.name == "gain_map_channels" && $0.severity == .fail })

        let mismatch1as3 = try await probe.verify(
            url: valid1chHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: heic1chPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch,
                expectLegacyAppleGainMap: false
            )
        )
        #expect(!mismatch1as3.passed)
        #expect(mismatch1as3.checks.contains { $0.name == "gain_map_channels" && $0.severity == .fail })

        // 3. Container format mismatch: .jpg checked with expected.format == .heic
        let formatMismatch = try await probe.verify(
            url: validJPG,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: xhsPreset.targetHeadroom.toLinear(),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch
            )
        )
        #expect(!formatMismatch.passed)
        #expect(formatMismatch.checks.contains { $0.name == "container_format" && $0.severity == .fail })

        // 4. JPEGDualEncoder rejects 2-element rgb3ch metadata array
        var badMetaFrame = heic3chFrame
        badMetaFrame.sdrCGImage = cg8
        badMetaFrame.gainMap.metadata.gainMapMax = [2.5, 2.5]
        var pure3chJPGPreset = heic3chPreset
        pure3chJPGPreset.outputFormats = [.jpeg]
        pure3chJPGPreset.bitDepth = .bit8
        pure3chJPGPreset.compatOptions.writeUltrahdrXMP = false
        pure3chJPGPreset.compatOptions.writeLegacyAppleHDRGainMap = false
        await #expect(throws: JPEGEncodeError.invalidGainMapMetadata("gainMapMax count 2 invalid for rgb3ch")) {
            _ = try await jpegEncoder.encode(
                frame: badMetaFrame,
                preset: pure3chJPGPreset,
                to: tmpDir.appendingPathComponent("bad_meta_2el.jpg")
            )
        }

        // 5. HLGVideoProbe rejects MP4 with non-identity preferredTransform (rotated track matrix)
        let rotMP4 = tmpDir.appendingPathComponent("rotated_hlg.mp4")
        let rotWriter = try AVAssetWriter(outputURL: rotMP4, fileType: .mp4)
        let rotInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920,
        ])
        rotInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        var rotPBOpt: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1080,
            1920,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &rotPBOpt
        )
        let rotPB = try #require(rotPBOpt)
        if #available(macOS 27.0, *) {
            let receiver = rotWriter.inputPixelBufferReceiver(for: rotInput, pixelBufferAttributes: nil)
            try rotWriter.start()
            rotWriter.startSession(atSourceTime: .zero)
            let ro = CVReadOnlyPixelBuffer(unsafeBuffer: rotPB)
            for idx in 0..<90 {
                try await receiver.append(ro, with: CMTime(value: CMTimeValue(idx), timescale: 30))
            }
            receiver.finish()
            rotWriter.endSession(atSourceTime: CMTime(value: 90, timescale: 30))
            await rotWriter.finishWriting()
        } else {
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: rotInput, sourcePixelBufferAttributes: nil)
            rotWriter.add(rotInput)
            rotWriter.startWriting()
            rotWriter.startSession(atSourceTime: .zero)
            for idx in 0..<90 {
                while !rotInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                adaptor.append(rotPB, withPresentationTime: CMTime(value: CMTimeValue(idx), timescale: 30))
            }
            rotInput.markAsFinished()
            rotWriter.endSession(atSourceTime: CMTime(value: 90, timescale: 30))
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                rotWriter.finishWriting { c.resume() }
            }
        }
        let rotRep = try await HLGVideoProbe().verify(
            url: rotMP4,
            expected: HLGComplianceExpectation(
                expectedDimensions: PixelDimensions(width: 1080, height: 1920)
            )
        )
        #expect(!rotRep.passed)
        #expect(rotRep.checks.contains { $0.name == "orientation_upright" && $0.severity == .fail })
        #expect(rotRep.measuredOrientation == nil)
    }

    @Test("ISO21496Probe passes on 3.5 EV and 4.0 EV exports (<2%) and rejects mismatched headroom & SDR-only assets", .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testISO21496ProbeHighHeadroomAndRejections() async throws {
        let tmpDir = try makeM4bTempDir(prefix: "chiaro-m7-high-headroom")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let probe = ISO21496Probe()
        let heicEncoder = HEICImageIOEncoder()
        let jpegEncoder = JPEGDualEncoder()
        let avifEncoder = AVIFGridEncoder(speed: 8, maxThreads: 4)

        // Use 256x256 non-uniform gradient (>= 128px width) so macOS 27.2 CGImageSourceDecodeToHDR
        // would cap CGImage.contentHeadroom at 8.0, exercising CIImage(.expandToHDR: true) measurement.
        let cg16 = try makeSyntheticCGImage(width: 256, height: 256, bitDepth: .bit10, colorSpace: .displayP3)
        let cg8 = try makeSyntheticCGImage(width: 256, height: 256, bitDepth: .bit8, colorSpace: .displayP3)

        // 1. 3.5 EV HEIC export passes within <2%
        var heic35Preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        heic35Preset.targetHeadroomStops = 3.5
        let frame35 = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("synth_35.arw"),
            width: 256,
            height: 256,
            baseColorSpace: .displayP3,
            sdrCGImage: cg16,
            gainMap: makeSyntheticGainMap(
                width: 256,
                height: 256,
                channels: .rgb3ch,
                gainMapMax: 3.5,
                headroomStops: 3.5
            ),
            exif: sampleWhitelistedExif()
        )
        let heic35URL = tmpDir.appendingPathComponent("export_35ev.heic")
        _ = try await heicEncoder.encode(frame: frame35, preset: heic35Preset, to: heic35URL)

        let expected35 = exp2(3.5)
        let rep35 = try await probe.verify(
            url: heic35URL,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: expected35),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(rep35.passed, "3.5 EV HEIC probe failed: \(rep35.checks)")
        let measured35 = try #require(rep35.measuredHeadroom?.multiplier)
        #expect(abs(measured35 - expected35) / expected35 < 0.02)

        // 2. 4.0 EV HEIC, JPEG (1ch Ultra HDR), and AVIF exports all pass within <2%
        var heic40Preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        heic40Preset.targetHeadroomStops = 4.0
        let frame40_3ch = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("synth_40_3ch.arw"),
            width: 256,
            height: 256,
            baseColorSpace: .displayP3,
            sdrCGImage: cg16,
            gainMap: makeSyntheticGainMap(
                width: 256,
                height: 256,
                channels: .rgb3ch,
                gainMapMax: 4.0,
                headroomStops: 4.0
            ),
            exif: sampleWhitelistedExif()
        )
        let heic40URL = tmpDir.appendingPathComponent("export_40ev.heic")
        _ = try await heicEncoder.encode(frame: frame40_3ch, preset: heic40Preset, to: heic40URL)

        let expected40 = exp2(4.0)
        let rep40HEIC = try await probe.verify(
            url: heic40URL,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: expected40),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(rep40HEIC.passed, "4.0 EV HEIC probe failed: \(rep40HEIC.checks)")
        let measured40HEIC = try #require(rep40HEIC.measuredHeadroom?.multiplier)
        #expect(abs(measured40HEIC - expected40) / expected40 < 0.02)

        var jpg40Preset = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
        jpg40Preset.targetHeadroomStops = 4.0
        let frame40_1ch = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("synth_40_1ch.arw"),
            width: 256,
            height: 256,
            baseColorSpace: .displayP3,
            sdrCGImage: cg8,
            gainMap: makeSyntheticGainMap(
                width: 256,
                height: 256,
                channels: .mono1ch,
                gainMapMax: 4.0,
                headroomStops: 4.0
            ),
            exif: sampleWhitelistedExif()
        )
        let jpg40URL = tmpDir.appendingPathComponent("export_40ev.jpg")
        _ = try await jpegEncoder.encode(frame: frame40_1ch, preset: jpg40Preset, to: jpg40URL)

        let rep40JPG = try await probe.verify(
            url: jpg40URL,
            expected: ComplianceExpectation(
                format: .jpeg,
                expectedHeadroom: LinearHeadroom(multiplier: expected40),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch,
                expectUltrahdrXMP: true
            )
        )
        #expect(rep40JPG.passed, "4.0 EV JPEG probe failed: \(rep40JPG.checks)")
        let measured40JPG = try #require(rep40JPG.measuredHeadroom?.multiplier)
        #expect(abs(measured40JPG - expected40) / expected40 < 0.02)

        var avif40Preset = try PresetLoader.loadBuiltIn(id: .avifArchive)
        avif40Preset.targetHeadroomStops = 4.0
        let avif40URL = tmpDir.appendingPathComponent("export_40ev.avif")
        _ = try await avifEncoder.encode(frame: frame40_3ch, preset: avif40Preset, to: avif40URL)

        let rep40AVIF = try await probe.verify(
            url: avif40URL,
            expected: ComplianceExpectation(
                format: .avif,
                expectedHeadroom: LinearHeadroom(multiplier: expected40),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(rep40AVIF.passed, "4.0 EV AVIF probe failed: \(rep40AVIF.checks)")
        let measured40AVIF = try #require(rep40AVIF.measuredHeadroom?.multiplier)
        #expect(abs(measured40AVIF - expected40) / expected40 < 0.02)

        // 3. Reject mismatched expected headroom (4.0 EV asset checked as 2.5 EV, and 2.5 EV asset checked as 4.0 EV)
        let mismatch40as25 = try await probe.verify(
            url: heic40URL,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: exp2(2.5)),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(!mismatch40as25.passed)
        #expect(mismatch40as25.checks.contains { $0.name == "content_headroom" && $0.severity == .fail })

        let heic25Preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let frame25 = RenderedFrame(
            sourceURL: tmpDir.appendingPathComponent("synth_25.arw"),
            width: 256,
            height: 256,
            baseColorSpace: .displayP3,
            sdrCGImage: cg16,
            gainMap: makeSyntheticGainMap(
                width: 256,
                height: 256,
                channels: .rgb3ch,
                gainMapMax: 2.5,
                headroomStops: 2.5
            ),
            exif: sampleWhitelistedExif()
        )
        let heic25URL = tmpDir.appendingPathComponent("export_25ev.heic")
        _ = try await heicEncoder.encode(frame: frame25, preset: heic25Preset, to: heic25URL)

        let mismatch25as40 = try await probe.verify(
            url: heic25URL,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: expected40),
                expectedBitDepth: .bit10,
                expectedGainMapChannels: .rgb3ch
            )
        )
        #expect(!mismatch25as40.passed)
        #expect(mismatch25as40.checks.contains { $0.name == "content_headroom" && $0.severity == .fail })

        // 4. Reject SDR-only (1.0) HEIC asset
        let sdrHEIC = tmpDir.appendingPathComponent("plain_sdr.heic")
        let sdrDest = try #require(CGImageDestinationCreateWithURL(sdrHEIC as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(sdrDest, cg8, [
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(sdrDest))

        let sdrAs40Rep = try await probe.verify(
            url: sdrHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: expected40),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch
            )
        )
        #expect(!sdrAs40Rep.passed)
        #expect(!sdrAs40Rep.hasISOGainMap)
        #expect(sdrAs40Rep.checks.contains { $0.name == "content_headroom" && $0.severity == .fail })

        let sdrAs10Rep = try await probe.verify(
            url: sdrHEIC,
            expected: ComplianceExpectation(
                format: .heic,
                expectedHeadroom: LinearHeadroom(multiplier: 1.0),
                expectedBitDepth: .bit8,
                expectedGainMapChannels: .mono1ch
            )
        )
        #expect(!sdrAs10Rep.passed)
        #expect(!sdrAs10Rep.hasISOGainMap)
        #expect(sdrAs10Rep.measuredHeadroom?.multiplier == 1.0)
    }
}

}
