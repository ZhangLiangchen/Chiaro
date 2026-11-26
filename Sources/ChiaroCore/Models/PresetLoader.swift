import Foundation

public enum PresetValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyPresetID
    case emptyOutputFormats
    case duplicateOutputFormats
    case legacyAppleGainMapRequiresMono1ch
    case ultrahdrXMPRequiresMono1chForJPEGOnly
    case jpegOnlyPresetMustBe8Bit
    case midtoneAnchorOutOfBounds(Double)
    case targetHeadroomOutOfBounds(Double)
    case gainMapGammaOutOfBounds(Double)
    case qualityOutOfBounds(Double)
    case gainMapQualityOutOfBounds(Double)
    case invalidMaxLongEdge(Int)
    case invalidTargetMaxFileBytes(Int)
    case developDefaultsOutOfBounds(String)
    case hlgVideoRequiresOptions
    case hlgVideo4KForbidden(Int)
    case hlgVideoDurationOutOfBounds(Double)
    case hlgVideoFPSOutOfBounds(Int)
    case hlgVideoBitrateOutOfBounds(Double)
    case builtInPresetNotFound(String)

    public var description: String {
        switch self {
        case .emptyPresetID:
            return "preset.id must not be empty or whitespace."
        case .emptyOutputFormats:
            return "outputFormats must not be empty."
        case .duplicateOutputFormats:
            return "outputFormats must not contain duplicate entries."
        case .legacyAppleGainMapRequiresMono1ch:
            return "Legacy Apple HDRGainMap dual-write is forbidden for 3-channel gain maps; must use mono1ch."
        case .ultrahdrXMPRequiresMono1chForJPEGOnly:
            return "Ultra HDR XMP (hdrgm:) is forbidden on 3-channel JPEG presets; must use mono1ch."
        case .jpegOnlyPresetMustBe8Bit:
            return "JPEG-only presets must use 8-bit base image depth."
        case .midtoneAnchorOutOfBounds(let v):
            return "midtoneAnchorP (\(v)) must be in [0.65, 0.95]."
        case .targetHeadroomOutOfBounds(let v):
            return "targetHeadroomStops (\(v)) must be in [0.0, 4.0]."
        case .gainMapGammaOutOfBounds(let v):
            return "gainMapGamma (\(v)) must be in [0.25, 4.0]."
        case .qualityOutOfBounds(let v):
            return "quality (\(v)) must be in (0.0, 1.0]."
        case .gainMapQualityOutOfBounds(let v):
            return "gainMapQuality (\(v)) must be in (0.0, 1.0]."
        case .invalidMaxLongEdge(let v):
            return "maxLongEdge (\(v)) must be >= 64 and even."
        case .invalidTargetMaxFileBytes(let v):
            return "targetMaxFileBytes (\(v)) must be > 0."
        case .developDefaultsOutOfBounds(let detail):
            return "developDefaults out of bounds: \(detail)."
        case .hlgVideoRequiresOptions:
            return "hlgMP4 output requires hlgVideoOptions."
        case .hlgVideo4KForbidden(let v):
            return "Douyin HLG MP4 forbids >1920px / 4K export (got maxLongEdge=\(v))."
        case .hlgVideoDurationOutOfBounds(let v):
            return "hlgVideoOptions.durationSeconds (\(v)) must be in [3.0, 5.0]."
        case .hlgVideoFPSOutOfBounds(let v):
            return "hlgVideoOptions.fps (\(v)) must be 30."
        case .hlgVideoBitrateOutOfBounds(let v):
            return "hlgVideoOptions.bitrateMbps (\(v)) must be in [12.0, 16.0]."
        case .builtInPresetNotFound(let id):
            return "Built-in preset '\(id)' could not be located in Bundle.module."
        }
    }
}

public enum PresetLoader {
    public static var resourceBundle: Bundle { Bundle.module }

    public static func loadAllBuiltIn() throws -> [PresetSchema] {
        try BuiltInPresetID.allCases.map { try loadBuiltIn(id: $0.rawValue) }
    }

    public static func loadBuiltIn(id: String) throws -> PresetSchema {
        let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "Presets")
            ?? Bundle.module.url(forResource: id, withExtension: "json")
        guard let url else {
            throw PresetValidationError.builtInPresetNotFound(id)
        }
        return try load(from: url)
    }

    public static func loadBuiltIn(id: BuiltInPresetID) throws -> PresetSchema {
        try loadBuiltIn(id: id.rawValue)
    }

    public static func load(from url: URL) throws -> PresetSchema {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let preset = try decoder.decode(PresetSchema.self, from: data)
        try validate(preset)
        return preset
    }

    public static func validate(_ preset: PresetSchema) throws {
        guard !preset.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PresetValidationError.emptyPresetID
        }
        guard !preset.outputFormats.isEmpty else {
            throw PresetValidationError.emptyOutputFormats
        }
        let uniqueFormats = Set(preset.outputFormats)
        guard uniqueFormats.count == preset.outputFormats.count else {
            throw PresetValidationError.duplicateOutputFormats
        }
        if preset.compatOptions.writeLegacyAppleHDRGainMap && preset.gainMapChannels == .rgb3ch {
            throw PresetValidationError.legacyAppleGainMapRequiresMono1ch
        }
        if uniqueFormats == [.jpeg] && preset.gainMapChannels == .rgb3ch && preset.compatOptions.writeUltrahdrXMP {
            throw PresetValidationError.ultrahdrXMPRequiresMono1chForJPEGOnly
        }
        if uniqueFormats == [.jpeg] && preset.bitDepth != .bit8 {
            throw PresetValidationError.jpegOnlyPresetMustBe8Bit
        }
        guard preset.midtoneAnchorP.isFinite && (0.65...0.95).contains(preset.midtoneAnchorP) else {
            throw PresetValidationError.midtoneAnchorOutOfBounds(preset.midtoneAnchorP)
        }
        guard preset.targetHeadroomStops.isFinite && (0.0...4.0).contains(preset.targetHeadroomStops) else {
            throw PresetValidationError.targetHeadroomOutOfBounds(preset.targetHeadroomStops)
        }
        guard preset.gainMapGamma.isFinite && (0.25...4.0).contains(preset.gainMapGamma) else {
            throw PresetValidationError.gainMapGammaOutOfBounds(preset.gainMapGamma)
        }
        guard preset.quality.isFinite && preset.quality > 0.0 && preset.quality <= 1.0 else {
            throw PresetValidationError.qualityOutOfBounds(preset.quality)
        }
        if let gmQ = preset.gainMapQuality {
            guard gmQ.isFinite && gmQ > 0.0 && gmQ <= 1.0 else {
                throw PresetValidationError.gainMapQualityOutOfBounds(gmQ)
            }
        }
        if let edge = preset.maxLongEdge {
            guard edge >= 64 && edge % 2 == 0 else {
                throw PresetValidationError.invalidMaxLongEdge(edge)
            }
        }
        if let bytes = preset.targetMaxFileBytes {
            guard bytes > 0 else {
                throw PresetValidationError.invalidTargetMaxFileBytes(bytes)
            }
        }
        let d = preset.developDefaults
        let developChecks: [(String, Double, ClosedRange<Double>)] = [
            ("exposureEV", d.exposureEV, -3.0...3.0),
            ("shadowRecovery", d.shadowRecovery, 0.0...100.0),
            ("blackPoint", d.blackPoint, -100.0...100.0),
            ("vibrance", d.vibrance, -100.0...100.0),
            ("sdrExposureEV", d.sdrExposureEV, -1.0...1.0),
            ("sdrHighlightCompression", d.sdrHighlightCompression, 0.0...100.0),
            ("sdrContrast", d.sdrContrast, -100.0...100.0),
            ("sdrSaturation", d.sdrSaturation, -100.0...100.0),
            ("hdrHighlightExcitation", d.hdrHighlightExcitation, 0.0...100.0),
            ("hdrRolloffSoftness", d.hdrRolloffSoftness, 0.0...100.0),
            ("clarity", d.clarity, -100.0...100.0),
            ("opticalSharpness", d.opticalSharpness, 0.0...100.0),
        ]
        for (name, value, range) in developChecks {
            guard value.isFinite && range.contains(value) else {
                throw PresetValidationError.developDefaultsOutOfBounds(
                    "\(name)=\(value) must be in [\(range.lowerBound), \(range.upperBound)]"
                )
            }
        }
        if case .custom(let kelvin, let tint) = d.whiteBalance {
            guard kelvin.isFinite && (2000.0...15000.0).contains(kelvin),
                  tint.isFinite && (-150.0...150.0).contains(tint) else {
                throw PresetValidationError.developDefaultsOutOfBounds("whiteBalance.custom")
            }
        }
        if uniqueFormats.contains(.hlgMP4) {
            guard let opts = preset.hlgVideoOptions else {
                throw PresetValidationError.hlgVideoRequiresOptions
            }
            if let edge = preset.maxLongEdge, edge > 1920 {
                throw PresetValidationError.hlgVideo4KForbidden(edge)
            }
            guard opts.durationSeconds.isFinite && (3.0...5.0).contains(opts.durationSeconds) else {
                throw PresetValidationError.hlgVideoDurationOutOfBounds(opts.durationSeconds)
            }
            guard opts.fps == 30 else {
                throw PresetValidationError.hlgVideoFPSOutOfBounds(opts.fps)
            }
            guard opts.bitrateMbps.isFinite && (12.0...16.0).contains(opts.bitrateMbps) else {
                throw PresetValidationError.hlgVideoBitrateOutOfBounds(opts.bitrateMbps)
            }
        }
    }
}
