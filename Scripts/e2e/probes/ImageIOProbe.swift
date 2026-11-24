import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExifSummary: Codable {
    var make: String?
    var model: String?
    var lensModel: String?
    var dateTimeOriginal: String?
    var offsetTimeOriginal: String?
    var subSecTimeOriginal: String?
    var iso: Double?
    var fNumber: Double?
    var exposureTime: Double?
    var focalLength: Double?
    var customRendered: Int?
    var hasExifMakerNote: Bool
    var makerDictionaries: [String]
}

struct PixelStats: Codable {
    var sampledWidth: Int
    var sampledHeight: Int
    var meanLuma: Double
    var varianceLuma: Double
    var minLuma: Double
    var maxLuma: Double
    var isAllBlack: Bool
}

struct ImageIOProbeOutput: Codable {
    var filePath: String
    var fileSizeBytes: Int64
    var uti: String?
    var imageCount: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    var depth: Int?
    var orientation: Int?
    var colorModel: String?
    var profileName: String?
    var hasISOGainMap: Bool
    var isoGainMapWidth: Int?
    var isoGainMapHeight: Int?
    var isoGainMapBitsPerComponent: Int?
    var hasLegacyHDRGainMap: Bool
    var legacyHDRGainMapWidth: Int?
    var legacyHDRGainMapHeight: Int?
    var hdrDecodeSucceeded: Bool
    var contentHeadroom: Double?
    var sdrDecodeSucceeded: Bool
    var sdrDecodeContentHeadroom: Double?
    var exif: ExifSummary
    var pixelStats: PixelStats?
    var error: String?
}

func computePixelStats(cgImage: CGImage) -> PixelStats? {
    let w = min(cgImage.width, 64)
    let h = min(cgImage.height, 64)
    guard w > 0, h > 0 else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &buffer,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    ctx.interpolationQuality = .low
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    let count = w * h
    var lumas = [Double]()
    lumas.reserveCapacity(count)
    var sum = 0.0
    var minV = 1.0
    var maxV = 0.0
    for i in 0..<count {
        let idx = i * 4
        let r = Double(buffer[idx]) / 255.0
        let g = Double(buffer[idx + 1]) / 255.0
        let b = Double(buffer[idx + 2]) / 255.0
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        lumas.append(y)
        sum += y
        if y < minV { minV = y }
        if y > maxV { maxV = y }
    }
    let mean = sum / Double(count)
    var varSum = 0.0
    for y in lumas {
        let d = y - mean
        varSum += d * d
    }
    let variance = varSum / Double(count)
    return PixelStats(
        sampledWidth: w,
        sampledHeight: h,
        meanLuma: mean,
        varianceLuma: variance,
        minLuma: minV,
        maxLuma: maxV,
        isAllBlack: maxV < 1e-6
    )
}

func probeImage(path: String) -> ImageIOProbeOutput {
    let url = URL(fileURLWithPath: path)
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

    let emptyExif = ExifSummary(
        make: nil,
        model: nil,
        lensModel: nil,
        dateTimeOriginal: nil,
        offsetTimeOriginal: nil,
        subSecTimeOriginal: nil,
        iso: nil,
        fNumber: nil,
        exposureTime: nil,
        focalLength: nil,
        customRendered: nil,
        hasExifMakerNote: false,
        makerDictionaries: []
    )

    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return ImageIOProbeOutput(
            filePath: path,
            fileSizeBytes: fileSize,
            uti: nil,
            imageCount: 0,
            pixelWidth: nil,
            pixelHeight: nil,
            depth: nil,
            orientation: nil,
            colorModel: nil,
            profileName: nil,
            hasISOGainMap: false,
            isoGainMapWidth: nil,
            isoGainMapHeight: nil,
            isoGainMapBitsPerComponent: nil,
            hasLegacyHDRGainMap: false,
            legacyHDRGainMapWidth: nil,
            legacyHDRGainMapHeight: nil,
            hdrDecodeSucceeded: false,
            contentHeadroom: nil,
            sdrDecodeSucceeded: false,
            sdrDecodeContentHeadroom: nil,
            exif: emptyExif,
            pixelStats: nil,
            error: "Failed to open CGImageSource"
        )
    }

    let uti = CGImageSourceGetType(source) as String?
    let count = CGImageSourceGetCount(source)
    let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]

    let pixelWidth = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
    let pixelHeight = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
    let depth = (props[kCGImagePropertyDepth as String] as? NSNumber)?.intValue
    let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
    let colorModel = props[kCGImagePropertyColorModel as String] as? String
    let profileName = props[kCGImagePropertyProfileName as String] as? String

    let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    let exifDict = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
    let exifAux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]

    let isoArr = exifDict?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
    let makerDicts = props.keys.filter { $0.contains("Maker") }.sorted()
    let hasExifMakerNote = exifDict?[kCGImagePropertyExifMakerNote as String] != nil

    let exif = ExifSummary(
        make: tiff?[kCGImagePropertyTIFFMake as String] as? String,
        model: tiff?[kCGImagePropertyTIFFModel as String] as? String,
        lensModel: (exifDict?[kCGImagePropertyExifLensModel as String] as? String)
            ?? (exifAux?[kCGImagePropertyExifAuxLensModel as String] as? String),
        dateTimeOriginal: exifDict?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
        offsetTimeOriginal: exifDict?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
        subSecTimeOriginal: exifDict?[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
        iso: isoArr?.first?.doubleValue,
        fNumber: (exifDict?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue,
        exposureTime: (exifDict?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
        focalLength: (exifDict?[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue,
        customRendered: (exifDict?[kCGImagePropertyExifCustomRendered as String] as? NSNumber)?.intValue,
        hasExifMakerNote: hasExifMakerNote,
        makerDictionaries: makerDicts
    )

    let isoAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeISOGainMap
    ) as? [String: Any]
    let isoDesc = isoAux?[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any]
    let hasISOGainMap = (isoAux != nil)
    let isoGMW = (isoDesc?["Width"] as? NSNumber)?.intValue
    let isoGMH = (isoDesc?["Height"] as? NSNumber)?.intValue
    let isoGMBits = (isoDesc?["BitsPerComponent"] as? NSNumber)?.intValue

    let legacyAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
    ) as? [String: Any]
    let legacyDesc = legacyAux?[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any]
    let hasLegacyHDRGainMap = (legacyAux != nil)
    let legacyGMW = (legacyDesc?["Width"] as? NSNumber)?.intValue
    let legacyGMH = (legacyDesc?["Height"] as? NSNumber)?.intValue

    let hdrOpts: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
    ]
    let hdrImage = CGImageSourceCreateImageAtIndex(source, 0, hdrOpts as CFDictionary)
    let hdrDecodeSucceeded = (hdrImage != nil)
    let contentHeadroom: Double? = hdrImage.map { hdr in
        if let ciImage = CIImage(contentsOf: url, options: [.expandToHDR: true]) {
            return Double(ciImage.contentHeadroom)
        }
        return Double(hdr.contentHeadroom)
    }

    let sdrOpts: [CFString: Any] = [
        kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
    ]
    let sdrImage = CGImageSourceCreateImageAtIndex(source, 0, sdrOpts as CFDictionary)
    let sdrDecodeSucceeded = (sdrImage != nil)
    let sdrDecodeHeadroom = sdrImage.map { Double($0.contentHeadroom) }
    let pixelStats = sdrImage.flatMap { computePixelStats(cgImage: $0) }

    return ImageIOProbeOutput(
        filePath: path,
        fileSizeBytes: fileSize,
        uti: uti,
        imageCount: count,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        depth: depth,
        orientation: orientation,
        colorModel: colorModel,
        profileName: profileName,
        hasISOGainMap: hasISOGainMap,
        isoGainMapWidth: isoGMW,
        isoGainMapHeight: isoGMH,
        isoGainMapBitsPerComponent: isoGMBits,
        hasLegacyHDRGainMap: hasLegacyHDRGainMap,
        legacyHDRGainMapWidth: legacyGMW,
        legacyHDRGainMapHeight: legacyGMH,
        hdrDecodeSucceeded: hdrDecodeSucceeded,
        contentHeadroom: contentHeadroom,
        sdrDecodeSucceeded: sdrDecodeSucceeded,
        sdrDecodeContentHeadroom: sdrDecodeHeadroom,
        exif: exif,
        pixelStats: pixelStats,
        error: nil
    )
}

if CommandLine.arguments.count < 2 {
    fputs("Usage: ImageIOProbe <image-path>\n", stderr)
    exit(2)
}

let result = probeImage(path: CommandLine.arguments[1])
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let data = try? encoder.encode(result), let str = String(data: data, encoding: .utf8) {
    print(str)
    exit(result.error == nil ? 0 : 1)
} else {
    fputs("Failed to encode JSON output\n", stderr)
    exit(2)
}
