import CLibAVIFBridge
import CLibRawBridge
import CUltraHDRBridge
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// MARK: - Helpers

private let tangmoDir = TestFixtures.sampleDirectory
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ChiaroCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // Chiaro

private func cStringOrNil(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(cString: ptr)
}

private struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runCLI(_ executablePath: String, arguments: [String]) throws -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return CLIResult(
        status: process.terminationStatus,
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self)
    )
}

private func makeTempDirectory(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeMinimalCleanExifTIFF(
    make: String = "SONY",
    model: String = "ILCE-7CM2",
    orientation: UInt16 = 1,
    includeExifPrefix: Bool
) -> Data {
    // Little-endian TIFF with 3 IFD0 entries:
    // 0x010F Make (ASCII), 0x0110 Model (ASCII), 0x0112 Orientation (SHORT)
    var tiff = Data()
    func appendU16(_ v: UInt16) {
        var le = v.littleEndian
        tiff.append(Data(bytes: &le, count: 2))
    }
    func appendU32(_ v: UInt32) {
        var le = v.littleEndian
        tiff.append(Data(bytes: &le, count: 4))
    }

    let makeBytes = Data((make + "\0").utf8)
    let modelBytes = Data((model + "\0").utf8)

    // TIFF header (8 bytes): "II*\0" + IFD0 offset (8)
    tiff.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
    appendU32(8)

    // IFD0: count = 3 (2 bytes), 3 * 12 = 36 bytes entries, nextIFD = 0 (4 bytes)
    // Data starts at offset 8 + 2 + 36 + 4 = 50
    let makeOffset: UInt32 = 50
    let modelOffset: UInt32 = makeOffset + UInt32(makeBytes.count)

    appendU16(3)

    // Entry 1: Make (0x010F, ASCII = 2)
    appendU16(0x010F)
    appendU16(2)
    appendU32(UInt32(makeBytes.count))
    if makeBytes.count <= 4 {
        var padded = makeBytes
        while padded.count < 4 { padded.append(0) }
        tiff.append(padded)
    } else {
        appendU32(makeOffset)
    }

    // Entry 2: Model (0x0110, ASCII = 2)
    appendU16(0x0110)
    appendU16(2)
    appendU32(UInt32(modelBytes.count))
    if modelBytes.count <= 4 {
        var padded = modelBytes
        while padded.count < 4 { padded.append(0) }
        tiff.append(padded)
    } else {
        appendU32(modelOffset)
    }

    // Entry 3: Orientation (0x0112, SHORT = 3, count = 1, inline value)
    appendU16(0x0112)
    appendU16(3)
    appendU32(1)
    appendU16(orientation)
    appendU16(0)

    // Next IFD offset = 0
    appendU32(0)

    if makeBytes.count > 4 {
        tiff.append(makeBytes)
    }
    if modelBytes.count > 4 {
        tiff.append(modelBytes)
    }

    if includeExifPrefix {
        var prefixed = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
        prefixed.append(tiff)
        return prefixed
    }
    return tiff
}

private func makeSyntheticDisplayP3JPEG(
    width: Int,
    height: Int,
    embeddedExif: [CFString: Any]? = nil
) throws -> Data {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * bytesPerRow + x * 4
            pixels[i + 0] = UInt8((x * 255) / max(1, width - 1))
            pixels[i + 1] = UInt8((y * 255) / max(1, height - 1))
            pixels[i + 2] = 180
            pixels[i + 3] = 255
        }
    }

    let ctx = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let cgImage = try #require(ctx.makeImage())

    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    var props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.92,
    ]
    if let embeddedExif {
        props[kCGImagePropertyExifDictionary] = embeddedExif
    }
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

private func makeSyntheticGrayscaleGainMapJPEG(width: Int, height: Int) throws -> Data {
    let graySpace = CGColorSpaceCreateDeviceGray()
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            // Left half low gain (0), right half bright highlight gain (255)
            pixels[y * width + x] = (x >= width / 2) ? 255 : 0
        }
    }

    let ctx = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: graySpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    let cgImage = try #require(ctx.makeImage())

    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

private func float16ToFloat(_ bits: UInt16) -> Float {
    Float(Float16(bitPattern: bits))
}

// MARK: - CLibRawBridge Tests

extension ChiaroSerializedSuites {

@Suite("CBridgesTests", .serialized)
struct CBridgesTests {

@Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
func testCLibRawRealTangmoARWModesAndExifWhitelist() throws {
    let dsc2533 = tangmoDir.appendingPathComponent("DSC02533.ARW")
    let dsc2540 = tangmoDir.appendingPathComponent("DSC02540.ARW")
    let dsc2556 = tangmoDir.appendingPathComponent("DSC02556.ARW")

    try #require(FileManager.default.fileExists(atPath: dsc2533.path))
    try #require(FileManager.default.fileExists(atPath: dsc2540.path))
    try #require(FileManager.default.fileExists(atPath: dsc2556.path))

    let rawVer = cStringOrNil(hdr_libraw_version()) ?? ""
    #expect(rawVer.hasPrefix("0.22."))

    // 1. DSC02533.ARW (33MP Horizontal) BAYER_OR_SRAW
    var opts = hdr_libraw_default_options()
    opts.mode = HDR_LIBRAW_MODE_BAYER_OR_SRAW
    var bayerImg = HDRLibRawImage()
    let bayerStatus = hdr_libraw_decode_file(dsc2533.path, &opts, &bayerImg)
    defer { hdr_libraw_free_image(&bayerImg) }

    #expect(bayerStatus == HDR_LIBRAW_OK)
    #expect(bayerImg.payload_kind == HDR_LIBRAW_PAYLOAD_BAYER16U)
    #expect(bayerImg.width == 7008)
    #expect(bayerImg.height == 4672)
    #expect(bayerImg.bits_per_sample == 14)
    #expect(bayerImg.cfa_pattern == HDR_LIBRAW_CFA_RGGB)
    #expect(bayerImg.orientation == 1)
    #expect(bayerImg.is_lossless_ms == 0)
    #expect(bayerImg.as_shot_wb_applied == 0)
    #expect(bayerImg.white_level == 16383)
    #expect(bayerImg.black_level.0 == 512)
    #expect(bayerImg.cam_mul.0 > 1.0)
    #expect(bayerImg.data_bytes == 7008 * 4672 * 2)
    #expect(bayerImg.rgb16_data != nil)

    // EXIF whitelist checks + verify zero MakerNote property on struct
    #expect(cStringOrNil(bayerImg.exif.make) == "SONY")
    #expect(cStringOrNil(bayerImg.exif.model) == "ILCE-7CM2")
    #expect(cStringOrNil(bayerImg.exif.lens_model) == "TAMRON 25-200mm F2.8-5.6 A075 E")
    #expect(bayerImg.exif.iso_speed == 12800)
    #expect(bayerImg.exif.focal_length_mm == 49.0)
    #expect(bayerImg.exif.focal_length_35mm == 49)
    #expect(cStringOrNil(bayerImg.exif.offset_time_original) == "+08:00")
    #expect(cStringOrNil(bayerImg.exif.subsec_time_original) == "436")
    #expect(cStringOrNil(bayerImg.exif.date_time_original) == "2026:11:22 18:43:43")
    #expect(bayerImg.exif.has_exposure_bias == 1)
    #expect(abs(bayerImg.exif.exposure_bias_ev) < 0.01)

    let exifLabels = Mirror(reflecting: bayerImg.exif).children.compactMap { $0.label?.lowercased() }
    #expect(!exifLabels.contains(where: { $0.contains("makernote") }))

    // 2. DSC02533.ARW LINEAR_RGB16 (Rec.2020, highlight=1 unclip)
    var linOpts = hdr_libraw_default_options()
    linOpts.mode = HDR_LIBRAW_MODE_LINEAR_RGB16
    linOpts.output_color_space = HDR_LIBRAW_CS_LINEAR_REC2020
    linOpts.highlight_mode = 1
    var linImg = HDRLibRawImage()
    let linStatus = hdr_libraw_decode_file(dsc2533.path, &linOpts, &linImg)
    defer { hdr_libraw_free_image(&linImg) }

    #expect(linStatus == HDR_LIBRAW_OK)
    #expect(linImg.payload_kind == HDR_LIBRAW_PAYLOAD_RGB16U)
    #expect(linImg.color_space == HDR_LIBRAW_CS_LINEAR_REC2020)
    #expect(linImg.width == 7008)
    #expect(linImg.height == 4672)
    #expect(linImg.bits_per_sample == 16)
    #expect(linImg.data_bytes == 7008 * 4672 * 3 * 2)

    // 3. DSC02533.ARW PROXY_RGB16 (half_size=1) -> exact 3504x2336 RGB16U
    var proxyOpts = hdr_libraw_default_options()
    proxyOpts.mode = HDR_LIBRAW_MODE_PROXY_RGB16
    var proxyImg = HDRLibRawImage()
    let proxyStatus = hdr_libraw_decode_file(dsc2533.path, &proxyOpts, &proxyImg)
    defer { hdr_libraw_free_image(&proxyImg) }

    #expect(proxyStatus == HDR_LIBRAW_OK)
    #expect(proxyImg.payload_kind == HDR_LIBRAW_PAYLOAD_RGB16U)
    #expect(proxyImg.width == 3504)
    #expect(proxyImg.height == 2336)
    #expect(proxyImg.bits_per_sample == 16)
    #expect(proxyImg.data_bytes == 3504 * 2336 * 3 * 2)
    #expect(proxyImg.orientation == 1)

    // 4. DSC02540.ARW (33MP Rotate 270 CW -> orientation 8, raw sensor geometry preserved)
    var rotImg = HDRLibRawImage()
    let rotStatus = hdr_libraw_decode_file(dsc2540.path, &opts, &rotImg)
    defer { hdr_libraw_free_image(&rotImg) }

    #expect(rotStatus == HDR_LIBRAW_OK)
    #expect(rotImg.width == 7008)
    #expect(rotImg.height == 4672)
    #expect(rotImg.orientation == 8)
    #expect(rotImg.exif.orientation == 8)

    // 5. DSC02556.ARW (14MP APS-C Rotate 270 CW)
    var apscImg = HDRLibRawImage()
    let apscStatus = hdr_libraw_decode_file(dsc2556.path, &opts, &apscImg)
    defer { hdr_libraw_free_image(&apscImg) }

    #expect(apscStatus == HDR_LIBRAW_OK)
    #expect(apscImg.width == 4608)
    #expect(apscImg.height == 3072)
    #expect(apscImg.orientation == 8)
    #expect(cStringOrNil(apscImg.exif.make) == "SONY")
    #expect(apscImg.exif.focal_length_mm == 200.0)
    #expect(apscImg.exif.focal_length_35mm == 300)
    #expect(apscImg.exif.iso_speed == 6400)
    #expect(abs(apscImg.exif.exposure_bias_ev - (-0.7)) < 0.01)
    #expect(cStringOrNil(apscImg.exif.subsec_time_original) == "672")

    // 6. 14MP PROXY_RGB16 -> exact 2304x1536 RGB16U
    var apscProxy = HDRLibRawImage()
    let apscProxyStatus = hdr_libraw_decode_file(dsc2556.path, &proxyOpts, &apscProxy)
    defer { hdr_libraw_free_image(&apscProxy) }

    #expect(apscProxyStatus == HDR_LIBRAW_OK)
    #expect(apscProxy.payload_kind == HDR_LIBRAW_PAYLOAD_RGB16U)
    #expect(apscProxy.width == 2304)
    #expect(apscProxy.height == 1536)
    #expect(apscProxy.data_bytes == 2304 * 1536 * 3 * 2)
}

@Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
func testCLibRawBufferDecodeAndErrorHandling() throws {
    let dsc2556 = tangmoDir.appendingPathComponent("DSC02556.ARW")
    try #require(FileManager.default.fileExists(atPath: dsc2556.path))
    let arwData = try Data(contentsOf: dsc2556)

    var opts = hdr_libraw_default_options()
    opts.mode = HDR_LIBRAW_MODE_BAYER_OR_SRAW
    var bufImg = HDRLibRawImage()
    let status = arwData.withUnsafeBytes { rawBuf in
        hdr_libraw_decode_buffer(rawBuf.baseAddress, rawBuf.count, &opts, &bufImg)
    }
    #expect(status == HDR_LIBRAW_OK)
    #expect(bufImg.width == 4608)
    #expect(bufImg.height == 3072)
    #expect(bufImg.orientation == 8)
    #expect(cStringOrNil(bufImg.exif.make) == "SONY")

    // Verify both hdr_libraw_free_image and clraw_free_image are idempotent
    hdr_libraw_free_image(&bufImg)
    #expect(bufImg.rgb16_data == nil)
    #expect(bufImg.width == 0)
    clraw_free_image(&bufImg)
    hdr_libraw_free_image(nil)
    clraw_free_image(nil)

    // Non-existent file
    var missingImg = HDRLibRawImage()
    let missingStatus = hdr_libraw_decode_file("/tmp/does_not_exist_\(UUID().uuidString).ARW", &opts, &missingImg)
    defer { hdr_libraw_free_image(&missingImg) }
    #expect(missingStatus == HDR_LIBRAW_ERR_OPEN)
    #expect(missingImg.rgb16_data == nil)
    let errMsg = withUnsafePointer(to: &missingImg.error_message) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    #expect(!errMsg.isEmpty)

    // Garbage buffer
    let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04])
    var garbageImg = HDRLibRawImage()
    let garbageStatus = garbage.withUnsafeBytes { rawBuf in
        hdr_libraw_decode_buffer(rawBuf.baseAddress, rawBuf.count, &opts, &garbageImg)
    }
    defer { hdr_libraw_free_image(&garbageImg) }
    #expect(garbageStatus != HDR_LIBRAW_OK)
    #expect(garbageImg.rgb16_data == nil)

    // NULL arguments
    #expect(hdr_libraw_decode_file(nil, &opts, &garbageImg) == HDR_LIBRAW_ERR_INVALID_ARG)
    #expect(hdr_libraw_decode_file(dsc2556.path, &opts, nil) == HDR_LIBRAW_ERR_INVALID_ARG)
    #expect(hdr_libraw_decode_buffer(nil, 0, &opts, &garbageImg) == HDR_LIBRAW_ERR_INVALID_ARG)
    #expect(hdr_libraw_decode_buffer(nil, 10, &opts, nil) == HDR_LIBRAW_ERR_INVALID_ARG)

    // sraw_no_rgb = 1 rejected cleanly with HDR_LIBRAW_ERR_UNSUPPORTED
    var srawNoRgbOpts = hdr_libraw_default_options()
    srawNoRgbOpts.sraw_no_rgb = 1
    var srawNoRgbImg = HDRLibRawImage()
    defer { hdr_libraw_free_image(&srawNoRgbImg) }
    #expect(hdr_libraw_decode_file(dsc2556.path, &srawNoRgbOpts, &srawNoRgbImg) == HDR_LIBRAW_ERR_UNSUPPORTED)
    let srawBufStatus = arwData.withUnsafeBytes { rawBuf in
        hdr_libraw_decode_buffer(rawBuf.baseAddress, rawBuf.count, &srawNoRgbOpts, &srawNoRgbImg)
    }
    #expect(srawBufStatus == HDR_LIBRAW_ERR_UNSUPPORTED)

    // Invalid mode rejected cleanly with HDR_LIBRAW_ERR_INVALID_ARG
    var badModeOpts = hdr_libraw_default_options()
    badModeOpts.mode = HDRLibRawDecodeMode(rawValue: 99)
    var badModeImg = HDRLibRawImage()
    defer { hdr_libraw_free_image(&badModeImg) }
    #expect(hdr_libraw_decode_file(dsc2556.path, &badModeOpts, &badModeImg) == HDR_LIBRAW_ERR_INVALID_ARG)
    let badModeBufStatus = arwData.withUnsafeBytes { rawBuf in
        hdr_libraw_decode_buffer(rawBuf.baseAddress, rawBuf.count, &badModeOpts, &badModeImg)
    }
    #expect(badModeBufStatus == HDR_LIBRAW_ERR_INVALID_ARG)
}

@Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
func testCLibRawConcurrentTaskGroupDecode() async throws {
    let paths = [
        tangmoDir.appendingPathComponent("DSC02533.ARW").path,
        tangmoDir.appendingPathComponent("DSC02540.ARW").path,
        tangmoDir.appendingPathComponent("DSC02556.ARW").path,
        tangmoDir.appendingPathComponent("DSC02533.ARW").path,
        tangmoDir.appendingPathComponent("DSC02556.ARW").path,
    ]
    for path in paths {
        try #require(FileManager.default.fileExists(atPath: path))
    }

    struct Summary: Sendable, Equatable {
        let width: Int32
        let height: Int32
        let orientation: Int32
        let camMul0: Float
        let iso: Int32
    }

    let results = try await withThrowingTaskGroup(of: (Int, Summary).self) { group in
        for (idx, path) in paths.enumerated() {
            group.addTask {
                var opts = hdr_libraw_default_options()
                opts.mode = HDR_LIBRAW_MODE_BAYER_OR_SRAW
                var img = HDRLibRawImage()
                let status = hdr_libraw_decode_file(path, &opts, &img)
                defer { hdr_libraw_free_image(&img) }
                #expect(status == HDR_LIBRAW_OK)
                return (
                    idx,
                    Summary(
                        width: img.width,
                        height: img.height,
                        orientation: img.orientation,
                        camMul0: img.cam_mul.0,
                        iso: img.exif.iso_speed
                    )
                )
            }
        }
        var collected = [Int: Summary]()
        for try await (idx, s) in group {
            collected[idx] = s
        }
        return collected
    }

    #expect(results.count == 5)
    #expect(results[0] == results[3])
    #expect(results[2] == results[4])
    #expect(results[0]?.width == 7008)
    #expect(results[1]?.orientation == 8)
    #expect(results[2]?.width == 4608)
}

// MARK: - CUltraHDRBridge Tests

@Test
func testCUltraHDREncodeAPI4ProbeDecodeAndExternalTools() throws {
    let baseJPEG = try makeSyntheticDisplayP3JPEG(width: 64, height: 64)
    let gmJPEG = try makeSyntheticGrayscaleGainMapJPEG(width: 32, height: 32)
    let cleanExif = makeMinimalCleanExifTIFF(make: "SONY", model: "ILCE-7CM2", orientation: 1, includeExifPrefix: true)

    var outJPEG = HDRUltraHDRBuffer()
    var errPtr: UnsafeMutablePointer<CChar>?
    defer {
        hdr_ultrahdr_free_buffer(&outJPEG)
        cuhdr_free_error(errPtr)
    }

    let offset: Float = 1.0 / 64.0
    let meta = HDRUltraHDRGainMapMetadata(
        max_content_boost: (4.0, 4.0, 4.0),
        min_content_boost: (1.0, 1.0, 1.0),
        gamma: (1.0, 1.0, 1.0),
        offset_sdr: (offset, offset, offset),
        offset_hdr: (offset, offset, offset),
        hdr_capacity_min: 1.0,
        hdr_capacity_max: 4.0,
        use_base_cg: 1
    )

    let encStatus = baseJPEG.withUnsafeBytes { baseBuf in
        gmJPEG.withUnsafeBytes { gmBuf in
            cleanExif.withUnsafeBytes { exifBuf in
                var input = HDRUltraHDREncodeInput(
                    base_jpeg_data: baseBuf.bindMemory(to: UInt8.self).baseAddress,
                    base_jpeg_size: baseJPEG.count,
                    base_color_gamut: HDR_UHDR_CG_DISPLAY_P3,
                    gainmap_jpeg_data: gmBuf.bindMemory(to: UInt8.self).baseAddress,
                    gainmap_jpeg_size: gmJPEG.count,
                    exif_data: exifBuf.bindMemory(to: UInt8.self).baseAddress,
                    exif_size: cleanExif.count,
                    metadata: meta
                )
                return cuhdr_encode_api4(&input, &outJPEG, &errPtr)
            }
        }
    }

    #expect(encStatus == 0)
    #expect(errPtr == nil)
    #expect(outJPEG.data != nil)
    #expect(outJPEG.size > 0)

    let encodedData = Data(bytes: outJPEG.data, count: outJPEG.size)

    // Probe without pixel decode
    var probe = HDRUltraHDRProbeResult()
    var probeErr: UnsafeMutablePointer<CChar>?
    defer {
        cuhdr_free_probe_result(&probe)
        cuhdr_free_error(probeErr)
    }
    let probeStatus = encodedData.withUnsafeBytes { buf in
        cuhdr_probe(buf.bindMemory(to: UInt8.self).baseAddress, encodedData.count, 1, &probe, &probeErr)
    }
    #expect(probeStatus == 0)
    #expect(probe.is_valid == 1)
    #expect(probe.base_width == 64)
    #expect(probe.base_height == 64)
    #expect(probe.gainmap_width == 32)
    #expect(probe.gainmap_height == 32)
    #expect(probe.gainmap_channels == 1)
    #expect(probe.exif_size > 0)
    #expect(probe.icc_size > 0)
    #expect(probe.base_jpeg.data != nil)
    #expect(probe.gainmap_jpeg.data != nil)
    #expect(probe.exif_data.data != nil)
    #expect(probe.icc_data.data != nil)
    #expect(probe.metadata.use_base_cg == 1)
    #expect(abs(probe.metadata.max_content_boost.0 - 4.0) < 0.05)
    #expect(abs(probe.metadata.hdr_capacity_max - 4.0) < 0.05)
    #expect(abs(probe.metadata.offset_sdr.0 - offset) < 0.01)

    // Decode to HalfFloat linear
    var decoded = HDRUltraHDRDecodedImage()
    var decErr: UnsafeMutablePointer<CChar>?
    defer {
        cuhdr_free_decoded_image(&decoded)
        cuhdr_free_error(decErr)
    }
    let decStatus = encodedData.withUnsafeBytes { buf in
        cuhdr_decode(
            buf.bindMemory(to: UInt8.self).baseAddress,
            encodedData.count,
            HDR_UHDR_DECODE_RGBA_HALF_FLOAT_LINEAR,
            4.0,
            &decoded,
            &decErr
        )
    }
    #expect(decStatus == 0)
    #expect(decoded.width == 64)
    #expect(decoded.height == 64)
    #expect(decoded.pixels.size == 64 * 64 * 8)
    #expect(decoded.gainmap_channels == 1)
    #expect(decoded.gainmap_pixels.size == 32 * 32)

    let hfPtr = UnsafeRawPointer(decoded.pixels.data!).bindMemory(to: UInt16.self, capacity: 64 * 64 * 4)
    var maxChannelVal: Float = 0.0
    for i in 0..<(64 * 64) {
        let r = float16ToFloat(hfPtr[i * 4 + 0])
        let g = float16ToFloat(hfPtr[i * 4 + 1])
        let b = float16ToFloat(hfPtr[i * 4 + 2])
        maxChannelVal = max(maxChannelVal, max(r, max(g, b)))
    }
    #expect(maxChannelVal > 1.0)

    // Apple ImageIO auxiliary data check
    let src = try #require(CGImageSourceCreateWithData(encodedData as CFData, nil))
    let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap)
    #expect(aux != nil)

    // External CLI tools: ultrahdr_app + exiftool
    let tmpDir = try makeTempDirectory(prefix: "chiaro-uhdr-test")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let jpgURL = tmpDir.appendingPathComponent("test_uhdr.jpg")
    try encodedData.write(to: jpgURL)

    let ultrahdrApp = repoRoot.appendingPathComponent("Vendor/install/bin/ultrahdr_app").path
    if FileManager.default.isExecutableFile(atPath: ultrahdrApp) {
        let probeCLI = try runCLI(ultrahdrApp, arguments: ["-m", "1", "-j", jpgURL.path, "-P"])
        #expect(probeCLI.status == 0)
        #expect(probeCLI.stdout.contains("Ultra HDR Image: Yes"))
        #expect(probeCLI.stdout.contains("--maxContentBoost"))
    }

    let exiftoolPath = "/opt/homebrew/bin/exiftool"
    if FileManager.default.isExecutableFile(atPath: exiftoolPath) {
        let exifRes = try runCLI(exiftoolPath, arguments: ["-G1", "-a", "-s", "-ee", "-j", jpgURL.path])
        #expect(exifRes.status == 0)
        let jsonData = try #require(exifRes.stdout.data(using: .utf8))
        let arr = try #require(try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]])
        let dict = try #require(arr.first)

        #expect(dict.values.contains { ($0 as? String) == "urn:iso:std:iso:ts:21496:-1" })
        #expect((dict["MPF0:NumberOfImages"] as? Int) == 2)
        #expect((dict["MPImage2:MPImageFormat"] as? String) == "JPEG")
        #expect(dict["XMP-hdrgm:GainMapMax"] != nil)
        #expect((dict["ICC_Profile:ProfileDescription"] as? String) == "Display P3")
        #expect((dict["IFD0:Orientation"] as? String) == "Horizontal (normal)")
        #expect((dict["IFD0:Model"] as? String) == "ILCE-7CM2")
        #expect(!dict.keys.contains(where: { $0.localizedCaseInsensitiveContains("makernote") }))
        #expect(!dict.keys.contains(where: { $0.hasPrefix("Sony:") || $0.hasPrefix("Apple:") }))
    }
}

@Test
func testCUltraHDRExifSplicingReplacesExistingExifAndAcceptsRawTIFF() throws {
    // Base JPEG with pre-existing dummy EXIF
    let dummyExif = [kCGImagePropertyExifUserComment: "OLD_DUMMY_EXIF"] as [CFString: Any]
    let baseWithOldExif = try makeSyntheticDisplayP3JPEG(width: 64, height: 64, embeddedExif: dummyExif)
    let gmJPEG = try makeSyntheticGrayscaleGainMapJPEG(width: 32, height: 32)
    // Raw TIFF without "Exif\0\0" prefix
    let rawTIFF = makeMinimalCleanExifTIFF(make: "SONY", model: "ILCE-7CM2", orientation: 1, includeExifPrefix: false)

    var outJPEG = HDRUltraHDRBuffer()
    var errPtr: UnsafeMutablePointer<CChar>?
    defer {
        hdr_ultrahdr_free_buffer(&outJPEG)
        cuhdr_free_error(errPtr)
    }

    let offset: Float = 1.0 / 64.0
    let meta = HDRUltraHDRGainMapMetadata(
        max_content_boost: (4.0, 4.0, 4.0),
        min_content_boost: (1.0, 1.0, 1.0),
        gamma: (1.0, 1.0, 1.0),
        offset_sdr: (offset, offset, offset),
        offset_hdr: (offset, offset, offset),
        hdr_capacity_min: 1.0,
        hdr_capacity_max: 4.0,
        use_base_cg: 1
    )

    let status = baseWithOldExif.withUnsafeBytes { baseBuf in
        gmJPEG.withUnsafeBytes { gmBuf in
            rawTIFF.withUnsafeBytes { exifBuf in
                var input = HDRUltraHDREncodeInput(
                    base_jpeg_data: baseBuf.bindMemory(to: UInt8.self).baseAddress,
                    base_jpeg_size: baseWithOldExif.count,
                    base_color_gamut: HDR_UHDR_CG_DISPLAY_P3,
                    gainmap_jpeg_data: gmBuf.bindMemory(to: UInt8.self).baseAddress,
                    gainmap_jpeg_size: gmJPEG.count,
                    exif_data: exifBuf.bindMemory(to: UInt8.self).baseAddress,
                    exif_size: rawTIFF.count,
                    metadata: meta
                )
                return cuhdr_encode_api4(&input, &outJPEG, &errPtr)
            }
        }
    }
    #expect(status == 0)

    let outData = Data(bytes: outJPEG.data, count: outJPEG.size)
    let src = try #require(CGImageSourceCreateWithData(outData as CFData, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    let tiffDict = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    #expect((tiffDict[kCGImagePropertyTIFFModel] as? String) == "ILCE-7CM2")
    #expect((props[kCGImagePropertyOrientation] as? Int) == 1)
    let exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect((exifDict?[kCGImagePropertyExifUserComment] as? String) == nil)
}

@Test
func testCUltraHDRErrorHandlingInvalidInputs() throws {
    let baseJPEG = try makeSyntheticDisplayP3JPEG(width: 64, height: 64)
    let gmJPEG = try makeSyntheticGrayscaleGainMapJPEG(width: 32, height: 32)
    let offset: Float = 1.0 / 64.0

    func attemptEncode(_ meta: HDRUltraHDRGainMapMetadata, cg: HDRUltraHDRColorGamut = HDR_UHDR_CG_DISPLAY_P3, base: Data? = nil) -> (Int32, String?) {
        let baseData = base ?? baseJPEG
        var out = HDRUltraHDRBuffer()
        var err: UnsafeMutablePointer<CChar>?
        defer {
            hdr_ultrahdr_free_buffer(&out)
            cuhdr_free_error(err)
        }
        let st = baseData.withUnsafeBytes { b in
            gmJPEG.withUnsafeBytes { g in
                var inp = HDRUltraHDREncodeInput(
                    base_jpeg_data: b.bindMemory(to: UInt8.self).baseAddress,
                    base_jpeg_size: baseData.count,
                    base_color_gamut: cg,
                    gainmap_jpeg_data: g.bindMemory(to: UInt8.self).baseAddress,
                    gainmap_jpeg_size: gmJPEG.count,
                    exif_data: nil,
                    exif_size: 0,
                    metadata: meta
                )
                return cuhdr_encode_api4(&inp, &out, &err)
            }
        }
        return (st, cStringOrNil(err))
    }

    // 1. hdr_capacity_max <= hdr_capacity_min
    let badCap = HDRUltraHDRGainMapMetadata(
        max_content_boost: (4.0, 4.0, 4.0),
        min_content_boost: (1.0, 1.0, 1.0),
        gamma: (1.0, 1.0, 1.0),
        offset_sdr: (offset, offset, offset),
        offset_hdr: (offset, offset, offset),
        hdr_capacity_min: 4.0,
        hdr_capacity_max: 4.0,
        use_base_cg: 1
    )
    let res1 = attemptEncode(badCap)
    #expect(res1.0 != 0)
    #expect(res1.1 != nil)

    // 2. use_base_cg == 0
    let badCG = HDRUltraHDRGainMapMetadata(
        max_content_boost: (4.0, 4.0, 4.0),
        min_content_boost: (1.0, 1.0, 1.0),
        gamma: (1.0, 1.0, 1.0),
        offset_sdr: (offset, offset, offset),
        offset_hdr: (offset, offset, offset),
        hdr_capacity_min: 1.0,
        hdr_capacity_max: 4.0,
        use_base_cg: 0
    )
    let res2 = attemptEncode(badCG)
    #expect(res2.0 != 0)
    #expect(res2.1 != nil)

    // 3. Mismatched 3-channel boosts / gamma -> consistent UHDR_CODEC_UNSUPPORTED_FEATURE
    let mismatch = HDRUltraHDRGainMapMetadata(
        max_content_boost: (4.0, 2.0, 4.0),
        min_content_boost: (1.0, 1.0, 1.0),
        gamma: (1.0, 1.0, 1.0),
        offset_sdr: (offset, offset, offset),
        offset_hdr: (offset, offset, offset),
        hdr_capacity_min: 1.0,
        hdr_capacity_max: 4.0,
        use_base_cg: 1
    )
    let res3 = attemptEncode(mismatch)
    #expect(res3.0 != 0)
    #expect(res3.0 == res2.0)
    #expect(res3.1 != nil)

    let gammaMismatch = HDRUltraHDRGainMapMetadata(
        max_content_boost: (4.0, 4.0, 4.0),
        min_content_boost: (1.0, 1.0, 1.0),
        gamma: (1.0, 1.5, 1.0),
        offset_sdr: (offset, offset, offset),
        offset_hdr: (offset, offset, offset),
        hdr_capacity_min: 1.0,
        hdr_capacity_max: 4.0,
        use_base_cg: 1
    )
    let resGammaMismatch = attemptEncode(gammaMismatch)
    #expect(resGammaMismatch.0 == res2.0)
    #expect(resGammaMismatch.0 != res1.0)
    #expect(resGammaMismatch.1 != nil)

    // 4. Non-finite metadata -> UHDR_CODEC_INVALID_PARAM (matches res1)
    let nanMeta = HDRUltraHDRGainMapMetadata(
        max_content_boost: (.nan, 4.0, 4.0),
        min_content_boost: (1.0, 1.0, 1.0),
        gamma: (1.0, 1.0, 1.0),
        offset_sdr: (offset, offset, offset),
        offset_hdr: (offset, offset, offset),
        hdr_capacity_min: 1.0,
        hdr_capacity_max: 4.0,
        use_base_cg: 1
    )
    let resNan = attemptEncode(nanMeta)
    #expect(resNan.0 == res1.0)
    #expect(resNan.1 != nil)

    // 4. Corrupt JPEG passed to cuhdr_probe
    let corrupt = Data([0xFF, 0xD8, 0x00, 0x11, 0x22])
    var probe = HDRUltraHDRProbeResult()
    var probeErr: UnsafeMutablePointer<CChar>?
    defer {
        cuhdr_free_probe_result(&probe)
        cuhdr_free_error(probeErr)
    }
    let probeSt = corrupt.withUnsafeBytes { buf in
        cuhdr_probe(buf.bindMemory(to: UInt8.self).baseAddress, corrupt.count, 0, &probe, &probeErr)
    }
    #expect(probeSt != 0)
    #expect(probe.is_valid == 0)
    #expect(probeErr != nil)
}

// MARK: - CLibAVIFBridge Tests

@Test
func testCLibAVIFVersionAndCodecsAvailable() {
    let ver = cStringOrNil(hdr_libavif_version()) ?? ""
    #expect(ver.hasPrefix("1.4."))

    var buf = [CChar](repeating: 0, count: 512)
    hdr_libavif_codec_versions(&buf, buf.count)
    let codecs = buf.withUnsafeBufferPointer { ptr in
        String(cString: ptr.baseAddress!)
    }
    #expect(codecs.localizedCaseInsensitiveContains("svt"))
    #expect(codecs.localizedCaseInsensitiveContains("aom"))
    #expect(codecs.localizedCaseInsensitiveContains("dav1d"))

    // Small-buffer truncation & null/zero-size safety (never overflows caller buffer)
    var buf8 = [CChar](repeating: 0x5A, count: 8)
    hdr_libavif_codec_versions(&buf8, buf8.count)
    #expect(buf8[7] == 0)
    let truncated7 = buf8.withUnsafeBufferPointer { ptr in
        String(cString: ptr.baseAddress!)
    }
    #expect(truncated7.utf8.count == min(7, codecs.utf8.count))
    #expect(codecs.hasPrefix(truncated7))

    var buf1 = [CChar](repeating: 0x5A, count: 1)
    hdr_libavif_codec_versions(&buf1, buf1.count)
    #expect(buf1[0] == 0)

    var sentinel = [CChar](repeating: 0x41, count: 4)
    hdr_libavif_codec_versions(&sentinel, 0)
    #expect(sentinel == [0x41, 0x41, 0x41, 0x41])

    hdr_libavif_codec_versions(nil, 8)
    hdr_libavif_codec_versions(nil, 0)
}

@Test
func testCLibAVIFGridPlannerCanonicalAndBoundaryCases() {
    var err = [CChar](repeating: 0, count: 256)

    func plan(_ w: UInt32, _ h: UInt32, _ gmw: UInt32, _ gmh: UInt32, _ ch: UInt32 = 3) -> (HDRAVIFStatus, HDRAVIFGridPlan) {
        var p = HDRAVIFGridPlan()
        let st = hdr_avif_plan_grid(w, h, gmw, gmh, ch, &p, &err, err.count)
        return (st, p)
    }

    // Canonical Sony resolutions (L&P)
    let cases: [(UInt32, UInt32, UInt32, UInt32)] = [
        (6000, 4000, 2, 2),
        (4000, 6000, 2, 2),
        (7008, 4672, 4, 2),
        (4672, 7008, 2, 4),
        (7952, 5304, 4, 2),
        (5304, 7952, 2, 4),
        (9504, 6336, 4, 3),
        (6336, 9504, 3, 4),
    ]
    for (w, h, expCols, expRows) in cases {
        let (st, p) = plan(w, h, w / 2, h / 2, 3)
        #expect(st == HDR_AVIF_OK)
        #expect(p.use_grid == 1)
        #expect(p.cols == expCols)
        #expect(p.rows == expRows)
        #expect(p.base_tile_width <= 4096 && p.base_tile_height <= 4096)
        #expect(UInt64(p.base_tile_width) * UInt64(p.base_tile_height) <= 8_912_896)
        #expect(p.gm_tile_width >= 64 && p.gm_tile_height >= 64)
        #expect(p.gm_last_width >= 64 && p.gm_last_height >= 64)
    }

    // Boundary 4096x2176 = 8,912,896 -> no grid
    let (stExact, pExact) = plan(4096, 2176, 2048, 1088, 3)
    #expect(stExact == HDR_AVIF_OK)
    #expect(pExact.use_grid == 0)

    // Boundary 4096x2180 = 8,929,280 > 8,912,896 -> grid
    let (stOverArea, pOverArea) = plan(4096, 2180, 2048, 1090, 3)
    #expect(stOverArea == HDR_AVIF_OK)
    #expect(pOverArea.use_grid == 1)

    // Boundary 4100x2000 (width > 4096) -> grid
    let (stOverDim, pOverDim) = plan(4100, 2000, 2050, 1000, 3)
    #expect(stOverDim == HDR_AVIF_OK)
    #expect(pOverDim.use_grid == 1)
    #expect(pOverDim.gm_last_width >= 64 && pOverDim.gm_last_width % 2 == 0)

    // Arbitrary crops
    for (w, h) in [(5200 as UInt32, 3800 as UInt32), (4160, 4160), (2620, 3800)] {
        let (st, p) = plan(w, h, w / 2, h / 2, 3)
        #expect(st == HDR_AVIF_OK)
        #expect(p.use_grid == 1)
        #expect(p.base_last_width <= p.base_tile_width)
        #expect(p.base_last_height <= p.base_tile_height)
        #expect(p.gm_last_width >= 64 && p.gm_last_height >= 64)
        #expect(p.gm_tile_width % 2 == 0 && p.gm_last_width % 2 == 0)
    }

    // Negative: odd 0.5x GM width in 3ch YUV420 gridded mode
    let (stOdd, _) = plan(4098, 2000, 2049, 1000, 3)
    #expect(stOdd == HDR_AVIF_ERR_INVALID_DIMENSIONS)

    // 4098x4098 1ch 0.5x (YUV400 allows odd GM tile/last dimensions)
    let (st4098Mono, p4098Mono) = plan(4098, 4098, 2049, 2049, 1)
    #expect(st4098Mono == HDR_AVIF_OK)
    #expect(p4098Mono.use_grid == 1)
    #expect(p4098Mono.cols == 2)
    #expect(p4098Mono.rows == 2)
    #expect(p4098Mono.gm_last_width == 993)
    #expect(p4098Mono.gm_last_height == 993)

    // Tiny 64x64 (no grid)
    let (st64, p64) = plan(64, 64, 32, 32, 3)
    #expect(st64 == HDR_AVIF_OK)
    #expect(p64.use_grid == 0)
    #expect(p64.cols == 1)
    #expect(p64.rows == 1)
    #expect(p64.base_tile_width == 64)
    #expect(p64.base_tile_height == 64)

    // 4098x64: valid with 1x GM or SDR-only, rejected with 0.5x GM (height 64 < min_cell 128)
    let (st4098x64, p4098x64) = plan(4098, 64, 4098, 64, 3)
    #expect(st4098x64 == HDR_AVIF_OK)
    #expect(p4098x64.use_grid == 1)
    #expect(p4098x64.cols == 2)
    #expect(p4098x64.rows == 1)
    #expect(p4098x64.base_tile_height == 64)
    #expect(p4098x64.base_last_height == 64)

    let (st4098x64Half, _) = plan(4098, 64, 2049, 32, 1)
    #expect(st4098x64Half == HDR_AVIF_ERR_INVALID_DIMENSIONS)
}

@Test
func testCLibAVIFEncodeGridLandscapeAndPortraitSVTAndAOMMonoFallback() throws {
    let p3Space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let p3ICC = try #require(p3Space.copyICCData() as Data?)
    let cleanTIFF = makeMinimalCleanExifTIFF(make: "SONY", model: "ILCE-7CM2", orientation: 1, includeExifPrefix: false)

    let tmpDir = try makeTempDirectory(prefix: "chiaro-avif-test")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let avifdecPath = repoRoot.appendingPathComponent("Vendor/install/bin/avifdec").path
    let gainmapUtilPath = repoRoot.appendingPathComponent("Vendor/install/bin/avifgainmaputil").path

    func encodeAndVerifyGrid(width: Int, height: Int, tag: String) throws {
        let baseCount = width * height * 4
        var basePixels = [UInt16](repeating: 0, count: baseCount)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                basePixels[idx + 0] = UInt16((x * 65535) / max(1, width - 1))
                basePixels[idx + 1] = UInt16((y * 65535) / max(1, height - 1))
                basePixels[idx + 2] = 32768
                basePixels[idx + 3] = 65535
            }
        }

        let gmW = width / 2
        let gmH = height / 2
        var gmPixels = [UInt8](repeating: 255, count: gmW * gmH * 4)
        for y in 0..<gmH {
            for x in 0..<gmW {
                let idx = (y * gmW + x) * 4
                let v: UInt8 = (x >= gmW / 2) ? 255 : 0
                gmPixels[idx + 0] = v
                gmPixels[idx + 1] = v
                gmPixels[idx + 2] = v
                gmPixels[idx + 3] = 255
            }
        }

        let offset = 1.0 / 64.0
        let meta = HDRAVIFGainMapMetadata(
            gain_map_min: (0.0, 0.0, 0.0),
            gain_map_max: (2.5, 2.5, 2.5),
            gain_map_gamma: (1.0, 1.0, 1.0),
            base_offset: (offset, offset, offset),
            alternate_offset: (offset, offset, offset),
            base_hdr_headroom_stops: 0.0,
            alternate_hdr_headroom_stops: 2.5,
            use_base_color_space: 1
        )

        var outBuf = HDRAVIFBuffer()
        var errBuf = [CChar](repeating: 0, count: 512)
        defer { hdr_libavif_free_buffer(&outBuf) }

        let status = basePixels.withUnsafeBytes { bPtr in
            gmPixels.withUnsafeBytes { gPtr in
                p3ICC.withUnsafeBytes { iccPtr in
                    cleanTIFF.withUnsafeBytes { exifPtr in
                        var req = HDRAVIFEncodeRequest(
                            base_pixels: bPtr.bindMemory(to: UInt8.self).baseAddress,
                            base_width: UInt32(width),
                            base_height: UInt32(height),
                            base_row_bytes: UInt32(width * 4 * 2),
                            base_pixel_format: HDR_AVIF_PIXFMT_RGBA16,
                            target_bit_depth: 10,
                            color_primaries: HDR_AVIF_PRIMARIES_DISPLAY_P3,
                            gain_map_pixels: gPtr.bindMemory(to: UInt8.self).baseAddress,
                            gain_map_width: UInt32(gmW),
                            gain_map_height: UInt32(gmH),
                            gain_map_row_bytes: UInt32(gmW * 4),
                            gain_map_pixel_format: HDR_AVIF_PIXFMT_BGRA8,
                            gain_map_channels: 3,
                            gain_map_meta: meta,
                            icc_data: iccPtr.bindMemory(to: UInt8.self).baseAddress,
                            icc_size: p3ICC.count,
                            exif_data: exifPtr.bindMemory(to: UInt8.self).baseAddress,
                            exif_size: cleanTIFF.count,
                            codec: HDR_AVIF_CODEC_SVT,
                            quality: 75,
                            gain_map_quality: 75,
                            speed: 8,
                            max_threads: 4,
                            enable_tune_iq: 1
                        )
                        return hdr_avif_encode(&req, &outBuf, &errBuf, errBuf.count)
                    }
                }
            }
        }

        #expect(status == HDR_AVIF_OK)
        #expect(outBuf.used_grid_tiling == 1)
        #expect(outBuf.grid_columns == 2)
        #expect(outBuf.grid_rows == 2)
        #expect(outBuf.actual_codec == HDR_AVIF_CODEC_SVT)
        #expect(outBuf.size > 0)

        let avifData = Data(bytes: outBuf.data, count: outBuf.size)
        let avifURL = tmpDir.appendingPathComponent("grid_\(tag).avif")
        try avifData.write(to: avifURL)

        // Apple ImageIO verification
        let src = try #require(CGImageSourceCreateWithData(avifData as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyDepth] as? Int) == 10)
        #expect((props[kCGImagePropertyOrientation] as? Int) == 1)

        let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        #expect(aux != nil)

        let hdrDecodeOpts: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
        let hdrImage = try #require(CGImageSourceCreateImageAtIndex(src, 0, hdrDecodeOpts as CFDictionary))
        let headroom = Double(hdrImage.contentHeadroom)
        let expectedHeadroom = exp2(2.5) // 5.656854
        #expect(abs(headroom - expectedHeadroom) / expectedHeadroom < 0.02)

        // Vendor CLI tools verification
        if FileManager.default.isExecutableFile(atPath: avifdecPath) {
            let decRes = try runCLI(avifdecPath, arguments: ["--info", "--depth", "16", avifURL.path])
            #expect(decRes.status == 0)
            #expect(decRes.stdout.contains("\(width)x\(height)"))
            #expect(decRes.stdout.contains("Bit Depth      : 10"))
            #expect(decRes.stdout.contains("YUV420"))
            #expect(decRes.stdout.contains("Range          : Full"))
            #expect(decRes.stdout.contains("Color Primaries: 12"))
            #expect(decRes.stdout.contains("Transfer Char. : 13"))
            #expect(decRes.stdout.contains("Matrix Coeffs. : 6"))
            #expect(decRes.stdout.contains("ICC Profile    : Present"))
            #expect(decRes.stdout.contains("Exif Metadata  : Present"))
            #expect(decRes.stdout.contains("Gain map       : \(gmW)x\(gmH)"))
        }

        if FileManager.default.isExecutableFile(atPath: gainmapUtilPath) {
            let gmMetaRes = try runCLI(gainmapUtilPath, arguments: ["printmetadata", avifURL.path])
            #expect(gmMetaRes.status == 0)
            #expect(gmMetaRes.stdout.contains("Alternate headroom: 2.5"))
        }
    }

    // Landscape 4160x2800 (2x2 grid) and Portrait 2800x4160 (2x2 grid)
    try encodeAndVerifyGrid(width: 4160, height: 2800, tag: "landscape")
    try encodeAndVerifyGrid(width: 2800, height: 4160, tag: "portrait")

    // 1ch GRAY8 AOM fallback when requesting SVT-AV1
    let w = 256
    let h = 256
    let basePixels = [UInt16](repeating: 32768, count: w * h * 4)
    let gmGray = [UInt8](repeating: 192, count: (w / 2) * (h / 2))
    let offset = 1.0 / 64.0
    let meta = HDRAVIFGainMapMetadata(
        gain_map_min: (0.0, 0.0, 0.0),
        gain_map_max: (2.5, 2.5, 2.5),
        gain_map_gamma: (1.0, 1.0, 1.0),
        base_offset: (offset, offset, offset),
        alternate_offset: (offset, offset, offset),
        base_hdr_headroom_stops: 0.0,
        alternate_hdr_headroom_stops: 2.5,
        use_base_color_space: 1
    )

    var monoBuf = HDRAVIFBuffer()
    var errBuf = [CChar](repeating: 0, count: 512)
    defer { hdr_libavif_free_buffer(&monoBuf) }

    let monoStatus = basePixels.withUnsafeBytes { bPtr in
        gmGray.withUnsafeBytes { gPtr in
            p3ICC.withUnsafeBytes { iccPtr in
                var req = HDRAVIFEncodeRequest(
                    base_pixels: bPtr.bindMemory(to: UInt8.self).baseAddress,
                    base_width: UInt32(w),
                    base_height: UInt32(h),
                    base_row_bytes: UInt32(w * 4 * 2),
                    base_pixel_format: HDR_AVIF_PIXFMT_RGBA16,
                    target_bit_depth: 10,
                    color_primaries: HDR_AVIF_PRIMARIES_DISPLAY_P3,
                    gain_map_pixels: gPtr.bindMemory(to: UInt8.self).baseAddress,
                    gain_map_width: UInt32(w / 2),
                    gain_map_height: UInt32(h / 2),
                    gain_map_row_bytes: UInt32(w / 2),
                    gain_map_pixel_format: HDR_AVIF_PIXFMT_GRAY8,
                    gain_map_channels: 1,
                    gain_map_meta: meta,
                    icc_data: iccPtr.bindMemory(to: UInt8.self).baseAddress,
                    icc_size: p3ICC.count,
                    exif_data: nil,
                    exif_size: 0,
                    codec: HDR_AVIF_CODEC_SVT,
                    quality: 80,
                    gain_map_quality: 80,
                    speed: 6,
                    max_threads: 4,
                    enable_tune_iq: 1
                )
                return hdr_avif_encode(&req, &monoBuf, &errBuf, errBuf.count)
            }
        }
    }
    #expect(monoStatus == HDR_AVIF_OK)
    #expect(monoBuf.actual_codec == HDR_AVIF_CODEC_AOM)
    #expect(monoBuf.used_grid_tiling == 0)

    let monoData = Data(bytes: monoBuf.data, count: monoBuf.size)
    let monoSrc = try #require(CGImageSourceCreateWithData(monoData as CFData, nil))
    #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(monoSrc, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil)

    if FileManager.default.isExecutableFile(atPath: gainmapUtilPath),
       FileManager.default.isExecutableFile(atPath: avifdecPath) {
        let monoURL = tmpDir.appendingPathComponent("mono1ch.avif")
        let extractedGM = tmpDir.appendingPathComponent("extracted_gm.avif")
        try monoData.write(to: monoURL)

        let extRes = try runCLI(gainmapUtilPath, arguments: ["extractgainmap", monoURL.path, extractedGM.path])
        #expect(extRes.status == 0)

        let gmInfo = try runCLI(avifdecPath, arguments: ["--info", extractedGM.path])
        #expect(gmInfo.status == 0)
        #expect(gmInfo.stdout.contains("YUV400"))
    }
}

@Test
func testCLibAVIFNullAndInvalidArgsSafety() {
    var out = HDRAVIFBuffer()
    var err = [CChar](repeating: 0, count: 256)

    #expect(hdr_avif_encode(nil, &out, &err, err.count) == HDR_AVIF_ERR_INVALID_ARGUMENT)
    #expect(hdr_avif_encode(nil, nil, &err, err.count) == HDR_AVIF_ERR_INVALID_ARGUMENT)

    let dummy = [UInt8](repeating: 0, count: 64 * 64 * 4)
    let badStatus = dummy.withUnsafeBytes { ptr in
        var req = HDRAVIFEncodeRequest()
        req.base_pixels = ptr.bindMemory(to: UInt8.self).baseAddress
        req.base_width = 64
        req.base_height = 64
        req.base_row_bytes = 64 * 4
        req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA8
        req.target_bit_depth = 12 // invalid: only 8 or 10 supported
        req.color_primaries = HDR_AVIF_PRIMARIES_DISPLAY_P3
        return hdr_avif_encode(&req, &out, &err, err.count)
    }
    #expect(badStatus == HDR_AVIF_ERR_INVALID_ARGUMENT)

    // Invalid codec enum -> HDR_AVIF_ERR_INVALID_ARGUMENT
    let badCodecStatus = dummy.withUnsafeBytes { ptr in
        var req = HDRAVIFEncodeRequest()
        req.base_pixels = ptr.bindMemory(to: UInt8.self).baseAddress
        req.base_width = 64
        req.base_height = 64
        req.base_row_bytes = 64 * 4
        req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA8
        req.target_bit_depth = 10
        req.color_primaries = HDR_AVIF_PRIMARIES_DISPLAY_P3
        req.codec = HDRAVIFCodec(rawValue: 99)
        return hdr_avif_encode(&req, &out, &err, err.count)
    }
    #expect(badCodecStatus == HDR_AVIF_ERR_INVALID_ARGUMENT)

    // Extreme width that would overflow uint32_t row bytes if not computed in uint64_t
    let overflowStrideStatus = dummy.withUnsafeBytes { ptr in
        var req = HDRAVIFEncodeRequest()
        req.base_pixels = ptr.bindMemory(to: UInt8.self).baseAddress
        req.base_width = 0x4000_0000
        req.base_height = 64
        req.base_row_bytes = 256
        req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA16
        req.target_bit_depth = 10
        req.color_primaries = HDR_AVIF_PRIMARIES_DISPLAY_P3
        req.codec = HDR_AVIF_CODEC_SVT
        return hdr_avif_encode(&req, &out, &err, err.count)
    }
    #expect(overflowStrideStatus == HDR_AVIF_ERR_INVALID_ARGUMENT)

    // libavif-stage failure with out_error == nil and error_capacity == 256 (must NOT segfault / UB)
    // Passing gain_map_min > gain_map_max passes bridge-level checks and fails inside libavif's
    // avifEncoderAddImage -> avifGainMapValidateMetadata, directly exercising set_errorf(nil, 256/0, ...).
    let gmDummy = [UInt8](repeating: 128, count: 32 * 32)
    let badGMMeta = HDRAVIFGainMapMetadata(
        gain_map_min: (2.0, 2.0, 2.0),
        gain_map_max: (1.0, 1.0, 1.0),
        gain_map_gamma: (1.0, 1.0, 1.0),
        base_offset: (1.0 / 64.0, 1.0 / 64.0, 1.0 / 64.0),
        alternate_offset: (1.0 / 64.0, 1.0 / 64.0, 1.0 / 64.0),
        base_hdr_headroom_stops: 0.0,
        alternate_hdr_headroom_stops: 2.5,
        use_base_color_space: 1
    )
    let nilErrNonZeroCapStatus = dummy.withUnsafeBytes { bPtr in
        gmDummy.withUnsafeBytes { gPtr in
            var req = HDRAVIFEncodeRequest()
            req.base_pixels = bPtr.bindMemory(to: UInt8.self).baseAddress
            req.base_width = 64
            req.base_height = 64
            req.base_row_bytes = 64 * 4
            req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA8
            req.target_bit_depth = 10
            req.color_primaries = HDR_AVIF_PRIMARIES_DISPLAY_P3
            req.gain_map_pixels = gPtr.bindMemory(to: UInt8.self).baseAddress
            req.gain_map_width = 32
            req.gain_map_height = 32
            req.gain_map_row_bytes = 32
            req.gain_map_pixel_format = HDR_AVIF_PIXFMT_GRAY8
            req.gain_map_channels = 1
            req.gain_map_meta = badGMMeta
            req.codec = HDR_AVIF_CODEC_AOM
            req.quality = 80
            req.speed = 8
            return hdr_avif_encode(&req, &out, nil, 256)
        }
    }
    #expect(nilErrNonZeroCapStatus == HDR_AVIF_ERR_ENCODE_FAILED)

    let nilErrZeroCapStatus = dummy.withUnsafeBytes { bPtr in
        gmDummy.withUnsafeBytes { gPtr in
            var req = HDRAVIFEncodeRequest()
            req.base_pixels = bPtr.bindMemory(to: UInt8.self).baseAddress
            req.base_width = 64
            req.base_height = 64
            req.base_row_bytes = 64 * 4
            req.base_pixel_format = HDR_AVIF_PIXFMT_RGBA8
            req.target_bit_depth = 10
            req.color_primaries = HDR_AVIF_PRIMARIES_DISPLAY_P3
            req.gain_map_pixels = gPtr.bindMemory(to: UInt8.self).baseAddress
            req.gain_map_width = 32
            req.gain_map_height = 32
            req.gain_map_row_bytes = 32
            req.gain_map_pixel_format = HDR_AVIF_PIXFMT_GRAY8
            req.gain_map_channels = 1
            req.gain_map_meta = badGMMeta
            req.codec = HDR_AVIF_CODEC_AOM
            req.quality = 80
            req.speed = 8
            return hdr_avif_encode(&req, &out, nil, 0)
        }
    }
    #expect(nilErrZeroCapStatus == HDR_AVIF_ERR_ENCODE_FAILED)

    hdr_libavif_free_buffer(&out)
    hdr_libavif_free_buffer(nil)
}

@Test
func testCLibAVIFLosslessAOMWithTuneIQAndMonoFallback() {
    let w = 64
    let h = 64
    let basePixels = [UInt16](repeating: 32768, count: w * h * 4)
    let gmGray = [UInt8](repeating: 192, count: (w / 2) * (h / 2))
    let gmBGRA = [UInt8](repeating: 192, count: (w / 2) * (h / 2) * 4)
    let offset = 1.0 / 64.0
    let meta = HDRAVIFGainMapMetadata(
        gain_map_min: (0.0, 0.0, 0.0),
        gain_map_max: (2.5, 2.5, 2.5),
        gain_map_gamma: (1.0, 1.0, 1.0),
        base_offset: (offset, offset, offset),
        alternate_offset: (offset, offset, offset),
        base_hdr_headroom_stops: 0.0,
        alternate_hdr_headroom_stops: 2.5,
        use_base_color_space: 1
    )

    // 1. Direct AOM Q=100 + enable_tune_iq=1 (3ch gain map at Q=100)
    var outAOM = HDRAVIFBuffer()
    var errBuf = [CChar](repeating: 0, count: 512)
    defer { hdr_libavif_free_buffer(&outAOM) }

    let stAOM = basePixels.withUnsafeBytes { bPtr in
        gmBGRA.withUnsafeBytes { gPtr in
            var req = HDRAVIFEncodeRequest(
                base_pixels: bPtr.bindMemory(to: UInt8.self).baseAddress,
                base_width: UInt32(w),
                base_height: UInt32(h),
                base_row_bytes: UInt32(w * 4 * 2),
                base_pixel_format: HDR_AVIF_PIXFMT_RGBA16,
                target_bit_depth: 10,
                color_primaries: HDR_AVIF_PRIMARIES_DISPLAY_P3,
                gain_map_pixels: gPtr.bindMemory(to: UInt8.self).baseAddress,
                gain_map_width: UInt32(w / 2),
                gain_map_height: UInt32(h / 2),
                gain_map_row_bytes: UInt32((w / 2) * 4),
                gain_map_pixel_format: HDR_AVIF_PIXFMT_BGRA8,
                gain_map_channels: 3,
                gain_map_meta: meta,
                icc_data: nil,
                icc_size: 0,
                exif_data: nil,
                exif_size: 0,
                codec: HDR_AVIF_CODEC_AOM,
                quality: 100,
                gain_map_quality: 100,
                speed: 8,
                max_threads: 4,
                enable_tune_iq: 1
            )
            return hdr_avif_encode(&req, &outAOM, &errBuf, errBuf.count)
        }
    }
    #expect(stAOM == HDR_AVIF_OK)
    #expect(outAOM.actual_codec == HDR_AVIF_CODEC_AOM)
    #expect(outAOM.size > 0)

    // 2. 1ch SVT->AOM fallback at Q=100 + enable_tune_iq=1 (and mixed Q=80, gain_map_quality=100)
    var outMono = HDRAVIFBuffer()
    defer { hdr_libavif_free_buffer(&outMono) }

    let stMono = basePixels.withUnsafeBytes { bPtr in
        gmGray.withUnsafeBytes { gPtr in
            var req = HDRAVIFEncodeRequest(
                base_pixels: bPtr.bindMemory(to: UInt8.self).baseAddress,
                base_width: UInt32(w),
                base_height: UInt32(h),
                base_row_bytes: UInt32(w * 4 * 2),
                base_pixel_format: HDR_AVIF_PIXFMT_RGBA16,
                target_bit_depth: 10,
                color_primaries: HDR_AVIF_PRIMARIES_DISPLAY_P3,
                gain_map_pixels: gPtr.bindMemory(to: UInt8.self).baseAddress,
                gain_map_width: UInt32(w / 2),
                gain_map_height: UInt32(h / 2),
                gain_map_row_bytes: UInt32(w / 2),
                gain_map_pixel_format: HDR_AVIF_PIXFMT_GRAY8,
                gain_map_channels: 1,
                gain_map_meta: meta,
                icc_data: nil,
                icc_size: 0,
                exif_data: nil,
                exif_size: 0,
                codec: HDR_AVIF_CODEC_SVT,
                quality: 100,
                gain_map_quality: 100,
                speed: 8,
                max_threads: 4,
                enable_tune_iq: 1
            )
            return hdr_avif_encode(&req, &outMono, &errBuf, errBuf.count)
        }
    }
    #expect(stMono == HDR_AVIF_OK)
    #expect(outMono.actual_codec == HDR_AVIF_CODEC_AOM)
    #expect(outMono.size > 0)

    var outMixed = HDRAVIFBuffer()
    defer { hdr_libavif_free_buffer(&outMixed) }

    let stMixed = basePixels.withUnsafeBytes { bPtr in
        gmGray.withUnsafeBytes { gPtr in
            var req = HDRAVIFEncodeRequest(
                base_pixels: bPtr.bindMemory(to: UInt8.self).baseAddress,
                base_width: UInt32(w),
                base_height: UInt32(h),
                base_row_bytes: UInt32(w * 4 * 2),
                base_pixel_format: HDR_AVIF_PIXFMT_RGBA16,
                target_bit_depth: 10,
                color_primaries: HDR_AVIF_PRIMARIES_DISPLAY_P3,
                gain_map_pixels: gPtr.bindMemory(to: UInt8.self).baseAddress,
                gain_map_width: UInt32(w / 2),
                gain_map_height: UInt32(h / 2),
                gain_map_row_bytes: UInt32(w / 2),
                gain_map_pixel_format: HDR_AVIF_PIXFMT_GRAY8,
                gain_map_channels: 1,
                gain_map_meta: meta,
                icc_data: nil,
                icc_size: 0,
                exif_data: nil,
                exif_size: 0,
                codec: HDR_AVIF_CODEC_AOM,
                quality: 80,
                gain_map_quality: 100,
                speed: 8,
                max_threads: 4,
                enable_tune_iq: 1
            )
            return hdr_avif_encode(&req, &outMixed, &errBuf, errBuf.count)
        }
    }
    #expect(stMixed == HDR_AVIF_OK)
    #expect(outMixed.actual_codec == HDR_AVIF_CODEC_AOM)
    #expect(outMixed.size > 0)
}

}

}
