import ChiaroAppCore
@testable import ChiaroCore
import Foundation
import Metal
import os
import simd
import Testing

private let tier5V11RepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ChiaroCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // Chiaro

private func makeTier5V11TempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeIsolatedDefaultsV11() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "io.github.zhangliangchen.chiaro.tier5v11.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func findTier5V11CLIBinary() -> URL? {
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
        let candidate = tier5V11RepoRoot.appendingPathComponent(rel)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func runTier5V11CLI(
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

private func makeLinearRGB16FDataV11(rgb: [Float]) -> Data {
    precondition(rgb.count % 3 == 0)
    var halfBits = [UInt16](repeating: 0, count: rgb.count)
    for i in 0..<rgb.count {
        halfBits[i] = Float16(rgb[i]).bitPattern
    }
    return halfBits.withUnsafeBytes { Data($0) }
}

private func makeRGBA16FTextureV11(
    device: any MTLDevice,
    width: Int,
    height: Int,
    rgba: [Float]
) throws -> any MTLTexture {
    precondition(rgba.count == width * height * 4)
    let halfs = rgba.map { Float16($0).bitPattern }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width,
        height: height,
        mipmapped: false
    )
    desc.storageMode = .shared
    desc.usage = [.shaderRead, .shaderWrite]
    let tex = try #require(device.makeTexture(descriptor: desc))
    halfs.withUnsafeBytes { raw in
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: raw.baseAddress!,
            bytesPerRow: width * 8
        )
    }
    return tex
}

private func readRGBA16FPixelsV11(
    device: any MTLDevice,
    commandQueue: any MTLCommandQueue,
    texture: any MTLTexture
) throws -> [Float] {
    let w = texture.width
    let h = texture.height
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: w,
        height: h,
        mipmapped: false
    )
    desc.storageMode = .shared
    desc.usage = [.shaderRead, .shaderWrite]
    let staging = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(commandQueue.makeCommandBuffer())
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.copy(
        from: texture,
        sourceSlice: 0,
        sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: w, height: h, depth: 1),
        to: staging,
        destinationSlice: 0,
        destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()

    var halfs = [UInt16](repeating: 0, count: w * h * 4)
    halfs.withUnsafeMutableBytes { raw in
        staging.getBytes(
            raw.baseAddress!,
            bytesPerRow: w * 8,
            from: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0
        )
    }
    return halfs.map { Float(Float16(bitPattern: $0)) }
}

private func decodeISOGainMapPixelV11(
    sdrLin: [Double],
    gmBuffer: GainMapBuffer,
    metadata: GainMapMetadata,
    gx: Int,
    gy: Int
) -> [Double] {
    let kOffset = metadata.baseOffset.first ?? GainMapMetadata.symmetricOffset
    var out = [Double](repeating: 0.0, count: 3)
    for c in 0..<3 {
        let gMin = metadata.gainMapMin[min(c, metadata.gainMapMin.count - 1)]
        let gMax = metadata.gainMapMax[min(c, metadata.gainMapMax.count - 1)]
        let gamma = metadata.gamma[min(c, metadata.gamma.count - 1)]
        let encoded: Double
        switch gmBuffer.channels {
        case .mono1ch:
            encoded = Double(gmBuffer.data[gy * gmBuffer.bytesPerRow + gx]) / 255.0
        case .rgb3ch:
            let off = gy * gmBuffer.bytesPerRow + gx * 4
            let bgrIdx = 2 - c
            encoded = Double(gmBuffer.data[off + bgrIdx]) / 255.0
        }
        let logGain = gMin + pow(encoded, 1.0 / gamma) * (gMax - gMin)
        out[c] = (sdrLin[c] + kOffset) * exp2(logGain) - kOffset
    }
    return out
}

private final class SpyLinearDenoiseStage: LinearDenoiseStage, @unchecked Sendable {
    private let countLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    var callCount: Int {
        countLock.withLock { $0 }
    }

    func denoise(
        inputTexture: any MTLTexture,
        iso: Int?,
        noiseProfile: SensorNoiseProfile?,
        params: DenoiseParameters,
        commandQueue: any MTLCommandQueue
    ) async throws -> any MTLTexture {
        countLock.withLock { $0 += 1 }
        return inputTexture
    }
}

private func sRGBToLinearV11(_ c: Double) -> Double {
    c <= 0.04045 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
}

private func hasTmpFilesV11(in dir: URL) -> Bool {
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

    // MARK: - Suite 1: Tier5V11AppAndSidecarTests

    @Suite("Tier5V11AppAndSidecarTests", .serialized)
    struct Tier5V11AppAndSidecarTests {

        @Test("1. AppViewModel rejects .nan/.infinity/-.infinity slider inputs without poisoning state or codecs")
        @MainActor
        func testAppViewModelRejectsNonFiniteSliderInputsWithoutPoisoningState() throws {
            let (defaults, suiteName) = makeIsolatedDefaultsV11()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-nan-guards")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let fakeARW = tmpDir.appendingPathComponent("DSC00001.ARW")
            try Data("FAKE_ARW".utf8).write(to: fakeARW)

            let vm = AppViewModel(userDefaults: defaults)
            vm.autoSaveSidecar = false
            vm.importDroppedOrOpenedURLs([fakeARW])
            try #require(vm.selectedItem != nil)

            let nonFiniteInputs: [Double] = [.nan, .infinity, -.infinity]
            let scopes: [(WorkspaceMode, InspectorEditScope)] = [
                (.pro, .globalPreset),
                (.pro, .perPhotoDelta),
                (.preset, .perPhotoDelta),
            ]

            for (mode, scope) in scopes {
                vm.workspaceMode = mode
                vm.editScope = scope
                for bad in nonFiniteInputs {
                    vm.updateExposureEV(bad)
                    vm.updatePresetModeWhiteBalanceKelvin(bad)
                    vm.updateWhiteBalance(.custom(temperatureKelvin: bad, tint: bad))
                    vm.updateShadowRecovery(bad)
                    vm.updateBlackPoint(bad)
                    vm.updateClarity(bad)
                    vm.updateOpticalSharpness(bad)
                    vm.updateVibrance(bad)
                    vm.updateSDRExposureEV(bad)
                    vm.updateSDRHighlightCompression(bad)
                    vm.updateSDRContrast(bad)
                    vm.updateSDRSaturation(bad)
                    vm.updateTargetHeadroomStops(bad)
                    vm.updatePresetModeHDRIntensity(bad)
                    vm.updateMidtoneAnchorP(bad)
                    vm.updateHDRHighlightExcitation(bad)
                    vm.updateHDRRolloffSoftness(bad)
                    vm.setGainMapGamma(bad)
                    vm.setSimulatedHeadroom(LinearHeadroom(multiplier: bad))
                    vm.updateCropOffsetX(bad)
                    vm.updateCropOffsetY(bad)
                    vm.updateScreenMaxEDR(bad)
                    vm.updateDenoiseLuminance(bad)
                    vm.updateDenoiseChroma(bad)
                    vm.updateDenoiseDetail(bad)
                    vm.updateOpticsVignettingStrength(bad)
                }
            }

            // Assert all stored numeric properties remain strictly finite
            #expect(vm.simulatedHeadroom.multiplier.isFinite)
            #expect(vm.screenMaxEDR.isFinite)
            #expect(vm.activePreset.gainMapGamma.isFinite)
            #expect(vm.activePreset.midtoneAnchorP.isFinite)
            #expect(vm.activePreset.targetHeadroomStops.isFinite)
            #expect(vm.activePreset.developDefaults.exposureEV.isFinite)
            #expect(vm.activePreset.developDefaults.clarity.isFinite)
            #expect(vm.activePreset.developDefaults.opticalSharpness.isFinite)
            #expect(vm.activePreset.developDefaults.shadowRecovery.isFinite)
            #expect(vm.activePreset.developDefaults.blackPoint.isFinite)
            #expect(vm.activePreset.developDefaults.vibrance.isFinite)
            #expect(vm.activePreset.developDefaults.sdrExposureEV.isFinite)
            #expect(vm.activePreset.developDefaults.sdrHighlightCompression.isFinite)
            #expect(vm.activePreset.developDefaults.sdrContrast.isFinite)
            #expect(vm.activePreset.developDefaults.sdrSaturation.isFinite)
            #expect(vm.activePreset.developDefaults.hdrHighlightExcitation.isFinite)
            #expect(vm.activePreset.developDefaults.hdrRolloffSoftness.isFinite)

            let eff = vm.selectedEffectiveParams
            #expect(eff.develop.exposureEV.isFinite)
            #expect(eff.develop.shadowRecovery.isFinite)
            #expect(eff.develop.blackPoint.isFinite)
            #expect(eff.develop.clarity.isFinite)
            #expect(eff.develop.opticalSharpness.isFinite)
            #expect(eff.develop.vibrance.isFinite)
            #expect(eff.develop.sdrExposureEV.isFinite)
            #expect(eff.develop.sdrHighlightCompression.isFinite)
            #expect(eff.develop.sdrContrast.isFinite)
            #expect(eff.develop.sdrSaturation.isFinite)
            #expect(eff.develop.hdrHighlightExcitation.isFinite)
            #expect(eff.develop.hdrRolloffSoftness.isFinite)
            #expect(eff.targetHeadroom.log2Value.isFinite)
            #expect(eff.midtoneAnchorP.isFinite)
            #expect(eff.cropOffset.normalizedCenterX.isFinite)
            #expect(eff.cropOffset.normalizedCenterY.isFinite)
            #expect(eff.optics.vignettingStrength.isFinite)
            #expect(eff.denoise.luminanceStrength.isFinite)
            #expect(eff.denoise.chromaStrength.isFinite)
            #expect(eff.denoise.detailPreservation.isFinite)
            if case let .custom(k, t) = eff.develop.whiteBalance {
                #expect(k.isFinite && t.isFinite)
            }

            // PresetLoader.validate & JSON codecs must succeed and round-trip cleanly
            try PresetLoader.validate(vm.activePreset)

            let presetURL = tmpDir.appendingPathComponent("exported_preset.json")
            try PresetJSONCodec.exportPreset(vm.activePreset, to: presetURL)
            let reimportedPreset = try PresetJSONCodec.importPreset(from: presetURL)
            #expect(reimportedPreset.id == vm.activePreset.id)

            // Seed a finite delta so saveMap round-trips a non-empty delta alongside rejected non-finite writes
            vm.editScope = .perPhotoDelta
            vm.updateExposureEV(0.5)
            vm.updateExposureEV(.nan)
            let deltaURL = tmpDir.appendingPathComponent("deltas.json")
            let deltaMap = ["DSC00001.ARW": vm.perPhotoDeltas[fakeARW] ?? PerPhotoDelta()]
            try DeltaJSONCodec.saveMap(deltaMap, to: deltaURL)
            let reloadedMap = try DeltaJSONCodec.loadMap(from: deltaURL)
            #expect(reloadedMap["DSC00001.ARW"]?.exposureEVDelta == 0.5)
        }

        @Test("2. AppViewModel maxLongEdge and output format guardrails enforce even >= 64, <= 1920 for HLG MP4, and 8-bit 1ch JPEG+XMP")
        @MainActor
        func testAppViewModelMaxLongEdgeAndFormatGuardrails() throws {
            let (defaults, suiteName) = makeIsolatedDefaultsV11()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = AppViewModel(userDefaults: defaults)
            vm.workspaceMode = .pro
            vm.editScope = .globalPreset

            let douyin = try PresetLoader.loadBuiltIn(id: .douyinHLGMP4)
            let appleHEIC = try PresetLoader.loadBuiltIn(id: .appleHEIC)
            let triFormat = try PresetLoader.loadBuiltIn(id: .triFormat)

            vm.selectPreset(douyin)
            vm.updateMaxLongEdge(3841)
            let edgeAfter3841 = try #require(vm.activePreset.maxLongEdge)
            #expect(edgeAfter3841 <= 1920 && edgeAfter3841 >= 64 && edgeAfter3841 % 2 == 0)

            vm.updateMaxLongEdge(31)
            let edgeAfter31 = try #require(vm.activePreset.maxLongEdge)
            #expect(edgeAfter31 == 64)

            vm.selectPreset(appleHEIC)
            vm.toggleOutputFormat(.hlgMP4)
            vm.updateMaxLongEdge(4096)
            let edgeWithHLG = try #require(vm.activePreset.maxLongEdge)
            #expect(edgeWithHLG == 1920)
            vm.toggleOutputFormat(.heic)
            #expect(vm.activePreset.outputFormats == [.hlgMP4])
            #expect((vm.activePreset.maxLongEdge ?? 0) <= 1920)
            #expect(vm.activePreset.hlgVideoOptions != nil)

            vm.selectPreset(triFormat)
            vm.toggleOutputFormat(.heic)
            vm.toggleOutputFormat(.avif)
            #expect(Set(vm.activePreset.outputFormats) == [.jpeg])
            #expect(vm.activePreset.bitDepth == .bit8)
            if vm.activePreset.compatOptions.writeUltrahdrXMP {
                #expect(vm.activePreset.gainMapChannels == .mono1ch)
            }
        }

        @Test("3. ChiaroSidecar and PerPhotoDelta degrade unknown future enums and nested payloads gracefully without losing edits")
        func testChiaroSidecarPerPhotoDeltaForwardCompatibleUnknownEnums() throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-sidecar-fwd")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let rawURL = tmpDir.appendingPathComponent("DSC09991.ARW")
            let sidecarURL = ChiaroSidecar.sidecarURL(for: rawURL)

            let futureJSON = """
            {
              "schemaVersion": 2,
              "updatedAt": "2026-11-26T00:00:00Z",
              "delta": {
                "exposureEVDelta": 0.75,
                "clarityOverride": 20.0,
                "highlightReconstructionOverride": "future_ai_recon_v4",
                "sdrToneMapperOverride": "future_agx_v3",
                "cropAspectOverride": "future_21x9",
                "decodeBackendOverride": "future_gpu_raw",
                "demosaicOverride": "future_neural_bayer",
                "opticsOverride": {
                  "enabled": true,
                  "source": "future_ai_optics"
                },
                "denoiseOverride": {
                  "mode": "future_diffusion"
                },
                "aiColorOverride": "incompatible_string_payload"
              }
            }
            """
            try futureJSON.write(to: sidecarURL, atomically: true, encoding: .utf8)

            let loaded = try ChiaroSidecar.load(from: sidecarURL)
            let delta = try #require(loaded.delta)
            #expect(delta.exposureEVDelta == 0.75)
            #expect(delta.clarityOverride == 20.0)
            #expect(delta.highlightReconstructionOverride == nil)
            #expect(delta.sdrToneMapperOverride == nil)
            #expect(delta.cropAspectOverride == nil)
            #expect(delta.decodeBackendOverride == nil)
            #expect(delta.demosaicOverride == nil)
            #expect(delta.aiColorOverride == nil)
            #expect(delta.opticsOverride?.enabled == true)
            #expect(delta.opticsOverride?.source == .auto)
            #expect(delta.denoiseOverride?.mode == .off)
        }

        @Test("4. LiquidGlassSystem #111214 neutral canvas constants match linearized sRGB and ARW discovery rejects non-ARWs & fake .ARW dirs")
        func testDesignSystemNeutralCanvasHexAndARWOnlyDiscovery() throws {
            let liquidGlassURL = tier5V11RepoRoot
                .appendingPathComponent("App/DesignSystem/LiquidGlassSystem.swift")
            let sourceText = try String(contentsOf: liquidGlassURL, encoding: .utf8)

            #expect(sourceText.contains("neutralCanvasHex: String = \"#111214\""))
            #expect(sourceText.contains("neutralCanvasRed: Double = 0.067"))
            #expect(sourceText.contains("neutralCanvasGreen: Double = 0.071"))
            #expect(sourceText.contains("neutralCanvasBlue: Double = 0.078"))
            #expect(sourceText.contains("red: 0.005605"))
            #expect(sourceText.contains("green: 0.006049"))
            #expect(sourceText.contains("blue: 0.006995"))

            let srgb17 = 17.0 / 255.0
            let srgb18 = 18.0 / 255.0
            let srgb20 = 20.0 / 255.0
            #expect(abs(srgb17 - 0.067) < 1e-3)
            #expect(abs(srgb18 - 0.071) < 1e-3)
            #expect(abs(srgb20 - 0.078) < 1e-3)
            #expect(abs(sRGBToLinearV11(srgb17) - 0.005605) < 1e-4)
            #expect(abs(sRGBToLinearV11(srgb18) - 0.006049) < 1e-4)
            #expect(abs(sRGBToLinearV11(srgb20) - 0.006995) < 1e-4)

            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-arw-discovery")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let upperARW = tmpDir.appendingPathComponent("DSC00001.ARW")
            let lowerARW = tmpDir.appendingPathComponent("DSC00002.arw")
            let fakeDirARW = tmpDir.appendingPathComponent("Folder.ARW", isDirectory: true)
            try Data("arw1".utf8).write(to: upperARW)
            try Data("arw2".utf8).write(to: lowerARW)
            try FileManager.default.createDirectory(at: fakeDirARW, withIntermediateDirectories: true)
            for ext in ["HIF", "JPG", "CR3", "DNG"] {
                try Data("other".utf8).write(to: tmpDir.appendingPathComponent("IMG_0001.\(ext)"))
            }

            let discovered = ARWFileDiscovery.discover(urls: [tmpDir], recursive: true)
            let discoveredNames = discovered.map(\.lastPathComponent).sorted()
            #expect(discoveredNames == ["DSC00001.ARW", "DSC00002.arw"])
        }

        @Test("AppViewModel updateWhiteBalance clamps out-of-range custom Kelvin/tint to PresetLoader bounds")
        @MainActor
        func testUpdateWhiteBalanceClampsCustomKelvinAndTint() throws {
            let (defaults, suiteName) = makeIsolatedDefaultsV11()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = AppViewModel(userDefaults: defaults)
            vm.workspaceMode = .pro
            vm.editScope = .globalPreset
            vm.updateWhiteBalance(.custom(temperatureKelvin: 50000.0, tint: 500.0))
            #expect(vm.activePreset.developDefaults.whiteBalance == .custom(temperatureKelvin: 15000.0, tint: 150.0))
            try PresetLoader.validate(vm.activePreset)

            vm.updateWhiteBalance(.custom(temperatureKelvin: 500.0, tint: -500.0))
            #expect(vm.activePreset.developDefaults.whiteBalance == .custom(temperatureKelvin: 2000.0, tint: -150.0))
            try PresetLoader.validate(vm.activePreset)

            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-wb-clamp")
            defer { try? FileManager.default.removeItem(at: tmpDir) }
            let fakeARW = tmpDir.appendingPathComponent("DSC00002.ARW")
            try Data("FAKE_ARW".utf8).write(to: fakeARW)
            vm.autoSaveSidecar = false
            vm.importDroppedOrOpenedURLs([fakeARW])
            vm.editScope = .perPhotoDelta
            vm.updateWhiteBalance(.custom(temperatureKelvin: 99999.0, tint: -999.0))
            #expect(vm.perPhotoDeltas[fakeARW]?.whiteBalanceOverride == .custom(temperatureKelvin: 15000.0, tint: -150.0))
        }

        @Test("PerPhotoDelta and ChiaroSidecar survive scalar type mismatches and float-for-Int without wiping valid edits")
        func testSidecarAndDeltaSurviveScalarTypeMismatchAndFloatForInt() throws {
            let dir = try makeTier5V11TempDir(prefix: "tier5-v11-sidecar-scalar")
            defer { try? FileManager.default.removeItem(at: dir) }

            let arw1 = dir.appendingPathComponent("FLOAT_FOR_INT.ARW")
            let json1 = """
            {"schemaVersion":3,"updatedAt":"2026-11-26T00:00:00Z","delta":{"exposureEVDelta":0.5,"maxLongEdgeOverride":1920.5,"clearMaxLongEdgeOverride":"invalid","clarityOverride":18.0}}
            """
            try json1.write(to: ChiaroSidecar.sidecarURL(for: arw1), atomically: true, encoding: .utf8)
            let s1 = try #require(try ChiaroSidecar.loadIfExists(for: arw1))
            #expect(s1.delta?.exposureEVDelta == 0.5)
            #expect(s1.delta?.clarityOverride == 18.0)
            #expect(s1.delta?.maxLongEdgeOverride == nil)
            #expect(s1.delta?.clearMaxLongEdgeOverride == false)

            let arw2 = dir.appendingPathComponent("STRING_FOR_DOUBLE.ARW")
            let json2 = """
            {"schemaVersion":3,"updatedAt":"2026-11-26T00:00:00Z","optics":{"vignettingStrength":"bad"},"delta":{"exposureEVDelta":"bad","clarityOverride":18.0}}
            """
            try json2.write(to: ChiaroSidecar.sidecarURL(for: arw2), atomically: true, encoding: .utf8)
            let s2 = try #require(try ChiaroSidecar.loadIfExists(for: arw2))
            #expect(s2.optics == nil)
            #expect(s2.delta?.exposureEVDelta == nil)
            #expect(s2.delta?.clarityOverride == 18.0)
        }

        @Test("AppViewModel concurrent flushPendingSidecarSaves with deleteSidecar, removeItem, and clearQueue leaves zero stale sidecars")
        @MainActor
        func testAppViewModelConcurrentFlushAndDeleteRemoveClearRace() async throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-sidecar-race")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            for iteration in 0..<5 {
                // (a) Concurrent flushPendingSidecarSaves() + deleteSidecar(for:)
                do {
                    let (defaults, suiteName) = makeIsolatedDefaultsV11()
                    defer { defaults.removePersistentDomain(forName: suiteName) }

                    let arwURL = tmpDir.appendingPathComponent("RACE_DEL_\(iteration).ARW")
                    try Data("FAKE_ARW".utf8).write(to: arwURL)

                    let vm = AppViewModel(userDefaults: defaults)
                    vm.autoSaveSidecar = true
                    vm.importDroppedOrOpenedURLs([arwURL])
                    let item = try #require(vm.selectedItem)
                    vm.editScope = .perPhotoDelta
                    vm.updateExposureEV(0.75)

                    let flushTask = Task { @MainActor in
                        await vm.flushPendingSidecarSaves()
                    }
                    await Task.yield()
                    vm.deleteSidecar(for: item)
                    await flushTask.value

                    #expect(!ChiaroSidecar.exists(for: arwURL))
                    #expect(!vm.sidecarPresentURLs.contains(arwURL))
                    #expect(!vm.hasSidecar(for: item))
                    if let currentItem = vm.items.first {
                        #expect(!vm.hasSidecar(for: currentItem))
                    }
                }

                // (b) Concurrent flushPendingSidecarSaves() + removeItem(_:)
                do {
                    let (defaults, suiteName) = makeIsolatedDefaultsV11()
                    defer { defaults.removePersistentDomain(forName: suiteName) }

                    let arwURL = tmpDir.appendingPathComponent("RACE_REM_\(iteration).ARW")
                    try Data("FAKE_ARW".utf8).write(to: arwURL)

                    let vm = AppViewModel(userDefaults: defaults)
                    vm.autoSaveSidecar = true
                    vm.importDroppedOrOpenedURLs([arwURL])
                    let item = try #require(vm.selectedItem)
                    vm.editScope = .perPhotoDelta
                    vm.updateExposureEV(0.75)

                    let flushTask = Task { @MainActor in
                        await vm.flushPendingSidecarSaves()
                    }
                    await Task.yield()
                    vm.removeItem(item)
                    await flushTask.value

                    #expect(vm.items.isEmpty)
                    #expect(!ChiaroSidecar.exists(for: arwURL))
                    #expect(!vm.sidecarPresentURLs.contains(arwURL))
                    #expect(!vm.hasSidecar(for: item))
                }

                // (c) Concurrent flushPendingSidecarSaves() + clearQueue()
                do {
                    let (defaults, suiteName) = makeIsolatedDefaultsV11()
                    defer { defaults.removePersistentDomain(forName: suiteName) }

                    let arwURL = tmpDir.appendingPathComponent("RACE_CLR_\(iteration).ARW")
                    try Data("FAKE_ARW".utf8).write(to: arwURL)

                    let vm = AppViewModel(userDefaults: defaults)
                    vm.autoSaveSidecar = true
                    vm.importDroppedOrOpenedURLs([arwURL])
                    let item = try #require(vm.selectedItem)
                    vm.editScope = .perPhotoDelta
                    vm.updateExposureEV(0.75)

                    let flushTask = Task { @MainActor in
                        await vm.flushPendingSidecarSaves()
                    }
                    await Task.yield()
                    vm.clearQueue()
                    await flushTask.value

                    #expect(vm.items.isEmpty)
                    #expect(!ChiaroSidecar.exists(for: arwURL))
                    #expect(!vm.sidecarPresentURLs.contains(arwURL))
                    #expect(!vm.hasSidecar(for: item))
                }
            }
        }

        @Test("AppViewModel concurrent flushPendingSidecarSaves with interleaved edit persists latest delta without premature return")
        @MainActor
        func testAppViewModelConcurrentFlushWithSubsequentEditNeverReturnsPrematurely() async throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-flush-edit-race")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            for iteration in 0..<30 {
                let (defaults, suiteName) = makeIsolatedDefaultsV11()
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let arwURL = tmpDir.appendingPathComponent("FLUSH_EDIT_\(iteration).ARW")
                try Data("FAKE_ARW".utf8).write(to: arwURL)

                let vm = AppViewModel(userDefaults: defaults)
                vm.autoSaveSidecar = true
                vm.importDroppedOrOpenedURLs([arwURL])
                try #require(vm.selectedItem != nil)
                vm.editScope = .perPhotoDelta

                vm.updateExposureEV(1.0)
                let t1 = Task { @MainActor in
                    await vm.flushPendingSidecarSaves()
                }
                await Task.yield()
                vm.updateExposureEV(-1.25)
                let t2 = Task { @MainActor in
                    await vm.flushPendingSidecarSaves()
                }
                await t1.value
                await t2.value

                #expect(ChiaroSidecar.exists(for: arwURL))
                let loaded = try ChiaroSidecar.loadIfExists(for: arwURL)
                #expect(loaded?.delta?.exposureEVDelta == -1.25)
            }
        }

        @Test("AppViewModel deleteSidecar + autoSaveSidecar = false + edit during in-flight save never resurrects sidecar")
        @MainActor
        func testAppViewModelDeleteSidecarThenAutoSaveFalseAndEditNeverResurrectsSidecar() async throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-del-autosave-off")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            for iteration in 0..<30 {
                let (defaults, suiteName) = makeIsolatedDefaultsV11()
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let arwURL = tmpDir.appendingPathComponent("DEL_AUTOSAVE_OFF_\(iteration).ARW")
                try Data("FAKE_ARW".utf8).write(to: arwURL)

                let vm = AppViewModel(userDefaults: defaults)
                vm.autoSaveSidecar = true
                vm.importDroppedOrOpenedURLs([arwURL])
                let item = try #require(vm.selectedItem)
                vm.editScope = .perPhotoDelta

                vm.updateExposureEV(1.0)
                let flushTask = Task { @MainActor in
                    await vm.flushPendingSidecarSaves()
                }
                if iteration % 5 == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .microseconds((iteration % 5) * 35))
                }
                vm.deleteSidecar(for: item)
                vm.autoSaveSidecar = false
                vm.updateExposureEV(2.0)
                await flushTask.value

                #expect(!ChiaroSidecar.exists(for: arwURL))
                try #require(vm.items.count == 1)
                #expect(!vm.items[0].hasSidecar)
                #expect(!vm.hasSidecar(for: vm.items[0]))
            }
        }

        @Test("AppViewModel removeItem + immediate re-import during in-flight save keeps disk and queue state consistent")
        @MainActor
        func testAppViewModelRemoveAndImmediateReimportDuringInFlightSaveStaysConsistent() async throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-rem-reimport")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            for iteration in 0..<40 {
                let (defaults, suiteName) = makeIsolatedDefaultsV11()
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let arwURL = tmpDir.appendingPathComponent("REM_REIMPORT_\(iteration).ARW")
                try Data("FAKE_ARW".utf8).write(to: arwURL)

                let vm = AppViewModel(userDefaults: defaults)
                vm.autoSaveSidecar = true
                vm.importDroppedOrOpenedURLs([arwURL])
                let item = try #require(vm.selectedItem)
                vm.editScope = .perPhotoDelta

                vm.updateExposureEV(1.75)
                let flushTask = Task { @MainActor in
                    await vm.flushPendingSidecarSaves()
                }
                if iteration % 8 == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .microseconds((iteration % 8) * 20))
                }
                vm.removeItem(item)
                vm.importDroppedOrOpenedURLs([arwURL])
                await flushTask.value

                let diskExists = ChiaroSidecar.exists(for: arwURL)
                let uiHasSidecar = vm.items.first?.hasSidecar ?? false
                #expect(diskExists == uiHasSidecar)
                if diskExists {
                    #expect(vm.perPhotoDeltas[arwURL] != nil)
                } else {
                    #expect(vm.perPhotoDeltas[arwURL] == nil)
                }
            }
        }

        @Test("AppViewModel resetDelta + mid-flight autoSaveSidecar = false clears hasSidecar matching disk")
        @MainActor
        func testResetDeltaMidFlightAutoSaveDisabledSyncsUIWithDisk() async throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-reset-autosave-off")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            for iteration in 0..<50 {
                let (defaults, suiteName) = makeIsolatedDefaultsV11()
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let arwURL = tmpDir.appendingPathComponent("RESET_AUTOSAVE_OFF_\(iteration).ARW")
                try Data("FAKE_ARW".utf8).write(to: arwURL)
                try ChiaroSidecar.save(
                    ChiaroSidecar(delta: PerPhotoDelta(exposureEVDelta: 1.0)),
                    for: arwURL
                )

                let vm = AppViewModel(userDefaults: defaults)
                vm.autoSaveSidecar = true
                vm.importDroppedOrOpenedURLs([arwURL])
                let item = try #require(vm.selectedItem)
                #expect(vm.hasSidecar(for: item))

                vm.resetDelta(for: item)
                let flushTask = Task { @MainActor in
                    await vm.flushPendingSidecarSaves()
                }
                let jitterUs = (iteration * 53) % 1001
                if iteration % 6 == 0 || jitterUs == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .microseconds(jitterUs))
                }
                vm.autoSaveSidecar = false
                await flushTask.value
                await vm.flushPendingSidecarSaves()

                let currentItem = try #require(vm.items.first(where: { $0.sourceURL == arwURL }))
                let diskExists = ChiaroSidecar.exists(for: arwURL)
                #expect(vm.hasSidecar(for: currentItem) == diskExists)
                #expect(currentItem.hasSidecar == diskExists)
                #expect(vm.sidecarPresentURLs.contains(arwURL) == diskExists)
            }
        }

        @Test("AppViewModel mid-flight autoSaveSidecar = false keeps hasSidecar synced with written disk file")
        @MainActor
        func testFreshWriteMidFlightAutoSaveDisabledSyncsUIWithDisk() async throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-fresh-autosave-off")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            for iteration in 0..<100 {
                let (defaults, suiteName) = makeIsolatedDefaultsV11()
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let arwURL = tmpDir.appendingPathComponent("FRESH_AUTOSAVE_OFF_\(iteration).ARW")
                try Data("FAKE_ARW".utf8).write(to: arwURL)

                let vm = AppViewModel(userDefaults: defaults)
                vm.autoSaveSidecar = true
                vm.importDroppedOrOpenedURLs([arwURL])
                _ = try #require(vm.selectedItem)
                vm.editScope = .perPhotoDelta
                vm.updateExposureEV(1.5)

                let flushTask = Task { @MainActor in
                    await vm.flushPendingSidecarSaves()
                }
                let jitterUs = (iteration * 37) % 1001
                if iteration % 8 == 0 || jitterUs == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .microseconds(jitterUs))
                }
                vm.autoSaveSidecar = false
                await flushTask.value
                await vm.flushPendingSidecarSaves()

                let currentItem = try #require(vm.items.first(where: { $0.sourceURL == arwURL }))
                let diskExists = ChiaroSidecar.exists(for: arwURL)
                #expect(vm.hasSidecar(for: currentItem) == diskExists)
                #expect(currentItem.hasSidecar == diskExists)
                #expect(vm.sidecarPresentURLs.contains(arwURL) == diskExists)
            }
        }

        @Test("AppViewModel removeItem + immediate re-import with pre-existing sidecar never diverges disk vs memory")
        @MainActor
        func testRemoveAndReimportWithPreExistingSidecarNoTOCTOU() async throws {
            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-preexist-reimport")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            for iteration in 0..<100 {
                let (defaults, suiteName) = makeIsolatedDefaultsV11()
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let arwURL = tmpDir.appendingPathComponent("PRE_REIMPORT_\(iteration).ARW")
                try Data("FAKE_ARW".utf8).write(to: arwURL)
                try ChiaroSidecar.save(
                    ChiaroSidecar(delta: PerPhotoDelta(exposureEVDelta: 1.0)),
                    for: arwURL
                )

                let vm = AppViewModel(userDefaults: defaults)
                vm.autoSaveSidecar = true
                vm.importDroppedOrOpenedURLs([arwURL])
                let item = try #require(vm.selectedItem)
                #expect(vm.perPhotoDeltas[arwURL]?.exposureEVDelta == 1.0)

                vm.editScope = .perPhotoDelta
                vm.updateExposureEV(2.5)
                let flushTask = Task { @MainActor in
                    await vm.flushPendingSidecarSaves()
                }
                let jitterUs = (iteration * 41) % 1001
                if iteration % 8 == 0 || jitterUs == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .microseconds(jitterUs))
                }
                vm.removeItem(item)
                vm.importDroppedOrOpenedURLs([arwURL])
                await flushTask.value
                await vm.flushPendingSidecarSaves()

                let currentItem = try #require(vm.items.first(where: { $0.sourceURL == arwURL }))
                let diskSidecar = try ChiaroSidecar.loadIfExists(for: arwURL)
                let diskExists = ChiaroSidecar.exists(for: arwURL)
                #expect(diskSidecar?.delta?.exposureEVDelta == vm.perPhotoDeltas[arwURL]?.exposureEVDelta)
                #expect(vm.hasSidecar(for: currentItem) == diskExists)
                #expect(currentItem.hasSidecar == diskExists)
            }
        }
    }

    // MARK: - Suite 2: Tier5V11OpticsAndDenoiseTests

    @Suite("Tier5V11OpticsAndDenoiseTests", .serialized)
    struct Tier5V11OpticsAndDenoiseTests {

        @Test("5. CLensfunBridge explicit lensfunCameraOverride is not clobbered by Sony APS-C fallback")
        func testLensfunCameraOverrideNotClobberedBySonyAPSCFallback() throws {
            let provider = LensfunOpticsProvider.shared
            let sonyLenses = provider.availableLenses(mountFilter: "Sony E")
            let firstSonyLens = try #require(sonyLenses.first)

            let canonMatch = try #require(provider.resolveMatch(
                make: "SONY",
                model: "ILCE-7CM2",
                lensMake: "SONY",
                lensModel: firstSonyLens,
                cropFactor: 1.5,
                params: OpticalCorrectionParameters(
                    enabled: true,
                    source: .lensfun,
                    lensfunCameraOverride: "Canon EOS 5D Mark IV",
                    lensfunLensOverride: firstSonyLens
                )
            ))
            #expect(canonMatch.isSonyEFallback == false)
            #expect(canonMatch.cameraMatched.contains("5D Mark IV"))
            #expect(canonMatch.resolvedCropFactor < 1.30)

            let sonyFFMatch = try #require(provider.resolveMatch(
                make: "SONY",
                model: "ILCE-7CM2",
                lensMake: "SONY",
                lensModel: firstSonyLens,
                cropFactor: 1.5,
                params: OpticalCorrectionParameters(
                    enabled: true,
                    source: .lensfun,
                    lensfunCameraOverride: "Sony ILCE-7M4",
                    lensfunLensOverride: firstSonyLens
                )
            ))
            #expect(sonyFFMatch.isSonyEFallback == false)
            #expect(sonyFFMatch.cameraMatched.contains("ILCE-7M4"))
            #expect(sonyFFMatch.resolvedCropFactor < 1.30)
        }

        @Test("6. Lensfun computeLUT rejects 1x1, survives NaN/0 boundary inputs, and resolveOpticsInfo returns .none when zero Lensfun ops apply")
        func testLensfunComputeLUTBoundaryInputsAndResolveOpticsInfoShortCircuit() throws {
            let provider = LensfunOpticsProvider.shared
            let firstSonyLens = try #require(provider.availableLenses(mountFilter: "Sony E").first)

            let params = OpticalCorrectionParameters(
                enabled: true,
                source: .lensfun,
                lensfunLensOverride: firstSonyLens
            )

            // width <= 1 returns nil
            let tinyLUT = provider.computeLUT(
                make: "SONY",
                model: "ILCE-7CM2",
                lensMake: "SONY",
                lensModel: firstSonyLens,
                focalLengthMM: 35.0,
                apertureFNumber: 2.8,
                cropFactor: 1.0,
                width: 1,
                height: 1,
                params: params
            )
            #expect(tinyLUT == nil)

            // Invalid focal/aperture/crop inputs still return finite LUTs
            let boundaryCases: [(focal: Double?, aperture: Double?, crop: Double)] = [
                (nil, nil, 0.0),
                (0.0, 0.0, -1.5),
                (-10.0, .nan, .nan),
                (.nan, 2.8, 1.0),
            ]
            for b in boundaryCases {
                let res = try #require(provider.computeLUT(
                    make: "SONY",
                    model: "ILCE-7CM2",
                    lensMake: "SONY",
                    lensModel: firstSonyLens,
                    focalLengthMM: b.focal,
                    apertureFNumber: b.aperture,
                    cropFactor: b.crop,
                    width: 128,
                    height: 96,
                    lutWidth: 32,
                    lutHeight: 24,
                    params: params
                ))
                #expect(res.lut.warpRGBUV.allSatisfy { $0.isFinite })
                #expect(res.lut.vignettingGain.allSatisfy { $0.isFinite })
            }

            // Custom Lensfun XML with ONLY <vignetting> (hasDistortion=false, hasTCA=false, hasVignetting=true)
            let xmlDir = try makeTier5V11TempDir(prefix: "tier5-v11-vigonly-xml")
            defer { try? FileManager.default.removeItem(at: xmlDir) }

            let customXML = """
            <lensdatabase version="1">
                <mount>
                    <name>Sony E</name>
                </mount>
                <camera>
                    <maker>Sony</maker>
                    <model>ILCE-7CM2</model>
                    <mount>Sony E</mount>
                    <cropfactor>1.0</cropfactor>
                </camera>
                <lens>
                    <maker>ChiaroTest</maker>
                    <model>Chiaro VignetteOnly 50mm F2</model>
                    <mount>Sony E</mount>
                    <cropfactor>1.0</cropfactor>
                    <calibration>
                        <vignetting model="pa" focal="50" aperture="2.0" distance="1000" k1="-0.3" k2="0.1" k3="0.0"/>
                    </calibration>
                </lens>
            </lensdatabase>
            """
            try customXML.write(to: xmlDir.appendingPathComponent("vig_only.xml"), atomically: true, encoding: .utf8)

            let vigOnlyProvider = LensfunOpticsProvider(primaryDatabaseURL: xmlDir, userDatabaseURL: nil)
            let vigFrame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/VIG_ONLY.ARW"),
                backendUsed: .libraw,
                payload: .rawBayer(width: 8, height: 8, bitsPerSample: 14, cfa: .rggb, data: Data(count: 8 * 8 * 2)),
                visibleCrop: SensorCropRect(x: 0, y: 0, width: 8, height: 8),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif(
                    make: "Sony",
                    model: "ILCE-7CM2",
                    lensMake: "ChiaroTest",
                    lensModel: "Chiaro VignetteOnly 50mm F2",
                    focalLengthMM: 50.0,
                    fNumber: 2.0
                ),
                cropFactor: 1.0
            )

            // Vignetting disabled -> zero Lensfun corrections will execute -> must resolve to .none
            let infoVigOff = OpticsPipelineEngine.resolveOpticsInfo(
                frame: vigFrame,
                params: OpticalCorrectionParameters(
                    enabled: true,
                    source: .lensfun,
                    distortion: true,
                    tca: true,
                    vignetting: false
                ),
                provider: vigOnlyProvider
            )
            #expect(infoVigOff == .none)

            // Vignetting enabled with strength 0.0 preserves .lensfun + vignettingApplied == false contract
            let infoVigZeroStrength = OpticsPipelineEngine.resolveOpticsInfo(
                frame: vigFrame,
                params: OpticalCorrectionParameters(
                    enabled: true,
                    source: .lensfun,
                    distortion: false,
                    tca: false,
                    vignetting: true,
                    vignettingStrength: 0.0
                ),
                provider: vigOnlyProvider
            )
            #expect(infoVigZeroStrength.source == .lensfun)
            #expect(infoVigZeroStrength.vignettingApplied == false)
        }

        @Test("7. EmbeddedSonyOpticsEvaluator handles mismatched distortionNodeCount/caNodeCount and 1-node/Int16 boundary curves")
        func testEmbeddedSonyOpticsMismatchedNodeCountsAndSingleNodeBoundaries() {
            let payload = EmbeddedSonyOpticsPayload(
                distortionNodeCount: 16,
                distortionParams: (0..<16).map { Int16($0 * 50) },
                caNodeCount: 11,
                caRedParams: (0..<11).map { Int16($0 * 25) },
                caBlueParams: (0..<11).map { Int16(-$0 * 20) },
                vignettingNodeCount: 16,
                vignettingParams: (0..<16).map { Int16($0 * 80) },
                focalLengthMM: 49.0,
                fNumber: 4.0,
                sensorAspectRatio: 1.5,
                cropFactor: 1.0
            )

            let lutDistAndTCA = EmbeddedSonyOpticsEvaluator.computeLUT(
                payload: payload,
                width: 6000,
                height: 4000,
                lutWidth: 64,
                lutHeight: 48,
                distortion: true,
                autoScale: false,
                tca: true,
                vignetting: true
            )
            let lutDistOnly = EmbeddedSonyOpticsEvaluator.computeLUT(
                payload: payload,
                width: 6000,
                height: 4000,
                lutWidth: 64,
                lutHeight: 48,
                distortion: true,
                autoScale: false,
                tca: false,
                vignetting: true
            )

            let sliceFloats = lutDistAndTCA.lutWidth * lutDistAndTCA.lutHeight * 2
            var maxGreenDiff: Float = 0.0
            for i in 0..<sliceFloats {
                let gBoth = lutDistAndTCA.warpRGBUV[sliceFloats + i]
                let gOnly = lutDistOnly.warpRGBUV[sliceFloats + i]
                maxGreenDiff = max(maxGreenDiff, abs(gBoth - gOnly))
            }
            #expect(maxGreenDiff < 1e-6, "Green distortion warp differed by \(maxGreenDiff) when TCA enabled")

            // 1-node and extreme Int16.min/Int16.max boundary curves
            let singleNodePayload = EmbeddedSonyOpticsPayload(
                distortionNodeCount: 1,
                distortionParams: [Int16.max],
                caNodeCount: 1,
                caRedParams: [Int16.min],
                caBlueParams: [Int16.max],
                vignettingNodeCount: 2,
                vignettingParams: [Int16.min, Int16.max]
            )
            let boundaryLUT = EmbeddedSonyOpticsEvaluator.computeLUT(
                payload: singleNodePayload,
                width: 1000,
                height: 1000,
                lutWidth: 16,
                lutHeight: 16,
                distortion: true,
                autoScale: true,
                tca: true,
                vignetting: true
            )
            #expect(boundaryLUT.warpRGBUV.allSatisfy { $0.isFinite })
            #expect(boundaryLUT.vignettingGain.allSatisfy { val in
                val.isFinite && val >= Float16(0.25) && val <= Float16(8.0)
            })

            for badStrength in [-1.0, 0.0, 2.0, .nan] {
                let sanitized = OpticalCorrectionParameters(vignettingStrength: badStrength).sanitized()
                #expect(sanitized.vignettingStrength.isFinite)
                #expect(sanitized.vignettingStrength >= 0.0 && sanitized.vignettingStrength <= 1.0)
            }
        }

        @Test("8. ProfiledWaveletDenoiseStage luma-only, chroma-only, extreme ISO 204800, odd dims, and CIRAWv9 preferANE bypass")
        func testProfiledWaveletDenoiseLumaOnlyChromaOnlyAndExtremeISO() async throws {
            let dev = try #require(MTLCreateSystemDefaultDevice())
            let queue = try #require(dev.makeCommandQueue())
            let stage = try ProfiledWaveletDenoiseStage(device: dev)
            let profile = try #require(SensorNoiseProfileLoader.shared.profile(forMake: "SONY", model: "ILCE-7CM2"))

            let w = 64, h = 64
            var rgba = [Float](repeating: 0, count: w * h * 4)
            var rng: UInt64 = 0xCAFEBABEDEADBEEF
            func nextGaussian() -> Float {
                func nextU() -> Double {
                    rng ^= rng >> 12
                    rng ^= rng << 25
                    rng ^= rng >> 27
                    let val = rng &* 0x2545F4914F6CDD1D
                    return Double(val >> 11) / Double(1 << 53)
                }
                let u1 = max(nextU(), 1e-12)
                let u2 = nextU()
                return Float(sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2))
            }

            let coeffs = try #require(profile.interpolatedParameters(forISO: 12800))
            let base: Float = 0.14
            let stdR = Float(sqrt(coeffs.a.x * Double(base) + coeffs.b.x))
            let stdG = Float(sqrt(coeffs.a.y * Double(base) + coeffs.b.y))
            let stdB = Float(sqrt(coeffs.a.z * Double(base) + coeffs.b.z))
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    rgba[i + 0] = max(base + stdR * nextGaussian(), 0.001)
                    rgba[i + 1] = max(base + stdG * nextGaussian(), 0.001)
                    rgba[i + 2] = max(base + stdB * nextGaussian(), 0.001)
                    rgba[i + 3] = 1.0
                }
            }

            let noisyTex = try makeRGBA16FTextureV11(device: dev, width: w, height: h, rgba: rgba)

            func stats(_ tex: any MTLTexture) throws -> (lumaVar: Double, chromaVar: Double, allFiniteNonNeg: Bool) {
                let px = try readRGBA16FPixelsV11(device: dev, commandQueue: queue, texture: tex)
                var lumas: [Double] = []
                var rg: [Double] = []
                var bg: [Double] = []
                for y in 4..<(h - 4) {
                    for x in 4..<(w - 4) {
                        let off = (y * w + x) * 4
                        let r = px[off], g = px[off + 1], b = px[off + 2]
                        guard r.isFinite && g.isFinite && b.isFinite && r >= 0 && g >= 0 && b >= 0 else {
                            return (0, 0, false)
                        }
                        lumas.append(0.2627 * Double(r) + 0.6780 * Double(g) + 0.0593 * Double(b))
                        rg.append(Double(r - g))
                        bg.append(Double(b - g))
                    }
                }
                func variance(_ arr: [Double]) -> Double {
                    let mean = arr.reduce(0, +) / Double(max(arr.count, 1))
                    return arr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(arr.count, 1))
                }
                return (variance(lumas), variance(rg) + variance(bg), true)
            }

            let baseStats = try stats(noisyTex)
            #expect(baseStats.allFiniteNonNeg)

            // (a) lumaOnly
            let lumaOnlyTex = try await stage.denoise(
                inputTexture: noisyTex,
                iso: 12800,
                noiseProfile: profile,
                params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 80, chromaStrength: 0),
                commandQueue: queue
            )
            let lumaStats = try stats(lumaOnlyTex)
            #expect(lumaStats.allFiniteNonNeg)
            #expect(lumaStats.lumaVar < baseStats.lumaVar * 0.75)

            // (b) chromaOnly
            let chromaOnlyTex = try await stage.denoise(
                inputTexture: noisyTex,
                iso: 12800,
                noiseProfile: profile,
                params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 0, chromaStrength: 80),
                commandQueue: queue
            )
            let chromaStats = try stats(chromaOnlyTex)
            #expect(chromaStats.allFiniteNonNeg)
            #expect(chromaStats.chromaVar < baseStats.chromaVar * 0.70)
            #expect(chromaStats.lumaVar > lumaStats.lumaVar)
            #expect(lumaStats.chromaVar > chromaStats.chromaVar)

            // (c) both 80
            let bothTex = try await stage.denoise(
                inputTexture: noisyTex,
                iso: 12800,
                noiseProfile: profile,
                params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 80, chromaStrength: 80),
                commandQueue: queue
            )
            let bothStats = try stats(bothTex)
            #expect(bothStats.allFiniteNonNeg)
            #expect(bothStats.lumaVar < baseStats.lumaVar * 0.75)
            #expect(bothStats.chromaVar < baseStats.chromaVar * 0.70)

            // (d) ISO 204800 (negative b), ISO 0, ISO -50, Sony fallback, and 1x1 / 3x5 odd dims
            let fallbackProfile = SensorNoiseProfileLoader.shared.profileWithSonyFallback(
                forMake: "SONY",
                model: "UNKNOWN_SONY"
            )
            #expect(fallbackProfile?.model == "ILCE-7CM2")

            for isoVal in [204800, 0, -50] {
                let extremeTex = try await stage.denoise(
                    inputTexture: noisyTex,
                    iso: isoVal,
                    noiseProfile: fallbackProfile,
                    params: .default,
                    commandQueue: queue
                )
                let exStats = try stats(extremeTex)
                #expect(exStats.allFiniteNonNeg, "Non-finite/negative output at ISO \(isoVal)")
            }

            for (ow, oh) in [(1, 1), (3, 5)] {
                let oddRGBA = [Float](repeating: 0.25, count: ow * oh * 4)
                let oddTex = try makeRGBA16FTextureV11(device: dev, width: ow, height: oh, rgba: oddRGBA)
                let outOdd = try await stage.denoise(
                    inputTexture: oddTex,
                    iso: 204800,
                    noiseProfile: profile,
                    params: .default,
                    commandQueue: queue
                )
                let oddPx = try readRGBA16FPixelsV11(device: dev, commandQueue: queue, texture: outOdd)
                #expect(oddPx.allSatisfy { $0.isFinite && $0 >= 0.0 })
            }

            // (e) coreMLANE with preferANE true vs false on ciraw9 frame via MetalPipelineEngine
            let spy = SpyLinearDenoiseStage()
            let engine = try MetalPipelineEngine(device: dev, denoiseStage: spy)
            let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
            let cirawFrame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/CIRAW_TEST.ARW"),
                backendUsed: .ciraw9,
                payload: .linearRGB16F(
                    width: 4,
                    height: 4,
                    colorSpace: .linearRec2020,
                    data: makeLinearRGB16FDataV11(rgb: [Float](repeating: 0.25, count: 4 * 4 * 3))
                ),
                visibleCrop: SensorCropRect(x: 0, y: 0, width: 4, height: 4),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif(make: "SONY", model: "ILCE-7CM2")
            )

            var paramsPreferANE = EffectiveDevelopParams.resolve(preset: preset)
            paramsPreferANE.denoise = DenoiseParameters(mode: .coreMLANE, preferANE: true)
            _ = try await engine.render(frame: cirawFrame, params: paramsPreferANE, outputSpec: RenderOutputSpec())
            #expect(spy.callCount == 0)

            var paramsNoANE = EffectiveDevelopParams.resolve(preset: preset)
            paramsNoANE.denoise = DenoiseParameters(mode: .coreMLANE, preferANE: false)
            _ = try await engine.render(frame: cirawFrame, params: paramsNoANE, outputSpec: RenderOutputSpec())
            #expect(spy.callCount == 1)
        }

        @Test("OpticsPipelineEngine and MetalPipelineEngine bypass Lensfun cleanly on 1x1, 1x32, and 32x1 frames")
        func testSub2pxLensfunFramesRenderCleanlyWithoutThrowing() async throws {
            let dev = try #require(MTLCreateSystemDefaultDevice())
            let queue = try #require(dev.makeCommandQueue())
            let opticsEngine = try OpticsPipelineEngine(device: dev)
            let metalEngine = try MetalPipelineEngine(device: dev)
            let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

            let opticsParams = OpticalCorrectionParameters(
                enabled: true,
                source: .lensfun,
                lensfunCameraOverride: "ILCE-7CM2",
                lensfunLensOverride: "Auto Chinon 35mm f/2.8",
                distortion: true,
                autoScale: true,
                tca: true,
                vignetting: true,
                vignettingStrength: 1.0
            )

            var delta = PerPhotoDelta()
            delta.opticsOverride = opticsParams
            let effectiveParams = EffectiveDevelopParams.resolve(preset: preset, delta: delta)

            for (w, h) in [(1, 1), (1, 32), (32, 1)] {
                let frame = DecodedRAWFrame(
                    sourceURL: URL(fileURLWithPath: "/tmp/LENSFUN_\(w)x\(h).ARW"),
                    backendUsed: .libraw,
                    payload: .linearRGB16F(
                        width: w,
                        height: h,
                        colorSpace: .linearRec2020,
                        data: makeLinearRGB16FDataV11(rgb: [Float](repeating: 0.35, count: w * h * 3))
                    ),
                    visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
                    orientation: 1,
                    colorMatrices: CameraColorMatrices(),
                    isLosslessMS: false,
                    exif: WhitelistedExif(
                        make: "SONY",
                        model: "ILCE-7CM2",
                        lensModel: "Auto Chinon 35mm f/2.8",
                        focalLengthMM: 35.0,
                        fNumber: 4.0
                    ),
                    cropFactor: 1.0
                )

                // Confirm Lensfun actually resolves this camera/lens pair
                let resolved = opticsEngine.resolveOptics(frame: frame, params: opticsParams)
                #expect(resolved.source == .lensfun)

                // Direct OpticsPipelineEngine.applyCorrection bypasses cleanly
                let tex = try makeRGBA16FTextureV11(
                    device: dev,
                    width: w,
                    height: h,
                    rgba: Array(repeating: [Float(0.35), Float(0.35), Float(0.35), Float(1.0)], count: w * h).flatMap { $0 }
                )
                let (outTex, appliedRes) = try await opticsEngine.applyCorrection(
                    inputTexture: tex,
                    frame: frame,
                    params: opticsParams,
                    commandQueue: queue
                )
                #expect(appliedRes == .none)
                #expect(outTex === tex)

                // Full MetalPipelineEngine.render succeeds with finite pixels
                let rendered = try await metalEngine.render(
                    frame: frame,
                    params: effectiveParams,
                    outputSpec: RenderOutputSpec(targetBitDepth: .bit8, baseColorSpace: .displayP3)
                )
                let sdrTex = try #require(rendered.sdrLinearTexture?.texture)
                let hdrTex = try #require(rendered.hdrLinearTexture?.texture)
                #expect(try readRGBA16FPixelsV11(device: dev, commandQueue: queue, texture: sdrTex).allSatisfy { $0.isFinite })
                #expect(try readRGBA16FPixelsV11(device: dev, commandQueue: queue, texture: hdrTex).allSatisfy { $0.isFinite })
            }
        }

        @Test("OpticsPipelineEngine invalidates cached Lensfun LUT across importCustomXML and reloadUserDatabase")
        func testOpticsPipelineEngineInvalidatesLUTCacheOnLensfunXMLReload() async throws {
            let dev = try #require(MTLCreateSystemDefaultDevice())
            let queue = try #require(dev.makeCommandQueue())

            let tmpDir = try makeTier5V11TempDir(prefix: "tier5-v11-lensfun-cache-gen")
            defer { try? FileManager.default.removeItem(at: tmpDir) }
            let userDB = tmpDir.appendingPathComponent("user_db", isDirectory: true)
            let srcXML = tmpDir.appendingPathComponent("custom_test_lens.xml")

            let provider = LensfunOpticsProvider(userDatabaseURL: userDB)
            let opticsEngine = try OpticsPipelineEngine(device: dev, lensfunProvider: provider)

            func makeCustomXML(k1: Double, k2: Double) -> String {
                """
                <lensdatabase version="1">
                    <mount>
                        <name>Sony E</name>
                    </mount>
                    <camera>
                        <maker>Sony</maker>
                        <model>ILCE-7CM2</model>
                        <mount>Sony E</mount>
                        <cropfactor>1.0</cropfactor>
                    </camera>
                    <lens>
                        <maker>ChiaroCacheTest</maker>
                        <model>Chiaro CacheTest 50mm F2</model>
                        <mount>Sony E</mount>
                        <cropfactor>1.0</cropfactor>
                        <calibration>
                            <vignetting model="pa" focal="50" aperture="2.0" distance="1000" k1="\(k1)" k2="\(k2)" k3="0.0"/>
                        </calibration>
                    </lens>
                </lensdatabase>
                """
            }

            let w = 64, h = 64
            let frame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/CACHE_GEN_TEST.ARW"),
                backendUsed: .libraw,
                payload: .linearRGB16F(
                    width: w,
                    height: h,
                    colorSpace: .linearRec2020,
                    data: makeLinearRGB16FDataV11(rgb: [Float](repeating: 0.5, count: w * h * 3))
                ),
                visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif(
                    make: "Sony",
                    model: "ILCE-7CM2",
                    lensMake: "ChiaroCacheTest",
                    lensModel: "Chiaro CacheTest 50mm F2",
                    focalLengthMM: 50.0,
                    fNumber: 2.0
                ),
                cropFactor: 1.0
            )
            let params = OpticalCorrectionParameters(
                enabled: true,
                source: .lensfun,
                distortion: false,
                autoScale: false,
                tca: false,
                vignetting: true,
                vignettingStrength: 1.0
            )

            let inTex = try makeRGBA16FTextureV11(
                device: dev,
                width: w,
                height: h,
                rgba: Array(repeating: [Float(0.5), Float(0.5), Float(0.5), Float(1.0)], count: w * h).flatMap { $0 }
            )

            // Import XML A (k1 = -0.3, k2 = 0.1)
            let gen0 = provider.databaseGeneration
            try makeCustomXML(k1: -0.3, k2: 0.1).write(to: srcXML, atomically: true, encoding: .utf8)
            try provider.importCustomXML(from: srcXML)
            let gen1 = provider.databaseGeneration
            #expect(gen1 > gen0)

            let (texA, resA) = try await opticsEngine.applyCorrection(
                inputTexture: inTex,
                frame: frame,
                params: params,
                commandQueue: queue
            )
            #expect(resA.source == .lensfun)
            let pxA = try readRGBA16FPixelsV11(device: dev, commandQueue: queue, texture: texA)
            let cornerA = pxA[0]

            // Overwrite & import XML B (k1 = -0.8, k2 = 0.0) on the SAME provider & OpticsPipelineEngine
            try makeCustomXML(k1: -0.8, k2: 0.0).write(to: srcXML, atomically: true, encoding: .utf8)
            try provider.importCustomXML(from: srcXML)
            let gen2 = provider.databaseGeneration
            #expect(gen2 > gen1)

            let (texB, resB) = try await opticsEngine.applyCorrection(
                inputTexture: inTex,
                frame: frame,
                params: params,
                commandQueue: queue
            )
            #expect(resB.source == .lensfun)
            let pxB = try readRGBA16FPixelsV11(device: dev, commandQueue: queue, texture: texB)
            let cornerB = pxB[0]

            #expect(cornerA.isFinite && cornerB.isFinite)
            #expect(abs(cornerA - cornerB) > 0.25, "Expected LUT cache invalidation on XML reload, got cornerA=\(cornerA), cornerB=\(cornerB)")
        }
    }

    // MARK: - Suite 3: Tier5V11MetalPipelineAndBatchTests

    @Suite("Tier5V11MetalPipelineAndBatchTests", .serialized)
    struct Tier5V11MetalPipelineAndBatchTests {

        @Test("9. Sigmoid extreme 65000 uniform HDR gain map preserves headroom, 1x1/3x5 stages & whiteLevel==blackLevel stay finite")
        func testSigmoidExtremeHighlightUniformHDRGainMapAndOdd1x1Stages() async throws {
            let dev = try #require(MTLCreateSystemDefaultDevice())
            let engine = try MetalPipelineEngine(device: dev)
            let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

            // (a) Uniform 8x8 (65000, 65000, 65000) frame with .sigmoid
            let wA = 8, hA = 8
            let brightFrame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/UNIFORM_65000.ARW"),
                backendUsed: .libraw,
                payload: .linearRGB16F(
                    width: wA,
                    height: hA,
                    colorSpace: .linearRec2020,
                    data: makeLinearRGB16FDataV11(rgb: [Float](repeating: 65000.0, count: wA * hA * 3))
                ),
                visibleCrop: SensorCropRect(x: 0, y: 0, width: wA, height: hA),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif()
            )
            var brightDelta = PerPhotoDelta()
            brightDelta.sdrToneMapperOverride = .sigmoid
            brightDelta.midtoneAnchorPOverride = 0.95
            brightDelta.sdrHighlightCompressionOverride = 100.0
            brightDelta.targetHeadroomStopsOverride = 2.5
            let brightParams = EffectiveDevelopParams.resolve(preset: preset, delta: brightDelta)

            let renderedBright = try await engine.render(
                frame: brightFrame,
                params: brightParams,
                outputSpec: RenderOutputSpec(
                    targetBitDepth: .bit8,
                    baseColorSpace: .displayP3,
                    gainMapChannels: .rgb3ch,
                    gainMapResolution: .half,
                    gainMapGamma: 1.0
                )
            )
            let sdrTex = try #require(renderedBright.sdrLinearTexture?.texture)
            let hdrTex = try #require(renderedBright.hdrLinearTexture?.texture)
            let sdrPx = try readRGBA16FPixelsV11(device: dev, commandQueue: engine.commandQueue, texture: sdrTex)
            let hdrPx = try readRGBA16FPixelsV11(device: dev, commandQueue: engine.commandQueue, texture: hdrTex)
            #expect(sdrPx.allSatisfy { $0.isFinite })
            #expect(hdrPx.allSatisfy { $0.isFinite })

            let gm = renderedBright.gainMap
            #expect(gm.metadata.gainMapMin.allSatisfy { $0.isFinite })
            #expect(gm.metadata.gainMapMax.allSatisfy { $0.isFinite })
            for c in 0..<3 {
                #expect(gm.metadata.gainMapMin[c] <= gm.metadata.gainMapMax[c])
                #expect(gm.metadata.gainMapMax[c] > 2.0, "Uniform HDR gain collapsed: \(gm.metadata.gainMapMax)")
            }
            let reconstructed = decodeISOGainMapPixelV11(
                sdrLin: [Double(sdrPx[0]), Double(sdrPx[1]), Double(sdrPx[2])],
                gmBuffer: gm.buffer,
                metadata: gm.metadata,
                gx: 0,
                gy: 0
            )
            #expect(reconstructed.allSatisfy { $0.isFinite && $0 >= 5.0 })

            // Also verify uniform negative gain preserves gainMapMin < 0, gainMapMax == 0
            let uniformSdrTex = try makeRGBA16FTextureV11(
                device: dev,
                width: 4,
                height: 4,
                rgba: Array(repeating: [Float(0.8), Float(0.8), Float(0.8), Float(1.0)], count: 16).flatMap { $0 }
            )
            let uniformDimHdrTex = try makeRGBA16FTextureV11(
                device: dev,
                width: 4,
                height: 4,
                rgba: Array(repeating: [Float(0.2), Float(0.2), Float(0.2), Float(1.0)], count: 16).flatMap { $0 }
            )
            let negRes = try engine.gainMapSynthesizer.synthesize(
                commandQueue: engine.commandQueue,
                sdrLinearTexture: SendableMTLTexture(uniformSdrTex),
                hdrLinearTexture: SendableMTLTexture(uniformDimHdrTex),
                baseColorSpace: .displayP3,
                targetHeadroom: HeadroomStops(log2Value: 2.5),
                midtoneAnchorP: 0.80,
                gamma: 1.0,
                channels: .rgb3ch,
                resolution: .full,
                lockLegacyBounds: false
            )
            for c in 0..<3 {
                #expect(negRes.metadata.gainMapMin[c] < -1.0)
                #expect(negRes.metadata.gainMapMax[c] == 0.0)
                #expect(negRes.metadata.gainMapMin[c] <= negRes.metadata.gainMapMax[c])
            }

            // (b) 1x1 and 3x5 frames with orientation=8, cropAspect=.ratio3x4, denoise, optics, opticalSharpness=100, clarity=100
            for (ow, oh) in [(1, 1), (3, 5)] {
                let oddFrame = DecodedRAWFrame(
                    sourceURL: URL(fileURLWithPath: "/tmp/ODD_\(ow)x\(oh).ARW"),
                    backendUsed: .libraw,
                    payload: .linearRGB16F(
                        width: ow,
                        height: oh,
                        colorSpace: .linearRec2020,
                        data: makeLinearRGB16FDataV11(rgb: [Float](repeating: 0.45, count: ow * oh * 3))
                    ),
                    visibleCrop: SensorCropRect(x: 0, y: 0, width: ow, height: oh),
                    orientation: 8,
                    colorMatrices: CameraColorMatrices(),
                    isLosslessMS: false,
                    exif: WhitelistedExif(make: "SONY", model: "ILCE-7CM2", isoSpeedRatings: 6400)
                )
                var oddDelta = PerPhotoDelta()
                oddDelta.cropAspectOverride = .ratio3x4
                oddDelta.denoiseOverride = .default
                oddDelta.opticsOverride = .default
                oddDelta.opticalSharpnessOverride = 100.0
                oddDelta.clarityOverride = 100.0
                let oddParams = EffectiveDevelopParams.resolve(preset: preset, delta: oddDelta)

                let oddRendered = try await engine.render(
                    frame: oddFrame,
                    params: oddParams,
                    outputSpec: RenderOutputSpec(targetBitDepth: .bit8, baseColorSpace: .displayP3)
                )
                let oSdr = try #require(oddRendered.sdrLinearTexture?.texture)
                let oHdr = try #require(oddRendered.hdrLinearTexture?.texture)
                #expect(try readRGBA16FPixelsV11(device: dev, commandQueue: engine.commandQueue, texture: oSdr).allSatisfy { $0.isFinite })
                #expect(try readRGBA16FPixelsV11(device: dev, commandQueue: engine.commandQueue, texture: oHdr).allSatisfy { $0.isFinite })
            }

            // (c) 2x2 rawBayer with degenerate whiteLevel == blackLevel == 512
            let rawSamples: [UInt16] = [512, 512, 512, 512]
            let rawData = rawSamples.withUnsafeBytes { Data($0) }
            let degenerateFrame = DecodedRAWFrame(
                sourceURL: URL(fileURLWithPath: "/tmp/DEGEN_BAYER.ARW"),
                backendUsed: .libraw,
                payload: .rawBayer(width: 2, height: 2, bitsPerSample: 14, cfa: .rggb, data: rawData),
                visibleCrop: SensorCropRect(x: 0, y: 0, width: 2, height: 2),
                orientation: 1,
                colorMatrices: CameraColorMatrices(),
                isLosslessMS: false,
                exif: WhitelistedExif()
            )
            let degenRendered = try await engine.render(
                frame: degenerateFrame,
                params: EffectiveDevelopParams.resolve(preset: preset),
                outputSpec: RenderOutputSpec(targetBitDepth: .bit8, baseColorSpace: .displayP3),
                rawCalibration: RAWLevelCalibration(blackLevel: [512, 512, 512, 512], whiteLevel: 512)
            )
            let dSdr = try #require(degenRendered.sdrLinearTexture?.texture)
            let dHdr = try #require(degenRendered.hdrLinearTexture?.texture)
            #expect(try readRGBA16FPixelsV11(device: dev, commandQueue: engine.commandQueue, texture: dSdr).allSatisfy { $0.isFinite })
            #expect(try readRGBA16FPixelsV11(device: dev, commandQueue: engine.commandQueue, texture: dHdr).allSatisfy { $0.isFinite })
        }

        @Test("10. BoundedAsyncChannel cancellation wakes waiting producers/consumers cleanly without dropping subsequent items")
        func testBoundedAsyncChannelCancellationAndBackpressureContracts() async throws {
            // (a) Producer cancellation while suspended at capacity
            let chA = BoundedAsyncChannel<Int>(capacity: 1)
            try await chA.send(1)

            let prod1 = Task {
                try await chA.send(2)
            }
            try await Task.sleep(for: .milliseconds(25))
            let prod2 = Task {
                try await chA.send(3)
            }
            try await Task.sleep(for: .milliseconds(25))
            #expect(await chA.waitingProducerCount == 2)

            prod1.cancel()
            await #expect(throws: CancellationError.self) {
                try await prod1.value
            }

            #expect(await chA.next() == 1)
            try await prod2.value
            #expect(await chA.next() == 3)

            // (b) Consumer cancellation while waiting on empty channel
            let chB = BoundedAsyncChannel<Int>(capacity: 1)
            let waitingConsumer = Task {
                await chB.next()
            }
            try await Task.sleep(for: .milliseconds(25))
            waitingConsumer.cancel()
            let cancelledVal = await waitingConsumer.value
            #expect(cancelledVal == nil)

            try await chB.send(42)
            #expect(await chB.next() == 42)

            // (c) finish() wakes multiple waiting consumers with nil and rejects subsequent send
            let chC = BoundedAsyncChannel<Int>(capacity: 1)
            let c1 = Task { await chC.next() }
            let c2 = Task { await chC.next() }
            try await Task.sleep(for: .milliseconds(25))
            await chC.finish()
            #expect(await c1.value == nil)
            #expect(await c2.value == nil)
            await #expect(throws: BoundedAsyncChannelError.finished) {
                try await chC.send(99)
            }
        }

        @Test("11. CLI rejects non-finite/whitespace flags; sidecar AVIF budget, 4K HLG rejection, and batch cancellation leave zero .tmp files")
        func testBoundedBatchPipelineSidecarAVIFBudgetCancellationAndCLIInvalidArgs() async throws {
            // (a) Sample-free CLI invalid flag checks
            let cliURL = try #require(findTier5V11CLIBinary(), "chiaro-cli binary not found in .build")
            let cliDir = try makeTier5V11TempDir(prefix: "tier5-v11-cli-invalid")
            defer { try? FileManager.default.removeItem(at: cliDir) }

            let dummyARW = cliDir.appendingPathComponent("dummy.ARW")
            try Data("DUMMY".utf8).write(to: dummyARW)
            let badOut = cliDir.appendingPathComponent("out", isDirectory: true)

            let invalidCalls: [[String]] = [
                [dummyARW.path, "--clarity", "nan", "-o", badOut.path],
                [dummyARW.path, "--sharpness", "inf", "-o", badOut.path],
                [dummyARW.path, "--denoise-luma", "-1", "-o", badOut.path],
                [dummyARW.path, "--denoise-chroma", "101", "-o", badOut.path],
                [dummyARW.path, "--lens-vignetting-strength", "nan", "-o", badOut.path],
                [dummyARW.path, "--naming", "   ", "-o", badOut.path],
            ]
            for args in invalidCalls {
                let res = try runTier5V11CLI(cliURL, arguments: args)
                #expect(res.status == 1, "Expected exit status 1 for \(args), got \(res.status)")
                #expect(!res.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            #expect(!FileManager.default.fileExists(atPath: badOut.path))

            // (b) & (c) Real-ARW gated BoundedBatchPipeline checks
            guard TestFixtures.hasSampleDirectory else {
                return
            }

            let sample2532 = TestFixtures.sampleDirectory.appendingPathComponent("DSC02532.ARW")
            let sample2540 = TestFixtures.sampleDirectory.appendingPathComponent("DSC02540.ARW")
            let sample2556 = TestFixtures.sampleDirectory.appendingPathComponent("DSC02556.ARW")
            try #require(FileManager.default.fileExists(atPath: sample2532.path))
            try #require(FileManager.default.fileExists(atPath: sample2540.path))
            try #require(FileManager.default.fileExists(atPath: sample2556.path))

            let workDir = try makeTier5V11TempDir(prefix: "tier5-v11-batch-sidecar")
            defer { try? FileManager.default.removeItem(at: workDir) }

            let appleHEIC = try PresetLoader.loadBuiltIn(id: .appleHEIC)

            // (b1) Sidecar presetID = avif_archive activates PreAVIFPoolSnapshot & AVIF budget
            let avifInputDir = workDir.appendingPathComponent("avif_in", isDirectory: true)
            let avifOutDir = workDir.appendingPathComponent("avif_out", isDirectory: true)
            try FileManager.default.createDirectory(at: avifInputDir, withIntermediateDirectories: true)
            let copiedAVIFARW = avifInputDir.appendingPathComponent("DSC02556.ARW")
            try FileManager.default.copyItem(at: sample2556, to: copiedAVIFARW)
            let avifSidecar = ChiaroSidecar(presetID: BuiltInPresetID.avifArchive.rawValue)
            try ChiaroSidecar.save(avifSidecar, for: copiedAVIFARW)

            let avifJob = ExportJob(
                inputURL: copiedAVIFARW,
                outputDirectory: avifOutDir,
                preset: appleHEIC,
                cliOverrides: CLIDevelopOverrides(presetExplicitlySpecified: false),
                useSidecar: true
            )

            let capturedSnapshots = OSAllocatedUnfairLock<[BoundedBatchPipeline.PreAVIFPoolSnapshot]>(initialState: [])
            let sharedEngine = try MetalPipelineEngine()
            let avifPipeline = BoundedBatchPipeline(
                metalEngine: sharedEngine,
                preAVIFPoolStatsHook: { snap in
                    capturedSnapshots.withLock { $0.append(snap) }
                }
            )
            let avifResults = try await avifPipeline.run(jobs: [avifJob])
            #expect(avifResults.count == 1)
            #expect(avifResults[0].errorDescription == nil)
            #expect(avifResults[0].artifacts.allSatisfy { $0.format == .avif })
            let snaps = capturedSnapshots.withLock { $0 }
            #expect(snaps.count == 1)
            #expect(snaps[0].statsAfterEvict.activeCount == 0)
            #expect(snaps[0].statsAfterEvict.heapCount == 0)
            #expect(!hasTmpFilesV11(in: workDir))

            // (c) Sidecar presetID = douyin_hlg_mp4 + maxLongEdgeOverride = 3840 -> Stage 1 rejection
            let hlgInputDir = workDir.appendingPathComponent("hlg_in", isDirectory: true)
            let hlgOutDir = workDir.appendingPathComponent("hlg_out", isDirectory: true)
            try FileManager.default.createDirectory(at: hlgInputDir, withIntermediateDirectories: true)
            let copiedHLGARW = hlgInputDir.appendingPathComponent("DSC02532.ARW")
            try FileManager.default.copyItem(at: sample2532, to: copiedHLGARW)
            let hlgSidecar = ChiaroSidecar(
                presetID: BuiltInPresetID.douyinHLGMP4.rawValue,
                delta: PerPhotoDelta(maxLongEdgeOverride: 3840)
            )
            try ChiaroSidecar.save(hlgSidecar, for: copiedHLGARW)

            let hlgJob = ExportJob(
                inputURL: copiedHLGARW,
                outputDirectory: hlgOutDir,
                preset: appleHEIC,
                cliOverrides: CLIDevelopOverrides(presetExplicitlySpecified: false),
                useSidecar: true
            )
            let hlgResults = try await BoundedBatchPipeline().run(jobs: [hlgJob])
            #expect(hlgResults.count == 1)
            let hlgErr = try #require(hlgResults[0].errorDescription)
            #expect(hlgErr.contains("3840") || hlgErr.contains("4K"))
            #expect(hlgResults[0].artifacts.isEmpty)

            // (b2) Mid-batch Task.cancel() cleanly terminates without leaked .tmp files
            let cancelOutDir = workDir.appendingPathComponent("cancel_out", isDirectory: true)
            let cancelJobs = [sample2532, sample2540, sample2556].map { url in
                ExportJob(
                    inputURL: url,
                    outputDirectory: cancelOutDir,
                    preset: appleHEIC,
                    verifyAfterExport: false
                )
            }
            let batchTask = Task {
                try await BoundedBatchPipeline().run(jobs: cancelJobs)
            }
            try await Task.sleep(for: .milliseconds(80))
            batchTask.cancel()
            do {
                _ = try await batchTask.value
            } catch is CancellationError {
                // Expected cancellation path
            }
            #expect(!hasTmpFilesV11(in: cancelOutDir))
        }
    }
}
