import Foundation

public protocol ARWDecoderProtocol: Sendable {
    func decodeFull(url: URL, options: DecodeOptions) async throws -> DecodedRAWFrame
    func decodeProxy(url: URL) async throws -> DecodedRAWFrame
}

public protocol MetalPipelineProtocol: Sendable {
    func render(
        frame: DecodedRAWFrame,
        params: EffectiveDevelopParams,
        outputSpec: RenderOutputSpec
    ) async throws -> RenderedFrame

    func recomputeGainMapCompensated(
        hdrTexture: SendableMTLTexture,
        compressedSDRJPEGData: Data,
        metadata: GainMapMetadata,
        gamma: Double,
        channels: GainMapChannels,
        resolution: GainMapResolution,
        midtoneAnchorP: Double,
        baseColorSpace: BaseColorSpace?
    ) async throws -> GainMapResult
}

public extension MetalPipelineProtocol {
    func recomputeGainMapCompensated(
        hdrTexture: SendableMTLTexture,
        compressedSDRJPEGData: Data,
        metadata: GainMapMetadata,
        gamma: Double,
        channels: GainMapChannels,
        resolution: GainMapResolution
    ) async throws -> GainMapResult {
        try await recomputeGainMapCompensated(
            hdrTexture: hdrTexture,
            compressedSDRJPEGData: compressedSDRJPEGData,
            metadata: metadata,
            gamma: gamma,
            channels: channels,
            resolution: resolution,
            midtoneAnchorP: 0.80,
            baseColorSpace: nil
        )
    }
}

public protocol FrameEncoderProtocol: Sendable {
    var format: OutputFormat { get }
    func encode(frame: RenderedFrame, preset: PresetSchema, to outputURL: URL) async throws -> ExportArtifact
}

public protocol HEICEncoderProtocol: FrameEncoderProtocol {}
public protocol JPEGEncoderProtocol: FrameEncoderProtocol {}
public protocol AVIFEncoderProtocol: FrameEncoderProtocol {}

public protocol HLGVideoEncoderProtocol: Sendable {
    func encodeVideo(
        frame: RenderedFrame,
        preset: PresetSchema,
        options: HLGVideoOptions,
        to outputURL: URL
    ) async throws -> ExportArtifact
}

public protocol ComplianceProbeProtocol: Sendable {
    func verify(url: URL, expected: ComplianceExpectation) async throws -> ComplianceReport
}

public protocol HLGVideoProbeProtocol: Sendable {
    func verify(url: URL, expected: HLGComplianceExpectation) async throws -> ComplianceReport
}
