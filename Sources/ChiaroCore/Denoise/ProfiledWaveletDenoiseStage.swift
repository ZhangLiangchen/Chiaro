/*
 * This file is part of Chiaro.
 *
 * Chiaro is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Profiled Poisson-Gaussian GAT + À-trous wavelet + Makitalo-Foi IGAT ported from darktable:
 *   darktable/src/iop/denoiseprofile.c (GPL-3.0-or-later)
 */

import Foundation
import Metal
import simd

private struct ProfiledDenoiseUniforms {
    var width: UInt32
    var height: UInt32
    var scaleIndex: UInt32
    var stepSize: UInt32
    var aCoeffs: SIMD4<Float>      // xyz = a[0..2], w = sb2[scaleIndex]
    var sigmaG2: SIMD4<Float>      // xyz = b[c] / (a[c]*a[c]), w = 0
    var yZeroFloor: SIMD4<Float>   // xyz = 0.5 * 2 * sqrt(0.375 + sigmaG2[c]), w = 0
    var lumaLambda: Float
    var chromaLambda: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var srcOffsetY: UInt32 = 0
    var writeOffsetY: UInt32 = 0
    var validHeight: UInt32 = 0
    var flags: UInt32 = 0
}

public enum ProfiledDenoiseError: Error, Sendable, CustomStringConvertible {
    case metalDeviceUnavailable
    case outputTextureAllocationFailed
    case commandEncodingFailed
    case gpuExecutionFailed(String)

    public var description: String {
        switch self {
        case .metalDeviceUnavailable:
            return "Metal device unavailable for ProfiledWaveletDenoiseStage."
        case .outputTextureAllocationFailed:
            return "Failed to allocate output texture for ProfiledWaveletDenoiseStage."
        case .commandEncodingFailed:
            return "Failed to encode Metal commands for ProfiledWaveletDenoiseStage."
        case let .gpuExecutionFailed(msg):
            return "Metal profiled denoise execution failed: \(msg)"
        }
    }
}

public final class ProfiledWaveletDenoiseStage: LinearDenoiseStage, @unchecked Sendable {
    /// Exact 2D B3-spline (`h = [1, 4, 6, 4, 1]/16`) white-noise variance per wavelet detail scale.
    private static let b3SplineBandVariances: [Float] = [
        0.79351807,
        0.04026598,
        0.00731153,
        0.00169888,
        0.00041140,
    ]

    public let device: any MTLDevice
    private let shaderLibrary: MetalShaderLibrary
    private let texturePool: MTLHeapTexturePool

    public init(
        device: (any MTLDevice)? = nil,
        shaderLibrary: MetalShaderLibrary? = nil,
        texturePool: MTLHeapTexturePool? = nil
    ) throws {
        guard let dev = device ?? shaderLibrary?.device ?? texturePool?.device ?? MTLCreateSystemDefaultDevice() else {
            throw ProfiledDenoiseError.metalDeviceUnavailable
        }
        self.device = dev
        self.shaderLibrary = try shaderLibrary ?? MetalShaderLibrary(device: dev, prewarmAllKernels: true)
        self.texturePool = texturePool ?? MTLHeapTexturePool(device: dev)
    }

    public func denoise(
        inputTexture: any MTLTexture,
        iso: Int?,
        noiseProfile: SensorNoiseProfile?,
        params: DenoiseParameters,
        commandQueue: any MTLCommandQueue
    ) async throws -> any MTLTexture {
        try await denoiseImpl(
            inputTexture: inputTexture,
            iso: iso,
            noiseProfile: noiseProfile,
            params: params,
            commandQueue: commandQueue,
            forceUntiled: false
        )
    }

    internal func denoiseImpl(
        inputTexture: any MTLTexture,
        iso: Int?,
        noiseProfile: SensorNoiseProfile?,
        params: DenoiseParameters,
        commandQueue: any MTLCommandQueue,
        forceUntiled: Bool
    ) async throws -> any MTLTexture {
        let sanitized = params.sanitized()
        guard sanitized.mode == .profiledWavelet || sanitized.mode == .coreMLANE else {
            return inputTexture
        }
        guard sanitized.luminanceStrength > 0.0 || sanitized.chromaStrength > 0.0 else {
            return inputTexture
        }

        let width = inputTexture.width
        let height = inputTexture.height
        guard width > 0, height > 0 else {
            return inputTexture
        }

        let effectiveISO = max(iso ?? 100, 50)
        let coeffs = Self.resolveCoefficients(iso: effectiveISO, noiseProfile: noiseProfile)

        let aVec = SIMD3<Float>(
            max(Float(coeffs.a.x), 1e-8),
            max(Float(coeffs.a.y), 1e-8),
            max(Float(coeffs.a.z), 1e-8)
        )
        let bVec = SIMD3<Float>(
            max(Float(coeffs.b.x), 0.0),
            max(Float(coeffs.b.y), 0.0),
            max(Float(coeffs.b.z), 0.0)
        )
        let sigmaG2 = SIMD3<Float>(
            bVec.x / (aVec.x * aVec.x),
            bVec.y / (aVec.y * aVec.y),
            bVec.z / (aVec.z * aVec.z)
        )
        let yZeroFloor = SIMD3<Float>(
            2.0 * sqrt(0.375 + sigmaG2.x) * 1.0001,
            2.0 * sqrt(0.375 + sigmaG2.y) * 1.0001,
            2.0 * sqrt(0.375 + sigmaG2.z) * 1.0001
        )

        let lumaNorm = Float(sanitized.luminanceStrength / 100.0)
        let chromaNorm = Float(sanitized.chromaStrength / 100.0)
        let detailNorm = Float(sanitized.detailPreservation / 100.0)

        let tISO = Self.smoothstep(
            edge0: log2(100.0),
            edge1: log2(6400.0),
            x: log2(Float(effectiveISO))
        )
        let isoLumaScale: Float = 0.25 + (1.40 - 0.25) * tISO
        let detailScale: Float = 1.35 + (0.55 - 1.35) * detailNorm
        let lumaLambda: Float = lumaNorm > 0.0 ? (lumaNorm * isoLumaScale * detailScale) : 0.0
        let chromaLambda: Float = chromaNorm > 0.0 ? (2.0 * chromaNorm) : 0.0

        // Rec.2020 Stage 2A receives WB- and color-matrix-transformed linear pixels, whereas
        // darktable noiseprofiles.json (a, b) is calibrated on pre-WB raw sensor ADU.
        // Keep GAT/IGAT `a` close to raw scale (1.5x/2.5x) to avoid IGAT DC shift in deep shadows,
        // and account for Rec.2020 variance amplification in the wavelet band variance `sb2`.
        let aChromaVec = aVec * 2.5
        let aLumaVec = aVec * 1.5

        // Output MUST be ARC-owned (never pool-backed) across LinearDenoiseStage protocol boundary.
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        outDesc.storageMode = .private
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let outputTexture = device.makeTexture(descriptor: outDesc) else {
            throw ProfiledDenoiseError.outputTextureAllocationFailed
        }

        // Strip/tile-chunked denoising when > 3 MP: halo = 128 px exceeds max 5-scale wavelet radius (78 px),
        // making interior strip pixels bit-for-bit identical to untiled execution while slashing scratch pool ~4-5x.
        let halo = 128
        let useTiling = !forceUntiled && (width * height > 3_000_000) && (height > 512)
        let stripRanges: [(y0: Int, y1: Int)]
        let maxTileHeight: Int
        if useTiling {
            let targetStripH = 512
            let stripCount = max(2, (height + targetStripH - 1) / targetStripH)
            let baseStripH = (height + stripCount - 1) / stripCount
            var ranges: [(y0: Int, y1: Int)] = []
            ranges.reserveCapacity(stripCount)
            var y = 0
            while y < height {
                let yEnd = min(height, y + baseStripH)
                ranges.append((y0: y, y1: yEnd))
                y = yEnd
            }
            stripRanges = ranges
            maxTileHeight = ranges.map { range in
                min(height, range.y1 + halo) - max(0, range.y0 - halo)
            }.max() ?? height
        } else {
            stripRanges = [(y0: 0, y1: height)]
            maxTileHeight = height
        }

        try autoreleasepool {
            // Intermediate GAT/À-trous scratch textures MUST use .rgba32Float to avoid Float16 banding.
            var curTex = try texturePool.acquire(width: width, height: maxTileHeight, pixelFormat: .rgba32Float)
            let tmpTex = try texturePool.acquire(width: width, height: maxTileHeight, pixelFormat: .rgba32Float)
            var coarseTex = try texturePool.acquire(width: width, height: maxTileHeight, pixelFormat: .rgba32Float)
            let detailTex = try texturePool.acquire(width: width, height: maxTileHeight, pixelFormat: .rgba32Float)
            var accumTex = try texturePool.acquire(width: width, height: maxTileHeight, pixelFormat: .rgba32Float)
            var retained: [SendableMTLTexture] = [curTex, tmpTex, coarseTex, detailTex, accumTex]
            let chromaTmp: SendableMTLTexture?
            if chromaLambda > 0.0 && lumaLambda > 0.0 {
                let cTmp = try texturePool.acquire(width: width, height: maxTileHeight, pixelFormat: .rgba16Float)
                retained.append(cTmp)
                chromaTmp = cTmp
            } else {
                chromaTmp = nil
            }

            let gatPSO = try shaderLibrary.computePipelineState(for: "profiled_denoise_gat_opponent_kernel")
            let hPSO = try shaderLibrary.computePipelineState(for: "profiled_denoise_atrous_h_kernel")
            let vPSO = try shaderLibrary.computePipelineState(for: "profiled_denoise_atrous_v_detail_kernel")
            let shrinkPSO = try shaderLibrary.computePipelineState(for: "profiled_denoise_shrink_accum_kernel")
            let igatPSO = try shaderLibrary.computePipelineState(for: "profiled_denoise_igat_rgb_kernel")

            let tg = MTLSize(width: 16, height: 16, depth: 1)

            for range in stripRanges {
                let srcY0 = useTiling ? max(0, range.y0 - halo) : 0
                let srcY1 = useTiling ? min(height, range.y1 + halo) : height
                let tileH = srcY1 - srcY0
                let writeOffsetY = range.y0 - srcY0
                let validHeight = range.y1 - range.y0
                let grid = MTLSize(width: (width + 15) / 16, height: (tileH + 15) / 16, depth: 1)

                guard let cb = commandQueue.makeCommandBuffer(),
                      let enc = cb.makeComputeCommandEncoder() else {
                    throw ProfiledDenoiseError.commandEncodingFailed
                }

                func makeUniforms(isChromaPass: Bool) -> ProfiledDenoiseUniforms {
                    let passA = isChromaPass ? aChromaVec : aLumaVec
                    return ProfiledDenoiseUniforms(
                        width: UInt32(width),
                        height: UInt32(tileH),
                        scaleIndex: 0,
                        stepSize: 1,
                        aCoeffs: SIMD4<Float>(passA, Self.b3SplineBandVariances[0]),
                        sigmaG2: SIMD4<Float>(sigmaG2, 0),
                        yZeroFloor: SIMD4<Float>(yZeroFloor, 0),
                        lumaLambda: lumaLambda,
                        chromaLambda: chromaLambda,
                        pad0: isChromaPass ? 1.0 : 0.0,
                        pad1: 0.0,
                        srcOffsetY: UInt32(srcY0),
                        writeOffsetY: UInt32(writeOffsetY),
                        validHeight: UInt32(validHeight),
                        flags: 0
                    )
                }

                func encodeWaveletPass(isChromaPass: Bool) {
                    var u = makeUniforms(isChromaPass: isChromaPass)

                    // Pass 1: Linear -> per-channel GAT + zero accumTex
                    enc.setComputePipelineState(gatPSO)
                    enc.setTexture(inputTexture, index: 0)
                    enc.setTexture(curTex.texture, index: 1)
                    enc.setTexture(accumTex.texture, index: 2)
                    enc.setBytes(&u, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

                    // Pass 2: Separable À-trous B3-spline decomposition & BayesShrink accumulation
                    // Chroma uses 5 scales (up to step=16) to suppress demosaiced color blotches; luma uses 4 scales.
                    let scaleCount = isChromaPass ? 5 : 4
                    for scale in 0..<scaleCount {
                        u.scaleIndex = UInt32(scale)
                        u.stepSize = UInt32(1 << scale)
                        u.aCoeffs.w = Self.b3SplineBandVariances[scale]

                        enc.setComputePipelineState(hPSO)
                        enc.setTexture(curTex.texture, index: 0)
                        enc.setTexture(tmpTex.texture, index: 1)
                        enc.setBytes(&u, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

                        enc.setComputePipelineState(vPSO)
                        enc.setTexture(curTex.texture, index: 0)
                        enc.setTexture(tmpTex.texture, index: 1)
                        enc.setTexture(coarseTex.texture, index: 2)
                        enc.setTexture(detailTex.texture, index: 3)
                        enc.setBytes(&u, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

                        enc.setComputePipelineState(shrinkPSO)
                        enc.setTexture(detailTex.texture, index: 0)
                        enc.setTexture(accumTex.texture, index: 1)
                        enc.setTexture(curTex.texture, index: 2)
                        enc.setBytes(&u, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

                        swap(&accumTex, &curTex)
                        swap(&curTex, &coarseTex)
                    }
                }

                if let chromaTmp {
                    encodeWaveletPass(isChromaPass: true)
                    var igatChroma = makeUniforms(isChromaPass: true)
                    igatChroma.pad1 = 0.0
                    igatChroma.flags = 0 // Write full tile to tile-sized chromaTmp
                    enc.setComputePipelineState(igatPSO)
                    enc.setTexture(accumTex.texture, index: 0)
                    enc.setTexture(curTex.texture, index: 1)
                    enc.setTexture(inputTexture, index: 2)
                    enc.setTexture(chromaTmp.texture, index: 3)
                    enc.setTexture(inputTexture, index: 4)
                    enc.setBytes(&igatChroma, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

                    encodeWaveletPass(isChromaPass: false)
                    var igatLuma = makeUniforms(isChromaPass: false)
                    igatLuma.pad1 = 1.0
                    igatLuma.flags = 2 // ref = tile-sized chromaTmp (bit 0 = 0), out = full-frame (bit 1 = 1)
                    enc.setComputePipelineState(igatPSO)
                    enc.setTexture(accumTex.texture, index: 0)
                    enc.setTexture(curTex.texture, index: 1)
                    enc.setTexture(chromaTmp.texture, index: 2)
                    enc.setTexture(outputTexture, index: 3)
                    enc.setTexture(inputTexture, index: 4)
                    enc.setBytes(&igatLuma, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                } else if chromaLambda > 0.0 {
                    encodeWaveletPass(isChromaPass: true)
                    var igatChroma = makeUniforms(isChromaPass: true)
                    igatChroma.pad1 = 2.0
                    igatChroma.flags = 3 // ref = full-frame inputTexture (bit 0 = 1), out = full-frame (bit 1 = 1)
                    enc.setComputePipelineState(igatPSO)
                    enc.setTexture(accumTex.texture, index: 0)
                    enc.setTexture(curTex.texture, index: 1)
                    enc.setTexture(inputTexture, index: 2)
                    enc.setTexture(outputTexture, index: 3)
                    enc.setTexture(inputTexture, index: 4)
                    enc.setBytes(&igatChroma, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                } else {
                    encodeWaveletPass(isChromaPass: false)
                    var igatLuma = makeUniforms(isChromaPass: false)
                    igatLuma.pad1 = 1.0
                    igatLuma.flags = 3 // ref = full-frame inputTexture (bit 0 = 1), out = full-frame (bit 1 = 1)
                    enc.setComputePipelineState(igatPSO)
                    enc.setTexture(accumTex.texture, index: 0)
                    enc.setTexture(curTex.texture, index: 1)
                    enc.setTexture(inputTexture, index: 2)
                    enc.setTexture(outputTexture, index: 3)
                    enc.setTexture(inputTexture, index: 4)
                    enc.setBytes(&igatLuma, length: MemoryLayout<ProfiledDenoiseUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                }

                enc.endEncoding()
                let kept = retained
                cb.addCompletedHandler { _ in _ = kept }
                cb.commit()
                cb.waitUntilCompleted()
                if let err = cb.error {
                    throw ProfiledDenoiseError.gpuExecutionFailed(String(describing: err))
                }
            }
        }

        return outputTexture
    }

    private static func resolveCoefficients(
        iso: Int,
        noiseProfile: SensorNoiseProfile?
    ) -> SensorNoiseProfile.InterpolatedCoefficients {
        if let profile = noiseProfile, let c = profile.interpolatedParameters(forISO: iso) {
            return c
        }
        if let fallback = SensorNoiseProfileLoader.shared
            .profileWithSonyFallback(forMake: "Sony", model: "ILCE-7CM2")?
            .interpolatedParameters(forISO: iso) {
            return fallback
        }
        let scale = Double(iso) / 100.0
        return SensorNoiseProfile.InterpolatedCoefficients(
            iso: iso,
            a: SIMD3<Double>(2.5e-6 * scale, 1.0e-6 * scale, 1.8e-6 * scale),
            b: SIMD3<Double>(1.0e-9 * scale, 1.0e-9 * scale, 1.2e-9 * scale)
        )
    }

    private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 1e-6), 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}
