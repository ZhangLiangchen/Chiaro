import CUltraHDRBridge
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import os

public enum JPEGEncodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidGainMapBuffer(String)
    case invalidGainMapMetadata(String)
    case invalidHeadroomForUltraHDR(baseLinear: Double, alternateLinear: Double)
    case jpegCompressionFailed(String)
    case metadataSerializationFailed(String)
    case ultraHDREncodeFailed(status: Int32, message: String)
    case exceededMaxFileBytes(actualBytes: Int, maxBytes: Int)
    case atomicRenameFailed(errno: Int32, path: String)

    public var description: String {
        switch self {
        case .invalidGainMapBuffer(let detail):
            return "Invalid gain map buffer for JPEG export: \(detail)"
        case .invalidGainMapMetadata(let detail):
            return "Invalid gain map metadata for JPEG export: \(detail)"
        case .invalidHeadroomForUltraHDR(let base, let alt):
            return "Ultra HDR JPEG requires alternate headroom (\(alt)) > base headroom (\(base)) >= 1.0"
        case .jpegCompressionFailed(let detail):
            return "JPEG compression failed: \(detail)"
        case .metadataSerializationFailed(let detail):
            return "JPEG metadata serialization failed: \(detail)"
        case .ultraHDREncodeFailed(let status, let msg):
            return "libultrahdr API-4 encode failed (status=\(status)): \(msg)"
        case .exceededMaxFileBytes(let actual, let max):
            return "Encoded JPEG (\(actual) bytes) exceeds targetMaxFileBytes (\(max) bytes) even at minimum quality"
        case .atomicRenameFailed(let code, let path):
            return "Atomic rename failed (errno=\(code)) for \(path)"
        }
    }
}

public final class JPEGDualEncoder: JPEGEncoderProtocol, Sendable {
    public let format: OutputFormat = .jpeg

    private let engineLock: OSAllocatedUnfairLock<MetalPipelineEngine?>

    public init(metalEngine: MetalPipelineEngine? = nil) {
        self.engineLock = OSAllocatedUnfairLock(initialState: metalEngine)
    }

    public func encode(
        frame: RenderedFrame,
        preset: PresetSchema,
        to outputURL: URL
    ) async throws -> ExportArtifact {
        try Task.checkCancellation()

        try validateGainMapBuffer(frame.gainMap.buffer)
        try validateGainMapMetadata(frame.gainMap.metadata, channels: frame.gainMap.buffer.channels)

        let effectiveChannels = preset.effectiveGainMapChannels(for: .jpeg)
        let useUltraHDRBridge = (effectiveChannels == .mono1ch && preset.compatOptions.writeUltrahdrXMP)

        let baseImage = try ensureBaseCGImageColorSpace(frame.sdrCGImage, baseColorSpace: frame.baseColorSpace)
        let initialQ = preset.quality.isFinite ? min(max(preset.quality, 0.05), 1.0) : 0.90
        let initialGMQ = preset.effectiveGainMapQuality.isFinite
            ? min(max(preset.effectiveGainMapQuality, 0.05), 1.0)
            : initialQ

        let schedule = Self.buildQualitySchedule(
            initialBaseQ: initialQ,
            initialGMQ: initialGMQ,
            hasSizeBudget: preset.targetMaxFileBytes != nil
        )

        var chosenData: Data?
        var lastByteCount = 0

        for (baseQ, gmQ) in schedule {
            try Task.checkCancellation()

            let needsGPURecompute = (frame.hdrLinearTexture != nil)
                && (preset.compatOptions.closedLoopSDRCompensation || frame.gainMap.buffer.channels != effectiveChannels)
            let compressedSDR: Data? = (useUltraHDRBridge || needsGPURecompute)
                ? try compressSDRToJPEG(image: baseImage, quality: baseQ)
                : nil

            let resolvedGainMap: GainMapResult
            if needsGPURecompute, let hdrTex = frame.hdrLinearTexture, let sdrJPEG = compressedSDR {
                let engine = try getOrCreateEngine(device: hdrTex.texture.device)
                resolvedGainMap = try await engine.recomputeGainMapCompensated(
                    hdrTexture: hdrTex,
                    compressedSDRJPEGData: sdrJPEG,
                    metadata: frame.gainMap.metadata,
                    gamma: preset.gainMapGamma,
                    channels: effectiveChannels,
                    resolution: preset.gainMapResolution,
                    midtoneAnchorP: preset.midtoneAnchorP,
                    baseColorSpace: frame.baseColorSpace
                )
            } else if frame.gainMap.buffer.channels == .rgb3ch && effectiveChannels == .mono1ch {
                resolvedGainMap = try collapseBGRAtoMono1ch(
                    frame.gainMap,
                    targetGamma: preset.gainMapGamma,
                    baseColorSpace: frame.baseColorSpace
                )
            } else {
                resolvedGainMap = frame.gainMap
            }

            let candidateData: Data
            if useUltraHDRBridge, let sdrJPEG = compressedSDR {
                candidateData = try encodeUltraHDRv11(
                    baseJPEG: sdrJPEG,
                    gainMap: resolvedGainMap,
                    gainMapQuality: gmQ,
                    baseColorSpace: frame.baseColorSpace,
                    exif: frame.exif,
                    customRenderedHDR: preset.compatOptions.writeCustomRenderedHDR
                )
            } else {
                candidateData = try encodeImageIOISOGainMapJPEG(
                    baseImage: baseImage,
                    baseQuality: baseQ,
                    gainMap: resolvedGainMap,
                    exif: frame.exif,
                    customRenderedHDR: preset.compatOptions.writeCustomRenderedHDR
                )
            }

            lastByteCount = candidateData.count
            if let maxBytes = preset.targetMaxFileBytes {
                if candidateData.count <= maxBytes {
                    chosenData = candidateData
                    break
                }
            } else {
                chosenData = candidateData
                break
            }
        }

        guard let finalData = chosenData else {
            throw JPEGEncodeError.exceededMaxFileBytes(
                actualBytes: lastByteCount,
                maxBytes: preset.targetMaxFileBytes ?? 0
            )
        }

        try writeAtomically(data: finalData, to: outputURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(finalData.count)

        return ExportArtifact(
            format: .jpeg,
            outputURL: outputURL,
            fileSizeBytes: fileSize
        )
    }

    // MARK: - Path A: 1ch Ultra HDR v1.1 (libultrahdr API-4)

    private func encodeUltraHDRv11(
        baseJPEG: Data,
        gainMap: GainMapResult,
        gainMapQuality: Double,
        baseColorSpace: BaseColorSpace,
        exif: WhitelistedExif,
        customRenderedHDR: Bool
    ) throws -> Data {
        guard gainMap.buffer.channels == .mono1ch else {
            throw JPEGEncodeError.invalidGainMapBuffer("Ultra HDR v1.1 path requires mono1ch ('L008') gain map")
        }
        try validateGainMapBuffer(gainMap.buffer)
        try validateGainMapMetadata(gainMap.metadata, channels: .mono1ch)

        let gmJPEG = try compressMonoGainMapToJPEG(buffer: gainMap.buffer, quality: gainMapQuality)
        let tiffEXIF = try ExifWhitelistBuilder.buildTIFFData(from: exif, customRenderedHDR: customRenderedHDR)

        let meta = gainMap.metadata
        let gMinStops = meta.gainMapMin[0]
        let gMaxStops = max(meta.gainMapMax[0], gMinStops)
        let gammaVal = Float(meta.gamma[0])
        let baseOffVal = Float(meta.baseOffset[0])
        let altOffVal = Float(meta.altOffset[0])

        let minBoost = Float(exp2(gMinStops))
        let maxBoost = Float(exp2(gMaxStops))
        let capMin = max(1.0, Float(meta.baseHeadroom.toLinear().multiplier))
        let capMax = Float(meta.alternateHeadroom.toLinear().multiplier)

        guard minBoost.isFinite, maxBoost.isFinite, capMin.isFinite, capMax.isFinite,
              minBoost > 0, maxBoost >= minBoost, capMax > capMin else {
            throw JPEGEncodeError.invalidHeadroomForUltraHDR(
                baseLinear: Double(capMin),
                alternateLinear: Double(capMax)
            )
        }

        let uhdrMeta = HDRUltraHDRGainMapMetadata(
            max_content_boost: (maxBoost, maxBoost, maxBoost),
            min_content_boost: (minBoost, minBoost, minBoost),
            gamma: (gammaVal, gammaVal, gammaVal),
            offset_sdr: (baseOffVal, baseOffVal, baseOffVal),
            offset_hdr: (altOffVal, altOffVal, altOffVal),
            hdr_capacity_min: capMin,
            hdr_capacity_max: capMax,
            use_base_cg: 1
        )

        let gamut: HDRUltraHDRColorGamut = (baseColorSpace == .srgb)
            ? HDR_UHDR_CG_BT_709
            : HDR_UHDR_CG_DISPLAY_P3

        var outBuffer = HDRUltraHDRBuffer()
        var errPtr: UnsafeMutablePointer<CChar>?
        defer {
            hdr_ultrahdr_free_buffer(&outBuffer)
            cuhdr_free_error(errPtr)
        }

        let status = baseJPEG.withUnsafeBytes { basePtr in
            gmJPEG.withUnsafeBytes { gmPtr in
                tiffEXIF.withUnsafeBytes { exifPtr in
                    var input = HDRUltraHDREncodeInput(
                        base_jpeg_data: basePtr.bindMemory(to: UInt8.self).baseAddress,
                        base_jpeg_size: baseJPEG.count,
                        base_color_gamut: gamut,
                        gainmap_jpeg_data: gmPtr.bindMemory(to: UInt8.self).baseAddress,
                        gainmap_jpeg_size: gmJPEG.count,
                        exif_data: exifPtr.bindMemory(to: UInt8.self).baseAddress,
                        exif_size: tiffEXIF.count,
                        metadata: uhdrMeta
                    )
                    return cuhdr_encode_api4(&input, &outBuffer, &errPtr)
                }
            }
        }

        guard status == 0, let outBytes = outBuffer.data, outBuffer.size > 0 else {
            let msg = errPtr.map { String(cString: $0) } ?? "unknown error"
            throw JPEGEncodeError.ultraHDREncodeFailed(status: status, message: msg)
        }

        return Data(bytes: outBytes, count: outBuffer.size)
    }

    // MARK: - Path B: Pure ISO 21496-1 APP2 + MPF via Apple ImageIO (No hdrgm: XMP, No MakerNote 33/48)

    private func encodeImageIOISOGainMapJPEG(
        baseImage: CGImage,
        baseQuality: Double,
        gainMap: GainMapResult,
        exif: WhitelistedExif,
        customRenderedHDR: Bool
    ) throws -> Data {
        try validateGainMapBuffer(gainMap.buffer)
        try validateGainMapMetadata(gainMap.metadata, channels: gainMap.buffer.channels)

        var props = ExifWhitelistBuilder.buildImageIODictionary(
            from: exif,
            customRenderedHDR: customRenderedHDR
        )
        props[kCGImageDestinationLossyCompressionQuality] = baseQuality

        let pixelFormat: OSType = (gainMap.buffer.channels == .mono1ch)
            ? kCVPixelFormatType_OneComponent8
            : kCVPixelFormatType_32BGRA

        let desc: [CFString: Any] = [
            kCGImagePropertyWidth: gainMap.buffer.width,
            kCGImagePropertyHeight: gainMap.buffer.height,
            kCGImagePropertyBytesPerRow: gainMap.buffer.bytesPerRow,
            kCGImagePropertyPixelFormat: pixelFormat,
        ]

        let xmpData = try buildHDRToneMapXMP(metadata: gainMap.metadata, channels: gainMap.buffer.channels)
        guard let cgMeta = CGImageMetadataCreateFromXMPData(xmpData as CFData) else {
            throw JPEGEncodeError.metadataSerializationFailed("CGImageMetadataCreateFromXMPData failed")
        }

        let auxInfo: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: gainMap.buffer.data as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: desc as CFDictionary,
            kCGImageAuxiliaryDataInfoMetadata: cgMeta,
        ]

        let outData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw JPEGEncodeError.jpegCompressionFailed("CGImageDestinationCreateWithData failed")
        }

        CGImageDestinationAddImage(destination, baseImage, props as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(
            destination,
            kCGImageAuxiliaryDataTypeISOGainMap,
            auxInfo as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw JPEGEncodeError.jpegCompressionFailed("CGImageDestinationFinalize failed for ImageIO ISO JPEG")
        }

        return outData as Data
    }

    // MARK: - Compression & Fallback Helpers

    private func compressSDRToJPEG(image: CGImage, quality: Double) throws -> Data {
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw JPEGEncodeError.jpegCompressionFailed("Failed to create SDR JPEG destination")
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw JPEGEncodeError.jpegCompressionFailed("Failed to finalize SDR JPEG")
        }
        return outData as Data
    }

    private func compressMonoGainMapToJPEG(buffer: GainMapBuffer, quality: Double) throws -> Data {
        let grayCS = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: buffer.data as CFData),
              let gmCG = CGImage(
                width: buffer.width,
                height: buffer.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: buffer.bytesPerRow,
                space: grayCS,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw JPEGEncodeError.jpegCompressionFailed("Failed to create grayscale CGImage for L008 gain map")
        }

        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw JPEGEncodeError.jpegCompressionFailed("Failed to create gain map JPEG destination")
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, gmCG, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw JPEGEncodeError.jpegCompressionFailed("Failed to finalize gain map JPEG")
        }
        return outData as Data
    }

    private func ensureBaseCGImageColorSpace(
        _ image: CGImage,
        baseColorSpace: BaseColorSpace
    ) throws -> CGImage {
        let csName: CFString = (baseColorSpace == .srgb) ? CGColorSpace.sRGB : CGColorSpace.displayP3
        if image.colorSpace?.name == csName {
            return image
        }
        guard let targetCS = CGColorSpace(name: csName) else {
            throw JPEGEncodeError.jpegCompressionFailed("Unable to create target CGColorSpace")
        }
        if image.colorSpace == nil, let tagged = image.copy(colorSpace: targetCS) {
            return tagged
        }
        let w = image.width
        let h = image.height
        let bpr = w * 4
        var rgba = Data(count: bpr * h)
        let cg = rgba.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: targetCS,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return nil
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        guard let cg else {
            throw JPEGEncodeError.jpegCompressionFailed("Failed to convert base CGImage to target color space")
        }
        return cg
    }

    private func collapseBGRAtoMono1ch(
        _ gainMap: GainMapResult,
        targetGamma: Double,
        baseColorSpace: BaseColorSpace
    ) throws -> GainMapResult {
        let buf = gainMap.buffer
        let meta = gainMap.metadata
        let w = buf.width
        let h = buf.height
        let srcStride = buf.bytesPerRow

        let gMinR = valueAt(meta.gainMapMin, index: 0)
        let gMinG = valueAt(meta.gainMapMin, index: 1)
        let gMinB = valueAt(meta.gainMapMin, index: 2)
        let gMaxR = valueAt(meta.gainMapMax, index: 0)
        let gMaxG = valueAt(meta.gainMapMax, index: 1)
        let gMaxB = valueAt(meta.gainMapMax, index: 2)
        let gamR = max(valueAt(meta.gamma, index: 0), 1e-4)
        let gamG = max(valueAt(meta.gamma, index: 1), 1e-4)
        let gamB = max(valueAt(meta.gamma, index: 2), 1e-4)

        let (wr, wg, wb): (Double, Double, Double) = (baseColorSpace == .displayP3)
            ? (0.22897, 0.69174, 0.07929)
            : (0.2126, 0.7152, 0.0722)

        var logLuma = [Double](repeating: 0.0, count: w * h)
        var minL = Double.greatestFiniteMagnitude
        var maxL = -Double.greatestFiniteMagnitude

        buf.data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<h {
                let rowOff = y * srcStride
                for x in 0..<w {
                    let off = rowOff + x * 4
                    let qb = Double(ptr[off + 0]) / 255.0
                    let qg = Double(ptr[off + 1]) / 255.0
                    let qr = Double(ptr[off + 2]) / 255.0
                    let gr = gMinR + (gMaxR - gMinR) * pow(qr, 1.0 / gamR)
                    let gg = gMinG + (gMaxG - gMinG) * pow(qg, 1.0 / gamG)
                    let gb = gMinB + (gMaxB - gMinB) * pow(qb, 1.0 / gamB)
                    let lin = wr * exp2(gr) + wg * exp2(gg) + wb * exp2(gb)
                    let gl = log2(max(lin, 1e-6))
                    logLuma[y * w + x] = gl
                    if gl < minL { minL = gl }
                    if gl > maxL { maxL = gl }
                }
            }
        }

        if !minL.isFinite || !maxL.isFinite || minL > maxL {
            minL = 0.0
            maxL = 0.0
        }

        let safeGam = (targetGamma.isFinite && targetGamma > 0.0) ? targetGamma : 1.0
        let span = maxL - minL
        var monoBytes = Data(count: w * h)
        monoBytes.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<(w * h) {
                if span < 1e-6 {
                    out[i] = 0
                } else {
                    let mLin = min(max((logLuma[i] - minL) / span, 0.0), 1.0)
                    let mEnc = pow(mLin, safeGam)
                    out[i] = UInt8(min(max(Int((255.0 * mEnc).rounded()), 0), 255))
                }
            }
        }

        let monoBuf = GainMapBuffer(
            width: w,
            height: h,
            channels: .mono1ch,
            bytesPerRow: w,
            data: monoBytes
        )
        let monoMeta = GainMapMetadata(
            gainMapMin: [minL],
            gainMapMax: [maxL],
            gamma: [safeGam],
            baseOffset: [valueAt(meta.baseOffset, index: 0)],
            altOffset: [valueAt(meta.altOffset, index: 0)],
            baseHeadroom: meta.baseHeadroom,
            alternateHeadroom: meta.alternateHeadroom,
            useBaseColorSpace: meta.useBaseColorSpace
        )
        return GainMapResult(buffer: monoBuf, metadata: monoMeta)
    }

    internal static func buildQualitySchedule(
        initialBaseQ: Double,
        initialGMQ: Double,
        hasSizeBudget: Bool
    ) -> [(Double, Double)] {
        guard hasSizeBudget else {
            return [(initialBaseQ, initialGMQ)]
        }

        let rawBaseSteps: [Double] = [
            initialBaseQ,
            initialBaseQ - 0.08,
            initialBaseQ - 0.16,
            initialBaseQ - 0.25,
            initialBaseQ - 0.35,
            0.48,
            0.38,
            0.28,
            0.18,
            0.10,
        ]

        var result: [(Double, Double)] = []
        for q in rawBaseSteps {
            let clampedQ = min(max(q, 0.08), initialBaseQ)
            let qRounded = (clampedQ * 100.0).rounded() / 100.0
            let gmQ: Double
            if qRounded >= 0.60 {
                gmQ = initialGMQ
            } else if qRounded >= 0.40 {
                gmQ = min(initialGMQ, 0.75)
            } else {
                gmQ = min(initialGMQ, 0.65)
            }
            if result.last.map({ qRounded < $0.0 - 0.015 }) ?? true {
                result.append((qRounded, gmQ))
            }
        }
        return result
    }

    private func getOrCreateEngine(device: any MTLDevice) throws -> MetalPipelineEngine {
        try engineLock.withLock { cached in
            if let cached {
                return cached
            }
            let created = try MetalPipelineEngine(device: device)
            cached = created
            return created
        }
    }

    private func validateGainMapBuffer(_ buffer: GainMapBuffer) throws {
        guard buffer.width > 0, buffer.height > 0 else {
            throw JPEGEncodeError.invalidGainMapBuffer("Non-positive dimensions \(buffer.width)x\(buffer.height)")
        }
        let bpp = (buffer.channels == .mono1ch) ? 1 : 4
        let minStride = buffer.width * bpp
        guard buffer.bytesPerRow >= minStride else {
            throw JPEGEncodeError.invalidGainMapBuffer(
                "bytesPerRow \(buffer.bytesPerRow) < minimum \(minStride)"
            )
        }
        guard buffer.data.count >= buffer.height * buffer.bytesPerRow else {
            throw JPEGEncodeError.invalidGainMapBuffer(
                "data.count \(buffer.data.count) < required \(buffer.height * buffer.bytesPerRow)"
            )
        }
    }

    private func validateGainMapMetadata(_ metadata: GainMapMetadata, channels: GainMapChannels) throws {
        guard metadata.baseHeadroom.log2Value.isFinite,
              metadata.alternateHeadroom.log2Value.isFinite else {
            throw JPEGEncodeError.invalidGainMapMetadata("Non-finite headroom stops")
        }
        let requiredCount = (channels == .mono1ch) ? 1 : 3
        let arrays: [(String, [Double])] = [
            ("gainMapMin", metadata.gainMapMin),
            ("gainMapMax", metadata.gainMapMax),
            ("gamma", metadata.gamma),
            ("baseOffset", metadata.baseOffset),
            ("altOffset", metadata.altOffset),
        ]
        for (name, arr) in arrays {
            guard !arr.isEmpty else {
                throw JPEGEncodeError.invalidGainMapMetadata("\(name) must not be empty")
            }
            if channels == .rgb3ch && arr.count != 1 && arr.count < 3 {
                throw JPEGEncodeError.invalidGainMapMetadata("\(name) count \(arr.count) invalid for rgb3ch")
            }
            let checkCount = min(arr.count, requiredCount)
            for i in 0..<checkCount {
                guard arr[i].isFinite else {
                    throw JPEGEncodeError.invalidGainMapMetadata("\(name)[\(i)] is non-finite")
                }
            }
        }
        for c in 0..<requiredCount {
            let gMin = valueAt(metadata.gainMapMin, index: c)
            let gMax = valueAt(metadata.gainMapMax, index: c)
            let gam = valueAt(metadata.gamma, index: c)
            guard gam > 0 else {
                throw JPEGEncodeError.invalidGainMapMetadata("gamma[\(c)]=\(gam) must be > 0")
            }
            guard gMin <= gMax + 1e-9 else {
                throw JPEGEncodeError.invalidGainMapMetadata("gainMapMin[\(c)] > gainMapMax[\(c)]")
            }
        }
    }

    private func valueAt(_ array: [Double], index: Int) -> Double {
        if index < array.count {
            return array[index]
        }
        return array[0]
    }

    private func buildHDRToneMapXMP(
        metadata: GainMapMetadata,
        channels: GainMapChannels
    ) throws -> Data {
        let baseH = try formatPOSIXFloat(metadata.baseHeadroom.log2Value, name: "BaseHeadroom")
        let altH = try formatPOSIXFloat(metadata.alternateHeadroom.log2Value, name: "AlternateHeadroom")
        let chCount = (channels == .mono1ch) ? 1 : 3

        var channelItems = ""
        for c in 0..<chCount {
            let gMinVal = valueAt(metadata.gainMapMin, index: c)
            let gMaxVal = max(valueAt(metadata.gainMapMax, index: c), gMinVal)
            let gMin = try formatPOSIXFloat(gMinVal, name: "GainMapMin[\(c)]")
            let gMax = try formatPOSIXFloat(gMaxVal, name: "GainMapMax[\(c)]")
            let gamma = try formatPOSIXFloat(valueAt(metadata.gamma, index: c), name: "Gamma[\(c)]")
            let baseOff = try formatPOSIXFloat(valueAt(metadata.baseOffset, index: c), name: "BaseOffset[\(c)]")
            let altOff = try formatPOSIXFloat(valueAt(metadata.altOffset, index: c), name: "AlternateOffset[\(c)]")
            channelItems += """
                   <rdf:li rdf:parseType="Resource">
                    <HDRToneMap:GainMapMin>\(gMin)</HDRToneMap:GainMapMin>
                    <HDRToneMap:GainMapMax>\(gMax)</HDRToneMap:GainMapMax>
                    <HDRToneMap:Gamma>\(gamma)</HDRToneMap:Gamma>
                    <HDRToneMap:BaseOffset>\(baseOff)</HDRToneMap:BaseOffset>
                    <HDRToneMap:AlternateOffset>\(altOff)</HDRToneMap:AlternateOffset>
                   </rdf:li>

            """
        }

        let baseColorFlag = metadata.useBaseColorSpace ? "True" : "False"
        let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:HDRToneMap="http://ns.apple.com/HDRToneMap/1.0/">
           <HDRToneMap:Version>1</HDRToneMap:Version>
           <HDRToneMap:BaseHeadroom>\(baseH)</HDRToneMap:BaseHeadroom>
           <HDRToneMap:AlternateHeadroom>\(altH)</HDRToneMap:AlternateHeadroom>
           <HDRToneMap:ChannelMetadata>
            <rdf:Seq>
        \(channelItems)    </rdf:Seq>
           </HDRToneMap:ChannelMetadata>
           <HDRToneMap:BaseColorIsWorkingColor>\(baseColorFlag)</HDRToneMap:BaseColorIsWorkingColor>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        guard let data = xmp.data(using: .utf8) else {
            throw JPEGEncodeError.metadataSerializationFailed("UTF-8 encoding failed for HDRToneMap XMP")
        }
        return data
    }

    private func formatPOSIXFloat(_ value: Double, name: String) throws -> String {
        guard value.isFinite else {
            throw JPEGEncodeError.invalidGainMapMetadata("\(name) is non-finite")
        }
        return String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func writeAtomically(data: Data, to outputURL: URL) throws {
        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tmpURL = parentDir.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")

        var renamed = false
        defer {
            if !renamed {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        try data.write(to: tmpURL, options: [])

        let rc = tmpURL.withUnsafeFileSystemRepresentation { srcPath in
            outputURL.withUnsafeFileSystemRepresentation { dstPath in
                guard let srcPath, let dstPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.rename(srcPath, dstPath)
            }
        }
        guard rc == 0 else {
            throw JPEGEncodeError.atomicRenameFailed(errno: errno, path: outputURL.path)
        }
        renamed = true
    }
}
