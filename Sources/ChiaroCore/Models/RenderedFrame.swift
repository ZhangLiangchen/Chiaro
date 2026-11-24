import CoreGraphics
import CoreVideo
import Foundation
import Metal

/// Swift 6 strict-concurrency wrapper around an MTLTexture whose lifetime and command-buffer
/// synchronization are managed by the Metal pipeline and pool.
public final class SendableMTLTexture: @unchecked Sendable {
    public let texture: any MTLTexture
    private let onDeinit: (@Sendable () -> Void)?

    public init(_ texture: any MTLTexture, onDeinit: (@Sendable () -> Void)? = nil) {
        self.texture = texture
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit?()
    }
}

/// Swift 6 strict-concurrency wrapper around an immutable CVPixelBuffer passed across actors.
public final class SendablePixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

public struct PixelDimensions: Sendable, Codable, Equatable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct GainMapMetadata: Sendable, Codable, Equatable, Hashable {
    /// Symmetric offset k = 1/64 = 0.015625 per ISO/IEC 21496-1 & ADR-003.
    public static let symmetricOffset: Double = 1.0 / 64.0

    public var gainMapMin: [Double]
    public var gainMapMax: [Double]
    public var gamma: [Double]
    public var baseOffset: [Double]
    public var altOffset: [Double]
    public var baseHeadroom: HeadroomStops
    public var alternateHeadroom: HeadroomStops
    public var useBaseColorSpace: Bool

    public init(
        gainMapMin: [Double],
        gainMapMax: [Double],
        gamma: [Double],
        baseOffset: [Double] = [GainMapMetadata.symmetricOffset],
        altOffset: [Double] = [GainMapMetadata.symmetricOffset],
        baseHeadroom: HeadroomStops = .sdr,
        alternateHeadroom: HeadroomStops,
        useBaseColorSpace: Bool = true
    ) {
        self.gainMapMin = gainMapMin
        self.gainMapMax = gainMapMax
        self.gamma = gamma
        self.baseOffset = baseOffset
        self.altOffset = altOffset
        self.baseHeadroom = baseHeadroom
        self.alternateHeadroom = alternateHeadroom
        self.useBaseColorSpace = useBaseColorSpace
    }
}

public struct GainMapBuffer: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var channels: GainMapChannels
    public var bytesPerRow: Int
    public var data: Data

    public init(
        width: Int,
        height: Int,
        channels: GainMapChannels,
        bytesPerRow: Int,
        data: Data
    ) {
        self.width = width
        self.height = height
        self.channels = channels
        self.bytesPerRow = bytesPerRow
        self.data = data
    }
}

public struct GainMapResult: Sendable, Equatable {
    public var buffer: GainMapBuffer
    public var metadata: GainMapMetadata

    public init(buffer: GainMapBuffer, metadata: GainMapMetadata) {
        self.buffer = buffer
        self.metadata = metadata
    }
}

public struct RenderOutputSpec: Sendable, Codable, Equatable, Hashable {
    public var targetBitDepth: BitDepth
    public var baseColorSpace: BaseColorSpace
    public var gainMapChannels: GainMapChannels
    public var gainMapResolution: GainMapResolution
    public var gainMapGamma: Double
    public var lockLegacyAppleGainMapBounds: Bool
    public var generateHLGTexture: Bool
    public var hlgTargetDimensions: PixelDimensions?

    public init(
        targetBitDepth: BitDepth = .bit10,
        baseColorSpace: BaseColorSpace = .displayP3,
        gainMapChannels: GainMapChannels = .rgb3ch,
        gainMapResolution: GainMapResolution = .half,
        gainMapGamma: Double = 1.0,
        lockLegacyAppleGainMapBounds: Bool = false,
        generateHLGTexture: Bool = false,
        hlgTargetDimensions: PixelDimensions? = nil
    ) {
        self.targetBitDepth = targetBitDepth
        self.baseColorSpace = baseColorSpace
        self.gainMapChannels = gainMapChannels
        self.gainMapResolution = gainMapResolution
        self.gainMapGamma = gainMapGamma
        self.lockLegacyAppleGainMapBounds = lockLegacyAppleGainMapBounds
        self.generateHLGTexture = generateHLGTexture
        self.hlgTargetDimensions = hlgTargetDimensions
    }
}

public struct RenderedFrame: Sendable {
    public var sourceURL: URL
    public var width: Int
    public var height: Int
    public var baseColorSpace: BaseColorSpace
    public var sdrCGImage: CGImage
    public var sdrLinearTexture: SendableMTLTexture?
    public var hdrLinearTexture: SendableMTLTexture?
    public var hlgPixelBuffer: SendablePixelBuffer?
    public var gainMap: GainMapResult
    public var exif: WhitelistedExif

    public init(
        sourceURL: URL,
        width: Int,
        height: Int,
        baseColorSpace: BaseColorSpace,
        sdrCGImage: CGImage,
        sdrLinearTexture: SendableMTLTexture? = nil,
        hdrLinearTexture: SendableMTLTexture? = nil,
        hlgPixelBuffer: SendablePixelBuffer? = nil,
        gainMap: GainMapResult,
        exif: WhitelistedExif
    ) {
        self.sourceURL = sourceURL
        self.width = width
        self.height = height
        self.baseColorSpace = baseColorSpace
        self.sdrCGImage = sdrCGImage
        self.sdrLinearTexture = sdrLinearTexture
        self.hdrLinearTexture = hdrLinearTexture
        self.hlgPixelBuffer = hlgPixelBuffer
        self.gainMap = gainMap
        self.exif = exif
    }
}
