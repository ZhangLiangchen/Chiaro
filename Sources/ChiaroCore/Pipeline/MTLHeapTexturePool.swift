import Foundation
import Metal
import os

public enum MTLHeapTexturePoolError: Error, Sendable, CustomStringConvertible {
    case invalidDimensions(width: Int, height: Int)
    case heapAllocationFailed(size: Int)
    case textureAllocationFailed(width: Int, height: Int, pixelFormat: MTLPixelFormat)
    case memoryBudgetExceeded(requestedBytes: Int, currentBytes: Int, maxBytes: Int)

    public var description: String {
        switch self {
        case let .invalidDimensions(width, height):
            return "Invalid texture dimensions: \(width)x\(height)"
        case let .heapAllocationFailed(size):
            return "Failed to allocate MTLHeap of \(size) bytes"
        case let .textureAllocationFailed(width, height, pixelFormat):
            return "Failed to allocate MTLTexture \(width)x\(height) format=\(pixelFormat.rawValue)"
        case let .memoryBudgetExceeded(requestedBytes, currentBytes, maxBytes):
            return "MTLHeapTexturePool memory budget exceeded: requested=\(requestedBytes), current=\(currentBytes), max=\(maxBytes)"
        }
    }
}

public struct PoolStats: Sendable, Equatable {
    public var activeCount: Int
    public var freeCount: Int
    public var heapCount: Int
    public var totalHeapBytes: Int
    public var allocatedCount: Int
    public var reusedCount: Int
    public var evictedHeapCount: Int

    public init(
        activeCount: Int = 0,
        freeCount: Int = 0,
        heapCount: Int = 0,
        totalHeapBytes: Int = 0,
        allocatedCount: Int = 0,
        reusedCount: Int = 0,
        evictedHeapCount: Int = 0
    ) {
        self.activeCount = activeCount
        self.freeCount = freeCount
        self.heapCount = heapCount
        self.totalHeapBytes = totalHeapBytes
        self.allocatedCount = allocatedCount
        self.reusedCount = reusedCount
        self.evictedHeapCount = evictedHeapCount
    }
}

/// Resolution- and pixel-format-bucketed `MTLHeap` (`MTLStorageModePrivate`, `MTLHeapType.placement`)
/// texture pool with Swift 6 strict-concurrency safety via `OSAllocatedUnfairLock`.
///
/// Pooled textures are returned wrapped in `SendableMTLTexture`, whose synchronous `deinit`
/// returns the underlying `MTLTexture` to the free list once all GPU command buffers holding
/// references to the `SendableMTLTexture` have completed.
public final class MTLHeapTexturePool: @unchecked Sendable {
    private struct BucketKey: Hashable, Sendable {
        let width: Int
        let height: Int
        let pixelFormatRaw: UInt
        let usageRaw: UInt

        init(width: Int, height: Int, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage) {
            self.width = width
            self.height = height
            self.pixelFormatRaw = pixelFormat.rawValue
            self.usageRaw = usage.rawValue
        }
    }

    private struct FreeEntry {
        let texture: any MTLTexture
        let heapID: UUID
    }

    private struct HeapBucket {
        let id: UUID
        let key: BucketKey
        let heap: any MTLHeap
        let size: Int
        var cursor: Int
        var activeCount: Int
        var allocatedTextures: Int
    }

    private struct PoolState: @unchecked Sendable {
        var heaps: [UUID: HeapBucket] = [:]
        var heapsByKey: [BucketKey: [UUID]] = [:]
        var freeList: [BucketKey: [FreeEntry]] = [:]
        var totalHeapBytes: Int = 0
        var activeCount: Int = 0
        var allocatedCount: Int = 0
        var reusedCount: Int = 0
        var evictedHeapCount: Int = 0
    }

    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: T
    }

    public let device: any MTLDevice
    public let maxPoolBytes: Int
    private let state: OSAllocatedUnfairLock<PoolState>

    public init(device: any MTLDevice, maxPoolBytes: Int? = nil) {
        self.device = device
        let defaultCap = max(
            64 * 1024 * 1024,
            min(
                Int(device.recommendedMaxWorkingSetSize / 2),
                Int(ProcessInfo.processInfo.physicalMemory / 3)
            )
        )
        self.maxPoolBytes = max(1024 * 1024, maxPoolBytes ?? defaultCap)
        self.state = OSAllocatedUnfairLock(initialState: PoolState())
    }

    public var stats: PoolStats {
        state.withLock { s in
            let freeCount = s.freeList.values.reduce(0) { $0 + $1.count }
            return PoolStats(
                activeCount: s.activeCount,
                freeCount: freeCount,
                heapCount: s.heaps.count,
                totalHeapBytes: s.totalHeapBytes,
                allocatedCount: s.allocatedCount,
                reusedCount: s.reusedCount,
                evictedHeapCount: s.evictedHeapCount
            )
        }
    }

    public static func maxTextureDimension(for device: any MTLDevice) -> Int {
        (device.supportsFamily(.apple3) || device.supportsFamily(.mac2)) ? 16384 : 8192
    }

    public func acquire(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .rgba16Float,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    ) throws -> SendableMTLTexture {
        let maxDim = Self.maxTextureDimension(for: device)
        guard width > 0, height > 0, width <= maxDim, height <= maxDim else {
            throw MTLHeapTexturePoolError.invalidDimensions(width: width, height: height)
        }

        let key = BucketKey(width: width, height: height, pixelFormat: pixelFormat, usage: usage)

        // Fast-path: reuse an idle texture from the free list.
        let recycled: UncheckedBox<(texture: any MTLTexture, heapID: UUID)>? = state.withLock { s in
            guard var entries = s.freeList[key], let entry = entries.popLast() else {
                return nil
            }
            if entries.isEmpty {
                s.freeList.removeValue(forKey: key)
            } else {
                s.freeList[key] = entries
            }
            if var bucket = s.heaps[entry.heapID] {
                bucket.activeCount += 1
                s.heaps[entry.heapID] = bucket
            }
            s.activeCount += 1
            s.reusedCount += 1
            return UncheckedBox(value: (entry.texture, entry.heapID))
        }

        if let recycled {
            let texBox = UncheckedBox(value: recycled.value.texture)
            let hid = recycled.value.heapID
            return SendableMTLTexture(recycled.value.texture) { [weak self] in
                self?.releaseTexture(texBox.value, key: key, heapID: hid)
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = usage

        let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: desc)
        let texSize = max(1, sizeAndAlign.size)
        let texAlign = max(1, sizeAndAlign.align)
        let slotStride = alignUp(texSize, alignment: texAlign)

        enum AllocationPlan: @unchecked Sendable {
            case recycled(texture: any MTLTexture, heapID: UUID)
            case existing(heap: any MTLHeap, heapID: UUID, offset: Int)
            case needNewHeap(slots: Int, heapSize: Int)
        }

        enum CommitAction: @unchecked Sendable {
            case committed
            case useRecycled(texture: any MTLTexture, heapID: UUID)
            case useExisting(heap: any MTLHeap, heapID: UUID, offset: Int)
            case retrySingleSlot
        }

        func placeInExistingHeap(
            _ heap: any MTLHeap,
            heapID: UUID,
            offset: Int
        ) throws -> SendableMTLTexture {
            guard let texture = heap.makeTexture(descriptor: desc, offset: offset) else {
                state.withLock { s in
                    if var bucket = s.heaps[heapID] {
                        bucket.activeCount = max(0, bucket.activeCount - 1)
                        s.heaps[heapID] = bucket
                    }
                    s.activeCount = max(0, s.activeCount - 1)
                }
                throw MTLHeapTexturePoolError.textureAllocationFailed(
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat
                )
            }
            let texBox = UncheckedBox(value: texture)
            return SendableMTLTexture(texture) { [weak self] in
                self?.releaseTexture(texBox.value, key: key, heapID: heapID)
            }
        }

        var maxSlotsCap = Int.max
        while true {
            let slotsCap = maxSlotsCap
            let plan: AllocationPlan = try state.withLock { s in
                if var entries = s.freeList[key], let entry = entries.popLast() {
                    if entries.isEmpty {
                        s.freeList.removeValue(forKey: key)
                    } else {
                        s.freeList[key] = entries
                    }
                    if var bucket = s.heaps[entry.heapID] {
                        bucket.activeCount += 1
                        s.heaps[entry.heapID] = bucket
                    }
                    s.activeCount += 1
                    s.reusedCount += 1
                    return .recycled(texture: entry.texture, heapID: entry.heapID)
                }

                if let bucketIDs = s.heapsByKey[key] {
                    for hid in bucketIDs {
                        if var bucket = s.heaps[hid] {
                            let alignedOffset = alignUp(bucket.cursor, alignment: texAlign)
                            if alignedOffset + texSize <= bucket.size {
                                bucket.cursor = alignedOffset + texSize
                                bucket.activeCount += 1
                                bucket.allocatedTextures += 1
                                s.heaps[hid] = bucket
                                s.activeCount += 1
                                s.allocatedCount += 1
                                return .existing(heap: bucket.heap, heapID: hid, offset: alignedOffset)
                            }
                        }
                    }
                }

                let preferredSlots = texSize >= 48 * 1024 * 1024 ? 1 : (texSize >= 16 * 1024 * 1024 ? 2 : 4)
                let maxAffordableSlots = max(1, maxPoolBytes / max(1, slotStride))
                var slots = min(preferredSlots, min(maxAffordableSlots, slotsCap))
                var requestedHeapSize = slotStride * slots

                if s.totalHeapBytes + requestedHeapSize > maxPoolBytes {
                    evictIdleHeapsLocked(&s, targetFreeBytes: (s.totalHeapBytes + requestedHeapSize) - maxPoolBytes)
                }
                if s.totalHeapBytes + requestedHeapSize > maxPoolBytes, slots > 1 {
                    slots = 1
                    requestedHeapSize = slotStride
                    if s.totalHeapBytes + requestedHeapSize > maxPoolBytes {
                        evictIdleHeapsLocked(&s, targetFreeBytes: (s.totalHeapBytes + requestedHeapSize) - maxPoolBytes)
                    }
                }

                if s.totalHeapBytes + requestedHeapSize > maxPoolBytes {
                    throw MTLHeapTexturePoolError.memoryBudgetExceeded(
                        requestedBytes: requestedHeapSize,
                        currentBytes: s.totalHeapBytes,
                        maxBytes: maxPoolBytes
                    )
                }

                return .needNewHeap(slots: slots, heapSize: requestedHeapSize)
            }

            switch plan {
            case let .recycled(recycledTex, hid):
                let texBox = UncheckedBox(value: recycledTex)
                return SendableMTLTexture(recycledTex) { [weak self] in
                    self?.releaseTexture(texBox.value, key: key, heapID: hid)
                }

            case let .existing(heap, heapID, offset):
                return try placeInExistingHeap(heap, heapID: heapID, offset: offset)

            case let .needNewHeap(slots, heapSize):
                let heapDesc = MTLHeapDescriptor()
                heapDesc.type = .placement
                heapDesc.storageMode = .private
                heapDesc.hazardTrackingMode = .tracked
                heapDesc.size = heapSize

                guard let heap = device.makeHeap(descriptor: heapDesc) else {
                    throw MTLHeapTexturePoolError.heapAllocationFailed(size: heapSize)
                }
                guard let texture = heap.makeTexture(descriptor: desc, offset: 0) else {
                    throw MTLHeapTexturePoolError.textureAllocationFailed(
                        width: width,
                        height: height,
                        pixelFormat: pixelFormat
                    )
                }

                let heapID = UUID()
                let heapBox = UncheckedBox(value: heap)
                let texBox = UncheckedBox(value: texture)
                let commitAction: CommitAction = try state.withLock { s in
                    // Re-check freeList and existing buckets inside lock to avoid cold-bucket race
                    if var entries = s.freeList[key], let entry = entries.popLast() {
                        if entries.isEmpty {
                            s.freeList.removeValue(forKey: key)
                        } else {
                            s.freeList[key] = entries
                        }
                        if var bucket = s.heaps[entry.heapID] {
                            bucket.activeCount += 1
                            s.heaps[entry.heapID] = bucket
                        }
                        s.activeCount += 1
                        s.reusedCount += 1
                        texBox.value.makeAliasable()
                        return .useRecycled(texture: entry.texture, heapID: entry.heapID)
                    }

                    if let bucketIDs = s.heapsByKey[key] {
                        for hid in bucketIDs {
                            if var bucket = s.heaps[hid] {
                                let alignedOffset = alignUp(bucket.cursor, alignment: texAlign)
                                if alignedOffset + texSize <= bucket.size {
                                    bucket.cursor = alignedOffset + texSize
                                    bucket.activeCount += 1
                                    bucket.allocatedTextures += 1
                                    s.heaps[hid] = bucket
                                    s.activeCount += 1
                                    s.allocatedCount += 1
                                    texBox.value.makeAliasable()
                                    return .useExisting(heap: bucket.heap, heapID: hid, offset: alignedOffset)
                                }
                            }
                        }
                    }

                    if s.totalHeapBytes + heapSize > maxPoolBytes {
                        evictIdleHeapsLocked(&s, targetFreeBytes: (s.totalHeapBytes + heapSize) - maxPoolBytes)
                    }
                    if s.totalHeapBytes + heapSize > maxPoolBytes {
                        texBox.value.makeAliasable()
                        if slots > 1 {
                            return .retrySingleSlot
                        }
                        throw MTLHeapTexturePoolError.memoryBudgetExceeded(
                            requestedBytes: heapSize,
                            currentBytes: s.totalHeapBytes,
                            maxBytes: maxPoolBytes
                        )
                    }

                    let bucket = HeapBucket(
                        id: heapID,
                        key: key,
                        heap: heapBox.value,
                        size: heapSize,
                        cursor: texSize,
                        activeCount: 1,
                        allocatedTextures: 1
                    )
                    s.heaps[heapID] = bucket
                    s.heapsByKey[key, default: []].append(heapID)
                    s.totalHeapBytes += heapSize
                    s.activeCount += 1
                    s.allocatedCount += 1
                    return .committed
                }

                switch commitAction {
                case .committed:
                    return SendableMTLTexture(texture) { [weak self] in
                        self?.releaseTexture(texBox.value, key: key, heapID: heapID)
                    }
                case let .useRecycled(rTex, rHID):
                    let rBox = UncheckedBox(value: rTex)
                    return SendableMTLTexture(rTex) { [weak self] in
                        self?.releaseTexture(rBox.value, key: key, heapID: rHID)
                    }
                case let .useExisting(eHeap, eHID, eOffset):
                    return try placeInExistingHeap(eHeap, heapID: eHID, offset: eOffset)
                case .retrySingleSlot:
                    maxSlotsCap = 1
                    continue
                }
            }
        }
    }

    /// Evicts all idle heaps (buckets with `activeCount == 0`) and marks their textures aliasable.
    @discardableResult
    public func evictIdle() -> Int {
        state.withLock { s in
            evictIdleHeapsLocked(&s, targetFreeBytes: Int.max)
        }
    }

    private func releaseTexture(_ texture: any MTLTexture, key: BucketKey, heapID: UUID) {
        let texBox = UncheckedBox(value: texture)
        state.withLock { s in
            s.activeCount = max(0, s.activeCount - 1)
            guard var bucket = s.heaps[heapID] else {
                texBox.value.makeAliasable()
                return
            }
            bucket.activeCount = max(0, bucket.activeCount - 1)
            s.heaps[heapID] = bucket
            s.freeList[key, default: []].append(FreeEntry(texture: texBox.value, heapID: heapID))
        }
    }

    @discardableResult
    private func evictIdleHeapsLocked(_ s: inout PoolState, targetFreeBytes: Int) -> Int {
        var freedBytes = 0
        let idleBucketIDs = s.heaps.values
            .filter { $0.activeCount == 0 }
            .sorted { $0.size > $1.size }
            .map(\.id)

        for hid in idleBucketIDs {
            if freedBytes >= targetFreeBytes { break }
            guard let bucket = s.heaps.removeValue(forKey: hid) else { continue }
            s.totalHeapBytes = max(0, s.totalHeapBytes - bucket.size)
            s.evictedHeapCount += 1
            freedBytes += bucket.size

            if var list = s.heapsByKey[bucket.key] {
                list.removeAll { $0 == hid }
                if list.isEmpty {
                    s.heapsByKey.removeValue(forKey: bucket.key)
                } else {
                    s.heapsByKey[bucket.key] = list
                }
            }

            if let freeEntries = s.freeList[bucket.key] {
                var remaining: [FreeEntry] = []
                remaining.reserveCapacity(freeEntries.count)
                for entry in freeEntries {
                    if entry.heapID == hid {
                        entry.texture.makeAliasable()
                    } else {
                        remaining.append(entry)
                    }
                }
                if remaining.isEmpty {
                    s.freeList.removeValue(forKey: bucket.key)
                } else {
                    s.freeList[bucket.key] = remaining
                }
            }
        }
        return freedBytes
    }

    private func alignUp(_ value: Int, alignment: Int) -> Int {
        let mask = alignment - 1
        if alignment & mask == 0 {
            return (value + mask) & ~mask
        }
        return ((value + alignment - 1) / alignment) * alignment
    }
}
