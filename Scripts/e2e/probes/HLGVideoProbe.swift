import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

struct HLGVideoProbeOutput: Codable {
    var filePath: String
    var fileSizeBytes: Int64
    var hasVideoTrack: Bool
    var codecSubType: String?
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var nominalFrameRate: Double?
    var estimatedBitrateBps: Double?
    var colorPrimaries: String?
    var transferFunction: String?
    var ycbcrMatrix: String?
    var fullRangeVideo: Bool?
    var bitsPerComponentExt: Int?
    var hvccPresent: Bool
    var hvccProfileIDC: Int?
    var hvccChromaFormat: Int?
    var hvccBitDepthLuma: Int?
    var hvccBitDepthChroma: Int?
    var isHEVCMain10: Bool
    var firstFrameReadable: Bool
    var error: String?
}

func fourCCString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", code)
}

@main
struct HLGVideoProbeMain {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: HLGVideoProbe <mp4-path>\n", stderr)
            exit(2)
        }
        let path = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        var out = HLGVideoProbeOutput(
            filePath: path,
            fileSizeBytes: fileSize,
            hasVideoTrack: false,
            codecSubType: nil,
            width: nil,
            height: nil,
            durationSeconds: nil,
            nominalFrameRate: nil,
            estimatedBitrateBps: nil,
            colorPrimaries: nil,
            transferFunction: nil,
            ycbcrMatrix: nil,
            fullRangeVideo: nil,
            bitsPerComponentExt: nil,
            hvccPresent: false,
            hvccProfileIDC: nil,
            hvccChromaFormat: nil,
            hvccBitDepthLuma: nil,
            hvccBitDepthChroma: nil,
            isHEVCMain10: false,
            firstFrameReadable: false,
            error: nil
        )

        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            let durSec = CMTimeGetSeconds(duration)
            out.durationSeconds = durSec.isFinite ? durSec : nil

            guard let track = tracks.first else {
                out.error = "No video track found"
                emitAndExit(out, code: 1)
            }
            out.hasVideoTrack = true
            let fps = Double(try await track.load(.nominalFrameRate))
            out.nominalFrameRate = fps.isFinite ? fps : nil
            let estBitrate = Double(try await track.load(.estimatedDataRate))
            out.estimatedBitrateBps = estBitrate.isFinite ? estBitrate : nil

            let formatDescs = try await track.load(.formatDescriptions)
            if let desc = formatDescs.first {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                out.codecSubType = fourCCString(subType)
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                out.width = Int(dims.width)
                out.height = Int(dims.height)

                if let exts = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                    out.colorPrimaries = exts[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                    out.transferFunction = exts[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                    out.ycbcrMatrix = exts[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
                    if let fullRange = exts[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber {
                        out.fullRangeVideo = fullRange.boolValue
                    }
                    if let bpc = exts[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber {
                        out.bitsPerComponentExt = bpc.intValue
                    }
                    if let atoms = exts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
                       let hvcc = atoms["hvcC"] as? Data,
                       hvcc.count >= 23
                    {
                        out.hvccPresent = true
                        let profileIDC = Int(hvcc[1] & 0x1F)
                        let chromaFmt = Int(hvcc[16] & 0x03)
                        let lumaBits = Int(hvcc[17] & 0x07) + 8
                        let chromaBits = Int(hvcc[18] & 0x07) + 8
                        out.hvccProfileIDC = profileIDC
                        out.hvccChromaFormat = chromaFmt
                        out.hvccBitDepthLuma = lumaBits
                        out.hvccBitDepthChroma = chromaBits
                        out.isHEVCMain10 = (subType == kCMVideoCodecType_HEVC)
                            && (profileIDC == 2)
                            && (lumaBits == 10)
                            && (chromaBits == 10)
                    }
                }
            }

            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            do {
                let (cgImg, _) = try await gen.image(at: .zero)
                out.firstFrameReadable = (cgImg.width > 0 && cgImg.height > 0)
            } catch {
                out.firstFrameReadable = false
            }

            emitAndExit(out, code: 0)
        } catch {
            out.error = "AVAsset probe failed: \(error.localizedDescription)"
            emitAndExit(out, code: 1)
        }
    }

    static func emitAndExit(_ out: HLGVideoProbeOutput, code: Int32) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(out), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        exit(code)
    }
}
