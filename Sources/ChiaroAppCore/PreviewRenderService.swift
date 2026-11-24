import Foundation
import ChiaroCore
import Metal

public actor PreviewRenderService {
    private struct ProxyCacheKey: Hashable {
        let canonicalPath: String
        let backend: RAWBackend
    }

    private struct RenderPoolContextKey: Equatable {
        let canonicalPath: String
        let cropWidth: Int
        let cropHeight: Int
        let orientation: Int
        let cropAspect: AspectRatio
        let maxLongEdge: Int?
    }

    private let libRawDecoder = LibRawDecoder()
    private let cirawDecoder = CIRAWv9Decoder()
    private var engineInstance: MetalPipelineEngine?
    private var proxyCache: [ProxyCacheKey: DecodedRAWFrame] = [:]
    private var proxyLRU: [ProxyCacheKey] = []
    private let maxCachedProxies = 6
    private var lastRenderContextKey: RenderPoolContextKey?

    public init() {}

    public func getEngine() throws -> MetalPipelineEngine {
        if let existing = engineInstance {
            return existing
        }
        let created = try MetalPipelineEngine(poolMaxBytes: 1536 * 1024 * 1024)
        engineInstance = created
        return created
    }

    public func sharedShaderLibrary() throws -> MetalShaderLibrary {
        try getEngine().shaderLibrary
    }

    public func evictPoolBeforeBatch() {
        engineInstance?.texturePool.evictIdle()
    }

    public func decodeProxy(url: URL, backend: RAWBackend) async throws -> DecodedRAWFrame {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        let key = ProxyCacheKey(canonicalPath: canonical, backend: backend)

        if let cached = proxyCache[key] {
            if let idx = proxyLRU.firstIndex(of: key) {
                proxyLRU.remove(at: idx)
            }
            proxyLRU.append(key)
            return cached
        }

        let decoded: DecodedRAWFrame
        switch backend {
        case .libraw:
            decoded = try await libRawDecoder.decodeProxy(url: url)
        case .ciraw9:
            decoded = try await cirawDecoder.decodeProxy(url: url)
        }

        try Task.checkCancellation()
        proxyCache[key] = decoded
        proxyLRU.append(key)
        while proxyLRU.count > maxCachedProxies {
            let evicted = proxyLRU.removeFirst()
            proxyCache.removeValue(forKey: evicted)
        }
        return decoded
    }

    public func renderPreviewAndHistogram(
        url: URL,
        backend: RAWBackend,
        params: EffectiveDevelopParams,
        outputSpec: RenderOutputSpec,
        displayHeadroom: LinearHeadroom
    ) async throws -> PreviewRenderSnapshot {
        try Task.checkCancellation()
        let proxyFrame = try await decodeProxy(url: url, backend: backend)
        try Task.checkCancellation()

        let engine = try getEngine()
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let contextKey = RenderPoolContextKey(
            canonicalPath: canonicalPath,
            cropWidth: proxyFrame.visibleCrop.width,
            cropHeight: proxyFrame.visibleCrop.height,
            orientation: proxyFrame.orientation,
            cropAspect: params.cropAspect,
            maxLongEdge: params.maxLongEdge
        )
        if lastRenderContextKey != contextKey {
            engine.texturePool.evictIdle()
            lastRenderContextKey = contextKey
        }

        let rendered: RenderedFrame
        do {
            rendered = try await engine.render(
                frame: proxyFrame,
                params: params,
                outputSpec: outputSpec
            )
        } catch MTLHeapTexturePoolError.memoryBudgetExceeded {
            engine.texturePool.evictIdle()
            rendered = try await engine.render(
                frame: proxyFrame,
                params: params,
                outputSpec: outputSpec
            )
        }
        try Task.checkCancellation()

        let histBins = try computeHistogram(
            engine: engine,
            rendered: rendered,
            displayHeadroom: displayHeadroom
        )

        let uniforms = EDRPreviewUniforms(
            mode: .standardEDR,
            sdrExposureScaleEnabled: false,
            metadata: rendered.gainMap.metadata,
            isMonoGainMap: rendered.gainMap.buffer.channels == .mono1ch,
            isSRGBBase: rendered.baseColorSpace == .srgb,
            displayHeadroom: displayHeadroom
        )

        return PreviewRenderSnapshot(
            sourceURL: url,
            renderedFrame: rendered,
            effectiveParams: params,
            fallbackReason: proxyFrame.fallbackReason,
            backendUsed: proxyFrame.backendUsed,
            colorMatrices: proxyFrame.colorMatrices,
            histogramBins: histBins,
            uniforms: uniforms
        )
    }

    public func recomputeHistogram(
        rendered: RenderedFrame,
        displayHeadroom: LinearHeadroom
    ) throws -> [UInt32] {
        try Task.checkCancellation()
        let engine = try getEngine()
        return try computeHistogram(
            engine: engine,
            rendered: rendered,
            displayHeadroom: displayHeadroom
        )
    }

    private func computeHistogram(
        engine: MetalPipelineEngine,
        rendered: RenderedFrame,
        displayHeadroom: LinearHeadroom
    ) throws -> [UInt32] {
        try Task.checkCancellation()
        guard let sdrLinearTex = rendered.sdrLinearTexture else {
            return Array(repeating: 0, count: 256)
        }
        let gmTex = try uploadGainMapTexture(device: engine.device, buffer: rendered.gainMap.buffer)
        let histUniforms = EDRPreviewUniforms(
            mode: .standardEDR,
            sdrExposureScaleEnabled: false,
            metadata: rendered.gainMap.metadata,
            isMonoGainMap: rendered.gainMap.buffer.channels == .mono1ch,
            isSRGBBase: rendered.baseColorSpace == .srgb,
            displayHeadroom: displayHeadroom
        )
        return try engine.edrPreviewPipeline.computeDualZoneHistogram(
            commandQueue: engine.commandQueue,
            sdrLinearTexture: sdrLinearTex,
            gainMapTexture: SendableMTLTexture(gmTex),
            uniforms: histUniforms
        )
    }

    private func uploadGainMapTexture(
        device: any MTLDevice,
        buffer: GainMapBuffer
    ) throws -> any MTLTexture {
        let pixelFormat: MTLPixelFormat = (buffer.channels == .mono1ch) ? .r8Unorm : .bgra8Unorm
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(1, buffer.width),
            height: max(1, buffer.height),
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw EDRPreviewError.bufferAllocationFailed
        }
        buffer.data.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, buffer.width, buffer.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: buffer.bytesPerRow
            )
        }
        return texture
    }
}
