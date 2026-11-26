import Foundation
import Metal

/// Bilingual text container (`zh-Hans` / `en`) shared by AI rationales and UI documentation (`ADR-015`, `ADR-018`).
public struct LocalizedText: Sendable, Codable, Equatable, Hashable {
    public var zhHans: String
    public var en: String

    public init(zhHans: String, en: String) {
        self.zhHans = zhHans
        self.en = en
    }
}

// MARK: - v1.1 / v2 Linear Denoise Contracts (ADR-013B, ADR-017)

/// Denoise engine mode frozen across v1.1 (`profiledWavelet`) and v2 (`coreMLANE`).
public enum DenoiseEngineMode: String, Sendable, Codable, CaseIterable, Hashable {
    case off
    /// v1.1 darktable `noiseprofiles.json` + Metal GAT + 4-level À-trous wavelet + IGAT.
    case profiledWavelet
    /// Native Apple CIRAWFilter v9 ANE denoise.
    case appleCIRAWv9ANE
    /// v2 open-source CoreML Neural Denoise (NAFNet / NIND) targeting Apple ANE.
    case coreMLANE
}

/// Non-destructive denoise parameters (`ADR-014`, `ADR-017`).
public struct DenoiseParameters: Sendable, Codable, Equatable, Hashable {
    public var mode: DenoiseEngineMode
    /// 0...100, default 25.0
    public var luminanceStrength: Double
    /// 0...100, default 65.0
    public var chromaStrength: Double
    /// 0...100, default 70.0
    public var detailPreservation: Double
    /// Prefer Apple Neural Engine execution (`MLComputeUnits.all` / `.cpuAndNeuralEngine`).
    public var preferANE: Bool
    /// Optional v2 CoreML model identifier (e.g. `"chiaro-a7c2-nafnet-v1.mlpackage"`).
    public var modelID: String?

    public static let `default` = DenoiseParameters()

    public init(
        mode: DenoiseEngineMode = .profiledWavelet,
        luminanceStrength: Double = 25.0,
        chromaStrength: Double = 65.0,
        detailPreservation: Double = 70.0,
        preferANE: Bool = true,
        modelID: String? = nil
    ) {
        self.mode = mode
        self.luminanceStrength = Self.clampStrength(luminanceStrength, fallback: 25.0)
        self.chromaStrength = Self.clampStrength(chromaStrength, fallback: 65.0)
        self.detailPreservation = Self.clampStrength(detailPreservation, fallback: 70.0)
        self.preferANE = preferANE
        if let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            self.modelID = trimmed
        } else {
            self.modelID = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case luminanceStrength
        case chromaStrength
        case detailPreservation
        case preferANE
        case modelID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let decodedMode: DenoiseEngineMode
        if let rawMode = try c.decodeIfPresent(String.self, forKey: .mode) {
            decodedMode = DenoiseEngineMode(rawValue: rawMode) ?? .off
        } else {
            decodedMode = .profiledWavelet
        }

        let luma = try c.decodeIfPresent(Double.self, forKey: .luminanceStrength) ?? 25.0
        let chroma = try c.decodeIfPresent(Double.self, forKey: .chromaStrength) ?? 65.0
        let detail = try c.decodeIfPresent(Double.self, forKey: .detailPreservation) ?? 70.0
        let preferANE = try c.decodeIfPresent(Bool.self, forKey: .preferANE) ?? true
        let modelID = try c.decodeIfPresent(String.self, forKey: .modelID)

        self.init(
            mode: decodedMode,
            luminanceStrength: luma,
            chromaStrength: chroma,
            detailPreservation: detail,
            preferANE: preferANE,
            modelID: modelID
        )
    }

    public func sanitized() -> DenoiseParameters {
        DenoiseParameters(
            mode: mode,
            luminanceStrength: luminanceStrength,
            chromaStrength: chromaStrength,
            detailPreservation: detailPreservation,
            preferANE: preferANE,
            modelID: modelID
        )
    }

    private static func clampStrength(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0.0), 100.0)
    }
}

/// Single ISO calibration point matching darktable `noiseprofiles.json`.
public struct SensorNoiseProfilePoint: Sendable, Codable, Equatable, Hashable {
    public var name: String?
    public var iso: Int
    /// Shot noise Poisson slope `[aR, aG, aB]`.
    public var a: [Double]
    /// Read noise Gaussian baseline `[bR, bG, bB]`.
    public var b: [Double]

    public init(name: String? = nil, iso: Int, a: [Double], b: [Double]) {
        self.name = name
        self.iso = iso
        self.a = a
        self.b = b
    }
}

/// Per-camera Poisson-Gaussian sensor noise profile with log-ISO interpolation (`ADR-013B`).
public struct SensorNoiseProfile: Sendable, Codable, Equatable, Hashable {
    public var maker: String
    public var model: String
    public var profiles: [SensorNoiseProfilePoint]

    public struct InterpolatedCoefficients: Sendable, Equatable, Hashable {
        public var iso: Int
        public var a: SIMD3<Double>
        public var b: SIMD3<Double>

        public init(iso: Int, a: SIMD3<Double>, b: SIMD3<Double>) {
            self.iso = iso
            self.a = a
            self.b = b
        }
    }

    public init(maker: String, model: String, profiles: [SensorNoiseProfilePoint]) {
        self.maker = maker
        self.model = model
        self.profiles = profiles
    }

    /// Interpolates `(a(ISO), b(ISO))` in the `log(ISO)` domain, clamping outside min/max points
    /// and guaranteeing non-negative finite coefficients.
    public func interpolatedParameters(forISO iso: Int) -> InterpolatedCoefficients? {
        let valid = profiles
            .filter { point in
                point.iso > 0
                    && point.a.count >= 3
                    && point.b.count >= 3
                    && point.a.prefix(3).allSatisfy(\.isFinite)
                    && point.b.prefix(3).allSatisfy(\.isFinite)
            }
            .sorted { $0.iso < $1.iso }

        guard let first = valid.first, let last = valid.last else {
            return nil
        }

        if iso <= first.iso {
            return InterpolatedCoefficients(
                iso: iso,
                a: SIMD3<Double>(max(0.0, first.a[0]), max(0.0, first.a[1]), max(0.0, first.a[2])),
                b: SIMD3<Double>(max(0.0, first.b[0]), max(0.0, first.b[1]), max(0.0, first.b[2]))
            )
        }

        if iso >= last.iso {
            return InterpolatedCoefficients(
                iso: iso,
                a: SIMD3<Double>(max(0.0, last.a[0]), max(0.0, last.a[1]), max(0.0, last.a[2])),
                b: SIMD3<Double>(max(0.0, last.b[0]), max(0.0, last.b[1]), max(0.0, last.b[2]))
            )
        }

        for index in 0..<(valid.count - 1) {
            let p0 = valid[index]
            let p1 = valid[index + 1]
            if iso >= p0.iso && iso <= p1.iso {
                if p0.iso == p1.iso {
                    return InterpolatedCoefficients(
                        iso: iso,
                        a: SIMD3<Double>(max(0.0, p0.a[0]), max(0.0, p0.a[1]), max(0.0, p0.a[2])),
                        b: SIMD3<Double>(max(0.0, p0.b[0]), max(0.0, p0.b[1]), max(0.0, p0.b[2]))
                    )
                }
                let logTarget = log(Double(iso))
                let log0 = log(Double(p0.iso))
                let log1 = log(Double(p1.iso))
                let denom = log1 - log0
                let t = denom > 0.0 ? min(max((logTarget - log0) / denom, 0.0), 1.0) : 0.0

                let aVec = SIMD3<Double>(
                    max(0.0, (1.0 - t) * p0.a[0] + t * p1.a[0]),
                    max(0.0, (1.0 - t) * p0.a[1] + t * p1.a[1]),
                    max(0.0, (1.0 - t) * p0.a[2] + t * p1.a[2])
                )
                let bVec = SIMD3<Double>(
                    max(0.0, (1.0 - t) * p0.b[0] + t * p1.b[0]),
                    max(0.0, (1.0 - t) * p0.b[1] + t * p1.b[1]),
                    max(0.0, (1.0 - t) * p0.b[2] + t * p1.b[2])
                )
                return InterpolatedCoefficients(iso: iso, a: aVec, b: bVec)
            }
        }

        return nil
    }
}

/// Helper entry for decoding darktable root `noiseprofiles.json` model blocks.
public struct SensorNoiseProfileModelEntry: Sendable, Codable, Equatable, Hashable {
    public var model: String
    public var profiles: [SensorNoiseProfilePoint]

    public init(model: String, profiles: [SensorNoiseProfilePoint]) {
        self.model = model
        self.profiles = profiles
    }
}

/// Helper entry for decoding darktable root `noiseprofiles.json` maker blocks.
public struct SensorNoiseProfileMakerEntry: Sendable, Codable, Equatable, Hashable {
    public var maker: String
    public var models: [SensorNoiseProfileModelEntry]

    public init(maker: String, models: [SensorNoiseProfileModelEntry]) {
        self.maker = maker
        self.models = models
    }
}

/// Darktable `noiseprofiles.json` root database schema helper.
public struct SensorNoiseProfileDatabase: Sendable, Codable, Equatable, Hashable {
    public var version: Int
    public var noiseprofiles: [SensorNoiseProfileMakerEntry]

    public init(version: Int = 0, noiseprofiles: [SensorNoiseProfileMakerEntry] = []) {
        self.version = version
        self.noiseprofiles = noiseprofiles
    }

    public func profile(maker: String, model: String) -> SensorNoiseProfile? {
        let targetMaker = maker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for makerEntry in noiseprofiles {
            guard makerEntry.maker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetMaker else {
                continue
            }
            if let modelEntry = makerEntry.models.first(where: {
                $0.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetModel
            }) {
                return SensorNoiseProfile(
                    maker: makerEntry.maker,
                    model: modelEntry.model,
                    profiles: modelEntry.profiles
                )
            }
        }
        return nil
    }
}

/// Stage 2A linear-domain denoising contract (strictly ordered **before** `OpticalCorrectionStage`).
public protocol LinearDenoiseStage: Sendable {
    func denoise(
        inputTexture: any MTLTexture,
        iso: Int?,
        noiseProfile: SensorNoiseProfile?,
        params: DenoiseParameters,
        commandQueue: any MTLCommandQueue
    ) async throws -> any MTLTexture
}

// MARK: - v3 AI Color Grading & Multimodal Agent Contracts (ADR-018)

/// Perceptual 4-way color wheel node for darktable `Color Balance RGB` (`ADR-018`).
public struct ColorBalanceWheelAdjustment: Sendable, Codable, Equatable, Hashable {
    /// Hue angle in `[0.0, 360.0]` degrees.
    public var hueDegrees: Double
    /// Perceptual chroma intensity in `[0.0, 1.0]`.
    public var chroma: Double
    /// Luminance offset in `[-1.0, 1.0]`.
    public var luminanceOffset: Double

    public static let zero = ColorBalanceWheelAdjustment()

    public init(
        hueDegrees: Double = 0.0,
        chroma: Double = 0.0,
        luminanceOffset: Double = 0.0
    ) {
        self.hueDegrees = Self.clamp(hueDegrees, 0.0, 360.0, fallback: 0.0)
        self.chroma = Self.clamp(chroma, 0.0, 1.0, fallback: 0.0)
        self.luminanceOffset = Self.clamp(luminanceOffset, -1.0, 1.0, fallback: 0.0)
    }

    private enum CodingKeys: String, CodingKey {
        case hueDegrees
        case chroma
        case luminanceOffset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hue = try c.decodeIfPresent(Double.self, forKey: .hueDegrees) ?? 0.0
        let chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 0.0
        let luma = try c.decodeIfPresent(Double.self, forKey: .luminanceOffset) ?? 0.0
        self.init(hueDegrees: hue, chroma: chroma, luminanceOffset: luma)
    }

    public func sanitized() -> ColorBalanceWheelAdjustment {
        ColorBalanceWheelAdjustment(
            hueDegrees: hueDegrees,
            chroma: chroma,
            luminanceOffset: luminanceOffset
        )
    }

    private static func clamp(_ value: Double, _ minVal: Double, _ maxVal: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, minVal), maxVal)
    }
}

/// 8-band guided-filter Tone Equalizer (`-8 EV ~ +3 EV`, each band `[-3.0, +3.0]` EV).
public struct ToneEqualizerParameters: Sendable, Codable, Equatable, Hashable {
    public static let bandCount = 8

    public var bandOffsetsEV: [Double]
    public var smoothing: Double

    public init(
        bandOffsetsEV: [Double] = Array(repeating: 0.0, count: ToneEqualizerParameters.bandCount),
        smoothing: Double = 0.5
    ) {
        self.bandOffsetsEV = Self.normalizeBands(bandOffsetsEV)
        self.smoothing = smoothing.isFinite ? min(max(smoothing, 0.0), 1.0) : 0.5
    }

    private enum CodingKeys: String, CodingKey {
        case bandOffsetsEV
        case smoothing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bands = try c.decodeIfPresent([Double].self, forKey: .bandOffsetsEV)
            ?? Array(repeating: 0.0, count: Self.bandCount)
        let smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.5
        self.init(bandOffsetsEV: bands, smoothing: smoothing)
    }

    public static func normalizeBands(_ bands: [Double]) -> [Double] {
        var normalized = Array(repeating: 0.0, count: bandCount)
        for index in 0..<min(bands.count, bandCount) {
            let v = bands[index]
            normalized[index] = v.isFinite ? min(max(v, -3.0), 3.0) : 0.0
        }
        return normalized
    }

    public func sanitized() -> ToneEqualizerParameters {
        ToneEqualizerParameters(bandOffsetsEV: bandOffsetsEV, smoothing: smoothing)
    }
}

/// Frozen v3 deterministic AI / manual color grading parameters (`ADR-018`).
public struct AIColorGradingParameters: Sendable, Codable, Equatable, Hashable {
    public var enabled: Bool
    public var shadows: ColorBalanceWheelAdjustment
    public var midtones: ColorBalanceWheelAdjustment
    public var highlights: ColorBalanceWheelAdjustment
    public var global: ColorBalanceWheelAdjustment
    /// Perceptual brilliance in `[-100.0, 100.0]`.
    public var brilliance: Double
    /// Global chroma in `[-100.0, 100.0]`.
    public var chroma: Double
    public var toneEqualizer: ToneEqualizerParameters
    public var promptHistory: [String]?

    public static let `default` = AIColorGradingParameters()

    public var toneEqualizerEV: [Double] {
        get { toneEqualizer.bandOffsetsEV }
        set { toneEqualizer.bandOffsetsEV = ToneEqualizerParameters.normalizeBands(newValue) }
    }

    public init(
        enabled: Bool = false,
        shadows: ColorBalanceWheelAdjustment = .zero,
        midtones: ColorBalanceWheelAdjustment = .zero,
        highlights: ColorBalanceWheelAdjustment = .zero,
        global: ColorBalanceWheelAdjustment = .zero,
        brilliance: Double = 0.0,
        chroma: Double = 0.0,
        toneEqualizer: ToneEqualizerParameters = ToneEqualizerParameters(),
        promptHistory: [String]? = nil
    ) {
        self.enabled = enabled
        self.shadows = shadows.sanitized()
        self.midtones = midtones.sanitized()
        self.highlights = highlights.sanitized()
        self.global = global.sanitized()
        self.brilliance = Self.clampPercent(brilliance)
        self.chroma = Self.clampPercent(chroma)
        self.toneEqualizer = toneEqualizer.sanitized()
        self.promptHistory = promptHistory
    }

    public init(
        enabled: Bool = false,
        shadows: ColorBalanceWheelAdjustment = .zero,
        midtones: ColorBalanceWheelAdjustment = .zero,
        highlights: ColorBalanceWheelAdjustment = .zero,
        global: ColorBalanceWheelAdjustment = .zero,
        brilliance: Double = 0.0,
        chroma: Double = 0.0,
        toneEqualizerEV: [Double],
        promptHistory: [String]? = nil
    ) {
        self.init(
            enabled: enabled,
            shadows: shadows,
            midtones: midtones,
            highlights: highlights,
            global: global,
            brilliance: brilliance,
            chroma: chroma,
            toneEqualizer: ToneEqualizerParameters(bandOffsetsEV: toneEqualizerEV),
            promptHistory: promptHistory
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case shadows
        case midtones
        case highlights
        case global
        case brilliance
        case chroma
        case toneEqualizer
        case toneEqualizerEV
        case promptHistory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let shadows = try c.decodeIfPresent(ColorBalanceWheelAdjustment.self, forKey: .shadows) ?? .zero
        let midtones = try c.decodeIfPresent(ColorBalanceWheelAdjustment.self, forKey: .midtones) ?? .zero
        let highlights = try c.decodeIfPresent(ColorBalanceWheelAdjustment.self, forKey: .highlights) ?? .zero
        let global = try c.decodeIfPresent(ColorBalanceWheelAdjustment.self, forKey: .global) ?? .zero
        let brilliance = try c.decodeIfPresent(Double.self, forKey: .brilliance) ?? 0.0
        let chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 0.0
        let toneEq: ToneEqualizerParameters
        if let nested = try c.decodeIfPresent(ToneEqualizerParameters.self, forKey: .toneEqualizer) {
            toneEq = nested
        } else if let flatEV = try c.decodeIfPresent([Double].self, forKey: .toneEqualizerEV) {
            toneEq = ToneEqualizerParameters(bandOffsetsEV: flatEV)
        } else {
            toneEq = ToneEqualizerParameters()
        }
        let history = try c.decodeIfPresent([String].self, forKey: .promptHistory)

        self.init(
            enabled: enabled,
            shadows: shadows,
            midtones: midtones,
            highlights: highlights,
            global: global,
            brilliance: brilliance,
            chroma: chroma,
            toneEqualizer: toneEq,
            promptHistory: history
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(midtones, forKey: .midtones)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(global, forKey: .global)
        try c.encode(brilliance, forKey: .brilliance)
        try c.encode(chroma, forKey: .chroma)
        try c.encode(toneEqualizer, forKey: .toneEqualizer)
        try c.encodeIfPresent(promptHistory, forKey: .promptHistory)
    }

    public func sanitized() -> AIColorGradingParameters {
        AIColorGradingParameters(
            enabled: enabled,
            shadows: shadows,
            midtones: midtones,
            highlights: highlights,
            global: global,
            brilliance: brilliance,
            chroma: chroma,
            toneEqualizer: toneEqualizer,
            promptHistory: promptHistory
        )
    }

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(max(value, -100.0), 100.0)
    }
}

/// Stage 2D linear-domain color grading slot between Scene Grading and Dual-Branch ToneMap (`ADR-018`).
public protocol ColorGradingStage: Sendable {
    func apply(
        inputTexture: any MTLTexture,
        params: AIColorGradingParameters?,
        commandQueue: any MTLCommandQueue
    ) async throws -> any MTLTexture
}

/// Default v1.1 zero-cost pass-through implementation of `ColorGradingStage`.
public struct PassThroughColorGradingStage: ColorGradingStage {
    public init() {}

    public func apply(
        inputTexture: any MTLTexture,
        params: AIColorGradingParameters?,
        commandQueue: any MTLCommandQueue
    ) async throws -> any MTLTexture {
        inputTexture
    }
}

/// Dual-zone SDR + HDR histogram statistics provided to multimodal LLM/VLM providers (`ADR-018`).
public struct AgentHistogramSummary: Sendable, Codable, Equatable, Hashable {
    public var bins256: [UInt32]
    public var shadowFraction: Double
    public var midtoneFraction: Double
    public var highlightFraction: Double
    public var hdrAboveWhiteFraction: Double

    public init(
        bins256: [UInt32] = Array(repeating: 0, count: 256),
        shadowFraction: Double = 0.0,
        midtoneFraction: Double = 0.0,
        highlightFraction: Double = 0.0,
        hdrAboveWhiteFraction: Double = 0.0
    ) {
        self.bins256 = bins256
        self.shadowFraction = shadowFraction
        self.midtoneFraction = midtoneFraction
        self.highlightFraction = highlightFraction
        self.hdrAboveWhiteFraction = hdrAboveWhiteFraction
    }
}

/// Multimodal context payload passed to `LLMProviderProtocol`.
/// Intentionally stores NO API keys or credentials (`ADR-018`, macOS Keychain only).
public struct AgentImageContext: Sendable, Codable, Equatable {
    public var previewJPEGData: Data
    public var heatmapJPEGData: Data?
    public var exif: WhitelistedExif
    public var estimatedSceneKelvin: Double
    public var histogram: AgentHistogramSummary
    public var currentParams: EffectiveDevelopParams
    public var userPrompt: String

    public init(
        previewJPEGData: Data,
        heatmapJPEGData: Data? = nil,
        exif: WhitelistedExif,
        estimatedSceneKelvin: Double = 5500.0,
        histogram: AgentHistogramSummary = AgentHistogramSummary(),
        currentParams: EffectiveDevelopParams,
        userPrompt: String
    ) {
        self.previewJPEGData = previewJPEGData
        self.heatmapJPEGData = heatmapJPEGData
        self.exif = exif
        self.estimatedSceneKelvin = estimatedSceneKelvin
        self.histogram = histogram
        self.currentParams = currentParams
        self.userPrompt = userPrompt
    }
}

/// Strict JSON recipe returned by a v3 LLM/VLM provider (`ADR-018`).
public struct ChiaroAgentRecipe: Sendable, Codable, Equatable, Hashable {
    public var developPatch: PerPhotoDelta
    public var colorGradingNodes: AIColorGradingParameters?
    public var recommendedDenoise: DenoiseParameters?
    public var rationale: LocalizedText

    public init(
        developPatch: PerPhotoDelta = PerPhotoDelta(),
        colorGradingNodes: AIColorGradingParameters? = nil,
        recommendedDenoise: DenoiseParameters? = nil,
        rationale: LocalizedText
    ) {
        self.developPatch = developPatch
        self.colorGradingNodes = colorGradingNodes
        self.recommendedDenoise = recommendedDenoise
        self.rationale = rationale
    }
}

/// Pluggable cloud/local VLM provider contract (`ADR-018`).
/// Implementations MUST read credentials from macOS Keychain and NEVER persist API keys in sidecars or context payloads.
public protocol LLMProviderProtocol: Sendable {
    var providerID: String { get }
    var displayName: String { get }
    var isLocalOffline: Bool { get }
    func generateRecipe(context: AgentImageContext) async throws -> ChiaroAgentRecipe
}
