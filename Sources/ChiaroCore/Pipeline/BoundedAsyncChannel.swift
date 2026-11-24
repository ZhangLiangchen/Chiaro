import Foundation

public enum BoundedAsyncChannelError: Error, Sendable, Equatable {
    case finished
}

/// True suspending bounded FIFO channel for Swift Concurrency backpressure.
/// Unlike stdlib `AsyncStream` (which drops elements or grows unboundedly),
/// `send(_:)` suspends producers once `capacity` elements are buffered and
/// supports `Task` cancellation cleanly.
public actor BoundedAsyncChannel<Element: Sendable> {
    private struct WaitingProducer {
        let id: UUID
        let element: Element
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct WaitingConsumer {
        let id: UUID
        let continuation: CheckedContinuation<Element?, Never>
    }

    public let capacity: Int
    private var buffer: [Element] = []
    private var isFinished: Bool = false
    private var producers: [WaitingProducer] = []
    private var consumers: [WaitingConsumer] = []
    private var cancelledProducerIDs: Set<UUID> = []
    private var cancelledConsumerIDs: Set<UUID> = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var bufferedCount: Int {
        buffer.count
    }

    public var waitingProducerCount: Int {
        producers.count
    }

    public func send(_ element: Element) async throws {
        try Task.checkCancellation()
        guard !isFinished else {
            throw BoundedAsyncChannelError.finished
        }

        while !consumers.isEmpty {
            let consumer = consumers.removeFirst()
            if cancelledConsumerIDs.remove(consumer.id) != nil {
                consumer.continuation.resume(returning: nil)
                continue
            }
            consumer.continuation.resume(returning: element)
            return
        }

        if buffer.count < capacity {
            buffer.append(element)
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.enqueueOrResumeProducer(id: waiterID, element: element, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelProducer(id: waiterID)
            }
        }
    }

    public func next() async -> Element? {
        if !buffer.isEmpty {
            let element = buffer.removeFirst()
            wakeNextProducerIntoBuffer()
            return element
        }

        if isFinished || Task.isCancelled {
            return nil
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                self.enqueueOrResumeConsumer(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelConsumer(id: waiterID)
            }
        }
    }

    public func finish() {
        isFinished = true
        while !consumers.isEmpty {
            let consumer = consumers.removeFirst()
            _ = cancelledConsumerIDs.remove(consumer.id)
            consumer.continuation.resume(returning: nil)
        }
    }

    public func cancelAll() {
        isFinished = true
        buffer.removeAll()
        while !producers.isEmpty {
            let producer = producers.removeFirst()
            _ = cancelledProducerIDs.remove(producer.id)
            producer.continuation.resume(throwing: CancellationError())
        }
        while !consumers.isEmpty {
            let consumer = consumers.removeFirst()
            _ = cancelledConsumerIDs.remove(consumer.id)
            consumer.continuation.resume(returning: nil)
        }
    }

    private func wakeNextProducerIntoBuffer() {
        while !producers.isEmpty && buffer.count < capacity {
            let producer = producers.removeFirst()
            if cancelledProducerIDs.remove(producer.id) != nil {
                producer.continuation.resume(throwing: CancellationError())
                continue
            }
            buffer.append(producer.element)
            producer.continuation.resume(returning: ())
            return
        }
    }

    private func enqueueOrResumeProducer(
        id: UUID,
        element: Element,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if cancelledProducerIDs.remove(id) != nil || Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard !isFinished else {
            continuation.resume(throwing: BoundedAsyncChannelError.finished)
            return
        }
        while !consumers.isEmpty {
            let consumer = consumers.removeFirst()
            if cancelledConsumerIDs.remove(consumer.id) != nil {
                consumer.continuation.resume(returning: nil)
                continue
            }
            consumer.continuation.resume(returning: element)
            continuation.resume(returning: ())
            return
        }
        if buffer.count < capacity {
            buffer.append(element)
            continuation.resume(returning: ())
            return
        }
        producers.append(WaitingProducer(id: id, element: element, continuation: continuation))
    }

    private func enqueueOrResumeConsumer(
        id: UUID,
        continuation: CheckedContinuation<Element?, Never>
    ) {
        if cancelledConsumerIDs.remove(id) != nil || Task.isCancelled {
            continuation.resume(returning: nil)
            return
        }
        if !buffer.isEmpty {
            let element = buffer.removeFirst()
            wakeNextProducerIntoBuffer()
            continuation.resume(returning: element)
            return
        }
        if isFinished {
            continuation.resume(returning: nil)
            return
        }
        consumers.append(WaitingConsumer(id: id, continuation: continuation))
    }

    private func cancelProducer(id: UUID) {
        if let idx = producers.firstIndex(where: { $0.id == id }) {
            let waiter = producers.remove(at: idx)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledProducerIDs.insert(id)
        }
    }

    private func cancelConsumer(id: UUID) {
        if let idx = consumers.firstIndex(where: { $0.id == id }) {
            let waiter = consumers.remove(at: idx)
            waiter.continuation.resume(returning: nil)
        } else {
            cancelledConsumerIDs.insert(id)
        }
    }
}
