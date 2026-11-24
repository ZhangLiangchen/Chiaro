import Foundation
import ChiaroCore

public enum ARWFileDiscovery {
    public static func parseLaunchURLs(arguments: [String]) -> [URL] {
        var candidateURLs: [URL] = []
        let fm = FileManager.default
        let dropped = Array(arguments.dropFirst())
        var index = 0

        while index < dropped.count {
            let arg = dropped[index]
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") || arg.hasPrefix("-psn_") {
                if !arg.hasPrefix("-psn_") && !arg.contains("="), index + 1 < dropped.count {
                    let next = dropped[index + 1]
                    let expandedNext = (next as NSString).expandingTildeInPath
                    let nextLooksLikePathOrFlag = next.hasPrefix("/")
                        || next.hasPrefix("~")
                        || next.hasPrefix("-NS")
                        || next.hasPrefix("-Apple")
                        || next.hasPrefix("-psn_")
                        || fm.fileExists(atPath: expandedNext)
                    if !nextLooksLikePathOrFlag {
                        // AppKit/Foundation debug arguments often take a single value token (e.g. YES / NO)
                        index += 2
                        continue
                    }
                }
                index += 1
                continue
            }
            let expanded = (arg as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if fm.fileExists(atPath: url.path) {
                candidateURLs.append(url)
            }
            index += 1
        }
        return discover(urls: candidateURLs, recursive: true)
    }

    public static func discover(urls: [URL], recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var seenCanonicalPaths: Set<String> = []
        var discovered: [URL] = []

        func appendIfARW(_ url: URL) {
            guard url.pathExtension.lowercased() == "arw" else { return }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedURL.pathExtension.lowercased() == "arw" else { return }
            var resolvedIsDir: ObjCBool = false
            guard fm.fileExists(atPath: resolvedURL.path, isDirectory: &resolvedIsDir),
                  !resolvedIsDir.boolValue else {
                return
            }
            let canonical = resolvedURL.path
            guard !seenCanonicalPaths.contains(canonical) else { return }
            seenCanonicalPaths.insert(canonical)
            discovered.append(URL(fileURLWithPath: canonical, isDirectory: false))
        }

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                appendIfARW(url)
                continue
            }

            if recursive {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                var dirFiles: [URL] = []
                for case let itemURL as URL in enumerator {
                    guard itemURL.pathExtension.lowercased() == "arw" else { continue }
                    let resolvedItem = itemURL.resolvingSymlinksInPath().standardizedFileURL
                    guard resolvedItem.pathExtension.lowercased() == "arw" else { continue }
                    var itemIsDir: ObjCBool = false
                    if fm.fileExists(atPath: resolvedItem.path, isDirectory: &itemIsDir), !itemIsDir.boolValue {
                        dirFiles.append(itemURL)
                    }
                }
                dirFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for fileURL in dirFiles {
                    appendIfARW(fileURL)
                }
            } else {
                let contents = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                let sorted = contents.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                for itemURL in sorted {
                    var itemIsDir: ObjCBool = false
                    if fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir), !itemIsDir.boolValue {
                        appendIfARW(itemURL)
                    }
                }
            }
        }
        return discovered
    }
}

public enum DeltaJSONCodec {
    public static func loadMap(from url: URL) throws -> [String: PerPhotoDelta] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: PerPhotoDelta].self, from: data)
    }

    public static func saveMap(_ map: [String: PerPhotoDelta], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: url, options: .atomic)
    }

    public static func matchDelta(in map: [String: PerPhotoDelta], for fileURL: URL) -> PerPhotoDelta? {
        let filename = fileURL.lastPathComponent
        let stem = fileURL.deletingPathExtension().lastPathComponent
        if let exact = map[filename] ?? map[stem] {
            return exact
        }
        let lowerFilename = filename.lowercased()
        let lowerStem = stem.lowercased()
        for (key, value) in map {
            let lowerKey = key.lowercased()
            if lowerKey == lowerFilename || lowerKey == lowerStem {
                return value
            }
        }
        return nil
    }
}

public enum PresetJSONCodec {
    public static func importPreset(from url: URL) throws -> PresetSchema {
        try PresetLoader.load(from: url)
    }

    public static func exportPreset(_ preset: PresetSchema, to url: URL) throws {
        try PresetLoader.validate(preset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        try data.write(to: url, options: .atomic)
    }
}
