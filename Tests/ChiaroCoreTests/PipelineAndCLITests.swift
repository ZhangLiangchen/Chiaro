import Foundation
import ImageIO
import os
import Testing
@testable import ChiaroCore

private let m5TangmoDir = TestFixtures.sampleDirectory
private let m5RepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ChiaroCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // Chiaro

private func makeM5TempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func findBuiltCLIBinary() -> URL? {
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
        let candidate = m5RepoRoot.appendingPathComponent(rel)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func runM5CLI(
    _ executableURL: URL,
    arguments: [String]
) throws -> (status: Int32, stdout: String, stderr: String) {
    let proc = Process()
    proc.executableURL = executableURL
    proc.arguments = arguments
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

private func hasLeftoverM5TmpFiles(in dir: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
        return false
    }
    for case let url as URL in enumerator {
        if url.lastPathComponent.contains(".tmp") {
            return true
        }
    }
    return false
}

extension ChiaroSerializedSuites {

@Suite("PipelineAndCLITests", .serialized)
struct PipelineAndCLITests {

    @Test
    func testMemoryBudgetSchedulerTiersAndBackpressure() async throws {
        // 16 GiB tier (<= 20 GiB)
        let scheduler16 = MemoryBudgetScheduler(physicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        let budget16_61MP = scheduler16.budget(estimatedMegapixels: 61.0, backend: .libraw, outputFormats: [.heic, .avif])
        #expect(budget16_61MP.tier == .standard16GB)
        #expect(budget16_61MP.maxInFlightFrames <= 2)
        #expect(budget16_61MP.decodeConcurrency <= 2)
        #expect(budget16_61MP.gpuRenderConcurrency == 1)
        #expect(budget16_61MP.encodeJobConcurrency == 1)
        #expect(budget16_61MP.stage1To2Capacity == 1)
        #expect(budget16_61MP.stage2To3Capacity == 1)

        let budget16_33MP = scheduler16.budget(estimatedMegapixels: 33.0, backend: .libraw, outputFormats: [.heic])
        #expect(budget16_33MP.decodeConcurrency <= 2)
        #expect(budget16_33MP.gpuRenderConcurrency == 1)
        #expect(budget16_33MP.encodeJobConcurrency == 1)

        // 32 GiB+ tier (> 20 GiB)
        let scheduler32 = MemoryBudgetScheduler(physicalMemoryBytes: 32 * 1024 * 1024 * 1024)
        let budget32_33MP = scheduler32.budget(estimatedMegapixels: 33.0, backend: .libraw, outputFormats: [.heic, .jpeg, .avif])
        #expect(budget32_33MP.tier == .high32GBPlus)
        #expect(budget32_33MP.decodeConcurrency == 3)
        #expect(budget32_33MP.gpuRenderConcurrency == 1)
        #expect(budget32_33MP.encodeJobConcurrency == 2)
        #expect(budget32_33MP.stage1To2Capacity == 2)
        #expect(budget32_33MP.stage2To3Capacity == 2)
        #expect((3...4).contains(budget32_33MP.maxInFlightFrames))

        let budget32_61MP_avif = scheduler32.budget(estimatedMegapixels: 61.0, backend: .libraw, outputFormats: [.avif])
        #expect(budget32_61MP_avif.decodeConcurrency == 2)
        #expect(budget32_61MP_avif.encodeJobConcurrency == 1)
        #expect((3...4).contains(budget32_61MP_avif.maxInFlightFrames))

        let budget32_ciraw = scheduler32.budget(estimatedMegapixels: 33.0, backend: .ciraw9, outputFormats: [.heic])
        #expect(budget32_ciraw.decodeConcurrency == 2)

        // Async permit backpressure + cancellation
        let gatedScheduler = MemoryBudgetScheduler(physicalMemoryBytes: 16 * 1024 * 1024 * 1024, permitCount: 2)
        actor Counter {
            var active = 0
            var peak = 0
            func enter() {
                active += 1
                peak = max(peak, active)
            }
            func leave() {
                active -= 1
            }
        }
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await gatedScheduler.withPermit {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(25))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let observedPeak = await counter.peak
        #expect(observedPeak == 2)

        // Verify waiting acquire throws CancellationError cleanly without leaking permit
        try await gatedScheduler.acquire()
        try await gatedScheduler.acquire()
        let cancelledTask = Task {
            try await gatedScheduler.acquire()
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelledTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledTask.value
        }
        await gatedScheduler.release()
        await gatedScheduler.release()

        // Both permits should be available again
        try await gatedScheduler.withPermit { () async throws -> Void in }
    }

    @Test
    func testBoundedAsyncChannelSuspendsProducersAndDrainsFIFO() async throws {
        let channel = BoundedAsyncChannel<Int>(capacity: 2)
        try await channel.send(1)
        try await channel.send(2)
        #expect(await channel.bufferedCount == 2)

        // 3rd send must suspend until consumer consumes one item
        let thirdSent = Task {
            try await channel.send(3)
            return true
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await channel.waitingProducerCount == 1)

        let first = await channel.next()
        #expect(first == 1)
        #expect(try await thirdSent.value == true)
        #expect(await channel.next() == 2)
        #expect(await channel.next() == 3)

        // Cancelled blocked send must wake immediately with CancellationError
        try await channel.send(10)
        try await channel.send(20)
        let blockedSend = Task {
            try await channel.send(30)
        }
        try await Task.sleep(for: .milliseconds(20))
        blockedSend.cancel()
        await #expect(throws: CancellationError.self) {
            try await blockedSend.value
        }
        await channel.finish()
        #expect(await channel.next() == 10)
        #expect(await channel.next() == 20)
        #expect(await channel.next() == nil)
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testTriFormatSingleDecodeFanOutAndSubdirs() async throws {
        let dsc2532 = m5TangmoDir.appendingPathComponent("DSC02532.ARW")
        let dsc2540 = m5TangmoDir.appendingPathComponent("DSC02540.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2532.path))
        try #require(FileManager.default.fileExists(atPath: dsc2540.path))

        let outDir = try makeM5TempDir(prefix: "m5-triformat")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let triPreset = try PresetLoader.loadBuiltIn(id: .triFormat)
        let jobs = [
            ExportJob(
                inputURL: dsc2532,
                outputDirectory: outDir,
                preset: triPreset,
                useFormatSubdirectories: true,
                verifyAfterExport: true
            ),
            ExportJob(
                inputURL: dsc2540,
                outputDirectory: outDir,
                preset: triPreset,
                useFormatSubdirectories: true,
                verifyAfterExport: true
            ),
        ]

        let sharedEngine = try MetalPipelineEngine()
        let capturedSnapshots = OSAllocatedUnfairLock<[BoundedBatchPipeline.PreAVIFPoolSnapshot]>(initialState: [])
        let pipeline = BoundedBatchPipeline(
            metalEngine: sharedEngine,
            preAVIFPoolStatsHook: { snapshot in
                capturedSnapshots.withLock { $0.append(snapshot) }
            }
        )
        let results = try await pipeline.run(jobs: jobs)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.errorDescription == nil })

        let preAVIFSnapshots = capturedSnapshots.withLock { $0 }
        #expect(preAVIFSnapshots.count == 2)
        for snap in preAVIFSnapshots {
            #expect(snap.statsBeforeEvict.activeCount == 0)
            #expect(snap.statsAfterEvict.activeCount == 0)
            #expect(snap.statsAfterEvict.heapCount == 0)
            #expect(snap.statsAfterEvict.totalHeapBytes == 0)
            #expect(snap.statsAfterEvict.evictedHeapCount > 0)
        }
        #expect(sharedEngine.texturePool.stats.activeCount == 0)
        #expect(sharedEngine.texturePool.stats.heapCount == 0)
        #expect(sharedEngine.texturePool.stats.totalHeapBytes == 0)

        for (stem, expW, expH) in [("DSC02532", 7008, 4672), ("DSC02540", 4672, 7008)] {
            let heicURL = outDir.appendingPathComponent("heic/\(stem)_HDR.heic")
            let jpgURL = outDir.appendingPathComponent("jpeg/\(stem)_HDR.jpg")
            let avifURL = outDir.appendingPathComponent("avif/\(stem)_HDR.avif")
            for url in [heicURL, jpgURL, avifURL] {
                #expect(FileManager.default.fileExists(atPath: url.path))
                let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
                #expect((props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == expW)
                #expect((props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == expH)
                #expect((props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue == 1)
            }
        }

        for result in results {
            #expect(result.artifacts.count == 3)
            for artifact in result.artifacts {
                #expect(artifact.compliance?.passed == true)
                if artifact.format == .avif {
                    #expect(artifact.usedGridTiling == true)
                }
            }
        }
        #expect(!hasLeftoverM5TmpFiles(in: outDir))
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testNamingTemplatesAndConflictPolicies() async throws {
        let dsc2556 = m5TangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        let outDir = try makeM5TempDir(prefix: "m5-conflicts")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let pipeline = BoundedBatchPipeline()

        // 1. Custom naming template
        let namedJob = ExportJob(
            inputURL: dsc2556,
            outputDirectory: outDir,
            preset: preset,
            namingTemplate: "{preset}_{format}_{name}.{ext}",
            verifyAfterExport: true
        )
        let namedRes = try await pipeline.run(jobs: [namedJob])
        #expect(namedRes.first?.errorDescription == nil)
        let expectedNamedURL = outDir.appendingPathComponent("apple_heic_heic_DSC02556.heic")
        #expect(FileManager.default.fileExists(atPath: expectedNamedURL.path))

        // 2. .skip preserves sentinel
        let sentinelURL = outDir.appendingPathComponent("DSC02556_HDR.heic")
        let sentinelBytes = Data("SENTINEL_KEEP".utf8)
        try sentinelBytes.write(to: sentinelURL)

        let skipJob = ExportJob(
            inputURL: dsc2556,
            outputDirectory: outDir,
            preset: preset,
            conflictPolicy: .skip,
            verifyAfterExport: true
        )
        let skipRes = try await pipeline.run(jobs: [skipJob])
        #expect(skipRes.first?.errorDescription == nil)
        #expect(skipRes.first?.artifacts.isEmpty == true)
        #expect(try Data(contentsOf: sentinelURL) == sentinelBytes)

        // 3. .autoNumber preserves sentinel and writes DSC02556_HDR_1.heic
        let autoJob = ExportJob(
            inputURL: dsc2556,
            outputDirectory: outDir,
            preset: preset,
            conflictPolicy: .autoNumber,
            verifyAfterExport: true
        )
        let autoRes = try await pipeline.run(jobs: [autoJob])
        #expect(autoRes.first?.errorDescription == nil)
        #expect(try Data(contentsOf: sentinelURL) == sentinelBytes)
        let numberedURL = outDir.appendingPathComponent("DSC02556_HDR_1.heic")
        #expect(autoRes.first?.artifacts.first?.outputURL.standardizedFileURL == numberedURL.standardizedFileURL)
        #expect(autoRes.first?.artifacts.first?.compliance?.passed == true)

        // 4. .overwrite replaces sentinel
        let overwriteJob = ExportJob(
            inputURL: dsc2556,
            outputDirectory: outDir,
            preset: preset,
            conflictPolicy: .overwrite,
            verifyAfterExport: true
        )
        let ovrRes = try await pipeline.run(jobs: [overwriteJob])
        #expect(ovrRes.first?.errorDescription == nil)
        #expect(ovrRes.first?.artifacts.first?.compliance?.passed == true)
        #expect(try Data(contentsOf: sentinelURL) != sentinelBytes)
        #expect(!hasLeftoverM5TmpFiles(in: outDir))
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testDeltaHeadroomAndFourFormatOverrideWithSynthesizedHLG() async throws {
        let dsc2540 = m5TangmoDir.appendingPathComponent("DSC02540.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2540.path))

        let outDir = try makeM5TempDir(prefix: "m5-fourformat")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let triPreset = try PresetLoader.loadBuiltIn(id: .triFormat)
        #expect(triPreset.hlgVideoOptions == nil)

        let delta = PerPhotoDelta(
            exposureEVDelta: -0.25,
            targetHeadroomStopsOverride: 1.5,
            cropAspectOverride: .ratio3x4
        )
        let job = ExportJob(
            inputURL: dsc2540,
            outputDirectory: outDir,
            preset: triPreset,
            formatOverrides: [.heic, .jpeg, .avif, .hlgMP4],
            delta: delta,
            useFormatSubdirectories: true,
            verifyAfterExport: true
        )

        let results = try await BoundedBatchPipeline().run(jobs: [job])
        #expect(results.count == 1)
        let res = try #require(results.first)
        #expect(res.errorDescription == nil, "Expected nil error, got: \(res.errorDescription ?? "")")
        #expect(res.artifacts.count == 4)

        // Verify mp4 subdir (NOT hlgMP4) and all 4 compliance reports pass
        let mp4URL = outDir.appendingPathComponent("mp4/DSC02540_HDR.mp4")
        #expect(FileManager.default.fileExists(atPath: mp4URL.path))
        for artifact in res.artifacts {
            #expect(artifact.compliance?.passed == true)
            if artifact.format != .hlgMP4 {
                let hr = try #require(artifact.compliance?.measuredHeadroom?.multiplier)
                let expected = HeadroomStops(log2Value: 1.5).toLinear().multiplier
                #expect(abs(hr - expected) / expected < 0.02)
            }
        }
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testFaultIsolationAndCancellation() async throws {
        let dsc2556 = m5TangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        let workDir = try makeM5TempDir(prefix: "m5-fault")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let corruptARW = workDir.appendingPathComponent("corrupt_trunc.ARW")
        try Data("NOT_A_VALID_RAW_FILE".utf8).write(to: corruptARW)
        let outDir = workDir.appendingPathComponent("out", isDirectory: true)

        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
        let jobs = [
            ExportJob(inputURL: dsc2556, outputDirectory: outDir, preset: preset, verifyAfterExport: true),
            ExportJob(inputURL: corruptARW, outputDirectory: outDir, preset: preset, verifyAfterExport: true),
        ]

        let results = try await BoundedBatchPipeline().run(jobs: jobs)
        #expect(results.count == 2)
        #expect(results[0].errorDescription == nil)
        #expect(results[0].artifacts.first?.compliance?.passed == true)
        #expect(results[1].errorDescription != nil)
        #expect(results[1].artifacts.isEmpty)
        #expect(!hasLeftoverM5TmpFiles(in: outDir))

        // Cancellation test
        let cancelOut = workDir.appendingPathComponent("cancel_out", isDirectory: true)
        let cancelJobs = (0..<6).map { idx in
            ExportJob(
                inputURL: dsc2556,
                outputDirectory: cancelOut,
                preset: preset,
                namingTemplate: "{name}_\(idx).{ext}",
                verifyAfterExport: false
            )
        }
        let task = Task {
            try await BoundedBatchPipeline().run(jobs: cancelJobs)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected cancellation path
        }
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testCLISubprocessContractsAndEndToEnd() async throws {
        let cliURL = try #require(findBuiltCLIBinary(), "chiaro binary not found in .build")

        // 1. --list-presets and --help
        let listRes = try runM5CLI(cliURL, arguments: ["--list-presets"])
        #expect(listRes.status == 0)
        for presetID in BuiltInPresetID.allCases {
            #expect(listRes.stdout.contains(presetID.rawValue))
        }
        let helpRes = try runM5CLI(cliURL, arguments: ["--help"])
        #expect(helpRes.status == 0)
        #expect(helpRes.stdout.contains("USAGE:"))

        let workDir = try makeM5TempDir(prefix: "m5-cli-e2e")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let dsc2556 = m5TangmoDir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        // 2. Invalid invocations must exit > 0 and leave zero outputs
        let badOut = workDir.appendingPathComponent("bad_out", isDirectory: true)
        let invalidCalls: [[String]] = [
            ["--preset", "apple_heic", "--output", badOut.path],
            [dsc2556.path, "--preset", "no_such_preset", "--output", badOut.path],
            [dsc2556.path, "--formats", "png", "--output", badOut.path],
            [dsc2556.path, "--backend", "bogus", "--output", badOut.path],
            [dsc2556.path, "--avif-codec", "x265", "--output", badOut.path],
            [dsc2556.path, "--on-conflict", "crash", "--output", badOut.path],
            [dsc2556.path, "--delta-file", "/tmp/nonexistent_delta_m5.json", "--output", badOut.path],
        ]
        for args in invalidCalls {
            let r = try runM5CLI(cliURL, arguments: args)
            #expect(r.status > 0, "Expected non-zero exit for \(args)")
        }
        #expect(!FileManager.default.fileExists(atPath: badOut.path))

        // 3. Recursive mixed folder (.ARW + .HIF + .txt + symlink duplicate + directory named subdir.ARW/) + --delta-file + --custom-rendered-hdr + --json-progress
        let inDir = workDir.appendingPathComponent("in", isDirectory: true)
        let subDir = inDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let fakeARWDir = inDir.appendingPathComponent("subdir.ARW", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeARWDir, withIntermediateDirectories: true)
        let copiedARW = subDir.appendingPathComponent("DSC02556.ARW")
        try FileManager.default.copyItem(at: dsc2556, to: copiedARW)
        let symlinkARW = inDir.appendingPathComponent("DSC02556_link.ARW")
        try FileManager.default.createSymbolicLink(at: symlinkARW, withDestinationURL: copiedARW)
        try Data("hif".utf8).write(to: subDir.appendingPathComponent("DSC02556.HIF"))
        try Data("notes".utf8).write(to: subDir.appendingPathComponent("readme.txt"))

        // Directory containing only subdir.ARW/ must fail discovery cleanly (not pass subdir.ARW/ to LibRaw)
        let onlyFakeARWDirRoot = workDir.appendingPathComponent("only_fake_arw_dir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: onlyFakeARWDirRoot.appendingPathComponent("subdir.ARW", isDirectory: true),
            withIntermediateDirectories: true
        )
        let emptyDirOut = workDir.appendingPathComponent("empty_dir_out", isDirectory: true)
        let onlyFakeDirRes = try runM5CLI(cliURL, arguments: [
            onlyFakeARWDirRoot.path,
            "--recursive",
            "--output", emptyDirOut.path,
        ])
        #expect(onlyFakeDirRes.status > 0)
        #expect(onlyFakeDirRes.stderr.contains("No .ARW files found"))
        #expect(!FileManager.default.fileExists(atPath: emptyDirOut.path))

        let deltaFile = workDir.appendingPathComponent("delta.json")
        let deltaJSON = """
        {
          "DSC02556": {
            "targetHeadroomStopsOverride": 1.75,
            "cropAspectOverride": "3:4"
          }
        }
        """
        try Data(deltaJSON.utf8).write(to: deltaFile)

        let okOut = workDir.appendingPathComponent("ok_out", isDirectory: true)
        let okRes = try runM5CLI(cliURL, arguments: [
            inDir.path,
            "--recursive",
            "--output", okOut.path,
            "--preset", "apple_heic",
            "--delta-file", deltaFile.path,
            "--custom-rendered-hdr",
            "--json-progress",
            "--verify",
        ])
        #expect(okRes.status == 0, "CLI failed: \(okRes.stderr)")

        let produced = try FileManager.default.contentsOfDirectory(at: okOut, includingPropertiesForKeys: nil)
        #expect(produced.count == 1)
        let outHEIC = okOut.appendingPathComponent("DSC02556_HDR.heic")
        #expect(FileManager.default.fileExists(atPath: outHEIC.path))

        let ndjsonLines = okRes.stdout.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        #expect(ndjsonLines.count >= 3)
        for line in ndjsonLines {
            let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
            #expect(parsed is [String: Any])
        }

        // Verify CustomRendered == 3 & headroom ~1.75 EV
        let src = try #require(CGImageSourceCreateWithURL(outHEIC as CFURL, nil))
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect((exif?[kCGImagePropertyExifCustomRendered as String] as? NSNumber)?.intValue == 3)
        let hdrImg = try #require(CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
        let expectedHR = HeadroomStops(log2Value: 1.75).toLinear().multiplier
        #expect(abs(Double(hdrImg.contentHeadroom) - expectedHR) / expectedHR < 0.02)

        // 4. Partial failure: valid + corrupt .ARW -> exit > 0 while valid output is written cleanly
        let corruptARW = workDir.appendingPathComponent("corrupt_trunc.ARW")
        try Data("TRUNCATED".utf8).write(to: corruptARW)
        let partialOut = workDir.appendingPathComponent("partial_out", isDirectory: true)
        let partialRes = try runM5CLI(cliURL, arguments: [
            dsc2556.path,
            corruptARW.path,
            "--output", partialOut.path,
            "--preset", "apple_heic",
            "--json-progress",
        ])
        #expect(partialRes.status > 0)
        #expect(FileManager.default.fileExists(atPath: partialOut.appendingPathComponent("DSC02556_HDR.heic").path))
        #expect((partialRes.stdout + partialRes.stderr).contains("corrupt_trunc.ARW"))
        #expect(!hasLeftoverM5TmpFiles(in: partialOut))
    }
}

}
