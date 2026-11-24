import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public struct ISO21496Probe: ComplianceProbeProtocol, Sendable {
    public init() {}

    public func verify(url: URL, expected: ComplianceExpectation) async throws -> ComplianceReport {
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
                message: "Exported file is empty (0 bytes)"
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

        if let maxBytes = expected.maxFileBytes {
            if fileSize <= Int64(maxBytes) {
                checks.append(ComplianceCheckItem(
                    name: "file_size_budget",
                    severity: .pass,
                    message: "File size \(fileSize) <= budget \(maxBytes) bytes"
                ))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "file_size_budget",
                    severity: .fail,
                    message: "File size \(fileSize) exceeds budget \(maxBytes) bytes"
                ))
            }
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) >= 1 else {
            checks.append(ComplianceCheckItem(
                name: "image_source_open",
                severity: .fail,
                message: "ImageIO failed to open image source at \(url.path)"
            ))
            return ComplianceReport(
                fileURL: url,
                passed: false,
                hasISOGainMap: false,
                fileSizeBytes: fileSize,
                checks: checks
            )
        }

        let sourceUTI = CGImageSourceGetType(source) as String?
        let formatMatches: Bool
        switch expected.format {
        case .heic:
            formatMatches = (sourceUTI == "public.heic" || sourceUTI == "public.heif")
        case .jpeg:
            formatMatches = (sourceUTI == "public.jpeg")
        case .avif:
            formatMatches = (sourceUTI == "public.avif")
        case .hlgMP4:
            formatMatches = false
        }
        if formatMatches {
            checks.append(ComplianceCheckItem(
                name: "container_format",
                severity: .pass,
                message: "Container UTI \(sourceUTI ?? "nil") matches expected \(expected.format.rawValue)"
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "container_format",
                severity: .fail,
                message: "Container UTI \(sourceUTI ?? "nil") does not match expected \(expected.format.rawValue)"
            ))
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let measuredOrientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
        let measuredBitDepth = (props[kCGImagePropertyDepth as String] as? NSNumber)?.intValue
        let exifDict = props[kCGImagePropertyExifDictionary as String] as? [String: Any]

        // Orientation must be 1 (physically baked upright)
        if measuredOrientation == 1 {
            checks.append(ComplianceCheckItem(
                name: "orientation_upright",
                severity: .pass,
                message: "Orientation == 1"
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "orientation_upright",
                severity: .fail,
                message: "Expected Orientation == 1, got \(String(describing: measuredOrientation))"
            ))
        }

        // Bit depth check
        if measuredBitDepth == expected.expectedBitDepth.rawValue {
            checks.append(ComplianceCheckItem(
                name: "bit_depth",
                severity: .pass,
                message: "Depth == \(expected.expectedBitDepth.rawValue)"
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "bit_depth",
                severity: .fail,
                message: "Expected Depth == \(expected.expectedBitDepth.rawValue), got \(String(describing: measuredBitDepth))"
            ))
        }

        // Zero MakerNote check (ImageIO dicts + direct byte-level EXIF/TIFF 0x927C scan)
        let hasExifMakerNote = (exifDict?[kCGImagePropertyExifMakerNote as String] != nil)
        let hasAppleMakerDict = (props[kCGImagePropertyMakerAppleDictionary as String] != nil)
        let makerKeys = props.keys.filter { $0.contains("Maker") }.sorted()
        let rawBytes = try? Data(contentsOf: url, options: [.mappedIfSafe])
        let hasRawMakerNote = rawBytes.map { containsRawExifMakerNote(in: $0, formatHint: sourceUTI) } ?? false

        if !hasExifMakerNote && !hasAppleMakerDict && makerKeys.isEmpty && !hasRawMakerNote {
            checks.append(ComplianceCheckItem(
                name: "zero_makernote",
                severity: .pass,
                message: "No MakerNote or Maker dictionaries present"
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "zero_makernote",
                severity: .fail,
                message: "Forbidden MakerNote detected (exifMakerNote=\(hasExifMakerNote), appleDict=\(hasAppleMakerDict), makerKeys=\(makerKeys), rawTag0x927C=\(hasRawMakerNote))"
            ))
        }

        // ISO 21496-1 Gain Map presence + channel count verification
        let isoAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source,
            0,
            kCGImageAuxiliaryDataTypeISOGainMap
        ) as? [String: Any]
        let hasISOGainMap = (isoAux != nil)
        if hasISOGainMap {
            checks.append(ComplianceCheckItem(
                name: "iso_gain_map",
                severity: .pass,
                message: "kCGImageAuxiliaryDataTypeISOGainMap present"
            ))
        } else {
            checks.append(ComplianceCheckItem(
                name: "iso_gain_map",
                severity: .fail,
                message: "Missing kCGImageAuxiliaryDataTypeISOGainMap"
            ))
        }

        if let isoAux {
            checks.append(verifyGainMapChannels(isoAux: isoAux, expected: expected.expectedGainMapChannels))
        }

        // Optional legacy Apple HDRGainMap check (and rejection when forbidden on 3ch HEIC)
        if expected.expectLegacyAppleGainMap {
            let legacyAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source,
                0,
                kCGImageAuxiliaryDataTypeHDRGainMap
            )
            if legacyAux != nil {
                checks.append(ComplianceCheckItem(
                    name: "legacy_apple_gain_map",
                    severity: .pass,
                    message: "kCGImageAuxiliaryDataTypeHDRGainMap present"
                ))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "legacy_apple_gain_map",
                    severity: .fail,
                    message: "Expected kCGImageAuxiliaryDataTypeHDRGainMap for legacy dual-write"
                ))
            }
        } else if expected.format == .heic {
            let legacyAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source,
                0,
                kCGImageAuxiliaryDataTypeHDRGainMap
            )
            let label = expected.expectedGainMapChannels == .rgb3ch ? "3ch HEIC" : "1ch HEIC"
            if legacyAux == nil {
                checks.append(ComplianceCheckItem(
                    name: "legacy_apple_gain_map",
                    severity: .pass,
                    message: "No unexpected legacy kCGImageAuxiliaryDataTypeHDRGainMap on \(label)"
                ))
            } else {
                checks.append(ComplianceCheckItem(
                    name: "legacy_apple_gain_map",
                    severity: .fail,
                    message: "Unexpected legacy kCGImageAuxiliaryDataTypeHDRGainMap present on \(label)"
                ))
            }
        }

        // JPEG hdrgm: XMP check
        if expected.format == .jpeg {
            let hasHdrgmXMP = hasUltraHDRGainMapXMP(source: source)
            if expected.expectUltrahdrXMP {
                if hasHdrgmXMP {
                    checks.append(ComplianceCheckItem(
                        name: "jpeg_hdrgm_xmp",
                        severity: .pass,
                        message: "Ultra HDR hdrgm: XMP present as expected"
                    ))
                } else {
                    checks.append(ComplianceCheckItem(
                        name: "jpeg_hdrgm_xmp",
                        severity: .fail,
                        message: "Expected Ultra HDR hdrgm: XMP metadata, but none found"
                    ))
                }
            } else {
                if !hasHdrgmXMP {
                    checks.append(ComplianceCheckItem(
                        name: "jpeg_hdrgm_xmp",
                        severity: .pass,
                        message: "No hdrgm: XMP emitted on pure ISO JPEG"
                    ))
                } else {
                    checks.append(ComplianceCheckItem(
                        name: "jpeg_hdrgm_xmp",
                        severity: .fail,
                        message: "Unexpected hdrgm: XMP found when expectUltrahdrXMP == false"
                    ))
                }
            }
        }

        // HDR Decode & contentHeadroom tolerance check
        let hdrOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ]
        var measuredHeadroom: LinearHeadroom?
        if let hdrImage = CGImageSourceCreateImageAtIndex(source, 0, hdrOpts as CFDictionary) {
            let ciHeadroom = CIImage(contentsOf: url, options: [.expandToHDR: true]).map {
                Double($0.contentHeadroom)
            }
            let rawHeadroom = ciHeadroom ?? Double(hdrImage.contentHeadroom)
            let expectedLinear = expected.expectedHeadroom.multiplier

            if !expectedLinear.isFinite || expectedLinear <= 0.0 {
                checks.append(ComplianceCheckItem(
                    name: "content_headroom",
                    severity: .fail,
                    message: "Invalid expected headroom multiplier: \(expectedLinear)"
                ))
            } else if !rawHeadroom.isFinite || rawHeadroom <= 0.0 {
                checks.append(ComplianceCheckItem(
                    name: "content_headroom",
                    severity: .fail,
                    message: "Decoded contentHeadroom is non-finite or non-positive (\(rawHeadroom))"
                ))
            } else {
                measuredHeadroom = LinearHeadroom(multiplier: rawHeadroom)
                if expectedLinear > 1.0 && rawHeadroom <= 1.0 {
                    checks.append(ComplianceCheckItem(
                        name: "content_headroom",
                        severity: .fail,
                        message: "Decoded contentHeadroom (\(rawHeadroom)) must be > 1.0"
                    ))
                } else {
                    let relErr = abs(rawHeadroom - expectedLinear) / expectedLinear
                    if relErr < 0.02 {
                        checks.append(ComplianceCheckItem(
                            name: "content_headroom",
                            severity: .pass,
                            message: String(
                                format: "contentHeadroom=%.4f matches expected=%.4f (err=%.2f%%)",
                                locale: Locale(identifier: "en_US_POSIX"),
                                rawHeadroom,
                                expectedLinear,
                                relErr * 100.0
                            )
                        ))
                    } else {
                        checks.append(ComplianceCheckItem(
                            name: "content_headroom",
                            severity: .fail,
                            message: String(
                                format: "contentHeadroom=%.4f differs from expected=%.4f by %.2f%% (>= 2.0%%)",
                                locale: Locale(identifier: "en_US_POSIX"),
                                rawHeadroom,
                                expectedLinear,
                                relErr * 100.0
                            )
                        ))
                    }
                }
            }
        } else {
            checks.append(ComplianceCheckItem(
                name: "hdr_decode",
                severity: .fail,
                message: "kCGImageSourceDecodeToHDR failed"
            ))
        }

        let passed = !checks.contains(where: { $0.severity == .fail })
        return ComplianceReport(
            fileURL: url,
            passed: passed,
            hasISOGainMap: hasISOGainMap,
            measuredHeadroom: measuredHeadroom,
            measuredBitDepth: measuredBitDepth,
            measuredOrientation: measuredOrientation,
            fileSizeBytes: fileSize,
            checks: checks
        )
    }

    private func verifyGainMapChannels(
        isoAux: [String: Any],
        expected: GainMapChannels
    ) -> ComplianceCheckItem {
        let dataDesc = isoAux[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any]
        let pixelFormat = (dataDesc?[kCGImagePropertyPixelFormat as String] as? NSNumber)?.uint32Value

        var channelMetaCount: Int?
        if let metaObj = isoAux[kCGImageAuxiliaryDataInfoMetadata as String] {
            let cfObj = metaObj as CFTypeRef
            if CFGetTypeID(cfObj) == CGImageMetadataGetTypeID() {
                let auxMeta = unsafeDowncast(cfObj, to: CGImageMetadata.self)
                channelMetaCount = extractChannelMetadataCount(from: auxMeta)
            }
        }

        let monoFormat: UInt32 = 0x4C303038 // 'L008'
        let threeChFormats: Set<UInt32> = [
            0x34323066, // '420f'
            0x34323076, // '420v'
            0x42475241, // 'BGRA'
            0x52474241, // 'RGBA'
        ]

        let formatStr = pixelFormat.map(fourCCString) ?? "nil"
        let metaStr = channelMetaCount.map(String.init) ?? "nil"

        switch expected {
        case .mono1ch:
            let fmtOK = (pixelFormat == monoFormat)
            let metaOK = (channelMetaCount == nil || channelMetaCount == 1)
            if fmtOK && metaOK {
                return ComplianceCheckItem(
                    name: "gain_map_channels",
                    severity: .pass,
                    message: "Gain map channels match mono1ch (pixelFormat='\(formatStr)', channelMetadataCount=\(metaStr))"
                )
            } else {
                return ComplianceCheckItem(
                    name: "gain_map_channels",
                    severity: .fail,
                    message: "Expected mono1ch gain map ('L008', 1 channel), got pixelFormat='\(formatStr)', channelMetadataCount=\(metaStr)"
                )
            }
        case .rgb3ch:
            let fmtOK = pixelFormat.map { threeChFormats.contains($0) } ?? false
            // ISO/IEC 21496-1 allows channel_count=1 metadata when all 3 channels share identical parameters
            // (e.g. libavif tmap compaction) as long as the auxiliary image pixelFormat itself is 3-channel.
            let metaOK = (channelMetaCount == nil || channelMetaCount == 3 || channelMetaCount == 1)
            if fmtOK && metaOK {
                return ComplianceCheckItem(
                    name: "gain_map_channels",
                    severity: .pass,
                    message: "Gain map channels match rgb3ch (pixelFormat='\(formatStr)', channelMetadataCount=\(metaStr))"
                )
            } else {
                return ComplianceCheckItem(
                    name: "gain_map_channels",
                    severity: .fail,
                    message: "Expected rgb3ch gain map (3 channels), got pixelFormat='\(formatStr)', channelMetadataCount=\(metaStr)"
                )
            }
        }
    }

    private func extractChannelMetadataCount(from meta: CGImageMetadata) -> Int? {
        if let tag = CGImageMetadataCopyTagWithPath(meta, nil, "HDRToneMap:ChannelMetadata" as CFString),
           let val = CGImageMetadataTagCopyValue(tag) as? [Any] {
            return val.count
        }
        if let xmpData = CGImageMetadataCreateXMPData(meta, nil) as Data? {
            let xmp = String(decoding: xmpData, as: UTF8.self)
            if let start = xmp.range(of: "<HDRToneMap:ChannelMetadata"),
               let end = xmp.range(of: "</HDRToneMap:ChannelMetadata>", range: start.upperBound..<xmp.endIndex) {
                let slice = xmp[start.upperBound..<end.lowerBound]
                var count = 0
                var searchRange = slice.startIndex..<slice.endIndex
                while let r = slice.range(of: "<rdf:li", range: searchRange) {
                    count += 1
                    searchRange = r.upperBound..<slice.endIndex
                }
                if count > 0 {
                    return count
                }
            }
        }
        return nil
    }

    private func fourCCString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return "0x" + String(code, radix: 16)
    }

    // MARK: - Raw Byte-Level EXIF/TIFF 0x927C (MakerNote) Scanner

    private func containsRawExifMakerNote(in data: Data, formatHint: String?) -> Bool {
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 {
            return jpegContainsMakerNote(data)
        }
        if formatHint == "public.jpeg" {
            return jpegContainsMakerNote(data)
        }
        if isISOBMFF(data) || formatHint == "public.heic" || formatHint == "public.heif" || formatHint == "public.avif" {
            return isobmffContainsMakerNote(data)
        }
        if tiffContainsMakerNote(data, startOffset: 0) {
            return true
        }
        return false
    }

    private func isISOBMFF(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        // 'ftyp' = 0x66747970
        return data[4] == 0x66 && data[5] == 0x74 && data[6] == 0x79 && data[7] == 0x70
    }

    private func jpegContainsMakerNote(_ data: Data) -> Bool {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
            return false
        }
        var pos = 2
        while pos < data.count {
            if data[pos] != 0xFF {
                break
            }
            while pos < data.count && data[pos] == 0xFF {
                pos += 1
            }
            if pos >= data.count {
                break
            }
            let marker = data[pos]
            pos += 1
            if marker == 0x00 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8) {
                continue
            }
            if marker == 0xD9 || marker == 0xDA {
                break
            }
            guard pos + 2 <= data.count else {
                break
            }
            let segLen = (Int(data[pos]) << 8) | Int(data[pos + 1])
            guard segLen >= 2, pos + segLen <= data.count else {
                break
            }
            if marker == 0xE1 && segLen >= 8 {
                let p = pos + 2
                if data[p] == 0x45 && data[p + 1] == 0x78 && data[p + 2] == 0x69 &&
                   data[p + 3] == 0x66 && data[p + 4] == 0x00 && data[p + 5] == 0x00 {
                    let tiffSlice = Data(data[(p + 6)..<(pos + segLen)])
                    if tiffContainsMakerNote(tiffSlice, startOffset: 0) {
                        return true
                    }
                }
            }
            pos += segLen
        }
        return false
    }

    private func isobmffContainsMakerNote(_ data: Data) -> Bool {
        let topBoxes = parseISOBMFFBoxes(in: data, range: 0..<data.count)
        let boxMeta: UInt32 = 0x6D657461 // 'meta'
        let boxMoov: UInt32 = 0x6D6F6F76 // 'moov'
        let boxIinf: UInt32 = 0x69696E66 // 'iinf'
        let boxIloc: UInt32 = 0x696C6F63 // 'iloc'
        let boxIdat: UInt32 = 0x69646174 // 'idat'
        let boxExif: UInt32 = 0x45786966 // 'Exif'

        var metaRanges: [Range<Int>] = []
        for box in topBoxes {
            if box.type == boxMeta {
                metaRanges.append(box.payload)
            } else if box.type == boxMoov {
                for sub in parseISOBMFFBoxes(in: data, range: box.payload) where sub.type == boxMeta {
                    metaRanges.append(sub.payload)
                }
            }
        }

        for metaPayload in metaRanges {
            var childBoxes: [(type: UInt32, payload: Range<Int>)] = []
            if metaPayload.count >= 4 {
                childBoxes = parseISOBMFFBoxes(in: data, range: (metaPayload.lowerBound + 4)..<metaPayload.upperBound)
            }
            if childBoxes.isEmpty {
                childBoxes = parseISOBMFFBoxes(in: data, range: metaPayload)
            }

            var exifItemIDs = Set<UInt32>()
            var ilocPayload: Range<Int>?
            var idatPayload: Range<Int>?

            for child in childBoxes {
                if child.type == boxIinf {
                    collectExifItemIDs(from: data, iinfPayload: child.payload, into: &exifItemIDs)
                } else if child.type == boxIloc {
                    ilocPayload = child.payload
                } else if child.type == boxIdat {
                    idatPayload = child.payload
                } else if child.type == boxExif {
                    let itemData = Data(data[child.payload])
                    if exifItemPayloadContainsMakerNote(itemData) {
                        return true
                    }
                }
            }

            if !exifItemIDs.isEmpty, let ilocPayload {
                let payloads = extractItemPayloads(
                    from: data,
                    ilocPayload: ilocPayload,
                    targetItemIDs: exifItemIDs,
                    idatPayload: idatPayload
                )
                for itemData in payloads where exifItemPayloadContainsMakerNote(itemData) {
                    return true
                }
            }
        }

        // Defensive scan for "Exif\0\0" + TIFF header in case of non-standard box packaging
        let exifMarkers: [[UInt8]] = [
            [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x49, 0x49, 0x2A, 0x00],
            [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x4D, 0x4D, 0x00, 0x2A],
        ]
        for sig in exifMarkers {
            let sigData = Data(sig)
            var searchStart = 0
            while searchStart < data.count,
                  let found = data.range(of: sigData, options: [], in: searchStart..<data.count) {
                if tiffContainsMakerNote(data, startOffset: found.lowerBound + 6) {
                    return true
                }
                searchStart = found.upperBound
            }
        }
        return false
    }

    private func parseISOBMFFBoxes(in data: Data, range: Range<Int>) -> [(type: UInt32, payload: Range<Int>)] {
        var cursor = range.lowerBound
        var boxes: [(UInt32, Range<Int>)] = []
        while cursor + 8 <= range.upperBound && boxes.count < 4096 {
            let size32 = readUInt32BE(data, at: cursor)
            let boxType = readUInt32BE(data, at: cursor + 4)
            var headerLen = 8
            var boxSize64 = UInt64(size32)
            if size32 == 0 {
                boxSize64 = UInt64(range.upperBound - cursor)
            } else if size32 == 1 {
                guard cursor + 16 <= range.upperBound else { break }
                boxSize64 = readUInt64BE(data, at: cursor + 8)
                headerLen = 16
            }
            let remaining = UInt64(range.upperBound - cursor)
            guard boxSize64 >= UInt64(headerLen), boxSize64 <= remaining else {
                break
            }
            let payloadStart = cursor + headerLen
            let boxEnd = cursor + Int(boxSize64)
            boxes.append((boxType, payloadStart..<boxEnd))
            cursor = boxEnd
        }
        return boxes
    }

    private func collectExifItemIDs(from data: Data, iinfPayload: Range<Int>, into ids: inout Set<UInt32>) {
        guard iinfPayload.count >= 6 else { return }
        let version = data[iinfPayload.lowerBound]
        var cursor = iinfPayload.lowerBound + 4
        if version == 0 {
            guard cursor + 2 <= iinfPayload.upperBound else { return }
            cursor += 2
        } else {
            guard cursor + 4 <= iinfPayload.upperBound else { return }
            cursor += 4
        }

        let boxInfe: UInt32 = 0x696E6665 // 'infe'
        let typeExif: UInt32 = 0x45786966 // 'Exif'
        for child in parseISOBMFFBoxes(in: data, range: cursor..<iinfPayload.upperBound) where child.type == boxInfe {
            let p = child.payload
            guard p.count >= 4 else { continue }
            let infeVer = data[p.lowerBound]
            if infeVer == 2, p.count >= 12 {
                let itemID = UInt32(readUInt16BE(data, at: p.lowerBound + 4))
                let itemType = readUInt32BE(data, at: p.lowerBound + 8)
                if itemType == typeExif {
                    ids.insert(itemID)
                }
            } else if infeVer == 3, p.count >= 14 {
                let itemID = readUInt32BE(data, at: p.lowerBound + 4)
                let itemType = readUInt32BE(data, at: p.lowerBound + 10)
                if itemType == typeExif {
                    ids.insert(itemID)
                }
            }
        }
    }

    private func extractItemPayloads(
        from data: Data,
        ilocPayload: Range<Int>,
        targetItemIDs: Set<UInt32>,
        idatPayload: Range<Int>?
    ) -> [Data] {
        guard ilocPayload.count >= 8 else { return [] }
        let version = data[ilocPayload.lowerBound]
        let b0 = data[ilocPayload.lowerBound + 4]
        let b1 = data[ilocPayload.lowerBound + 5]
        let offsetSize = Int((b0 >> 4) & 0x0F)
        let lengthSize = Int(b0 & 0x0F)
        let baseOffsetSize = Int((b1 >> 4) & 0x0F)
        let indexSize = (version == 1 || version == 2) ? Int(b1 & 0x0F) : 0
        let validSizes: Set<Int> = [0, 4, 8]
        guard validSizes.contains(offsetSize),
              validSizes.contains(lengthSize),
              validSizes.contains(baseOffsetSize),
              validSizes.contains(indexSize) else {
            return []
        }

        var cursor = ilocPayload.lowerBound + 6
        let itemCount: Int
        if version < 2 {
            guard cursor + 2 <= ilocPayload.upperBound else { return [] }
            itemCount = Int(readUInt16BE(data, at: cursor))
            cursor += 2
        } else {
            guard cursor + 4 <= ilocPayload.upperBound else { return [] }
            itemCount = Int(min(readUInt32BE(data, at: cursor), 10_000))
            cursor += 4
        }

        var results: [Data] = []
        let idSize = (version < 2) ? 2 : 4

        for _ in 0..<min(itemCount, 10_000) {
            guard cursor + idSize <= ilocPayload.upperBound else { break }
            let itemID: UInt32
            if idSize == 2 {
                itemID = UInt32(readUInt16BE(data, at: cursor))
            } else {
                itemID = readUInt32BE(data, at: cursor)
            }
            cursor += idSize

            var constructionMethod: UInt8 = 0
            if version == 1 || version == 2 {
                guard cursor + 2 <= ilocPayload.upperBound else { break }
                constructionMethod = data[cursor + 1] & 0x0F
                cursor += 2
            }

            // data_reference_index (2 bytes)
            guard cursor + 2 <= ilocPayload.upperBound else { break }
            cursor += 2

            guard cursor + baseOffsetSize <= ilocPayload.upperBound else { break }
            let baseOffset = readUIntNBE(data, at: cursor, size: baseOffsetSize)
            cursor += baseOffsetSize

            guard cursor + 2 <= ilocPayload.upperBound else { break }
            let extentCount = Int(readUInt16BE(data, at: cursor))
            cursor += 2

            let extentBytes = indexSize + offsetSize + lengthSize
            let (totalExtentSpan, spanOverflow) = extentCount.multipliedReportingOverflow(by: extentBytes)
            guard extentCount >= 0,
                  !spanOverflow,
                  cursor + totalExtentSpan <= ilocPayload.upperBound else {
                break
            }

            if targetItemIDs.contains(itemID) && (constructionMethod == 0 || constructionMethod == 1) {
                var assembled = Data()
                let maxAssembledBytes = 4 * 1024 * 1024
                var validExtents = true

                for _ in 0..<extentCount {
                    cursor += indexSize
                    let extOffset = readUIntNBE(data, at: cursor, size: offsetSize)
                    cursor += offsetSize
                    let extLength = readUIntNBE(data, at: cursor, size: lengthSize)
                    cursor += lengthSize

                    let baseAdjust: UInt64 = (constructionMethod == 1)
                        ? UInt64(idatPayload?.lowerBound ?? 0)
                        : 0
                    let upperLimit: Int = (constructionMethod == 1)
                        ? (idatPayload?.upperBound ?? 0)
                        : data.count

                    let (sum1, ov1) = baseOffset.addingReportingOverflow(extOffset)
                    let (absStart64, ov2) = sum1.addingReportingOverflow(baseAdjust)
                    let (absEnd64, ov3) = absStart64.addingReportingOverflow(extLength)

                    if ov1 || ov2 || ov3 ||
                        absStart64 > UInt64(upperLimit) ||
                        absEnd64 > UInt64(upperLimit) ||
                        UInt64(assembled.count) + extLength > UInt64(maxAssembledBytes) {
                        validExtents = false
                        continue
                    }
                    assembled.append(data[Int(absStart64)..<Int(absEnd64)])
                }
                if validExtents && !assembled.isEmpty {
                    results.append(assembled)
                }
            } else {
                cursor += totalExtentSpan
            }
        }

        return results
    }

    private func exifItemPayloadContainsMakerNote(_ itemData: Data) -> Bool {
        if itemData.count >= 4 {
            // Direct TIFF header
            if tiffContainsMakerNote(itemData, startOffset: 0) {
                return true
            }
            // "Exif\0\0" + TIFF header
            if itemData.count >= 10,
               itemData[0] == 0x45, itemData[1] == 0x78, itemData[2] == 0x69,
               itemData[3] == 0x66, itemData[4] == 0x00, itemData[5] == 0x00 {
                if tiffContainsMakerNote(Data(itemData.dropFirst(6)), startOffset: 0) {
                    return true
                }
            }
            // ISO 23008-12 4-byte exif_tiff_header_offset followed by optional "Exif\0\0" + TIFF
            let hdrOff = readUInt32BE(itemData, at: 0)
            if hdrOff <= UInt32(itemData.count), 4 + Int(hdrOff) < itemData.count {
                let sliced = Data(itemData.dropFirst(4 + Int(hdrOff)))
                if tiffContainsMakerNote(sliced, startOffset: 0) {
                    return true
                }
            }
        }
        return false
    }

    private func tiffContainsMakerNote(_ data: Data, startOffset: Int) -> Bool {
        guard startOffset >= 0, startOffset + 8 <= data.count else {
            return false
        }

        let isLittleEndian: Bool
        let b0 = data[startOffset]
        let b1 = data[startOffset + 1]
        let b2 = data[startOffset + 2]
        let b3 = data[startOffset + 3]
        if b0 == 0x49 && b1 == 0x49 && b2 == 0x2A && b3 == 0x00 {
            isLittleEndian = true
        } else if b0 == 0x4D && b1 == 0x4D && b2 == 0x00 && b3 == 0x2A {
            isLittleEndian = false
        } else {
            return false
        }

        func read16(_ offset: Int) -> UInt16 {
            isLittleEndian ? readUInt16LE(data, at: offset) : readUInt16BE(data, at: offset)
        }
        func read32(_ offset: Int) -> UInt32 {
            isLittleEndian ? readUInt32LE(data, at: offset) : readUInt32BE(data, at: offset)
        }

        let ifd0RelOffset = Int(read32(startOffset + 4))
        var visitedRelOffsets = Set<Int>()
        var queue: [Int] = [ifd0RelOffset]

        while !queue.isEmpty && visitedRelOffsets.count < 128 {
            let relOff = queue.removeFirst()
            guard relOff >= 8, !visitedRelOffsets.contains(relOff) else { continue }
            visitedRelOffsets.insert(relOff)

            let absOff = startOffset + relOff
            guard absOff >= startOffset, absOff + 2 <= data.count else { continue }

            let entryCount = Int(read16(absOff))
            let entriesStart = absOff + 2
            let maxPossible = (data.count - entriesStart) / 12
            let boundedCount = min(entryCount, maxPossible)
            guard boundedCount >= 0 else { continue }

            for i in 0..<boundedCount {
                let eOff = entriesStart + i * 12
                let tag = read16(eOff)
                if tag == 0x927C {
                    return true
                }

                let type = read16(eOff + 2)
                let count = read32(eOff + 4)

                // ExifIFD (0x8769), GPSIFD (0x8825), InteropIFD (0xA005), SubIFDs (0x014A)
                if tag == 0x8769 || tag == 0x8825 || tag == 0xA005 {
                    if count >= 1 && (type == 4 || type == 13 || type == 3) {
                        let subOff = (type == 3 && count == 1) ? Int(read16(eOff + 8)) : Int(read32(eOff + 8))
                        if subOff >= 8 && !visitedRelOffsets.contains(subOff) {
                            queue.append(subOff)
                        }
                    }
                } else if tag == 0x014A {
                    if count == 1 && (type == 4 || type == 13) {
                        let subOff = Int(read32(eOff + 8))
                        if subOff >= 8 && !visitedRelOffsets.contains(subOff) {
                            queue.append(subOff)
                        }
                    } else if count > 1 && (type == 4 || type == 13) {
                        let arrRel = Int(read32(eOff + 8))
                        let arrAbs = startOffset + arrRel
                        let n = min(Int(count), 32)
                        if arrRel >= 8 && arrAbs >= startOffset && arrAbs + n * 4 <= data.count {
                            for j in 0..<n {
                                let subOff = Int(read32(arrAbs + j * 4))
                                if subOff >= 8 && !visitedRelOffsets.contains(subOff) {
                                    queue.append(subOff)
                                }
                            }
                        }
                    }
                }
            }

            let nextIFDPtrOff = entriesStart + entryCount * 12
            if nextIFDPtrOff >= entriesStart && nextIFDPtrOff + 4 <= data.count {
                let nextRel = Int(read32(nextIFDPtrOff))
                if nextRel >= 8 && !visitedRelOffsets.contains(nextRel) {
                    queue.append(nextRel)
                }
            }
        }

        return false
    }

    private func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(data[offset + i])
        }
        return v
    }

    private func readUIntNBE(_ data: Data, at offset: Int, size: Int) -> UInt64 {
        switch size {
        case 0: return 0
        case 4: return UInt64(readUInt32BE(data, at: offset))
        case 8: return readUInt64BE(data, at: offset)
        default: return 0
        }
    }

    private func hasUltraHDRGainMapXMP(source: CGImageSource) -> Bool {
        guard let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else {
            return false
        }
        for tag in tags {
            if let ns = CGImageMetadataTagCopyNamespace(tag) as String?,
               ns.contains("ns.adobe.com/hdr-gain-map") {
                return true
            }
            if let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
               prefix == "hdrgm" {
                return true
            }
        }
        return false
    }
}
