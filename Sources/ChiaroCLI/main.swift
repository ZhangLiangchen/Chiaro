import Darwin
import Foundation
import ChiaroCore
import os

private final class NDJSONPrinter: Sendable {
    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())

    func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        lock.withLock {
            print(line)
            fflush(stdout)
        }
    }

    func logStderr(_ message: String) {
        lock.withLock {
            fputs(message + "\n", stderr)
            fflush(stderr)
        }
    }

    func logStdout(_ message: String) {
        lock.withLock {
            print(message)
            fflush(stdout)
        }
    }
}

@main
struct ChiaroCLIMain {
    static func main() async {
        let exitCode = await run(arguments: Array(CommandLine.arguments.dropFirst()))
        Foundation.exit(exitCode)
    }

    private static func run(arguments: [String]) async -> Int32 {
        let printer = NDJSONPrinter()

        let config: CLIConfig
        do {
            config = try CLIConfig.parse(arguments: arguments)
        } catch {
            printer.logStderr("Error: \(error)")
            return 1
        }

        if config.showHelp {
            print(CLIConfig.usageText)
            return 0
        }

        if config.listPresets {
            do {
                let presets = try PresetLoader.loadAllBuiltIn()
                for preset in presets {
                    let formats = preset.outputFormats.map(\.rawValue).joined(separator: ",")
                    print("\(preset.id)\t\(preset.name)\t[\(formats)]\t\(String(format: "%.2f", preset.targetHeadroomStops)) EV")
                }
                return 0
            } catch {
                printer.logStderr("Error loading built-in presets: \(error)")
                return 1
            }
        }

        // Load & validate preset BEFORE discovering/creating output directories
        var preset: PresetSchema
        do {
            if let presetFile = config.presetFilePath {
                let expanded = (presetFile as NSString).expandingTildeInPath
                preset = try PresetLoader.load(from: URL(fileURLWithPath: expanded))
            } else {
                preset = try PresetLoader.loadBuiltIn(id: config.presetID)
            }
        } catch {
            printer.logStderr("Error loading preset: \(error)")
            return 1
        }

        if let avifCodec = config.avifCodecOverride {
            preset.avifCodec = avifCodec
        }
        if config.customRenderedHDR {
            preset.compatOptions.writeCustomRenderedHDR = true
        }

        // Load & validate optional --delta-file BEFORE processing
        let deltaLookup: DeltaLookup?
        if let deltaPath = config.deltaFilePath {
            let expanded = (deltaPath as NSString).expandingTildeInPath
            do {
                deltaLookup = try DeltaLookup(from: URL(fileURLWithPath: expanded))
            } catch {
                printer.logStderr("Error loading --delta-file '\(deltaPath)': \(error)")
                return 1
            }
        } else {
            deltaLookup = nil
        }

        // Discover & deduplicate .ARW inputs
        let inputURLs: [URL]
        do {
            inputURLs = try InputDiscovery.discoverARWFiles(
                inputPaths: config.inputPaths,
                recursive: config.recursive
            )
        } catch {
            printer.logStderr("Error: \(error)")
            return 1
        }

        let expandedOutput = (config.outputPath as NSString).expandingTildeInPath
        let outputDir = URL(fileURLWithPath: expandedOutput, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            printer.logStderr("Error creating output directory '\(outputDir.path)': \(error)")
            return 1
        }

        let decodeOptions = DecodeOptions(
            backend: config.backend,
            highlightMode: preset.developDefaults.highlightReconstruction,
            isProxy: false,
            maxThreadsPerWorker: 2,
            customRenderedHDR: config.customRenderedHDR || preset.compatOptions.writeCustomRenderedHDR
        )

        let jobs = inputURLs.map { inputURL in
            ExportJob(
                inputURL: inputURL,
                outputDirectory: outputDir,
                preset: preset,
                formatOverrides: config.formatOverrides,
                delta: deltaLookup?.delta(for: inputURL),
                decodeOptions: decodeOptions,
                namingTemplate: config.namingTemplate,
                useFormatSubdirectories: config.useFormatSubdirectories,
                conflictPolicy: config.conflictPolicy,
                verifyAfterExport: config.verifyAfterExport
            )
        }

        let pipeline = BoundedBatchPipeline()
        let jsonProgress = config.jsonProgress

        let results: [ExportResult]
        do {
            results = try await pipeline.run(jobs: jobs) { event in
                handleProgressEvent(event, jsonProgress: jsonProgress, printer: printer)
            }
        } catch {
            printer.logStderr("Batch pipeline failed: \(error)")
            return 1
        }

        let failedResults = results.filter { $0.errorDescription != nil }
        if !failedResults.isEmpty {
            for failed in failedResults {
                printer.logStderr("Failed [\(failed.sourceURL.lastPathComponent)]: \(failed.errorDescription ?? "unknown error")")
            }
            return 1
        }

        return 0
    }

    private static func handleProgressEvent(
        _ event: BatchProgressEvent,
        jsonProgress: Bool,
        printer: NDJSONPrinter
    ) {
        if jsonProgress {
            switch event {
            case let .batchStarted(totalJobs, presetID, formats):
                printer.emit([
                    "event": "batch_start",
                    "totalJobs": totalJobs,
                    "preset": presetID,
                    "formats": formats.map { OutputPathCoordinator.formatSubdirectoryName(for: $0) },
                ])

            case let .jobStarted(jobID, sourceURL):
                printer.emit([
                    "event": "job_started",
                    "jobID": jobID.uuidString,
                    "source": sourceURL.path,
                    "filename": sourceURL.lastPathComponent,
                ])

            case let .jobDecoded(jobID, sourceURL, backendUsed, fallbackReason):
                var payload: [String: Any] = [
                    "event": "job_decoded",
                    "jobID": jobID.uuidString,
                    "source": sourceURL.path,
                    "filename": sourceURL.lastPathComponent,
                    "backend": backendUsed.rawValue,
                ]
                if let fallbackReason {
                    payload["fallbackReason"] = fallbackReason
                }
                printer.emit(payload)

            case let .jobRendered(jobID, sourceURL):
                printer.emit([
                    "event": "job_rendered",
                    "jobID": jobID.uuidString,
                    "source": sourceURL.path,
                    "filename": sourceURL.lastPathComponent,
                ])

            case let .jobCompleted(result):
                let artifactObjs: [[String: Any]] = result.artifacts.map { artifact in
                    var obj: [String: Any] = [
                        "format": OutputPathCoordinator.formatSubdirectoryName(for: artifact.format),
                        "path": artifact.outputURL.path,
                        "fileSizeBytes": artifact.fileSizeBytes,
                        "usedGridTiling": artifact.usedGridTiling,
                    ]
                    if let compliance = artifact.compliance {
                        obj["verified"] = true
                        obj["compliancePassed"] = compliance.passed
                        if let hr = compliance.measuredHeadroom {
                            obj["measuredHeadroom"] = hr.multiplier
                        }
                    } else {
                        obj["verified"] = false
                    }
                    return obj
                }
                var payload: [String: Any] = [
                    "event": result.errorDescription == nil ? "job_completed" : "job_failed",
                    "jobID": result.jobID.uuidString,
                    "source": result.sourceURL.path,
                    "filename": result.sourceURL.lastPathComponent,
                    "backend": result.backendUsed.rawValue,
                    "elapsedSeconds": result.elapsedSeconds,
                    "artifacts": artifactObjs,
                ]
                if let fallback = result.fallbackReason {
                    payload["fallbackReason"] = fallback
                }
                if let err = result.errorDescription {
                    payload["error"] = err
                }
                printer.emit(payload)

            case let .batchCompleted(totalJobs, succeeded, failed, elapsedSeconds):
                printer.emit([
                    "event": "batch_summary",
                    "totalJobs": totalJobs,
                    "succeeded": succeeded,
                    "failed": failed,
                    "elapsedSeconds": elapsedSeconds,
                ])
            }
        } else {
            switch event {
            case let .jobCompleted(result):
                let name = result.sourceURL.lastPathComponent
                if let err = result.errorDescription {
                    printer.logStderr("[FAIL] \(name): \(err)")
                } else {
                    let outputs = result.artifacts.map(\.outputURL.lastPathComponent).joined(separator: ", ")
                    let elapsedStr = String(format: "%.2fs", result.elapsedSeconds)
                    printer.logStdout("[OK] \(name) -> [\(outputs)] (\(elapsedStr))")
                }
            case let .batchCompleted(totalJobs, succeeded, failed, elapsedSeconds):
                let elapsedStr = String(format: "%.2fs", elapsedSeconds)
                printer.logStdout("Done: \(succeeded)/\(totalJobs) succeeded, \(failed) failed in \(elapsedStr).")
            default:
                break
            }
        }
    }
}
