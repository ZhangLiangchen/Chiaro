import Foundation

/// Exhaustive strongly typed identifier for every adjustable parameter, picker, and toggle
/// exposed across Chiaro's Preset Mode, Pro Mode, and Preview Toolbar (`FR-17`, `ADR-015`).
///
/// Strictly follows `ADR-013`: contains ZERO speculative manual distortion (`k1`/`k2`) or
/// manual chromatic aberration parameters.
public enum ParameterID: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    // App & Workspace Controls
    case workspaceMode
    case appLanguage
    case showInlineParameterSummaries
    case autoSaveSidecar

    // Preview Toolbar Controls
    case previewMode
    case simulatedHeadroom
    case sdrExposureScaleEnabled

    // Group 1: Decode, Denoise & Open-Source Optics
    case editScope
    case decodeBackend
    case demosaicAlgorithm
    case writeCustomRenderedHDR
    case denoiseEnabled
    case denoiseMode
    case denoiseLuminanceStrength
    case denoiseChromaStrength
    case denoiseDetailPreservation
    case opticsEnabled
    case opticsSource
    case opticsDistortion
    case opticsAutoScale
    case opticsTCA
    case opticsVignetting
    case opticsVignettingStrength
    case opticsLensfunLensOverride

    // Group 2: Shared Base Grading (Linear Rec.2020)
    case whiteBalanceMode
    case whiteBalanceKelvin
    case whiteBalanceTint
    case exposureEV
    case shadowRecovery
    case blackPoint
    case clarity
    case opticalSharpness
    case vibrance
    case highlightReconstruction
    case cameraProfile
    case cubeLUT

    // Group 3: SDR Base Branch
    case sdrToneMapper
    case sdrExposureEV
    case sdrHighlightCompression
    case sdrContrast
    case sdrSaturation

    // Group 4: HDR & Gain Map Engine
    case targetHeadroomStops
    case midtoneAnchorP
    case hdrHighlightExcitation
    case hdrRolloffSoftness
    case gainMapChannels
    case gainMapResolution
    case gainMapGamma
    case closedLoopSDRCompensation
    case writeLegacyAppleHDRGainMap

    // Group 5: Composition & Output Guardrails
    case cropAspect
    case cropOffsetX
    case cropOffsetY
    case maxLongEdge
    case baseColorSpace

    public var id: String { rawValue }
}
