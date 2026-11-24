import Foundation
import ImageIO

public enum ExifWhitelistBuilderError: Error, Sendable, Equatable, CustomStringConvertible {
    case payloadExceedsLimit(actualBytes: Int, maxBytes: Int)
    case serializationFailed(String)

    public var description: String {
        switch self {
        case let .payloadExceedsLimit(actualBytes, maxBytes):
            return "Serialized EXIF TIFF payload (\(actualBytes) bytes) exceeds maximum limit (\(maxBytes) bytes)"
        case let .serializationFailed(reason):
            return "EXIF serialization failed: \(reason)"
        }
    }
}

public enum ExifWhitelistBuilder {
    public static let maxTIFFPayloadBytes = 8192
    private static let maxASCIIFieldBytes = 255

    // MARK: - Public API

    /// Builds a raw little-endian Exif 2.32 TIFF payload (`II*\0` + IFD0 offset `8`),
    /// containing strictly whitelisted tags, forced `Orientation = 1`, optional
    /// `CustomRendered = 3`, and zero `MakerNote` (`0x927C`) tags.
    public static func buildTIFFData(
        from exif: WhitelistedExif,
        customRenderedHDR: Bool = false
    ) throws -> Data {
        let gpsNorm = normalizeGPS(exif)
        let effectiveCustomRendered = resolveCustomRendered(exif: exif, customRenderedHDR: customRenderedHDR)

        let makeStr = sanitizeString(exif.make)
        let modelStr = sanitizeString(exif.model)
        let dateTimeOrigStr = sanitizeString(exif.dateTimeOriginal)
        let offsetTimeOrigStr = sanitizeString(exif.offsetTimeOriginal)
        let subSecTimeOrigStr = sanitizeString(exif.subSecTimeOriginal)
        let lensMakeStr = sanitizeString(exif.lensMake)
        let lensModelStr = sanitizeString(exif.lensModel)

        let hasDateTimeIFD0 = (dateTimeOrigStr != nil)

        // 1. Build ExifIFD entries (strictly ascending UInt16 tag IDs)
        var exifEntries: [TIFFEntrySpec] = []

        if let exp = exif.exposureTimeSeconds, exp.isFinite, exp > 0,
           let rat = exposureRational(exp) {
            exifEntries.append(.rational(tag: 0x829A, values: [rat]))
        }
        if let fn = exif.fNumber, fn.isFinite, fn > 0,
           let rat = positiveRational(fn, scale: 100) {
            exifEntries.append(.rational(tag: 0x829D, values: [rat]))
        }
        if let iso = exif.isoSpeedRatings, iso > 0 {
            exifEntries.append(.short(tag: 0x8827, value: UInt16(clamping: iso)))
            if iso > Int(UInt16.max) {
                exifEntries.append(.short(tag: 0x8830, value: 2)) // SensitivityType = Recommended Exposure Index
                exifEntries.append(.long(tag: 0x8832, value: UInt32(clamping: iso)))
            }
        }
        // Always emit ExifVersion 0232 so ExifIFD is non-empty and valid Exif 2.32
        exifEntries.append(.undefinedInline4(tag: 0x9000, bytes: [0x30, 0x32, 0x33, 0x32]))

        if let dto = dateTimeOrigStr {
            exifEntries.append(.ascii(tag: 0x9003, string: dto))
        }
        if hasDateTimeIFD0, let offset = offsetTimeOrigStr {
            exifEntries.append(.ascii(tag: 0x9010, string: offset))
        }
        if let offset = offsetTimeOrigStr {
            // Canonical OffsetTimeOriginal tag ID is 0x9011
            exifEntries.append(.ascii(tag: 0x9011, string: offset))
        }
        if let bias = exif.exposureBiasEV, bias.isFinite,
           let srat = signedExposureBiasRational(bias) {
            exifEntries.append(.srational(tag: 0x9204, values: [srat]))
        }
        if let fl = exif.focalLengthMM, fl.isFinite, fl > 0,
           let rat = positiveRational(fl, scale: 100) {
            exifEntries.append(.rational(tag: 0x920A, values: [rat]))
        }
        if let subsec = subSecTimeOrigStr {
            exifEntries.append(.ascii(tag: 0x9291, string: subsec))
        }
        if let cr = effectiveCustomRendered {
            exifEntries.append(.short(tag: 0xA401, value: UInt16(cr)))
        }
        if let fl35 = exif.focalLengthIn35mmFilm, fl35 > 0 {
            exifEntries.append(.short(tag: 0xA405, value: UInt16(clamping: fl35)))
        }
        if let lm = lensMakeStr {
            exifEntries.append(.ascii(tag: 0xA433, string: lm))
        }
        if let lmod = lensModelStr {
            exifEntries.append(.ascii(tag: 0xA434, string: lmod))
        }

        // 2. Build GPSIFD entries if valid GPS coordinates are present
        var gpsEntries: [TIFFEntrySpec] = []
        if let gps = gpsNorm {
            gpsEntries.append(.bytesInline4(tag: 0x0000, bytes: [2, 3, 0, 0])) // GPSVersionID 2.3.0.0
            gpsEntries.append(.ascii(tag: 0x0001, string: gps.latRef))
            gpsEntries.append(.rational(tag: 0x0002, values: decimalDegreesToDMS(gps.latAbs)))
            gpsEntries.append(.ascii(tag: 0x0003, string: gps.lonRef))
            gpsEntries.append(.rational(tag: 0x0004, values: decimalDegreesToDMS(gps.lonAbs)))
            if let altAbs = gps.altAbs, let altRef = gps.altRef,
               let altRat = positiveRational(altAbs, scale: 100, allowZero: true) {
                gpsEntries.append(.byte(tag: 0x0005, value: UInt8(altRef & 1)))
                gpsEntries.append(.rational(tag: 0x0006, values: [altRat]))
            }
            if let tsRationals = gps.timestampRationals {
                gpsEntries.append(.rational(tag: 0x0007, values: tsRationals))
            }
            if let ds = gps.dateStamp {
                gpsEntries.append(.ascii(tag: 0x001D, string: ds))
            }
        }

        // 3. Build IFD0 entries (strictly ascending UInt16 tag IDs, Orientation forced to 1)
        var ifd0Entries: [TIFFEntrySpec] = []
        if let mk = makeStr {
            ifd0Entries.append(.ascii(tag: 0x010F, string: mk))
        }
        if let md = modelStr {
            ifd0Entries.append(.ascii(tag: 0x0110, string: md))
        }
        // Unconditionally force Orientation = 1 (pixels are physically rotated upright before encoding)
        ifd0Entries.append(.short(tag: 0x0112, value: 1))
        if let dto = dateTimeOrigStr {
            ifd0Entries.append(.ascii(tag: 0x0132, string: dto))
        }
        // Placeholder pointers for ExifIFD (0x8769) and optional GPSIFD (0x8825)
        ifd0Entries.append(.long(tag: 0x8769, value: 0))
        if !gpsEntries.isEmpty {
            ifd0Entries.append(.long(tag: 0x8825, value: 0))
        }

        try validateSortedTags(ifd0Entries, ifdName: "IFD0")
        try validateSortedTags(exifEntries, ifdName: "ExifIFD")
        if !gpsEntries.isEmpty {
            try validateSortedTags(gpsEntries, ifdName: "GPSIFD")
        }

        // 4. Serialize TIFF binary with back-patched IFD pointers and even-aligned offsets
        var out = Data()
        // TIFF header: "II*\0" + IFD0 offset (8)
        out.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        appendUInt32(8, to: &out)

        let ifd0PatchOffsets = serializeIFD(entries: ifd0Entries, into: &out)

        // Align ExifIFD start to even offset
        padToEven(&out)
        let exifIFDOffset = UInt32(out.count)
        _ = serializeIFD(entries: exifEntries, into: &out)

        var gpsIFDOffset: UInt32 = 0
        if !gpsEntries.isEmpty {
            padToEven(&out)
            gpsIFDOffset = UInt32(out.count)
            _ = serializeIFD(entries: gpsEntries, into: &out)
        }

        // Back-patch ExifIFD pointer (0x8769) and GPSIFD pointer (0x8825)
        guard let exifPtrPos = ifd0PatchOffsets[0x8769] else {
            throw ExifWhitelistBuilderError.serializationFailed("Missing ExifIFD patch offset")
        }
        writeUInt32(exifIFDOffset, at: exifPtrPos, in: &out)

        if !gpsEntries.isEmpty {
            guard let gpsPtrPos = ifd0PatchOffsets[0x8825] else {
                throw ExifWhitelistBuilderError.serializationFailed("Missing GPSIFD patch offset")
            }
            writeUInt32(gpsIFDOffset, at: gpsPtrPos, in: &out)
        }

        guard out.count < maxTIFFPayloadBytes else {
            throw ExifWhitelistBuilderError.payloadExceedsLimit(
                actualBytes: out.count,
                maxBytes: maxTIFFPayloadBytes
            )
        }

        return out
    }

    /// Builds `"Exif\0\0"` (6 bytes) + `buildTIFFData(...)` for JPEG APP1 segments.
    public static func buildAPP1ExifData(
        from exif: WhitelistedExif,
        customRenderedHDR: Bool = false
    ) throws -> Data {
        let tiff = try buildTIFFData(from: exif, customRenderedHDR: customRenderedHDR)
        var app1 = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        app1.append(tiff)
        return app1
    }

    /// Builds an Apple ImageIO metadata dictionary (`kCGImagePropertyOrientation = 1`,
    /// `kCGImagePropertyTIFFDictionary`, `kCGImagePropertyExifDictionary`, optional
    /// `kCGImagePropertyGPSDictionary`) with strictly whitelisted tags and zero MakerNote.
    public static func buildImageIODictionary(
        from exif: WhitelistedExif,
        customRenderedHDR: Bool = false
    ) -> [CFString: Any] {
        var root: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
        ]

        var tiffDict: [CFString: Any] = [
            kCGImagePropertyTIFFOrientation: 1,
        ]
        if let mk = sanitizeString(exif.make) {
            tiffDict[kCGImagePropertyTIFFMake] = mk
        }
        if let md = sanitizeString(exif.model) {
            tiffDict[kCGImagePropertyTIFFModel] = md
        }
        let dto = sanitizeString(exif.dateTimeOriginal)
        if let dto {
            tiffDict[kCGImagePropertyTIFFDateTime] = dto
        }
        root[kCGImagePropertyTIFFDictionary] = tiffDict

        var exifDict: [CFString: Any] = [
            kCGImagePropertyExifVersion: [2, 3, 2],
        ]
        if let exp = exif.exposureTimeSeconds, exp.isFinite, exp > 0,
           exposureRational(exp) != nil {
            exifDict[kCGImagePropertyExifExposureTime] = exp
        }
        if let fn = exif.fNumber, fn.isFinite, fn > 0,
           positiveRational(fn, scale: 100) != nil {
            exifDict[kCGImagePropertyExifFNumber] = fn
        }
        if let iso = exif.isoSpeedRatings, iso > 0 {
            exifDict[kCGImagePropertyExifISOSpeedRatings] = [min(iso, Int(UInt16.max))]
            if iso > Int(UInt16.max) {
                exifDict[kCGImagePropertyExifSensitivityType] = 2
                exifDict[kCGImagePropertyExifRecommendedExposureIndex] = iso
            }
        }
        if let dto {
            exifDict[kCGImagePropertyExifDateTimeOriginal] = dto
        }
        if let offset = sanitizeString(exif.offsetTimeOriginal) {
            exifDict[kCGImagePropertyExifOffsetTimeOriginal] = offset
            if dto != nil {
                exifDict[kCGImagePropertyExifOffsetTime] = offset
            }
        }
        if let subsec = sanitizeString(exif.subSecTimeOriginal) {
            exifDict[kCGImagePropertyExifSubsecTimeOriginal] = subsec
        }
        if let bias = exif.exposureBiasEV, bias.isFinite {
            exifDict[kCGImagePropertyExifExposureBiasValue] = bias
        }
        if let fl = exif.focalLengthMM, fl.isFinite, fl > 0,
           positiveRational(fl, scale: 100) != nil {
            exifDict[kCGImagePropertyExifFocalLength] = fl
        }
        if let fl35 = exif.focalLengthIn35mmFilm, fl35 > 0 {
            exifDict[kCGImagePropertyExifFocalLenIn35mmFilm] = fl35
        }
        if let lm = sanitizeString(exif.lensMake) {
            exifDict[kCGImagePropertyExifLensMake] = lm
        }
        if let lmod = sanitizeString(exif.lensModel) {
            exifDict[kCGImagePropertyExifLensModel] = lmod
        }
        if let cr = resolveCustomRendered(exif: exif, customRenderedHDR: customRenderedHDR) {
            exifDict[kCGImagePropertyExifCustomRendered] = cr
        }
        root[kCGImagePropertyExifDictionary] = exifDict

        if let gps = normalizeGPS(exif) {
            var gpsDict: [CFString: Any] = [
                kCGImagePropertyGPSVersion: [2, 3, 0, 0],
                kCGImagePropertyGPSLatitudeRef: gps.latRef,
                kCGImagePropertyGPSLatitude: gps.latAbs,
                kCGImagePropertyGPSLongitudeRef: gps.lonRef,
                kCGImagePropertyGPSLongitude: gps.lonAbs,
            ]
            if let altAbs = gps.altAbs, let altRef = gps.altRef {
                gpsDict[kCGImagePropertyGPSAltitudeRef] = altRef
                gpsDict[kCGImagePropertyGPSAltitude] = altAbs
            }
            if let tsStr = gps.timestampString {
                gpsDict[kCGImagePropertyGPSTimeStamp] = tsStr
            }
            if let ds = gps.dateStamp {
                gpsDict[kCGImagePropertyGPSDateStamp] = ds
            }
            root[kCGImagePropertyGPSDictionary] = gpsDict
        }

        return root
    }

    // MARK: - Normalization Helpers

    private struct NormalizedGPS {
        let latAbs: Double
        let latRef: String
        let lonAbs: Double
        let lonRef: String
        let altAbs: Double?
        let altRef: Int?
        let timestampRationals: [(UInt32, UInt32)]?
        let timestampString: String?
        let dateStamp: String?
    }

    private static func normalizeGPS(_ exif: WhitelistedExif) -> NormalizedGPS? {
        guard let rawLat = exif.gpsLatitude,
              let rawLon = exif.gpsLongitude,
              rawLat.isFinite,
              rawLon.isFinite,
              abs(rawLat) <= 90.0,
              abs(rawLon) <= 180.0 else {
            return nil
        }

        let latRef: String
        if rawLat < 0 {
            latRef = "S"
        } else if let ref = sanitizeString(exif.gpsLatitudeRef)?.uppercased(), ref == "N" || ref == "S" {
            latRef = ref
        } else {
            latRef = "N"
        }

        let lonRef: String
        if rawLon < 0 {
            lonRef = "W"
        } else if let ref = sanitizeString(exif.gpsLongitudeRef)?.uppercased(), ref == "E" || ref == "W" {
            lonRef = ref
        } else {
            lonRef = "E"
        }

        var altAbs: Double?
        var altRef: Int?
        if let rawAlt = exif.gpsAltitude, rawAlt.isFinite {
            altAbs = abs(rawAlt)
            if rawAlt < 0 {
                altRef = 1
            } else {
                altRef = (exif.gpsAltitudeRef ?? 0) != 0 ? 1 : 0
            }
        }

        let tsParsed = parseGPSTimestamp(exif.gpsTimestamp)
        let dsParsed = parseGPSDateStamp(exif.gpsDateStamp)

        return NormalizedGPS(
            latAbs: abs(rawLat),
            latRef: latRef,
            lonAbs: abs(rawLon),
            lonRef: lonRef,
            altAbs: altAbs,
            altRef: altRef,
            timestampRationals: tsParsed?.rationals,
            timestampString: tsParsed?.formatted,
            dateStamp: dsParsed
        )
    }

    private static func parseGPSTimestamp(_ raw: String?) -> (rationals: [(UInt32, UInt32)], formatted: String)? {
        guard var s = sanitizeString(raw) else { return nil }
        if s.hasSuffix("Z") || s.hasSuffix("z") {
            s.removeLast()
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hh = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let mm = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              let ss = Double(parts[2].trimmingCharacters(in: .whitespaces)),
              (0...23).contains(hh),
              (0...59).contains(mm),
              ss.isFinite, ss >= 0.0, ss < 60.0 else {
            return nil
        }
        let secScaled = UInt32((ss * 100.0).rounded())
        let clampedSecScaled = min(secScaled, 5999)
        let rationals: [(UInt32, UInt32)] = [
            (UInt32(hh), 1),
            (UInt32(mm), 1),
            reduceUnsignedRational(clampedSecScaled, 100),
        ]
        let formatted = String(format: "%02d:%02d:%05.2f", hh, mm, Double(clampedSecScaled) / 100.0)
        return (rationals, formatted)
    }

    private static func parseGPSDateStamp(_ raw: String?) -> String? {
        guard let s = sanitizeString(raw) else { return nil }
        let normalized = s.replacingOccurrences(of: "-", with: ":")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, let yyyy = Int(parts[0]), (1900...2999).contains(yyyy),
              parts[1].count == 2, let mm = Int(parts[1]), (1...12).contains(mm),
              parts[2].count == 2, let dd = Int(parts[2]), (1...31).contains(dd) else {
            return nil
        }
        return String(format: "%04d:%02d:%02d", yyyy, mm, dd)
    }

    private static func resolveCustomRendered(exif: WhitelistedExif, customRenderedHDR: Bool) -> Int? {
        if customRenderedHDR || exif.customRendered == 3 {
            return 3
        }
        if let cr = exif.customRendered, (0...8).contains(cr) {
            return cr
        }
        return nil
    }

    private static func sanitizeString(_ raw: String?, maxBytes: Int = maxASCIIFieldBytes) -> String? {
        guard let raw else { return nil }
        // Strip embedded NUL bytes to avoid premature C-string truncation
        let noNul = raw.replacingOccurrences(of: "\0", with: "")
        let trimmed = noNul.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.utf8.count <= maxBytes {
            return trimmed
        }
        // Truncate safely on Character boundaries so UTF-8 never exceeds maxBytes
        var result = ""
        var byteCount = 0
        for ch in trimmed {
            let chBytes = String(ch).utf8.count
            if byteCount + chBytes > maxBytes {
                break
            }
            result.append(ch)
            byteCount += chBytes
        }
        let finalTrimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return finalTrimmed.isEmpty ? nil : finalTrimmed
    }

    // MARK: - Rational Math

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a
        var y = b
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return max(x, 1)
    }

    private static func reduceUnsignedRational(_ num: UInt32, _ den: UInt32) -> (UInt32, UInt32) {
        guard den != 0 else { return (0, 1) }
        if num == 0 { return (0, 1) }
        let g = gcd(UInt64(num), UInt64(den))
        return (UInt32(UInt64(num) / g), UInt32(UInt64(den) / g))
    }

    private static func exposureRational(_ value: Double) -> (UInt32, UInt32)? {
        guard value.isFinite, value > 0 else { return nil }
        if value < 1.0 {
            let inv = (1.0 / value).rounded()
            if inv >= 1.0, inv <= 1_000_000.0, abs(value - 1.0 / inv) / value < 1e-4 {
                return (1, UInt32(inv))
            }
            return positiveRational(value, scale: 1_000_000)
        }
        return positiveRational(value, scale: 100)
    }

    private static func positiveRational(
        _ value: Double,
        scale initialScale: UInt64,
        allowZero: Bool = false
    ) -> (UInt32, UInt32)? {
        guard value.isFinite else { return nil }
        if allowZero && abs(value) < 1e-9 {
            return (0, 1)
        }
        guard value > 0 else { return nil }

        var scale = initialScale
        while scale >= 1 {
            let scaled = (value * Double(scale)).rounded()
            if scaled >= 0, scaled <= Double(UInt32.max) {
                let n64 = UInt64(scaled)
                if !allowZero && n64 == 0 {
                    if scale == 1 { break }
                    scale /= 10
                    continue
                }
                let d64 = scale
                let g = gcd(n64, d64)
                let rn = n64 / g
                let rd = d64 / g
                if rn <= UInt64(UInt32.max), rd <= UInt64(UInt32.max), rd > 0 {
                    return (UInt32(rn), UInt32(rd))
                }
            }
            if scale == 1 { break }
            scale /= 10
        }
        return nil
    }

    private static func signedExposureBiasRational(_ value: Double) -> (Int32, Int32)? {
        guard value.isFinite else { return nil }
        if abs(value) < 1e-6 {
            return (0, 1)
        }
        // Check third-stop fractions (e.g. +1/3, -2/3 EV) first without disturbing decimal tenths (-0.7)
        let third = (value * 3.0).rounded()
        if abs(value - third / 3.0) < 1e-4, abs(third) <= Double(Int32.max) {
            let n = Int64(third)
            let g = Int64(gcd(UInt64(abs(n)), 3))
            return (Int32(n / g), Int32(3 / g))
        }
        let scaled = (value * 100.0).rounded()
        guard abs(scaled) <= Double(Int32.max) else { return nil }
        let n = Int64(scaled)
        let g = Int64(gcd(UInt64(abs(n)), 100))
        return (Int32(n / g), Int32(100 / g))
    }

    private static func decimalDegreesToDMS(_ absDeg: Double) -> [(UInt32, UInt32)] {
        let scale: UInt64 = 10_000
        let totalUnits = UInt64((absDeg * 3600.0 * Double(scale)).rounded())
        let secPerMin = UInt64(60) * scale
        let secPerDeg = UInt64(3600) * scale

        let deg = UInt32(totalUnits / secPerDeg)
        let remAfterDeg = totalUnits % secPerDeg
        let min = UInt32(remAfterDeg / secPerMin)
        let secScaled = UInt32(remAfterDeg % secPerMin)
        return [
            (deg, 1),
            (min, 1),
            reduceUnsignedRational(secScaled, UInt32(scale)),
        ]
    }

    // MARK: - TIFF Binary Serialization

    private enum TIFFEntryPayload {
        case inline4([UInt8])
        case outOfLine(Data)
    }

    private struct TIFFEntrySpec {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let payload: TIFFEntryPayload

        static func byte(tag: UInt16, value: UInt8) -> TIFFEntrySpec {
            TIFFEntrySpec(tag: tag, type: 1, count: 1, payload: .inline4([value, 0, 0, 0]))
        }

        static func bytesInline4(tag: UInt16, bytes: [UInt8]) -> TIFFEntrySpec {
            precondition(bytes.count == 4)
            return TIFFEntrySpec(tag: tag, type: 1, count: 4, payload: .inline4(bytes))
        }

        static func undefinedInline4(tag: UInt16, bytes: [UInt8]) -> TIFFEntrySpec {
            precondition(bytes.count == 4)
            return TIFFEntrySpec(tag: tag, type: 7, count: 4, payload: .inline4(bytes))
        }

        static func short(tag: UInt16, value: UInt16) -> TIFFEntrySpec {
            let b0 = UInt8(value & 0xFF)
            let b1 = UInt8((value >> 8) & 0xFF)
            return TIFFEntrySpec(tag: tag, type: 3, count: 1, payload: .inline4([b0, b1, 0, 0]))
        }

        static func long(tag: UInt16, value: UInt32) -> TIFFEntrySpec {
            let bytes = [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF),
            ]
            return TIFFEntrySpec(tag: tag, type: 4, count: 1, payload: .inline4(bytes))
        }

        static func ascii(tag: UInt16, string: String) -> TIFFEntrySpec {
            var bytes = Array(string.utf8)
            bytes.append(0)
            let count = UInt32(bytes.count)
            if bytes.count <= 4 {
                while bytes.count < 4 { bytes.append(0) }
                return TIFFEntrySpec(tag: tag, type: 2, count: count, payload: .inline4(bytes))
            }
            return TIFFEntrySpec(tag: tag, type: 2, count: count, payload: .outOfLine(Data(bytes)))
        }

        static func rational(tag: UInt16, values: [(UInt32, UInt32)]) -> TIFFEntrySpec {
            var data = Data(capacity: values.count * 8)
            for (n, d) in values {
                appendLE32(n, to: &data)
                appendLE32(d, to: &data)
            }
            return TIFFEntrySpec(tag: tag, type: 5, count: UInt32(values.count), payload: .outOfLine(data))
        }

        static func srational(tag: UInt16, values: [(Int32, Int32)]) -> TIFFEntrySpec {
            var data = Data(capacity: values.count * 8)
            for (n, d) in values {
                appendLE32(UInt32(bitPattern: n), to: &data)
                appendLE32(UInt32(bitPattern: d), to: &data)
            }
            return TIFFEntrySpec(tag: tag, type: 10, count: UInt32(values.count), payload: .outOfLine(data))
        }

        private static func appendLE32(_ v: UInt32, to data: inout Data) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
    }

    private static func validateSortedTags(_ entries: [TIFFEntrySpec], ifdName: String) throws {
        // Explicit safeguard: MakerNote (0x927C) must never be emitted
        for i in 0..<entries.count {
            if entries[i].tag == 0x927C {
                throw ExifWhitelistBuilderError.serializationFailed("Forbidden MakerNote tag in \(ifdName)")
            }
            if i > 0 && entries[i].tag <= entries[i - 1].tag {
                throw ExifWhitelistBuilderError.serializationFailed(
                    "Non-ascending TIFF tag order in \(ifdName): \(entries[i - 1].tag) followed by \(entries[i].tag)"
                )
            }
        }
    }

    private static func serializeIFD(entries: [TIFFEntrySpec], into out: inout Data) -> [UInt16: Int] {
        let ifdStart = out.count
        appendUInt16(UInt16(entries.count), to: &out)

        var valueSlotOffsets: [UInt16: Int] = [:]
        for entry in entries {
            appendUInt16(entry.tag, to: &out)
            appendUInt16(entry.type, to: &out)
            appendUInt32(entry.count, to: &out)
            let slotPos = out.count
            valueSlotOffsets[entry.tag] = slotPos
            switch entry.payload {
            case let .inline4(bytes):
                out.append(contentsOf: bytes)
            case .outOfLine:
                appendUInt32(0, to: &out) // placeholder offset, patched below
            }
        }

        // Next IFD offset = 0
        appendUInt32(0, to: &out)
        _ = ifdStart

        // Write out-of-line data with even-byte alignment and patch offsets
        for entry in entries {
            guard case let .outOfLine(payloadData) = entry.payload else { continue }
            padToEven(&out)
            let dataOffset = UInt32(out.count)
            out.append(payloadData)
            if let slotPos = valueSlotOffsets[entry.tag] {
                writeUInt32(dataOffset, at: slotPos, in: &out)
            }
        }

        return valueSlotOffsets
    }

    private static func padToEven(_ data: inout Data) {
        if data.count % 2 != 0 {
            data.append(0x00)
        }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }

    private static func writeUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { ptr in
            data.replaceSubrange(offset..<(offset + 4), with: ptr)
        }
    }
}
