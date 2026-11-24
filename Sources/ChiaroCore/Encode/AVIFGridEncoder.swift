import CLibAVIFBridge
import CoreGraphics
import Darwin
import Foundation

public enum AVIFEncodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidDimensions(width: Int, height: Int, reason: String)
    case invalidGainMapBuffer(String)
    case invalidGainMapMetadata(String)
    case pixelExtractionFailed(String)
    case encodeFailed(status: Int32, message: String)
    case atomicRenameFailed(errno: Int32, path: String)

    public var description: String {
        switch self {
        case let .invalidDimensions(w, h, reason):
            return "Invalid AVIF dimensions \(w)x\(h): \(reason)"
        case let .invalidGainMapBuffer(detail):
            return "Invalid gain map buffer for AVIF export: \(detail)"
        case let .invalidGainMapMetadata(detail):
            return "Invalid gain map metadata for AVIF export: \(detail)"
        case let .pixelExtractionFailed(detail):
            return "Failed to extract AVIF base pixels: \(detail)"
        case let .encodeFailed(status, msg):
            return "libavif encode failed (status=\(status)): \(msg)"
        case let .atomicRenameFailed(code, path):
            return "Atomic rename failed (errno=\(code)) for \(path)"
        }
    }
}

public struct AVIFGridEncoder: AVIFEncoderProtocol, Sendable {
    public let format: OutputFormat = .avif
    public let speed: Int
    public let maxThreads: Int

    public init(speed: Int = 6, maxThreads: Int = 4) {
        self.speed = min(max(speed, 0), 10)
        self.maxThreads = max(1, maxThreads)
    }

    public func encode(
        frame: RenderedFrame,
        preset: PresetSchema,
        to outputURL: URL
    ) async throws -> ExportArtifact {
        try Task.checkCancellation()

        let baseImage = frame.sdrCGImage
        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0 else {
            throw AVIFEncodeError.invalidDimensions(width: width, height: height, reason: "Non-positive dimensions")
        }

        let gmBuffer = frame.gainMap.buffer
        let gmMeta = frame.gainMap.metadata
        try validateGainMapBuffer(gmBuffer)
        try validateGainMapMetadata(gmMeta, channels: gmBuffer.channels)

        let willTile = (width > 4096) || (height > 4096) || ((Int64(width) * Int64(height)) > 8_912_896)
        if willTile {
            guard width % 2 == 0, height % 2 == 0 else {
                throw AVIFEncodeError.invalidDimensions(
                    width: width,
                    height: height,
                    reason: "Gridded YUV420 AVIF requires even base dimensions"
                )
            }
            if gmBuffer.channels == .rgb3ch {
                guard gmBuffer.width % 2 == 0, gmBuffer.height % 2 == 0 else {
                    throw AVIFEncodeError.invalidDimensions(
                        width: gmBuffer.width,
                        height: gmBuffer.height,
                        reason: "Gridded 3ch YUV420 gain map requires even dimensions"
                    )
                }
            }
        }

        let targetBitDepth = preset.effectiveBitDepth(for: .avif)
        let extractedBase = try extractBasePixels(from: baseImage, targetBitDepth: targetBitDepth, baseColorSpace: frame.baseColorSpace)

        let csName: CFString = (frame.baseColorSpace == .srgb) ? CGColorSpace.sRGB : CGColorSpace.displayP3
        let iccData = CGColorSpace(name: csName)?.copyICCData() as Data?
        let colorPrimaries: HDRAVIFColorPrimaries = (frame.baseColorSpace == .srgb)
            ? HDR_AVIF_PRIMARIES_BT709_SRGB
            : HDR_AVIF_PRIMARIES_DISPLAY_P3

        let gmChannels: UInt32 = (gmBuffer.channels == .mono1ch) ? 1 : 3
        let gmPixelFormat: HDRAVIFPixelFormat = (gmBuffer.channels == .mono1ch)
            ? HDR_AVIF_PIXFMT_GRAY8
            : HDR_AVIF_PIXFMT_BGRA8

        let avifMeta = buildAVIFMetadata(gmMeta, channels: gmBuffer.channels)
        let exifTIFF = try ExifWhitelistBuilder.buildTIFFData(
            from: frame.exif,
            customRenderedHDR: preset.compatOptions.writeCustomRenderedHDR
        )

        let codec: HDRAVIFCodec = (preset.avifCodec == .svtAV1) ? HDR_AVIF_CODEC_SVT : HDR_AVIF_CODEC_AOM
        let quality = min(max(preset.qualityPercent, 1), 100)
        let gmQuality = min(max(preset.effectiveGainMapQualityPercent, 1), 100)

        try Task.checkCancellation()

        var outBuffer = HDRAVIFBuffer()
        var errBuf = [CChar](repeating: 0, count: 1024)
        defer { hdr_libavif_free_buffer(&outBuffer) }

        let status: HDRAVIFStatus = extractedBase.data.withUnsafeBytes { basePtr in
            gmBuffer.data.withUnsafeBytes { gmPtr in
                exifTIFF.withUnsafeBytes { exifPtr in
                    let encodeWithICC: (UnsafePointer<UInt8>?, Int) -> HDRAVIFStatus = { iccBase, iccSize in
                        var req = HDRAVIFEncodeRequest(
                            base_pixels: basePtr.bindMemory(to: UInt8.self).baseAddress,
                            base_width: UInt32(width),
                            base_height: UInt32(height),
                            base_row_bytes: UInt32(extractedBase.bytesPerRow),
                            base_pixel_format: extractedBase.pixelFormat,
                            target_bit_depth: UInt32(targetBitDepth.rawValue),
                            color_primaries: colorPrimaries,
                            gain_map_pixels: gmPtr.bindMemory(to: UInt8.self).baseAddress,
                            gain_map_width: UInt32(gmBuffer.width),
                            gain_map_height: UInt32(gmBuffer.height),
                            gain_map_row_bytes: UInt32(gmBuffer.bytesPerRow),
                            gain_map_pixel_format: gmPixelFormat,
                            gain_map_channels: gmChannels,
                            gain_map_meta: avifMeta,
                            icc_data: iccBase,
                            icc_size: iccSize,
                            exif_data: exifPtr.bindMemory(to: UInt8.self).baseAddress,
                            exif_size: exifTIFF.count,
                            codec: codec,
                            quality: Int32(quality),
                            gain_map_quality: Int32(gmQuality),
                            speed: Int32(speed),
                            max_threads: Int32(maxThreads),
                            enable_tune_iq: 1
                        )
                        return hdr_avif_encode(&req, &outBuffer, &errBuf, errBuf.count)
                    }

                    if let iccData, !iccData.isEmpty {
                        return iccData.withUnsafeBytes { iccPtr in
                            encodeWithICC(iccPtr.bindMemory(to: UInt8.self).baseAddress, iccData.count)
                        }
                    } else {
                        return encodeWithICC(nil, 0)
                    }
                }
            }
        }

        guard status == HDR_AVIF_OK, let outBytes = outBuffer.data, outBuffer.size > 0 else {
            let errLen = errBuf.firstIndex(of: 0) ?? errBuf.count
            let msgBytes = errBuf.prefix(errLen).map { UInt8(bitPattern: $0) }
            let msg = String(decoding: msgBytes, as: UTF8.self)
            throw AVIFEncodeError.encodeFailed(status: Int32(status.rawValue), message: msg)
        }

        let avifData = Data(bytes: outBytes, count: outBuffer.size)
        try writeAtomically(data: avifData, to: outputURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(avifData.count)

        let usedGrid = (outBuffer.used_grid_tiling != 0)
        return ExportArtifact(
            format: .avif,
            outputURL: outputURL,
            fileSizeBytes: fileSize,
            usedGridTiling: usedGrid,
            gridRows: usedGrid ? Int(outBuffer.grid_rows) : nil,
            gridColumns: usedGrid ? Int(outBuffer.grid_columns) : nil
        )
    }

    // MARK: - Pixel Extraction & Metadata Helpers

    private struct ExtractedBasePixels {
        let data: Data
        let bytesPerRow: Int
        let pixelFormat: HDRAVIFPixelFormat
    }

    private func extractBasePixels(
        from image: CGImage,
        targetBitDepth: BitDepth,
        baseColorSpace: BaseColorSpace
    ) throws -> ExtractedBasePixels {
        let w = image.width
        let h = image.height
        let bpc = image.bitsPerComponent
        let bpp = image.bitsPerPixel
        let bpr = image.bytesPerRow
        let info = image.bitmapInfo
        let alpha = image.alphaInfo
        let byteOrder = info.intersection(.byteOrderMask)

        let csName: CFString = (baseColorSpace == .srgb) ? CGColorSpace.sRGB : CGColorSpace.displayP3
        let matchesTargetColorSpace = (image.colorSpace == nil || image.colorSpace?.name == csName)

        if matchesTargetColorSpace, let providerData = image.dataProvider?.data as Data? {
            if bpc == 16, bpp == 64, bpr >= w * 8,
               byteOrder == .byteOrder16Little,
               alpha == .noneSkipLast || alpha == .premultipliedLast || alpha == .last,
               providerData.count >= h * bpr {
                return ExtractedBasePixels(
                    data: providerData,
                    bytesPerRow: bpr,
                    pixelFormat: HDR_AVIF_PIXFMT_RGBA16
                )
            }

            if bpc == 8, bpp == 32, bpr >= w * 4,
               (byteOrder == [] || byteOrder == .byteOrder32Big),
               alpha == .noneSkipLast || alpha == .premultipliedLast || alpha == .last,
               providerData.count >= h * bpr {
                return ExtractedBasePixels(
                    data: providerData,
                    bytesPerRow: bpr,
                    pixelFormat: HDR_AVIF_PIXFMT_RGBA8
                )
            }

            if bpc == 8, bpp == 32, bpr >= w * 4,
               byteOrder == .byteOrder32Little,
               alpha == .noneSkipFirst || alpha == .premultipliedFirst || alpha == .first,
               providerData.count >= h * bpr {
                return ExtractedBasePixels(
                    data: providerData,
                    bytesPerRow: bpr,
                    pixelFormat: HDR_AVIF_PIXFMT_BGRA8
                )
            }
        }

        guard let cs = CGColorSpace(name: csName) else {
            throw AVIFEncodeError.pixelExtractionFailed("Unable to resolve CGColorSpace")
        }

        if targetBitDepth == .bit10 {
            let rowBytes = w * 8
            var out = Data(count: rowBytes * h)
            let ok = out.withUnsafeMutableBytes { raw -> Bool in
                let infos: [UInt32] = [
                    CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue,
                    CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue,
                ]
                for bm in infos {
                    if let ctx = CGContext(
                        data: raw.baseAddress,
                        width: w,
                        height: h,
                        bitsPerComponent: 16,
                        bytesPerRow: rowBytes,
                        space: cs,
                        bitmapInfo: bm
                    ) {
                        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                        return true
                    }
                }
                return false
            }
            if ok {
                return ExtractedBasePixels(
                    data: out,
                    bytesPerRow: rowBytes,
                    pixelFormat: HDR_AVIF_PIXFMT_RGBA16
                )
            }
        }

        let rowBytes8 = w * 4
        var out8 = Data(count: rowBytes8 * h)
        let ok8 = out8.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes8,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok8 else {
            throw AVIFEncodeError.pixelExtractionFailed("CGContext RGBA normalization failed")
        }
        return ExtractedBasePixels(
            data: out8,
            bytesPerRow: rowBytes8,
            pixelFormat: HDR_AVIF_PIXFMT_RGBA8
        )
    }

    private func validateGainMapBuffer(_ buffer: GainMapBuffer) throws {
        guard buffer.width > 0, buffer.height > 0 else {
            throw AVIFEncodeError.invalidGainMapBuffer("Non-positive dimensions \(buffer.width)x\(buffer.height)")
        }
        let bpp = (buffer.channels == .mono1ch) ? 1 : 4
        let minStride = buffer.width * bpp
        guard buffer.bytesPerRow >= minStride else {
            throw AVIFEncodeError.invalidGainMapBuffer(
                "bytesPerRow \(buffer.bytesPerRow) < minimum \(minStride)"
            )
        }
        guard buffer.data.count >= buffer.height * buffer.bytesPerRow else {
            throw AVIFEncodeError.invalidGainMapBuffer(
                "data.count \(buffer.data.count) < required \(buffer.height * buffer.bytesPerRow)"
            )
        }
    }

    private func validateGainMapMetadata(_ metadata: GainMapMetadata, channels: GainMapChannels) throws {
        guard metadata.baseHeadroom.log2Value.isFinite,
              metadata.alternateHeadroom.log2Value.isFinite else {
            throw AVIFEncodeError.invalidGainMapMetadata("Non-finite headroom stops")
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
                throw AVIFEncodeError.invalidGainMapMetadata("\(name) must not be empty")
            }
            let checkCount = min(arr.count, requiredCount)
            for i in 0..<checkCount {
                guard arr[i].isFinite else {
                    throw AVIFEncodeError.invalidGainMapMetadata("\(name)[\(i)] is non-finite")
                }
            }
        }
        for c in 0..<requiredCount {
            let gMin = valueAt(metadata.gainMapMin, index: c)
            let gMax = valueAt(metadata.gainMapMax, index: c)
            let gam = valueAt(metadata.gamma, index: c)
            guard gam > 0 else {
                throw AVIFEncodeError.invalidGainMapMetadata("gamma[\(c)]=\(gam) must be > 0")
            }
            guard gMin <= gMax + 1e-9 else {
                throw AVIFEncodeError.invalidGainMapMetadata("gainMapMin[\(c)] > gainMapMax[\(c)]")
            }
        }
    }

    private func buildAVIFMetadata(
        _ metadata: GainMapMetadata,
        channels: GainMapChannels
    ) -> HDRAVIFGainMapMetadata {
        func triple(_ arr: [Double]) -> (Double, Double, Double) {
            if channels == .mono1ch || arr.count == 1 {
                let v = arr[0]
                return (v, v, v)
            }
            return (valueAt(arr, index: 0), valueAt(arr, index: 1), valueAt(arr, index: 2))
        }

        let minT = triple(metadata.gainMapMin)
        let rawMaxT = triple(metadata.gainMapMax)
        let maxT = (max(rawMaxT.0, minT.0), max(rawMaxT.1, minT.1), max(rawMaxT.2, minT.2))

        return HDRAVIFGainMapMetadata(
            gain_map_min: minT,
            gain_map_max: maxT,
            gain_map_gamma: triple(metadata.gamma),
            base_offset: triple(metadata.baseOffset),
            alternate_offset: triple(metadata.altOffset),
            base_hdr_headroom_stops: metadata.baseHeadroom.log2Value,
            alternate_hdr_headroom_stops: metadata.alternateHeadroom.log2Value,
            use_base_color_space: metadata.useBaseColorSpace ? 1 : 0
        )
    }

    private func valueAt(_ array: [Double], index: Int) -> Double {
        if index < array.count {
            return array[index]
        }
        return array[0]
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
            throw AVIFEncodeError.atomicRenameFailed(errno: errno, path: outputURL.path)
        }
        renamed = true
    }
}
