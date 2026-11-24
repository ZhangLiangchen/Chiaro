@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

public struct HLGVideoProbe: HLGVideoProbeProtocol, Sendable {
    public init() {}

    public func verify(url: URL, expected: HLGComplianceExpectation) async throws -> ComplianceReport {
        try Task.checkCancellation()

        var checks: [ComplianceCheckItem] = []

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            checks.append(ComplianceCheckItem(
                name: "file_exists",
                severity: .fail,
                message: "File does not exist at \(url.path)"
            ))
            return ComplianceReport(
                fileURL: url,
                passed: false,
                hasISOGainMap: false,
                fileSizeBytes: 0,
                checks: checks
            )
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            checks.append(ComplianceCheckItem(
                name: "file_non_empty",
                severity: .fail,
                message: "MP4 file is empty (0 bytes)"
            ))
            return ComplianceReport(
                fileURL: url,
                passed: false,
                hasISOGainMap: false,
                fileSizeBytes: fileSize,
                checks: checks
            )
        }
        checks.append(ComplianceCheckItem(
            name: "file_non_empty",
            severity: .pass,
            message: "File size is \(fileSize) bytes"
        ))

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            checks.append(ComplianceCheckItem(
                name: "video_track",
                severity: .fail,
                message: "No video track found in MP4"
            ))
            return ComplianceReport(
                fileURL: url,
                passed: false,
                hasISOGainMap: false,
                fileSizeBytes: fileSize,
                checks: checks
            )
        }

        let duration = try await asset.load(.duration)
        let durSec = CMTimeGetSeconds(duration)
        if durSec.isFinite &&
            durSec >= (expected.minDurationSeconds - 0.1) &&
            durSec <= (expected.maxDurationSeconds + 0.1) {
            checks.append(ComplianceCheckItem(
                name: "duration",
                severity: .pass,
                message: String(format: "Duration %.2fs in [%.1f, %.1f]s", durSec, expected.minDurationSeconds, expected.maxDurationSeconds)
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "duration",
                severity: .fail,
                message: "Duration \(durSec)s outside [\(expected.minDurationSeconds), \(expected.maxDurationSeconds)]s"
            ))
        }

        let fps = Double(try await track.load(.nominalFrameRate))
        if fps.isFinite && abs(fps - Double(expected.expectedFPS)) < 0.5 {
            checks.append(ComplianceCheckItem(
                name: "frame_rate",
                severity: .pass,
                message: String(format: "Frame rate %.2f fps", fps)
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "frame_rate",
                severity: .fail,
                message: "Expected fps=\(expected.expectedFPS), got \(fps)"
            ))
        }

        let estBitrate = Double(try await track.load(.estimatedDataRate))
        if estBitrate.isFinite && (10_800_000.0...17_600_000.0).contains(estBitrate) {
            checks.append(ComplianceCheckItem(
                name: "bitrate",
                severity: .pass,
                message: String(format: "Estimated bitrate %.2f Mbps", estBitrate / 1_000_000.0)
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "bitrate",
                severity: .fail,
                message: "Estimated bitrate \(estBitrate) bps outside [10.8, 17.6] Mbps"
            ))
        }

        let preferredTransform = try await track.load(.preferredTransform)
        let measuredOrientation: Int?
        if preferredTransform.isIdentity {
            measuredOrientation = 1
            checks.append(ComplianceCheckItem(
                name: "orientation_upright",
                severity: .pass,
                message: "Track preferredTransform is identity (Orientation == 1)"
            ))
        } else {
            measuredOrientation = nil
            checks.append(ComplianceCheckItem(
                name: "orientation_upright",
                severity: .fail,
                message: "Track preferredTransform is not identity (rotated/transformed)"
            ))
        }

        let formatDescs = try await track.load(.formatDescriptions)
        var measuredBitDepth: Int?

        if let desc = formatDescs.first {
            let subType = CMFormatDescriptionGetMediaSubType(desc)
            if subType == kCMVideoCodecType_HEVC {
                checks.append(ComplianceCheckItem(
                    name: "codec_hevc",
                    severity: .pass,
                    message: "Codec subtype is hvc1/HEVC"
                ))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "codec_hevc",
                    severity: .fail,
                    message: "Expected HEVC codec, got 0x\(String(subType, radix: 16))"
                ))
            }

            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let w = Int(dims.width)
            let h = Int(dims.height)
            let allowedDims = (w == 1080 && h == 1920) || (w == 1080 && h == 1440)
            if allowedDims && w == expected.expectedDimensions.width && h == expected.expectedDimensions.height {
                checks.append(ComplianceCheckItem(
                    name: "dimensions",
                    severity: .pass,
                    message: "Dimensions \(w)x\(h) match expected Douyin HLG spec"
                ))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "dimensions",
                    severity: .fail,
                    message: "Dimensions \(w)x\(h) do not match expected \(expected.expectedDimensions.width)x\(expected.expectedDimensions.height)"
                ))
            }

            let exts = (CMFormatDescriptionGetExtensions(desc) as? [String: Any]) ?? [:]
            let primaries = exts[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            let transfer = exts[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            let matrix = exts[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
            let fullRange = (exts[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber)?.boolValue

            if primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                checks.append(ComplianceCheckItem(name: "color_primaries", severity: .pass, message: "ITU_R_2020"))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "color_primaries",
                    severity: .fail,
                    message: "Expected ITU_R_2020 primaries, got \(String(describing: primaries))"
                ))
            }

            if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                checks.append(ComplianceCheckItem(name: "transfer_function", severity: .pass, message: "ITU_R_2100_HLG"))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "transfer_function",
                    severity: .fail,
                    message: "Expected ITU_R_2100_HLG transfer, got \(String(describing: transfer))"
                ))
            }

            if matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) {
                checks.append(ComplianceCheckItem(name: "ycbcr_matrix", severity: .pass, message: "ITU_R_2020"))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "ycbcr_matrix",
                    severity: .fail,
                    message: "Expected ITU_R_2020 YCbCr matrix, got \(String(describing: matrix))"
                ))
            }

            if fullRange == false {
                checks.append(ComplianceCheckItem(name: "video_range", severity: .pass, message: "Video range (FullRangeVideo=false)"))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "video_range",
                    severity: .fail,
                    message: "Expected Video Range (FullRangeVideo=false), got \(String(describing: fullRange))"
                ))
            }

            if let atoms = exts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
               let hvcc = atoms["hvcC"] as? Data,
               hvcc.count >= 23 {
                let profileIDC = Int(hvcc[1] & 0x1F)
                let chromaFmt = Int(hvcc[16] & 0x03)
                let lumaBits = Int(hvcc[17] & 0x07) + 8
                let chromaBits = Int(hvcc[18] & 0x07) + 8
                measuredBitDepth = lumaBits

                if subType == kCMVideoCodecType_HEVC &&
                    profileIDC == 2 &&
                    chromaFmt == 1 &&
                    lumaBits == 10 &&
                    chromaBits == 10 {
                    checks.append(ComplianceCheckItem(
                        name: "hevc_main10",
                        severity: .pass,
                        message: "hvcC Main 10 4:2:0 10-bit verified"
                    ))
                } else {
                    checks.append(ComplianceCheckItem(
                        name: "hevc_main10",
                        severity: .fail,
                        message: "Invalid hvcC (profileIDC=\(profileIDC), chromaFmt=\(chromaFmt), luma=\(lumaBits), chroma=\(chromaBits))"
                    ))
                }
            } else {
                checks.append(ComplianceCheckItem(
                    name: "hevc_main10",
                    severity: .fail,
                    message: "Missing or truncated hvcC atom"
                ))
            }
        } else {
            checks.append(ComplianceCheckItem(
                name: "format_description",
                severity: .fail,
                message: "Missing video format description"
            ))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        do {
            let (cgImg, _) = try await generator.image(at: .zero)
            if cgImg.width > 0 && cgImg.height > 0 {
                checks.append(ComplianceCheckItem(
                    name: "first_frame_decode",
                    severity: .pass,
                    message: "First frame decoded (\(cgImg.width)x\(cgImg.height))"
                ))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "first_frame_decode",
                    severity: .fail,
                    message: "Decoded first frame has zero dimensions"
                ))
            }
        } catch {
            checks.append(ComplianceCheckItem(
                name: "first_frame_decode",
                severity: .fail,
                message: "First frame decode failed: \(error.localizedDescription)"
            ))
        }

        let passed = !checks.contains(where: { $0.severity == .fail })
        return ComplianceReport(
            fileURL: url,
            passed: passed,
            hasISOGainMap: false,
            measuredHeadroom: nil,
            measuredBitDepth: measuredBitDepth,
            measuredOrientation: measuredOrientation,
            fileSizeBytes: fileSize,
            checks: checks
        )
    }
}
