import Dispatch
import Foundation
import os

public enum BatchProgressEvent: Sendable {
    case batchStarted(totalJobs: Int, presetID: String, formats: [OutputFormat])
    case jobStarted(jobID: UUID, sourceURL: URL)
    case jobDecoded(jobID: UUID, sourceURL: URL, backendUsed: RAWBackend, fallbackReason: String?)
    case jobRendered(jobID: UUID, sourceURL: URL)
    case jobCompleted(ExportResult)
    case batchCompleted(totalJobs: Int, succeeded: Int, failed: Int, elapsedSeconds: Double)
}

public final class BoundedBatchPipeline: Sendable {
    private struct Stage1Output: Sendable {
        let index: Int
        let job: ExportJob
        let startTime: ContinuousClock.Instant
        let decodedFrame: DecodedRAWFrame
        let wantCustomRenderedHDR: Bool
    }

    private struct Stage2Output: Sendable {
        let index: Int
        let job: ExportJob
        let effectivePreset: PresetSchema
        let effectiveParams: EffectiveDevelopParams
        let hlgOptions: HLGVideoOptions
        let startTime: ContinuousClock.Instant
        let backendUsed: RAWBackend
        let fallbackReason: String?
        let renderedFrame: RenderedFrame
    }

    private actor JobCursor {
        private let jobs: [ExportJob]
        private var nextIndex: Int = 0

        init(jobs: [ExportJob]) {
            self.jobs = jobs
        }

        func next() -> (index: Int, job: ExportJob)? {
            guard nextIndex < jobs.count else { return nil }
            let idx = nextIndex
            nextIndex += 1
            return (idx, jobs[idx])
        }
    }

    private actor ResultCollector {
        private var results: [ExportResult?]

        init(count: Int) {
            self.results = Array(repeating: nil, count: count)
        }

        func record(_ result: ExportResult, at index: Int) {
            if index >= 0 && index < results.count {
                results[index] = result
            }
        }

        func orderedResults() -> [ExportResult] {
            results.compactMap { $0 }
        }
    }

    private actor MetalRenderCoordinator {
        private let serialQueue: DispatchSerialQueue

        init() {
            self.serialQueue = DispatchSerialQueue(
                label: "io.github.zhangliangchen.chiaro.pipeline.metal-render",
                qos: .userInitiated
            )
        }

        nonisolated var unownedExecutor: UnownedSerialExecutor {
            serialQueue.asUnownedSerialExecutor()
        }

        func prepareRenderSpec(
            job: ExportJob,
            wantCustomRenderedHDR: Bool
        ) -> (effectivePreset: PresetSchema, effectiveParams: EffectiveDevelopParams, hlgOptions: HLGVideoOptions, outputSpec: RenderOutputSpec) {
            var effectivePreset = job.preset
            if wantCustomRenderedHDR {
                effectivePreset.compatOptions.writeCustomRenderedHDR = true
            }
            let effectiveParams = EffectiveDevelopParams.resolve(preset: effectivePreset, delta: job.delta)
            let activeFormats = Self.deduplicatedFormats(job.activeFormats)

            let needsStill10Bit = activeFormats.contains { $0 == .heic || $0 == .avif } && effectivePreset.bitDepth == .bit10
            let targetBitDepth: BitDepth = needsStill10Bit
                ? .bit10
                : (activeFormats == [.jpeg] ? .bit8 : effectivePreset.bitDepth)
            let gainMapChannels: GainMapChannels = (activeFormats == [.jpeg])
                ? effectivePreset.effectiveGainMapChannels(for: .jpeg)
                : effectivePreset.gainMapChannels
            let needsHLG = activeFormats.contains(.hlgMP4)
            let hlgOptions = effectivePreset.hlgVideoOptions ?? HLGVideoOptions(
                aspect: effectiveParams.cropAspect == .ratio3x4 ? .portrait3x4 : .portrait9x16,
                durationSeconds: 4.0,
                fps: 30,
                bitrateMbps: 14.0
            )

            let spec = RenderOutputSpec(
                targetBitDepth: targetBitDepth,
                baseColorSpace: effectivePreset.baseColorSpace,
                gainMapChannels: gainMapChannels,
                gainMapResolution: effectivePreset.gainMapResolution,
                gainMapGamma: effectivePreset.gainMapGamma,
                lockLegacyAppleGainMapBounds: activeFormats.contains(.heic)
                    && effectivePreset.compatOptions.writeLegacyAppleHDRGainMap
                    && gainMapChannels == .mono1ch,
                generateHLGTexture: needsHLG,
                hlgTargetDimensions: needsHLG ? hlgOptions.aspect.dimensions : nil
            )
            return (effectivePreset, effectiveParams, hlgOptions, spec)
        }

        func pruneRenderedFrame(
            _ rendered: inout RenderedFrame,
            activeFormats: [OutputFormat],
            effectivePreset: PresetSchema
        ) {
            rendered.sdrLinearTexture = nil
            let jpegNeedsHDRTex = activeFormats.contains(.jpeg) && (
                effectivePreset.compatOptions.closedLoopSDRCompensation
                    || rendered.gainMap.buffer.channels != effectivePreset.effectiveGainMapChannels(for: .jpeg)
            )
            let hlgNeedsHDRTex = activeFormats.contains(.hlgMP4) && rendered.hlgPixelBuffer == nil
            if !jpegNeedsHDRTex && !hlgNeedsHDRTex {
                rendered.hdrLinearTexture = nil
            }
        }

        private static func deduplicatedFormats(_ formats: [OutputFormat]) -> [OutputFormat] {
            var seen: Set<OutputFormat> = []
            var ordered: [OutputFormat] = []
            for fmt in formats where !seen.contains(fmt) {
                seen.insert(fmt)
                ordered.append(fmt)
            }
            return ordered
        }
    }

    internal struct PreAVIFPoolSnapshot: Sendable, Equatable {
        let sourceURL: URL
        let statsBeforeEvict: PoolStats
        let statsAfterEvict: PoolStats
    }

    internal typealias PreAVIFPoolStatsHook = @Sendable (PreAVIFPoolSnapshot) -> Void

    private let scheduler: MemoryBudgetScheduler
    private let injectedEngine: MetalPipelineEngine?
    private let preAVIFPoolStatsHook: PreAVIFPoolStatsHook?
    private let libRawDecoder: LibRawDecoder
    private let isoProbe: ISO21496Probe
    private let hlgProbe: HLGVideoProbe

    public init(
        scheduler: MemoryBudgetScheduler = MemoryBudgetScheduler(),
        metalEngine: MetalPipelineEngine? = nil
    ) {
        self.scheduler = scheduler
        self.injectedEngine = metalEngine
        self.preAVIFPoolStatsHook = nil
        self.libRawDecoder = LibRawDecoder()
        self.isoProbe = ISO21496Probe()
        self.hlgProbe = HLGVideoProbe()
    }

    internal init(
        scheduler: MemoryBudgetScheduler = MemoryBudgetScheduler(),
        metalEngine: MetalPipelineEngine? = nil,
        preAVIFPoolStatsHook: PreAVIFPoolStatsHook?
    ) {
        self.scheduler = scheduler
        self.injectedEngine = metalEngine
        self.preAVIFPoolStatsHook = preAVIFPoolStatsHook
        self.libRawDecoder = LibRawDecoder()
        self.isoProbe = ISO21496Probe()
        self.hlgProbe = HLGVideoProbe()
    }

    public func run(
        jobs: [ExportJob],
        progressHandler: (@Sendable (BatchProgressEvent) -> Void)? = nil
    ) async throws -> [ExportResult] {
        try Task.checkCancellation()
        let batchStart = ContinuousClock.now
        let firstPresetID = jobs.first?.preset.id ?? ""
        let firstFormats = jobs.first?.activeFormats ?? []
        progressHandler?(.batchStarted(totalJobs: jobs.count, presetID: firstPresetID, formats: firstFormats))

        guard !jobs.isEmpty else {
            progressHandler?(.batchCompleted(totalJobs: 0, succeeded: 0, failed: 0, elapsedSeconds: 0.0))
            return []
        }

        let budget = scheduler.budget(for: jobs)
        let engine = try injectedEngine ?? MetalPipelineEngine(poolMaxBytes: budget.metalPoolMaxBytes)
        defer {
            _ = engine.texturePool.evictIdle()
        }

        let cirawDecoder = CIRAWv9Decoder(
            libRawFallback: libRawDecoder,
            mtlDevice: engine.device
        )
        let heicEncoder = HEICImageIOEncoder()
        let jpegEncoder = JPEGDualEncoder(metalEngine: engine)
        let avifEncoder = AVIFGridEncoder(speed: 6, maxThreads: budget.avifMaxThreads)
        let hlgEncoder = HLGVideoEncoder(metalEngine: engine)

        let hasAVIF = jobs.contains { $0.activeFormats.contains(.avif) }
        let stage1To2 = BoundedAsyncChannel<Stage1Output>(capacity: budget.stage1To2Capacity)
        let stage2To3 = BoundedAsyncChannel<Stage2Output>(capacity: budget.stage2To3Capacity)
        let framePermitPool = scheduler.makeSemaphore(
            permits: hasAVIF ? 1 : budget.maxInFlightFrames
        )
        let avifEncodePermitPool = scheduler.makeSemaphore(permits: 1)
        let activeDecodeLimiter = scheduler.makeSemaphore(
            permits: hasAVIF ? 1 : budget.decodeConcurrency
        )
        let effectiveEncodeJobConcurrency = hasAVIF ? 1 : budget.encodeJobConcurrency

        let cursor = JobCursor(jobs: jobs)
        let collector = ResultCollector(count: jobs.count)
        let pathCoordinator = OutputPathCoordinator()
        let renderCoordinator = MetalRenderCoordinator()

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Stage 1: Bounded CPU Decode (2–3 workers)
                group.addTask {
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { decodeGroup in
                            for _ in 0..<budget.decodeConcurrency {
                                decodeGroup.addTask {
                                    while let (index, job) = await cursor.next() {
                                        try Task.checkCancellation()
                                        try await framePermitPool.acquire()
                                        let jobStart = ContinuousClock.now
                                        progressHandler?(.jobStarted(jobID: job.id, sourceURL: job.inputURL))

                                        let activeFormats = Self.deduplicatedFormats(job.activeFormats)
                                        let effectiveParams = EffectiveDevelopParams.resolve(preset: job.preset, delta: job.delta)
                                        if activeFormats == [.hlgMP4],
                                           let maxEdge = effectiveParams.maxLongEdge,
                                           maxEdge > 1920 {
                                            await framePermitPool.release()
                                            let err = HLGVideoEncodeError.fourKForbidden(maxEdge)
                                            let failed = ExportResult(
                                                jobID: job.id,
                                                sourceURL: job.inputURL,
                                                backendUsed: job.decodeOptions.backend,
                                                fallbackReason: nil,
                                                artifacts: [],
                                                elapsedSeconds: Self.elapsedSeconds(since: jobStart),
                                                errorDescription: "hlgMP4 encode failed: \(err)"
                                            )
                                            await collector.record(failed, at: index)
                                            progressHandler?(.jobCompleted(failed))
                                            continue
                                        }

                                        let wantCustomRendered = job.preset.compatOptions.writeCustomRenderedHDR
                                            || job.decodeOptions.customRenderedHDR
                                        var decodeOpts = job.decodeOptions
                                        decodeOpts.maxThreadsPerWorker = min(
                                            max(1, job.decodeOptions.maxThreadsPerWorker),
                                            budget.maxThreadsPerDecodeWorker
                                        )
                                        decodeOpts.customRenderedHDR = wantCustomRendered

                                        let finalDecodeOpts = decodeOpts
                                        let decodedFrame: DecodedRAWFrame
                                        do {
                                            decodedFrame = try await activeDecodeLimiter.withPermit {
                                                if finalDecodeOpts.backend == .ciraw9 {
                                                    return try await cirawDecoder.decodeFull(url: job.inputURL, options: finalDecodeOpts)
                                                } else {
                                                    return try await self.libRawDecoder.decodeFull(url: job.inputURL, options: finalDecodeOpts)
                                                }
                                            }
                                        } catch is CancellationError {
                                            await framePermitPool.release()
                                            throw CancellationError()
                                        } catch {
                                            if case RAWDecodeError.cancelled = error, Task.isCancelled {
                                                await framePermitPool.release()
                                                throw CancellationError()
                                            }
                                            await framePermitPool.release()
                                            let failed = ExportResult(
                                                jobID: job.id,
                                                sourceURL: job.inputURL,
                                                backendUsed: decodeOpts.backend,
                                                fallbackReason: nil,
                                                artifacts: [],
                                                elapsedSeconds: Self.elapsedSeconds(since: jobStart),
                                                errorDescription: String(describing: error)
                                            )
                                            await collector.record(failed, at: index)
                                            progressHandler?(.jobCompleted(failed))
                                            continue
                                        }

                                        progressHandler?(.jobDecoded(
                                            jobID: job.id,
                                            sourceURL: job.inputURL,
                                            backendUsed: decodedFrame.backendUsed,
                                            fallbackReason: decodedFrame.fallbackReason
                                        ))

                                        do {
                                            try await stage1To2.send(Stage1Output(
                                                index: index,
                                                job: job,
                                                startTime: jobStart,
                                                decodedFrame: decodedFrame,
                                                wantCustomRenderedHDR: wantCustomRendered
                                            ))
                                        } catch {
                                            await framePermitPool.release()
                                            throw error
                                        }
                                    }
                                }
                            }
                            try await decodeGroup.waitForAll()
                        }
                        await stage1To2.finish()
                    } catch {
                        await stage1To2.cancelAll()
                        throw error
                    }
                }

                // Stage 2: Serialized Metal GPU Render (gpuRenderConcurrency = 1)
                group.addTask {
                    do {
                        var lastBucketDims: (Int, Int, Int, Int)?
                        while true {
                            var stage1Opt = await stage1To2.next()
                            guard let stage1Val = stage1Opt else { break }
                            let s1Index = stage1Val.index
                            let job = stage1Val.job
                            let s1StartTime = stage1Val.startTime
                            let wantCustomRenderedHDR = stage1Val.wantCustomRenderedHDR
                            let backendUsed = stage1Val.decodedFrame.backendUsed
                            let fallbackReason = stage1Val.decodedFrame.fallbackReason
                            let (srcW, srcH) = Self.payloadDimensions(of: stage1Val.decodedFrame.payload)
                            let orientation = stage1Val.decodedFrame.orientation
                            stage1Opt = nil

                            var renderedOpt: RenderedFrame?
                            var resolvedSpec: (
                                effectivePreset: PresetSchema,
                                effectiveParams: EffectiveDevelopParams,
                                hlgOptions: HLGVideoOptions,
                                outputSpec: RenderOutputSpec
                            )?
                            do {
                                try Task.checkCancellation()
                                let specTuple = await renderCoordinator.prepareRenderSpec(
                                    job: job,
                                    wantCustomRenderedHDR: wantCustomRenderedHDR
                                )
                                resolvedSpec = specTuple

                                let geom = ColorTransforms.computeOutputGeometry(
                                    srcWidth: srcW,
                                    srcHeight: srcH,
                                    orientation: orientation,
                                    cropAspect: specTuple.effectiveParams.cropAspect,
                                    cropOffset: specTuple.effectiveParams.cropOffset,
                                    maxLongEdge: specTuple.effectiveParams.maxLongEdge,
                                    gainMapResolution: specTuple.outputSpec.gainMapResolution,
                                    gainMapChannels: specTuple.outputSpec.gainMapChannels
                                )
                                let currentDims = (srcW, srcH, geom.outWidth, geom.outHeight)
                                if let prev = lastBucketDims, prev != currentDims {
                                    _ = engine.texturePool.evictIdle()
                                }
                                lastBucketDims = currentDims

                                var rendered = try await self.renderStage1(
                                    consume stage1Val,
                                    engine: engine,
                                    effectiveParams: specTuple.effectiveParams,
                                    outputSpec: specTuple.outputSpec
                                )

                                await renderCoordinator.pruneRenderedFrame(
                                    &rendered,
                                    activeFormats: Self.deduplicatedFormats(job.activeFormats),
                                    effectivePreset: specTuple.effectivePreset
                                )
                                renderedOpt = rendered
                            } catch is CancellationError {
                                await framePermitPool.release()
                                throw CancellationError()
                            } catch {
                                await framePermitPool.release()
                                let failed = ExportResult(
                                    jobID: job.id,
                                    sourceURL: job.inputURL,
                                    backendUsed: backendUsed,
                                    fallbackReason: fallbackReason,
                                    artifacts: [],
                                    elapsedSeconds: Self.elapsedSeconds(since: s1StartTime),
                                    errorDescription: String(describing: error)
                                )
                                await collector.record(failed, at: s1Index)
                                progressHandler?(.jobCompleted(failed))
                                continue
                            }

                            guard let renderedFrame = renderedOpt,
                                  let spec = resolvedSpec else {
                                continue
                            }
                            renderedOpt = nil
                            progressHandler?(.jobRendered(jobID: job.id, sourceURL: job.inputURL))

                            do {
                                try await stage2To3.send(Stage2Output(
                                    index: s1Index,
                                    job: job,
                                    effectivePreset: spec.effectivePreset,
                                    effectiveParams: spec.effectiveParams,
                                    hlgOptions: spec.hlgOptions,
                                    startTime: s1StartTime,
                                    backendUsed: backendUsed,
                                    fallbackReason: fallbackReason,
                                    renderedFrame: renderedFrame
                                ))
                            } catch {
                                await framePermitPool.release()
                                throw error
                            }
                        }
                        await stage2To3.finish()
                    } catch {
                        await stage2To3.cancelAll()
                        throw error
                    }
                }

                // Stage 3: Bounded Encoder Fan-Out + Post-Export Verification
                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { encodeGroup in
                        for _ in 0..<effectiveEncodeJobConcurrency {
                            encodeGroup.addTask {
                                while true {
                                    var stage2Opt = await stage2To3.next()
                                    guard let stage2Val = stage2Opt else { break }
                                    let jobIndex = stage2Val.index
                                    stage2Opt = nil
                                    do {
                                        try Task.checkCancellation()
                                        let result = try await self.encodeAndVerifyJob(
                                            stage2: consume stage2Val,
                                            engine: engine,
                                            pathCoordinator: pathCoordinator,
                                            heicEncoder: heicEncoder,
                                            jpegEncoder: jpegEncoder,
                                            avifEncoder: avifEncoder,
                                            hlgEncoder: hlgEncoder,
                                            avifPermitPool: avifEncodePermitPool
                                        )
                                        await framePermitPool.release()
                                        await collector.record(result, at: jobIndex)
                                        progressHandler?(.jobCompleted(result))
                                    } catch {
                                        await framePermitPool.release()
                                        throw error
                                    }
                                }
                            }
                        }
                        try await encodeGroup.waitForAll()
                    }
                }

                try await group.waitForAll()
            }
        } onCancel: {
            Task {
                await stage1To2.cancelAll()
                await stage2To3.cancelAll()
            }
        }

        let ordered = await collector.orderedResults()
        let succeeded = ordered.filter { $0.errorDescription == nil }.count
        let failed = ordered.count - succeeded
        progressHandler?(.batchCompleted(
            totalJobs: ordered.count,
            succeeded: succeeded,
            failed: failed,
            elapsedSeconds: Self.elapsedSeconds(since: batchStart)
        ))
        return ordered
    }

    public func runWithStream(
        jobs: [ExportJob]
    ) -> (events: AsyncStream<BatchProgressEvent>, resultsTask: Task<[ExportResult], Error>) {
        var capturedContinuation: AsyncStream<BatchProgressEvent>.Continuation?
        let stream = AsyncStream<BatchProgressEvent> { continuation in
            capturedContinuation = continuation
        }
        let continuation = capturedContinuation
        let task = Task { [self] in
            defer { continuation?.finish() }
            return try await self.run(jobs: jobs) { event in
                continuation?.yield(event)
            }
        }
        return (stream, task)
    }

    private func renderStage1(
        _ stage1: consuming Stage1Output,
        engine: MetalPipelineEngine,
        effectiveParams: EffectiveDevelopParams,
        outputSpec: RenderOutputSpec
    ) async throws -> RenderedFrame {
        let frame = stage1.decodedFrame
        _ = consume stage1
        return try await engine.render(
            frame: frame,
            params: effectiveParams,
            outputSpec: outputSpec
        )
    }

    private static func payloadDimensions(of payload: RAWPixelPayload) -> (Int, Int) {
        switch payload {
        case let .rawBayer(width, height, _, _, _):
            return (width, height)
        case let .linearRGB16F(width, height, _, _):
            return (width, height)
        case let .linearRGB16U(width, height, _, _):
            return (width, height)
        }
    }

    private func encodeAndVerifyJob(
        stage2: consuming Stage2Output,
        engine: MetalPipelineEngine,
        pathCoordinator: OutputPathCoordinator,
        heicEncoder: HEICImageIOEncoder,
        jpegEncoder: JPEGDualEncoder,
        avifEncoder: AVIFGridEncoder,
        hlgEncoder: HLGVideoEncoder,
        avifPermitPool: AsyncBudgetSemaphore
    ) async throws -> ExportResult {
        let job = stage2.job
        let preset = stage2.effectivePreset
        let params = stage2.effectiveParams
        let hlgOptions = stage2.hlgOptions
        let startTime = stage2.startTime
        let backendUsed = stage2.backendUsed
        let fallbackReason = stage2.fallbackReason
        var renderedOpt: RenderedFrame? = stage2.renderedFrame
        _ = consume stage2

        let activeFormats = Self.deduplicatedFormats(job.activeFormats)

        guard !activeFormats.isEmpty else {
            renderedOpt = nil
            return ExportResult(
                jobID: job.id,
                sourceURL: job.inputURL,
                backendUsed: backendUsed,
                fallbackReason: fallbackReason,
                artifacts: [],
                elapsedSeconds: Self.elapsedSeconds(since: startTime),
                errorDescription: "No output formats specified for job."
            )
        }

        var targets: [(format: OutputFormat, url: URL)] = []
        var errors: [String] = []

        for format in activeFormats {
            do {
                switch try pathCoordinator.resolveAndReserve(job: job, format: format) {
                case .write(let destURL):
                    targets.append((format: format, url: destURL))
                case .skip:
                    break
                }
            } catch {
                errors.append("\(format.rawValue) path error: \(error)")
            }
        }

        var artifacts: [ExportArtifact] = []
        if !targets.isEmpty {
            let verifyAfterExport = job.verifyAfterExport

            let indexedTargets = Array(targets.enumerated())
            let nonAvifTargets = indexedTargets.filter { $0.element.format != .avif }
            let avifTargets = indexedTargets.filter { $0.element.format == .avif }

            var collectedIndexed: [(Int, FormatStepResult)] = []
            if !nonAvifTargets.isEmpty, let snapshotFrame = renderedOpt {
                let batch = try await withThrowingTaskGroup(of: (Int, FormatStepResult).self) { group in
                    for (orderIndex, target) in nonAvifTargets {
                        group.addTask {
                            try await self.runFormatTarget(
                                orderIndex: orderIndex,
                                format: target.format,
                                url: target.url,
                                frame: snapshotFrame,
                                preset: preset,
                                params: params,
                                hlgOptions: hlgOptions,
                                verifyAfterExport: verifyAfterExport,
                                heicEncoder: heicEncoder,
                                jpegEncoder: jpegEncoder,
                                avifEncoder: avifEncoder,
                                hlgEncoder: hlgEncoder,
                                avifPermitPool: avifPermitPool
                            )
                        }
                    }
                    var items: [(Int, FormatStepResult)] = []
                    for try await item in group {
                        items.append(item)
                    }
                    return items
                }
                collectedIndexed.append(contentsOf: batch)
            }

            if !avifTargets.isEmpty {
                // Move RenderedFrame out of renderedOpt, drop renderedOpt, and strip GPU/IOSurface
                // handles so ZERO live bindings retain SendableMTLTexture before evictIdle() & SVT-AV1.
                var avifFrame: RenderedFrame?
                if var baseFrame = renderedOpt {
                    renderedOpt = nil
                    baseFrame.sdrLinearTexture = nil
                    baseFrame.hdrLinearTexture = nil
                    baseFrame.hlgPixelBuffer = nil
                    avifFrame = baseFrame
                } else {
                    avifFrame = nil
                }

                let statsBeforeEvict = engine.texturePool.stats
                _ = engine.texturePool.evictIdle()
                let statsAfterEvict = engine.texturePool.stats
                preAVIFPoolStatsHook?(PreAVIFPoolSnapshot(
                    sourceURL: job.inputURL,
                    statsBeforeEvict: statsBeforeEvict,
                    statsAfterEvict: statsAfterEvict
                ))

                if let readyFrame = avifFrame {
                    avifFrame = nil
                    for (orderIndex, target) in avifTargets {
                        let item = try await runFormatTarget(
                            orderIndex: orderIndex,
                            format: target.format,
                            url: target.url,
                            frame: readyFrame,
                            preset: preset,
                            params: params,
                            hlgOptions: hlgOptions,
                            verifyAfterExport: verifyAfterExport,
                            heicEncoder: heicEncoder,
                            jpegEncoder: jpegEncoder,
                            avifEncoder: avifEncoder,
                            hlgEncoder: hlgEncoder,
                            avifPermitPool: avifPermitPool
                        )
                        collectedIndexed.append(item)
                    }
                }
            }
            renderedOpt = nil

            let stepResults = collectedIndexed.sorted { $0.0 < $1.0 }.map { $0.1 }

            for step in stepResults {
                switch step {
                case .artifact(let a):
                    artifacts.append(a)
                case .artifactWithFailure(let a, let msg):
                    artifacts.append(a)
                    errors.append(msg)
                case .failure(let msg):
                    errors.append(msg)
                }
            }
        } else {
            renderedOpt = nil
        }

        return ExportResult(
            jobID: job.id,
            sourceURL: job.inputURL,
            backendUsed: backendUsed,
            fallbackReason: fallbackReason,
            artifacts: artifacts,
            elapsedSeconds: Self.elapsedSeconds(since: startTime),
            errorDescription: errors.isEmpty ? nil : errors.joined(separator: " | ")
        )
    }

    private enum FormatStepResult: Sendable {
        case artifact(ExportArtifact)
        case artifactWithFailure(ExportArtifact, String)
        case failure(String)
    }

    private func runFormatTarget(
        orderIndex: Int,
        format: OutputFormat,
        url: URL,
        frame: RenderedFrame,
        preset: PresetSchema,
        params: EffectiveDevelopParams,
        hlgOptions: HLGVideoOptions,
        verifyAfterExport: Bool,
        heicEncoder: HEICImageIOEncoder,
        jpegEncoder: JPEGDualEncoder,
        avifEncoder: AVIFGridEncoder,
        hlgEncoder: HLGVideoEncoder,
        avifPermitPool: AsyncBudgetSemaphore
    ) async throws -> (Int, FormatStepResult) {
        try Task.checkCancellation()
        do {
            var artifact: ExportArtifact
            switch format {
            case .heic:
                artifact = try await heicEncoder.encode(frame: frame, preset: preset, to: url)
            case .jpeg:
                artifact = try await jpegEncoder.encode(frame: frame, preset: preset, to: url)
            case .avif:
                artifact = try await avifPermitPool.withPermit {
                    try await avifEncoder.encode(frame: frame, preset: preset, to: url)
                }
            case .hlgMP4:
                var hlgPreset = preset
                hlgPreset.maxLongEdge = params.maxLongEdge
                artifact = try await hlgEncoder.encodeVideo(
                    frame: frame,
                    preset: hlgPreset,
                    options: hlgOptions,
                    to: url
                )
            }

            if verifyAfterExport {
                let report: ComplianceReport
                if format == .hlgMP4 {
                    report = try await hlgProbe.verify(
                        url: artifact.outputURL,
                        expected: HLGComplianceExpectation(
                            expectedDimensions: hlgOptions.aspect.dimensions,
                            minDurationSeconds: 3.0,
                            maxDurationSeconds: 5.0,
                            expectedFPS: hlgOptions.fps
                        )
                    )
                } else {
                    let effectiveChannels = preset.effectiveGainMapChannels(for: format)
                    report = try await isoProbe.verify(
                        url: artifact.outputURL,
                        expected: ComplianceExpectation(
                            format: format,
                            expectedHeadroom: params.targetHeadroom.toLinear(),
                            expectedBitDepth: preset.effectiveBitDepth(for: format),
                            expectedGainMapChannels: effectiveChannels,
                            maxFileBytes: (format == .jpeg) ? preset.targetMaxFileBytes : nil,
                            expectLegacyAppleGainMap: (format == .heic)
                                && preset.compatOptions.writeLegacyAppleHDRGainMap
                                && (effectiveChannels == .mono1ch),
                            expectUltrahdrXMP: (format == .jpeg)
                                && preset.compatOptions.writeUltrahdrXMP
                                && (effectiveChannels == .mono1ch)
                        )
                    )
                }
                artifact.compliance = report
                if !report.passed {
                    let failDetails = report.checks
                        .filter { $0.severity == .fail }
                        .map { "\($0.name): \($0.message)" }
                        .joined(separator: "; ")
                    return (
                        orderIndex,
                        .artifactWithFailure(
                            artifact,
                            "\(format.rawValue) compliance failed: \(failDetails)"
                        )
                    )
                }
            }
            return (orderIndex, .artifact(artifact))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (orderIndex, .failure("\(format.rawValue) encode failed: \(error)"))
        }
    }

    private static func deduplicatedFormats(_ formats: [OutputFormat]) -> [OutputFormat] {
        var seen: Set<OutputFormat> = []
        var ordered: [OutputFormat] = []
        for fmt in formats where !seen.contains(fmt) {
            seen.insert(fmt)
            ordered.append(fmt)
        }
        return ordered
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
