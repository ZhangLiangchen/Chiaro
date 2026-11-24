import Foundation
import Metal
import simd

public enum EDRPreviewMode: UInt32, Sendable, CaseIterable, Codable, Hashable {
    case standardEDR = 0
    case splitScreenSwipe = 1
    case falseColorHeatmap = 2
    case gainMapDirectView = 3
}

/// Shared Swift/Metal uniform layout for 120Hz EDR Preview (`edr_preview_vertex`, `edr_preview_fragment`,
/// `edr_preview_compute`) and `dual_zone_histogram_kernel`.
/// Uses only 4-byte scalars and `SIMD4<Float>` to guarantee identical alignment across Swift and MSL.
public struct EDRPreviewUniforms: Sendable, Equatable {
    public var mode: UInt32
    public var sdrExposureScaleEnabled: UInt32
    public var isMonoGainMap: UInt32
    public var isSRGBBase: UInt32

    public var displayLinearHeadroom: Float
    public var baseHeadroomStops: Float
    public var altHeadroomStops: Float
    public var splitPosition: Float

    public var dividerWidthUV: Float
    public var clipThreshold: Float
    public var kOffset: Float
    public var pad0: Float

    public var gainMapMin: SIMD4<Float>
    public var gainMapMax: SIMD4<Float>
    public var gamma: SIMD4<Float>

    public init(
        mode: EDRPreviewMode = .standardEDR,
        sdrExposureScaleEnabled: Bool = false,
        metadata: GainMapMetadata,
        isMonoGainMap: Bool,
        isSRGBBase: Bool = false,
        displayHeadroom: LinearHeadroom,
        splitPosition: Float = 0.5,
        dividerWidthUV: Float = 0.0025
    ) {
        self.mode = mode.rawValue
        self.sdrExposureScaleEnabled = sdrExposureScaleEnabled ? 1 : 0
        self.isMonoGainMap = isMonoGainMap ? 1 : 0
        self.isSRGBBase = isSRGBBase ? 1 : 0

        let linHeadroom = max(Float(displayHeadroom.multiplier), 1.0)
        self.displayLinearHeadroom = linHeadroom
        self.baseHeadroomStops = Float(metadata.baseHeadroom.log2Value)
        self.altHeadroomStops = Float(metadata.alternateHeadroom.log2Value)
        self.splitPosition = min(max(splitPosition, 0.0), 1.0)
        self.dividerWidthUV = max(dividerWidthUV, 0.0)
        self.clipThreshold = linHeadroom * 0.995
        self.kOffset = Float(metadata.baseOffset.first ?? GainMapMetadata.symmetricOffset)
        self.pad0 = 0.0

        func vec3To4(_ arr: [Double], defaultVal: Double) -> SIMD4<Float> {
            let v0 = Float(arr.first ?? defaultVal)
            let v1 = Float(arr.count > 1 ? arr[1] : (arr.first ?? defaultVal))
            let v2 = Float(arr.count > 2 ? arr[2] : (arr.first ?? defaultVal))
            return SIMD4<Float>(v0, v1, v2, 0.0)
        }

        self.gainMapMin = vec3To4(metadata.gainMapMin, defaultVal: 0.0)
        self.gainMapMax = vec3To4(metadata.gainMapMax, defaultVal: 0.0)
        self.gamma = vec3To4(metadata.gamma, defaultVal: 1.0)
    }
}

public enum EDRPreviewError: Error, Sendable, CustomStringConvertible {
    case commandBufferCreationFailed
    case commandEncodingFailed
    case gpuExecutionFailed(String)
    case bufferAllocationFailed

    public var description: String {
        switch self {
        case .commandBufferCreationFailed: return "Failed to create MTLCommandBuffer for EDR preview"
        case .commandEncodingFailed: return "Failed to create MTLComputeCommandEncoder for EDR preview"
        case let .gpuExecutionFailed(msg): return "EDR preview GPU execution failed: \(msg)"
        case .bufferAllocationFailed: return "Failed to allocate Metal buffer for dual-zone histogram"
        }
    }
}

/// Headless GPU EDR Preview evaluator and 256-bin Dual-Zone Histogram engine.
/// Shares identical MSL evaluation math (`evaluate_edr_preview`) with `edr_preview_fragment`
/// used by `Chiaro.app` (M6).
public final class EDRPreviewPipeline: @unchecked Sendable {
    public let device: any MTLDevice
    public let shaderLibrary: MetalShaderLibrary

    public init(device: any MTLDevice, shaderLibrary: MetalShaderLibrary) {
        self.device = device
        self.shaderLibrary = shaderLibrary
    }

    public func evaluateCompute(
        commandQueue: any MTLCommandQueue,
        sdrLinearTexture: SendableMTLTexture,
        gainMapTexture: SendableMTLTexture,
        outputTexture: SendableMTLTexture,
        uniforms: EDRPreviewUniforms
    ) throws {
        try autoreleasepool {
            let pso = try shaderLibrary.computePipelineState(for: "edr_preview_compute")
            guard let cb = commandQueue.makeCommandBuffer() else {
                throw EDRPreviewError.commandBufferCreationFailed
            }
            guard let enc = cb.makeComputeCommandEncoder() else {
                throw EDRPreviewError.commandEncodingFailed
            }

            var u = uniforms
            enc.setComputePipelineState(pso)
            enc.setTexture(sdrLinearTexture.texture, index: 0)
            enc.setTexture(gainMapTexture.texture, index: 1)
            enc.setTexture(outputTexture.texture, index: 2)
            enc.setBytes(&u, length: MemoryLayout<EDRPreviewUniforms>.stride, index: 0)

            let w = outputTexture.texture.width
            let h = outputTexture.texture.height
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()

            let retained = [sdrLinearTexture, gainMapTexture, outputTexture]
            cb.addCompletedHandler { _ in _ = retained }
            cb.commit()
            cb.waitUntilCompleted()

            if let err = cb.error {
                throw EDRPreviewError.gpuExecutionFailed(String(describing: err))
            }
        }
    }

    /// Computes a 256-bin dual-zone luminance histogram:
    /// - Bins `0...127`: SDR zone `[-6 EV, 0 EV]` (`Y <= 1.0`)
    /// - Bins `128...255`: HDR zone `(0 EV, +4 EV]` (`Y > 1.0`)
    /// Exact `0 EV` diffuse white boundary sits at bin index `128`.
    public func computeDualZoneHistogram(
        commandQueue: any MTLCommandQueue,
        sdrLinearTexture: SendableMTLTexture,
        gainMapTexture: SendableMTLTexture,
        uniforms: EDRPreviewUniforms
    ) throws -> [UInt32] {
        try autoreleasepool {
            let pso = try shaderLibrary.computePipelineState(for: "dual_zone_histogram_kernel")
            let binByteSize = 256 * MemoryLayout<UInt32>.stride
            guard let histBuf = device.makeBuffer(length: binByteSize, options: .storageModeShared) else {
                throw EDRPreviewError.bufferAllocationFailed
            }
            memset(histBuf.contents(), 0, binByteSize)

            guard let cb = commandQueue.makeCommandBuffer() else {
                throw EDRPreviewError.commandBufferCreationFailed
            }
            guard let enc = cb.makeComputeCommandEncoder() else {
                throw EDRPreviewError.commandEncodingFailed
            }

            var u = uniforms
            enc.setComputePipelineState(pso)
            enc.setTexture(sdrLinearTexture.texture, index: 0)
            enc.setTexture(gainMapTexture.texture, index: 1)
            enc.setBuffer(histBuf, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<EDRPreviewUniforms>.stride, index: 1)

            let w = sdrLinearTexture.texture.width
            let h = sdrLinearTexture.texture.height
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()

            let retained = [sdrLinearTexture, gainMapTexture]
            cb.addCompletedHandler { _ in _ = retained }
            cb.commit()
            cb.waitUntilCompleted()

            if let err = cb.error {
                throw EDRPreviewError.gpuExecutionFailed(String(describing: err))
            }

            let ptr = histBuf.contents().bindMemory(to: UInt32.self, capacity: 256)
            return Array(UnsafeBufferPointer(start: ptr, count: 256))
        }
    }
}
