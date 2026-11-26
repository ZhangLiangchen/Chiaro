import Foundation
import os
import Testing
@testable import ChiaroCore

private let m4RepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ChiaroCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // Chiaro

private func makeM4TempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func findM4CLIBinary() -> URL? {
    if let envPath = ProcessInfo.processInfo.environment["CHIARO_CLI_BIN"],
       FileManager.default.isExecutableFile(atPath: envPath) {
        return URL(fileURLWithPath: envPath)
    }
    let candidates = [
        ".build/out/Products/Debug/chiaro-cli",
        ".build/debug/chiaro-cli",
        ".build/arm64-apple-macosx/debug/chiaro-cli",
        ".build/out/Products/Release/chiaro-cli",
        ".build/release/chiaro-cli",
        ".build/arm64-apple-macosx/release/chiaro-cli",
    ]
    for rel in candidates {
        let candidate = m4RepoRoot.appendingPathComponent(rel)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func runM4CLI(
    _ executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil
) throws -> (status: Int32, stdout: String, stderr: String) {
    let proc = Process()
    proc.executableURL = executableURL
    proc.arguments = arguments
    if let currentDirectoryURL {
        proc.currentDirectoryURL = currentDirectoryURL
    }
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    try proc.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (
        proc.terminationStatus,
        String(decoding: outData, as: UTF8.self),
        String(decoding: errData, as: UTF8.self)
    )
}

extension ChiaroSerializedSuites {

@Suite("SidecarAndCLITests", .serialized)
struct SidecarAndCLITests {

    @Test
    func testExportJobLegacyJSONDecodingAndV11FieldsRoundTrip() throws {
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let inputURL = URL(fileURLWithPath: "/tmp/input/DSC02532.ARW")
        let outputDir = URL(fileURLWithPath: "/tmp/output", isDirectory: true)

        let legacyPayload: [String: Any] = [
            "id": UUID().uuidString,
            "inputURL": inputURL.absoluteString,
            "outputDirectory": outputDir.absoluteString,
            "preset": try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)),
            "decodeOptions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(DecodeOptions.default)),
            "namingTemplate": "{name}_HDR.{ext}",
            "useFormatSubdirectories": false,
            "conflictPolicy": "overwrite",
            "verifyAfterExport": true,
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
        let decodedLegacy = try JSONDecoder().decode(ExportJob.self, from: legacyData)
        #expect(decodedLegacy.inputURL == inputURL)
        #expect(decodedLegacy.cliOverrides == nil)
        #expect(decodedLegacy.useSidecar == false)
        #expect(decodedLegacy.avifCodecOverride == nil)

        let cliOverrides = CLIDevelopOverrides(
            presetExplicitlySpecified: true,
            backend: .libraw,
            demosaic: .lmmse,
            toneMapper: .sigmoid,
            clarity: 25.0,
            opticalSharpness: 40.0
        )
        let v11Job = ExportJob(
            inputURL: inputURL,
            outputDirectory: outputDir,
            preset: preset,
            cliOverrides: cliOverrides,
            useSidecar: true,
            avifCodecOverride: .libaom
        )
        let encoded = try JSONEncoder().encode(v11Job)
        let decodedV11 = try JSONDecoder().decode(ExportJob.self, from: encoded)
        #expect(decodedV11 == v11Job)
        #expect(decodedV11.useSidecar == true)
        #expect(decodedV11.avifCodecOverride == .libaom)
        #expect(decodedV11.cliOverrides?.demosaic == .lmmse)
    }

    @Test
    func testFourTierPrecedenceWithExplicitAndImplicitPreset() throws {
        let appleHEIC = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let xhsJPG = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
        let presetsByID = [appleHEIC.id: appleHEIC, xhsJPG.id: xhsJPG]

        let sidecar = ChiaroSidecar(
            presetID: xhsJPG.id,
            decodeBackend: .ciraw9,
            demosaic: .dcb,
            optics: OpticalCorrectionParameters(
                enabled: true,
                source: .embedded,
                distortion: false,
                tca: true,
                vignetting: true,
                vignettingStrength: 0.4
            ),
            delta: PerPhotoDelta(
                exposureEVDelta: 0.5,
                sdrToneMapperOverride: .neutralRational,
                clarityOverride: 30.0,
                opticalSharpnessOverride: 45.0
            ),
            denoise: DenoiseParameters(
                mode: .profiledWavelet,
                luminanceStrength: 40.0,
                chromaStrength: 80.0
            )
        )

        // Implicit preset allows sidecar presetID switching
        let implicitResolved = EffectiveDevelopParams.resolve(
            preset: appleHEIC,
            delta: nil,
            sidecar: sidecar,
            cliOverrides: CLIDevelopOverrides(presetExplicitlySpecified: false),
            presetResolver: { presetsByID[$0] }
        )
        #expect(implicitResolved.cropAspect == xhsJPG.cropAspect)
        #expect(implicitResolved.maxLongEdge == 2048)
        #expect(implicitResolved.sdrToneMapper == .neutralRational)

        // Explicit preset blocks sidecar presetID switching
        let explicitResolved = EffectiveDevelopParams.resolve(
            preset: appleHEIC,
            delta: nil,
            sidecar: sidecar,
            cliOverrides: CLIDevelopOverrides(presetExplicitlySpecified: true),
            presetResolver: { presetsByID[$0] }
        )
        #expect(explicitResolved.cropAspect == appleHEIC.cropAspect)
        #expect(explicitResolved.maxLongEdge == nil)

        // Full 4-tier: CLI > --delta-file > .chiaro.json > Preset
        let delta = PerPhotoDelta(
            exposureEVDelta: -0.25,
            sdrToneMapperOverride: .openDRT,
            clarityOverride: -15.0,
            opticalSharpnessOverride: 10.0,
            demosaicOverride: .dht
        )
        let cli = CLIDevelopOverrides(
            presetExplicitlySpecified: true,
            backend: .libraw,
            demosaic: .lmmse,
            denoiseMode: .off,
            denoiseLuma: 12.0,
            denoiseChroma: 50.0,
            lensCorrectionEnabled: true,
            lensSource: .lensfun,
            lensDistortion: true,
            lensTCA: false,
            lensVignetting: true,
            lensVignettingStrength: 0.5,
            toneMapper: .sigmoid,
            clarity: 60.0,
            opticalSharpness: 75.0
        )
        let merged = EffectiveDevelopParams.resolve(
            preset: appleHEIC,
            delta: delta,
            sidecar: sidecar,
            cliOverrides: cli,
            presetResolver: { presetsByID[$0] }
        )
        #expect(abs(merged.develop.exposureEV - (-0.25)) < 1e-9) // Replaced sidecar 0.50, not stacked
        #expect(merged.decodeBackend == .libraw)
        #expect(merged.demosaic == .lmmse)
        #expect(merged.sdrToneMapper == .sigmoid)
        #expect(merged.develop.clarity == 60.0)
        #expect(merged.develop.opticalSharpness == 75.0)
        #expect(merged.denoise.mode == .off)
        #expect(merged.denoise.luminanceStrength == 12.0)
        #expect(merged.denoise.chromaStrength == 50.0)
        #expect(merged.optics.enabled == true)
        #expect(merged.optics.source == .lensfun)
        #expect(merged.optics.distortion == true)
        #expect(merged.optics.tca == false)
        #expect(merged.optics.vignetting == true)
        #expect(abs(merged.optics.vignettingStrength - 0.5) < 1e-9)
    }

    @Test
    func testMalformedSidecarBatchIsolationAndUseSidecarToggle() async throws {
        let dir = try makeM4TempDir(prefix: "m4-malformed-sidecar")
        defer { try? FileManager.default.removeItem(at: dir) }

        let rawURL = dir.appendingPathComponent("DSC00001.ARW")
        try Data("NOT_VALID_RAW_BYTES".utf8).write(to: rawURL)
        try Data("{broken sidecar json".utf8).write(to: ChiaroSidecar.sidecarURL(for: rawURL))

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

        // 1. useSidecar: true fails per-job cleanly without throwing out of runDetailed
        let jobWithSidecar = ExportJob(
            inputURL: rawURL,
            outputDirectory: outDir,
            preset: preset,
            useSidecar: true
        )
        let detailedEvents = OSAllocatedUnfairLock<[BatchDetailedProgressEvent]>(initialState: [])
        let resultsWithSidecar = try await BoundedBatchPipeline().runDetailed(jobs: [jobWithSidecar]) { ev in
            detailedEvents.withLock { $0.append(ev) }
        }
        #expect(resultsWithSidecar.count == 1)
        let errWithSidecar = try #require(resultsWithSidecar[0].errorDescription)
        #expect(errWithSidecar.contains("Failed to load sidecar"))
        let events = detailedEvents.withLock { $0 }
        #expect(events.contains { if case .batchCompleted(_, 0, 1, _) = $0 { return true }; return false })

        // 2. useSidecar: false ignores the corrupt .chiaro.json completely (fails on RAW decode instead)
        let jobWithoutSidecar = ExportJob(
            inputURL: rawURL,
            outputDirectory: outDir,
            preset: preset,
            useSidecar: false
        )
        let resultsWithoutSidecar = try await BoundedBatchPipeline().runDetailed(jobs: [jobWithoutSidecar])
        #expect(resultsWithoutSidecar.count == 1)
        let errWithoutSidecar = try #require(resultsWithoutSidecar[0].errorDescription)
        #expect(!errWithoutSidecar.contains("Failed to load sidecar"))
    }

    @Test
    func testOpticsResolutionInfoWithEmbeddedAndDisabledOptics() throws {
        let embedded = EmbeddedSonyOpticsPayload(
            distortionNodeCount: 2,
            distortionParams: [12, 24],
            caNodeCount: 2,
            caRedParams: [4, 8],
            caBlueParams: [-4, -8],
            vignettingNodeCount: 2,
            vignettingParams: [100, 200],
            focalLengthMM: 50.0,
            fNumber: 2.8,
            sensorAspectRatio: 1.5,
            cropFactor: 1.0
        )
        let frame = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/DSC00001.ARW"),
            backendUsed: .libraw,
            payload: .rawBayer(width: 8, height: 8, bitsPerSample: 14, cfa: .rggb, data: Data(count: 8 * 8 * 2)),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: 8, height: 8),
            orientation: 1,
            colorMatrices: CameraColorMatrices(),
            isLosslessMS: false,
            exif: WhitelistedExif(
                make: "SONY",
                model: "ILCE-7CM2",
                lensModel: "FE 50mm F1.4 GM",
                focalLengthMM: 50.0,
                fNumber: 2.8
            ),
            demosaicUsed: .amaze,
            embeddedSonyOptics: embedded,
            fullSensorDimensions: PixelDimensions(width: 8, height: 8),
            cropFactor: 1.0
        )

        let autoInfo = OpticsPipelineEngine.resolveOpticsInfo(frame: frame, params: .default)
        #expect(autoInfo.source == .embeddedARW)
        #expect(autoInfo.lensMatched == "FE 50mm F1.4 GM")
        #expect(autoInfo.distortionApplied == true)
        #expect(autoInfo.tcaApplied == true)
        #expect(autoInfo.vignettingApplied == true)

        let disabledInfo = OpticsPipelineEngine.resolveOpticsInfo(
            frame: frame,
            params: OpticalCorrectionParameters(enabled: false)
        )
        #expect(disabledInfo == .none)

        let allSubOffInfo = OpticsPipelineEngine.resolveOpticsInfo(
            frame: frame,
            params: OpticalCorrectionParameters(enabled: true, distortion: false, tca: false, vignetting: false)
        )
        #expect(allSubOffInfo == .none)

        let zeroVigStrengthInfo = OpticsPipelineEngine.resolveOpticsInfo(
            frame: frame,
            params: OpticalCorrectionParameters(
                enabled: true,
                source: .embedded,
                distortion: false,
                tca: false,
                vignetting: true,
                vignettingStrength: 0.0
            )
        )
        #expect(zeroVigStrengthInfo.source == .embeddedARW)
        #expect(zeroVigStrengthInfo.vignettingApplied == false)
    }

    @Test
    func testCLISubprocessSampleFreeContractsAndValidation() throws {
        let cliURL = try #require(findM4CLIBinary(), "chiaro-cli binary not found in .build")

        // 1. --help documents USAGE: and all v1.1 flags
        let helpRes = try runM4CLI(cliURL, arguments: ["--help"])
        #expect(helpRes.status == 0)
        #expect(helpRes.stdout.contains("USAGE:"))
        for flag in [
            "--demosaic",
            "--denoise",
            "--denoise-luma",
            "--denoise-chroma",
            "--lens-correction",
            "--lens-distortion",
            "--lens-tca",
            "--lens-vignetting",
            "--lens-vignetting-strength",
            "--tone-mapper",
            "--clarity",
            "--sharpness",
            "--use-sidecar",
            "--no-sidecar",
        ] {
            #expect(helpRes.stdout.contains(flag), "Missing \(flag) in --help")
        }

        // 2. --list-presets returns all 7 presets
        let listRes = try runM4CLI(cliURL, arguments: ["--list-presets"])
        #expect(listRes.status == 0)
        for presetID in BuiltInPresetID.allCases {
            #expect(listRes.stdout.contains(presetID.rawValue))
        }

        // 3. Invalid v1.1 enum / BVA / NaN / Inf invocations reject before creating output dir
        let workDir = try makeM4TempDir(prefix: "m4-cli-samplefree")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let dummyARW = workDir.appendingPathComponent("dummy.ARW")
        try Data("DUMMY".utf8).write(to: dummyARW)
        let badOut = workDir.appendingPathComponent("bad_out", isDirectory: true)

        let emptyCwdDir = workDir.appendingPathComponent("empty_cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyCwdDir, withIntermediateDirectories: true)

        let invalidInvocations: [[String]] = [
            [dummyARW.path, "--demosaic", "bilinear", "-o", badOut.path],
            [dummyARW.path, "--demosaic", "", "-o", badOut.path],
            [dummyARW.path, "--demosaic"],
            [dummyARW.path, "--denoise", "coreml", "-o", badOut.path],
            [dummyARW.path, "--denoise", "high", "-o", badOut.path],
            [dummyARW.path, "--denoise"],
            [dummyARW.path, "--denoise-chroma", "-0.1", "-o", badOut.path],
            [dummyARW.path, "--denoise-chroma", "100.1", "-o", badOut.path],
            [dummyARW.path, "--denoise-chroma", "nan", "-o", badOut.path],
            [dummyARW.path, "--denoise-chroma", "inf", "-o", badOut.path],
            [dummyARW.path, "--denoise-chroma=", "-o", badOut.path],
            [dummyARW.path, "--denoise-luma", "-1", "-o", badOut.path],
            [dummyARW.path, "--denoise-luma", "101", "-o", badOut.path],
            [dummyARW.path, "--denoise-luma", "nan", "-o", badOut.path],
            [dummyARW.path, "--denoise-luma", "abc", "-o", badOut.path],
            [dummyARW.path, "--lens-correction", "manual", "-o", badOut.path],
            [dummyARW.path, "--lens-correction", "", "-o", badOut.path],
            [dummyARW.path, "--lens-distortion", "2", "-o", badOut.path],
            [dummyARW.path, "--lens-distortion", "maybe", "-o", badOut.path],
            [dummyARW.path, "--lens-tca", "2", "-o", badOut.path],
            [dummyARW.path, "--lens-tca", "", "-o", badOut.path],
            [dummyARW.path, "--lens-vignetting", "maybe", "-o", badOut.path],
            [dummyARW.path, "--lens-vignetting", "2", "-o", badOut.path],
            [dummyARW.path, "--lens-vignetting-strength", "-0.1", "-o", badOut.path],
            [dummyARW.path, "--lens-vignetting-strength", "100.1", "-o", badOut.path],
            [dummyARW.path, "--lens-vignetting-strength", "nan", "-o", badOut.path],
            [dummyARW.path, "--lens-vignetting-strength", "xyz", "-o", badOut.path],
            [dummyARW.path, "--tone-mapper", "reinhard", "-o", badOut.path],
            [dummyARW.path, "--tone-mapper", "", "-o", badOut.path],
            [dummyARW.path, "--clarity", "-100.1", "-o", badOut.path],
            [dummyARW.path, "--clarity", "100.1", "-o", badOut.path],
            [dummyARW.path, "--clarity", "nan", "-o", badOut.path],
            [dummyARW.path, "--clarity", "bad", "-o", badOut.path],
            [dummyARW.path, "--sharpness", "-0.1", "-o", badOut.path],
            [dummyARW.path, "--sharpness", "100.1", "-o", badOut.path],
            [dummyARW.path, "--sharpness", "nan", "-o", badOut.path],
            [dummyARW.path, "--sharpness", "bad", "-o", badOut.path],
            // Valueless boolean flags must reject =value rather than silently discarding it
            [dummyARW.path, "--use-sidecar=false", "-o", badOut.path],
            [dummyARW.path, "--use-sidecar=", "-o", badOut.path],
            [dummyARW.path, "--no-sidecar=true", "-o", badOut.path],
            [dummyARW.path, "--verify=false", "-o", badOut.path],
            [dummyARW.path, "--no-verify=true", "-o", badOut.path],
            [dummyARW.path, "--recursive=false", "-o", badOut.path],
            ["--help=garbage"],
            ["--list-presets=1"],
            [dummyARW.path, "--format-subdirs=false", "-o", badOut.path],
            [dummyARW.path, "--custom-rendered-hdr=false", "-o", badOut.path],
            [dummyARW.path, "--json-progress=false", "-o", badOut.path],
            // Empty or whitespace-only -o / --output must fail instead of targeting CWD
            [dummyARW.path, "-o", ""],
            [dummyARW.path, "-o", "   "],
            [dummyARW.path, "--output=   "],
            [dummyARW.path, "--output="],
        ]
        for args in invalidInvocations {
            let res = try runM4CLI(cliURL, arguments: args, currentDirectoryURL: emptyCwdDir)
            #expect(res.status > 0, "Expected failure exit code for \(args)")
            #expect(!res.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Expected stderr for \(args)")
            #expect(res.stdout.isEmpty, "Expected empty stdout for invalid args \(args)")
        }
        #expect(!FileManager.default.fileExists(atPath: badOut.path))
        let cwdContents = try FileManager.default.contentsOfDirectory(atPath: emptyCwdDir.path)
        #expect(cwdContents.isEmpty, "Expected zero files/directories created in CWD, found: \(cwdContents)")

        // 4. Strict ARW discovery excludes fake.ARW/, .HIF, .JPG, .HEIC, .chiaro.json, and symlink -> .HIF
        let mixedDir = workDir.appendingPathComponent("mixed_non_arw", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mixedDir.appendingPathComponent("fake.ARW", isDirectory: true),
            withIntermediateDirectories: true
        )
        let hifURL = mixedDir.appendingPathComponent("DSC00001.HIF")
        try Data("hif".utf8).write(to: hifURL)
        try Data("jpg".utf8).write(to: mixedDir.appendingPathComponent("DSC00001.JPG"))
        try Data("heic".utf8).write(to: mixedDir.appendingPathComponent("DSC00001.HEIC"))
        try Data("{}".utf8).write(to: mixedDir.appendingPathComponent("DSC00001.ARW.chiaro.json"))
        try FileManager.default.createSymbolicLink(
            at: mixedDir.appendingPathComponent("sneaky.ARW"),
            withDestinationURL: hifURL
        )

        let noARWOut = workDir.appendingPathComponent("no_arw_out", isDirectory: true)
        let discoveryRes = try runM4CLI(cliURL, arguments: [mixedDir.path, "-r", "-o", noARWOut.path])
        #expect(discoveryRes.status > 0)
        #expect(discoveryRes.stderr.contains("No .ARW files found"))
        #expect(!FileManager.default.fileExists(atPath: noARWOut.path))
    }

    @Test
    func testCLIEmptyAndWhitespaceValueOptionRejection() throws {
        let cliURL = try #require(findM4CLIBinary(), "chiaro-cli binary not found in .build")
        let workDir = try makeM4TempDir(prefix: "m4-cli-empty-opts")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let dummyARW = workDir.appendingPathComponent("dummy.ARW")
        try Data("DUMMY".utf8).write(to: dummyARW)
        let badOut = workDir.appendingPathComponent("bad_out", isDirectory: true)
        let emptyCwdDir = workDir.appendingPathComponent("empty_cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyCwdDir, withIntermediateDirectories: true)

        let cases: [(flag: String, args: [String])] = [
            ("--preset", [dummyARW.path, "--preset", "", "-o", badOut.path]),
            ("-p", [dummyARW.path, "-p", "", "-o", badOut.path]),
            ("--preset", [dummyARW.path, "--preset=", "-o", badOut.path]),
            ("--preset", [dummyARW.path, "--preset", "   ", "-o", badOut.path]),
            ("-p", [dummyARW.path, "-p", "   ", "-o", badOut.path]),
            ("--preset", [dummyARW.path, "--preset=   ", "-o", badOut.path]),
            ("--preset", [dummyARW.path, "--preset", "", "--no-sidecar", "--no-verify", "--json-progress", "-o", badOut.path]),
            ("--preset-file", [dummyARW.path, "--preset-file", "", "-o", badOut.path]),
            ("--preset-file", [dummyARW.path, "--preset-file=", "-o", badOut.path]),
            ("--preset-file", [dummyARW.path, "--preset-file", "   ", "-o", badOut.path]),
            ("--delta-file", [dummyARW.path, "--delta-file", "", "-o", badOut.path]),
            ("--delta-file", [dummyARW.path, "--delta-file=", "-o", badOut.path]),
            ("--delta-file", [dummyARW.path, "--delta-file", "   ", "-o", badOut.path]),
            ("-i", ["-i", "", "-o", badOut.path]),
            ("--input", ["--input=", "-o", badOut.path]),
            ("-i", ["-i", "   ", "-o", badOut.path]),
            ("--input", ["--input", "   ", "-o", badOut.path]),
        ]

        for entry in cases {
            let res = try runM4CLI(cliURL, arguments: entry.args, currentDirectoryURL: emptyCwdDir)
            #expect(res.status > 0, "Expected non-zero exit for \(entry.args)")
            #expect(res.stdout.isEmpty, "Expected empty stdout for \(entry.args), got: \(res.stdout)")
            let trimmedErr = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!trimmedErr.isEmpty, "Expected non-empty stderr for \(entry.args)")
            #expect(trimmedErr.contains("Option \(entry.flag) cannot be empty."), "Unexpected stderr for \(entry.args): \(trimmedErr)")
            #expect(!trimmedErr.contains("NSCocoaErrorDomain"), "Raw Cocoa error leaked for \(entry.args): \(trimmedErr)")
            #expect(!trimmedErr.contains("Is a directory"), "Raw EISDIR leaked for \(entry.args): \(trimmedErr)")
            #expect(!trimmedErr.contains("douyin_hlg_mp4"), "Unexpected preset fallback in stderr for \(entry.args)")
        }

        #expect(!FileManager.default.fileExists(atPath: badOut.path))
        let cwdContents = try FileManager.default.contentsOfDirectory(atPath: emptyCwdDir.path)
        #expect(cwdContents.isEmpty, "Expected zero files/directories created in CWD, found: \(cwdContents)")
    }
}

} // extension ChiaroSerializedSuites
