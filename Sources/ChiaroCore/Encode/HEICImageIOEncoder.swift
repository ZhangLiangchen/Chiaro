import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum HEICEncodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case legacyDualWriteUnsupportedFor3Channel
    case invalidGainMapBuffer(String)
    case invalidGainMapMetadata(String)
    case pixelFormatConversionFailed(String)
    case metadataSerializationFailed(String)
    case destinationCreationFailed(URL)
    case imageFinalizationFailed(URL)
    case atomicRenameFailed(errno: Int32, path: String)

    public var description: String {
        switch self {
        case .legacyDualWriteUnsupportedFor3Channel:
            return "Legacy Apple HDRGainMap dual-write is forbidden for 3-channel gain maps; must use mono1ch ('L008')."
        case .invalidGainMapBuffer(let detail):
            return "Invalid gain map buffer for HEIC export: \(detail)"
        case .invalidGainMapMetadata(let detail):
            return "Invalid gain map metadata for HEIC export: \(detail)"
        case .pixelFormatConversionFailed(let detail):
            return "Failed to prepare HEIC base CGImage: \(detail)"
        case .metadataSerializationFailed(let detail):
            return "Failed to serialize HEIC gain map XMP metadata: \(detail)"
        case .destinationCreationFailed(let url):
            return "Failed to create ImageIO HEIC destination at \(url.path)"
        case .imageFinalizationFailed(let url):
            return "Failed to finalize ImageIO HEIC destination at \(url.path)"
        case .atomicRenameFailed(let code, let path):
            return "Atomic rename failed (errno=\(code)) for \(path)"
        }
    }
}

public struct HEICImageIOEncoder: HEICEncoderProtocol, Sendable {
    public let format: OutputFormat = .heic

    public init() {}

    public func encode(
        frame: RenderedFrame,
        preset: PresetSchema,
        to outputURL: URL
    ) async throws -> ExportArtifact {
        try Task.checkCancellation()

        // ADR-005 / Mandatory Guardrail: NEVER pass 3ch BGRA gain maps to legacy kCGImageAuxiliaryDataTypeHDRGainMap.
        if preset.compatOptions.writeLegacyAppleHDRGainMap {
            if preset.effectiveGainMapChannels(for: .heic) == .rgb3ch || frame.gainMap.buffer.channels == .rgb3ch {
                throw HEICEncodeError.legacyDualWriteUnsupportedFor3Channel
            }
        }

        var gmBuffer = frame.gainMap.buffer
        var gmMeta = frame.gainMap.metadata
        try validateGainMapBuffer(gmBuffer)
        try validateGainMapMetadata(gmMeta, channels: gmBuffer.channels)

        // When 1ch legacy dual-write is active, lock gainMapMin=0.0 and gainMapMax=max(altHeadroom, 0.0)
        // so ISO tmap and legacy Apple HDRGainMap share identical quantized endpoints.
        if preset.compatOptions.writeLegacyAppleHDRGainMap {
            let locked = try lockLegacyOneChannelBounds(buffer: gmBuffer, metadata: gmMeta)
            gmBuffer = locked.buffer
            gmMeta = locked.metadata
        }

        let targetBitDepth = preset.effectiveBitDepth(for: .heic)
        let baseImage = try normalizeBaseCGImage(
            frame.sdrCGImage,
            targetBitDepth: targetBitDepth,
            baseColorSpace: frame.baseColorSpace
        )

        var imageProps = ExifWhitelistBuilder.buildImageIODictionary(
            from: frame.exif,
            customRenderedHDR: preset.compatOptions.writeCustomRenderedHDR
        )
        let quality = preset.quality.isFinite ? min(max(preset.quality, 0.05), 1.0) : 0.90
        imageProps[kCGImageDestinationLossyCompressionQuality] = quality

        let isoAuxInfo = try buildISOGainMapAuxiliaryInfo(buffer: gmBuffer, metadata: gmMeta)
        let legacyAuxInfo: [CFString: Any]? = preset.compatOptions.writeLegacyAppleHDRGainMap
            ? try buildLegacyAppleGainMapAuxiliaryInfo(buffer: gmBuffer, metadata: gmMeta)
            : nil

        try Task.checkCancellation()

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tmpURL = parentDir.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")

        var renamed = false
        defer {
            if !renamed {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        guard let destination = CGImageDestinationCreateWithURL(
            tmpURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw HEICEncodeError.destinationCreationFailed(outputURL)
        }

        CGImageDestinationAddImage(destination, baseImage, imageProps as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(
            destination,
            kCGImageAuxiliaryDataTypeISOGainMap,
            isoAuxInfo as CFDictionary
        )
        if let legacyAuxInfo {
            CGImageDestinationAddAuxiliaryDataInfo(
                destination,
                kCGImageAuxiliaryDataTypeHDRGainMap,
                legacyAuxInfo as CFDictionary
            )
        }

        guard CGImageDestinationFinalize(destination) else {
            throw HEICEncodeError.imageFinalizationFailed(outputURL)
        }

        let renameResult = tmpURL.withUnsafeFileSystemRepresentation { srcPath in
            outputURL.withUnsafeFileSystemRepresentation { dstPath in
                guard let srcPath, let dstPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.rename(srcPath, dstPath)
            }
        }
        guard renameResult == 0 else {
            throw HEICEncodeError.atomicRenameFailed(errno: errno, path: outputURL.path)
        }
        renamed = true

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        return ExportArtifact(
            format: .heic,
            outputURL: outputURL,
            fileSizeBytes: fileSize
        )
    }

    // MARK: - Validation & Helpers

    private func validateGainMapBuffer(_ buffer: GainMapBuffer) throws {
        guard buffer.width > 0, buffer.height > 0 else {
            throw HEICEncodeError.invalidGainMapBuffer("Non-positive dimensions \(buffer.width)x\(buffer.height)")
        }
        let bpp = (buffer.channels == .mono1ch) ? 1 : 4
        let minStride = buffer.width * bpp
        guard buffer.bytesPerRow >= minStride else {
            throw HEICEncodeError.invalidGainMapBuffer(
                "bytesPerRow \(buffer.bytesPerRow) < minimum \(minStride)"
            )
        }
        let requiredBytes = buffer.height * buffer.bytesPerRow
        guard buffer.data.count >= requiredBytes else {
            throw HEICEncodeError.invalidGainMapBuffer(
                "data.count \(buffer.data.count) < required \(requiredBytes)"
            )
        }
    }

    private func validateGainMapMetadata(_ metadata: GainMapMetadata, channels: GainMapChannels) throws {
        guard metadata.baseHeadroom.log2Value.isFinite,
              metadata.alternateHeadroom.log2Value.isFinite else {
            throw HEICEncodeError.invalidGainMapMetadata("Non-finite base/alternate headroom stops")
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
                throw HEICEncodeError.invalidGainMapMetadata("\(name) must not be empty")
            }
            if channels == .rgb3ch && arr.count != 1 && arr.count < 3 {
                throw HEICEncodeError.invalidGainMapMetadata("\(name) count \(arr.count) invalid for rgb3ch")
            }
            let checkCount = min(arr.count, requiredCount)
            for i in 0..<checkCount {
                guard arr[i].isFinite else {
                    throw HEICEncodeError.invalidGainMapMetadata("\(name)[\(i)] is non-finite")
                }
            }
        }
        for c in 0..<requiredCount {
            let gMin = valueAt(metadata.gainMapMin, index: c)
            let gMax = valueAt(metadata.gainMapMax, index: c)
            let gam = valueAt(metadata.gamma, index: c)
            guard gam > 0 else {
                throw HEICEncodeError.invalidGainMapMetadata("gamma[\(c)]=\(gam) must be > 0")
            }
            guard gMin <= gMax + 1e-9 else {
                throw HEICEncodeError.invalidGainMapMetadata("gainMapMin[\(c)]=\(gMin) > gainMapMax[\(c)]=\(gMax)")
            }
        }
    }

    private func valueAt(_ array: [Double], index: Int) -> Double {
        if index < array.count {
            return array[index]
        }
        return array[0]
    }

    private func lockLegacyOneChannelBounds(
        buffer: GainMapBuffer,
        metadata: GainMapMetadata
    ) throws -> (buffer: GainMapBuffer, metadata: GainMapMetadata) {
        let targetMin = 0.0
        let targetMax = max(metadata.alternateHeadroom.log2Value, 0.0)
        guard targetMax.isFinite else {
            throw HEICEncodeError.invalidGainMapMetadata("Non-finite alternate headroom for legacy dual-write")
        }

        let oldMin = valueAt(metadata.gainMapMin, index: 0)
        let oldMax = valueAt(metadata.gainMapMax, index: 0)
        let gam = max(valueAt(metadata.gamma, index: 0), 1e-4)

        let alreadyLocked = abs(oldMin - targetMin) <= 1e-6 && abs(oldMax - targetMax) <= 1e-6
        if alreadyLocked {
            var lockedMeta = metadata
            lockedMeta.gainMapMin = [targetMin]
            lockedMeta.gainMapMax = [targetMax]
            return (buffer, lockedMeta)
        }

        var remapped = buffer.data
        let w = buffer.width
        let h = buffer.height
        let stride = buffer.bytesPerRow
        let oldSpan = oldMax - oldMin

        remapped.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<h {
                let rowBase = y * stride
                for x in 0..<w {
                    let q = ptr[rowBase + x]
                    let g: Double
                    if abs(oldSpan) < 1e-6 {
                        g = oldMin
                    } else {
                        let u = Double(q) / 255.0
                        g = oldMin + oldSpan * pow(u, 1.0 / gam)
                    }
                    if targetMax < 1e-6 {
                        ptr[rowBase + x] = 0
                    } else {
                        let mLin = min(max((g - targetMin) / targetMax, 0.0), 1.0)
                        let mEnc = pow(mLin, gam)
                        let qNew = Int((255.0 * mEnc).rounded())
                        ptr[rowBase + x] = UInt8(min(max(qNew, 0), 255))
                    }
                }
            }
        }

        var updatedBuffer = buffer
        updatedBuffer.data = remapped

        var updatedMeta = metadata
        updatedMeta.gainMapMin = [targetMin]
        updatedMeta.gainMapMax = [targetMax]
        updatedMeta.gamma = [gam]
        updatedMeta.baseOffset = [valueAt(metadata.baseOffset, index: 0)]
        updatedMeta.altOffset = [valueAt(metadata.altOffset, index: 0)]
        return (updatedBuffer, updatedMeta)
    }

    private func normalizeBaseCGImage(
        _ image: CGImage,
        targetBitDepth: BitDepth,
        baseColorSpace: BaseColorSpace
    ) throws -> CGImage {
        let csName: CFString = (baseColorSpace == .srgb) ? CGColorSpace.sRGB : CGColorSpace.displayP3
        guard let targetCS = CGColorSpace(name: csName) else {
            throw HEICEncodeError.pixelFormatConversionFailed("Unable to create target CGColorSpace")
        }

        let desiredBPC = (targetBitDepth == .bit10) ? 16 : 8
        let sameCS = image.colorSpace?.name == csName
        if image.bitsPerComponent == desiredBPC && sameCS {
            return image
        }

        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw HEICEncodeError.pixelFormatConversionFailed("Zero dimensions \(w)x\(h)")
        }

        if targetBitDepth == .bit10 {
            let bpr = w * 8
            var pixels = Data(count: bpr * h)
            let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            let drawn = pixels.withUnsafeMutableBytes { raw -> CGImage? in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 16,
                    bytesPerRow: bpr,
                    space: targetCS,
                    bitmapInfo: bitmapInfo
                ) else {
                    return nil
                }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()
            }
            if let drawn {
                return drawn
            }

            // Fallback to premultipliedLast 16-bit if noneSkipLast CGContext isn't supported for this source
            let premulInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            let drawnPremul = pixels.withUnsafeMutableBytes { raw -> CGImage? in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 16,
                    bytesPerRow: bpr,
                    space: targetCS,
                    bitmapInfo: premulInfo
                ) else {
                    return nil
                }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()
            }
            if let drawnPremul {
                return drawnPremul
            }
            throw HEICEncodeError.pixelFormatConversionFailed("Failed 16-bit CGContext normalization")
        } else {
            let bpr = w * 4
            var pixels = Data(count: bpr * h)
            let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            let drawn = pixels.withUnsafeMutableBytes { raw -> CGImage? in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: targetCS,
                    bitmapInfo: bitmapInfo
                ) else {
                    return nil
                }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()
            }
            guard let drawn else {
                throw HEICEncodeError.pixelFormatConversionFailed("Failed 8-bit CGContext normalization")
            }
            return drawn
        }
    }

    private func buildISOGainMapAuxiliaryInfo(
        buffer: GainMapBuffer,
        metadata: GainMapMetadata
    ) throws -> [CFString: Any] {
        let pixelFormat: OSType = (buffer.channels == .mono1ch)
            ? kCVPixelFormatType_OneComponent8
            : kCVPixelFormatType_32BGRA

        let desc: [CFString: Any] = [
            kCGImagePropertyWidth: buffer.width,
            kCGImagePropertyHeight: buffer.height,
            kCGImagePropertyBytesPerRow: buffer.bytesPerRow,
            kCGImagePropertyPixelFormat: pixelFormat,
        ]

        let xmpData = try buildHDRToneMapXMP(metadata: metadata, channels: buffer.channels)
        guard let cgMeta = CGImageMetadataCreateFromXMPData(xmpData as CFData) else {
            throw HEICEncodeError.metadataSerializationFailed("CGImageMetadataCreateFromXMPData failed for HDRToneMap")
        }

        return [
            kCGImageAuxiliaryDataInfoData: buffer.data as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: desc as CFDictionary,
            kCGImageAuxiliaryDataInfoMetadata: cgMeta,
        ]
    }

    private func buildLegacyAppleGainMapAuxiliaryInfo(
        buffer: GainMapBuffer,
        metadata: GainMapMetadata
    ) throws -> [CFString: Any] {
        let desc: [CFString: Any] = [
            kCGImagePropertyWidth: buffer.width,
            kCGImagePropertyHeight: buffer.height,
            kCGImagePropertyBytesPerRow: buffer.bytesPerRow,
            kCGImagePropertyPixelFormat: kCVPixelFormatType_OneComponent8,
        ]

        let linearHeadroom = max(exp2(max(metadata.alternateHeadroom.log2Value, 0.0)), 1.0)
        guard linearHeadroom.isFinite else {
            throw HEICEncodeError.invalidGainMapMetadata("Non-finite linear headroom for HDRGainMap")
        }

        let xmpData = try buildLegacyHDRGainMapXMP(linearHeadroom: linearHeadroom)
        guard let cgMeta = CGImageMetadataCreateFromXMPData(xmpData as CFData) else {
            throw HEICEncodeError.metadataSerializationFailed("CGImageMetadataCreateFromXMPData failed for HDRGainMap")
        }

        return [
            kCGImageAuxiliaryDataInfoData: buffer.data as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: desc as CFDictionary,
            kCGImageAuxiliaryDataInfoMetadata: cgMeta,
        ]
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
            throw HEICEncodeError.metadataSerializationFailed("UTF-8 encoding failed for HDRToneMap XMP")
        }
        return data
    }

    private func buildLegacyHDRGainMapXMP(linearHeadroom: Double) throws -> Data {
        let headroomStr = try formatPOSIXFloat(linearHeadroom, name: "HDRGainMapHeadroom")
        let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:HDRGainMap="http://ns.apple.com/HDRGainMap/1.0/">
           <HDRGainMap:HDRGainMapVersion>131072</HDRGainMap:HDRGainMapVersion>
           <HDRGainMap:HDRGainMapHeadroom>\(headroomStr)</HDRGainMap:HDRGainMapHeadroom>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        guard let data = xmp.data(using: .utf8) else {
            throw HEICEncodeError.metadataSerializationFailed("UTF-8 encoding failed for HDRGainMap XMP")
        }
        return data
    }

    private func formatPOSIXFloat(_ value: Double, name: String) throws -> String {
        guard value.isFinite else {
            throw HEICEncodeError.invalidGainMapMetadata("\(name) is non-finite")
        }
        return String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
