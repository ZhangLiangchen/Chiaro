import Foundation

/// High-precision RAW Bayer demosaic algorithm selection (`ADR-012`).
public enum DemosaicAlgorithm: String, Sendable, Codable, CaseIterable, Hashable {
    /// Adaptive Homogeneity-Directed / Aliasing Minimization and Zipper Elimination (LibRTProcess default).
    case amaze
    /// Linear Minimum Mean Square Error (high-ISO night scenes via LibRTProcess).
    case lmmse
    /// Dual-Channel Bilinear interpolation (LibRaw `user_qual = 4`).
    case dcb
    /// Directional Homogeneity-based interpolation (LibRaw `user_qual = 11`).
    case dht
    /// Adaptive Homogeneity-Directed baseline (LibRaw `user_qual = 3`).
    case ahd

    public static let `default`: DemosaicAlgorithm = .amaze
}

/// User/sidecar preference for the open-source optical correction engine (`ADR-013`).
public enum OpticalProfileSource: String, Sendable, Codable, CaseIterable, Hashable {
    /// Prefer Sony `.ARW` embedded factory curves; fall back to offline Lensfun DB.
    case auto
    /// Only use `.ARW` embedded factory optical curves.
    case embedded
    /// Only use the Lensfun offline/user XML database.
    case lensfun
}

/// Actual runtime optical correction engine resolved for a given frame (`FR-19`, `ADR-013`).
public enum ResolvedOpticsSource: String, Sendable, Codable, CaseIterable, Hashable {
    case embeddedARW = "embedded_arw"
    case lensfun = "lensfun"
    case none = "none"
}

/// Open-source optical correction parameters (zero speculative manual k1/k2/CA sliders).
public struct OpticalCorrectionParameters: Sendable, Codable, Equatable, Hashable {
    public var enabled: Bool
    public var source: OpticalProfileSource
    public var lensfunCameraOverride: String?
    public var lensfunLensOverride: String?
    public var distortion: Bool
    public var autoScale: Bool
    public var tca: Bool
    public var vignetting: Bool
    /// Vignetting compensation blend strength in `[0.0, 1.0]` (UI `0%...100%`).
    public var vignettingStrength: Double

    public static let `default` = OpticalCorrectionParameters()

    public init(
        enabled: Bool = true,
        source: OpticalProfileSource = .auto,
        lensfunCameraOverride: String? = nil,
        lensfunLensOverride: String? = nil,
        distortion: Bool = true,
        autoScale: Bool = true,
        tca: Bool = true,
        vignetting: Bool = true,
        vignettingStrength: Double = 1.0
    ) {
        self.enabled = enabled
        self.source = source
        self.lensfunCameraOverride = Self.normalizeOverride(lensfunCameraOverride)
        self.lensfunLensOverride = Self.normalizeOverride(lensfunLensOverride)
        self.distortion = distortion
        self.autoScale = autoScale
        self.tca = tca
        self.vignetting = vignetting
        self.vignettingStrength = Self.sanitizeStrength(vignettingStrength)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case source
        case lensfunCameraOverride
        case lensfunLensOverride
        case distortion
        case autoScale
        case tca
        case vignetting
        case vignettingStrength
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let source: OpticalProfileSource
        if let rawSource = try c.decodeIfPresent(String.self, forKey: .source) {
            source = OpticalProfileSource(rawValue: rawSource) ?? .auto
        } else {
            source = .auto
        }
        let cameraOverride = try c.decodeIfPresent(String.self, forKey: .lensfunCameraOverride)
        let lensOverride = try c.decodeIfPresent(String.self, forKey: .lensfunLensOverride)
        let distortion = try c.decodeIfPresent(Bool.self, forKey: .distortion) ?? true
        let autoScale = try c.decodeIfPresent(Bool.self, forKey: .autoScale) ?? true
        let tca = try c.decodeIfPresent(Bool.self, forKey: .tca) ?? true
        let vignetting = try c.decodeIfPresent(Bool.self, forKey: .vignetting) ?? true
        let strength = try c.decodeIfPresent(Double.self, forKey: .vignettingStrength) ?? 1.0

        self.init(
            enabled: enabled,
            source: source,
            lensfunCameraOverride: cameraOverride,
            lensfunLensOverride: lensOverride,
            distortion: distortion,
            autoScale: autoScale,
            tca: tca,
            vignetting: vignetting,
            vignettingStrength: strength
        )
    }

    public func sanitized() -> OpticalCorrectionParameters {
        OpticalCorrectionParameters(
            enabled: enabled,
            source: source,
            lensfunCameraOverride: lensfunCameraOverride,
            lensfunLensOverride: lensfunLensOverride,
            distortion: distortion,
            autoScale: autoScale,
            tca: tca,
            vignetting: vignetting,
            vignettingStrength: vignettingStrength
        )
    }

    private static func sanitizeStrength(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.0), 1.0)
    }

    private static func normalizeOverride(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Embedded Sony `.ARW` SubIFD / SR2SubIFD factory optical curves (`ADR-013`).
///
/// Tag mapping verified empirically on Sony `ILCE-7CM2` `.ARW` samples:
/// - Distortion (`0x7037` / `0x7982`): `nc` active nodes (`16` FF, `11` APS-C)
/// - Chromatic Aberration (`0x7035` / `0x7980`): `2 * nc` nodes (`nc` Red + `nc` Blue)
/// - Vignetting (`0x7032` / `0x797d`): `nc` active nodes (`16` FF, `11` APS-C)
public struct EmbeddedSonyOpticsPayload: Sendable, Codable, Equatable, Hashable {
    public static let maxNodeCount = 16

    public var distortionNodeCount: Int
    public var distortionParams: [Int16]

    public var caNodeCount: Int
    public var caRedParams: [Int16]
    public var caBlueParams: [Int16]

    public var vignettingNodeCount: Int
    public var vignettingParams: [Int16]

    public var focalLengthMM: Double?
    public var fNumber: Double?
    public var sensorAspectRatio: Double
    public var cropFactor: Double

    public init(
        distortionNodeCount: Int = 0,
        distortionParams: [Int16] = [],
        caNodeCount: Int = 0,
        caRedParams: [Int16] = [],
        caBlueParams: [Int16] = [],
        vignettingNodeCount: Int = 0,
        vignettingParams: [Int16] = [],
        focalLengthMM: Double? = nil,
        fNumber: Double? = nil,
        sensorAspectRatio: Double = 1.5,
        cropFactor: Double = 1.0
    ) {
        let clampedDistCount = min(max(distortionNodeCount, 0), Self.maxNodeCount, distortionParams.count)
        self.distortionNodeCount = clampedDistCount
        self.distortionParams = Array(distortionParams.prefix(clampedDistCount))

        let clampedCACount = min(max(caNodeCount, 0), Self.maxNodeCount, caRedParams.count, caBlueParams.count)
        self.caNodeCount = clampedCACount
        self.caRedParams = Array(caRedParams.prefix(clampedCACount))
        self.caBlueParams = Array(caBlueParams.prefix(clampedCACount))

        let clampedVigCount = min(max(vignettingNodeCount, 0), Self.maxNodeCount, vignettingParams.count)
        self.vignettingNodeCount = clampedVigCount
        self.vignettingParams = Array(vignettingParams.prefix(clampedVigCount))

        self.focalLengthMM = focalLengthMM.flatMap { ($0.isFinite && $0 > 0.0) ? $0 : nil }
        self.fNumber = fNumber.flatMap { ($0.isFinite && $0 > 0.0) ? $0 : nil }
        self.sensorAspectRatio = (sensorAspectRatio.isFinite && sensorAspectRatio > 0.0) ? sensorAspectRatio : 1.5
        self.cropFactor = (cropFactor.isFinite && cropFactor > 0.0) ? cropFactor : 1.0
    }

    private enum CodingKeys: String, CodingKey {
        case distortionNodeCount
        case distortionParams
        case caNodeCount
        case caRedParams
        case caBlueParams
        case vignettingNodeCount
        case vignettingParams
        case focalLengthMM
        case fNumber
        case sensorAspectRatio
        case cropFactor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let distCount = try c.decodeIfPresent(Int.self, forKey: .distortionNodeCount) ?? 0
        let distParams = try c.decodeIfPresent([Int16].self, forKey: .distortionParams) ?? []
        let caCount = try c.decodeIfPresent(Int.self, forKey: .caNodeCount) ?? 0
        let caRed = try c.decodeIfPresent([Int16].self, forKey: .caRedParams) ?? []
        let caBlue = try c.decodeIfPresent([Int16].self, forKey: .caBlueParams) ?? []
        let vigCount = try c.decodeIfPresent(Int.self, forKey: .vignettingNodeCount) ?? 0
        let vigParams = try c.decodeIfPresent([Int16].self, forKey: .vignettingParams) ?? []
        let focal = try c.decodeIfPresent(Double.self, forKey: .focalLengthMM)
        let fNum = try c.decodeIfPresent(Double.self, forKey: .fNumber)
        let aspect = try c.decodeIfPresent(Double.self, forKey: .sensorAspectRatio) ?? 1.5
        let crop = try c.decodeIfPresent(Double.self, forKey: .cropFactor) ?? 1.0

        self.init(
            distortionNodeCount: distCount,
            distortionParams: distParams,
            caNodeCount: caCount,
            caRedParams: caRed,
            caBlueParams: caBlue,
            vignettingNodeCount: vigCount,
            vignettingParams: vigParams,
            focalLengthMM: focal,
            fNumber: fNum,
            sensorAspectRatio: aspect,
            cropFactor: crop
        )
    }

    public var hasDistortion: Bool {
        distortionNodeCount > 0 && distortionParams.count >= distortionNodeCount
    }

    public var hasTCA: Bool {
        caNodeCount > 0 && caRedParams.count >= caNodeCount && caBlueParams.count >= caNodeCount
    }

    public var hasVignetting: Bool {
        vignettingNodeCount > 0 && vignettingParams.count >= vignettingNodeCount
    }

    public var hasAnyCorrection: Bool {
        hasDistortion || hasTCA || hasVignetting
    }
}

/// Resolved optics metadata reported to UI badges and CLI NDJSON `job_decoded` events.
public struct OpticsResolutionInfo: Sendable, Codable, Equatable, Hashable {
    public var source: ResolvedOpticsSource
    public var lensMatched: String?
    public var cameraMatched: String?
    public var distortionApplied: Bool
    public var tcaApplied: Bool
    public var vignettingApplied: Bool

    public static let none = OpticsResolutionInfo(source: .none, lensMatched: nil)

    public init(
        source: ResolvedOpticsSource,
        lensMatched: String? = nil,
        cameraMatched: String? = nil,
        distortionApplied: Bool = false,
        tcaApplied: Bool = false,
        vignettingApplied: Bool = false
    ) {
        self.source = source
        self.lensMatched = lensMatched
        self.cameraMatched = cameraMatched
        self.distortionApplied = distortionApplied
        self.tcaApplied = tcaApplied
        self.vignettingApplied = vignettingApplied
    }
}
