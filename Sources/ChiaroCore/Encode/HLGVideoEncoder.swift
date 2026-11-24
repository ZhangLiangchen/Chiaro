@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import VideoToolbox
import os

public enum HLGVideoEncodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case fourKForbidden(Int)
    case forbiddenDimensions(width: Int, height: Int)
    case invalidDuration(Double)
    case invalidFPS(Int)
    case invalidBitrate(Double)
    case missingHLGPixelBuffer
    case invalidPixelFormat(OSType)
    case writerFailed(String)
    case atomicRenameFailed(errno: Int32, path: String)

    public var description: String {
        switch self {
        case .fourKForbidden(let edge):
            return "Douyin HLG MP4 forbids 4K / >1920px export (got \(edge)px)"
        case let .forbiddenDimensions(width, height):
            return "Douyin HLG MP4 requires 1080x1920 or 1080x1440 (got \(width)x\(height))"
        case .invalidDuration(let dur):
            return "Douyin HLG MP4 duration (\(dur)s) must be in [3.0, 5.0]"
        case .invalidFPS(let fps):
            return "Douyin HLG MP4 fps (\(fps)) must be 30"
        case .invalidBitrate(let mbps):
            return "Douyin HLG MP4 bitrate (\(mbps) Mbps) must be in [12.0, 16.0]"
        case .missingHLGPixelBuffer:
            return "RenderedFrame missing hlgPixelBuffer and hdrLinearTexture for HLG video encoding"
        case .invalidPixelFormat(let fmt):
            return "HLG pixel buffer must be 420YpCbCr10BiPlanarVideoRange ('x420'), got 0x\(String(fmt, radix: 16))"
        case .writerFailed(let detail):
            return "AVAssetWriter HLG MP4 encode failed: \(detail)"
        case let .atomicRenameFailed(code, path):
            return "Atomic rename failed (errno=\(code)) for \(path)"
        }
    }
}

public final class HLGVideoEncoder: HLGVideoEncoderProtocol, Sendable {
    private let engineLock: OSAllocatedUnfairLock<MetalPipelineEngine?>

    public init(metalEngine: MetalPipelineEngine? = nil) {
        self.engineLock = OSAllocatedUnfairLock(initialState: metalEngine)
    }

    public func encodeVideo(
        frame: RenderedFrame,
        preset: PresetSchema,
        options: HLGVideoOptions,
        to outputURL: URL
    ) async throws -> ExportArtifact {
        try Task.checkCancellation()

        if let maxEdge = preset.maxLongEdge, maxEdge > 1920 {
            throw HLGVideoEncodeError.fourKForbidden(maxEdge)
        }
        guard options.durationSeconds.isFinite, (3.0...5.0).contains(options.durationSeconds) else {
            throw HLGVideoEncodeError.invalidDuration(options.durationSeconds)
        }
        guard options.fps == 30 else {
            throw HLGVideoEncodeError.invalidFPS(options.fps)
        }
        guard options.bitrateMbps.isFinite, (12.0...16.0).contains(options.bitrateMbps) else {
            throw HLGVideoEncodeError.invalidBitrate(options.bitrateMbps)
        }

        let targetDims = options.aspect.dimensions
        guard (targetDims.width == 1080 && targetDims.height == 1920)
            || (targetDims.width == 1080 && targetDims.height == 1440) else {
            throw HLGVideoEncodeError.forbiddenDimensions(width: targetDims.width, height: targetDims.height)
        }

        let sendablePB: SendablePixelBuffer
        if let existing = frame.hlgPixelBuffer {
            let w = CVPixelBufferGetWidth(existing.buffer)
            let h = CVPixelBufferGetHeight(existing.buffer)
            if max(w, h) > 1920 {
                throw HLGVideoEncodeError.fourKForbidden(max(w, h))
            }
            guard w == targetDims.width, h == targetDims.height else {
                throw HLGVideoEncodeError.forbiddenDimensions(width: w, height: h)
            }
            let fmt = CVPixelBufferGetPixelFormatType(existing.buffer)
            guard fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
                throw HLGVideoEncodeError.invalidPixelFormat(fmt)
            }
            sendablePB = existing
        } else if let hdrTex = frame.hdrLinearTexture {
            let engine = try getOrCreateEngine(device: hdrTex.texture.device)
            sendablePB = try await engine.generateHLGPixelBuffer(
                from: hdrTex,
                baseColorSpace: frame.baseColorSpace,
                targetDimensions: targetDims
            )
        } else {
            throw HLGVideoEncodeError.missingHLGPixelBuffer
        }

        let pb = sendablePB.buffer
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var bestAttemptURL: URL?
        var bestScore = Double.greatestFiniteMagnitude
        var bestInRange = false
        var activeAttemptURL: URL?
        var renamed = false

        defer {
            if !renamed {
                if let bestAttemptURL {
                    try? FileManager.default.removeItem(at: bestAttemptURL)
                }
                if let activeAttemptURL, activeAttemptURL != bestAttemptURL {
                    try? FileManager.default.removeItem(at: activeAttemptURL)
                }
            }
        }

        let minPassBps = 10_800_000.0
        let maxPassBps = 17_600_000.0
        let retryLowerTriggerBps = 10_800_000.0
        let retryUpperTriggerBps = 17_200_000.0

        // Conservative initial CBR target: boost lower bitrates so static frames stay >= 10.8 Mbps,
        // while capping initial target at 15.8 Mbps so 16.0 Mbps avoids overshoot; then adaptively
        // verify & adjust against the encoded stream bitrate with up to 3 retries.
        var cbrTarget = min(options.bitrateMbps * 1_000_000.0 * 1.15, 15_800_000.0)
        let totalFrames = Int((options.durationSeconds * Double(options.fps)).rounded())

        for attempt in 0..<4 {
            try Task.checkCancellation()

            let attemptURL = parentDir.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.mp4")
            activeAttemptURL = attemptURL

            try await writeMP4Attempt(
                to: attemptURL,
                pixelBuffer: sendablePB,
                targetDims: targetDims,
                totalFrames: totalFrames,
                fps: options.fps,
                cbrBitsPerSecond: Int(cbrTarget.rounded())
            )

            let (estRate, sampleRate) = try await measureEncodedBitrates(at: attemptURL)
            let lowMeasured = min(estRate, sampleRate)
            let highMeasured = max(estRate, sampleRate)
            let inStrictRange = lowMeasured >= minPassBps && highMeasured <= maxPassBps
            let inTargetWindow = lowMeasured >= retryLowerTriggerBps && highMeasured <= retryUpperTriggerBps

            let score: Double
            if inStrictRange {
                let midpoint = (lowMeasured + highMeasured) * 0.5
                score = abs(midpoint - 14_200_000.0) * 1e-9
            } else {
                let under = max(0.0, minPassBps - lowMeasured)
                let over = max(0.0, highMeasured - maxPassBps)
                score = under + over
            }

            let isBetter = (bestAttemptURL == nil)
                || (inStrictRange && !bestInRange)
                || (inStrictRange == bestInRange && score < bestScore)

            if isBetter {
                if let previousBest = bestAttemptURL {
                    try? FileManager.default.removeItem(at: previousBest)
                }
                bestAttemptURL = attemptURL
                bestScore = score
                bestInRange = inStrictRange
            } else {
                try? FileManager.default.removeItem(at: attemptURL)
            }
            activeAttemptURL = nil

            if inTargetWindow || attempt == 3 {
                break
            }

            if highMeasured > retryUpperTriggerBps {
                let desiredBps = min(options.bitrateMbps * 1_000_000.0, 15_200_000.0)
                let scaled = cbrTarget * (desiredBps / max(highMeasured, 1.0))
                cbrTarget = min(max(scaled, 1_500_000.0), 22_000_000.0)
            } else {
                let desiredBps = max(options.bitrateMbps * 1_000_000.0, 12_500_000.0)
                let scaled = cbrTarget * (desiredBps / max(lowMeasured, 1_000_000.0))
                cbrTarget = min(max(scaled, 1_500_000.0), 22_000_000.0)
            }
        }

        guard let tmpURL = bestAttemptURL else {
            throw HLGVideoEncodeError.writerFailed("No MP4 output produced")
        }

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
            throw HLGVideoEncodeError.atomicRenameFailed(errno: errno, path: outputURL.path)
        }
        renamed = true

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        return ExportArtifact(
            format: .hlgMP4,
            outputURL: outputURL,
            fileSizeBytes: fileSize
        )
    }

    private func writeMP4Attempt(
        to tmpURL: URL,
        pixelBuffer: SendablePixelBuffer,
        targetDims: PixelDimensions,
        totalFrames: Int,
        fps: Int,
        cbrBitsPerSecond: Int
    ) async throws {
        let compressionProps: [String: Any] = [
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            kVTCompressionPropertyKey_RealTime as String: false,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: fps,
            kVTCompressionPropertyKey_ConstantBitRate as String: cbrBitsPerSecond,
            AVVideoMaxKeyFrameIntervalKey: fps,
        ]

        let colorProps: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: targetDims.width,
            AVVideoHeightKey: targetDims.height,
            AVVideoColorPropertiesKey: colorProps,
            AVVideoCompressionPropertiesKey: compressionProps,
        ]

        let writer = try AVAssetWriter(outputURL: tmpURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)

        guard writer.canAdd(input) else {
            throw HLGVideoEncodeError.writerFailed("AVAssetWriter cannot add HEVC video input")
        }

        do {
            if #available(macOS 27.0, *) {
                let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
                try writer.start()
                writer.startSession(atSourceTime: .zero)

                let roBuffer = CVReadOnlyPixelBuffer(unsafeBuffer: pixelBuffer.buffer)
                for frameIndex in 0..<totalFrames {
                    try Task.checkCancellation()
                    let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
                    try await receiver.append(roBuffer, with: pts)
                }
                receiver.finish()
                let endPTS = CMTime(value: CMTimeValue(totalFrames), timescale: CMTimeScale(fps))
                writer.endSession(atSourceTime: endPTS)
                await writer.finishWriting()
            } else {
                try await writeLegacyAssetWriter(
                    writer: writer,
                    input: input,
                    pixelBuffer: pixelBuffer,
                    totalFrames: totalFrames,
                    fps: fps
                )
            }
        } catch {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            throw error
        }

        guard writer.status == .completed else {
            let errMsg = writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)"
            throw HLGVideoEncodeError.writerFailed(errMsg)
        }
    }

    private func measureEncodedBitrates(at url: URL) async throws -> (estimatedDataRate: Double, sampleBitrate: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw HLGVideoEncodeError.writerFailed("Encoded MP4 missing video track during bitrate verification")
        }
        let estRate = Double(try await track.load(.estimatedDataRate))
        let duration = try await asset.load(.duration)
        let durSec = CMTimeGetSeconds(duration)
        let totalSampleBytes = try await track.load(.totalSampleDataLength)
        let sampleRate: Double
        if durSec.isFinite && durSec > 0.0 && totalSampleBytes > 0 {
            sampleRate = (Double(totalSampleBytes) * 8.0) / durSec
        } else {
            sampleRate = estRate
        }
        let safeEst = estRate.isFinite && estRate > 0 ? estRate : sampleRate
        let safeSample = sampleRate.isFinite && sampleRate > 0 ? sampleRate : safeEst
        return (safeEst, safeSample)
    }

    @available(macOS, introduced: 15.0, deprecated: 27.0)
    private func writeLegacyAssetWriter(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        pixelBuffer: SendablePixelBuffer,
        totalFrames: Int,
        fps: Int
    ) async throws {
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw HLGVideoEncodeError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<totalFrames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed || writer.status == .cancelled {
                    throw HLGVideoEncodeError.writerFailed(
                        writer.error?.localizedDescription ?? "AVAssetWriter terminated (status=\(writer.status.rawValue))"
                    )
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            if !adaptor.append(pixelBuffer.buffer, withPresentationTime: pts) {
                throw HLGVideoEncodeError.writerFailed(writer.error?.localizedDescription ?? "append failed")
            }
        }

        input.markAsFinished()
        let endPTS = CMTime(value: CMTimeValue(totalFrames), timescale: CMTimeScale(fps))
        writer.endSession(atSourceTime: endPTS)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }
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
}
