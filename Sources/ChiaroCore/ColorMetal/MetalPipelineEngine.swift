import CoreGraphics
import CoreVideo
import Foundation
import Metal
import os
import simd

public struct RAWLevelCalibration: Sendable, Codable, Equatable, Hashable {
    public var blackLevel: [UInt32]
    public var whiteLevel: UInt32
    public var preMul: [Double]
    public var rgbCam: [Double]

    public init(
        blackLevel: [UInt32] = [0, 0, 0, 0],
        whiteLevel: UInt32 = 16383,
        preMul: [Double] = [1, 1, 1, 1],
        rgbCam: [Double] = []
    ) {
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.preMul = preMul
        self.rgbCam = rgbCam
    }

    public static func defaultFor(bitsPerSample: Int) -> RAWLevelCalibration {
        let clampedBits = max(1, min(bitsPerSample, 16))
        let maxVal = UInt32((1 << clampedBits) - 1)
        return RAWLevelCalibration(blackLevel: [0, 0, 0, 0], whiteLevel: maxVal)
    }
}

public enum MetalPipelineError: Error, Sendable, CustomStringConvertible {
    case metalUnavailable
    case commandQueueCreationFailed
    case invalidDimensions(width: Int, height: Int)
    case invalidPayloadDataSize(expectedAtLeast: Int, actual: Int)
    case commandBufferCreationFailed
    case commandEncodingFailed
    case bufferAllocationFailed
    case cgImageCreationFailed
    case hlgPixelBufferCreationFailed(CVReturn)
    case hlgMetalTextureBindFailed(CVReturn)
    case gpuExecutionFailed(String)

    public var description: String {
        switch self {
        case .metalUnavailable:
            return "Metal GPU device is unavailable"
        case .commandQueueCreationFailed:
            return "Failed to create MTLCommandQueue"
        case let .invalidDimensions(width, height):
            return "Invalid RAW pixel dimensions: \(width)x\(height)"
        case let .invalidPayloadDataSize(expected, actual):
            return "RAW pixel payload too small: expected >= \(expected) bytes, got \(actual)"
        case .commandBufferCreationFailed:
            return "Failed to create MTLCommandBuffer"
        case .commandEncodingFailed:
            return "Failed to create MTLComputeCommandEncoder"
        case .bufferAllocationFailed:
            return "Failed to allocate Metal buffer"
        case .cgImageCreationFailed:
            return "Failed to create sdrCGImage from quantized output buffer"
        case let .hlgPixelBufferCreationFailed(status):
            return "CVPixelBufferCreate for HLG 'x420' failed with status \(status)"
        case let .hlgMetalTextureBindFailed(status):
            return "CVMetalTextureCacheCreateTextureFromImage failed with status \(status)"
        case let .gpuExecutionFailed(msg):
            return "Metal pipeline execution failed: \(msg)"
        }
    }
}

private struct DemosaicUniforms {
    var width: UInt32
    var height: UInt32
    var cfaPattern: UInt32
    var whiteLevel: Float
    var blackLevel: SIMD4<Float>
    var wbGain: SIMD4<Float>
    var clipThreshold: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

private struct HighlightReconUniforms {
    var width: UInt32
    var height: UInt32
    var minClipCeil: Float
    var maxClipCeil: Float
}

private struct UnpackRGBUniforms {
    var width: UInt32
    var height: UInt32
    var channelCount: UInt32
    var scaleFactor: Float
    var preCompClipThreshold: SIMD4<Float>
    var preMatCol0: SIMD4<Float>
    var preMatCol1: SIMD4<Float>
    var preMatCol2: SIMD4<Float>
    var usePreMat: UInt32
    var clipThreshScale: Float = 0.985
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

private struct CameraColorLUTUniforms {
    var camToRec2020Col0: SIMD4<Float>
    var camToRec2020Col1: SIMD4<Float>
    var camToRec2020Col2: SIMD4<Float>
    var lutDomainMin: SIMD4<Float>
    var lutDomainMax: SIMD4<Float>
    var hasHueSatTable: UInt32
    var hasLookTable: UInt32
    var lutMode: UInt32
    var lutSize: UInt32
}

private struct SceneGradingUniforms {
    var wbCol0: SIMD4<Float>
    var wbCol1: SIMD4<Float>
    var wbCol2: SIMD4<Float>
    var exposureLinear: Float
    var blackPoint: Float
    var shadowRecovery: Float
    var vibrance: Float
}

private struct OrientCropResizeUniforms {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var cropX: UInt32
    var cropY: UInt32
    var cropWidth: UInt32
    var cropHeight: UInt32
    var outWidth: UInt32
    var outHeight: UInt32
    var orientation: UInt32
    var isOneToOne: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

private struct ToneMapGamutUniforms {
    var midtoneAnchorP: Float
    var targetHeadroomStops: Float
    var sdrToneMapper: UInt32
    var isSRGBBase: UInt32
    var sdrExposureLinear: Float
    var sdrHighlightCompression: Float
    var sdrContrast: Float
    var sdrSaturation: Float
    var hdrHighlightExcitation: Float
    var hdrRolloffSoftness: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

private struct QuantizeOutputUniforms {
    var width: UInt32
    var height: UInt32
    var is16Bit: UInt32
    var pad0: UInt32 = 0
}

private struct HLGConvertUniforms {
    var isSRGBBase: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

private struct ClarityUniforms {
    var width: UInt32
    var height: UInt32
    var stride: UInt32
    var clarity: Float
}

private struct OpticalSharpnessUniforms {
    var width: UInt32
    var height: UInt32
    var dt: Float
    var pad0: Float = 0
}

public final class MetalPipelineEngine: MetalPipelineProtocol, @unchecked Sendable {
    private struct CVCacheBox: @unchecked Sendable {
        var cache: CVMetalTextureCache?
    }

    private struct HLGPlaneTextures: @unchecked Sendable {
        let yCV: CVMetalTexture
        let uvCV: CVMetalTexture
        let yMetal: any MTLTexture
        let uvMetal: any MTLTexture
    }

    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let shaderLibrary: MetalShaderLibrary
    public let texturePool: MTLHeapTexturePool
    public let gainMapSynthesizer: GainMapSynthesizer
    public let edrPreviewPipeline: EDRPreviewPipeline
    public let denoiseStage: any LinearDenoiseStage
    public let opticsStage: any OpticalCorrectionStage
    public let colorGradingStage: any ColorGradingStage

    private let dummyTex2D: any MTLTexture
    private let dummyTex3D: any MTLTexture
    private let cvCacheLock: OSAllocatedUnfairLock<CVCacheBox>

    public init(
        device: (any MTLDevice)? = nil,
        poolMaxBytes: Int? = nil,
        denoiseStage: (any LinearDenoiseStage)? = nil,
        opticsStage: (any OpticalCorrectionStage)? = nil,
        colorGradingStage: (any ColorGradingStage)? = nil
    ) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalPipelineError.metalUnavailable
        }
        guard let queue = dev.makeCommandQueue() else {
            throw MetalPipelineError.commandQueueCreationFailed
        }

        self.device = dev
        self.commandQueue = queue
        self.shaderLibrary = try MetalShaderLibrary(device: dev, prewarmAllKernels: true)
        self.texturePool = MTLHeapTexturePool(device: dev, maxPoolBytes: poolMaxBytes)
        self.gainMapSynthesizer = try GainMapSynthesizer(
            device: dev,
            shaderLibrary: self.shaderLibrary,
            pool: self.texturePool
        )
        self.edrPreviewPipeline = EDRPreviewPipeline(device: dev, shaderLibrary: self.shaderLibrary)
        self.denoiseStage = try denoiseStage ?? ProfiledWaveletDenoiseStage(
            device: dev,
            shaderLibrary: self.shaderLibrary,
            texturePool: self.texturePool
        )
        self.opticsStage = try opticsStage ?? OpticsPipelineEngine(
            device: dev,
            shaderLibrary: self.shaderLibrary
        )
        self.colorGradingStage = colorGradingStage ?? PassThroughColorGradingStage()

        let d2Desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        d2Desc.usage = .shaderRead
        d2Desc.storageMode = .shared
        guard let d2 = dev.makeTexture(descriptor: d2Desc) else {
            throw MetalPipelineError.bufferAllocationFailed
        }
        var zero4: [Float] = [0, 0, 0, 1]
        d2.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero4, bytesPerRow: 16)
        self.dummyTex2D = d2

        let d3Desc = MTLTextureDescriptor()
        d3Desc.textureType = .type3D
        d3Desc.pixelFormat = .rgba32Float
        d3Desc.width = 1
        d3Desc.height = 1
        d3Desc.depth = 1
        d3Desc.usage = .shaderRead
        d3Desc.storageMode = .shared
        guard let d3 = dev.makeTexture(descriptor: d3Desc) else {
            throw MetalPipelineError.bufferAllocationFailed
        }
        d3.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &zero4, bytesPerRow: 16, bytesPerImage: 16)
        self.dummyTex3D = d3

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        self.cvCacheLock = OSAllocatedUnfairLock(initialState: CVCacheBox(cache: cache))
    }

    public func render(
        frame: DecodedRAWFrame,
        params: EffectiveDevelopParams,
        outputSpec: RenderOutputSpec
    ) async throws -> RenderedFrame {
        try await render(frame: frame, params: params, outputSpec: outputSpec, rawCalibration: nil)
    }

    public func render(
        frame: DecodedRAWFrame,
        params: EffectiveDevelopParams,
        outputSpec: RenderOutputSpec,
        rawCalibration: RAWLevelCalibration?
    ) async throws -> RenderedFrame {
        var workingFrame = frame
        return try await renderImpl(
            frame: &workingFrame,
            releasePayloadAfterIngest: false,
            params: params,
            outputSpec: outputSpec,
            rawCalibration: rawCalibration
        )
    }

    internal func renderAndReleasePayload(
        frame: inout DecodedRAWFrame,
        params: EffectiveDevelopParams,
        outputSpec: RenderOutputSpec,
        rawCalibration: RAWLevelCalibration? = nil
    ) async throws -> RenderedFrame {
        try await renderImpl(
            frame: &frame,
            releasePayloadAfterIngest: true,
            params: params,
            outputSpec: outputSpec,
            rawCalibration: rawCalibration
        )
    }

    private func renderImpl(
        frame: inout DecodedRAWFrame,
        releasePayloadAfterIngest: Bool,
        params: EffectiveDevelopParams,
        outputSpec: RenderOutputSpec,
        rawCalibration: RAWLevelCalibration?
    ) async throws -> RenderedFrame {
        let safeMidtoneAnchorP = params.midtoneAnchorP.isFinite ? min(max(params.midtoneAnchorP, 0.65), 0.95) : 0.80
        let safeTargetHeadroom = HeadroomStops(
            log2Value: params.targetHeadroom.log2Value.isFinite ? max(params.targetHeadroom.log2Value, 0.0) : 0.0
        )

        let maxDim = MTLHeapTexturePool.maxTextureDimension(for: device)

        // Phase A (Stage 1): Ingest RAW payload, highlight reconstruction, Camera -> Linear Rec.2020 (D65)
        var (rec2020Opt, srcW, srcH, customWBAppliedInPass1): (SendableMTLTexture?, Int, Int, Bool) = try autoreleasepool {
            () throws -> (SendableMTLTexture?, Int, Int, Bool) in

            // Load optional DCP profile / Creative Look / .cube LUT
            var loadedDCP: DCPProfile? = nil
            var creativeLookTable: HSVTable3D? = nil
            switch params.develop.cameraProfile {
            case .standard:
                break
            case let .dcp(path):
                loadedDCP = try DCPProfile(contentsOf: URL(fileURLWithPath: path))
            case let .creativeLook(name):
                creativeLookTable = DCPProfile.builtInCreativeLook(named: name)
            }

            let loadedLUT: CubeLUT? = try params.develop.cubeLUTPath.map {
                try CubeLUT(contentsOf: URL(fileURLWithPath: $0))
            }

            let sceneKelvin: Double
            switch params.develop.whiteBalance {
            case .asShot:
                sceneKelvin = ColorTransforms.estimateSceneKelvin(matrices: frame.colorMatrices)
            case let .custom(kelvin, _):
                sceneKelvin = kelvin
            }

            let hueSatTable = loadedDCP?.interpolatedHueSatTable(sceneKelvin: sceneKelvin)
            let lookTable = loadedDCP?.lookTable ?? creativeLookTable

            let hueSatTex: any MTLTexture
            if let table = hueSatTable {
                guard let tex = table.makeMetalTexture(device: device) else {
                    throw MetalPipelineError.invalidDimensions(width: table.satDivs, height: table.hueDivs)
                }
                hueSatTex = tex
            } else {
                hueSatTex = dummyTex3D
            }

            let lookTex: any MTLTexture
            if let table = lookTable {
                guard let tex = table.makeMetalTexture(device: device) else {
                    throw MetalPipelineError.invalidDimensions(width: table.satDivs, height: table.hueDivs)
                }
                lookTex = tex
            } else {
                lookTex = dummyTex3D
            }

            var lut1DTex: any MTLTexture = dummyTex2D
            var lut3DTex: any MTLTexture = dummyTex3D
            var lutMode: UInt32 = 0
            var lutSize: UInt32 = 0
            var lutDomainMin = SIMD4<Float>(0, 0, 0, 0)
            var lutDomainMax = SIMD4<Float>(1, 1, 1, 1)

            if let lut = loadedLUT {
                guard let tex = lut.makeMetalTexture(device: device) else {
                    switch lut.dimension {
                    case let .oneD(n), let .threeD(n):
                        throw CubeLUTError.unsupportedDimension(n)
                    }
                }
                lutDomainMin = SIMD4<Float>(lut.domainMin, 0)
                lutDomainMax = SIMD4<Float>(lut.domainMax, 1)
                switch lut.dimension {
                case let .oneD(n):
                    lut1DTex = tex
                    lutMode = 1
                    lutSize = UInt32(n)
                case let .threeD(n):
                    lut3DTex = tex
                    lutMode = 2
                    lutSize = UInt32(n)
                }
            }

            // Stage 1-2: Ingest payload & transform to Linear Rec.2020 (D65)
            let srcW: Int
            let srcH: Int
            let rec2020Tex: SendableMTLTexture
            var customWBAppliedInPass1 = false

            switch frame.payload {
            case let .rawBayer(w, h, bitsPerSample, cfa, data):
                let minBytes = try Self.checkedByteCount(w, h, bytesPerPixel: MemoryLayout<UInt16>.stride, maxDimension: maxDim)
                guard data.count >= minBytes else {
                    throw MetalPipelineError.invalidPayloadDataSize(expectedAtLeast: minBytes, actual: data.count)
                }
                srcW = w
                srcH = h
                let cal = rawCalibration ?? RAWLevelCalibration.defaultFor(bitsPerSample: bitsPerSample)

                guard let rawBuf = data.withUnsafeBytes({ ptr -> (any MTLBuffer)? in
                    guard let base = ptr.baseAddress else { return nil }
                    return device.makeBuffer(bytes: base, length: minBytes, options: .storageModeShared)
                }) else {
                    throw MetalPipelineError.bufferAllocationFailed
                }

                let wbVec: SIMD3<Double>
                if frame.colorMatrices.asShotWBApplied {
                    wbVec = SIMD3<Double>(1, 1, 1)
                } else {
                    switch params.develop.whiteBalance {
                    case .asShot:
                        let m = frame.colorMatrices.wbMultipliers
                        let gAvg = m.count >= 4 ? 0.5 * (m[1] + m[3]) : (m.count >= 2 ? m[1] : 1.0)
                        let safeG = gAvg > 1e-6 ? gAvg : 1.0
                        let r = m.count >= 1 && m[0] > 1e-6 ? m[0] / safeG : 1.0
                        let b = m.count >= 3 && m[2] > 1e-6 ? m[2] / safeG : 1.0
                        wbVec = SIMD3<Double>(r, 1.0, b)
                    case let .custom(kelvin, tint):
                        wbVec = ColorTransforms.customWBMultipliers(
                            kelvin: kelvin,
                            tint: tint,
                            camXYZ: frame.colorMatrices.camXYZ
                        )
                        customWBAppliedInPass1 = true
                    }
                }

                let cfaCode: UInt32
                switch cfa {
                case .rggb, .unknown: cfaCode = 0
                case .bggr: cfaCode = 1
                case .grbg: cfaCode = 2
                case .gbrg: cfaCode = 3
                }

                let b0 = Float(cal.blackLevel.count > 0 ? cal.blackLevel[0] : 0)
                let b1 = Float(cal.blackLevel.count > 1 ? cal.blackLevel[1] : UInt32(b0))
                let b2 = Float(cal.blackLevel.count > 2 ? cal.blackLevel[2] : UInt32(b0))
                let b3 = Float(cal.blackLevel.count > 3 ? cal.blackLevel[3] : UInt32(b1))

                let demosaicTex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
                let reconTex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
                rec2020Tex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)

                let tg = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)

                let camTo2020 = ColorTransforms.toFloat3x3(
                    ColorTransforms.buildCameraToRec2020Matrix(
                        matrices: frame.colorMatrices,
                        dcp: loadedDCP,
                        sceneKelvin: sceneKelvin
                    )
                )

                var retainedForCB: [SendableMTLTexture] = [demosaicTex, reconTex, rec2020Tex]

                guard let cb = commandQueue.makeCommandBuffer() else {
                    throw MetalPipelineError.commandBufferCreationFailed
                }

                // Pass 1A: Malvar-He-Cutler 5x5 Demosaic + WB
                do {
                    let pso = try shaderLibrary.computePipelineState(for: "demosaic_bayer_malvar_5x5_kernel")
                    guard let enc = cb.makeComputeCommandEncoder() else {
                        throw MetalPipelineError.commandEncodingFailed
                    }
                    var u = DemosaicUniforms(
                        width: UInt32(w),
                        height: UInt32(h),
                        cfaPattern: cfaCode,
                        whiteLevel: Float(max(cal.whiteLevel, 1)),
                        blackLevel: SIMD4<Float>(b0, b1, b2, b3),
                        wbGain: SIMD4<Float>(Float(wbVec.x), Float(wbVec.y), Float(wbVec.z), 1.0),
                        clipThreshold: 0.985
                    )
                    enc.setComputePipelineState(pso)
                    enc.setBuffer(rawBuf, offset: 0, index: 0)
                    enc.setBytes(&u, length: MemoryLayout<DemosaicUniforms>.stride, index: 1)
                    enc.setTexture(demosaicTex.texture, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                    enc.endEncoding()
                }

                // Pass 1B: Highlight Reconstruction
                let minCeil = Float(0.985 * min(wbVec.x, min(wbVec.y, wbVec.z)))
                let maxCeil = Float(0.985 * max(wbVec.x, max(wbVec.y, wbVec.z)))
                try encodeHighlightReconstruction(
                    cb: cb,
                    inTex: demosaicTex,
                    outTex: reconTex,
                    width: w,
                    height: h,
                    mode: params.develop.highlightReconstruction,
                    minClipCeil: minCeil,
                    maxClipCeil: maxCeil,
                    retainedForCB: &retainedForCB
                )

                // Pass 2: Camera Matrix + DCP HSV / .cube LUT -> Linear Rec.2020
                do {
                    let pso = try shaderLibrary.computePipelineState(for: "camera_to_rec2020_lut_kernel")
                    guard let enc = cb.makeComputeCommandEncoder() else {
                        throw MetalPipelineError.commandEncodingFailed
                    }
                    var cu = CameraColorLUTUniforms(
                        camToRec2020Col0: SIMD4<Float>(camTo2020.columns.0, 0),
                        camToRec2020Col1: SIMD4<Float>(camTo2020.columns.1, 0),
                        camToRec2020Col2: SIMD4<Float>(camTo2020.columns.2, 0),
                        lutDomainMin: lutDomainMin,
                        lutDomainMax: lutDomainMax,
                        hasHueSatTable: hueSatTable != nil ? 1 : 0,
                        hasLookTable: lookTable != nil ? 1 : 0,
                        lutMode: lutMode,
                        lutSize: lutSize
                    )
                    enc.setComputePipelineState(pso)
                    enc.setTexture(reconTex.texture, index: 0)
                    enc.setTexture(rec2020Tex.texture, index: 1)
                    enc.setTexture(hueSatTex, index: 2)
                    enc.setTexture(lookTex, index: 3)
                    enc.setTexture(lut1DTex, index: 4)
                    enc.setTexture(lut3DTex, index: 5)
                    enc.setBytes(&cu, length: MemoryLayout<CameraColorLUTUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                    enc.endEncoding()
                }

                let kept = retainedForCB
                cb.addCompletedHandler { _ in _ = kept }
                cb.commit()
                cb.waitUntilCompleted()
                if let err = cb.error {
                    throw MetalPipelineError.gpuExecutionFailed(String(describing: err))
                }

            case let .linearRGB16U(w, h, cs, data):
                let expected3 = try Self.checkedByteCount(w, h, bytesPerPixel: 3 * MemoryLayout<UInt16>.stride, maxDimension: maxDim)
                let expected4 = try Self.checkedByteCount(w, h, bytesPerPixel: 4 * MemoryLayout<UInt16>.stride, maxDimension: maxDim)
                let chCount: UInt32
                let byteLen: Int
                if data.count >= expected4 && data.count % expected4 == 0 {
                    chCount = 4
                    byteLen = expected4
                } else if data.count >= expected3 {
                    chCount = 3
                    byteLen = expected3
                } else {
                    throw MetalPipelineError.invalidPayloadDataSize(expectedAtLeast: expected3, actual: data.count)
                }
                srcW = w
                srcH = h

                // Compensate LibRaw scale_colors() highlight=1 dmax attenuation & pre-comp highlight clipping
                var scaleFactor: Float = 1.0
                var wbNorm = SIMD3<Double>(1, 1, 1)
                if !frame.isLosslessMS && !frame.colorMatrices.asShotWBApplied {
                    let m = frame.colorMatrices.wbMultipliers
                    if m.count >= 3 {
                        let gAvg = m.count >= 4 ? 0.5 * (m[1] + m[3]) : m[1]
                        let safeG = gAvg > 1e-6 ? gAvg : 1.0
                        let rNorm = m[0] > 1e-6 ? m[0] / safeG : 1.0
                        let bNorm = m[2] > 1e-6 ? m[2] / safeG : 1.0
                        wbNorm = SIMD3<Double>(rNorm, 1.0, bNorm)
                        let dmaxNorm = max(rNorm, max(1.0, bNorm))
                        if dmaxNorm > 1.0 {
                            scaleFactor = Float(dmaxNorm)
                        }
                    }
                }

                let runClipRecon = !frame.isLosslessMS
                    && !frame.colorMatrices.asShotWBApplied
                    && (cs == .cameraNative || cs == .linearRec2020)

                var preMat = matrix_identity_double3x3
                var baseMat: simd_double3x3
                var threshScale = 0.985
                var usePreMat: UInt32 = 0
                switch cs {
                case .cameraNative:
                    baseMat = ColorTransforms.buildCameraToRec2020Matrix(
                        matrices: frame.colorMatrices,
                        dcp: loadedDCP,
                        sceneKelvin: sceneKelvin
                    )
                case .linearRec2020:
                    if runClipRecon && !ColorTransforms.isApproxIdentity(frame.colorMatrices.camXYZ) {
                        let cam2020NoDCP = ColorTransforms.buildCameraToRec2020Matrix(
                            matrices: frame.colorMatrices,
                            dcp: nil,
                            sceneKelvin: sceneKelvin
                        )
                        if ColorTransforms.isInvertible(cam2020NoDCP) {
                            preMat = cam2020NoDCP.inverse
                            threshScale = 0.985
                            usePreMat = 1
                            baseMat = ColorTransforms.buildCameraToRec2020Matrix(
                                matrices: frame.colorMatrices,
                                dcp: loadedDCP,
                                sceneKelvin: sceneKelvin
                            )
                        } else {
                            baseMat = matrix_identity_double3x3
                        }
                    } else {
                        baseMat = matrix_identity_double3x3
                    }
                case .extendedLinearDisplayP3:
                    baseMat = ColorTransforms.displayP3ToRec2020
                }
                let preMatF = ColorTransforms.toFloat3x3(preMat)
                let matF = ColorTransforms.toFloat3x3(baseMat)

                let dmaxD = max(wbNorm.x, max(wbNorm.y, wbNorm.z))
                let preCompClipThreshold = runClipRecon
                    ? SIMD4<Float>(
                        Float(threshScale * min(wbNorm.x / dmaxD, 1.0)),
                        Float(threshScale * min(wbNorm.y / dmaxD, 1.0)),
                        Float(threshScale * min(wbNorm.z / dmaxD, 1.0)),
                        1.0
                    )
                    : SIMD4<Float>(1, 1, 1, 0)

                guard let rawBuf = data.withUnsafeBytes({ ptr -> (any MTLBuffer)? in
                    guard let base = ptr.baseAddress else { return nil }
                    return device.makeBuffer(bytes: base, length: byteLen, options: .storageModeShared)
                }) else {
                    throw MetalPipelineError.bufferAllocationFailed
                }

                let camTex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
                rec2020Tex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
                var retainedForCB: [SendableMTLTexture] = [camTex, rec2020Tex]

                let tg = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
                guard let cb = commandQueue.makeCommandBuffer() else {
                    throw MetalPipelineError.commandBufferCreationFailed
                }

                do {
                    let unpackPSO = try shaderLibrary.computePipelineState(for: "unpack_rgb16u_to_rgba16f_kernel")
                    guard let enc = cb.makeComputeCommandEncoder() else {
                        throw MetalPipelineError.commandEncodingFailed
                    }
                    var uu = UnpackRGBUniforms(
                        width: UInt32(w),
                        height: UInt32(h),
                        channelCount: chCount,
                        scaleFactor: scaleFactor,
                        preCompClipThreshold: preCompClipThreshold,
                        preMatCol0: SIMD4<Float>(preMatF.columns.0, 0),
                        preMatCol1: SIMD4<Float>(preMatF.columns.1, 0),
                        preMatCol2: SIMD4<Float>(preMatF.columns.2, 0),
                        usePreMat: usePreMat,
                        clipThreshScale: Float(threshScale)
                    )
                    enc.setComputePipelineState(unpackPSO)
                    enc.setBuffer(rawBuf, offset: 0, index: 0)
                    enc.setBytes(&uu, length: MemoryLayout<UnpackRGBUniforms>.stride, index: 1)
                    enc.setTexture(camTex.texture, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                    enc.endEncoding()
                }

                let colorInputTex: SendableMTLTexture
                if runClipRecon {
                    let reconTex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
                    retainedForCB.append(reconTex)
                    let minCeil = Float(0.985 * min(wbNorm.x, min(wbNorm.y, wbNorm.z)))
                    let maxCeil = Float(0.985 * max(wbNorm.x, max(wbNorm.y, wbNorm.z)))
                    try encodeHighlightReconstruction(
                        cb: cb,
                        inTex: camTex,
                        outTex: reconTex,
                        width: w,
                        height: h,
                        mode: params.develop.highlightReconstruction,
                        minClipCeil: minCeil,
                        maxClipCeil: maxCeil,
                        retainedForCB: &retainedForCB
                    )
                    colorInputTex = reconTex
                } else {
                    colorInputTex = camTex
                }

                do {
                    let colorPSO = try shaderLibrary.computePipelineState(for: "camera_to_rec2020_lut_kernel")
                    guard let enc = cb.makeComputeCommandEncoder() else {
                        throw MetalPipelineError.commandEncodingFailed
                    }
                    var cu = CameraColorLUTUniforms(
                        camToRec2020Col0: SIMD4<Float>(matF.columns.0, 0),
                        camToRec2020Col1: SIMD4<Float>(matF.columns.1, 0),
                        camToRec2020Col2: SIMD4<Float>(matF.columns.2, 0),
                        lutDomainMin: lutDomainMin,
                        lutDomainMax: lutDomainMax,
                        hasHueSatTable: hueSatTable != nil ? 1 : 0,
                        hasLookTable: lookTable != nil ? 1 : 0,
                        lutMode: lutMode,
                        lutSize: lutSize
                    )
                    enc.setComputePipelineState(colorPSO)
                    enc.setTexture(colorInputTex.texture, index: 0)
                    enc.setTexture(rec2020Tex.texture, index: 1)
                    enc.setTexture(hueSatTex, index: 2)
                    enc.setTexture(lookTex, index: 3)
                    enc.setTexture(lut1DTex, index: 4)
                    enc.setTexture(lut3DTex, index: 5)
                    enc.setBytes(&cu, length: MemoryLayout<CameraColorLUTUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                    enc.endEncoding()
                }

                let kept = retainedForCB
                cb.addCompletedHandler { _ in _ = kept }
                cb.commit()
                cb.waitUntilCompleted()
                if let err = cb.error {
                    throw MetalPipelineError.gpuExecutionFailed(String(describing: err))
                }

            case let .linearRGB16F(w, h, cs, data):
                let expected3 = try Self.checkedByteCount(w, h, bytesPerPixel: 3 * 2, maxDimension: maxDim)
                let expected4 = try Self.checkedByteCount(w, h, bytesPerPixel: 4 * 2, maxDimension: maxDim)
                let chCount: UInt32
                let byteLen: Int
                if data.count >= expected4 {
                    chCount = 4
                    byteLen = expected4
                } else if data.count >= expected3 {
                    chCount = 3
                    byteLen = expected3
                } else {
                    throw MetalPipelineError.invalidPayloadDataSize(expectedAtLeast: expected3, actual: data.count)
                }
                srcW = w
                srcH = h

                guard let rawBuf = data.withUnsafeBytes({ ptr -> (any MTLBuffer)? in
                    guard let base = ptr.baseAddress else { return nil }
                    return device.makeBuffer(bytes: base, length: byteLen, options: .storageModeShared)
                }) else {
                    throw MetalPipelineError.bufferAllocationFailed
                }

                let inTex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
                rec2020Tex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)

                let baseMat: simd_double3x3
                switch cs {
                case .cameraNative:
                    baseMat = ColorTransforms.buildCameraToRec2020Matrix(
                        matrices: frame.colorMatrices,
                        dcp: loadedDCP,
                        sceneKelvin: sceneKelvin
                    )
                case .linearRec2020:
                    baseMat = matrix_identity_double3x3
                case .extendedLinearDisplayP3:
                    baseMat = ColorTransforms.displayP3ToRec2020
                }
                let matF = ColorTransforms.toFloat3x3(baseMat)

                let tg = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
                guard let cb = commandQueue.makeCommandBuffer(),
                      let enc = cb.makeComputeCommandEncoder() else {
                    throw MetalPipelineError.commandEncodingFailed
                }

                let unpackPSO = try shaderLibrary.computePipelineState(for: "unpack_rgb16f_to_rgba16f_kernel")
                var uu = UnpackRGBUniforms(
                    width: UInt32(w),
                    height: UInt32(h),
                    channelCount: chCount,
                    scaleFactor: 1.0,
                    preCompClipThreshold: SIMD4<Float>(1, 1, 1, 0),
                    preMatCol0: SIMD4<Float>(1, 0, 0, 0),
                    preMatCol1: SIMD4<Float>(0, 1, 0, 0),
                    preMatCol2: SIMD4<Float>(0, 0, 1, 0),
                    usePreMat: 0,
                    clipThreshScale: 1.0
                )
                enc.setComputePipelineState(unpackPSO)
                enc.setBuffer(rawBuf, offset: 0, index: 0)
                enc.setBytes(&uu, length: MemoryLayout<UnpackRGBUniforms>.stride, index: 1)
                enc.setTexture(inTex.texture, index: 0)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

                let colorPSO = try shaderLibrary.computePipelineState(for: "camera_to_rec2020_lut_kernel")
                var cu = CameraColorLUTUniforms(
                    camToRec2020Col0: SIMD4<Float>(matF.columns.0, 0),
                    camToRec2020Col1: SIMD4<Float>(matF.columns.1, 0),
                    camToRec2020Col2: SIMD4<Float>(matF.columns.2, 0),
                    lutDomainMin: lutDomainMin,
                    lutDomainMax: lutDomainMax,
                    hasHueSatTable: hueSatTable != nil ? 1 : 0,
                    hasLookTable: lookTable != nil ? 1 : 0,
                    lutMode: lutMode,
                    lutSize: lutSize
                )
                enc.setComputePipelineState(colorPSO)
                enc.setTexture(inTex.texture, index: 0)
                enc.setTexture(rec2020Tex.texture, index: 1)
                enc.setTexture(hueSatTex, index: 2)
                enc.setTexture(lookTex, index: 3)
                enc.setTexture(lut1DTex, index: 4)
                enc.setTexture(lut3DTex, index: 5)
                enc.setBytes(&cu, length: MemoryLayout<CameraColorLUTUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                enc.endEncoding()

                let kept = [inTex, rec2020Tex]
                cb.addCompletedHandler { _ in _ = kept }
                cb.commit()
                cb.waitUntilCompleted()
                if let err = cb.error {
                    throw MetalPipelineError.gpuExecutionFailed(String(describing: err))
                }
            }

            return (rec2020Tex, srcW, srcH, customWBAppliedInPass1)
        }
        if releasePayloadAfterIngest {
            frame.payload = .linearRGB16U(width: 0, height: 0, colorSpace: .cameraNative, data: Data())
        }

        // Stage 2A: LinearDenoiseStage (strictly BEFORE OpticalCorrectionStage per ADR-017).
        // Bypassed by default when CIRAWv9 ANE already denoised and preferANE == true.
        var stage2AOpt: SendableMTLTexture?
        let shouldRunLinearDenoise =
            (params.denoise.mode == .profiledWavelet || params.denoise.mode == .coreMLANE)
            && !(frame.backendUsed == .ciraw9 && params.denoise.preferANE)
            && (params.denoise.luminanceStrength > 0.0 || params.denoise.chromaStrength > 0.0)
        if shouldRunLinearDenoise {
            let inputRec2020 = rec2020Opt!
            let noiseProfile = SensorNoiseProfileLoader.shared.profileWithSonyFallback(
                forMake: frame.exif.make,
                model: frame.exif.model
            )
            let denoisedTex = try await denoiseStage.denoise(
                inputTexture: inputRec2020.texture,
                iso: frame.isoSpeed,
                noiseProfile: noiseProfile,
                params: params.denoise,
                commandQueue: commandQueue
            )
            stage2AOpt = SendableMTLTexture(denoisedTex)
            if denoisedTex !== inputRec2020.texture {
                rec2020Opt = nil
            }
        } else {
            stage2AOpt = rec2020Opt
        }
        rec2020Opt = nil

        // Stage 2B: OpticalCorrectionStage (unrotated sensor coordinates)
        var stage2BOpt: SendableMTLTexture?
        if params.optics.enabled {
            let inputStage2A = stage2AOpt!
            let (correctedTex, _) = try await opticsStage.applyCorrection(
                inputTexture: inputStage2A.texture,
                frame: frame,
                params: params.optics,
                commandQueue: commandQueue
            )
            stage2BOpt = SendableMTLTexture(correctedTex)
            if correctedTex !== inputStage2A.texture {
                stage2AOpt = nil
            }
        } else {
            stage2BOpt = stage2AOpt
        }
        stage2AOpt = nil

        // Compute Pass 5 output geometry (Orientation 1..8 -> Upright, Aspect Crop, Linear Resize)
        let geom = ColorTransforms.computeOutputGeometry(
            srcWidth: srcW,
            srcHeight: srcH,
            orientation: frame.orientation,
            cropAspect: params.cropAspect,
            cropOffset: params.cropOffset,
            maxLongEdge: params.maxLongEdge,
            gainMapResolution: outputSpec.gainMapResolution,
            gainMapChannels: outputSpec.gainMapChannels
        )
        guard geom.outWidth > 0,
              geom.outHeight > 0,
              geom.outWidth <= maxDim,
              geom.outHeight <= maxDim else {
            throw MetalPipelineError.invalidDimensions(width: geom.outWidth, height: geom.outHeight)
        }

        // Phase B (Stage 2C + OrientCropResize): Scene Grading, Optical Sharpness, Clarity, Orient/Crop/Resize
        var uprightRec2020Opt: SendableMTLTexture? = try autoreleasepool { () throws -> SendableMTLTexture in
            let stage2BBox = stage2BOpt!
            let gradedTex = try texturePool.acquire(width: srcW, height: srcH, pixelFormat: .rgba16Float)
            let uprightTex = try texturePool.acquire(width: geom.outWidth, height: geom.outHeight, pixelFormat: .rgba16Float)
            var retainedCB: [SendableMTLTexture] = [stage2BBox, gradedTex, uprightTex]

            let wbMatDouble: simd_double3x3
            if !customWBAppliedInPass1, case let .custom(kelvin, tint) = params.develop.whiteBalance {
                let refXYZ = ColorTransforms.estimateAsShotSceneXYZ(matrices: frame.colorMatrices)
                wbMatDouble = ColorTransforms.customWBAdaptationMatrixRec2020(
                    kelvin: kelvin,
                    tint: tint,
                    referenceSceneXYZ: refXYZ
                )
            } else {
                wbMatDouble = matrix_identity_double3x3
            }
            let wbMatF = ColorTransforms.toFloat3x3(wbMatDouble)

            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let srcGrid = MTLSize(width: (srcW + 15) / 16, height: (srcH + 15) / 16, depth: 1)
            let outGrid = MTLSize(width: (geom.outWidth + 15) / 16, height: (geom.outHeight + 15) / 16, depth: 1)

            guard let cb = commandQueue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else {
                throw MetalPipelineError.commandEncodingFailed
            }

            // Pass 3: Shared Scene Grading
            do {
                let pso = try shaderLibrary.computePipelineState(for: "scene_grading_kernel")
                var su = SceneGradingUniforms(
                    wbCol0: SIMD4<Float>(wbMatF.columns.0, 0),
                    wbCol1: SIMD4<Float>(wbMatF.columns.1, 0),
                    wbCol2: SIMD4<Float>(wbMatF.columns.2, 0),
                    exposureLinear: Float(exp2(params.develop.exposureEV)),
                    blackPoint: Float(params.develop.blackPoint),
                    shadowRecovery: Float(params.develop.shadowRecovery),
                    vibrance: Float(params.develop.vibrance)
                )
                enc.setComputePipelineState(pso)
                enc.setTexture(stage2BBox.texture, index: 0)
                enc.setTexture(gradedTex.texture, index: 1)
                enc.setBytes(&su, length: MemoryLayout<SceneGradingUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(srcGrid, threadsPerThreadgroup: tg)
            }

            var current2CTex = gradedTex

            // Optional Stage 2C-1: Physical Inverse-Diffusion Optical Sharpness (0...100)
            let sharpStrength = params.develop.opticalSharpness
            if sharpStrength.isFinite && sharpStrength > 1e-4 {
                let diffA = try texturePool.acquire(width: srcW, height: srcH, pixelFormat: .r32Float)
                let diffB = try texturePool.acquire(width: srcW, height: srcH, pixelFormat: .r32Float)
                let sharpOutTex = try texturePool.acquire(width: srcW, height: srcH, pixelFormat: .rgba16Float)
                retainedCB.append(contentsOf: [diffA, diffB, sharpOutTex])

                let initPSO = try shaderLibrary.computePipelineState(for: "optical_sharpness_init_kernel")
                let stepPSO = try shaderLibrary.computePipelineState(for: "optical_sharpness_diffuse_step_kernel")
                let appPSO = try shaderLibrary.computePipelineState(for: "optical_sharpness_apply_kernel")

                let dt = Float(0.14 * min(max(sharpStrength, 0.0), 100.0) / 100.0)
                var osu = OpticalSharpnessUniforms(width: UInt32(srcW), height: UInt32(srcH), dt: dt)

                enc.setComputePipelineState(initPSO)
                enc.setTexture(current2CTex.texture, index: 0)
                enc.setTexture(diffA.texture, index: 1)
                enc.setBytes(&osu, length: MemoryLayout<OpticalSharpnessUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(srcGrid, threadsPerThreadgroup: tg)

                var curDiff = diffA
                var nextDiff = diffB
                for _ in 0..<4 {
                    enc.setComputePipelineState(stepPSO)
                    enc.setTexture(curDiff.texture, index: 0)
                    enc.setTexture(nextDiff.texture, index: 1)
                    enc.setBytes(&osu, length: MemoryLayout<OpticalSharpnessUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(srcGrid, threadsPerThreadgroup: tg)
                    swap(&curDiff, &nextDiff)
                }

                enc.setComputePipelineState(appPSO)
                enc.setTexture(current2CTex.texture, index: 0)
                enc.setTexture(curDiff.texture, index: 1)
                enc.setTexture(sharpOutTex.texture, index: 2)
                enc.setBytes(&osu, length: MemoryLayout<OpticalSharpnessUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(srcGrid, threadsPerThreadgroup: tg)

                current2CTex = sharpOutTex
            }

            // Optional Stage 2C-2: Halo-Free Edge-Aware Clarity (-100...+100)
            let clarityVal = params.develop.clarity
            if clarityVal.isFinite && abs(clarityVal) > 1e-4 {
                let clarityTmp = try texturePool.acquire(width: srcW, height: srcH, pixelFormat: .rg16Float)
                let clarityOut = try texturePool.acquire(width: srcW, height: srcH, pixelFormat: .rgba16Float)
                retainedCB.append(contentsOf: [clarityTmp, clarityOut])

                let hPSO = try shaderLibrary.computePipelineState(for: "clarity_bilateral_h_kernel")
                let vPSO = try shaderLibrary.computePipelineState(for: "clarity_bilateral_v_apply_kernel")
                let stride = UInt32(max(1, min(srcW, srcH) / 1500 + 1))
                var cu = ClarityUniforms(
                    width: UInt32(srcW),
                    height: UInt32(srcH),
                    stride: stride,
                    clarity: Float(min(max(clarityVal, -100.0), 100.0))
                )

                enc.setComputePipelineState(hPSO)
                enc.setTexture(current2CTex.texture, index: 0)
                enc.setTexture(clarityTmp.texture, index: 1)
                enc.setBytes(&cu, length: MemoryLayout<ClarityUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(srcGrid, threadsPerThreadgroup: tg)

                enc.setComputePipelineState(vPSO)
                enc.setTexture(current2CTex.texture, index: 0)
                enc.setTexture(clarityTmp.texture, index: 1)
                enc.setTexture(clarityOut.texture, index: 2)
                enc.setBytes(&cu, length: MemoryLayout<ClarityUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(srcGrid, threadsPerThreadgroup: tg)

                current2CTex = clarityOut
            }

            // Pass 5A: Orientation Baking + Aspect Crop + Linear-Light Resize
            do {
                let pso = try shaderLibrary.computePipelineState(for: "orient_crop_resize_kernel")
                let isOneToOne: UInt32 = (geom.outWidth == geom.cropWidth && geom.outHeight == geom.cropHeight) ? 1 : 0
                var ou = OrientCropResizeUniforms(
                    srcWidth: UInt32(srcW),
                    srcHeight: UInt32(srcH),
                    cropX: UInt32(geom.cropX),
                    cropY: UInt32(geom.cropY),
                    cropWidth: UInt32(geom.cropWidth),
                    cropHeight: UInt32(geom.cropHeight),
                    outWidth: UInt32(geom.outWidth),
                    outHeight: UInt32(geom.outHeight),
                    orientation: UInt32(geom.orientation),
                    isOneToOne: isOneToOne
                )
                enc.setComputePipelineState(pso)
                enc.setTexture(current2CTex.texture, index: 0)
                enc.setTexture(uprightTex.texture, index: 1)
                enc.setBytes(&ou, length: MemoryLayout<OrientCropResizeUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(outGrid, threadsPerThreadgroup: tg)
            }

            enc.endEncoding()
            let kept = retainedCB
            cb.addCompletedHandler { _ in _ = kept }
            cb.commit()
            cb.waitUntilCompleted()
            if let err = cb.error {
                throw MetalPipelineError.gpuExecutionFailed(String(describing: err))
            }
            return uprightTex
        }
        stage2BOpt = nil

        // Stage 2D [v3 Slot]: ColorGradingStage (default PassThroughColorGradingStage)
        var stage2DOpt: SendableMTLTexture? = SendableMTLTexture(
            try await colorGradingStage.apply(
                inputTexture: uprightRec2020Opt!.texture,
                params: params.aiColor,
                commandQueue: commandQueue
            )
        )

        // Phase C (Stage 2E): Dual-Branch ToneMap + OKLab Gamut Map + sRGB Quantization
        let (sdrLinearTex, hdrLinearTex, sdrCGImage) = try autoreleasepool {
            () throws -> (SendableMTLTexture, SendableMTLTexture, CGImage) in
            let uprightRec2020Tex = uprightRec2020Opt!
            let stage2DBox = stage2DOpt!
            let sdrLinearTex = try texturePool.acquire(width: geom.outWidth, height: geom.outHeight, pixelFormat: .rgba16Float)
            let hdrLinearTex = try texturePool.acquire(width: geom.outWidth, height: geom.outHeight, pixelFormat: .rgba16Float)

            let is16Bit = (outputSpec.targetBitDepth == .bit10)
            let bytesPerPixel = is16Bit ? 8 : 4
            let outBytesPerRow = geom.outWidth * bytesPerPixel
            let outByteCount = outBytesPerRow * geom.outHeight
            guard let cgOutBuf = device.makeBuffer(length: outByteCount, options: .storageModeShared) else {
                throw MetalPipelineError.bufferAllocationFailed
            }

            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let outGrid = MTLSize(width: (geom.outWidth + 15) / 16, height: (geom.outHeight + 15) / 16, depth: 1)

            guard let cb = commandQueue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else {
                throw MetalPipelineError.commandEncodingFailed
            }

            // Pass 4: Midtone-Locked Dual-Branch Tone Mapping + OKLab Soft Gamut Mapping
            do {
                let pso = try shaderLibrary.computePipelineState(for: "dual_branch_tonemap_gamut_kernel")
                let mapperCode: UInt32
                switch params.sdrToneMapper {
                case .agx: mapperCode = 0
                case .neutralRational: mapperCode = 1
                case .openDRT: mapperCode = 2
                case .sigmoid: mapperCode = 3
                }
                var tu = ToneMapGamutUniforms(
                    midtoneAnchorP: Float(safeMidtoneAnchorP),
                    targetHeadroomStops: Float(safeTargetHeadroom.log2Value),
                    sdrToneMapper: mapperCode,
                    isSRGBBase: outputSpec.baseColorSpace == .srgb ? 1 : 0,
                    sdrExposureLinear: Float(exp2(params.develop.sdrExposureEV)),
                    sdrHighlightCompression: Float(params.develop.sdrHighlightCompression),
                    sdrContrast: Float(params.develop.sdrContrast),
                    sdrSaturation: Float(params.develop.sdrSaturation),
                    hdrHighlightExcitation: Float(params.develop.hdrHighlightExcitation),
                    hdrRolloffSoftness: Float(params.develop.hdrRolloffSoftness)
                )
                enc.setComputePipelineState(pso)
                enc.setTexture(stage2DBox.texture, index: 0)
                enc.setTexture(sdrLinearTex.texture, index: 1)
                enc.setTexture(hdrLinearTex.texture, index: 2)
                enc.setBytes(&tu, length: MemoryLayout<ToneMapGamutUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(outGrid, threadsPerThreadgroup: tg)
            }

            // Pass 5B: sRGB OETF Quantization for sdrCGImage
            do {
                let pso = try shaderLibrary.computePipelineState(for: "linear_to_srgb_oetf_quantize_kernel")
                var qu = QuantizeOutputUniforms(
                    width: UInt32(geom.outWidth),
                    height: UInt32(geom.outHeight),
                    is16Bit: is16Bit ? 1 : 0
                )
                enc.setComputePipelineState(pso)
                enc.setTexture(sdrLinearTex.texture, index: 0)
                enc.setBuffer(cgOutBuf, offset: 0, index: 0)
                enc.setBuffer(gainMapSynthesizer.blueNoiseBuffer, offset: 0, index: 1)
                enc.setBytes(&qu, length: MemoryLayout<QuantizeOutputUniforms>.stride, index: 2)
                enc.dispatchThreadgroups(outGrid, threadsPerThreadgroup: tg)
            }

            enc.endEncoding()
            let kept = [uprightRec2020Tex, stage2DBox, sdrLinearTex, hdrLinearTex]
            cb.addCompletedHandler { _ in _ = kept }
            cb.commit()
            cb.waitUntilCompleted()
            if let err = cb.error {
                throw MetalPipelineError.gpuExecutionFailed(String(describing: err))
            }

            // Build CGImage in target color space
            let cgData = Data(bytes: cgOutBuf.contents(), count: outByteCount)
            guard let provider = CGDataProvider(data: cgData as CFData) else {
                throw MetalPipelineError.cgImageCreationFailed
            }
            let csName = (outputSpec.baseColorSpace == .srgb) ? CGColorSpace.sRGB : CGColorSpace.displayP3
            guard let cgColorSpace = CGColorSpace(name: csName) else {
                throw MetalPipelineError.cgImageCreationFailed
            }
            let bitmapInfo: CGBitmapInfo = is16Bit
                ? CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
                : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

            guard let cgImage = CGImage(
                width: geom.outWidth,
                height: geom.outHeight,
                bitsPerComponent: is16Bit ? 16 : 8,
                bitsPerPixel: is16Bit ? 64 : 32,
                bytesPerRow: outBytesPerRow,
                space: cgColorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else {
                throw MetalPipelineError.cgImageCreationFailed
            }

            return (sdrLinearTex, hdrLinearTex, cgImage)
        }
        uprightRec2020Opt = nil
        stage2DOpt = nil

        // ISO/IEC 21496-1:2025 Gain Map Synthesis
        let gainMapResult = try gainMapSynthesizer.synthesize(
            commandQueue: commandQueue,
            sdrLinearTexture: sdrLinearTex,
            hdrLinearTexture: hdrLinearTex,
            baseColorSpace: outputSpec.baseColorSpace,
            targetHeadroom: safeTargetHeadroom,
            midtoneAnchorP: safeMidtoneAnchorP,
            gamma: outputSpec.gainMapGamma,
            channels: outputSpec.gainMapChannels,
            resolution: outputSpec.gainMapResolution,
            lockLegacyBounds: outputSpec.lockLegacyAppleGainMapBounds
        )

        // Optional HLG 'x420' CVPixelBuffer for Douyin HLG MP4
        let hlgBuffer: SendablePixelBuffer?
        if outputSpec.generateHLGTexture {
            let dims = outputSpec.hlgTargetDimensions ?? PixelDimensions(width: geom.outWidth, height: geom.outHeight)
            hlgBuffer = try await generateHLGPixelBuffer(
                from: hdrLinearTex,
                baseColorSpace: outputSpec.baseColorSpace,
                targetDimensions: dims
            )
        } else {
            hlgBuffer = nil
        }

        var outExif = frame.exif
        outExif.orientation = 1

        return RenderedFrame(
            sourceURL: frame.sourceURL,
            width: geom.outWidth,
            height: geom.outHeight,
            baseColorSpace: outputSpec.baseColorSpace,
            sdrCGImage: sdrCGImage,
            sdrLinearTexture: sdrLinearTex,
            hdrLinearTexture: hdrLinearTex,
            hlgPixelBuffer: hlgBuffer,
            gainMap: gainMapResult,
            exif: outExif
        )
    }

    public func recomputeGainMapCompensated(
        hdrTexture: SendableMTLTexture,
        compressedSDRJPEGData: Data,
        metadata: GainMapMetadata,
        gamma: Double,
        channels: GainMapChannels,
        resolution: GainMapResolution,
        midtoneAnchorP: Double = 0.80,
        baseColorSpace: BaseColorSpace? = nil
    ) async throws -> GainMapResult {
        try gainMapSynthesizer.recomputeGainMapCompensated(
            commandQueue: commandQueue,
            hdrTexture: hdrTexture,
            compressedSDRJPEGData: compressedSDRJPEGData,
            metadata: metadata,
            gamma: gamma,
            channels: channels,
            resolution: resolution,
            midtoneAnchorP: midtoneAnchorP,
            baseColorSpace: baseColorSpace
        )
    }

    /// Converts an Extended Linear Display P3 / sRGB `.rgba16Float` texture into a BT.2020 HLG 10-bit
    /// `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`'x420'`) `CVPixelBuffer` anchored
    /// with diffuse white `1.0` at exact `75.00%` HLG (`Y_10 = 721`).
    public func generateHLGPixelBuffer(
        from hdrLinearTexture: SendableMTLTexture,
        baseColorSpace: BaseColorSpace = .displayP3,
        targetDimensions: PixelDimensions
    ) async throws -> SendablePixelBuffer {
        try autoreleasepool {
            let maxDim = MTLHeapTexturePool.maxTextureDimension(for: device)
            guard targetDimensions.width > 0,
                  targetDimensions.height > 0,
                  targetDimensions.width <= maxDim,
                  targetDimensions.height <= maxDim else {
                throw MetalPipelineError.invalidDimensions(width: targetDimensions.width, height: targetDimensions.height)
            }
            let outW = max(2, targetDimensions.width & ~1)
            let outH = max(2, targetDimensions.height & ~1)
            guard outW <= maxDim, outH <= maxDim else {
                throw MetalPipelineError.invalidDimensions(width: outW, height: outH)
            }

            let attrs: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var maybePB: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                outW,
                outH,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                attrs as CFDictionary,
                &maybePB
            )
            guard status == kCVReturnSuccess, let pb = maybePB else {
                throw MetalPipelineError.hlgPixelBufferCreationFailed(status)
            }

            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)

            let sendablePB = SendablePixelBuffer(pb)
            let planes: HLGPlaneTextures = try cvCacheLock.withLock { box in
                if box.cache == nil {
                    var created: CVMetalTextureCache?
                    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &created)
                    box.cache = created
                }
                guard let cache = box.cache else {
                    throw MetalPipelineError.hlgMetalTextureBindFailed(kCVReturnError)
                }

                var yRef: CVMetalTexture?
                let st0 = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault,
                    cache,
                    sendablePB.buffer,
                    nil,
                    .r16Uint,
                    outW,
                    outH,
                    0,
                    &yRef
                )
                guard st0 == kCVReturnSuccess, let yCV = yRef, let yMetal = CVMetalTextureGetTexture(yCV) else {
                    throw MetalPipelineError.hlgMetalTextureBindFailed(st0)
                }

                var uvRef: CVMetalTexture?
                let st1 = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault,
                    cache,
                    sendablePB.buffer,
                    nil,
                    .rg16Uint,
                    outW / 2,
                    outH / 2,
                    1,
                    &uvRef
                )
                guard st1 == kCVReturnSuccess, let uvCV = uvRef, let uvMetal = CVMetalTextureGetTexture(uvCV) else {
                    throw MetalPipelineError.hlgMetalTextureBindFailed(st1)
                }

                return HLGPlaneTextures(yCV: yCV, uvCV: uvCV, yMetal: yMetal, uvMetal: uvMetal)
            }

            let pso = try shaderLibrary.computePipelineState(for: "hlg_p3_to_bt2020_420x10_kernel")
            guard let cb = commandQueue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else {
                throw MetalPipelineError.commandEncodingFailed
            }

            var hu = HLGConvertUniforms(isSRGBBase: baseColorSpace == .srgb ? 1 : 0)
            enc.setComputePipelineState(pso)
            enc.setTexture(hdrLinearTexture.texture, index: 0)
            enc.setTexture(planes.yMetal, index: 1)
            enc.setTexture(planes.uvMetal, index: 2)
            enc.setBytes(&hu, length: MemoryLayout<HLGConvertUniforms>.stride, index: 0)

            let uvW = outW / 2
            let uvH = outH / 2
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (uvW + 15) / 16, height: (uvH + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()

            let kept = [hdrLinearTexture]
            cb.addCompletedHandler { _ in _ = kept }
            cb.commit()
            cb.waitUntilCompleted()

            withExtendedLifetime((planes.yCV, planes.uvCV)) {}
            cvCacheLock.withLock { box in
                if let cache = box.cache {
                    CVMetalTextureCacheFlush(cache, 0)
                }
            }

            if let err = cb.error {
                throw MetalPipelineError.gpuExecutionFailed(String(describing: err))
            }

            return sendablePB
        }
    }

    private static func checkedByteCount(_ w: Int, _ h: Int, bytesPerPixel: Int, maxDimension: Int) throws -> Int {
        guard w > 0, h > 0, w <= maxDimension, h <= maxDimension, bytesPerPixel > 0 else {
            throw MetalPipelineError.invalidDimensions(width: w, height: h)
        }
        let (wh, ov1) = w.multipliedReportingOverflow(by: h)
        let (total, ov2) = wh.multipliedReportingOverflow(by: bytesPerPixel)
        guard !ov1, !ov2, total > 0 else {
            throw MetalPipelineError.invalidDimensions(width: w, height: h)
        }
        return total
    }

    private func encodeHighlightReconstruction(
        cb: any MTLCommandBuffer,
        inTex: SendableMTLTexture,
        outTex: SendableMTLTexture,
        width w: Int,
        height h: Int,
        mode: HighlightReconstructionMode,
        minClipCeil: Float,
        maxClipCeil: Float,
        retainedForCB: inout [SendableMTLTexture]
    ) throws {
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let gridW = (w + 15) / 16
        let gridH = (h + 15) / 16
        let grid = MTLSize(width: gridW, height: gridH, depth: 1)

        var hrUniforms = HighlightReconUniforms(
            width: UInt32(w),
            height: UInt32(h),
            minClipCeil: minClipCeil,
            maxClipCeil: maxClipCeil
        )

        switch mode {
        case .opposedInpaint:
            let chromaHistBytes = 6 * 256 * MemoryLayout<UInt32>.stride
            guard let chromaHistBuf = device.makeBuffer(length: chromaHistBytes, options: .storageModeShared),
                  let finalChromaBuf = device.makeBuffer(length: 4 * MemoryLayout<Float>.stride, options: .storageModePrivate) else {
                throw MetalPipelineError.bufferAllocationFailed
            }
            memset(chromaHistBuf.contents(), 0, chromaHistBytes)

            let redPSO = try shaderLibrary.computePipelineState(for: "opposed_inpaint_reduce_kernel")
            let finPSO = try shaderLibrary.computePipelineState(for: "opposed_inpaint_finalize_kernel")
            let appPSO = try shaderLibrary.computePipelineState(for: "opposed_inpaint_apply_kernel")
            guard let enc = cb.makeComputeCommandEncoder() else {
                throw MetalPipelineError.commandEncodingFailed
            }

            enc.setComputePipelineState(redPSO)
            enc.setTexture(inTex.texture, index: 0)
            enc.setBuffer(chromaHistBuf, offset: 0, index: 0)
            enc.setBytes(&hrUniforms, length: MemoryLayout<HighlightReconUniforms>.stride, index: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

            enc.setComputePipelineState(finPSO)
            enc.setBuffer(chromaHistBuf, offset: 0, index: 0)
            enc.setBuffer(finalChromaBuf, offset: 0, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

            enc.setComputePipelineState(appPSO)
            enc.setTexture(inTex.texture, index: 0)
            enc.setTexture(outTex.texture, index: 1)
            enc.setBuffer(finalChromaBuf, offset: 0, index: 0)
            enc.setBytes(&hrUniforms, length: MemoryLayout<HighlightReconUniforms>.stride, index: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()

        case .blend:
            let blendPSO = try shaderLibrary.computePipelineState(for: "highlight_blend_kernel")
            guard let enc = cb.makeComputeCommandEncoder() else {
                throw MetalPipelineError.commandEncodingFailed
            }
            enc.setComputePipelineState(blendPSO)
            enc.setTexture(inTex.texture, index: 0)
            enc.setTexture(outTex.texture, index: 1)
            enc.setBytes(&hrUniforms, length: MemoryLayout<HighlightReconUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()

        case .rebuild:
            let w1 = max(1, (w + 1) / 2), h1 = max(1, (h + 1) / 2)
            let w2 = max(1, (w1 + 1) / 2), h2 = max(1, (h1 + 1) / 2)
            let seedTex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
            let pull1Tex = try texturePool.acquire(width: w1, height: h1, pixelFormat: .rgba16Float)
            let pull2Tex = try texturePool.acquire(width: w2, height: h2, pixelFormat: .rgba16Float)
            let push1Tex = try texturePool.acquire(width: w1, height: h1, pixelFormat: .rgba16Float)
            let push0Tex = try texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
            retainedForCB.append(contentsOf: [seedTex, pull1Tex, pull2Tex, push1Tex, push0Tex])

            let seedPSO = try shaderLibrary.computePipelineState(for: "rebuild_seed_kernel")
            let pullPSO = try shaderLibrary.computePipelineState(for: "rebuild_pull_kernel")
            let pushPSO = try shaderLibrary.computePipelineState(for: "rebuild_push_kernel")
            let appPSO = try shaderLibrary.computePipelineState(for: "rebuild_apply_kernel")
            guard let enc = cb.makeComputeCommandEncoder() else {
                throw MetalPipelineError.commandEncodingFailed
            }
            enc.setComputePipelineState(seedPSO)
            enc.setTexture(inTex.texture, index: 0)
            enc.setTexture(seedTex.texture, index: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

            enc.setComputePipelineState(pullPSO)
            enc.setTexture(seedTex.texture, index: 0)
            enc.setTexture(pull1Tex.texture, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: (w1 + 15) / 16, height: (h1 + 15) / 16, depth: 1), threadsPerThreadgroup: tg)

            enc.setTexture(pull1Tex.texture, index: 0)
            enc.setTexture(pull2Tex.texture, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: (w2 + 15) / 16, height: (h2 + 15) / 16, depth: 1), threadsPerThreadgroup: tg)

            enc.setComputePipelineState(pushPSO)
            enc.setTexture(pull1Tex.texture, index: 0)
            enc.setTexture(pull2Tex.texture, index: 1)
            enc.setTexture(push1Tex.texture, index: 2)
            enc.dispatchThreadgroups(MTLSize(width: (w1 + 15) / 16, height: (h1 + 15) / 16, depth: 1), threadsPerThreadgroup: tg)

            enc.setTexture(seedTex.texture, index: 0)
            enc.setTexture(push1Tex.texture, index: 1)
            enc.setTexture(push0Tex.texture, index: 2)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

            enc.setComputePipelineState(appPSO)
            enc.setTexture(inTex.texture, index: 0)
            enc.setTexture(push0Tex.texture, index: 1)
            enc.setTexture(outTex.texture, index: 2)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
    }
}
