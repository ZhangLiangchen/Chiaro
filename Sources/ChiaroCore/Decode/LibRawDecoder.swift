import CLibRawBridge
import Foundation
import os

public enum RAWDecodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidFileURL(URL)
    case fileNotFound(URL)
    case librawFailed(status: Int32, nativeErrorCode: Int32, message: String)
    case invalidImagePayload(String)
    case cirawUnsupported(String)
    case cirawFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case let .invalidFileURL(url):
            return "Invalid RAW file URL: \(url.absoluteString)"
        case let .fileNotFound(url):
            return "RAW file not found at path: \(url.path)"
        case let .librawFailed(status, nativeErrorCode, message):
            return "LibRaw decode failed (status=\(status), native=\(nativeErrorCode)): \(message)"
        case let .invalidImagePayload(reason):
            return "Invalid decoded RAW image payload: \(reason)"
        case let .cirawUnsupported(reason):
            return "CIRAWv9 unsupported: \(reason)"
        case let .cirawFailed(reason):
            return "CIRAWv9 decode failed: \(reason)"
        case .cancelled:
            return "RAW decode cancelled"
        }
    }
}

public struct LibRawDecoder: ARWDecoderProtocol, Sendable {
    private static let decodeQueue = DispatchQueue(
        label: "io.github.zhangliangchen.chiaro.decode.libraw",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init() {}

    public func decodeFull(url: URL, options: DecodeOptions = .default) async throws -> DecodedRAWFrame {
        try await decode(url: url, options: options, forceProxy: options.isProxy)
    }

    public func decodeProxy(url: URL) async throws -> DecodedRAWFrame {
        let proxyOpts = DecodeOptions(
            backend: .libraw,
            highlightMode: .opposedInpaint,
            isProxy: true,
            maxThreadsPerWorker: 6,
            customRenderedHDR: false
        )
        return try await decode(url: url, options: proxyOpts, forceProxy: true)
    }

    public func decodeBuffer(
        _ data: Data,
        sourceURL: URL,
        options: DecodeOptions = .default
    ) async throws -> DecodedRAWFrame {
        try Task.checkCancellation()
        let forceProxy = options.isProxy
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.decodeQueue.async {
                    do {
                        if cancelFlag.withLock({ $0 }) {
                            throw RAWDecodeError.cancelled
                        }
                        let decoded = try Self.decodeBufferSync(
                            data,
                            sourceURL: sourceURL,
                            options: options,
                            forceProxy: forceProxy
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

    private func decode(
        url: URL,
        options: DecodeOptions,
        forceProxy: Bool
    ) async throws -> DecodedRAWFrame {
        try Task.checkCancellation()
        guard url.isFileURL else {
            throw RAWDecodeError.invalidFileURL(url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RAWDecodeError.fileNotFound(url)
        }

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.decodeQueue.async {
                    do {
                        if cancelFlag.withLock({ $0 }) {
                            throw RAWDecodeError.cancelled
                        }
                        let decoded = try Self.decodeFileSync(
                            url: url,
                            options: options,
                            forceProxy: forceProxy
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

    private static func makeBridgeOptions(options: DecodeOptions, forceProxy: Bool) -> HDRLibRawDecodeOptions {
        var cOpts = hdr_libraw_default_options()
        cOpts.mode = forceProxy ? HDR_LIBRAW_MODE_PROXY_RGB16 : HDR_LIBRAW_MODE_LINEAR_RGB16
        cOpts.output_color_space = HDR_LIBRAW_CS_CAMERA_NATIVE
        // Always pass unclip (highlight_mode = 1) so MetalPipelineEngine receives
        // unclipped dmax ratios and executes GPU highlight reconstruction cleanly.
        cOpts.highlight_mode = 1
        cOpts.max_threads = Int32(min(max(options.maxThreadsPerWorker, 1), 8))
        cOpts.apply_inset_crop = 1
        cOpts.sraw_no_rgb = 0
        switch options.demosaicAlgorithm {
        case .amaze: cOpts.demosaic_algorithm = HDR_LIBRAW_DEMOSAIC_AMAZE
        case .lmmse: cOpts.demosaic_algorithm = HDR_LIBRAW_DEMOSAIC_LMMSE
        case .dcb:   cOpts.demosaic_algorithm = HDR_LIBRAW_DEMOSAIC_DCB
        case .dht:   cOpts.demosaic_algorithm = HDR_LIBRAW_DEMOSAIC_DHT
        case .ahd:   cOpts.demosaic_algorithm = HDR_LIBRAW_DEMOSAIC_AHD
        }
        return cOpts
    }

    private static func decodeFileSync(
        url: URL,
        options: DecodeOptions,
        forceProxy: Bool
    ) throws -> DecodedRAWFrame {
        var cOpts = makeBridgeOptions(options: options, forceProxy: forceProxy)
        var img = HDRLibRawImage()
        defer { hdr_libraw_free_image(&img) }

        let status: HDRLibRawStatus = try url.withUnsafeFileSystemRepresentation { pathPtr in
            guard let pathPtr else {
                throw RAWDecodeError.invalidFileURL(url)
            }
            return hdr_libraw_decode_file(pathPtr, &cOpts, &img)
        }

        if status != HDR_LIBRAW_OK {
            let msg = extractErrorMessage(from: &img)
            throw RAWDecodeError.librawFailed(
                status: status.rawValue,
                nativeErrorCode: img.error_code,
                message: msg
            )
        }

        return try mapImageToFrame(&img, sourceURL: url, options: options, forceProxy: forceProxy)
    }

    private static func decodeBufferSync(
        _ data: Data,
        sourceURL: URL,
        options: DecodeOptions,
        forceProxy: Bool
    ) throws -> DecodedRAWFrame {
        guard !data.isEmpty else {
            throw RAWDecodeError.invalidImagePayload("Empty input buffer")
        }
        var cOpts = makeBridgeOptions(options: options, forceProxy: forceProxy)
        var img = HDRLibRawImage()
        defer { hdr_libraw_free_image(&img) }

        let status: HDRLibRawStatus = data.withUnsafeBytes { rawBuf in
            hdr_libraw_decode_buffer(rawBuf.baseAddress, rawBuf.count, &cOpts, &img)
        }

        if status != HDR_LIBRAW_OK {
            let msg = extractErrorMessage(from: &img)
            throw RAWDecodeError.librawFailed(
                status: status.rawValue,
                nativeErrorCode: img.error_code,
                message: msg
            )
        }

        return try mapImageToFrame(&img, sourceURL: sourceURL, options: options, forceProxy: forceProxy)
    }

    private static func extractErrorMessage(from img: inout HDRLibRawImage) -> String {
        withUnsafePointer(to: &img.error_message) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { cPtr in
                let s = String(cString: cPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? "Unknown LibRaw error" : s
            }
        }
    }

    private static func cStringOrNil(_ ptr: UnsafePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        let trimmed = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func mapImageToFrame(
        _ img: inout HDRLibRawImage,
        sourceURL: URL,
        options: DecodeOptions,
        forceProxy: Bool
    ) throws -> DecodedRAWFrame {
        let width = Int(img.width)
        let height = Int(img.height)
        guard width > 0, height > 0 else {
            throw RAWDecodeError.invalidImagePayload("Non-positive dimensions \(width)x\(height)")
        }
        guard img.payload_kind == HDR_LIBRAW_PAYLOAD_RGB16U else {
            throw RAWDecodeError.invalidImagePayload("Unexpected payload kind \(img.payload_kind.rawValue)")
        }
        guard let pixelPtr = img.rgb16_data else {
            throw RAWDecodeError.invalidImagePayload("Missing RGB16 pixel buffer")
        }

        let expectedBytes = width * height * 3 * MemoryLayout<UInt16>.stride
        guard img.data_bytes >= expectedBytes else {
            throw RAWDecodeError.invalidImagePayload(
                "Byte count mismatch: expected at least \(expectedBytes), got \(img.data_bytes)"
            )
        }

        let pixelData: Data
        if expectedBytes > 0 {
            // Transfer ownership of the malloc'd pixel buffer directly to Data (.free)
            // and nil out img.rgb16_data so hdr_libraw_free_image(&img) does not double-free
            // while still freeing img.exif strings.
            pixelData = Data(
                bytesNoCopy: UnsafeMutableRawPointer(pixelPtr),
                count: expectedBytes,
                deallocator: .free
            )
            img.rgb16_data = nil
            img.data_bytes = 0
        } else {
            pixelData = Data()
        }
        let colorSpace: LinearPayloadColorSpace = (img.color_space == HDR_LIBRAW_CS_LINEAR_REC2020)
            ? .linearRec2020
            : .cameraNative

        let rawOrientation = Int(img.orientation)
        let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1

        let visibleCrop = SensorCropRect(
            x: max(0, Int(img.crop_left)),
            y: max(0, Int(img.crop_top)),
            width: width,
            height: height
        )

        let rawCamXYZ: [Double] = [
            Double(img.cam_xyz.0), Double(img.cam_xyz.1), Double(img.cam_xyz.2),
            Double(img.cam_xyz.3), Double(img.cam_xyz.4), Double(img.cam_xyz.5),
            Double(img.cam_xyz.6), Double(img.cam_xyz.7), Double(img.cam_xyz.8),
        ]
        let identity3x3: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let camXYZValid = rawCamXYZ.allSatisfy { $0.isFinite } && !rawCamXYZ.allSatisfy { abs($0) < 1e-12 }
        let camXYZ = camXYZValid ? rawCamXYZ : identity3x3

        let rawForwardMatrix: [Double] = [
            Double(img.forward_matrix.0), Double(img.forward_matrix.1), Double(img.forward_matrix.2),
            Double(img.forward_matrix.3), Double(img.forward_matrix.4), Double(img.forward_matrix.5),
            Double(img.forward_matrix.6), Double(img.forward_matrix.7), Double(img.forward_matrix.8),
        ]
        let hasValidFM = (img.has_forward_matrix != 0)
            && rawForwardMatrix.allSatisfy { $0.isFinite }
            && !rawForwardMatrix.allSatisfy { abs($0) < 1e-12 }
        let forwardMatrix = hasValidFM ? rawForwardMatrix : identity3x3

        let camMul = [
            Double(img.cam_mul.0),
            Double(img.cam_mul.1),
            Double(img.cam_mul.2),
            Double(img.cam_mul.3),
        ]
        let preMul = [
            Double(img.pre_mul.0),
            Double(img.pre_mul.1),
            Double(img.pre_mul.2),
            Double(img.pre_mul.3),
        ]
        let wbMultipliers = sanitizeWBMultipliers(primary: camMul, fallback: preMul)

        let asShotWBApplied = (img.as_shot_wb_applied != 0)
        let isLosslessMS = (img.is_lossless_ms != 0)

        let colorMatrices = CameraColorMatrices(
            camXYZ: camXYZ,
            forwardMatrix: forwardMatrix,
            wbMultipliers: wbMultipliers,
            asShotWBApplied: asShotWBApplied
        )

        var exif = WhitelistedExif(
            make: cStringOrNil(img.exif.make),
            model: cStringOrNil(img.exif.model),
            lensMake: cStringOrNil(img.exif.lens_make),
            lensModel: cStringOrNil(img.exif.lens_model),
            focalLengthMM: (img.exif.focal_length_mm.isFinite && img.exif.focal_length_mm > 0)
                ? img.exif.focal_length_mm : nil,
            focalLengthIn35mmFilm: img.exif.focal_length_35mm > 0
                ? Int(img.exif.focal_length_35mm) : nil,
            exposureTimeSeconds: (img.exif.exposure_time_sec.isFinite && img.exif.exposure_time_sec > 0)
                ? img.exif.exposure_time_sec : nil,
            fNumber: (img.exif.f_number.isFinite && img.exif.f_number > 0)
                ? img.exif.f_number : nil,
            isoSpeedRatings: img.exif.iso_speed > 0
                ? Int(img.exif.iso_speed) : nil,
            exposureBiasEV: (img.exif.has_exposure_bias != 0 && img.exif.exposure_bias_ev.isFinite)
                ? img.exif.exposure_bias_ev : nil,
            dateTimeOriginal: cStringOrNil(img.exif.date_time_original),
            offsetTimeOriginal: cStringOrNil(img.exif.offset_time_original),
            subSecTimeOriginal: cStringOrNil(img.exif.subsec_time_original),
            orientation: orientation,
            customRendered: options.customRenderedHDR ? 3 : nil
        )

        if img.exif.has_gps != 0,
           img.exif.gps_latitude.isFinite,
           img.exif.gps_longitude.isFinite,
           abs(img.exif.gps_latitude) <= 90.0,
           abs(img.exif.gps_longitude) <= 180.0 {
            exif.gpsLatitude = abs(img.exif.gps_latitude)
            exif.gpsLatitudeRef = cStringOrNil(img.exif.gps_latitude_ref)
                ?? (img.exif.gps_latitude < 0 ? "S" : "N")
            exif.gpsLongitude = abs(img.exif.gps_longitude)
            exif.gpsLongitudeRef = cStringOrNil(img.exif.gps_longitude_ref)
                ?? (img.exif.gps_longitude < 0 ? "W" : "E")
            if img.exif.has_gps_altitude != 0 && img.exif.gps_altitude.isFinite {
                exif.gpsAltitude = abs(img.exif.gps_altitude)
                exif.gpsAltitudeRef = img.exif.gps_altitude < 0
                    ? 1
                    : (img.exif.gps_altitude_ref != 0 ? 1 : 0)
            }
            exif.gpsTimestamp = cStringOrNil(img.exif.gps_timestamp)
            exif.gpsDateStamp = cStringOrNil(img.exif.gps_date_stamp)
        }

        let fullSensorDimensions: PixelDimensions? = (img.raw_width > 0 && img.raw_height > 0)
            ? PixelDimensions(width: Int(img.raw_width), height: Int(img.raw_height))
            : nil

        let resolvedCropFactor: Double = {
            if let fMM = exif.focalLengthMM, fMM > 0, let f35 = exif.focalLengthIn35mmFilm, f35 > 0 {
                let ratio = Double(f35) / fMM
                if (1.42...1.60).contains(ratio) { return 1.5 }
                if (0.94...1.06).contains(ratio) { return 1.0 }
                if ratio.isFinite && ratio > 0 { return ratio }
            }
            if img.camera_format == 1 { return 1.5 }
            if img.camera_format == 2 { return 1.0 }
            if img.embedded_sony_optics.has_optics != 0 && img.embedded_sony_optics.distortion_node_count == 11 {
                return 1.5
            }
            return 1.0
        }()

        let embeddedSonyOptics: EmbeddedSonyOpticsPayload? = {
            let cOptics = img.embedded_sony_optics
            guard cOptics.has_optics != 0 else { return nil }
            let distCount = min(max(Int(cOptics.distortion_node_count), 0), EmbeddedSonyOpticsPayload.maxNodeCount)
            let caCount = min(max(Int(cOptics.ca_node_count), 0), EmbeddedSonyOpticsPayload.maxNodeCount)
            let vigCount = min(max(Int(cOptics.vignetting_node_count), 0), EmbeddedSonyOpticsPayload.maxNodeCount)

            let distParams = withUnsafeBytes(of: cOptics.distortion_params) { raw in
                Array(raw.bindMemory(to: Int16.self).prefix(distCount))
            }
            let caRedParams = withUnsafeBytes(of: cOptics.ca_red_params) { raw in
                Array(raw.bindMemory(to: Int16.self).prefix(caCount))
            }
            let caBlueParams = withUnsafeBytes(of: cOptics.ca_blue_params) { raw in
                Array(raw.bindMemory(to: Int16.self).prefix(caCount))
            }
            let vigParams = withUnsafeBytes(of: cOptics.vignetting_params) { raw in
                Array(raw.bindMemory(to: Int16.self).prefix(vigCount))
            }

            let aspect = height > 0 ? Double(width) / Double(height) : 1.5
            let payload = EmbeddedSonyOpticsPayload(
                distortionNodeCount: distCount,
                distortionParams: distParams,
                caNodeCount: caCount,
                caRedParams: caRedParams,
                caBlueParams: caBlueParams,
                vignettingNodeCount: vigCount,
                vignettingParams: vigParams,
                focalLengthMM: exif.focalLengthMM,
                fNumber: exif.fNumber,
                sensorAspectRatio: aspect,
                cropFactor: resolvedCropFactor
            )
            return payload.hasAnyCorrection ? payload : nil
        }()

        let demosaicUsed: DemosaicAlgorithm? = (forceProxy || isLosslessMS) ? nil : mapDemosaic(img.demosaic_used)

        return DecodedRAWFrame(
            sourceURL: sourceURL,
            backendUsed: .libraw,
            fallbackReason: nil,
            payload: .linearRGB16U(
                width: width,
                height: height,
                colorSpace: colorSpace,
                data: pixelData
            ),
            visibleCrop: visibleCrop,
            orientation: orientation,
            colorMatrices: colorMatrices,
            isLosslessMS: isLosslessMS,
            exif: exif,
            demosaicUsed: demosaicUsed,
            embeddedSonyOptics: embeddedSonyOptics,
            fullSensorDimensions: fullSensorDimensions,
            cropFactor: resolvedCropFactor
        )
    }

    private static func mapDemosaic(_ raw: HDRLibRawDemosaicAlgorithm) -> DemosaicAlgorithm {
        switch raw {
        case HDR_LIBRAW_DEMOSAIC_AMAZE: return .amaze
        case HDR_LIBRAW_DEMOSAIC_LMMSE: return .lmmse
        case HDR_LIBRAW_DEMOSAIC_DCB:   return .dcb
        case HDR_LIBRAW_DEMOSAIC_DHT:   return .dht
        case HDR_LIBRAW_DEMOSAIC_AHD:   return .ahd
        default: return .ahd
        }
    }

    private static func sanitizeWBMultipliers(primary: [Double], fallback: [Double]) -> [Double] {
        func validRGB(_ arr: [Double]) -> [Double]? {
            guard arr.count >= 3,
                  arr[0].isFinite, arr[0] > 0,
                  arr[1].isFinite, arr[1] > 0,
                  arr[2].isFinite, arr[2] > 0 else {
                return nil
            }
            let g2 = (arr.count >= 4 && arr[3].isFinite && arr[3] > 0) ? arr[3] : arr[1]
            return [arr[0], arr[1], arr[2], g2]
        }
        return validRGB(primary) ?? validRGB(fallback) ?? [1.0, 1.0, 1.0, 1.0]
    }
}
