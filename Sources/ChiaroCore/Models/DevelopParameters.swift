import Foundation

public enum HighlightReconstructionMode: String, Sendable, Codable, CaseIterable, Hashable {
    case opposedInpaint
    case blend
    case rebuild
}

public enum WhiteBalanceSetting: Sendable, Codable, Equatable, Hashable {
    case asShot
    case custom(temperatureKelvin: Double, tint: Double)
}

public enum CameraColorProfile: Sendable, Codable, Equatable, Hashable {
    case standard
    case dcp(path: String)
    case creativeLook(String)
}

public struct DevelopParameters: Sendable, Codable, Equatable, Hashable {
    // Canonical JSON fields (PROJECT.md § Interface Contracts 1)
    public var exposureEV: Double              // -3.0 ... +3.0
    public var shadowRecovery: Double          // 0.0 ... 100.0
    public var blackPoint: Double              // -100.0 ... +100.0
    public var vibrance: Double                // -100.0 ... +100.0
    public var highlightReconstruction: HighlightReconstructionMode
    public var sdrExposureEV: Double           // -1.0 ... +1.0
    public var sdrHighlightCompression: Double // 0.0 ... 100.0
    public var sdrContrast: Double             // -100.0 ... +100.0
    public var sdrSaturation: Double           // -100.0 ... +100.0
    public var hdrHighlightExcitation: Double  // 0.0 ... 100.0
    public var hdrRolloffSoftness: Double      // 0.0 ... 100.0

    // Optional extended controls (defaulted when omitted in preset JSON)
    public var whiteBalance: WhiteBalanceSetting
    public var cameraProfile: CameraColorProfile
    public var cubeLUTPath: String?

    public static let `default` = DevelopParameters()

    public init(
        exposureEV: Double = 0.0,
        shadowRecovery: Double = 0.0,
        blackPoint: Double = 0.0,
        vibrance: Double = 0.0,
        highlightReconstruction: HighlightReconstructionMode = .opposedInpaint,
        sdrExposureEV: Double = 0.0,
        sdrHighlightCompression: Double = 50.0,
        sdrContrast: Double = 0.0,
        sdrSaturation: Double = 0.0,
        hdrHighlightExcitation: Double = 60.0,
        hdrRolloffSoftness: Double = 50.0,
        whiteBalance: WhiteBalanceSetting = .asShot,
        cameraProfile: CameraColorProfile = .standard,
        cubeLUTPath: String? = nil
    ) {
        self.exposureEV = exposureEV
        self.shadowRecovery = shadowRecovery
        self.blackPoint = blackPoint
        self.vibrance = vibrance
        self.highlightReconstruction = highlightReconstruction
        self.sdrExposureEV = sdrExposureEV
        self.sdrHighlightCompression = sdrHighlightCompression
        self.sdrContrast = sdrContrast
        self.sdrSaturation = sdrSaturation
        self.hdrHighlightExcitation = hdrHighlightExcitation
        self.hdrRolloffSoftness = hdrRolloffSoftness
        self.whiteBalance = whiteBalance
        self.cameraProfile = cameraProfile
        self.cubeLUTPath = cubeLUTPath
    }

    private enum CodingKeys: String, CodingKey {
        case exposureEV, shadowRecovery, blackPoint, vibrance, highlightReconstruction
        case sdrExposureEV, sdrHighlightCompression, sdrContrast, sdrSaturation
        case hdrHighlightExcitation, hdrRolloffSoftness
        case whiteBalance, cameraProfile, cubeLUTPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exposureEV = try c.decode(Double.self, forKey: .exposureEV)
        self.shadowRecovery = try c.decode(Double.self, forKey: .shadowRecovery)
        self.blackPoint = try c.decode(Double.self, forKey: .blackPoint)
        self.vibrance = try c.decode(Double.self, forKey: .vibrance)
        self.highlightReconstruction = try c.decode(HighlightReconstructionMode.self, forKey: .highlightReconstruction)
        self.sdrExposureEV = try c.decode(Double.self, forKey: .sdrExposureEV)
        self.sdrHighlightCompression = try c.decode(Double.self, forKey: .sdrHighlightCompression)
        self.sdrContrast = try c.decode(Double.self, forKey: .sdrContrast)
        self.sdrSaturation = try c.decode(Double.self, forKey: .sdrSaturation)
        self.hdrHighlightExcitation = try c.decode(Double.self, forKey: .hdrHighlightExcitation)
        self.hdrRolloffSoftness = try c.decode(Double.self, forKey: .hdrRolloffSoftness)
        self.whiteBalance = try c.decodeIfPresent(WhiteBalanceSetting.self, forKey: .whiteBalance) ?? .asShot
        self.cameraProfile = try c.decodeIfPresent(CameraColorProfile.self, forKey: .cameraProfile) ?? .standard
        self.cubeLUTPath = try c.decodeIfPresent(String.self, forKey: .cubeLUTPath)
    }
}

public struct CropOffset: Sendable, Codable, Equatable, Hashable {
    public var normalizedCenterX: Double
    public var normalizedCenterY: Double

    public static let centered = CropOffset(normalizedCenterX: 0.5, normalizedCenterY: 0.5)

    public init(normalizedCenterX: Double = 0.5, normalizedCenterY: Double = 0.5) {
        self.normalizedCenterX = Self.sanitize(normalizedCenterX)
        self.normalizedCenterY = Self.sanitize(normalizedCenterY)
    }

    private enum CodingKeys: String, CodingKey {
        case normalizedCenterX
        case normalizedCenterY
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let x = try c.decode(Double.self, forKey: .normalizedCenterX)
        let y = try c.decode(Double.self, forKey: .normalizedCenterY)
        self.init(normalizedCenterX: x, normalizedCenterY: y)
    }

    private static func sanitize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0.0), 1.0) : 0.5
    }
}

public struct PerPhotoDelta: Sendable, Codable, Equatable, Hashable {
    public var exposureEVDelta: Double?
    public var sdrExposureEVDelta: Double?
    public var shadowRecoveryOverride: Double?
    public var blackPointOverride: Double?
    public var vibranceOverride: Double?
    public var whiteBalanceOverride: WhiteBalanceSetting?
    public var highlightReconstructionOverride: HighlightReconstructionMode?
    public var sdrHighlightCompressionOverride: Double?
    public var sdrContrastOverride: Double?
    public var sdrSaturationOverride: Double?
    public var hdrHighlightExcitationOverride: Double?
    public var hdrRolloffSoftnessOverride: Double?
    public var targetHeadroomStopsOverride: Double?
    public var midtoneAnchorPOverride: Double?
    public var sdrToneMapperOverride: SDRToneMapper?
    public var cropAspectOverride: AspectRatio?
    public var cropOffset: CropOffset?
    public var maxLongEdgeOverride: Int?
    public var clearMaxLongEdgeOverride: Bool

    public init(
        exposureEVDelta: Double? = nil,
        sdrExposureEVDelta: Double? = nil,
        shadowRecoveryOverride: Double? = nil,
        blackPointOverride: Double? = nil,
        vibranceOverride: Double? = nil,
        whiteBalanceOverride: WhiteBalanceSetting? = nil,
        highlightReconstructionOverride: HighlightReconstructionMode? = nil,
        sdrHighlightCompressionOverride: Double? = nil,
        sdrContrastOverride: Double? = nil,
        sdrSaturationOverride: Double? = nil,
        hdrHighlightExcitationOverride: Double? = nil,
        hdrRolloffSoftnessOverride: Double? = nil,
        targetHeadroomStopsOverride: Double? = nil,
        midtoneAnchorPOverride: Double? = nil,
        sdrToneMapperOverride: SDRToneMapper? = nil,
        cropAspectOverride: AspectRatio? = nil,
        cropOffset: CropOffset? = nil,
        maxLongEdgeOverride: Int? = nil,
        clearMaxLongEdgeOverride: Bool = false
    ) {
        self.exposureEVDelta = exposureEVDelta
        self.sdrExposureEVDelta = sdrExposureEVDelta
        self.shadowRecoveryOverride = shadowRecoveryOverride
        self.blackPointOverride = blackPointOverride
        self.vibranceOverride = vibranceOverride
        self.whiteBalanceOverride = whiteBalanceOverride
        self.highlightReconstructionOverride = highlightReconstructionOverride
        self.sdrHighlightCompressionOverride = sdrHighlightCompressionOverride
        self.sdrContrastOverride = sdrContrastOverride
        self.sdrSaturationOverride = sdrSaturationOverride
        self.hdrHighlightExcitationOverride = hdrHighlightExcitationOverride
        self.hdrRolloffSoftnessOverride = hdrRolloffSoftnessOverride
        self.targetHeadroomStopsOverride = targetHeadroomStopsOverride
        self.midtoneAnchorPOverride = midtoneAnchorPOverride
        self.sdrToneMapperOverride = sdrToneMapperOverride
        self.cropAspectOverride = cropAspectOverride
        self.cropOffset = cropOffset
        self.maxLongEdgeOverride = maxLongEdgeOverride
        self.clearMaxLongEdgeOverride = clearMaxLongEdgeOverride
    }

    private enum CodingKeys: String, CodingKey {
        case exposureEVDelta, sdrExposureEVDelta, shadowRecoveryOverride, blackPointOverride
        case vibranceOverride, whiteBalanceOverride, highlightReconstructionOverride
        case sdrHighlightCompressionOverride, sdrContrastOverride, sdrSaturationOverride
        case hdrHighlightExcitationOverride, hdrRolloffSoftnessOverride
        case targetHeadroomStopsOverride, midtoneAnchorPOverride, sdrToneMapperOverride
        case cropAspectOverride, cropOffset, maxLongEdgeOverride, clearMaxLongEdgeOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exposureEVDelta = try c.decodeIfPresent(Double.self, forKey: .exposureEVDelta)
        self.sdrExposureEVDelta = try c.decodeIfPresent(Double.self, forKey: .sdrExposureEVDelta)
        self.shadowRecoveryOverride = try c.decodeIfPresent(Double.self, forKey: .shadowRecoveryOverride)
        self.blackPointOverride = try c.decodeIfPresent(Double.self, forKey: .blackPointOverride)
        self.vibranceOverride = try c.decodeIfPresent(Double.self, forKey: .vibranceOverride)
        self.whiteBalanceOverride = try c.decodeIfPresent(WhiteBalanceSetting.self, forKey: .whiteBalanceOverride)
        self.highlightReconstructionOverride = try c.decodeIfPresent(HighlightReconstructionMode.self, forKey: .highlightReconstructionOverride)
        self.sdrHighlightCompressionOverride = try c.decodeIfPresent(Double.self, forKey: .sdrHighlightCompressionOverride)
        self.sdrContrastOverride = try c.decodeIfPresent(Double.self, forKey: .sdrContrastOverride)
        self.sdrSaturationOverride = try c.decodeIfPresent(Double.self, forKey: .sdrSaturationOverride)
        self.hdrHighlightExcitationOverride = try c.decodeIfPresent(Double.self, forKey: .hdrHighlightExcitationOverride)
        self.hdrRolloffSoftnessOverride = try c.decodeIfPresent(Double.self, forKey: .hdrRolloffSoftnessOverride)
        self.targetHeadroomStopsOverride = try c.decodeIfPresent(Double.self, forKey: .targetHeadroomStopsOverride)
        self.midtoneAnchorPOverride = try c.decodeIfPresent(Double.self, forKey: .midtoneAnchorPOverride)
        self.sdrToneMapperOverride = try c.decodeIfPresent(SDRToneMapper.self, forKey: .sdrToneMapperOverride)
        self.cropAspectOverride = try c.decodeIfPresent(AspectRatio.self, forKey: .cropAspectOverride)
        self.cropOffset = try c.decodeIfPresent(CropOffset.self, forKey: .cropOffset)
        self.maxLongEdgeOverride = try c.decodeIfPresent(Int.self, forKey: .maxLongEdgeOverride)
        self.clearMaxLongEdgeOverride = try c.decodeIfPresent(Bool.self, forKey: .clearMaxLongEdgeOverride) ?? false
    }
}

public struct EffectiveDevelopParams: Sendable, Codable, Equatable, Hashable {
    public var develop: DevelopParameters
    public var sdrToneMapper: SDRToneMapper
    public var targetHeadroom: HeadroomStops
    public var midtoneAnchorP: Double
    public var cropAspect: AspectRatio
    public var cropOffset: CropOffset
    public var maxLongEdge: Int?

    public init(
        develop: DevelopParameters,
        sdrToneMapper: SDRToneMapper,
        targetHeadroom: HeadroomStops,
        midtoneAnchorP: Double,
        cropAspect: AspectRatio,
        cropOffset: CropOffset,
        maxLongEdge: Int?
    ) {
        self.develop = develop
        self.sdrToneMapper = sdrToneMapper
        self.targetHeadroom = targetHeadroom
        self.midtoneAnchorP = midtoneAnchorP
        self.cropAspect = cropAspect
        self.cropOffset = cropOffset
        self.maxLongEdge = maxLongEdge
    }

    public static func resolve(preset: PresetSchema, delta: PerPhotoDelta? = nil) -> EffectiveDevelopParams {
        var dev = preset.developDefaults
        // Always clamp/sanitize preset developDefaults even when delta is nil.
        dev.exposureEV = clamp(dev.exposureEV, -3.0, 3.0, fallback: 0.0)
        dev.shadowRecovery = clamp(dev.shadowRecovery, 0.0, 100.0, fallback: 0.0)
        dev.blackPoint = clamp(dev.blackPoint, -100.0, 100.0, fallback: 0.0)
        dev.vibrance = clamp(dev.vibrance, -100.0, 100.0, fallback: 0.0)
        dev.sdrExposureEV = clamp(dev.sdrExposureEV, -1.0, 1.0, fallback: 0.0)
        dev.sdrHighlightCompression = clamp(dev.sdrHighlightCompression, 0.0, 100.0, fallback: 50.0)
        dev.sdrContrast = clamp(dev.sdrContrast, -100.0, 100.0, fallback: 0.0)
        dev.sdrSaturation = clamp(dev.sdrSaturation, -100.0, 100.0, fallback: 0.0)
        dev.hdrHighlightExcitation = clamp(dev.hdrHighlightExcitation, 0.0, 100.0, fallback: 60.0)
        dev.hdrRolloffSoftness = clamp(dev.hdrRolloffSoftness, 0.0, 100.0, fallback: 50.0)

        if let d = delta {
            let evDelta = d.exposureEVDelta.flatMap { $0.isFinite ? $0 : nil } ?? 0.0
            let sdrEVDelta = d.sdrExposureEVDelta.flatMap { $0.isFinite ? $0 : nil } ?? 0.0
            dev.exposureEV = clamp(dev.exposureEV + evDelta, -3.0, 3.0, fallback: dev.exposureEV)
            dev.sdrExposureEV = clamp(dev.sdrExposureEV + sdrEVDelta, -1.0, 1.0, fallback: dev.sdrExposureEV)
            if let v = d.shadowRecoveryOverride {
                dev.shadowRecovery = clamp(v, 0.0, 100.0, fallback: dev.shadowRecovery)
            }
            if let v = d.blackPointOverride {
                dev.blackPoint = clamp(v, -100.0, 100.0, fallback: dev.blackPoint)
            }
            if let v = d.vibranceOverride {
                dev.vibrance = clamp(v, -100.0, 100.0, fallback: dev.vibrance)
            }
            if let wb = d.whiteBalanceOverride { dev.whiteBalance = wb }
            if let hr = d.highlightReconstructionOverride { dev.highlightReconstruction = hr }
            if let v = d.sdrHighlightCompressionOverride {
                dev.sdrHighlightCompression = clamp(v, 0.0, 100.0, fallback: dev.sdrHighlightCompression)
            }
            if let v = d.sdrContrastOverride {
                dev.sdrContrast = clamp(v, -100.0, 100.0, fallback: dev.sdrContrast)
            }
            if let v = d.sdrSaturationOverride {
                dev.sdrSaturation = clamp(v, -100.0, 100.0, fallback: dev.sdrSaturation)
            }
            if let v = d.hdrHighlightExcitationOverride {
                dev.hdrHighlightExcitation = clamp(v, 0.0, 100.0, fallback: dev.hdrHighlightExcitation)
            }
            if let v = d.hdrRolloffSoftnessOverride {
                dev.hdrRolloffSoftness = clamp(v, 0.0, 100.0, fallback: dev.hdrRolloffSoftness)
            }
        }

        if case .custom(let kelvin, let tint) = dev.whiteBalance {
            let safeKelvin = clamp(kelvin, 2000.0, 15000.0, fallback: 5500.0)
            let safeTint = clamp(tint, -150.0, 150.0, fallback: 0.0)
            dev.whiteBalance = .custom(temperatureKelvin: safeKelvin, tint: safeTint)
        }

        let baseHeadroom = clamp(preset.targetHeadroomStops, 0.0, 4.0, fallback: 2.5)
        let baseAnchorP = clamp(preset.midtoneAnchorP, 0.65, 0.95, fallback: 0.80)
        let headroomStops = clamp(
            delta?.targetHeadroomStopsOverride ?? baseHeadroom,
            0.0,
            4.0,
            fallback: baseHeadroom
        )
        let anchorP = clamp(
            delta?.midtoneAnchorPOverride ?? baseAnchorP,
            0.65,
            0.95,
            fallback: baseAnchorP
        )
        let rawOffset = delta?.cropOffset ?? .centered
        let safeOffset = CropOffset(
            normalizedCenterX: rawOffset.normalizedCenterX,
            normalizedCenterY: rawOffset.normalizedCenterY
        )
        let rawMaxLongEdge: Int?
        if let override = delta?.maxLongEdgeOverride {
            rawMaxLongEdge = override
        } else if delta?.clearMaxLongEdgeOverride == true {
            rawMaxLongEdge = nil
        } else {
            rawMaxLongEdge = preset.maxLongEdge
        }
        let normalizedMaxLongEdge = rawMaxLongEdge.map {
            max(64, $0 & ~1)
        }

        return EffectiveDevelopParams(
            develop: dev,
            sdrToneMapper: delta?.sdrToneMapperOverride ?? preset.sdrToneMapper,
            targetHeadroom: HeadroomStops(log2Value: headroomStops),
            midtoneAnchorP: anchorP,
            cropAspect: delta?.cropAspectOverride ?? preset.cropAspect,
            cropOffset: safeOffset,
            maxLongEdge: normalizedMaxLongEdge
        )
    }

    private static func clamp(_ value: Double, _ minVal: Double, _ maxVal: Double, fallback: Double) -> Double {
        guard value.isFinite else {
            return fallback.isFinite ? min(max(fallback, minVal), maxVal) : minVal
        }
        return min(max(value, minVal), maxVal)
    }
}
