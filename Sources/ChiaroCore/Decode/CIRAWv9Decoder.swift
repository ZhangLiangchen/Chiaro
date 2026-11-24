import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import os
import simd

public final class CIRAWv9Decoder: ARWDecoderProtocol, Sendable {
    private static let decodeQueue = DispatchQueue(
        label: "io.github.zhangliangchen.chiaro.decode.ciraw9",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static let xyzD65ToDisplayP3RowMajor: [Double] = {
        let p3ToXYZ = ColorTransforms.rec2020ToXYZD65 * ColorTransforms.displayP3ToRec2020
        let xyzToP3 = p3ToXYZ.inverse
        let t = xyzToP3.transpose
        return [
            t.columns.0.x, t.columns.0.y, t.columns.0.z,
            t.columns.1.x, t.columns.1.y, t.columns.1.z,
            t.columns.2.x, t.columns.2.y, t.columns.2.z,
        ]
    }()

    private let libRawFallback: LibRawDecoder
    private let ciContext: CIContext
    private let resourceTimeoutSeconds: TimeInterval
    private let requireEDRHighlightHeadroom: Bool

    public init(
        libRawFallback: LibRawDecoder = LibRawDecoder(),
        mtlDevice: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        resourceTimeoutSeconds: TimeInterval = 30.0,
        requireEDRHighlightHeadroom: Bool = false
    ) {
        self.libRawFallback = libRawFallback
        self.resourceTimeoutSeconds = resourceTimeoutSeconds
        self.requireEDRHighlightHeadroom = requireEDRHighlightHeadroom

        var opts: [CIContextOption: Any] = [
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
            .outputPremultiplied: false,
        ]
        if let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            opts[.workingColorSpace] = p3
        }
        if let dev = mtlDevice {
            self.ciContext = CIContext(mtlDevice: dev, options: opts)
        } else {
            self.ciContext = CIContext(options: opts)
        }
    }

    public func decodeFull(url: URL, options: DecodeOptions = .default) async throws -> DecodedRAWFrame {
        try await decodeWithFallback(url: url, options: options, isProxy: options.isProxy)
    }

    public func decodeProxy(url: URL) async throws -> DecodedRAWFrame {
        let proxyOpts = DecodeOptions(
            backend: .ciraw9,
            highlightMode: .opposedInpaint,
            isProxy: true,
            maxThreadsPerWorker: 2,
            customRenderedHDR: false
        )
        return try await decodeWithFallback(url: url, options: proxyOpts, isProxy: true)
    }

    private func decodeWithFallback(
        url: URL,
        options: DecodeOptions,
        isProxy: Bool
    ) async throws -> DecodedRAWFrame {
        try Task.checkCancellation()
        guard url.isFileURL else {
            throw RAWDecodeError.invalidFileURL(url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RAWDecodeError.fileNotFound(url)
        }

        // 1. Fast (<1ms) pure-Swift TIFF/SubIFD/ExifIFD pre-flight + ImageIO auxiliary metadata
        let inspection = TIFFPreflightInspector.inspect(
            url: url,
            customRenderedHDR: options.customRenderedHDR
        )
        try Task.checkCancellation()

        if inspection?.isLosslessMS == true {
            var frame = try await fallbackDecode(url: url, options: options, isProxy: isProxy)
            frame.fallbackReason = "Sony Lossless M/S (YCbCr) detected; routed to LibRawDecoder"
            return frame
        }

        // 2. macOS 27.0+ availability check (Package.swift targets .macOS(.v15))
        guard #available(macOS 27.0, *) else {
            var frame = try await fallbackDecode(url: url, options: options, isProxy: isProxy)
            frame.fallbackReason = "CIRAWDecoderVersion9 requires macOS 27.0+"
            return frame
        }

        // 3. Run non-Sendable CIRAWFilter isolated on a blocking worker queue (off cooperative pool)
        do {
            return try await runCIRAWDecodeOffCooperativePool(
                url: url,
                options: options,
                isProxy: isProxy,
                inspection: inspection
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch RAWDecodeError.cancelled {
            throw RAWDecodeError.cancelled
        } catch {
            try Task.checkCancellation()
            var frame = try await fallbackDecode(url: url, options: options, isProxy: isProxy)
            frame.fallbackReason = "CIRAWv9 fallback: \(error)"
            return frame
        }
    }

    private func fallbackDecode(
        url: URL,
        options: DecodeOptions,
        isProxy: Bool
    ) async throws -> DecodedRAWFrame {
        if isProxy {
            return try await libRawFallback.decodeProxy(url: url)
        } else {
            return try await libRawFallback.decodeFull(url: url, options: options)
        }
    }

    @available(macOS 27.0, *)
    private func runCIRAWDecodeOffCooperativePool(
        url: URL,
        options: DecodeOptions,
        isProxy: Bool,
        inspection: TIFFPreflightResult?
    ) async throws -> DecodedRAWFrame {
        try Task.checkCancellation()
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.decodeQueue.async {
                    do {
                        if cancelFlag.withLock({ $0 }) {
                            throw RAWDecodeError.cancelled
                        }
                        let decoded = try self.decodeSyncCIRAWv9(
                            url: url,
                            options: options,
                            isProxy: isProxy,
                            inspection: inspection,
                            cancelFlag: cancelFlag
                        )
                        if cancelFlag.withLock({ $0 }) {
                            throw RAWDecodeError.cancelled
                        }
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelFlag.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return frame
    }

    @available(macOS 27.0, *)
    private func decodeSyncCIRAWv9(
        url: URL,
        options: DecodeOptions,
        isProxy: Bool,
        inspection: TIFFPreflightResult?,
        cancelFlag: OSAllocatedUnfairLock<Bool>
    ) throws -> DecodedRAWFrame {
        if cancelFlag.withLock({ $0 }) {
            throw RAWDecodeError.cancelled
        }
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RAWDecodeError.cirawUnsupported("CIRAWFilter(imageURL:) returned nil for \(url.lastPathComponent)")
        }

        guard filter.supportedDecoderVersions.contains(.version9) else {
            throw RAWDecodeError.cirawUnsupported("CIRAWDecoderVersion.version9 not in supportedDecoderVersions")
        }

        // Sanity-reference supportedCameraModels(with: .version9) for API availability coverage,
        // without rejecting on EXIF model string equality (Apple uses marketing names like "Sony Alpha ILCE-7C II").
        _ = CIRAWFilter.supportedCameraModels(with: .version9)

        // Capture original orientation BEFORE setting .up so CIRAWFilter renders unrotated sensor geometry
        // matching MetalPipelineEngine.orient_crop_resize_kernel (no double rotation).
        let rawOrientation = inspection?.exif.orientation ?? Int(filter.orientation.rawValue)
        let normalizedOrientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
        filter.orientation = .up

        // Explicitly override default (.version8 on ILCE-7CM2) to .version9
        filter.decoderVersion = .version9

        // Download / ensure ANE demosaic+denoise resources
        let sem = DispatchSemaphore(value: 0)
        let errBox = SendableErrorBox()
        let progress = filter.downloadResources(timeout: resourceTimeoutSeconds) { err in
            errBox.set(err)
            sem.signal()
        }
        let deadline = DispatchTime.now() + resourceTimeoutSeconds + 2.0
        while true {
            if cancelFlag.withLock({ $0 }) {
                progress.cancel()
                throw RAWDecodeError.cancelled
            }
            let slice = min(deadline, DispatchTime.now() + 0.1)
            if sem.wait(timeout: slice) == .success {
                break
            }
            if DispatchTime.now() >= deadline {
                progress.cancel()
                throw RAWDecodeError.cirawFailed("Timed out waiting for CIRAWv9 resources")
            }
        }
        if let dlErr = errBox.get() {
            throw RAWDecodeError.cirawFailed("Resource download failed: \(dlErr.localizedDescription)")
        }

        if cancelFlag.withLock({ $0 }) {
            throw RAWDecodeError.cancelled
        }

        // Force linear unclipped HDR output with Apple tone curve disabled
        filter.baselineExposure = 0.0
        filter.shadowBias = 0.0
        filter.boostAmount = 0.0
        filter.localToneMapAmount = 0.0
        filter.extendedDynamicRangeAmount = 2.0
        if filter.isHighlightRecoverySupported {
            filter.isHighlightRecoveryEnabled = true
        }
        if isProxy {
            filter.isDraftModeEnabled = true
            filter.scaleFactor = 0.5
        } else {
            filter.scaleFactor = 1.0
        }

        guard let outImage = filter.outputImage else {
            throw RAWDecodeError.cirawFailed("CIRAWFilter.outputImage returned nil")
        }
        guard let p3Space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw RAWDecodeError.cirawFailed("Failed to create CGColorSpace.extendedLinearDisplayP3")
        }

        let extent = outImage.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else {
            throw RAWDecodeError.cirawFailed("Invalid CIRAWFilter output extent \(extent)")
        }

        if cancelFlag.withLock({ $0 }) {
            throw RAWDecodeError.cancelled
        }

        let bytesPerPixel = 8 // CIFormat.RGBAh = 4 x Float16
        let rowBytes = width * bytesPerPixel
        var pixelData = Data(count: rowBytes * height)

        autoreleasepool {
            pixelData.withUnsafeMutableBytes { rawPtr in
                guard let base = rawPtr.baseAddress else { return }
                ciContext.render(
                    outImage,
                    toBitmap: base,
                    rowBytes: rowBytes,
                    bounds: extent,
                    format: .RGBAh,
                    colorSpace: p3Space
                )
            }
        }

        if cancelFlag.withLock({ $0 }) {
            throw RAWDecodeError.cancelled
        }

        var maxPixel: Float = 0.0
        var hasNonFinite = false
        pixelData.withUnsafeBytes { rawPtr in
            let halfs = rawPtr.bindMemory(to: UInt16.self)
            var i = 0
            while i + 2 < halfs.count {
                let r = Float(Float16(bitPattern: halfs[i]))
                let g = Float(Float16(bitPattern: halfs[i + 1]))
                let b = Float(Float16(bitPattern: halfs[i + 2]))
                if !r.isFinite || !g.isFinite || !b.isFinite {
                    hasNonFinite = true
                    break
                }
                if r > maxPixel { maxPixel = r }
                if g > maxPixel { maxPixel = g }
                if b > maxPixel { maxPixel = b }
                i += 4
            }
        }

        if hasNonFinite {
            throw RAWDecodeError.cirawFailed("Non-finite pixel detected in CIRAWv9 RGBAh output")
        }
        if requireEDRHighlightHeadroom && maxPixel <= 1.0 {
            throw RAWDecodeError.cirawFailed("EDR headroom missing (maxPixel=\(maxPixel) <= 1.0)")
        }

        var exif = inspection?.exif ?? TIFFPreflightInspector.readCGImageSourceFallbackExif(
            url: url,
            fallbackOrientation: normalizedOrientation,
            customRenderedHDR: options.customRenderedHDR
        )
        exif.orientation = normalizedOrientation
        if options.customRenderedHDR {
            exif.customRendered = 3
        }

        // CIRAWFilter outputs extendedLinearDisplayP3 with As-Shot WB already adapted to D65.
        // Setting camXYZ = xyzD65ToDisplayP3, wbMultipliers = [1, 1, 1, 1], asShotWBApplied = true
        // aligns ColorTransforms.estimateAsShotSceneXYZ / estimateSceneKelvin with D65 scene reference.
        let matrices = CameraColorMatrices(
            camXYZ: Self.xyzD65ToDisplayP3RowMajor,
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: [1.0, 1.0, 1.0, 1.0],
            asShotWBApplied: true
        )

        return DecodedRAWFrame(
            sourceURL: url,
            backendUsed: .ciraw9,
            fallbackReason: nil,
            payload: .linearRGB16F(
                width: width,
                height: height,
                colorSpace: .extendedLinearDisplayP3,
                data: pixelData
            ),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: width, height: height),
            orientation: normalizedOrientation,
            colorMatrices: matrices,
            isLosslessMS: false,
            exif: exif
        )
    }
}

private final class SendableErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var err: (any Error)?
    func set(_ e: (any Error)?) { lock.lock(); err = e; lock.unlock() }
    func get() -> (any Error)? { lock.lock(); defer { lock.unlock() }; return err }
}

// MARK: - Fast Pure-Swift TIFF/SubIFD/ExifIFD Pre-flight Inspector

private struct TIFFPreflightResult: Sendable {
    let isLosslessMS: Bool
    let exif: WhitelistedExif
}

private enum TIFFPreflightInspector {
    private static let maxEntriesPerIFD = 512
    private static let maxExternalTagBytes = 2048

    static func inspect(url: URL, customRenderedHDR: Bool) -> TIFFPreflightResult? {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fh.close() }

        guard let header = readBytes(fh: fh, offset: 0, count: 8), header.count == 8 else {
            return nil
        }

        let isLittleEndian: Bool
        if header[0] == 0x49 && header[1] == 0x49 && header[2] == 0x2A && header[3] == 0x00 {
            isLittleEndian = true
        } else if header[0] == 0x4D && header[1] == 0x4D && header[2] == 0x00 && header[3] == 0x2A {
            isLittleEndian = false
        } else {
            return nil
        }

        let ifd0Offset = readUInt32(header, at: 4, littleEndian: isLittleEndian)
        guard ifd0Offset >= 8 else { return nil }

        var visitedIFDs = Set<UInt32>()
        var subIFDOffsets: [UInt32] = []
        var exifIFDOffset: UInt32?
        var gpsIFDOffset: UInt32?

        var make: String?
        var model: String?
        var orientation: Int = 1
        var dateTimeIFD0: String?
        var detectedLosslessMS = false

        // Walk IFD0 chain (bounded to max 4 chained IFDs)
        var currentIFDOffset: UInt32? = ifd0Offset
        var chainSteps = 0
        while let offset = currentIFDOffset, offset >= 8, !visitedIFDs.contains(offset), chainSteps < 4 {
            visitedIFDs.insert(offset)
            chainSteps += 1
            guard let ifd = readIFD(fh: fh, offset: offset, littleEndian: isLittleEndian) else {
                break
            }

            var subfileType: UInt32?
            var compression: UInt16?
            var photometric: UInt16?
            var samplesPerPixel: UInt16?
            var bitsPerSample: [UInt16] = []

            for entry in ifd.entries {
                switch entry.tag {
                case 0x00FE: // NewSubfileType
                    subfileType = readFirstUInt32(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0102: // BitsPerSample
                    bitsPerSample = readUInt16Array(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0103: // Compression
                    compression = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0106: // PhotometricInterpretation
                    photometric = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x010F: // Make
                    if make == nil {
                        make = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                    }
                case 0x0110: // Model
                    if model == nil {
                        model = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                    }
                case 0x0112: // Orientation
                    if chainSteps == 1, let v = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian),
                       (1...8).contains(Int(v)) {
                        orientation = Int(v)
                    }
                case 0x0115: // SamplesPerPixel
                    samplesPerPixel = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0132: // DateTime
                    if dateTimeIFD0 == nil {
                        dateTimeIFD0 = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                    }
                case 0x014A: // SubIFDs
                    subIFDOffsets.append(contentsOf: readUInt32Array(fh: fh, entry: entry, littleEndian: isLittleEndian))
                case 0x8769: // ExifIFD
                    if exifIFDOffset == nil {
                        exifIFDOffset = readFirstUInt32(fh: fh, entry: entry, littleEndian: isLittleEndian)
                    }
                case 0x8825: // GPSIFD
                    if gpsIFDOffset == nil {
                        gpsIFDOffset = readFirstUInt32(fh: fh, entry: entry, littleEndian: isLittleEndian)
                    }
                default:
                    break
                }
            }

            if isSonyLosslessMSIFD(
                subfileType: subfileType,
                photometric: photometric,
                samplesPerPixel: samplesPerPixel,
                bitsPerSample: bitsPerSample,
                compression: compression,
                isSubIFD: false
            ) {
                detectedLosslessMS = true
            }

            currentIFDOffset = ifd.nextIFDOffset > 0 ? ifd.nextIFDOffset : nil
        }

        // Inspect all SubIFDs for Sony Lossless M/S YCbCr RAW descriptor
        for subOffset in subIFDOffsets where subOffset >= 8 && !visitedIFDs.contains(subOffset) {
            visitedIFDs.insert(subOffset)
            guard let subIFD = readIFD(fh: fh, offset: subOffset, littleEndian: isLittleEndian) else {
                continue
            }
            var subfileType: UInt32?
            var compression: UInt16?
            var photometric: UInt16?
            var samplesPerPixel: UInt16?
            var bitsPerSample: [UInt16] = []

            for entry in subIFD.entries {
                switch entry.tag {
                case 0x00FE:
                    subfileType = readFirstUInt32(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0102:
                    bitsPerSample = readUInt16Array(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0103:
                    compression = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0106:
                    photometric = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x0115:
                    samplesPerPixel = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x8769:
                    if exifIFDOffset == nil {
                        exifIFDOffset = readFirstUInt32(fh: fh, entry: entry, littleEndian: isLittleEndian)
                    }
                case 0x8825:
                    if gpsIFDOffset == nil {
                        gpsIFDOffset = readFirstUInt32(fh: fh, entry: entry, littleEndian: isLittleEndian)
                    }
                default:
                    break
                }
            }

            if isSonyLosslessMSIFD(
                subfileType: subfileType,
                photometric: photometric,
                samplesPerPixel: samplesPerPixel,
                bitsPerSample: bitsPerSample,
                compression: compression,
                isSubIFD: true
            ) {
                detectedLosslessMS = true
            }
        }

        // Inspect ExifIFD (strictly skipping 0x927C MakerNote)
        var exposureTime: Double?
        var fNumber: Double?
        var isoSpeed: Int?
        var recommendedExposureIndex: Int?
        var dateTimeOriginal: String?
        var offsetTimeOriginal: String?
        var offsetTimeFallback: String?
        var subSecTimeOriginal: String?
        var subSecTimeFallback: String?
        var exposureBiasEV: Double?
        var focalLengthMM: Double?
        var focalLength35mm: Int?
        var lensMake: String?
        var lensModel: String?

        if let exifOffset = exifIFDOffset, exifOffset >= 8, !visitedIFDs.contains(exifOffset),
           let exifIFD = readIFD(fh: fh, offset: exifOffset, littleEndian: isLittleEndian) {
            for entry in exifIFD.entries {
                if entry.tag == 0x927C {
                    // Never read or parse MakerNote
                    continue
                }
                switch entry.tag {
                case 0x829A: // ExposureTime
                    if let v = readFirstRational(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: false),
                       v.isFinite, v > 0 {
                        exposureTime = v
                    }
                case 0x829D: // FNumber
                    if let v = readFirstRational(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: false),
                       v.isFinite, v > 0 {
                        fNumber = v
                    }
                case 0x8827: // ISOSpeedRatings
                    if let v = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian), v > 0 {
                        isoSpeed = Int(v)
                    }
                case 0x8832: // RecommendedExposureIndex
                    if let v = readFirstUInt32(fh: fh, entry: entry, littleEndian: isLittleEndian), v > 0 {
                        recommendedExposureIndex = Int(v)
                    }
                case 0x9003: // DateTimeOriginal
                    dateTimeOriginal = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x9010: // OffsetTime (fallback)
                    offsetTimeFallback = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x9011: // OffsetTimeOriginal (canonical)
                    offsetTimeOriginal = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x9204: // ExposureBiasValue (SRATIONAL)
                    exposureBiasEV = readFirstRational(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: true)
                case 0x920A: // FocalLength
                    if let v = readFirstRational(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: false),
                       v.isFinite, v > 0 {
                        focalLengthMM = v
                    }
                case 0x9290: // SubSecTime (fallback)
                    subSecTimeFallback = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0x9291: // SubSecTimeOriginal
                    subSecTimeOriginal = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0xA405: // FocalLengthIn35mmFilm
                    if let v = readFirstUInt16(fh: fh, entry: entry, littleEndian: isLittleEndian), v > 0 {
                        focalLength35mm = Int(v)
                    }
                case 0xA433: // LensMake
                    lensMake = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                case 0xA434: // LensModel
                    lensModel = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                default:
                    break
                }
            }
        }

        // Inspect GPSIFD if present
        var gpsLat: Double?
        var gpsLatRef: String?
        var gpsLon: Double?
        var gpsLonRef: String?
        var gpsAlt: Double?
        var gpsAltRef: Int?
        var gpsTimestamp: String?
        var gpsDateStamp: String?

        if let gpsOffset = gpsIFDOffset, gpsOffset >= 8, !visitedIFDs.contains(gpsOffset),
           let gpsIFD = readIFD(fh: fh, offset: gpsOffset, littleEndian: isLittleEndian) {
            for entry in gpsIFD.entries {
                switch entry.tag {
                case 0x0001:
                    gpsLatRef = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)?.uppercased()
                case 0x0002:
                    let dms = readRationalArray(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: false)
                    if dms.count >= 3, dms.allSatisfy({ $0.isFinite }) {
                        gpsLat = dms[0] + dms[1] / 60.0 + dms[2] / 3600.0
                    }
                case 0x0003:
                    gpsLonRef = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)?.uppercased()
                case 0x0004:
                    let dms = readRationalArray(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: false)
                    if dms.count >= 3, dms.allSatisfy({ $0.isFinite }) {
                        gpsLon = dms[0] + dms[1] / 60.0 + dms[2] / 3600.0
                    }
                case 0x0005:
                    if let data = readTagData(fh: fh, entry: entry, littleEndian: isLittleEndian),
                       let first = data.first {
                        gpsAltRef = Int(first)
                    }
                case 0x0006:
                    gpsAlt = readFirstRational(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: false)
                case 0x0007:
                    let hms = readRationalArray(fh: fh, entry: entry, littleEndian: isLittleEndian, signed: false)
                    if hms.count >= 3, hms.allSatisfy({ $0.isFinite && $0 >= 0 }) {
                        let hh = Int(hms[0])
                        let mm = Int(hms[1])
                        let ss = hms[2]
                        gpsTimestamp = String(format: "%02d:%02d:%05.2f", hh, mm, ss)
                    }
                case 0x001D:
                    gpsDateStamp = readASCII(fh: fh, entry: entry, littleEndian: isLittleEndian)
                default:
                    break
                }
            }
        }

        // Combine with CGImageSourceCopyPropertiesAtIndex for ExifAux LensModel / GPS / missing fields
        let cgExif = readCGImageSourceFallbackExif(
            url: url,
            fallbackOrientation: orientation,
            customRenderedHDR: customRenderedHDR
        )

        let resolvedISO: Int? = {
            if let isoSpeed, isoSpeed < 65535 { return isoSpeed }
            if let recommendedExposureIndex, recommendedExposureIndex > 0 { return recommendedExposureIndex }
            return isoSpeed ?? cgExif.isoSpeedRatings
        }()

        var finalExif = WhitelistedExif(
            make: make ?? cgExif.make,
            model: model ?? cgExif.model,
            lensMake: lensMake ?? cgExif.lensMake,
            lensModel: lensModel ?? cgExif.lensModel,
            focalLengthMM: focalLengthMM ?? cgExif.focalLengthMM,
            focalLengthIn35mmFilm: focalLength35mm ?? cgExif.focalLengthIn35mmFilm,
            exposureTimeSeconds: exposureTime ?? cgExif.exposureTimeSeconds,
            fNumber: fNumber ?? cgExif.fNumber,
            isoSpeedRatings: resolvedISO,
            exposureBiasEV: exposureBiasEV ?? cgExif.exposureBiasEV,
            dateTimeOriginal: dateTimeOriginal ?? dateTimeIFD0 ?? cgExif.dateTimeOriginal,
            offsetTimeOriginal: offsetTimeOriginal ?? offsetTimeFallback ?? cgExif.offsetTimeOriginal,
            subSecTimeOriginal: subSecTimeOriginal ?? subSecTimeFallback ?? cgExif.subSecTimeOriginal,
            orientation: orientation,
            customRendered: customRenderedHDR ? 3 : nil
        )

        if let lat = gpsLat, let lon = gpsLon, lat.isFinite, lon.isFinite, abs(lat) <= 90.0, abs(lon) <= 180.0 {
            finalExif.gpsLatitude = abs(lat)
            finalExif.gpsLatitudeRef = gpsLatRef ?? (lat < 0 ? "S" : "N")
            finalExif.gpsLongitude = abs(lon)
            finalExif.gpsLongitudeRef = gpsLonRef ?? (lon < 0 ? "W" : "E")
            if let alt = gpsAlt, alt.isFinite {
                finalExif.gpsAltitude = abs(alt)
                finalExif.gpsAltitudeRef = alt < 0 ? 1 : (gpsAltRef ?? 0)
            }
            finalExif.gpsTimestamp = gpsTimestamp
            finalExif.gpsDateStamp = gpsDateStamp
        } else if let lat = cgExif.gpsLatitude, let lon = cgExif.gpsLongitude {
            finalExif.gpsLatitude = lat
            finalExif.gpsLatitudeRef = cgExif.gpsLatitudeRef
            finalExif.gpsLongitude = lon
            finalExif.gpsLongitudeRef = cgExif.gpsLongitudeRef
            finalExif.gpsAltitude = cgExif.gpsAltitude
            finalExif.gpsAltitudeRef = cgExif.gpsAltitudeRef
            finalExif.gpsTimestamp = cgExif.gpsTimestamp
            finalExif.gpsDateStamp = cgExif.gpsDateStamp
        }

        return TIFFPreflightResult(
            isLosslessMS: detectedLosslessMS,
            exif: finalExif
        )
    }

    private static func isSonyLosslessMSIFD(
        subfileType: UInt32?,
        photometric: UInt16?,
        samplesPerPixel: UInt16?,
        bitsPerSample: [UInt16],
        compression: UInt16?,
        isSubIFD: Bool
    ) -> Bool {
        // Never treat reduced-resolution JPEG preview thumbnails (SubfileType == 1) as Lossless M/S RAW.
        if subfileType == 1 {
            return false
        }
        guard photometric == 6, samplesPerPixel == 3 else {
            return false
        }
        let maxBits = bitsPerSample.max() ?? 0
        if maxBits >= 12 {
            return true
        }
        // In RAW SubIFD without explicit BitsPerSample, Compression == 6 with YCbCr 3-channel also indicates Sony YCC
        if isSubIFD && compression == 6 && bitsPerSample.isEmpty {
            return true
        }
        return false
    }

    static func readCGImageSourceFallbackExif(
        url: URL,
        fallbackOrientation: Int,
        customRenderedHDR: Bool
    ) -> WhitelistedExif {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return WhitelistedExif(
                orientation: fallbackOrientation,
                customRendered: customRenderedHDR ? 3 : nil
            )
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let rawOrient = (props[kCGImagePropertyOrientation] as? Int)
            ?? (tiff?[kCGImagePropertyTIFFOrientation] as? Int)
            ?? fallbackOrientation
        let orientation = (1...8).contains(rawOrient) ? rawOrient : fallbackOrientation

        let make = nonEmptyString(tiff?[kCGImagePropertyTIFFMake])
        let model = nonEmptyString(tiff?[kCGImagePropertyTIFFModel])
        let lensMake = nonEmptyString(exifDict?[kCGImagePropertyExifLensMake])
        let lensModel = nonEmptyString(exifDict?[kCGImagePropertyExifLensModel])
            ?? nonEmptyString(exifAux?[kCGImagePropertyExifAuxLensModel])

        let focalLength = positiveDouble(exifDict?[kCGImagePropertyExifFocalLength])
        let focalLength35 = positiveInt(exifDict?[kCGImagePropertyExifFocalLenIn35mmFilm])
        let exposureTime = positiveDouble(exifDict?[kCGImagePropertyExifExposureTime])
        let fNumber = positiveDouble(exifDict?[kCGImagePropertyExifFNumber])
        let iso = (exifDict?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?
            .first
            .flatMap { $0.intValue > 0 ? $0.intValue : nil }
        let expBias = finiteDouble(exifDict?[kCGImagePropertyExifExposureBiasValue])
        let dateOrig = nonEmptyString(exifDict?[kCGImagePropertyExifDateTimeOriginal])
            ?? nonEmptyString(tiff?[kCGImagePropertyTIFFDateTime])
        let offsetOrig = nonEmptyString(exifDict?[kCGImagePropertyExifOffsetTimeOriginal])
            ?? nonEmptyString(exifDict?[kCGImagePropertyExifOffsetTime])
        let subsecOrig = nonEmptyString(exifDict?[kCGImagePropertyExifSubsecTimeOriginal])

        var result = WhitelistedExif(
            make: make,
            model: model,
            lensMake: lensMake,
            lensModel: lensModel,
            focalLengthMM: focalLength,
            focalLengthIn35mmFilm: focalLength35,
            exposureTimeSeconds: exposureTime,
            fNumber: fNumber,
            isoSpeedRatings: iso,
            exposureBiasEV: expBias,
            dateTimeOriginal: dateOrig,
            offsetTimeOriginal: offsetOrig,
            subSecTimeOriginal: subsecOrig,
            orientation: orientation,
            customRendered: customRenderedHDR ? 3 : nil
        )

        if let gps,
           let rawLat = finiteDouble(gps[kCGImagePropertyGPSLatitude]),
           let rawLon = finiteDouble(gps[kCGImagePropertyGPSLongitude]),
           abs(rawLat) <= 90.0,
           abs(rawLon) <= 180.0 {
            result.gpsLatitude = abs(rawLat)
            result.gpsLatitudeRef = nonEmptyString(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased()
                ?? (rawLat < 0 ? "S" : "N")
            result.gpsLongitude = abs(rawLon)
            result.gpsLongitudeRef = nonEmptyString(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased()
                ?? (rawLon < 0 ? "W" : "E")
            if let rawAlt = finiteDouble(gps[kCGImagePropertyGPSAltitude]) {
                result.gpsAltitude = abs(rawAlt)
                let refNum = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue
                result.gpsAltitudeRef = rawAlt < 0 ? 1 : (refNum ?? 0)
            }
            result.gpsTimestamp = nonEmptyString(gps[kCGImagePropertyGPSTimeStamp])
            result.gpsDateStamp = nonEmptyString(gps[kCGImagePropertyGPSDateStamp])
        }

        return result
    }

    // MARK: - Low-level TIFF Helpers

    private struct IFDEntry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let valueOrOffsetBytes: Data // 4 bytes
    }

    private struct IFDTable {
        let entries: [IFDEntry]
        let nextIFDOffset: UInt32
    }

    private static func componentSize(for type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }

    private static func readBytes(fh: FileHandle, offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        do {
            try fh.seek(toOffset: offset)
            return try fh.read(upToCount: count)
        } catch {
            return nil
        }
    }

    private static func readIFD(fh: FileHandle, offset: UInt32, littleEndian: Bool) -> IFDTable? {
        guard let countData = readBytes(fh: fh, offset: UInt64(offset), count: 2),
              countData.count == 2 else {
            return nil
        }
        let count = Int(readUInt16(countData, at: 0, littleEndian: littleEndian))
        guard count > 0, count <= maxEntriesPerIFD else {
            return nil
        }
        let bodyBytes = count * 12 + 4
        guard let body = readBytes(fh: fh, offset: UInt64(offset) + 2, count: bodyBytes),
              body.count == bodyBytes else {
            return nil
        }

        var entries: [IFDEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let base = i * 12
            let tag = readUInt16(body, at: base, littleEndian: littleEndian)
            let type = readUInt16(body, at: base + 2, littleEndian: littleEndian)
            let cnt = readUInt32(body, at: base + 4, littleEndian: littleEndian)
            let valBytes = Data(body[(base + 8)..<(base + 12)])
            entries.append(IFDEntry(tag: tag, type: type, count: cnt, valueOrOffsetBytes: valBytes))
        }
        let nextOffset = readUInt32(body, at: count * 12, littleEndian: littleEndian)
        return IFDTable(entries: entries, nextIFDOffset: nextOffset)
    }

    private static func readTagData(fh: FileHandle, entry: IFDEntry, littleEndian: Bool) -> Data? {
        guard let elemSize = componentSize(for: entry.type), entry.count > 0 else {
            return nil
        }
        let total64 = UInt64(entry.count) * UInt64(elemSize)
        guard total64 > 0, total64 <= UInt64(maxExternalTagBytes) else {
            return nil
        }
        let total = Int(total64)
        if total <= 4 {
            return Data(entry.valueOrOffsetBytes.prefix(total))
        }
        let offset = UInt64(readUInt32(entry.valueOrOffsetBytes, at: 0, littleEndian: littleEndian))
        guard let data = readBytes(fh: fh, offset: offset, count: total), data.count == total else {
            return nil
        }
        return data
    }

    private static func readASCII(fh: FileHandle, entry: IFDEntry, littleEndian: Bool) -> String? {
        guard entry.type == 2 || entry.type == 7 || entry.type == 1,
              let data = readTagData(fh: fh, entry: entry, littleEndian: littleEndian) else {
            return nil
        }
        let bytes = data.prefix(while: { $0 != 0 })
        let str = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? nil : str
    }

    private static func readUInt16Array(fh: FileHandle, entry: IFDEntry, littleEndian: Bool) -> [UInt16] {
        guard let data = readTagData(fh: fh, entry: entry, littleEndian: littleEndian) else {
            return []
        }
        if entry.type == 3 {
            let count = data.count / 2
            return (0..<count).map { readUInt16(data, at: $0 * 2, littleEndian: littleEndian) }
        } else if entry.type == 4 || entry.type == 13 {
            let count = data.count / 4
            return (0..<count).compactMap { idx in
                let v = readUInt32(data, at: idx * 4, littleEndian: littleEndian)
                return v <= UInt32(UInt16.max) ? UInt16(v) : nil
            }
        }
        return []
    }

    private static func readFirstUInt16(fh: FileHandle, entry: IFDEntry, littleEndian: Bool) -> UInt16? {
        readUInt16Array(fh: fh, entry: entry, littleEndian: littleEndian).first
    }

    private static func readUInt32Array(fh: FileHandle, entry: IFDEntry, littleEndian: Bool) -> [UInt32] {
        guard let data = readTagData(fh: fh, entry: entry, littleEndian: littleEndian) else {
            return []
        }
        if entry.type == 4 || entry.type == 13 {
            let count = data.count / 4
            return (0..<count).map { readUInt32(data, at: $0 * 4, littleEndian: littleEndian) }
        } else if entry.type == 3 {
            let count = data.count / 2
            return (0..<count).map { UInt32(readUInt16(data, at: $0 * 2, littleEndian: littleEndian)) }
        }
        return []
    }

    private static func readFirstUInt32(fh: FileHandle, entry: IFDEntry, littleEndian: Bool) -> UInt32? {
        readUInt32Array(fh: fh, entry: entry, littleEndian: littleEndian).first
    }

    private static func readRationalArray(
        fh: FileHandle,
        entry: IFDEntry,
        littleEndian: Bool,
        signed: Bool
    ) -> [Double] {
        guard entry.type == 5 || entry.type == 10,
              let data = readTagData(fh: fh, entry: entry, littleEndian: littleEndian) else {
            return []
        }
        let count = data.count / 8
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let base = i * 8
            if signed || entry.type == 10 {
                let num = Int32(bitPattern: readUInt32(data, at: base, littleEndian: littleEndian))
                let den = Int32(bitPattern: readUInt32(data, at: base + 4, littleEndian: littleEndian))
                if den != 0 {
                    out.append(Double(num) / Double(den))
                }
            } else {
                let num = readUInt32(data, at: base, littleEndian: littleEndian)
                let den = readUInt32(data, at: base + 4, littleEndian: littleEndian)
                if den != 0 {
                    out.append(Double(num) / Double(den))
                }
            }
        }
        return out
    }

    private static func readFirstRational(
        fh: FileHandle,
        entry: IFDEntry,
        littleEndian: Bool,
        signed: Bool
    ) -> Double? {
        readRationalArray(fh: fh, entry: entry, littleEndian: littleEndian, signed: signed).first
    }

    private static func readUInt16(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return littleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
    }

    private static func readUInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        let i = data.startIndex + offset
        let b0 = UInt32(data[i])
        let b1 = UInt32(data[i + 1])
        let b2 = UInt32(data[i + 2])
        let b3 = UInt32(data[i + 3])
        return littleEndian
            ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
            : ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positiveDouble(_ raw: Any?) -> Double? {
        guard let d = (raw as? NSNumber)?.doubleValue, d.isFinite, d > 0 else { return nil }
        return d
    }

    private static func finiteDouble(_ raw: Any?) -> Double? {
        guard let d = (raw as? NSNumber)?.doubleValue, d.isFinite else { return nil }
        return d
    }

    private static func positiveInt(_ raw: Any?) -> Int? {
        guard let i = (raw as? NSNumber)?.intValue, i > 0 else { return nil }
        return i
    }
}
