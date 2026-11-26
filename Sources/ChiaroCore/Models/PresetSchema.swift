import Foundation

public enum OutputFormat: String, Sendable, Codable, CaseIterable, Hashable {
    case heic
    case jpeg
    case avif
    case hlgMP4

    public var fileExtension: String {
        switch self {
        case .heic: return "heic"
        case .jpeg: return "jpg"
        case .avif: return "avif"
        case .hlgMP4: return "mp4"
        }
    }
}

public enum BitDepth: Int, Sendable, Codable, CaseIterable, Hashable {
    case bit8 = 8
    case bit10 = 10
}

public enum BaseColorSpace: String, Sendable, Codable, CaseIterable, Hashable {
    case displayP3
    case srgb
}

public enum GainMapChannels: String, Sendable, Codable, CaseIterable, Hashable {
    case mono1ch
    case rgb3ch
}

public enum GainMapResolution: String, Sendable, Codable, CaseIterable, Hashable {
    case half
    case full
}

public enum SDRToneMapper: String, Sendable, Codable, CaseIterable, Hashable {
    case agx
    case sigmoid
    case neutralRational
    case openDRT
}

public enum AspectRatio: String, Sendable, Codable, CaseIterable, Hashable {
    case original = "original"
    case ratio3x4 = "3:4"
    case ratio4x5 = "4:5"
    case ratio1x1 = "1:1"
    case ratio4x3 = "4:3"
    case ratio9x16 = "9:16"

    public var numericRatio: Double? {
        switch self {
        case .original: return nil
        case .ratio3x4: return 3.0 / 4.0
        case .ratio4x5: return 4.0 / 5.0
        case .ratio1x1: return 1.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio9x16: return 9.0 / 16.0
        }
    }
}

public enum AVIFCodecChoice: String, Sendable, Codable, CaseIterable, Hashable {
    case svtAV1
    case libaom
}

public enum HLGVideoAspect: String, Sendable, Codable, CaseIterable, Hashable {
    case portrait9x16 = "9:16"
    case portrait3x4 = "3:4"

    public var dimensions: PixelDimensions {
        switch self {
        case .portrait9x16: return PixelDimensions(width: 1080, height: 1920)
        case .portrait3x4: return PixelDimensions(width: 1080, height: 1440)
        }
    }
}

public enum BuiltInPresetID: String, Sendable, Codable, CaseIterable, Hashable {
    case appleHEIC = "apple_heic"
    case appleHEICCompat = "apple_heic_compat"
    case xiaohongshuJPG = "xiaohongshu_jpg"
    case douyinJPG = "douyin_jpg"
    case douyinHLGMP4 = "douyin_hlg_mp4"
    case triFormat = "tri_format"
    case avifArchive = "avif_archive"
}

public struct CompatibilityOptions: Sendable, Codable, Equatable, Hashable {
    public var writeLegacyAppleHDRGainMap: Bool
    public var writeUltrahdrXMP: Bool
    public var writeCustomRenderedHDR: Bool
    public var closedLoopSDRCompensation: Bool

    public init(
        writeLegacyAppleHDRGainMap: Bool = false,
        writeUltrahdrXMP: Bool = false,
        writeCustomRenderedHDR: Bool = false,
        closedLoopSDRCompensation: Bool = false
    ) {
        self.writeLegacyAppleHDRGainMap = writeLegacyAppleHDRGainMap
        self.writeUltrahdrXMP = writeUltrahdrXMP
        self.writeCustomRenderedHDR = writeCustomRenderedHDR
        self.closedLoopSDRCompensation = closedLoopSDRCompensation
    }
}

public struct HLGVideoOptions: Sendable, Codable, Equatable, Hashable {
    public var aspect: HLGVideoAspect
    public var durationSeconds: Double
    public var fps: Int
    public var bitrateMbps: Double

    public init(
        aspect: HLGVideoAspect = .portrait9x16,
        durationSeconds: Double = 4.0,
        fps: Int = 30,
        bitrateMbps: Double = 14.0
    ) {
        self.aspect = aspect
        self.durationSeconds = durationSeconds
        self.fps = fps
        self.bitrateMbps = bitrateMbps
    }
}

public struct PresetSchema: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var outputFormats: [OutputFormat]
    public var bitDepth: BitDepth
    public var baseColorSpace: BaseColorSpace
    public var gainMapChannels: GainMapChannels
    public var gainMapResolution: GainMapResolution
    public var gainMapGamma: Double
    public var targetHeadroomStops: Double
    public var midtoneAnchorP: Double
    public var sdrToneMapper: SDRToneMapper
    public var developDefaults: DevelopParameters
    public var cropAspect: AspectRatio
    public var maxLongEdge: Int?
    public var targetMaxFileBytes: Int?
    public var quality: Double
    public var gainMapQuality: Double?
    public var avifCodec: AVIFCodecChoice
    public var compatOptions: CompatibilityOptions
    public var hlgVideoOptions: HLGVideoOptions?
    public var platformAdvisory: String

    public init(
        id: String,
        name: String,
        description: String,
        outputFormats: [OutputFormat],
        bitDepth: BitDepth,
        baseColorSpace: BaseColorSpace,
        gainMapChannels: GainMapChannels,
        gainMapResolution: GainMapResolution,
        gainMapGamma: Double,
        targetHeadroomStops: Double,
        midtoneAnchorP: Double,
        sdrToneMapper: SDRToneMapper,
        developDefaults: DevelopParameters,
        cropAspect: AspectRatio,
        maxLongEdge: Int?,
        targetMaxFileBytes: Int?,
        quality: Double,
        gainMapQuality: Double?,
        avifCodec: AVIFCodecChoice,
        compatOptions: CompatibilityOptions,
        hlgVideoOptions: HLGVideoOptions?,
        platformAdvisory: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.outputFormats = outputFormats
        self.bitDepth = bitDepth
        self.baseColorSpace = baseColorSpace
        self.gainMapChannels = gainMapChannels
        self.gainMapResolution = gainMapResolution
        self.gainMapGamma = gainMapGamma
        self.targetHeadroomStops = targetHeadroomStops
        self.midtoneAnchorP = midtoneAnchorP
        self.sdrToneMapper = sdrToneMapper
        self.developDefaults = developDefaults
        self.cropAspect = cropAspect
        self.maxLongEdge = maxLongEdge
        self.targetMaxFileBytes = targetMaxFileBytes
        self.quality = quality
        self.gainMapQuality = gainMapQuality
        self.avifCodec = avifCodec
        self.compatOptions = compatOptions
        self.hlgVideoOptions = hlgVideoOptions
        self.platformAdvisory = platformAdvisory
    }

    public var targetHeadroom: HeadroomStops {
        HeadroomStops(log2Value: targetHeadroomStops)
    }

    public var qualityPercent: Int {
        Int((quality * 100.0).rounded())
    }

    public var effectiveGainMapQuality: Double {
        gainMapQuality ?? quality
    }

    public var effectiveGainMapQualityPercent: Int {
        Int((effectiveGainMapQuality * 100.0).rounded())
    }

    public func effectiveGainMapChannels(for format: OutputFormat) -> GainMapChannels {
        if format == .jpeg && compatOptions.writeUltrahdrXMP {
            return .mono1ch
        }
        return gainMapChannels
    }

    public func effectiveBitDepth(for format: OutputFormat) -> BitDepth {
        switch format {
        case .jpeg: return .bit8
        case .hlgMP4: return .bit10
        case .heic, .avif: return bitDepth
        }
    }
}
