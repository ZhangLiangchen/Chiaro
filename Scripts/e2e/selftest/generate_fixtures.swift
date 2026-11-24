import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

func makeTestImages(width: Int, height: Int, headroomMultiplier: Double) -> (sdr: CIImage, hdr: CIImage) {
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    let base = CIImage(color: CIColor(red: 0.18, green: 0.28, blue: 0.42, alpha: 1.0)).cropped(to: rect)
    let highlightRect = CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2)
    let sdrSpot = CIImage(color: CIColor(red: 0.92, green: 0.90, blue: 0.85, alpha: 1.0)).cropped(to: highlightRect)
    let sdr = sdrSpot.composited(over: base)

    let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let hdrSpot = CIImage(
        color: CIColor(
            red: headroomMultiplier,
            green: headroomMultiplier,
            blue: headroomMultiplier,
            colorSpace: p3
        )!
    ).cropped(to: highlightRect)
    let hdrBase = CIImage(
        color: CIColor(red: 0.18, green: 0.28, blue: 0.42, colorSpace: p3)!
    ).cropped(to: rect)
    let hdr = hdrSpot.composited(over: hdrBase)
    return (sdr, hdr)
}

func cleanExifProperties(orientation: Int = 1, customRendered: Int? = 3, injectMakerNote: Bool = false) -> [String: Any] {
    var exif: [String: Any] = [
        kCGImagePropertyExifLensModel as String: "TAMRON 25-200mm F2.8-5.6 A075 E",
        kCGImagePropertyExifDateTimeOriginal as String: "2026:11:22 18:43:41",
        kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00",
        kCGImagePropertyExifSubsecTimeOriginal as String: "597",
        kCGImagePropertyExifISOSpeedRatings as String: [10000],
        kCGImagePropertyExifFNumber as String: 4.0,
        kCGImagePropertyExifExposureTime as String: 1.0 / 160.0,
        kCGImagePropertyExifFocalLength as String: 49.0,
    ]
    if let cr = customRendered {
        exif[kCGImagePropertyExifCustomRendered as String] = cr
    }
    if injectMakerNote {
        exif[kCGImagePropertyExifMakerNote as String] = Data("SONY DSC SYNTHETIC MAKERNOTE LEAK\0".utf8)
    }
    let tiff: [String: Any] = [
        kCGImagePropertyTIFFMake as String: "SONY",
        kCGImagePropertyTIFFModel as String: "ILCE-7CM2",
        kCGImagePropertyTIFFOrientation as String: orientation,
    ]
    return [
        kCGImagePropertyOrientation as String: orientation,
        kCGImagePropertyTIFFDictionary as String: tiff,
        kCGImagePropertyExifDictionary as String: exif,
    ]
}

func writePNG(_ ciImage: CIImage, to url: URL, colorSpace: CGColorSpace, format: CIFormat, ctx: CIContext) throws {
    let data = ctx.pngRepresentation(of: ciImage, format: format, colorSpace: colorSpace, options: [:])
    guard let data else {
        throw NSError(domain: "FixtureGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed PNG gen \(url.lastPathComponent)"])
    }
    try data.write(to: url)
}

func writeBadImageIOAVIF(fromValidHEIC heicURL: URL, to url: URL) throws {
    guard let src = CGImageSourceCreateWithURL(heicURL as CFURL, nil),
          let baseCG = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let auxInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap)
    else {
        throw NSError(domain: "FixtureGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to read valid.heic aux info"])
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.avif" as CFString, 1, nil) else {
        throw NSError(domain: "FixtureGen", code: 4, userInfo: [NSLocalizedDescriptionKey: "AVIF dest failed"])
    }
    CGImageDestinationAddImage(dest, baseCG, cleanExifProperties() as CFDictionary)
    CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeISOGainMap, auxInfo)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "FixtureGen", code: 5, userInfo: [NSLocalizedDescriptionKey: "AVIF finalize failed"])
    }
}

func fillPixelBuffer(_ pb: CVPixelBuffer, is10Bit: Bool) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let planeCount = CVPixelBufferGetPlaneCount(pb)
    for p in 0..<planeCount {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, p) else { continue }
        let h = CVPixelBufferGetHeightOfPlane(pb, p)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p)
        if is10Bit {
            if p == 0 {
                // Y plane: 10-bit shifted left by 6 in UInt16
                let yVal: UInt16 = 512 << 6
                for row in 0..<h {
                    let rowPtr = (base + row * bpr).assumingMemoryBound(to: UInt16.self)
                    let cols = bpr / 2
                    for col in 0..<cols {
                        rowPtr[col] = yVal
                    }
                }
            } else {
                // CbCr neutral 512 << 6
                let cVal: UInt16 = 512 << 6
                for row in 0..<h {
                    let rowPtr = (base + row * bpr).assumingMemoryBound(to: UInt16.self)
                    let cols = bpr / 2
                    for col in 0..<cols {
                        rowPtr[col] = cVal
                    }
                }
            }
        } else {
            let fill: UInt8 = (p == 0) ? 100 : 128
            for row in 0..<h {
                memset(base + row * bpr, Int32(fill), bpr)
            }
        }
    }
}

func writeVideo(
    to url: URL,
    width: Int,
    height: Int,
    durationSec: Double,
    fps: Int32,
    hlgMain10: Bool
) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    var settings: [String: Any]
    let pixFmt: OSType
    if hlgMain10 {
        pixFmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        settings = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: 14_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
        ]
    } else {
        pixFmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        settings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let pbAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: pixFmt,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: pbAttrs
    )
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? NSError(domain: "FixtureGen", code: 10)
    }
    writer.startSession(atSourceTime: .zero)

    let totalFrames = Int(durationSec * Double(fps))
    for frameIdx in 0..<totalFrames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "FixtureGen", code: 11, userInfo: [NSLocalizedDescriptionKey: "Missing pixelBufferPool"])
        }
        var pbOpt: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt)
        guard let pb = pbOpt else {
            throw NSError(domain: "FixtureGen", code: 12)
        }
        fillPixelBuffer(pb, is10Bit: hlgMain10)
        let pts = CMTime(value: CMTimeValue(frameIdx), timescale: fps)
        adaptor.append(pb, withPresentationTime: pts)
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed {
        throw writer.error ?? NSError(domain: "FixtureGen", code: 13)
    }
}

@main
struct GenerateFixturesMain {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: generate_fixtures <out_dir>\n", stderr)
            exit(2)
        }
        let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let ctx = CIContext()
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let extP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let headroom = pow(2.0, 2.5) // 5.656854
        let (sdr, hdr) = makeTestImages(width: 256, height: 256, headroomMultiplier: headroom)
        let sdrWithExif = sdr.settingProperties(cleanExifProperties(orientation: 1, customRendered: 3))

        do {
            // 1. valid.heic (10-bit P3 + ISO tmap + clean EXIF)
            try ctx.writeHEIF10Representation(
                of: sdrWithExif,
                to: outDir.appendingPathComponent("valid.heic"),
                colorSpace: p3,
                options: [CIImageRepresentationOption.hdrImage: hdr]
            )

            // 2. valid.jpg (8-bit P3 + ISO APP2 + MPF + clean EXIF)
            try ctx.writeJPEGRepresentation(
                of: sdrWithExif,
                to: outDir.appendingPathComponent("valid.jpg"),
                colorSpace: p3,
                options: [CIImageRepresentationOption.hdrImage: hdr]
            )

            // 3. base_sdr.png & alt_hdr.png for avifgainmaputil combine (2x2 grid)
            try writePNG(sdr, to: outDir.appendingPathComponent("base_sdr.png"), colorSpace: p3, format: .RGBA8, ctx: ctx)
            try writePNG(hdr, to: outDir.appendingPathComponent("alt_hdr.png"), colorSpace: extP3, format: .RGBA16, ctx: ctx)

            // 4. bad_no_gainmap.heic
            try ctx.writeHEIF10Representation(
                of: sdrWithExif,
                to: outDir.appendingPathComponent("bad_no_gainmap.heic"),
                colorSpace: p3,
                options: [:]
            )

            // 5. bad_orientation6.jpg
            let sdrOrient6 = sdr.settingProperties(cleanExifProperties(orientation: 6, customRendered: 0))
            try ctx.writeJPEGRepresentation(
                of: sdrOrient6,
                to: outDir.appendingPathComponent("bad_orientation6.jpg"),
                colorSpace: p3,
                options: [CIImageRepresentationOption.hdrImage: hdr]
            )

            // 5b. bad_makernote.jpg
            let sdrMakerNote = sdr.settingProperties(cleanExifProperties(orientation: 1, customRendered: 3, injectMakerNote: true))
            try ctx.writeJPEGRepresentation(
                of: sdrMakerNote,
                to: outDir.appendingPathComponent("bad_makernote.jpg"),
                colorSpace: p3,
                options: [CIImageRepresentationOption.hdrImage: hdr]
            )

            // 6. bad_imageio_tmap.avif (triggers Box[tmap] pasp error in avifdec)
            try writeBadImageIOAVIF(fromValidHEIC: outDir.appendingPathComponent("valid.heic"), to: outDir.appendingPathComponent("bad_imageio_tmap.avif"))

            // 7. valid_hlg.mp4 (1080x1920, 3.0s, 30fps, HEVC Main10 BT.2020 HLG)
            try await writeVideo(
                to: outDir.appendingPathComponent("valid_hlg.mp4"),
                width: 1080,
                height: 1920,
                durationSec: 3.0,
                fps: 30,
                hlgMain10: true
            )

            // 8. bad_sdr_4k.mp4 (2160x3840 H.264 BT.709 SDR)
            try await writeVideo(
                to: outDir.appendingPathComponent("bad_sdr_4k.mp4"),
                width: 2160,
                height: 3840,
                durationSec: 2.0,
                fps: 30,
                hlgMain10: false
            )

            print("OK")
        } catch {
            fputs("Fixture generation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
