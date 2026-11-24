import Foundation
import os

public enum OutputPathCoordinatorError: Error, Sendable, Equatable, CustomStringConvertible {
    case intraBatchPathCollision(URL)

    public var description: String {
        switch self {
        case .intraBatchPathCollision(let url):
            return "Intra-batch output path collision at '\(url.path)' under --on-conflict overwrite; use --on-conflict auto-number, --on-conflict skip, or a unique --naming template."
        }
    }
}

public enum OutputPathResolution: Sendable, Equatable {
    case write(URL)
    case skip(URL)
}

/// Thread-safe output path resolver and reservation tracker for Stage 3 encoder fan-out.
/// Ensures `--format-subdirs`, `--naming` templates, and `--on-conflict` (`overwrite`, `skip`,
/// `autoNumber`) never collide across concurrent export jobs.
public final class OutputPathCoordinator: Sendable {
    private let reservedPaths = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    public init() {}

    public static func formatSubdirectoryName(for format: OutputFormat) -> String {
        switch format {
        case .heic: return "heic"
        case .jpeg: return "jpeg"
        case .avif: return "avif"
        case .hlgMP4: return "mp4"
        }
    }

    public static func renderFilename(
        template: String,
        inputURL: URL,
        presetID: String,
        format: OutputFormat
    ) -> String {
        let rawStem = inputURL.deletingPathExtension().lastPathComponent
        let stem = sanitizeComponent(rawStem.isEmpty ? "output" : rawStem)
        let presetToken = sanitizeComponent(presetID.isEmpty ? "preset" : presetID)
        let formatToken = formatSubdirectoryName(for: format)
        let ext = format.fileExtension

        let effectiveTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "{name}_HDR.{ext}"
            : template

        let hasExtPlaceholder = effectiveTemplate.contains("{ext}")
        var rendered = effectiveTemplate
            .replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{ext}", with: ext)
            .replacingOccurrences(of: "{preset}", with: presetToken)
            .replacingOccurrences(of: "{format}", with: formatToken)

        rendered = rendered.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        if !hasExtPlaceholder && !rendered.lowercased().hasSuffix(".\(ext.lowercased())") {
            rendered += ".\(ext)"
        }
        return rendered
    }

    public func resolveAndReserve(
        job: ExportJob,
        format: OutputFormat
    ) throws -> OutputPathResolution {
        let baseDir: URL
        if job.useFormatSubdirectories {
            baseDir = job.outputDirectory.appendingPathComponent(
                Self.formatSubdirectoryName(for: format),
                isDirectory: true
            )
        } else {
            baseDir = job.outputDirectory
        }

        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let isCaseSensitive = Self.isVolumeCaseSensitive(for: baseDir)
        let fileName = Self.renderFilename(
            template: job.namingTemplate,
            inputURL: job.inputURL,
            presetID: job.preset.id,
            format: format
        )
        let candidateURL = baseDir.appendingPathComponent(fileName, isDirectory: false)
        let candidateKey = Self.reservationKey(for: candidateURL, caseSensitive: isCaseSensitive)

        return try reservedPaths.withLock { reserved in
            let fm = FileManager.default
            switch job.conflictPolicy {
            case .overwrite:
                if reserved.contains(candidateKey) {
                    throw OutputPathCoordinatorError.intraBatchPathCollision(candidateURL)
                }
                reserved.insert(candidateKey)
                return .write(candidateURL)

            case .skip:
                if fm.fileExists(atPath: candidateURL.path) || reserved.contains(candidateKey) {
                    return .skip(candidateURL)
                }
                reserved.insert(candidateKey)
                return .write(candidateURL)

            case .autoNumber:
                if !fm.fileExists(atPath: candidateURL.path) && !reserved.contains(candidateKey) {
                    reserved.insert(candidateKey)
                    return .write(candidateURL)
                }

                let ext = candidateURL.pathExtension
                let stem = candidateURL.deletingPathExtension().lastPathComponent
                var index = 1
                while true {
                    let numberedName = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
                    let numberedURL = baseDir.appendingPathComponent(numberedName, isDirectory: false)
                    let key = Self.reservationKey(for: numberedURL, caseSensitive: isCaseSensitive)
                    if !fm.fileExists(atPath: numberedURL.path) && !reserved.contains(key) {
                        reserved.insert(key)
                        return .write(numberedURL)
                    }
                    index += 1
                }
            }
        }
    }

    private static func isVolumeCaseSensitive(for directory: URL) -> Bool {
        var current = directory.standardizedFileURL
        let fm = FileManager.default
        while !fm.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return (try? current.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
    }

    private static func reservationKey(for url: URL, caseSensitive: Bool) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return caseSensitive ? path : path.lowercased()
    }

    private static func sanitizeComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
