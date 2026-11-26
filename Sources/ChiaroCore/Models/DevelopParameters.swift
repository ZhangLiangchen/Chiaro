import Foundation

public enum HighlightReconstructionMode: String, Sendable, Codable, CaseIterable, Hashable {
    case opposedInpaint
    case blend
    case rebuild
}

public enum WhiteBalanceSetting: Sendable, Codable, Equatable, Hashable {
    case asShot
    case custom(temperatureKelvin: Double, tint: Double)

    public func sanitized() -> WhiteBalanceSetting {
        switch self {
        case .asShot:
            return .asShot
        case .custom(let temperatureKelvin, let tint):
            let safeKelvin = temperatureKelvin.isFinite ? temperatureKelvin : 5500.0
            let safeTint = tint.isFinite ? tint : 0.0
            return .custom(temperatureKelvin: safeKelvin, tint: safeTint)
        }
    }
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
    public var clarity: Double                  // -100.0 ... +100.0
    public var opticalSharpness: Double         // 0.0 ... 100.0

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
        cubeLUTPath: String? = nil,
        clarity: Double = 0.0,
        opticalSharpness: Double = 0.0
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
        self.clarity = clarity
        self.opticalSharpness = opticalSharpness
    }

    private enum CodingKeys: String, CodingKey {
        case exposureEV, shadowRecovery, blackPoint, vibrance, highlightReconstruction
        case sdrExposureEV, sdrHighlightCompression, sdrContrast, sdrSaturation
        case hdrHighlightExcitation, hdrRolloffSoftness
        case whiteBalance, cameraProfile, cubeLUTPath
        case clarity, opticalSharpness
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
        self.clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0.0
        self.opticalSharpness = try c.decodeIfPresent(Double.self, forKey: .opticalSharpness) ?? 0.0
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

    public func sanitized() -> CropOffset {
        CropOffset(normalizedCenterX: normalizedCenterX, normalizedCenterY: normalizedCenterY)
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
    public var clarityOverride: Double?
    public var opticalSharpnessOverride: Double?
    public var decodeBackendOverride: RAWBackend?
    public var demosaicOverride: DemosaicAlgorithm?
    public var opticsOverride: OpticalCorrectionParameters?
    public var denoiseOverride: DenoiseParameters?
    public var aiColorOverride: AIColorGradingParameters?

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
        clearMaxLongEdgeOverride: Bool = false,
        clarityOverride: Double? = nil,
        opticalSharpnessOverride: Double? = nil,
        decodeBackendOverride: RAWBackend? = nil,
        demosaicOverride: DemosaicAlgorithm? = nil,
        opticsOverride: OpticalCorrectionParameters? = nil,
        denoiseOverride: DenoiseParameters? = nil,
        aiColorOverride: AIColorGradingParameters? = nil
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
        self.clarityOverride = clarityOverride
        self.opticalSharpnessOverride = opticalSharpnessOverride
        self.decodeBackendOverride = decodeBackendOverride
        self.demosaicOverride = demosaicOverride
        self.opticsOverride = opticsOverride
        self.denoiseOverride = denoiseOverride
        self.aiColorOverride = aiColorOverride
    }

    private enum CodingKeys: String, CodingKey {
        case exposureEVDelta, sdrExposureEVDelta, shadowRecoveryOverride, blackPointOverride
        case vibranceOverride, whiteBalanceOverride, highlightReconstructionOverride
        case sdrHighlightCompressionOverride, sdrContrastOverride, sdrSaturationOverride
        case hdrHighlightExcitationOverride, hdrRolloffSoftnessOverride
        case targetHeadroomStopsOverride, midtoneAnchorPOverride, sdrToneMapperOverride
        case cropAspectOverride, cropOffset, maxLongEdgeOverride, clearMaxLongEdgeOverride
        case clarityOverride, opticalSharpnessOverride
        case decodeBackendOverride, demosaicOverride, opticsOverride, denoiseOverride, aiColorOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func decodeOptional<T: Decodable>(_ type: T.Type, forKey key: CodingKeys) -> T? {
            do {
                return try c.decodeIfPresent(type, forKey: key)
            } catch {
                return nil
            }
        }
        func decodeBoolOrFalse(forKey key: CodingKeys) -> Bool {
            do {
                return try c.decodeIfPresent(Bool.self, forKey: key) ?? false
            } catch {
                return false
            }
        }

        self.exposureEVDelta = decodeOptional(Double.self, forKey: .exposureEVDelta)
        self.sdrExposureEVDelta = decodeOptional(Double.self, forKey: .sdrExposureEVDelta)
        self.shadowRecoveryOverride = decodeOptional(Double.self, forKey: .shadowRecoveryOverride)
        self.blackPointOverride = decodeOptional(Double.self, forKey: .blackPointOverride)
        self.vibranceOverride = decodeOptional(Double.self, forKey: .vibranceOverride)
        self.whiteBalanceOverride = decodeOptional(WhiteBalanceSetting.self, forKey: .whiteBalanceOverride)
        self.highlightReconstructionOverride = decodeOptional(HighlightReconstructionMode.self, forKey: .highlightReconstructionOverride)
        self.sdrHighlightCompressionOverride = decodeOptional(Double.self, forKey: .sdrHighlightCompressionOverride)
        self.sdrContrastOverride = decodeOptional(Double.self, forKey: .sdrContrastOverride)
        self.sdrSaturationOverride = decodeOptional(Double.self, forKey: .sdrSaturationOverride)
        self.hdrHighlightExcitationOverride = decodeOptional(Double.self, forKey: .hdrHighlightExcitationOverride)
        self.hdrRolloffSoftnessOverride = decodeOptional(Double.self, forKey: .hdrRolloffSoftnessOverride)
        self.targetHeadroomStopsOverride = decodeOptional(Double.self, forKey: .targetHeadroomStopsOverride)
        self.midtoneAnchorPOverride = decodeOptional(Double.self, forKey: .midtoneAnchorPOverride)
        self.sdrToneMapperOverride = decodeOptional(SDRToneMapper.self, forKey: .sdrToneMapperOverride)
        self.cropAspectOverride = decodeOptional(AspectRatio.self, forKey: .cropAspectOverride)
        self.cropOffset = decodeOptional(CropOffset.self, forKey: .cropOffset)
        self.maxLongEdgeOverride = decodeOptional(Int.self, forKey: .maxLongEdgeOverride)
        self.clearMaxLongEdgeOverride = decodeBoolOrFalse(forKey: .clearMaxLongEdgeOverride)
        self.clarityOverride = decodeOptional(Double.self, forKey: .clarityOverride)
        self.opticalSharpnessOverride = decodeOptional(Double.self, forKey: .opticalSharpnessOverride)
        self.decodeBackendOverride = decodeOptional(RAWBackend.self, forKey: .decodeBackendOverride)
        self.demosaicOverride = decodeOptional(DemosaicAlgorithm.self, forKey: .demosaicOverride)
        self.opticsOverride = decodeOptional(OpticalCorrectionParameters.self, forKey: .opticsOverride)
        self.denoiseOverride = decodeOptional(DenoiseParameters.self, forKey: .denoiseOverride)
        self.aiColorOverride = decodeOptional(AIColorGradingParameters.self, forKey: .aiColorOverride)
    }

    public func sanitized() -> PerPhotoDelta {
        PerPhotoDelta(
            exposureEVDelta: Self.finiteOrNil(exposureEVDelta),
            sdrExposureEVDelta: Self.finiteOrNil(sdrExposureEVDelta),
            shadowRecoveryOverride: Self.finiteOrNil(shadowRecoveryOverride),
            blackPointOverride: Self.finiteOrNil(blackPointOverride),
            vibranceOverride: Self.finiteOrNil(vibranceOverride),
            whiteBalanceOverride: whiteBalanceOverride?.sanitized(),
            highlightReconstructionOverride: highlightReconstructionOverride,
            sdrHighlightCompressionOverride: Self.finiteOrNil(sdrHighlightCompressionOverride),
            sdrContrastOverride: Self.finiteOrNil(sdrContrastOverride),
            sdrSaturationOverride: Self.finiteOrNil(sdrSaturationOverride),
            hdrHighlightExcitationOverride: Self.finiteOrNil(hdrHighlightExcitationOverride),
            hdrRolloffSoftnessOverride: Self.finiteOrNil(hdrRolloffSoftnessOverride),
            targetHeadroomStopsOverride: Self.finiteOrNil(targetHeadroomStopsOverride),
            midtoneAnchorPOverride: Self.finiteOrNil(midtoneAnchorPOverride),
            sdrToneMapperOverride: sdrToneMapperOverride,
            cropAspectOverride: cropAspectOverride,
            cropOffset: cropOffset?.sanitized(),
            maxLongEdgeOverride: maxLongEdgeOverride,
            clearMaxLongEdgeOverride: clearMaxLongEdgeOverride,
            clarityOverride: Self.finiteOrNil(clarityOverride),
            opticalSharpnessOverride: Self.finiteOrNil(opticalSharpnessOverride),
            decodeBackendOverride: decodeBackendOverride,
            demosaicOverride: demosaicOverride,
            opticsOverride: opticsOverride?.sanitized(),
            denoiseOverride: denoiseOverride?.sanitized(),
            aiColorOverride: aiColorOverride?.sanitized()
        )
    }

    private static func finiteOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

/// Explicit CLI overrides participating in the 4-tier merge precedence (`CLI > --delta-file > .chiaro.json > Preset`).
public struct CLIDevelopOverrides: Sendable, Codable, Equatable, Hashable {
    public var presetExplicitlySpecified: Bool
    public var backend: RAWBackend?
    public var demosaic: DemosaicAlgorithm?
    public var denoiseMode: DenoiseEngineMode?
    public var denoiseLuma: Double?
    public var denoiseChroma: Double?
    public var denoiseDetailPreservation: Double?
    public var lensCorrectionEnabled: Bool?
    public var lensSource: OpticalProfileSource?
    public var lensDistortion: Bool?
    public var lensAutoScale: Bool?
    public var lensTCA: Bool?
    public var lensVignetting: Bool?
    public var lensVignettingStrength: Double?
    public var toneMapper: SDRToneMapper?
    public var clarity: Double?
    public var opticalSharpness: Double?

    public init(
        presetExplicitlySpecified: Bool = false,
        backend: RAWBackend? = nil,
        demosaic: DemosaicAlgorithm? = nil,
        denoiseMode: DenoiseEngineMode? = nil,
        denoiseLuma: Double? = nil,
        denoiseChroma: Double? = nil,
        denoiseDetailPreservation: Double? = nil,
        lensCorrectionEnabled: Bool? = nil,
        lensSource: OpticalProfileSource? = nil,
        lensDistortion: Bool? = nil,
        lensAutoScale: Bool? = nil,
        lensTCA: Bool? = nil,
        lensVignetting: Bool? = nil,
        lensVignettingStrength: Double? = nil,
        toneMapper: SDRToneMapper? = nil,
        clarity: Double? = nil,
        opticalSharpness: Double? = nil
    ) {
        self.presetExplicitlySpecified = presetExplicitlySpecified
        self.backend = backend
        self.demosaic = demosaic
        self.denoiseMode = denoiseMode
        self.denoiseLuma = denoiseLuma
        self.denoiseChroma = denoiseChroma
        self.denoiseDetailPreservation = denoiseDetailPreservation
        self.lensCorrectionEnabled = lensCorrectionEnabled
        self.lensSource = lensSource
        self.lensDistortion = lensDistortion
        self.lensAutoScale = lensAutoScale
        self.lensTCA = lensTCA
        self.lensVignetting = lensVignetting
        self.lensVignettingStrength = lensVignettingStrength
        self.toneMapper = toneMapper
        self.clarity = clarity
        self.opticalSharpness = opticalSharpness
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
    public var decodeBackend: RAWBackend
    public var demosaic: DemosaicAlgorithm
    public var optics: OpticalCorrectionParameters
    public var denoise: DenoiseParameters
    public var aiColor: AIColorGradingParameters?

    public init(
        develop: DevelopParameters,
        sdrToneMapper: SDRToneMapper,
        targetHeadroom: HeadroomStops,
        midtoneAnchorP: Double,
        cropAspect: AspectRatio,
        cropOffset: CropOffset,
        maxLongEdge: Int?,
        decodeBackend: RAWBackend = .libraw,
        demosaic: DemosaicAlgorithm = .amaze,
        optics: OpticalCorrectionParameters = .default,
        denoise: DenoiseParameters = .default,
        aiColor: AIColorGradingParameters? = nil
    ) {
        self.develop = develop
        self.sdrToneMapper = sdrToneMapper
        self.targetHeadroom = targetHeadroom
        self.midtoneAnchorP = midtoneAnchorP
        self.cropAspect = cropAspect
        self.cropOffset = cropOffset
        self.maxLongEdge = maxLongEdge
        self.decodeBackend = decodeBackend
        self.demosaic = demosaic
        self.optics = optics
        self.denoise = denoise
        self.aiColor = aiColor
    }

    /// Resolves effective develop parameters enforcing strict 4-tier precedence:
    /// `CLI explicit > --delta-file > .chiaro.json Sidecar > Preset defaults`.
    public static func resolve(
        preset: PresetSchema,
        delta: PerPhotoDelta? = nil,
        sidecar: ChiaroSidecar? = nil,
        cliOverrides: CLIDevelopOverrides? = nil,
        presetResolver: ((String) -> PresetSchema?)? = nil
    ) -> EffectiveDevelopParams {
        let effectivePreset: PresetSchema
        if (cliOverrides?.presetExplicitlySpecified ?? false) == false,
           let scPresetID = sidecar?.presetID,
           let resolvedSidecarPreset = presetResolver?(scPresetID) {
            effectivePreset = resolvedSidecarPreset
        } else {
            effectivePreset = preset
        }

        var dev = effectivePreset.developDefaults
        // Always clamp/sanitize preset developDefaults even when delta/sidecar are nil.
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
        dev.clarity = clamp(dev.clarity, -100.0, 100.0, fallback: 0.0)
        dev.opticalSharpness = clamp(dev.opticalSharpness, 0.0, 100.0, fallback: 0.0)

        // Single active exposure delta (higher-precedence layer replaces lower-precedence delta; never stacked).
        let evDelta = finiteOrNil(delta?.exposureEVDelta)
            ?? finiteOrNil(sidecar?.delta?.exposureEVDelta)
            ?? 0.0
        let sdrEVDelta = finiteOrNil(delta?.sdrExposureEVDelta)
            ?? finiteOrNil(sidecar?.delta?.sdrExposureEVDelta)
            ?? 0.0
        dev.exposureEV = clamp(dev.exposureEV + evDelta, -3.0, 3.0, fallback: dev.exposureEV)
        dev.sdrExposureEV = clamp(dev.sdrExposureEV + sdrEVDelta, -1.0, 1.0, fallback: dev.sdrExposureEV)

        // Apply non-exposure delta overrides in ascending priority: Sidecar -> --delta-file.
        let orderedDeltas = [sidecar?.delta, delta].compactMap { $0 }
        for d in orderedDeltas {
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
            if let v = d.clarityOverride {
                dev.clarity = clamp(v, -100.0, 100.0, fallback: dev.clarity)
            }
            if let v = d.opticalSharpnessOverride {
                dev.opticalSharpness = clamp(v, 0.0, 100.0, fallback: dev.opticalSharpness)
            }
        }

        // CLI explicit overrides for clarity & opticalSharpness
        if let v = cliOverrides?.clarity {
            dev.clarity = clamp(v, -100.0, 100.0, fallback: dev.clarity)
        }
        if let v = cliOverrides?.opticalSharpness {
            dev.opticalSharpness = clamp(v, 0.0, 100.0, fallback: dev.opticalSharpness)
        }

        if case .custom(let kelvin, let tint) = dev.whiteBalance {
            let safeKelvin = clamp(kelvin, 2000.0, 15000.0, fallback: 5500.0)
            let safeTint = clamp(tint, -150.0, 150.0, fallback: 0.0)
            dev.whiteBalance = .custom(temperatureKelvin: safeKelvin, tint: safeTint)
        }

        let baseHeadroom = clamp(effectivePreset.targetHeadroomStops, 0.0, 4.0, fallback: 2.5)
        let baseAnchorP = clamp(effectivePreset.midtoneAnchorP, 0.65, 0.95, fallback: 0.80)
        let headroomStops = clamp(
            finiteOrNil(delta?.targetHeadroomStopsOverride)
                ?? finiteOrNil(sidecar?.delta?.targetHeadroomStopsOverride)
                ?? baseHeadroom,
            0.0,
            4.0,
            fallback: baseHeadroom
        )
        let anchorP = clamp(
            finiteOrNil(delta?.midtoneAnchorPOverride)
                ?? finiteOrNil(sidecar?.delta?.midtoneAnchorPOverride)
                ?? baseAnchorP,
            0.65,
            0.95,
            fallback: baseAnchorP
        )
        let rawOffset = delta?.cropOffset ?? sidecar?.delta?.cropOffset ?? .centered
        let safeOffset = CropOffset(
            normalizedCenterX: rawOffset.normalizedCenterX,
            normalizedCenterY: rawOffset.normalizedCenterY
        )

        let rawMaxLongEdge: Int?
        if let override = delta?.maxLongEdgeOverride {
            rawMaxLongEdge = override
        } else if delta?.clearMaxLongEdgeOverride == true {
            rawMaxLongEdge = nil
        } else if let sidecarOverride = sidecar?.delta?.maxLongEdgeOverride {
            rawMaxLongEdge = sidecarOverride
        } else if sidecar?.delta?.clearMaxLongEdgeOverride == true {
            rawMaxLongEdge = nil
        } else {
            rawMaxLongEdge = effectivePreset.maxLongEdge
        }
        let normalizedMaxLongEdge = rawMaxLongEdge.map {
            max(64, $0 & ~1)
        }

        let resolvedToneMapper = cliOverrides?.toneMapper
            ?? delta?.sdrToneMapperOverride
            ?? sidecar?.delta?.sdrToneMapperOverride
            ?? effectivePreset.sdrToneMapper
        let resolvedCropAspect = delta?.cropAspectOverride
            ?? sidecar?.delta?.cropAspectOverride
            ?? effectivePreset.cropAspect

        let resolvedBackend = cliOverrides?.backend
            ?? delta?.decodeBackendOverride
            ?? sidecar?.delta?.decodeBackendOverride
            ?? sidecar?.decodeBackend
            ?? .libraw
        let resolvedDemosaic = cliOverrides?.demosaic
            ?? delta?.demosaicOverride
            ?? sidecar?.delta?.demosaicOverride
            ?? sidecar?.demosaic
            ?? .amaze

        var resolvedOptics = delta?.opticsOverride
            ?? sidecar?.delta?.opticsOverride
            ?? sidecar?.optics
            ?? .default
        if let enabled = cliOverrides?.lensCorrectionEnabled { resolvedOptics.enabled = enabled }
        if let source = cliOverrides?.lensSource { resolvedOptics.source = source }
        if let distortion = cliOverrides?.lensDistortion { resolvedOptics.distortion = distortion }
        if let autoScale = cliOverrides?.lensAutoScale { resolvedOptics.autoScale = autoScale }
        if let tca = cliOverrides?.lensTCA { resolvedOptics.tca = tca }
        if let vignetting = cliOverrides?.lensVignetting { resolvedOptics.vignetting = vignetting }
        if let vigStrength = cliOverrides?.lensVignettingStrength {
            resolvedOptics.vignettingStrength = clamp(
                vigStrength,
                0.0,
                1.0,
                fallback: resolvedOptics.vignettingStrength
            )
        }
        resolvedOptics = resolvedOptics.sanitized()

        var resolvedDenoise = delta?.denoiseOverride
            ?? sidecar?.delta?.denoiseOverride
            ?? sidecar?.denoise
            ?? .default
        if let mode = cliOverrides?.denoiseMode { resolvedDenoise.mode = mode }
        if let luma = cliOverrides?.denoiseLuma {
            resolvedDenoise.luminanceStrength = clamp(
                luma,
                0.0,
                100.0,
                fallback: resolvedDenoise.luminanceStrength
            )
        }
        if let chroma = cliOverrides?.denoiseChroma {
            resolvedDenoise.chromaStrength = clamp(
                chroma,
                0.0,
                100.0,
                fallback: resolvedDenoise.chromaStrength
            )
        }
        if let detail = cliOverrides?.denoiseDetailPreservation {
            resolvedDenoise.detailPreservation = clamp(
                detail,
                0.0,
                100.0,
                fallback: resolvedDenoise.detailPreservation
            )
        }
        resolvedDenoise = resolvedDenoise.sanitized()

        let resolvedAIColor = (
            delta?.aiColorOverride
                ?? sidecar?.delta?.aiColorOverride
                ?? sidecar?.aiColor
        )?.sanitized()

        return EffectiveDevelopParams(
            develop: dev,
            sdrToneMapper: resolvedToneMapper,
            targetHeadroom: HeadroomStops(log2Value: headroomStops),
            midtoneAnchorP: anchorP,
            cropAspect: resolvedCropAspect,
            cropOffset: safeOffset,
            maxLongEdge: normalizedMaxLongEdge,
            decodeBackend: resolvedBackend,
            demosaic: resolvedDemosaic,
            optics: resolvedOptics,
            denoise: resolvedDenoise,
            aiColor: resolvedAIColor
        )
    }

    private static func finiteOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func clamp(_ value: Double, _ minVal: Double, _ maxVal: Double, fallback: Double) -> Double {
        guard value.isFinite else {
            return fallback.isFinite ? min(max(fallback, minVal), maxVal) : minVal
        }
        return min(max(value, minVal), maxVal)
    }
}
