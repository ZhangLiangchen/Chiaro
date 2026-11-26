import Foundation
import ChiaroCore

enum CLIParseError: Error, CustomStringConvertible {
    case missingValue(String)
    case unexpectedValue(flag: String, value: String)
    case unknownFlag(String)
    case invalidFormat(String)
    case emptyFormats
    case invalidBackend(String)
    case invalidAVIFCodec(String)
    case invalidConflictPolicy(String)
    case emptyOutputPath
    case emptyNamingTemplate
    case emptyOptionValue(flag: String)
    case missingInputs
    case inputNotFound(String)
    case noARWInputsFound
    case invalidDemosaic(String)
    case invalidDenoiseMode(String)
    case invalidLensCorrection(String)
    case invalidOnOffFlag(flag: String, value: String)
    case invalidToneMapper(String)
    case invalidNumericRange(flag: String, value: String, min: Double, max: Double)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value for flag \(flag)."
        case .unexpectedValue(let flag, let value):
            return "Option \(flag) does not accept a value (got '\(value)')."
        case .unknownFlag(let flag):
            return "Unknown option: \(flag). Use --help for usage."
        case .invalidFormat(let value):
            return "Unsupported output format '\(value)'. Valid values: heic, jpeg, avif, mp4."
        case .emptyFormats:
            return "--formats requires at least one format (heic, jpeg, avif, mp4)."
        case .invalidBackend(let value):
            return "Invalid --backend '\(value)'. Valid values: libraw, ciraw9."
        case .invalidAVIFCodec(let value):
            return "Invalid --avif-codec '\(value)'. Valid values: svt-av1, libaom."
        case .invalidConflictPolicy(let value):
            return "Invalid --on-conflict '\(value)'. Valid values: overwrite, skip, auto-number."
        case .emptyOutputPath:
            return "--output path cannot be empty."
        case .emptyNamingTemplate:
            return "--naming template must not be empty."
        case .emptyOptionValue(let flag):
            return "Option \(flag) cannot be empty."
        case .missingInputs:
            return "No input files or directories provided. Use --help for usage."
        case .inputNotFound(let path):
            return "Input path does not exist: \(path)"
        case .noARWInputsFound:
            return "No .ARW files found in the specified input paths."
        case .invalidDemosaic(let value):
            return "Invalid --demosaic '\(value)'. Valid values: amaze, lmmse, dcb, dht, ahd."
        case .invalidDenoiseMode(let value):
            return "Invalid --denoise '\(value)'. Valid values: auto, off."
        case .invalidLensCorrection(let value):
            return "Invalid --lens-correction '\(value)'. Valid values: auto, embedded, lensfun, off."
        case .invalidOnOffFlag(let flag, let value):
            return "Invalid \(flag) '\(value)'. Valid values: on, off."
        case .invalidToneMapper(let value):
            return "Invalid --tone-mapper '\(value)'. Valid values: agx, sigmoid, neutral, opendrt."
        case .invalidNumericRange(let flag, let value, let min, let max):
            return "Invalid \(flag) '\(value)'. Must be a finite number in [\(min), \(max)]."
        }
    }
}

struct CLIConfig: Sendable {
    var inputPaths: [String] = []
    var outputPath: String = "."
    var presetID: String = BuiltInPresetID.appleHEIC.rawValue
    var presetFilePath: String?
    var formatOverrides: [OutputFormat]?
    var backend: RAWBackend = .libraw
    var avifCodecOverride: AVIFCodecChoice?
    var deltaFilePath: String?
    var recursive: Bool = false
    var useFormatSubdirectories: Bool = false
    var namingTemplate: String = "{name}_HDR.{ext}"
    var conflictPolicy: ConflictPolicy = .overwrite
    var customRenderedHDR: Bool = false
    var verifyAfterExport: Bool = true
    var useSidecar: Bool = true
    var cliOverrides: CLIDevelopOverrides = CLIDevelopOverrides()
    var jsonProgress: Bool = false
    var listPresets: Bool = false
    var showHelp: Bool = false

    static let usageText = """
    chiaro-cli — Chiaro v1.1 Batch Sony ARW -> ISO 21496-1 HDR & Douyin HLG Pipeline

    USAGE:
      chiaro-cli [inputs...] [options]

    INPUTS:
      [inputs...]                  One or more .ARW files or directories containing .ARW files
      -i, --input <path>           Additional input file or directory (repeatable)
      -r, --recursive              Scan input directories recursively for .ARW files

    OUTPUT & PRESET OPTIONS:
      -o, --output <dir>           Output directory (default: current directory '.')
      -p, --preset <id>            Built-in preset ID (default: apple_heic)
      --preset-file <path>         Load custom PresetSchema JSON file
      --formats <list>             Override output formats: heic,jpeg,avif,mp4
      --format-subdirs             Place outputs in <output>/<heic|jpeg|avif|mp4>/
      --naming <template>          Filename template (default: {name}_HDR.{ext})
                                   Placeholders: {name}, {ext}, {preset}, {format}
      --on-conflict <policy>       overwrite (default), skip, or auto-number

    DECODE, DEVELOP & OPTICS OPTIONS:
      --backend <name>             libraw (default) or ciraw9
      --demosaic <name>            amaze (default), lmmse, dcb, dht, ahd
      --denoise <mode>             auto (profiled wavelet) or off
      --denoise-luma <0..100>      Luminance denoise strength (0...100)
      --denoise-chroma <0..100>    Chroma denoise strength (0...100)
      --lens-correction <mode>     auto (default), embedded, lensfun, off
      --lens-distortion <on|off>   Enable/disable distortion correction
      --lens-tca <on|off>          Enable/disable transverse chromatic aberration correction
      --lens-vignetting <on|off>   Enable/disable vignetting compensation
      --lens-vignetting-strength <0..100>
                                   Vignetting compensation strength (0...100)
      --tone-mapper <name>         agx, sigmoid, neutral, opendrt
      --clarity <-100..100>        Edge-aware local contrast (-100...100)
      --sharpness <0..100>         Physical inverse-diffusion optical sharpness (0...100)
      --use-sidecar / --no-sidecar Read per-photo <raw>.chiaro.json sidecar (default: --use-sidecar)

    ENCODE & VERIFY OPTIONS:
      --avif-codec <name>          svt-av1 or libaom
      --delta-file <path>          JSON file mapping filename or stem to PerPhotoDelta
      --custom-rendered-hdr        Write EXIF CustomRendered = 3 (HDR)
      --verify / --no-verify       Run post-export ISO21496Probe / HLGVideoProbe (default: --verify)
      --json-progress              Emit NDJSON progress events to stdout

    DISCOVERY:
      --list-presets               List all 7 built-in presets and exit
      -h, --help                   Show this help message and exit
    """

    static func parse(arguments: [String]) throws -> CLIConfig {
        var config = CLIConfig()
        var idx = 0

        func readValue(for flag: String, inlineValue: String?) throws -> String {
            if let inlineValue {
                return inlineValue
            }
            idx += 1
            guard idx < arguments.count else {
                throw CLIParseError.missingValue(flag)
            }
            return arguments[idx]
        }

        func readNonEmptyValue(for flag: String, inlineValue: String?) throws -> String {
            let value = try readValue(for: flag, inlineValue: inlineValue)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIParseError.emptyOptionValue(flag: flag)
            }
            return value
        }

        func rejectInlineValueIfPresent(flag: String, inlineValue: String?) throws {
            if let inlineValue {
                throw CLIParseError.unexpectedValue(flag: flag, value: inlineValue)
            }
        }

        while idx < arguments.count {
            let arg = arguments[idx]

            let flag: String
            let inlineValue: String?
            if arg.hasPrefix("--"), let eqIdx = arg.firstIndex(of: "=") {
                flag = String(arg[..<eqIdx])
                inlineValue = String(arg[arg.index(after: eqIdx)...])
            } else {
                flag = arg
                inlineValue = nil
            }

            switch flag {
            case "-h", "--help":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.showHelp = true
            case "--list-presets":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.listPresets = true
            case "-r", "--recursive":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.recursive = true
            case "--format-subdirs":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.useFormatSubdirectories = true
            case "--custom-rendered-hdr":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.customRenderedHDR = true
            case "--verify":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.verifyAfterExport = true
            case "--no-verify":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.verifyAfterExport = false
            case "--use-sidecar":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.useSidecar = true
            case "--no-sidecar":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.useSidecar = false
            case "--json-progress":
                try rejectInlineValueIfPresent(flag: flag, inlineValue: inlineValue)
                config.jsonProgress = true

            case "-i", "--input":
                config.inputPaths.append(try readNonEmptyValue(for: flag, inlineValue: inlineValue))
            case "-o", "--output":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                guard !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIParseError.emptyOutputPath
                }
                config.outputPath = val
            case "-p", "--preset":
                config.presetID = try readNonEmptyValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.presetExplicitlySpecified = true
            case "--preset-file":
                config.presetFilePath = try readNonEmptyValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.presetExplicitlySpecified = true
            case "--formats":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.formatOverrides = try parseFormats(val)
            case "--backend":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                let parsedBackend = try parseBackend(val)
                config.backend = parsedBackend
                config.cliOverrides.backend = parsedBackend
            case "--demosaic":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.demosaic = try parseDemosaic(val)
            case "--denoise":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.denoiseMode = try parseDenoiseMode(val)
            case "--denoise-chroma":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.denoiseChroma = try parseBoundedDouble(val, flag: flag, range: 0.0...100.0)
            case "--denoise-luma":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.denoiseLuma = try parseBoundedDouble(val, flag: flag, range: 0.0...100.0)
            case "--lens-correction":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                let (enabled, source) = try parseLensCorrection(val)
                config.cliOverrides.lensCorrectionEnabled = enabled
                config.cliOverrides.lensSource = source
            case "--lens-distortion":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.lensDistortion = try parseOnOff(val, flag: flag)
            case "--lens-tca":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.lensTCA = try parseOnOff(val, flag: flag)
            case "--lens-vignetting":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.lensVignetting = try parseOnOff(val, flag: flag)
            case "--lens-vignetting-strength":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                let pct = try parseBoundedDouble(val, flag: flag, range: 0.0...100.0)
                config.cliOverrides.lensVignettingStrength = pct / 100.0
            case "--tone-mapper":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.toneMapper = try parseToneMapper(val)
            case "--clarity":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.clarity = try parseBoundedDouble(val, flag: flag, range: -100.0...100.0)
            case "--sharpness":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.cliOverrides.opticalSharpness = try parseBoundedDouble(val, flag: flag, range: 0.0...100.0)
            case "--avif-codec":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.avifCodecOverride = try parseAVIFCodec(val)
            case "--delta-file":
                config.deltaFilePath = try readNonEmptyValue(for: flag, inlineValue: inlineValue)
            case "--naming":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                guard !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIParseError.emptyNamingTemplate
                }
                config.namingTemplate = val
            case "--on-conflict":
                let val = try readValue(for: flag, inlineValue: inlineValue)
                config.conflictPolicy = try parseConflictPolicy(val)

            default:
                if arg.hasPrefix("-") && arg != "-" {
                    throw CLIParseError.unknownFlag(arg)
                }
                config.inputPaths.append(arg)
            }

            idx += 1
        }

        return config
    }

    static func parseFormats(_ raw: String) throws -> [OutputFormat] {
        let tokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            throw CLIParseError.emptyFormats
        }

        var result: [OutputFormat] = []
        var seen: Set<OutputFormat> = []
        for token in tokens {
            let fmt: OutputFormat
            switch token {
            case "heic":
                fmt = .heic
            case "jpeg", "jpg":
                fmt = .jpeg
            case "avif":
                fmt = .avif
            case "mp4", "hlgmp4", "hlg-mp4":
                fmt = .hlgMP4
            default:
                throw CLIParseError.invalidFormat(token)
            }
            if !seen.contains(fmt) {
                seen.insert(fmt)
                result.append(fmt)
            }
        }
        return result
    }

    static func parseBackend(_ raw: String) throws -> RAWBackend {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "libraw":
            return .libraw
        case "ciraw9":
            return .ciraw9
        default:
            throw CLIParseError.invalidBackend(raw)
        }
    }

    static func parseDemosaic(_ raw: String) throws -> DemosaicAlgorithm {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "amaze":
            return .amaze
        case "lmmse":
            return .lmmse
        case "dcb":
            return .dcb
        case "dht":
            return .dht
        case "ahd":
            return .ahd
        default:
            throw CLIParseError.invalidDemosaic(raw)
        }
    }

    static func parseDenoiseMode(_ raw: String) throws -> DenoiseEngineMode {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            return .profiledWavelet
        case "off":
            return .off
        default:
            throw CLIParseError.invalidDenoiseMode(raw)
        }
    }

    static func parseLensCorrection(_ raw: String) throws -> (enabled: Bool, source: OpticalProfileSource?) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            return (true, .auto)
        case "embedded":
            return (true, .embedded)
        case "lensfun":
            return (true, .lensfun)
        case "off":
            return (false, nil)
        default:
            throw CLIParseError.invalidLensCorrection(raw)
        }
    }

    static func parseOnOff(_ raw: String, flag: String) throws -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on":
            return true
        case "off":
            return false
        default:
            throw CLIParseError.invalidOnOffFlag(flag: flag, value: raw)
        }
    }

    static func parseToneMapper(_ raw: String) throws -> SDRToneMapper {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "agx":
            return .agx
        case "sigmoid":
            return .sigmoid
        case "neutral", "neutralrational", "neutral-rational":
            return .neutralRational
        case "opendrt", "open-drt":
            return .openDRT
        default:
            throw CLIParseError.invalidToneMapper(raw)
        }
    }

    static func parseBoundedDouble(
        _ raw: String,
        flag: String,
        range: ClosedRange<Double>
    ) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let val = Double(trimmed),
              val.isFinite,
              range.contains(val) else {
            throw CLIParseError.invalidNumericRange(
                flag: flag,
                value: raw,
                min: range.lowerBound,
                max: range.upperBound
            )
        }
        return val
    }

    static func parseAVIFCodec(_ raw: String) throws -> AVIFCodecChoice {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "svt-av1", "svtav1":
            return .svtAV1
        case "libaom", "aom":
            return .libaom
        default:
            throw CLIParseError.invalidAVIFCodec(raw)
        }
    }

    static func parseConflictPolicy(_ raw: String) throws -> ConflictPolicy {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "overwrite":
            return .overwrite
        case "skip":
            return .skip
        case "auto-number", "autonumber":
            return .autoNumber
        default:
            throw CLIParseError.invalidConflictPolicy(raw)
        }
    }
}

enum InputDiscovery {
    static func discoverARWFiles(
        inputPaths: [String],
        recursive: Bool
    ) throws -> [URL] {
        guard !inputPaths.isEmpty else {
            throw CLIParseError.missingInputs
        }

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

        for rawPath in inputPaths {
            let expandedPath = (rawPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expandedPath, isDirectory: &isDir) else {
                throw CLIParseError.inputNotFound(rawPath)
            }

            let url = URL(fileURLWithPath: expandedPath, isDirectory: isDir.boolValue)
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
                    let resolvedItem = itemURL.resolvingSymlinksInPath()
                    guard resolvedItem.pathExtension.lowercased() == "arw" else { continue }
                    var itemIsDir: ObjCBool = false
                    if fm.fileExists(atPath: resolvedItem.path, isDirectory: &itemIsDir), !itemIsDir.boolValue {
                        dirFiles.append(itemURL)
                    }
                }
                dirFiles.sort { $0.path < $1.path }
                for fileURL in dirFiles {
                    appendIfARW(fileURL)
                }
            } else {
                let contents = try fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for itemURL in contents {
                    var itemIsDir: ObjCBool = false
                    if fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir), !itemIsDir.boolValue {
                        appendIfARW(itemURL)
                    }
                }
            }
        }

        guard !discovered.isEmpty else {
            throw CLIParseError.noARWInputsFound
        }
        return discovered
    }
}

struct DeltaLookup: Sendable {
    private let exactMap: [String: PerPhotoDelta]
    private let lowercaseMap: [String: PerPhotoDelta]

    init(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([String: PerPhotoDelta].self, from: data)
        self.exactMap = decoded
        var lower: [String: PerPhotoDelta] = [:]
        for (k, v) in decoded {
            lower[k.lowercased()] = v
        }
        self.lowercaseMap = lower
    }

    func delta(for inputURL: URL) -> PerPhotoDelta? {
        let filename = inputURL.lastPathComponent
        let stem = inputURL.deletingPathExtension().lastPathComponent
        if let hit = exactMap[filename] ?? exactMap[stem] {
            return hit
        }
        return lowercaseMap[filename.lowercased()] ?? lowercaseMap[stem.lowercased()]
    }
}
