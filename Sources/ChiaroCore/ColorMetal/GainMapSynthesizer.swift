import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd

public enum GainMapSynthesizerError: Error, Sendable, CustomStringConvertible {
    case invalidDimensions(width: Int, height: Int)
    case dimensionMismatch(expected: PixelDimensions, actual: PixelDimensions)
    case jpegDecodeFailed
    case commandBufferCreationFailed
    case commandEncodingFailed
    case bufferAllocationFailed
    case gpuExecutionFailed(String)

    public var description: String {
        switch self {
        case let .invalidDimensions(w, h):
            return "Invalid gain map input dimensions: \(w)x\(h)"
        case let .dimensionMismatch(expected, actual):
            return "Gain map input dimension mismatch: expected \(expected.width)x\(expected.height), got \(actual.width)x\(actual.height)"
        case .jpegDecodeFailed:
            return "Failed to decode compressed SDR JPEG for closed-loop gain map compensation"
        case .commandBufferCreationFailed:
            return "Failed to create MTLCommandBuffer in GainMapSynthesizer"
        case .commandEncodingFailed:
            return "Failed to create MTLComputeCommandEncoder in GainMapSynthesizer"
        case .bufferAllocationFailed:
            return "Failed to allocate Metal buffer in GainMapSynthesizer"
        case let .gpuExecutionFailed(msg):
            return "GainMapSynthesizer GPU execution failed: \(msg)"
        }
    }
}

private struct GainMapLogUniforms {
    var kOffset: Float
    var midtoneAnchorP: Float
    var deadzoneScale: Float
    var isSRGB: UInt32
    var isMono: UInt32
    var width: UInt32
    var height: UInt32
    var pad0: UInt32
}

private struct GainMapMinMaxUniforms {
    var channelCount: UInt32
    var width: UInt32
    var height: UInt32
    var pad0: UInt32
}

private struct GainMapHistUniforms {
    var rawMin: SIMD4<Float>
    var rawMax: SIMD4<Float>
    var channelCount: UInt32
    var width: UInt32
    var height: UInt32
    var pad0: UInt32
}

private struct GainMapQuantizeUniforms {
    var gMin: SIMD4<Float>
    var gMax: SIMD4<Float>
    var gamma: SIMD4<Float>
    var isMono: UInt32
    var width: UInt32
    var height: UInt32
    var enableDither: UInt32
}

/// GPU ISO/IEC 21496-1:2025 Gain Map Synthesizer supporting:
/// - Symmetric `1/2` anti-halo linear downsampling or `1:1` full resolution
/// - Symmetric offset `k = 1/64 = 0.015625`
/// - Smooth midtone threshold below `P`
/// - 2-pass GPU min/max + 4096-bin `0.01%–99.99%` quantile rejection & flatness guard
/// - Legacy Apple iOS 14–17 bounds lock (`[0, log2(H)]`)
/// - Zero-anchor refinement & 64×64 Void-and-Cluster Blue-Noise TPDF dithered quantization
/// - Closed-loop compressed SDR JPEG (`\hat{B}`) re-synthesis
public final class GainMapSynthesizer: @unchecked Sendable {
    public let device: any MTLDevice
    public let shaderLibrary: MetalShaderLibrary
    public let pool: MTLHeapTexturePool
    internal let blueNoiseBuffer: any MTLBuffer

    public init(device: any MTLDevice, shaderLibrary: MetalShaderLibrary, pool: MTLHeapTexturePool) throws {
        self.device = device
        self.shaderLibrary = shaderLibrary
        self.pool = pool

        let floats = Self.blueNoise64x64Ranks.map { (Float($0) + 0.5) / 4096.0 }
        guard let buf = device.makeBuffer(
            bytes: floats,
            length: floats.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw GainMapSynthesizerError.bufferAllocationFailed
        }
        self.blueNoiseBuffer = buf
    }

    public func synthesize(
        commandQueue: any MTLCommandQueue,
        sdrLinearTexture: SendableMTLTexture,
        hdrLinearTexture: SendableMTLTexture,
        baseColorSpace: BaseColorSpace,
        targetHeadroom: HeadroomStops,
        midtoneAnchorP: Double,
        gamma: Double,
        channels: GainMapChannels,
        resolution: GainMapResolution,
        lockLegacyBounds: Bool,
        kOffset: Double = GainMapMetadata.symmetricOffset,
        deadzoneScale: Double = 0.003,
        enableDither: Bool = true
    ) throws -> GainMapResult {
        try autoreleasepool {
            let maxDim = MTLHeapTexturePool.maxTextureDimension(for: device)
            let baseW = sdrLinearTexture.texture.width
            let baseH = sdrLinearTexture.texture.height
            guard baseW > 0, baseH > 0, baseW <= maxDim, baseH <= maxDim else {
                throw GainMapSynthesizerError.invalidDimensions(width: baseW, height: baseH)
            }
            let hdrW = hdrLinearTexture.texture.width
            let hdrH = hdrLinearTexture.texture.height
            guard hdrW > 0, hdrH > 0, hdrW <= maxDim, hdrH <= maxDim else {
                throw GainMapSynthesizerError.invalidDimensions(width: hdrW, height: hdrH)
            }
            guard hdrW == baseW, hdrH == baseH else {
                throw GainMapSynthesizerError.dimensionMismatch(
                    expected: PixelDimensions(width: baseW, height: baseH),
                    actual: PixelDimensions(width: hdrW, height: hdrH)
                )
            }

            let safeTargetHeadroom = HeadroomStops(
                log2Value: targetHeadroom.log2Value.isFinite ? max(targetHeadroom.log2Value, 0.0) : 0.0
            )
            let safeGamma = gamma.isFinite ? min(max(gamma, 0.25), 4.0) : 1.0
            let safeMidtoneAnchorP = midtoneAnchorP.isFinite ? min(max(midtoneAnchorP, 0.65), 0.95) : 0.80
            let safeDeadzoneScale = deadzoneScale.isFinite ? min(max(deadzoneScale, 0.0), 1.0) : 0.0
            let safeKOffset = (kOffset.isFinite && kOffset >= 0.0)
                ? min(max(kOffset, 1e-6), 10.0)
                : GainMapMetadata.symmetricOffset

            let gmW: Int
            let gmH: Int
            switch resolution {
            case .full:
                gmW = baseW
                gmH = baseH
            case .half:
                gmW = max(2, (baseW + 1) / 2)
                gmH = max(2, (baseH + 1) / 2)
            }

            let needsDownsample = (resolution == .half) && !(gmW == baseW && gmH == baseH)
            let effectiveSdrTex: SendableMTLTexture
            let effectiveHdrTex: SendableMTLTexture
            if needsDownsample {
                effectiveSdrTex = try pool.acquire(width: gmW, height: gmH, pixelFormat: .rgba16Float)
                effectiveHdrTex = try pool.acquire(width: gmW, height: gmH, pixelFormat: .rgba16Float)
            } else {
                effectiveSdrTex = sdrLinearTexture
                effectiveHdrTex = hdrLinearTexture
            }

            let logGainTex = try pool.acquire(width: gmW, height: gmH, pixelFormat: .rgba16Float)
            let channelCount = (channels == .mono1ch) ? 1 : 3

            // CB1: optional 2x anti-halo downsample + log-ratio + min/max reduction
            let tgW = 16
            let tgH = 16
            let gridW = (gmW + tgW - 1) / tgW
            let gridH = (gmH + tgH - 1) / tgH
            let groupCount = max(1, gridW * gridH)
            let minMaxBufLen = groupCount * 8 * MemoryLayout<Float>.stride
            guard let minMaxBuf = device.makeBuffer(length: minMaxBufLen, options: .storageModeShared) else {
                throw GainMapSynthesizerError.bufferAllocationFailed
            }

            do {
                guard let cb1 = commandQueue.makeCommandBuffer() else {
                    throw GainMapSynthesizerError.commandBufferCreationFailed
                }

                if needsDownsample {
                    let downPSO = try shaderLibrary.computePipelineState(for: "downsample_linear_antihalo_2x_kernel")
                    guard let enc = cb1.makeComputeCommandEncoder() else {
                        throw GainMapSynthesizerError.commandEncodingFailed
                    }
                    enc.setComputePipelineState(downPSO)
                    enc.setTexture(sdrLinearTexture.texture, index: 0)
                    enc.setTexture(effectiveSdrTex.texture, index: 1)
                    enc.dispatchThreadgroups(
                        MTLSize(width: gridW, height: gridH, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
                    )

                    enc.setTexture(hdrLinearTexture.texture, index: 0)
                    enc.setTexture(effectiveHdrTex.texture, index: 1)
                    enc.dispatchThreadgroups(
                        MTLSize(width: gridW, height: gridH, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
                    )
                    enc.endEncoding()
                }

                do {
                    let logPSO = try shaderLibrary.computePipelineState(for: "gainmap_log_ratio_kernel")
                    guard let enc = cb1.makeComputeCommandEncoder() else {
                        throw GainMapSynthesizerError.commandEncodingFailed
                    }
                    var u = GainMapLogUniforms(
                        kOffset: Float(safeKOffset),
                        midtoneAnchorP: Float(safeMidtoneAnchorP),
                        deadzoneScale: Float(safeDeadzoneScale),
                        isSRGB: baseColorSpace == .srgb ? 1 : 0,
                        isMono: channels == .mono1ch ? 1 : 0,
                        width: UInt32(gmW),
                        height: UInt32(gmH),
                        pad0: 0
                    )
                    enc.setComputePipelineState(logPSO)
                    enc.setTexture(effectiveSdrTex.texture, index: 0)
                    enc.setTexture(effectiveHdrTex.texture, index: 1)
                    enc.setTexture(logGainTex.texture, index: 2)
                    enc.setBytes(&u, length: MemoryLayout<GainMapLogUniforms>.stride, index: 0)
                    enc.dispatchThreadgroups(
                        MTLSize(width: gridW, height: gridH, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
                    )
                    enc.endEncoding()
                }

                do {
                    let mmPSO = try shaderLibrary.computePipelineState(for: "gainmap_minmax_reduce_kernel")
                    guard let enc = cb1.makeComputeCommandEncoder() else {
                        throw GainMapSynthesizerError.commandEncodingFailed
                    }
                    var u = GainMapMinMaxUniforms(
                        channelCount: UInt32(channelCount),
                        width: UInt32(gmW),
                        height: UInt32(gmH),
                        pad0: 0
                    )
                    enc.setComputePipelineState(mmPSO)
                    enc.setTexture(logGainTex.texture, index: 0)
                    enc.setBuffer(minMaxBuf, offset: 0, index: 0)
                    enc.setBytes(&u, length: MemoryLayout<GainMapMinMaxUniforms>.stride, index: 1)
                    enc.dispatchThreadgroups(
                        MTLSize(width: gridW, height: gridH, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
                    )
                    enc.endEncoding()
                }

                let retainedCB1 = [sdrLinearTexture, hdrLinearTexture, effectiveSdrTex, effectiveHdrTex, logGainTex]
                cb1.addCompletedHandler { _ in _ = retainedCB1 }
                cb1.commit()
                cb1.waitUntilCompleted()
                if let err = cb1.error {
                    throw GainMapSynthesizerError.gpuExecutionFailed(String(describing: err))
                }
            }

            // CPU reduction of per-threadgroup min/max
            let mmPtr = minMaxBuf.contents().bindMemory(to: Float.self, capacity: groupCount * 8)
            var rawMin = [Float](repeating: Float.greatestFiniteMagnitude, count: 3)
            var rawMax = [Float](repeating: -Float.greatestFiniteMagnitude, count: 3)
            for g in 0..<groupCount {
                let base = g * 8
                for c in 0..<channelCount {
                    let mn = mmPtr[base + c]
                    let mx = mmPtr[base + 4 + c]
                    if mn.isFinite && mn < rawMin[c] { rawMin[c] = mn }
                    if mx.isFinite && mx > rawMax[c] { rawMax[c] = mx }
                }
            }
            for c in 0..<channelCount {
                if !rawMin[c].isFinite || !rawMax[c].isFinite || rawMin[c] > rawMax[c] {
                    rawMin[c] = 0.0
                    rawMax[c] = 0.0
                }
            }

            var gMin = [Double](repeating: 0.0, count: channelCount)
            var gMax = [Double](repeating: 0.0, count: channelCount)

            if lockLegacyBounds {
                let maxStops = safeTargetHeadroom.log2Value
                if !(0..<channelCount).contains(where: { rawMax[$0] > 1e-5 }) || maxStops <= 1e-5 {
                    for c in 0..<channelCount { gMin[c] = 0.0; gMax[c] = 0.0 }
                } else {
                    for c in 0..<channelCount { gMin[c] = 0.0; gMax[c] = maxStops }
                }
            } else {
                let anySpan = (0..<channelCount).contains { (rawMax[$0] - rawMin[$0]) >= 1e-5 }
                if anySpan {
                    let binCount = 4096
                    let histBytes = binCount * 3 * MemoryLayout<UInt32>.stride
                    guard let histBuf = device.makeBuffer(length: histBytes, options: .storageModeShared) else {
                        throw GainMapSynthesizerError.bufferAllocationFailed
                    }
                    memset(histBuf.contents(), 0, histBytes)

                    guard let cbHist = commandQueue.makeCommandBuffer(),
                          let enc = cbHist.makeComputeCommandEncoder() else {
                        throw GainMapSynthesizerError.commandEncodingFailed
                    }
                    let histPSO = try shaderLibrary.computePipelineState(for: "gainmap_histogram_kernel")
                    var hu = GainMapHistUniforms(
                        rawMin: SIMD4<Float>(rawMin[0], rawMin[1], rawMin[2], 0),
                        rawMax: SIMD4<Float>(rawMax[0], rawMax[1], rawMax[2], 0),
                        channelCount: UInt32(channelCount),
                        width: UInt32(gmW),
                        height: UInt32(gmH),
                        pad0: 0
                    )
                    enc.setComputePipelineState(histPSO)
                    enc.setTexture(logGainTex.texture, index: 0)
                    enc.setBuffer(histBuf, offset: 0, index: 0)
                    enc.setBytes(&hu, length: MemoryLayout<GainMapHistUniforms>.stride, index: 1)
                    enc.dispatchThreadgroups(
                        MTLSize(width: gridW, height: gridH, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
                    )
                    enc.endEncoding()

                    let retainedHist = [logGainTex]
                    cbHist.addCompletedHandler { _ in _ = retainedHist }
                    cbHist.commit()
                    cbHist.waitUntilCompleted()
                    if let err = cbHist.error {
                        throw GainMapSynthesizerError.gpuExecutionFailed(String(describing: err))
                    }

                    let hPtr = histBuf.contents().bindMemory(to: UInt32.self, capacity: binCount * 3)
                    let totalPixels = gmW * gmH
                    let lowTarget = Int(floor(0.0001 * Double(totalPixels)))
                    let highTarget = max(lowTarget + 1, Int(ceil(0.9999 * Double(totalPixels))))

                    for c in 0..<channelCount {
                        let span = Double(rawMax[c] - rawMin[c])
                        if span < 1e-5 {
                            gMin[c] = 0.0
                            gMax[c] = 0.0
                            continue
                        }
                        let chOffset = c * binCount
                        var cumulative = 0
                        var lowBin = 0
                        var highBin = binCount - 1
                        var foundLow = false
                        for b in 0..<binCount {
                            cumulative += Int(hPtr[chOffset + b])
                            if !foundLow && cumulative > lowTarget {
                                lowBin = b
                                foundLow = true
                            }
                            if cumulative >= highTarget {
                                highBin = b
                                break
                            }
                        }

                        var mn = Double(rawMin[c]) + (Double(lowBin) / Double(binCount)) * span
                        let mx = Double(rawMin[c]) + (Double(highBin + 1) / Double(binCount)) * span
                        if mx - mn < 1e-5 {
                            gMin[c] = 0.0
                            gMax[c] = 0.0
                            continue
                        }

                        // Zero-anchor refinement: snap G = 0.0 to an exact quantized integer when straddling 0.
                        if mn < 0.0 && mx > 0.0 {
                            let qSpan = mx - mn
                            let mZeroLin = -mn / qSpan
                            let mZeroEnc = pow(mZeroLin, safeGamma)
                            let codeZero = 255.0 * mZeroEnc
                            if codeZero < 0.5 && abs(mn) <= 0.025 {
                                mn = 0.0
                            } else {
                                let qZero = min(max(ceil(codeZero), 1.0), 254.0)
                                let mTarget = pow(qZero / 255.0, 1.0 / safeGamma)
                                if mTarget > 0.0 && mTarget < 1.0 {
                                    let mnNew = -(mTarget / (1.0 - mTarget)) * mx
                                    let maxAllowedShift = max((1.5 / 255.0) * qSpan / min(safeGamma, 1.0), 0.05 * qSpan)
                                    if mnNew <= mn && abs(mnNew - mn) <= maxAllowedShift {
                                        mn = mnNew
                                    }
                                }
                            }
                        }

                        gMin[c] = mn
                        gMax[c] = mx
                    }
                }
            }

            for c in 0..<channelCount {
                if !gMin[c].isFinite || !gMax[c].isFinite || gMin[c] > gMax[c] {
                    gMin[c] = 0.0
                    gMax[c] = 0.0
                }
            }

            // Pass C: Gamma encode + 64x64 Void-and-Cluster Blue-Noise TPDF dither -> L008 or BGRA8
            let bytesPerPixel = (channels == .mono1ch) ? 1 : 4
            let bytesPerRow = gmW * bytesPerPixel
            let outByteCount = bytesPerRow * gmH
            guard let outBuf = device.makeBuffer(length: outByteCount, options: .storageModeShared) else {
                throw GainMapSynthesizerError.bufferAllocationFailed
            }

            do {
                guard let cbQ = commandQueue.makeCommandBuffer(),
                      let enc = cbQ.makeComputeCommandEncoder() else {
                    throw GainMapSynthesizerError.commandEncodingFailed
                }
                let qPSO = try shaderLibrary.computePipelineState(for: "gainmap_quantize_dither_kernel")
                let min4 = SIMD4<Float>(
                    Float(gMin[0]),
                    Float(channelCount > 1 ? gMin[1] : gMin[0]),
                    Float(channelCount > 2 ? gMin[2] : gMin[0]),
                    0
                )
                let max4 = SIMD4<Float>(
                    Float(gMax[0]),
                    Float(channelCount > 1 ? gMax[1] : gMax[0]),
                    Float(channelCount > 2 ? gMax[2] : gMax[0]),
                    0
                )
                let gam4 = SIMD4<Float>(repeating: Float(safeGamma))
                var qu = GainMapQuantizeUniforms(
                    gMin: min4,
                    gMax: max4,
                    gamma: gam4,
                    isMono: channels == .mono1ch ? 1 : 0,
                    width: UInt32(gmW),
                    height: UInt32(gmH),
                    enableDither: enableDither ? 1 : 0
                )
                enc.setComputePipelineState(qPSO)
                enc.setTexture(logGainTex.texture, index: 0)
                enc.setBuffer(outBuf, offset: 0, index: 0)
                enc.setBuffer(blueNoiseBuffer, offset: 0, index: 1)
                enc.setBytes(&qu, length: MemoryLayout<GainMapQuantizeUniforms>.stride, index: 2)
                enc.dispatchThreadgroups(
                    MTLSize(width: gridW, height: gridH, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
                )
                enc.endEncoding()

                let retainedQ = [logGainTex]
                cbQ.addCompletedHandler { _ in _ = retainedQ }
                cbQ.commit()
                cbQ.waitUntilCompleted()
                if let err = cbQ.error {
                    throw GainMapSynthesizerError.gpuExecutionFailed(String(describing: err))
                }
            }

            let outData = Data(bytes: outBuf.contents(), count: outByteCount)
            let buffer = GainMapBuffer(
                width: gmW,
                height: gmH,
                channels: channels,
                bytesPerRow: bytesPerRow,
                data: outData
            )
            let gammaArr = Array(repeating: safeGamma, count: channelCount)
            let offsetArr = Array(repeating: safeKOffset, count: channelCount)
            let metadata = GainMapMetadata(
                gainMapMin: gMin,
                gainMapMax: gMax,
                gamma: gammaArr,
                baseOffset: offsetArr,
                altOffset: offsetArr,
                baseHeadroom: .sdr,
                alternateHeadroom: safeTargetHeadroom,
                useBaseColorSpace: true
            )
            return GainMapResult(buffer: buffer, metadata: metadata)
        }
    }

    public func recomputeGainMapCompensated(
        commandQueue: any MTLCommandQueue,
        hdrTexture: SendableMTLTexture,
        compressedSDRJPEGData: Data,
        metadata: GainMapMetadata,
        gamma: Double,
        channels: GainMapChannels,
        resolution: GainMapResolution,
        midtoneAnchorP: Double = 0.80,
        baseColorSpace: BaseColorSpace? = nil
    ) throws -> GainMapResult {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(compressedSDRJPEGData as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw GainMapSynthesizerError.jpegDecodeFailed
            }

            let maxDim = MTLHeapTexturePool.maxTextureDimension(for: device)
            let w = cgImage.width
            let h = cgImage.height
            guard w > 0, h > 0, w <= maxDim, h <= maxDim else {
                throw GainMapSynthesizerError.invalidDimensions(width: w, height: h)
            }
            guard w == hdrTexture.texture.width, h == hdrTexture.texture.height else {
                throw GainMapSynthesizerError.dimensionMismatch(
                    expected: PixelDimensions(width: hdrTexture.texture.width, height: hdrTexture.texture.height),
                    actual: PixelDimensions(width: w, height: h)
                )
            }

            let resolvedBaseColorSpace: BaseColorSpace = baseColorSpace
                ?? ((cgImage.colorSpace?.name == CGColorSpace.sRGB) ? .srgb : .displayP3)
            let fallbackCSName: CFString = (resolvedBaseColorSpace == .srgb) ? CGColorSpace.sRGB : CGColorSpace.displayP3
            let nativeCS = cgImage.colorSpace ?? CGColorSpace(name: fallbackCSName) ?? CGColorSpaceCreateDeviceRGB()
            var rgbaBytes = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(
                data: &rgbaBytes,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: nativeCS,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                throw GainMapSynthesizerError.jpegDecodeFailed
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

            let srgbDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: w,
                height: h,
                mipmapped: false
            )
            srgbDesc.storageMode = .shared
            srgbDesc.usage = .shaderRead
            guard let srgbTex = device.makeTexture(descriptor: srgbDesc) else {
                throw GainMapSynthesizerError.bufferAllocationFailed
            }
            rgbaBytes.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    srgbTex.replace(
                        region: MTLRegionMake2D(0, 0, w, h),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: w * 4
                    )
                }
            }

            let bHatLinear = try pool.acquire(width: w, height: h, pixelFormat: .rgba16Float)
            do {
                let eotfPSO = try shaderLibrary.computePipelineState(for: "srgb_eotf_to_linear_kernel")
                guard let cb = commandQueue.makeCommandBuffer(),
                      let enc = cb.makeComputeCommandEncoder() else {
                    throw GainMapSynthesizerError.commandEncodingFailed
                }
                enc.setComputePipelineState(eotfPSO)
                enc.setTexture(srgbTex, index: 0)
                enc.setTexture(bHatLinear.texture, index: 1)
                let tg = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                enc.endEncoding()

                let retained = [bHatLinear]
                cb.addCompletedHandler { _ in _ = retained }
                cb.commit()
                cb.waitUntilCompleted()
                if let err = cb.error {
                    throw GainMapSynthesizerError.gpuExecutionFailed(String(describing: err))
                }
            }

            let rawK = metadata.baseOffset.first ?? GainMapMetadata.symmetricOffset
            let safeK = (rawK.isFinite && rawK >= 0.0) ? min(max(rawK, 1e-6), 10.0) : GainMapMetadata.symmetricOffset
            let safeBaseHeadroom = HeadroomStops(
                log2Value: metadata.baseHeadroom.log2Value.isFinite ? max(metadata.baseHeadroom.log2Value, 0.0) : 0.0
            )
            let safeTargetHeadroom = HeadroomStops(
                log2Value: metadata.alternateHeadroom.log2Value.isFinite ? max(metadata.alternateHeadroom.log2Value, 0.0) : 0.0
            )
            var result = try synthesize(
                commandQueue: commandQueue,
                sdrLinearTexture: bHatLinear,
                hdrLinearTexture: hdrTexture,
                baseColorSpace: resolvedBaseColorSpace,
                targetHeadroom: safeTargetHeadroom,
                midtoneAnchorP: midtoneAnchorP,
                gamma: gamma,
                channels: channels,
                resolution: resolution,
                lockLegacyBounds: false,
                kOffset: safeK,
                deadzoneScale: 0.0,
                enableDither: true
            )
            result.metadata.baseHeadroom = safeBaseHeadroom
            result.metadata.alternateHeadroom = safeTargetHeadroom
            result.metadata.useBaseColorSpace = metadata.useBaseColorSpace
            return result
        }
    }

    // 64x64 Void-and-Cluster Blue Noise rank table (values 0...4095)
    private static let blueNoise64x64Ranks: [UInt16] = [
        1468, 2216, 484, 3971, 2620, 320, 2934, 1570, 634, 1988, 1285, 3686, 601, 1633, 1084, 2935,
        3663, 744, 2778, 1745, 541, 3293, 2902, 1206, 3394, 13, 2415, 1675, 2169, 559, 1759, 3923,
        122, 1912, 2632, 3809, 2820, 1630, 3050, 15, 3632, 572, 2469, 3324, 1316, 56, 3589, 2755,
        809, 3952, 555, 2856, 2316, 1590, 3140, 611, 1718, 879, 265, 1352, 3130, 117, 1624, 386,
        818, 3539, 1863, 1386, 858, 3494, 3803, 963, 3320, 194, 2233, 942, 2887, 3988, 2339, 529,
        1913, 1237, 4073, 2274, 3744, 1946, 915, 3982, 2732, 1872, 2996, 1033, 3486, 1297, 2679, 2243,
        1442, 3665, 1038, 213, 3410, 748, 3905, 2324, 1877, 2792, 1657, 836, 2946, 3934, 2030, 1392,
        3038, 1813, 1055, 3747, 1923, 3508, 46, 2502, 4025, 3230, 2001, 3784, 988, 2176, 2828, 4074,
        2521, 137, 2754, 3356, 2351, 71, 2133, 2602, 1696, 2975, 3884, 2534, 1782, 0, 1393, 3254,
        2593, 3442, 340, 991, 1420, 123, 2463, 1586, 703, 3618, 471, 4089, 209, 3104, 897, 372,
        3167, 675, 2475, 1786, 2257, 1454, 1158, 470, 3448, 1032, 3829, 348, 1897, 1047, 562, 2376,
        270, 3485, 2647, 201, 910, 1284, 2788, 2049, 1412, 359, 2553, 2900, 502, 3548, 1151, 1978,
        1332, 3764, 1029, 590, 3042, 1776, 1337, 466, 3546, 726, 1489, 421, 3313, 2744, 3760, 949,
        181, 1579, 2405, 3022, 3373, 2702, 3679, 304, 2260, 1283, 2609, 2062, 1508, 2323, 3793, 1931,
        2775, 3380, 1291, 4016, 338, 3219, 2496, 2987, 1541, 179, 3097, 2276, 3489, 2695, 3220, 3831,
        1240, 2119, 1471, 3168, 2234, 3833, 694, 3397, 1045, 3639, 799, 1539, 2320, 1771, 646, 3246,
        2298, 2999, 1636, 2101, 3640, 1078, 4059, 2802, 2265, 1108, 3645, 2100, 1199, 706, 1938, 2262,
        3082, 3876, 762, 2044, 501, 1698, 834, 3054, 3447, 1784, 870, 3345, 2823, 670, 3429, 1154,
        1625, 35, 2099, 2940, 888, 3712, 2022, 673, 3749, 1962, 2548, 1170, 1513, 129, 1680, 883,
        2890, 666, 3987, 2523, 468, 1565, 3007, 292, 2275, 1844, 3120, 3980, 59, 3057, 3732, 267,
        1847, 513, 3912, 173, 2668, 665, 3227, 259, 1850, 3061, 100, 2457, 4020, 1608, 3510, 487,
        1278, 1833, 2811, 3521, 1251, 3903, 1992, 1090, 2745, 407, 3767, 65, 1203, 1814, 291, 2551,
        3931, 971, 3575, 515, 2699, 1576, 83, 2743, 1290, 3341, 429, 3976, 689, 3678, 2214, 2566,
        3366, 30, 1793, 861, 3633, 1886, 2479, 3928, 1517, 2758, 579, 1202, 2522, 1435, 2708, 959,
        3374, 2544, 1192, 3331, 1469, 1918, 2312, 903, 3807, 1560, 2707, 931, 3132, 203, 2950, 2627,
        3667, 353, 1114, 36, 2513, 3113, 256, 2408, 3996, 1547, 2003, 2982, 2432, 3878, 2910, 554,
        1995, 3077, 2401, 1339, 1898, 3495, 993, 4083, 2245, 842, 1701, 2761, 2031, 2985, 1280, 344,
        1943, 3573, 1196, 2805, 3327, 106, 1143, 764, 3216, 152, 3478, 1911, 3608, 692, 2117, 3958,
        1545, 806, 2937, 2378, 475, 3865, 2960, 1397, 3295, 458, 3484, 1987, 603, 2314, 1413, 967,
        2041, 3278, 4019, 2184, 1493, 718, 3579, 1409, 651, 3217, 998, 3569, 721, 1446, 2183, 3470,
        781, 1562, 185, 3961, 708, 2462, 3263, 1820, 296, 3177, 3598, 1004, 243, 3296, 802, 4068,
        1497, 2957, 2373, 414, 1396, 2213, 2715, 3685, 1292, 2413, 956, 2208, 242, 3276, 1123, 388,
        3666, 2155, 239, 1724, 3466, 1131, 38, 2525, 750, 2193, 1276, 3730, 1711, 3239, 3817, 688,
        2503, 1452, 592, 2718, 3729, 1859, 2860, 2217, 172, 2666, 2168, 286, 1746, 3267, 126, 1302,
        3709, 2660, 3335, 2113, 2977, 252, 1229, 2906, 639, 2538, 1328, 2338, 3881, 1788, 2421, 2730,
        551, 945, 3748, 2053, 4013, 3101, 530, 2006, 1692, 4092, 3055, 1524, 3824, 2815, 1810, 3073,
        2605, 1266, 3989, 3124, 682, 2131, 3572, 1836, 3966, 2891, 189, 2614, 1124, 302, 1882, 2875,
        97, 3098, 1749, 996, 3223, 410, 886, 3392, 1765, 3795, 1325, 2803, 4042, 1061, 3025, 2386,
        1805, 982, 474, 1148, 1660, 3716, 2293, 1531, 3819, 1949, 20, 3043, 1503, 455, 1128, 3695,
        2134, 3119, 196, 1688, 728, 1052, 3553, 217, 2872, 662, 303, 2537, 777, 1307, 2347, 17,
        3523, 524, 1997, 977, 2621, 1553, 2831, 409, 1000, 1667, 3273, 717, 4093, 2424, 3472, 1225,
        3944, 2109, 3460, 198, 2406, 1320, 4064, 2545, 1145, 756, 3473, 460, 2448, 1932, 612, 3921,
        358, 2862, 3822, 2515, 3206, 892, 493, 3303, 966, 2764, 3671, 752, 2114, 3541, 2896, 78,
        1628, 1187, 3409, 2539, 2901, 1520, 2368, 3271, 1181, 2149, 3516, 1866, 3210, 485, 4029, 954,
        2877, 1682, 2456, 3688, 164, 3844, 1216, 3213, 2416, 3697, 1416, 2159, 2989, 837, 1556, 465,
        2377, 746, 1179, 3874, 1953, 3018, 1641, 73, 3171, 2027, 2956, 1564, 878, 3587, 2717, 1208,
        2129, 3432, 1369, 1963, 48, 2720, 3997, 2047, 346, 1709, 1223, 3368, 2601, 946, 1906, 3319,
        2365, 3960, 622, 1941, 365, 3909, 1893, 816, 3851, 2673, 1401, 1005, 3689, 2738, 2051, 1465,
        749, 3242, 309, 1407, 2988, 2290, 754, 1961, 120, 2762, 520, 1829, 44, 3322, 2024, 2765,
        3637, 1659, 2917, 2567, 324, 791, 3625, 2315, 605, 3939, 245, 2239, 3282, 21, 1458, 3207,
        204, 838, 2350, 606, 3609, 1834, 1313, 2446, 3056, 3863, 2322, 576, 229, 4006, 1364, 391,
        824, 2719, 1408, 3687, 3111, 1262, 28, 2498, 1638, 411, 3093, 95, 2288, 1652, 342, 3371,
        2246, 2706, 1099, 3503, 1842, 479, 3389, 4014, 1358, 877, 3488, 3827, 2657, 1322, 3906, 1017,
        136, 3300, 516, 1398, 3474, 2141, 1193, 2768, 1411, 1779, 2604, 1164, 3846, 1851, 2572, 3781,
        1715, 3037, 4057, 1546, 2895, 1049, 663, 3459, 116, 841, 1428, 3204, 1743, 3028, 2466, 3736,
        2042, 3040, 124, 2223, 922, 2687, 3513, 3187, 629, 3610, 1970, 3922, 687, 3010, 1152, 3848,
        1858, 556, 4078, 2187, 880, 2630, 1518, 2888, 2163, 3155, 2388, 1104, 685, 2250, 417, 3091,
        1875, 2212, 917, 3782, 1728, 3200, 443, 3771, 3352, 896, 3118, 472, 2854, 620, 927, 2283,
        446, 1144, 2557, 298, 3288, 2279, 3797, 1631, 2819, 1993, 2661, 3692, 2147, 1125, 681, 1568,
        3268, 1056, 1712, 3421, 574, 1578, 2068, 1089, 2256, 2886, 1048, 2488, 1482, 3512, 2558, 75,
        1294, 3391, 1591, 128, 3183, 3815, 218, 1064, 498, 1755, 233, 1533, 2938, 3708, 1674, 2575,
        1274, 4052, 2817, 2337, 5, 2654, 968, 1870, 186, 2178, 3621, 1611, 2071, 3370, 1321, 2924,
        3659, 2092, 3507, 924, 1985, 168, 3036, 534, 1186, 4063, 397, 985, 69, 2807, 3452, 260,
        2625, 522, 3779, 2487, 2918, 4066, 281, 3664, 1445, 154, 1791, 3334, 310, 2088, 854, 3085,
        2162, 815, 2949, 2533, 1265, 1804, 2241, 3653, 3270, 2559, 3984, 3401, 1973, 184, 3285, 807,
        3562, 240, 1580, 710, 3083, 1345, 4012, 2392, 3008, 739, 1340, 4076, 253, 2460, 3887, 110,
        1861, 585, 1373, 2800, 3927, 1459, 2576, 2152, 3266, 1685, 2407, 3330, 1514, 3898, 2280, 1812,
        4026, 1334, 2012, 192, 1231, 1846, 709, 2528, 3051, 3955, 825, 2795, 1255, 4002, 1666, 3623,
        432, 3920, 1905, 402, 3439, 597, 2753, 1618, 793, 1178, 2095, 591, 947, 2663, 1182, 2357,
        581, 2077, 3458, 1119, 3647, 2000, 618, 1561, 3574, 2546, 379, 2767, 995, 1772, 720, 1540,
        3158, 2379, 3309, 343, 1806, 700, 3741, 958, 249, 3614, 653, 2936, 1885, 496, 1228, 853,
        2953, 2428, 3530, 884, 3169, 2333, 3375, 997, 1909, 413, 2297, 3684, 584, 2633, 195, 2450,
        1491, 2814, 1111, 3674, 2359, 932, 4039, 3041, 318, 3465, 2769, 1439, 3078, 3763, 1616, 3937,
        2850, 3157, 1748, 2671, 396, 2464, 3256, 119, 1097, 1796, 3228, 2221, 3476, 2973, 3606, 2535,
        1073, 3993, 857, 2195, 3588, 1168, 3192, 1881, 2859, 1402, 2209, 1161, 3756, 2669, 3156, 3601,
        16, 657, 1676, 2727, 3894, 456, 1612, 3791, 2692, 1370, 3112, 1635, 2009, 2981, 1162, 3312,
        691, 2266, 11, 3034, 1485, 2056, 138, 1317, 2394, 1699, 3904, 22, 2334, 495, 2148, 111,
        1394, 941, 289, 3985, 1438, 850, 3814, 2121, 2941, 3951, 787, 1502, 52, 1236, 2116, 403,
        2832, 207, 1646, 3035, 2694, 7, 2385, 483, 3938, 2639, 94, 3464, 812, 325, 1972, 1499,
        2188, 3318, 1129, 351, 2124, 1344, 2979, 202, 647, 3571, 1063, 41, 3419, 904, 3739, 1831,
        3861, 3195, 1357, 734, 3841, 2684, 3388, 1924, 3724, 538, 974, 3201, 1790, 3582, 1050, 3468,
        1934, 2517, 3385, 2191, 2990, 1824, 2585, 321, 1404, 519, 2002, 3773, 2612, 623, 3907, 1480,
        3418, 1948, 3681, 593, 1426, 1981, 3511, 1247, 1651, 885, 3174, 2078, 1665, 2467, 3855, 962,
        2882, 3963, 1835, 3075, 3703, 785, 1983, 2417, 3211, 2128, 2541, 4046, 1453, 2286, 261, 2583,
        494, 1955, 3561, 2426, 1690, 481, 1102, 712, 2947, 2600, 2019, 1267, 2511, 725, 2737, 3092,
        415, 3867, 731, 1232, 54, 3509, 1065, 3673, 2772, 3422, 2458, 1116, 3069, 1917, 3235, 849,
        2332, 1221, 2591, 1022, 4085, 3122, 803, 2928, 3668, 2495, 553, 4044, 2943, 1295, 169, 2648,
        431, 1349, 2345, 160, 2562, 3395, 1100, 3933, 1677, 863, 313, 1884, 2855, 743, 3107, 1230,
        1566, 2876, 983, 262, 3269, 2893, 2222, 3578, 1429, 200, 3808, 3399, 329, 4070, 1704, 1241,
        2329, 1554, 2839, 1868, 3209, 643, 1658, 2196, 813, 1726, 159, 3635, 385, 1613, 2733, 166,
        3796, 521, 3361, 140, 2410, 1703, 366, 2175, 177, 1994, 1461, 1040, 406, 3658, 3212, 2103,
        3491, 641, 3646, 951, 1559, 527, 2833, 82, 1384, 3759, 2739, 3305, 452, 3888, 2076, 3425,
        115, 4018, 2634, 2118, 1224, 3956, 61, 1761, 3188, 2299, 832, 2824, 1522, 2204, 156, 3672,
        889, 3310, 216, 3806, 2273, 2696, 3886, 369, 3281, 1279, 2926, 2226, 921, 4055, 1303, 2179,
        3031, 1521, 2866, 2126, 1259, 3287, 2637, 3892, 1159, 3222, 3576, 2724, 2319, 1854, 719, 1081,
        1678, 2481, 1899, 2791, 4086, 2264, 1774, 3525, 2991, 543, 1739, 970, 1343, 2499, 1670, 911,
        2344, 1792, 440, 3713, 669, 1512, 2504, 890, 3900, 1249, 464, 1896, 1001, 3262, 2547, 2932,
        531, 2008, 2607, 1009, 491, 1472, 1132, 3087, 2435, 3978, 548, 1825, 3347, 2486, 631, 3615,
        987, 1817, 3924, 761, 3702, 507, 940, 1583, 2863, 705, 1731, 40, 3376, 1490, 2808, 4005,
        3049, 72, 3299, 1197, 271, 3146, 835, 2512, 1135, 2166, 3437, 2355, 3717, 220, 3033, 3596,
        1105, 3343, 1347, 3059, 1860, 3451, 2841, 533, 2013, 2626, 3500, 2995, 3777, 650, 1314, 1763,
        3991, 1209, 3624, 1707, 3427, 2922, 2108, 74, 1907, 999, 3540, 1417, 2867, 24, 2036, 3294,
        364, 2507, 230, 1387, 2728, 1998, 3411, 2431, 272, 3810, 2190, 925, 3868, 546, 2142, 317,
        1430, 3752, 758, 2107, 3555, 1405, 1991, 371, 4000, 1526, 155, 3058, 1956, 830, 2675, 542,
        3769, 2790, 788, 2530, 332, 2277, 1146, 3699, 3086, 247, 1649, 2390, 67, 2120, 3390, 328,
        2270, 3165, 693, 2411, 246, 4087, 800, 3710, 1571, 2757, 278, 2375, 776, 3742, 1648, 1260,
        2845, 1989, 3534, 3193, 1669, 50, 4032, 1211, 1874, 3121, 1353, 2592, 2966, 1188, 3290, 2384,
        976, 2628, 1645, 2952, 575, 2582, 3720, 3229, 738, 2825, 3599, 609, 1268, 4067, 2156, 1487,
        1849, 70, 2132, 3248, 948, 4090, 133, 1719, 1356, 747, 4007, 1079, 1462, 2799, 3836, 1013,
        2686, 18, 1527, 2837, 1942, 1218, 2616, 3400, 570, 3064, 2020, 3914, 1155, 3148, 2698, 833,
        4017, 610, 1115, 2327, 874, 2913, 2158, 642, 2631, 380, 3567, 628, 1927, 236, 3619, 1775,
        3005, 451, 2261, 3852, 1071, 1734, 55, 1261, 2402, 1864, 1088, 2595, 1713, 3365, 355, 3105,
        714, 3973, 1603, 3580, 1421, 2021, 2972, 2485, 3551, 2127, 3297, 360, 3161, 1902, 745, 1664,
        3585, 2083, 3918, 871, 3308, 423, 1689, 2330, 1310, 895, 3289, 1595, 500, 2292, 224, 2150,
        3357, 1730, 3047, 3873, 430, 3594, 1455, 3238, 3740, 1043, 2304, 1609, 4075, 2489, 1376, 722,
        3953, 3449, 1257, 258, 3277, 2783, 2130, 3030, 3794, 269, 2244, 3879, 19, 2801, 1024, 2436,
        3428, 2670, 1091, 293, 2714, 658, 3367, 448, 938, 2809, 1816, 2598, 3727, 439, 2449, 2920,
        1184, 526, 3048, 1390, 3650, 2210, 3103, 121, 3941, 2642, 214, 2497, 3434, 1828, 3804, 1440,
        447, 2584, 102, 1361, 1883, 2571, 992, 222, 1702, 2836, 3435, 85, 3046, 944, 2840, 2111,
        12, 1563, 2681, 2037, 767, 3995, 497, 960, 1600, 3257, 873, 2961, 1474, 2046, 3757, 1319,
        1986, 549, 2354, 3106, 3856, 1668, 1180, 2336, 3950, 161, 1205, 679, 2254, 1367, 4065, 182,
        3362, 1853, 2468, 149, 2658, 676, 1076, 3493, 1549, 1935, 3602, 735, 1256, 2858, 953, 3542,
        2968, 1051, 2255, 3445, 724, 3023, 2296, 3975, 2040, 677, 1176, 2123, 1444, 3677, 506, 3329,
        2474, 912, 3144, 3715, 1656, 2317, 1372, 3593, 2656, 567, 1818, 3420, 424, 826, 3231, 257,
        2955, 3707, 1710, 792, 2079, 3, 3682, 1926, 1466, 3079, 3622, 1607, 3443, 950, 3108, 1594,
        2305, 772, 3726, 1037, 1809, 4008, 2054, 2752, 489, 973, 2965, 2201, 4035, 90, 2418, 664,
        1979, 3981, 1593, 2691, 3785, 150, 1544, 3134, 341, 2506, 3766, 3252, 367, 2353, 1840, 1215,
        3592, 1900, 486, 1191, 104, 2883, 3311, 290, 2028, 4021, 1308, 2471, 3828, 2747, 2291, 1567,
        1165, 108, 3378, 1366, 2536, 3243, 2868, 805, 2560, 331, 2171, 2905, 45, 2662, 2048, 480,
        3823, 2835, 1473, 3387, 3021, 237, 1264, 3260, 2434, 3786, 1437, 426, 1768, 3208, 1506, 2759,
        305, 3109, 831, 492, 2070, 1112, 3605, 795, 1330, 2931, 1798, 865, 2690, 3946, 811, 2879,
        251, 4047, 2976, 2422, 3455, 899, 1756, 2510, 1026, 3000, 206, 2143, 1096, 1723, 614, 3962,
        819, 2829, 2182, 4037, 381, 1016, 1620, 478, 3279, 3839, 1006, 1855, 3954, 649, 1300, 3528,
        1072, 335, 2066, 557, 2343, 1604, 3731, 763, 1754, 2, 3328, 2589, 1066, 3641, 2052, 1157,
        3714, 1826, 1304, 3346, 2844, 1684, 2540, 3382, 2225, 3932, 435, 1529, 2045, 112, 3137, 1693,
        1399, 2206, 774, 1351, 3880, 2057, 624, 3816, 1535, 3453, 672, 3669, 2897, 153, 3535, 2516,
        3250, 1857, 661, 2704, 1238, 3772, 2423, 3552, 2058, 1342, 544, 2477, 1463, 3355, 2282, 2771,
        1867, 3249, 2579, 3910, 907, 2849, 418, 2198, 3062, 1160, 2038, 3872, 759, 2945, 508, 3407,
        2311, 42, 3850, 2403, 273, 4023, 528, 1915, 25, 1023, 3531, 2821, 3403, 1121, 3616, 2542,
        566, 3408, 2742, 1708, 352, 2664, 3172, 180, 2284, 2735, 1903, 902, 1510, 3129, 1933, 1298,
        3890, 1495, 255, 3440, 1928, 3001, 176, 1794, 913, 2776, 3197, 3753, 279, 3012, 891, 188,
        4034, 1415, 51, 1253, 3436, 1965, 3591, 1400, 4045, 2798, 337, 1492, 2358, 151, 2619, 875,
        1584, 2816, 1966, 1041, 3153, 1414, 900, 2797, 3128, 1626, 2440, 645, 1378, 2242, 404, 1952,
        3835, 1060, 148, 3670, 2227, 1039, 1460, 3559, 1212, 436, 3261, 2425, 4081, 565, 2248, 357,
        2958, 2454, 3723, 862, 2303, 1486, 680, 3152, 4071, 99, 2186, 1673, 1130, 1964, 3694, 1637,
        713, 2231, 2970, 1803, 637, 2689, 131, 2453, 881, 600, 3544, 3102, 1873, 3690, 1315, 4094,
        3066, 697, 3604, 477, 1721, 3490, 2352, 3728, 1234, 2125, 3801, 178, 3044, 4015, 882, 2861,
        1504, 3110, 1887, 3247, 674, 4028, 2948, 1974, 768, 3917, 1714, 29, 1149, 2710, 3363, 1003,
        146, 2086, 1183, 3090, 420, 3895, 2622, 1175, 2387, 1543, 654, 3430, 2608, 441, 2397, 3184,
        2685, 3522, 1012, 3800, 3163, 1587, 1134, 3234, 1841, 2649, 2173, 1198, 894, 3275, 1694, 2146,
        327, 1245, 2644, 2278, 2903, 118, 1837, 699, 295, 3240, 847, 1843, 2588, 1622, 3301, 60,
        2318, 716, 2492, 1258, 2804, 1663, 80, 2491, 3099, 1410, 2793, 3492, 2089, 1449, 3826, 1742,
        3631, 627, 2756, 1614, 3338, 1002, 1848, 3704, 377, 3020, 3649, 866, 2927, 3994, 1389, 1058,
        238, 1957, 499, 2427, 275, 2247, 3891, 449, 3718, 1574, 66, 3969, 2581, 277, 617, 2529,
        3253, 3799, 1548, 846, 3964, 1296, 3068, 2552, 4072, 1501, 2746, 3506, 1177, 482, 2055, 3661,
        1214, 3968, 311, 3499, 457, 2341, 929, 3765, 333, 2232, 943, 625, 3065, 384, 801, 2606,
        1309, 1901, 4049, 31, 2137, 2857, 223, 3377, 2098, 1273, 2514, 1839, 53, 2122, 630, 3416,
        1700, 3967, 2852, 1424, 3550, 920, 2766, 2102, 1263, 3009, 3332, 668, 1929, 2907, 3838, 1093,
        1892, 96, 2174, 3196, 363, 2072, 3564, 1042, 2235, 547, 2005, 326, 3853, 2439, 1007, 2693,
        1787, 2898, 2090, 1537, 3866, 1871, 3417, 1277, 3264, 1819, 3611, 2549, 3775, 1640, 2331, 3123,
        416, 3444, 2473, 808, 3563, 1362, 2361, 814, 1686, 525, 3935, 1109, 3326, 1536, 3758, 2914,
        2509, 1219, 730, 2033, 3067, 1770, 684, 3384, 266, 855, 2349, 1335, 3529, 2249, 1500, 3481,
        794, 2842, 3581, 1126, 2712, 769, 1634, 170, 2869, 3393, 908, 2962, 1456, 3135, 632, 3398,
        225, 844, 3340, 1057, 3019, 659, 2713, 2112, 563, 2843, 248, 1271, 1930, 88, 3396, 939,
        2892, 1557, 1083, 3125, 1799, 577, 3998, 3071, 2705, 3487, 2180, 300, 2810, 2367, 930, 145,
        2073, 382, 3350, 3768, 26, 1306, 4069, 2461, 1880, 2834, 3869, 1767, 158, 1011, 438, 3060,
        2369, 1388, 535, 1740, 3821, 2447, 3127, 3915, 1250, 1705, 3774, 2144, 77, 1747, 4051, 2251,
        1436, 3780, 2577, 6, 2396, 1395, 205, 4062, 1094, 1610, 3862, 2306, 1015, 2721, 3983, 2157,
        174, 3864, 2281, 345, 3755, 2555, 1068, 1494, 101, 969, 3114, 1350, 3706, 504, 1760, 3166,
        3902, 1577, 2646, 1074, 2321, 2912, 437, 1481, 3683, 1082, 459, 2700, 3203, 4043, 2596, 1856,
        187, 3940, 2034, 3372, 9, 1374, 580, 1967, 2640, 285, 2505, 1217, 3532, 2780, 1095, 434,
        3052, 1722, 595, 1999, 3813, 3131, 1758, 3483, 2478, 3232, 736, 2959, 3533, 514, 1359, 1795,
        2651, 638, 3013, 1425, 2075, 197, 3518, 2253, 3854, 1832, 2570, 695, 1977, 3272, 2586, 1269,
        2289, 864, 3088, 1889, 613, 3634, 2080, 3117, 143, 3286, 1619, 2085, 1220, 571, 1569, 3620,
        1174, 3175, 2472, 935, 2921, 2272, 3283, 994, 3456, 773, 3084, 564, 2364, 798, 2025, 3636,
        2484, 1244, 2846, 3284, 1137, 765, 2295, 354, 914, 1914, 132, 1427, 2059, 3138, 784, 3314,
        1226, 1951, 3482, 860, 2848, 3298, 1733, 727, 2871, 453, 3556, 1519, 4077, 986, 221, 3660,
        589, 3480, 135, 3948, 1597, 2554, 1163, 821, 2623, 2294, 751, 3754, 3015, 2363, 3364, 823,
        2781, 314, 1528, 604, 3638, 1717, 373, 3805, 1447, 2063, 3992, 1598, 3218, 3847, 1484, 105,
        3353, 876, 4011, 306, 1615, 3652, 2826, 1293, 3016, 3630, 2665, 4009, 400, 1661, 2459, 3648,
        2300, 234, 1697, 4040, 1195, 532, 2643, 1368, 3259, 1086, 2043, 8, 2310, 2963, 1687, 2784,
        2015, 1505, 2383, 957, 2954, 208, 3526, 1937, 3999, 1326, 3438, 76, 952, 1876, 244, 2177,
        3788, 1925, 2641, 3986, 2115, 1107, 2751, 2356, 68, 2847, 1085, 210, 1891, 395, 2885, 2207,
        1757, 517, 2328, 1922, 2635, 103, 2017, 3959, 1650, 578, 2200, 859, 2919, 3761, 23, 979,
        3834, 3244, 2682, 376, 2366, 1959, 3919, 165, 2199, 3798, 2734, 3433, 1254, 633, 3837, 1153,
        3302, 316, 2688, 3705, 1336, 3317, 1695, 558, 2942, 330, 1822, 2838, 2519, 3943, 1432, 3032,
        615, 1046, 3221, 1305, 134, 3477, 701, 3159, 1681, 3643, 2224, 3479, 2722, 990, 3524, 1167,
        3897, 2726, 1464, 3554, 704, 3190, 1053, 450, 2465, 3342, 1147, 1802, 2564, 1282, 2105, 3039,
        428, 1331, 829, 3657, 1525, 3386, 1008, 3063, 1654, 778, 375, 1732, 3141, 2494, 394, 2215,
        782, 4003, 1811, 596, 2136, 387, 2409, 3745, 1054, 2238, 3811, 1516, 454, 3406, 1101, 2398,
        1647, 3505, 425, 2348, 2998, 1573, 1982, 4084, 1252, 505, 817, 2476, 1418, 3133, 656, 2493,
        339, 3180, 1020, 2929, 1299, 3832, 2219, 3475, 1448, 64, 3857, 3198, 322, 3423, 723, 1629,
        1895, 2563, 2135, 3006, 93, 2763, 608, 2482, 3642, 1207, 2335, 3974, 916, 1916, 3597, 3194,
        1478, 3002, 1098, 3560, 2827, 909, 3199, 1379, 2731, 733, 3116, 1156, 2106, 711, 3150, 32,
        4054, 2822, 1823, 867, 3870, 2590, 227, 928, 2676, 3029, 1736, 3957, 422, 2061, 3746, 1581,
        1954, 3644, 127, 2081, 427, 2526, 1729, 780, 3053, 2613, 2084, 678, 1592, 2374, 4030, 2806,
        3590, 621, 3893, 1070, 1783, 3568, 1382, 2023, 299, 2813, 3354, 1467, 125, 2853, 1329, 280,
        2599, 2035, 98, 2370, 1621, 4095, 1879, 10, 3414, 1958, 199, 3497, 2782, 3860, 1766, 2594,
        1333, 308, 2164, 3627, 503, 1227, 3405, 2342, 3547, 2014, 142, 3215, 1150, 2391, 62, 2993,
        1248, 737, 2381, 4088, 1511, 2986, 162, 3750, 1890, 972, 1346, 2944, 3680, 1010, 114, 1169,
        2939, 282, 1423, 3333, 490, 2258, 845, 4053, 3143, 1827, 583, 2574, 2138, 3820, 856, 1750,
        3883, 636, 3316, 1363, 334, 3094, 696, 2603, 1532, 3947, 2393, 1672, 319, 981, 2240, 582,
        3450, 1028, 3245, 1431, 2908, 2093, 660, 1617, 315, 1365, 3721, 2624, 1601, 3446, 934, 3885,
        2667, 3360, 1744, 3151, 906, 3565, 1189, 2678, 392, 4041, 3402, 254, 2703, 1971, 3258, 2205,
        1542, 3189, 2500, 2029, 2851, 3762, 2580, 37, 1515, 893, 3725, 1139, 3413, 539, 3070, 2443,
        3463, 980, 2864, 3738, 2501, 1138, 2220, 3675, 955, 509, 1235, 2650, 3655, 1488, 2994, 3790,
        1939, 2773, 2430, 107, 1737, 3792, 2716, 3145, 3908, 1031, 2172, 488, 740, 2889, 1830, 288,
        2140, 473, 1142, 2760, 607, 2309, 1589, 3181, 2154, 652, 2395, 1691, 587, 1327, 3899, 732,
        2372, 984, 4027, 779, 228, 1602, 1127, 3304, 2307, 2909, 1976, 193, 2741, 1623, 2060, 33,
        1275, 2203, 1655, 461, 1969, 3537, 241, 2870, 2065, 3274, 3017, 757, 2016, 3255, 113, 868,
        1585, 374, 3977, 775, 3381, 1044, 368, 1910, 783, 2483, 3081, 3498, 1947, 4050, 1324, 2532,
        3558, 1538, 3812, 226, 1980, 3936, 276, 3504, 1021, 1470, 3136, 3789, 2259, 2915, 232, 1777,
        3737, 49, 1888, 1318, 3412, 3026, 1960, 690, 3603, 408, 3979, 2362, 1323, 3586, 1027, 4056,
        3149, 312, 2697, 3970, 872, 3233, 1301, 1643, 3818, 92, 1845, 4048, 401, 1201, 2480, 2873,
        3502, 2271, 1136, 3072, 2145, 2565, 1385, 3462, 2874, 1507, 1, 1239, 2677, 356, 3147, 655,
        1018, 2984, 2414, 3471, 1287, 2587, 755, 1936, 2916, 2573, 4, 1185, 840, 3566, 2520, 3323,
        568, 2974, 3520, 2645, 2153, 523, 3925, 2701, 1391, 1019, 1662, 3321, 760, 2983, 444, 2550,
        1778, 3607, 707, 1419, 2997, 1808, 540, 2433, 796, 2729, 1355, 2518, 3469, 2167, 3896, 1383,
        640, 1852, 3612, 1496, 511, 3926, 157, 2267, 545, 3990, 1785, 3700, 905, 2325, 1575, 3783,
        2064, 39, 1789, 869, 2933, 3344, 1706, 3711, 349, 3965, 1753, 3441, 2039, 445, 1433, 1062,
        2236, 1642, 1092, 350, 3776, 926, 1552, 163, 2237, 3182, 2786, 323, 1920, 3843, 2263, 1477,
        827, 2923, 1990, 2360, 58, 2615, 3911, 3306, 1172, 3600, 336, 1627, 989, 569, 1815, 264,
        3236, 2636, 47, 2925, 1975, 2777, 1671, 3584, 1117, 2382, 3202, 599, 2074, 3379, 263, 2785,
        3336, 1354, 4038, 561, 2170, 147, 1113, 2437, 1360, 2218, 686, 2638, 3011, 4080, 1919, 2794,
        3913, 753, 2531, 3126, 1751, 2380, 2930, 3496, 1800, 616, 3734, 1246, 2629, 171, 1133, 3337,
        3787, 211, 1222, 3265, 3701, 1069, 2104, 235, 1908, 2894, 2202, 3325, 2672, 3100, 3617, 2302,
        1075, 4079, 786, 1289, 3691, 978, 644, 3160, 1950, 287, 2711, 1443, 2880, 3889, 1173, 1727,
        741, 2287, 3045, 2655, 1476, 3901, 3142, 552, 3461, 961, 3214, 183, 1582, 887, 301, 3251,
        130, 2097, 3662, 1286, 79, 3307, 1166, 361, 4082, 2452, 901, 2151, 3543, 1716, 2881, 536,
        2091, 2674, 3545, 442, 1606, 771, 3074, 1483, 3778, 923, 626, 3942, 34, 1434, 848, 2899,
        1523, 1944, 2470, 3348, 294, 2419, 2964, 1377, 3830, 820, 3431, 1059, 89, 1894, 573, 2610,
        3722, 1080, 398, 3626, 1984, 898, 2617, 1558, 2779, 2026, 3882, 1270, 2308, 3693, 2569, 1233,
        1588, 2951, 537, 1940, 3949, 770, 2787, 2050, 1288, 3003, 27, 1498, 3224, 790, 4024, 2490,
        1555, 936, 1797, 2269, 2830, 4060, 2524, 518, 2340, 3191, 1807, 1200, 2067, 2444, 3840, 469,
        3424, 191, 3027, 1605, 2211, 3972, 1780, 63, 2578, 2194, 1720, 4022, 2429, 3178, 3538, 2110,
        141, 3237, 1838, 1210, 283, 3515, 2230, 87, 3719, 383, 1683, 2904, 560, 3139, 1801, 3536,
        2301, 1067, 3349, 2597, 1530, 2285, 3656, 588, 3369, 1679, 3825, 2812, 462, 2313, 1348, 81,
        3280, 3877, 683, 3185, 1106, 109, 1781, 3570, 1312, 167, 2618, 3651, 3014, 297, 1735, 2748,
        2181, 965, 3875, 667, 1171, 463, 3315, 1034, 3628, 586, 3004, 412, 1550, 851, 1341, 2971,
        1596, 3849, 2326, 2796, 3173, 635, 1725, 2992, 1242, 828, 3549, 2527, 1035, 2082, 370, 797,
        2749, 4033, 378, 933, 3089, 215, 1769, 1030, 2653, 390, 2228, 1122, 1945, 3595, 2969, 1077,
        2032, 2789, 274, 3733, 1441, 2189, 3359, 742, 2818, 4001, 1572, 598, 975, 3339, 1243, 648,
        3583, 1403, 2652, 1865, 3519, 2911, 2094, 2750, 1639, 1281, 3501, 2069, 2659, 3770, 250, 2389,
        1014, 510, 789, 1534, 3916, 2445, 964, 4061, 1968, 3170, 2192, 43, 4004, 1422, 3735, 3225,
        1375, 1762, 2139, 3613, 1338, 2725, 3871, 2165, 1475, 3629, 3076, 698, 3930, 307, 1741, 3404,
        550, 1380, 2438, 1878, 2680, 433, 2980, 1036, 1904, 362, 2229, 3514, 1921, 2543, 4036, 1996,
        3115, 347, 3743, 84, 2442, 1450, 729, 284, 3845, 2420, 139, 1140, 3096, 602, 2004, 4091,
        2709, 3577, 3095, 2011, 190, 1371, 3358, 476, 2683, 1509, 671, 3351, 1738, 2967, 2451, 212,
        702, 3751, 14, 2441, 715, 3467, 512, 3162, 91, 918, 1752, 2455, 1381, 2723, 839, 2400,
        3945, 3080, 1025, 3557, 804, 3929, 1599, 3698, 2556, 3226, 1141, 2770, 144, 1457, 393, 2399,
        1103, 1644, 2268, 3241, 919, 4058, 3426, 1821, 3179, 810, 2878, 1773, 3676, 937, 3205, 1204,
        1764, 86, 2508, 1110, 3654, 2736, 1862, 2252, 175, 3802, 1118, 2774, 467, 843, 1194, 2018,
        3291, 2884, 1120, 3154, 1653, 2007, 1190, 2404, 4031, 2740, 3415, 268, 3186, 2087, 3527, 219,
        1551, 2160, 57, 3176, 1311, 2371, 231, 2096, 619, 1479, 3858, 766, 3164, 3696, 2865, 852,
        3454, 2978, 594, 1272, 2010, 405, 2561, 1087, 2161, 1406, 4010, 399, 2197, 2568, 1632, 419,
        3383, 2185, 1451, 3292, 389, 822, 3842, 1213, 3024, 2412, 3517, 1869, 2346, 3859, 3457, 2611,
    ]
}
