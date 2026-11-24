import Foundation

/// Log2 HDR headroom stops above SDR diffuse white (1.0).
/// Used in ISO/IEC 21496-1 binary metadata, HDRToneMap XMP, and libavif.
public struct HeadroomStops: Sendable, Codable, Hashable, Comparable {
    public let log2Value: Double

    public static let sdr = HeadroomStops(log2Value: 0.0)
    public static let x2 = HeadroomStops(log2Value: 1.0)
    public static let x4 = HeadroomStops(log2Value: 2.0)
    public static let defaultHDR = HeadroomStops(log2Value: 2.5)
    public static let x8 = HeadroomStops(log2Value: 3.0)
    public static let maxSupported = HeadroomStops(log2Value: 4.0)

    public init(log2Value: Double) {
        self.log2Value = log2Value
    }

    public func toLinear() -> LinearHeadroom {
        LinearHeadroom(multiplier: exp2(log2Value))
    }

    public static func < (lhs: HeadroomStops, rhs: HeadroomStops) -> Bool {
        lhs.log2Value < rhs.log2Value
    }
}

/// Linear HDR headroom multiplier (diffuse white = 1.0).
/// Used in CIImage.contentHeadroom, NSScreen, HDRGainMapHeadroom XMP, and libultrahdr.
public struct LinearHeadroom: Sendable, Codable, Hashable, Comparable {
    public let multiplier: Double

    public static let sdr = LinearHeadroom(multiplier: 1.0)
    public static let x2 = LinearHeadroom(multiplier: 2.0)
    public static let x4 = LinearHeadroom(multiplier: 4.0)
    public static let x8 = LinearHeadroom(multiplier: 8.0)

    public init(multiplier: Double) {
        self.multiplier = multiplier
    }

    public func toStops() -> HeadroomStops {
        HeadroomStops(log2Value: log2(max(multiplier, 1.0)))
    }

    public static func < (lhs: LinearHeadroom, rhs: LinearHeadroom) -> Bool {
        lhs.multiplier < rhs.multiplier
    }
}
