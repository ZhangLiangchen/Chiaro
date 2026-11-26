import Foundation
import ChiaroCore

public enum WorkspaceMode: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case preset
    case pro

    public var id: String { rawValue }
}

public enum ProOverrideInspector {
    /// Coupled excitation curve used by Preset Mode's 1.0...3.5 EV HDR Intensity slider.
    public static func expectedPresetExcitation(forHeadroomStops stops: Double) -> Double {
        min(100.0, max(0.0, (stops - 1.0) / 2.5 * 80.0 + 10.0))
    }

    /// Detects active Pro-only overrides relative to an unmodified `baselinePreset`.
    /// Built-in presets (e.g. `xiaohongshu_jpg`, `douyin_jpg`, `douyin_hlg_mp4`) and
    /// Preset Mode controls (6 sliders, optics master toggle, denoise master toggle, crop)
    /// NEVER trigger false positives.
    public static func activeProOnlyOverrides(
        effective: EffectiveDevelopParams,
        preset: PresetSchema,
        baselinePreset: PresetSchema
    ) -> [ParameterID] {
        var overrides: [ParameterID] = []

        // Group 1: Decode, Denoise & Open-Source Optics
        if effective.decodeBackend != .libraw {
            overrides.append(.decodeBackend)
        }
        if effective.demosaic != .amaze {
            overrides.append(.demosaicAlgorithm)
        }
        if preset.compatOptions.writeCustomRenderedHDR != baselinePreset.compatOptions.writeCustomRenderedHDR {
            overrides.append(.writeCustomRenderedHDR)
        }
        if effective.denoise.mode == .coreMLANE {
            overrides.append(.denoiseMode)
        }
        if effective.denoise.mode != .off {
            if abs(effective.denoise.luminanceStrength - DenoiseParameters.default.luminanceStrength) > 1e-4 {
                overrides.append(.denoiseLuminanceStrength)
            }
            if abs(effective.denoise.chromaStrength - DenoiseParameters.default.chromaStrength) > 1e-4 {
                overrides.append(.denoiseChromaStrength)
            }
            if abs(effective.denoise.detailPreservation - DenoiseParameters.default.detailPreservation) > 1e-4 {
                overrides.append(.denoiseDetailPreservation)
            }
        }
        if effective.optics.source != .auto {
            overrides.append(.opticsSource)
        }
        if !effective.optics.distortion {
            overrides.append(.opticsDistortion)
        }
        if !effective.optics.autoScale {
            overrides.append(.opticsAutoScale)
        }
        if !effective.optics.tca {
            overrides.append(.opticsTCA)
        }
        if !effective.optics.vignetting {
            overrides.append(.opticsVignetting)
        }
        if abs(effective.optics.vignettingStrength - 1.0) > 1e-4 {
            overrides.append(.opticsVignettingStrength)
        }
        if effective.optics.lensfunLensOverride != nil || effective.optics.lensfunCameraOverride != nil {
            overrides.append(.opticsLensfunLensOverride)
        }

        // Group 2: Shared Base Grading (Pro-only controls)
        if case .custom(_, let tint) = effective.develop.whiteBalance {
            let baselineTint: Double = {
                if case .custom(_, let bt) = baselinePreset.developDefaults.whiteBalance {
                    return bt
                }
                return 0.0
            }()
            if abs(tint - baselineTint) > 0.5 {
                overrides.append(.whiteBalanceTint)
            }
        }
        if abs(effective.develop.blackPoint - baselinePreset.developDefaults.blackPoint) > 1e-4 {
            overrides.append(.blackPoint)
        }
        if abs(effective.develop.opticalSharpness - baselinePreset.developDefaults.opticalSharpness) > 1e-4 {
            overrides.append(.opticalSharpness)
        }
        if effective.develop.highlightReconstruction != baselinePreset.developDefaults.highlightReconstruction {
            overrides.append(.highlightReconstruction)
        }
        if effective.develop.cameraProfile != baselinePreset.developDefaults.cameraProfile {
            overrides.append(.cameraProfile)
        }
        if effective.develop.cubeLUTPath != baselinePreset.developDefaults.cubeLUTPath {
            overrides.append(.cubeLUT)
        }

        // Group 3: SDR Base Branch
        if effective.sdrToneMapper != baselinePreset.sdrToneMapper {
            overrides.append(.sdrToneMapper)
        }
        if abs(effective.develop.sdrExposureEV - baselinePreset.developDefaults.sdrExposureEV) > 1e-4 {
            overrides.append(.sdrExposureEV)
        }
        if abs(effective.develop.sdrHighlightCompression - baselinePreset.developDefaults.sdrHighlightCompression) > 1e-4 {
            overrides.append(.sdrHighlightCompression)
        }
        if abs(effective.develop.sdrContrast - baselinePreset.developDefaults.sdrContrast) > 1e-4 {
            overrides.append(.sdrContrast)
        }
        if abs(effective.develop.sdrSaturation - baselinePreset.developDefaults.sdrSaturation) > 1e-4 {
            overrides.append(.sdrSaturation)
        }

        // Group 4: HDR & Gain Map Engine
        let stops = effective.targetHeadroom.log2Value
        let inPresetHeadroomRange = stops >= 1.0 - 1e-4 && stops <= 3.5 + 1e-4
        if !inPresetHeadroomRange && abs(stops - baselinePreset.targetHeadroomStops) > 1e-4 {
            overrides.append(.targetHeadroomStops)
        }
        if abs(effective.midtoneAnchorP - baselinePreset.midtoneAnchorP) > 1e-4 {
            overrides.append(.midtoneAnchorP)
        }
        let excitationMatchesBaseline = abs(
            effective.develop.hdrHighlightExcitation - baselinePreset.developDefaults.hdrHighlightExcitation
        ) <= 0.5
        let excitationMatchesCoupled = inPresetHeadroomRange && abs(
            effective.develop.hdrHighlightExcitation - expectedPresetExcitation(forHeadroomStops: stops)
        ) <= 0.5
        if !excitationMatchesBaseline && !excitationMatchesCoupled {
            overrides.append(.hdrHighlightExcitation)
        }
        if abs(effective.develop.hdrRolloffSoftness - baselinePreset.developDefaults.hdrRolloffSoftness) > 1e-4 {
            overrides.append(.hdrRolloffSoftness)
        }
        if preset.gainMapChannels != baselinePreset.gainMapChannels {
            overrides.append(.gainMapChannels)
        }
        if preset.gainMapResolution != baselinePreset.gainMapResolution {
            overrides.append(.gainMapResolution)
        }
        if abs(preset.gainMapGamma - baselinePreset.gainMapGamma) > 1e-4 {
            overrides.append(.gainMapGamma)
        }
        if preset.compatOptions.closedLoopSDRCompensation != baselinePreset.compatOptions.closedLoopSDRCompensation {
            overrides.append(.closedLoopSDRCompensation)
        }
        if preset.compatOptions.writeLegacyAppleHDRGainMap != baselinePreset.compatOptions.writeLegacyAppleHDRGainMap {
            overrides.append(.writeLegacyAppleHDRGainMap)
        }

        // Group 5: Output Guardrails
        if effective.maxLongEdge != baselinePreset.maxLongEdge {
            overrides.append(.maxLongEdge)
        }
        if preset.baseColorSpace != baselinePreset.baseColorSpace {
            overrides.append(.baseColorSpace)
        }

        return overrides
    }
}
