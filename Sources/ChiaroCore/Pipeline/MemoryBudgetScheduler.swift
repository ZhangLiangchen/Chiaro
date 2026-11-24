import Foundation

public enum MemoryTier: String, Sendable, Codable, Equatable, Hashable {
    case standard16GB
    case high32GBPlus
}

public struct PipelineBudget: Sendable, Equatable {
    public let tier: MemoryTier
    public let physicalMemoryBytes: UInt64
    public let estimatedMegapixels: Double
    public let decodeConcurrency: Int
    public let gpuRenderConcurrency: Int
    public let encodeJobConcurrency: Int
    public let stage1To2Capacity: Int
    public let stage2To3Capacity: Int
    public let maxInFlightFrames: Int
    public let maxThreadsPerDecodeWorker: Int
    public let avifMaxThreads: Int
    public let metalPoolMaxBytes: Int

    public init(
        tier: MemoryTier,
        physicalMemoryBytes: UInt64,
        estimatedMegapixels: Double,
        decodeConcurrency: Int,
        gpuRenderConcurrency: Int,
        encodeJobConcurrency: Int,
        stage1To2Capacity: Int,
        stage2To3Capacity: Int,
        maxInFlightFrames: Int,
        maxThreadsPerDecodeWorker: Int,
        avifMaxThreads: Int,
        metalPoolMaxBytes: Int
    ) {
        self.tier = tier
        self.physicalMemoryBytes = physicalMemoryBytes
        self.estimatedMegapixels = estimatedMegapixels
        self.decodeConcurrency = max(1, decodeConcurrency)
        self.gpuRenderConcurrency = max(1, gpuRenderConcurrency)
        self.encodeJobConcurrency = max(1, encodeJobConcurrency)
        self.stage1To2Capacity = max(1, stage1To2Capacity)
        self.stage2To3Capacity = max(1, stage2To3Capacity)
        self.maxInFlightFrames = max(1, maxInFlightFrames)
        self.maxThreadsPerDecodeWorker = max(1, maxThreadsPerDecodeWorker)
        self.avifMaxThreads = max(1, avifMaxThreads)
        self.metalPoolMaxBytes = max(64 * 1024 * 1024, metalPoolMaxBytes)
    }
}

public actor AsyncBudgetSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    public let maxPermits: Int
    private var available: Int
    private var waiters: [Waiter] = []
    private var cancelledIDs: Set<UUID> = []

    public init(permits: Int) {
        let safePermits = max(1, permits)
        self.maxPermits = safePermits
        self.available = safePermits
    }

    public var availablePermits: Int {
        available
    }

    public var waitingCount: Int {
        waiters.count
    }

    public func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.enqueueOrResume(waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    public func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if cancelledIDs.remove(next.id) != nil {
                next.continuation.resume(throwing: CancellationError())
                continue
            }
            next.continuation.resume(returning: ())
            return
        }
        available = min(maxPermits, available + 1)
    }

    public func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func enqueueOrResume(
        waiterID: UUID,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if cancelledIDs.remove(waiterID) != nil || Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if available > 0 {
            available -= 1
            continuation.resume(returning: ())
            return
        }
        waiters.append(Waiter(id: waiterID, continuation: continuation))
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledIDs.insert(id)
        }
    }
}

public final class MemoryBudgetScheduler: Sendable {
    public static let lowTierCeilingBytes: UInt64 = 20 * 1024 * 1024 * 1024

    public let physicalMemoryBytes: UInt64
    private let defaultSemaphore: AsyncBudgetSemaphore

    public init(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        permitCount: Int? = nil
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        let defaultPermits: Int
        if let permitCount {
            defaultPermits = max(1, permitCount)
        } else {
            defaultPermits = (physicalMemoryBytes <= Self.lowTierCeilingBytes) ? 2 : 4
        }
        self.defaultSemaphore = AsyncBudgetSemaphore(permits: defaultPermits)
    }

    public func budget(
        estimatedMegapixels: Double = 33.0,
        backend: RAWBackend = .libraw,
        outputFormats: [OutputFormat] = [.heic]
    ) -> PipelineBudget {
        let clampedMP = estimatedMegapixels.isFinite ? max(1.0, estimatedMegapixels) : 33.0
        let isLargeFrame = clampedMP >= 45.0
        let isLowTier = physicalMemoryBytes <= Self.lowTierCeilingBytes

        if isLowTier {
            let decodeConcurrency = (isLargeFrame || backend == .ciraw9) ? 1 : 2
            let minPoolBytes: UInt64 = 1_536 * 1024 * 1024
            let maxPoolBytes: UInt64 = 4_096 * 1024 * 1024
            let quarterRAM = physicalMemoryBytes / 4
            let poolBytes = Int(min(max(minPoolBytes, quarterRAM), maxPoolBytes))

            return PipelineBudget(
                tier: .standard16GB,
                physicalMemoryBytes: physicalMemoryBytes,
                estimatedMegapixels: clampedMP,
                decodeConcurrency: decodeConcurrency,
                gpuRenderConcurrency: 1,
                encodeJobConcurrency: 1,
                stage1To2Capacity: 1,
                stage2To3Capacity: 1,
                maxInFlightFrames: isLargeFrame ? 2 : 3,
                maxThreadsPerDecodeWorker: 2,
                avifMaxThreads: 4,
                metalPoolMaxBytes: poolBytes
            )
        } else {
            let decodeConcurrency = (isLargeFrame || backend == .ciraw9) ? 2 : 3
            let encodeJobConcurrency = (isLargeFrame && outputFormats.contains(.avif)) ? 1 : 2
            let minPoolBytes: UInt64 = 2_560 * 1024 * 1024
            let maxPoolBytes: UInt64 = 4_096 * 1024 * 1024
            let eighthRAM = physicalMemoryBytes / 8
            let poolBytes = Int(min(max(minPoolBytes, eighthRAM), maxPoolBytes))
            let avifThreads = 4
            let maxInFlight = (isLargeFrame || outputFormats.contains(.avif)) ? 3 : 4

            return PipelineBudget(
                tier: .high32GBPlus,
                physicalMemoryBytes: physicalMemoryBytes,
                estimatedMegapixels: clampedMP,
                decodeConcurrency: decodeConcurrency,
                gpuRenderConcurrency: 1,
                encodeJobConcurrency: encodeJobConcurrency,
                stage1To2Capacity: 2,
                stage2To3Capacity: 2,
                maxInFlightFrames: maxInFlight,
                maxThreadsPerDecodeWorker: 2,
                avifMaxThreads: avifThreads,
                metalPoolMaxBytes: poolBytes
            )
        }
    }

    public func budget(for jobs: [ExportJob]) -> PipelineBudget {
        guard !jobs.isEmpty else {
            return budget(estimatedMegapixels: 33.0, backend: .libraw, outputFormats: [.heic])
        }

        let estimatedMP = jobs.map(Self.estimateMegapixels(for:)).max() ?? 33.0
        let usesCIRAW = jobs.contains { $0.decodeOptions.backend == .ciraw9 }
        let backend: RAWBackend = usesCIRAW ? .ciraw9 : .libraw
        let allFormats = Array(Set(jobs.flatMap { $0.activeFormats }))

        return budget(
            estimatedMegapixels: estimatedMP,
            backend: backend,
            outputFormats: allFormats.isEmpty ? [.heic] : allFormats
        )
    }

    public func makeSemaphore(permits: Int) -> AsyncBudgetSemaphore {
        AsyncBudgetSemaphore(permits: permits)
    }

    public func acquire() async throws {
        try await defaultSemaphore.acquire()
    }

    public func release() async {
        await defaultSemaphore.release()
    }

    public func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await defaultSemaphore.withPermit(operation)
    }

    private static func estimateMegapixels(for job: ExportJob) -> Double {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: job.inputURL.path),
           let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value {
            if sizeBytes >= 65_000_000 {
                return 61.0
            } else if sizeBytes >= 25_000_000 {
                return 33.0
            } else if sizeBytes >= 8_000_000 {
                return 14.0
            }
        }
        return 33.0
    }
}
