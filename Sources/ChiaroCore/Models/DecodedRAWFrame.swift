import Foundation

public enum RAWBackend: String, Sendable, Codable, CaseIterable, Hashable {
    case libraw
    case ciraw9
}

public struct DecodeOptions: Sendable, Codable, Equatable, Hashable {
    public var backend: RAWBackend
    public var highlightMode: HighlightReconstructionMode
    public var isProxy: Bool
    public var maxThreadsPerWorker: Int
    public var customRenderedHDR: Bool
    public var demosaicAlgorithm: DemosaicAlgorithm

    public static let `default` = DecodeOptions()

    public init(
        backend: RAWBackend = .libraw,
        highlightMode: HighlightReconstructionMode = .opposedInpaint,
        isProxy: Bool = false,
        maxThreadsPerWorker: Int = 2,
        customRenderedHDR: Bool = false,
        demosaicAlgorithm: DemosaicAlgorithm = .amaze
    ) {
        self.backend = backend
        self.highlightMode = highlightMode
        self.isProxy = isProxy
        self.maxThreadsPerWorker = maxThreadsPerWorker
        self.customRenderedHDR = customRenderedHDR
        self.demosaicAlgorithm = demosaicAlgorithm
    }
}

public enum CFAPattern: String, Sendable, Codable, Hashable {
    case rggb
    case bggr
    case grbg
    case gbrg
    case unknown
}

public enum LinearPayloadColorSpace: String, Sendable, Codable, Hashable {
    case cameraNative
    case linearRec2020
    case extendedLinearDisplayP3
}

public enum RAWPixelPayload: Sendable, Equatable {
    case rawBayer(width: Int, height: Int, bitsPerSample: Int, cfa: CFAPattern, data: Data)
    case linearRGB16F(width: Int, height: Int, colorSpace: LinearPayloadColorSpace, data: Data)
    case linearRGB16U(width: Int, height: Int, colorSpace: LinearPayloadColorSpace, data: Data)
}

public struct SensorCropRect: Sendable, Codable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CameraColorMatrices: Sendable, Codable, Equatable, Hashable {
    public var camXYZ: [Double]        // 9 elements (3x3 row-major) or 12 elements (4x3)
    public var forwardMatrix: [Double] // 9 elements (3x3 row-major)
    public var wbMultipliers: [Double] // 4 elements [R, G1, B, G2]
    public var asShotWBApplied: Bool

    public init(
        camXYZ: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1],
        forwardMatrix: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1],
        wbMultipliers: [Double] = [1, 1, 1, 1],
        asShotWBApplied: Bool = false
    ) {
        self.camXYZ = camXYZ
        self.forwardMatrix = forwardMatrix
        self.wbMultipliers = wbMultipliers
        self.asShotWBApplied = asShotWBApplied
    }
}

/// Standard Exif 2.32 metadata whitelist (ADR-004).
/// Intentionally excludes any MakerNote field by construction.
public struct WhitelistedExif: Sendable, Codable, Equatable, Hashable {
    public var make: String?
    public var model: String?
    public var lensMake: String?
    public var lensModel: String?
    public var focalLengthMM: Double?
    public var focalLengthIn35mmFilm: Int?
    public var exposureTimeSeconds: Double?
    public var fNumber: Double?
    public var isoSpeedRatings: Int?
    public var exposureBiasEV: Double?
    public var dateTimeOriginal: String?
    public var offsetTimeOriginal: String?
    public var subSecTimeOriginal: String?
    public var gpsLatitude: Double?
    public var gpsLatitudeRef: String?
    public var gpsLongitude: Double?
    public var gpsLongitudeRef: String?
    public var gpsAltitude: Double?
    public var gpsAltitudeRef: Int?
    public var gpsTimestamp: String?
    public var gpsDateStamp: String?
    public var orientation: Int
    public var customRendered: Int?

    public init(
        make: String? = nil,
        model: String? = nil,
        lensMake: String? = nil,
        lensModel: String? = nil,
        focalLengthMM: Double? = nil,
        focalLengthIn35mmFilm: Int? = nil,
        exposureTimeSeconds: Double? = nil,
        fNumber: Double? = nil,
        isoSpeedRatings: Int? = nil,
        exposureBiasEV: Double? = nil,
        dateTimeOriginal: String? = nil,
        offsetTimeOriginal: String? = nil,
        subSecTimeOriginal: String? = nil,
        gpsLatitude: Double? = nil,
        gpsLatitudeRef: String? = nil,
        gpsLongitude: Double? = nil,
        gpsLongitudeRef: String? = nil,
        gpsAltitude: Double? = nil,
        gpsAltitudeRef: Int? = nil,
        gpsTimestamp: String? = nil,
        gpsDateStamp: String? = nil,
        orientation: Int = 1,
        customRendered: Int? = nil
    ) {
        self.make = make
        self.model = model
        self.lensMake = lensMake
        self.lensModel = lensModel
        self.focalLengthMM = focalLengthMM
        self.focalLengthIn35mmFilm = focalLengthIn35mmFilm
        self.exposureTimeSeconds = exposureTimeSeconds
        self.fNumber = fNumber
        self.isoSpeedRatings = isoSpeedRatings
        self.exposureBiasEV = exposureBiasEV
        self.dateTimeOriginal = dateTimeOriginal
        self.offsetTimeOriginal = offsetTimeOriginal
        self.subSecTimeOriginal = subSecTimeOriginal
        self.gpsLatitude = gpsLatitude
        self.gpsLatitudeRef = gpsLatitudeRef
        self.gpsLongitude = gpsLongitude
        self.gpsLongitudeRef = gpsLongitudeRef
        self.gpsAltitude = gpsAltitude
        self.gpsAltitudeRef = gpsAltitudeRef
        self.gpsTimestamp = gpsTimestamp
        self.gpsDateStamp = gpsDateStamp
        self.orientation = orientation
        self.customRendered = customRendered
    }
}

public struct DecodedRAWFrame: Sendable {
    public var sourceURL: URL
    public var backendUsed: RAWBackend
    public var fallbackReason: String?
    public var payload: RAWPixelPayload
    public var visibleCrop: SensorCropRect
    public var orientation: Int
    public var colorMatrices: CameraColorMatrices
    public var isLosslessMS: Bool
    public var exif: WhitelistedExif
    public var demosaicUsed: DemosaicAlgorithm?
    public var embeddedSonyOptics: EmbeddedSonyOpticsPayload?
    public var fullSensorDimensions: PixelDimensions?
    public var cropFactor: Double?

    public var lensModel: String? { exif.lensModel }
    public var focalLengthMM: Double? { exif.focalLengthMM }
    public var apertureFNumber: Double? { exif.fNumber }
    public var isoSpeed: Int? { exif.isoSpeedRatings }

    public init(
        sourceURL: URL,
        backendUsed: RAWBackend,
        fallbackReason: String? = nil,
        payload: RAWPixelPayload,
        visibleCrop: SensorCropRect,
        orientation: Int,
        colorMatrices: CameraColorMatrices,
        isLosslessMS: Bool,
        exif: WhitelistedExif,
        demosaicUsed: DemosaicAlgorithm? = nil,
        embeddedSonyOptics: EmbeddedSonyOpticsPayload? = nil,
        fullSensorDimensions: PixelDimensions? = nil,
        cropFactor: Double? = nil
    ) {
        self.sourceURL = sourceURL
        self.backendUsed = backendUsed
        self.fallbackReason = fallbackReason
        self.payload = payload
        self.visibleCrop = visibleCrop
        self.orientation = orientation
        self.colorMatrices = colorMatrices
        self.isLosslessMS = isLosslessMS
        self.exif = exif
        self.demosaicUsed = demosaicUsed
        self.embeddedSonyOptics = embeddedSonyOptics
        self.fullSensorDimensions = fullSensorDimensions
        self.cropFactor = cropFactor
    }
}
