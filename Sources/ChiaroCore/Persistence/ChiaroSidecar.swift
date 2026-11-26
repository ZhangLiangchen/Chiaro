import Darwin
import Foundation

public enum ChiaroSidecarError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case invalidTimestamp(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported Chiaro sidecar schemaVersion: \(version) (expected >= 1)."
        case .invalidTimestamp(let raw):
            return "Invalid ISO-8601 updatedAt timestamp in sidecar: '\(raw)'."
        case .writeFailed(let detail):
            return "Failed to write Chiaro sidecar atomically: \(detail)."
        }
    }
}

/// Non-destructive `.chiaro.json` sidecar (`schemaVersion = 2`, `ADR-014`).
/// Stored alongside RAW files at `<rawURL>.chiaro.json` (e.g., `DSC02532.ARW.chiaro.json`).
public struct ChiaroSidecar: Sendable, Codable, Equatable, Hashable {
    public static let currentSchemaVersion: Int = 2

    public var schemaVersion: Int
    public var appVersion: String
    public var updatedAt: Date
    public var presetID: String?
    public var decodeBackend: RAWBackend?
    public var demosaic: DemosaicAlgorithm?
    public var optics: OpticalCorrectionParameters?
    public var delta: PerPhotoDelta?
    public var denoise: DenoiseParameters?
    public var aiColor: AIColorGradingParameters?

    public static func currentTimestamp() -> Date {
        Date(timeIntervalSince1970: Double(Int64(Date().timeIntervalSince1970)))
    }

    public init(
        schemaVersion: Int = ChiaroSidecar.currentSchemaVersion,
        appVersion: String = "1.1.1",
        updatedAt: Date = ChiaroSidecar.currentTimestamp(),
        presetID: String? = nil,
        decodeBackend: RAWBackend? = nil,
        demosaic: DemosaicAlgorithm? = nil,
        optics: OpticalCorrectionParameters? = nil,
        delta: PerPhotoDelta? = nil,
        denoise: DenoiseParameters? = nil,
        aiColor: AIColorGradingParameters? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.updatedAt = updatedAt
        self.presetID = presetID
        self.decodeBackend = decodeBackend
        self.demosaic = demosaic
        self.optics = optics?.sanitized()
        self.delta = delta?.sanitized()
        self.denoise = denoise?.sanitized()
        self.aiColor = aiColor?.sanitized()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case appVersion
        case updatedAt
        case presetID
        case decodeBackend
        case demosaic
        case optics
        case delta
        case denoise
        case aiColor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        guard schemaVersion >= 1 else {
            throw ChiaroSidecarError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "1.1.1"

        if c.contains(.updatedAt) {
            if let timestampString = try? c.decode(String.self, forKey: .updatedAt) {
                guard let parsed = Self.parseISO8601Date(timestampString) else {
                    throw ChiaroSidecarError.invalidTimestamp(timestampString)
                }
                self.updatedAt = parsed
            } else if let decodedDate = try? c.decodeIfPresent(Date.self, forKey: .updatedAt) {
                self.updatedAt = decodedDate
            } else {
                self.updatedAt = Self.currentTimestamp()
            }
        } else {
            self.updatedAt = Self.currentTimestamp()
        }

        if let rawPresetID = try c.decodeIfPresent(String.self, forKey: .presetID) {
            let trimmed = rawPresetID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.presetID = trimmed.isEmpty ? nil : trimmed
        } else {
            self.presetID = nil
        }

        // Forward compatibility: incompatible future enum values or payload shapes in optional slots
        // degrade to nil instead of crashing sidecar loading (preserving user `delta` edits).
        do {
            self.decodeBackend = try c.decodeIfPresent(RAWBackend.self, forKey: .decodeBackend)
        } catch {
            self.decodeBackend = nil
        }

        do {
            self.demosaic = try c.decodeIfPresent(DemosaicAlgorithm.self, forKey: .demosaic)
        } catch {
            self.demosaic = nil
        }

        do {
            self.optics = try c.decodeIfPresent(OpticalCorrectionParameters.self, forKey: .optics)?.sanitized()
        } catch {
            self.optics = nil
        }

        do {
            self.delta = try c.decodeIfPresent(PerPhotoDelta.self, forKey: .delta)?.sanitized()
        } catch {
            self.delta = nil
        }

        do {
            self.denoise = try c.decodeIfPresent(DenoiseParameters.self, forKey: .denoise)?.sanitized()
        } catch {
            self.denoise = nil
        }

        do {
            self.aiColor = try c.decodeIfPresent(AIColorGradingParameters.self, forKey: .aiColor)?.sanitized()
        } catch {
            self.aiColor = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(Self.formatISO8601Date(updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(presetID, forKey: .presetID)
        try c.encodeIfPresent(decodeBackend, forKey: .decodeBackend)
        try c.encodeIfPresent(demosaic, forKey: .demosaic)
        try c.encodeIfPresent(optics?.sanitized(), forKey: .optics)
        try c.encodeIfPresent(delta?.sanitized(), forKey: .delta)
        try c.encodeIfPresent(denoise?.sanitized(), forKey: .denoise)
        try c.encode(aiColor?.sanitized(), forKey: .aiColor)
    }

    // MARK: - Path & Persistence Helpers

    /// Returns `<rawURL>.chiaro.json` (e.g., `/path/DSC02532.ARW` -> `/path/DSC02532.ARW.chiaro.json`).
    public static func sidecarURL(for rawURL: URL) -> URL {
        rawURL.appendingPathExtension("chiaro.json")
    }

    public static func exists(for rawURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: sidecarURL(for: rawURL).path)
    }

    public static func load(from sidecarURL: URL) throws -> ChiaroSidecar {
        let data = try Data(contentsOf: sidecarURL)
        return try JSONDecoder().decode(ChiaroSidecar.self, from: data)
    }

    public static func loadIfExists(for rawURL: URL) throws -> ChiaroSidecar? {
        let url = sidecarURL(for: rawURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try load(from: url)
    }

    /// Atomically writes `sidecar` to `sidecarURL` via a sibling `.chiaro_sidecar.<uuid>.tmp` file
    /// and POSIX `rename(2)` so concurrent writers are race-free with zero temp leftovers.
    public static func save(_ sidecar: ChiaroSidecar, to sidecarURL: URL) throws {
        let fm = FileManager.default
        let directory = sidecarURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)

        let tempURL = directory.appendingPathComponent(".chiaro_sidecar.\(UUID().uuidString).tmp")
        var tempMoved = false
        defer {
            if !tempMoved {
                try? fm.removeItem(at: tempURL)
            }
        }

        do {
            try data.write(to: tempURL)
            if Darwin.rename(tempURL.path, sidecarURL.path) != 0 {
                let reason = String(cString: Darwin.strerror(errno))
                throw ChiaroSidecarError.writeFailed("rename failed: \(reason) (errno \(errno))")
            }
            tempMoved = true
        } catch let error as ChiaroSidecarError {
            throw error
        } catch {
            throw ChiaroSidecarError.writeFailed(error.localizedDescription)
        }
    }

    public static func save(_ sidecar: ChiaroSidecar, for rawURL: URL) throws {
        try save(sidecar, to: sidecarURL(for: rawURL))
    }

    public static func delete(for rawURL: URL) throws {
        let url = sidecarURL(for: rawURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - ISO-8601 Helpers

    private static func parseISO8601Date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func formatISO8601Date(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        let hasSubseconds = abs(t - t.rounded()) > 1e-4
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = hasSubseconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
