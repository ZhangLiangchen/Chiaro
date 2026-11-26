import Foundation
import Testing
@testable import ChiaroCore

private func makeSidecarTestDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("chiaro-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test
func testSidecarURLPathConventionAndMissingLifecycle() throws {
    let dir = try makeSidecarTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let rawURL = dir.appendingPathComponent("DSC02532.ARW")
    let expectedSidecar = dir.appendingPathComponent("DSC02532.ARW.chiaro.json")
    #expect(ChiaroSidecar.sidecarURL(for: rawURL) == expectedSidecar)
    #expect(!ChiaroSidecar.exists(for: rawURL))
    #expect(try ChiaroSidecar.loadIfExists(for: rawURL) == nil)
}

@Test
func testSidecarAtomicSaveReloadOverwriteAndZeroTempLeftovers() throws {
    let dir = try makeSidecarTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let rawURL = dir.appendingPathComponent("DSC02532.ARW")
    let fixedDate = Date(timeIntervalSince1970: 1_764_121_500)

    let initial = ChiaroSidecar(
        schemaVersion: 2,
        updatedAt: fixedDate,
        presetID: "apple_heic",
        decodeBackend: .libraw,
        demosaic: .amaze,
        optics: OpticalCorrectionParameters(
            enabled: true,
            source: .auto,
            lensfunCameraOverride: nil,
            lensfunLensOverride: nil,
            distortion: true,
            autoScale: true,
            tca: true,
            vignetting: true,
            vignettingStrength: 0.85
        ),
        delta: PerPhotoDelta(
            exposureEVDelta: 0.35,
            shadowRecoveryOverride: 25.0,
            clarityOverride: 15.0,
            opticalSharpnessOverride: 30.0
        ),
        denoise: DenoiseParameters(
            mode: .profiledWavelet,
            luminanceStrength: 25.0,
            chromaStrength: 65.0,
            detailPreservation: 70.0,
            preferANE: true,
            modelID: nil
        ),
        aiColor: nil
    )

    try ChiaroSidecar.save(initial, for: rawURL)
    #expect(ChiaroSidecar.exists(for: rawURL))

    let loaded = try #require(try ChiaroSidecar.loadIfExists(for: rawURL))
    #expect(loaded == initial)
    #expect(loaded.schemaVersion == 2)
    #expect(loaded.appVersion == "1.1.1")

    // Verify canonical JSON contains "aiColor": null and zero leftover .tmp files
    let rawJSON = try String(contentsOf: ChiaroSidecar.sidecarURL(for: rawURL), encoding: .utf8)
    #expect(rawJSON.contains("\"aiColor\" : null") || rawJSON.contains("\"aiColor\":null"))
    let contentsAfterCreate = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(!contentsAfterCreate.contains(where: { $0.contains(".tmp") }))

    // Overwrite atomically with updated values including AIColorGradingParameters
    var updated = initial
    updated.demosaic = .lmmse
    updated.delta?.exposureEVDelta = -0.25
    updated.aiColor = AIColorGradingParameters(
        enabled: true,
        shadows: ColorBalanceWheelAdjustment(hueDegrees: 210.0, chroma: 0.25, luminanceOffset: -0.05),
        brilliance: 10.0,
        chroma: 5.0,
        toneEqualizerEV: [0.0, 0.2, 0.3, 0.0, 0.0, -0.2, -0.3, 0.0]
    )

    try ChiaroSidecar.save(updated, for: rawURL)
    let reloaded = try #require(try ChiaroSidecar.loadIfExists(for: rawURL))
    #expect(reloaded == updated)

    let contentsAfterOverwrite = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(!contentsAfterOverwrite.contains(where: { $0.contains(".tmp") }))
    #expect(contentsAfterOverwrite == ["DSC02532.ARW.chiaro.json"])

    // Delete cleanly
    try ChiaroSidecar.delete(for: rawURL)
    #expect(!ChiaroSidecar.exists(for: rawURL))
    #expect(try ChiaroSidecar.loadIfExists(for: rawURL) == nil)
}

@Test
func testSidecarForwardCompatibilityUnknownKeysFutureSchemaAndTimestamps() throws {
    let dir = try makeSidecarTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Case 1: Future schemaVersion = 3, unknown top-level & nested keys, unknown denoise.mode,
    // fractional ISO-8601 timestamp, and incompatible future aiColor payload.
    let futureRawURL = dir.appendingPathComponent("DSC09999.ARW")
    let futureJSON = """
    {
      "schemaVersion": 3,
      "appVersion": "2.4.0",
      "updatedAt": "2027-06-15T12:34:56.789Z",
      "presetID": "xiaohongshu_jpg",
      "decodeBackend": "libraw",
      "demosaic": "lmmse",
      "futureExperimentalBlock": {
        "enabled": true,
        "weights": [0.1, 0.9]
      },
      "optics": {
        "enabled": true,
        "source": "embedded",
        "vignettingStrength": 1.25,
        "futureOpticsTag": "v4"
      },
      "delta": {
        "exposureEVDelta": 0.5,
        "clarityOverride": 22.0,
        "futureSlider": 99
      },
      "denoise": {
        "mode": "futureTransformerV4",
        "luminanceStrength": 45.0,
        "futureKernelSize": 7
      },
      "aiColor": {
        "enabled": "incompatible-string-instead-of-bool",
        "futureGraph": { "nodes": [1, 2, 3] }
      }
    }
    """
    try futureJSON.write(to: ChiaroSidecar.sidecarURL(for: futureRawURL), atomically: true, encoding: .utf8)

    let decoded = try #require(try ChiaroSidecar.loadIfExists(for: futureRawURL))
    #expect(decoded.schemaVersion == 3)
    #expect(decoded.appVersion == "2.4.0")
    #expect(decoded.presetID == "xiaohongshu_jpg")
    #expect(decoded.demosaic == .lmmse)
    #expect(decoded.optics?.vignettingStrength == 1.0) // Clamped from 1.25
    #expect(decoded.delta?.exposureEVDelta == 0.5)
    #expect(decoded.delta?.clarityOverride == 22.0)
    #expect(decoded.denoise?.mode == .off) // Unknown mode safely fell back to .off
    #expect(decoded.denoise?.luminanceStrength == 45.0)
    #expect(decoded.aiColor == nil) // Incompatible structural payload safely degraded to nil

    // Case 2: Timezone offset timestamp (+08:00) and minimal partial sidecar
    let minimalRawURL = dir.appendingPathComponent("DSC00001.ARW")
    let minimalJSON = """
    {
      "updatedAt": "2026-11-26T09:45:00+08:00",
      "demosaic": "dcb"
    }
    """
    try minimalJSON.write(to: ChiaroSidecar.sidecarURL(for: minimalRawURL), atomically: true, encoding: .utf8)
    let minimal = try #require(try ChiaroSidecar.loadIfExists(for: minimalRawURL))
    #expect(minimal.schemaVersion == 2)
    #expect(minimal.appVersion == "1.1.1")
    #expect(minimal.demosaic == .dcb)
    #expect(minimal.presetID == nil)

    // Case 2b: Backward-compatible decoding of existing v1.1.0 sidecars preserves appVersion "1.1.0"
    let legacyV110RawURL = dir.appendingPathComponent("DSC01100.ARW")
    let legacyV110JSON = """
    {
      "schemaVersion": 2,
      "appVersion": "1.1.0",
      "updatedAt": "2026-11-26T01:45:00Z",
      "presetID": "apple_heic",
      "demosaic": "amaze"
    }
    """
    try legacyV110JSON.write(to: ChiaroSidecar.sidecarURL(for: legacyV110RawURL), atomically: true, encoding: .utf8)
    let legacyV110 = try #require(try ChiaroSidecar.loadIfExists(for: legacyV110RawURL))
    #expect(legacyV110.schemaVersion == 2)
    #expect(legacyV110.appVersion == "1.1.0")
    #expect(legacyV110.presetID == "apple_heic")
    #expect(legacyV110.demosaic == .amaze)

    // Case 3: Precedence integration with sidecar loaded from disk
    let appleHEIC = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let xhsJPG = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
    let resolved = EffectiveDevelopParams.resolve(
        preset: appleHEIC,
        delta: PerPhotoDelta(clarityOverride: 40.0),
        sidecar: decoded,
        cliOverrides: CLIDevelopOverrides(presetExplicitlySpecified: false, demosaic: .ahd),
        presetResolver: { $0 == xhsJPG.id ? xhsJPG : nil }
    )
    #expect(resolved.cropAspect == xhsJPG.cropAspect) // From sidecar presetID
    #expect(resolved.develop.clarity == 40.0)        // Delta beat sidecar (22.0)
    #expect(resolved.develop.exposureEV == 0.5)      // From sidecar delta
    #expect(resolved.demosaic == .ahd)               // CLI beat sidecar (.lmmse)
}

@Test
func testSidecarRejectsInvalidSchemaVersionAndCorruptJSON() throws {
    let dir = try makeSidecarTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let badSchemaURL = dir.appendingPathComponent("BAD_SCHEMA.ARW")
    let badSchemaJSON = """
    {
      "schemaVersion": 0,
      "updatedAt": "2026-11-26T01:45:00Z"
    }
    """
    try badSchemaJSON.write(to: ChiaroSidecar.sidecarURL(for: badSchemaURL), atomically: true, encoding: .utf8)
    #expect(throws: ChiaroSidecarError.unsupportedSchemaVersion(0)) {
        _ = try ChiaroSidecar.loadIfExists(for: badSchemaURL)
    }

    let corruptURL = dir.appendingPathComponent("CORRUPT.ARW")
    try "{ not valid json".write(to: ChiaroSidecar.sidecarURL(for: corruptURL), atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
        _ = try ChiaroSidecar.loadIfExists(for: corruptURL)
    }
}

@Test
func testSidecarSaveSanitizesNonFiniteDeltaValues() throws {
    let dir = try makeSidecarTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let rawURL = dir.appendingPathComponent("NAN_DELTA.ARW")

    var mutatedCrop = CropOffset(normalizedCenterX: 0.25, normalizedCenterY: 0.75)
    mutatedCrop.normalizedCenterX = .nan
    mutatedCrop.normalizedCenterY = -.infinity

    var mutatedOptics = OpticalCorrectionParameters(vignettingStrength: 0.5)
    mutatedOptics.vignettingStrength = .nan

    var mutatedDenoise = DenoiseParameters(luminanceStrength: 20.0)
    mutatedDenoise.luminanceStrength = .infinity

    var mutatedAIColor = AIColorGradingParameters(enabled: true, brilliance: 10.0)
    mutatedAIColor.brilliance = .nan

    let poisonDelta = PerPhotoDelta(
        exposureEVDelta: .nan,
        sdrExposureEVDelta: .infinity,
        shadowRecoveryOverride: -.infinity,
        blackPointOverride: -200.0, // Finite out-of-bounds preserved
        vibranceOverride: .nan,
        whiteBalanceOverride: .custom(temperatureKelvin: .nan, tint: .infinity),
        sdrHighlightCompressionOverride: .nan,
        sdrContrastOverride: .infinity,
        sdrSaturationOverride: -.infinity,
        hdrHighlightExcitationOverride: .nan,
        hdrRolloffSoftnessOverride: .infinity,
        targetHeadroomStopsOverride: .nan,
        midtoneAnchorPOverride: -.infinity,
        cropOffset: mutatedCrop,
        clarityOverride: .infinity,
        opticalSharpnessOverride: .nan,
        opticsOverride: mutatedOptics,
        denoiseOverride: mutatedDenoise,
        aiColorOverride: mutatedAIColor
    )

    // Test both init-time and post-init mutated delta before ChiaroSidecar.save
    var sidecar = ChiaroSidecar(delta: PerPhotoDelta(exposureEVDelta: 0.25))
    sidecar.delta = poisonDelta

    try ChiaroSidecar.save(sidecar, for: rawURL)
    let reloaded = try #require(try ChiaroSidecar.loadIfExists(for: rawURL))
    let loadedDelta = try #require(reloaded.delta)

    #expect(loadedDelta.exposureEVDelta == nil)
    #expect(loadedDelta.sdrExposureEVDelta == nil)
    #expect(loadedDelta.shadowRecoveryOverride == nil)
    #expect(loadedDelta.blackPointOverride == -200.0)
    #expect(loadedDelta.vibranceOverride == nil)
    #expect(loadedDelta.whiteBalanceOverride == .custom(temperatureKelvin: 5500.0, tint: 0.0))
    #expect(loadedDelta.sdrHighlightCompressionOverride == nil)
    #expect(loadedDelta.sdrContrastOverride == nil)
    #expect(loadedDelta.sdrSaturationOverride == nil)
    #expect(loadedDelta.hdrHighlightExcitationOverride == nil)
    #expect(loadedDelta.hdrRolloffSoftnessOverride == nil)
    #expect(loadedDelta.targetHeadroomStopsOverride == nil)
    #expect(loadedDelta.midtoneAnchorPOverride == nil)
    #expect(loadedDelta.cropOffset == .centered)
    #expect(loadedDelta.clarityOverride == nil)
    #expect(loadedDelta.opticalSharpnessOverride == nil)
    #expect(loadedDelta.opticsOverride?.vignettingStrength == 1.0)
    #expect(loadedDelta.denoiseOverride?.luminanceStrength == 25.0)
    #expect(loadedDelta.aiColorOverride?.brilliance == 0.0)
}

@Test
func testSidecarForwardCompatibleUnknownFutureOpticsDemosaicAndDecodeBackend() throws {
    let dir = try makeSidecarTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Standalone OpticalProfileSource decoding remains strict
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(OpticalProfileSource.self, from: Data("\"quantumOptics_v9\"".utf8))
    }

    let futureRawURL = dir.appendingPathComponent("FUTURE_ENUMS.ARW")
    let futureJSON = """
    {
      "schemaVersion": 4,
      "updatedAt": "2028-01-01T00:00:00Z",
      "decodeBackend": "quantumBackend_v9",
      "demosaic": "neuralDemosaic_v9",
      "optics": {
        "enabled": true,
        "source": "quantumOptics_v9",
        "distortion": false,
        "vignettingStrength": 0.42
      },
      "delta": {
        "exposureEVDelta": 0.65,
        "clarityOverride": 15.0
      }
    }
    """
    try futureJSON.write(to: ChiaroSidecar.sidecarURL(for: futureRawURL), atomically: true, encoding: .utf8)

    let loaded = try #require(try ChiaroSidecar.loadIfExists(for: futureRawURL))
    #expect(loaded.schemaVersion == 4)
    #expect(loaded.decodeBackend == nil)
    #expect(loaded.demosaic == nil)
    #expect(loaded.optics?.source == .auto)
    #expect(loaded.optics?.distortion == false)
    #expect(loaded.optics?.vignettingStrength == 0.42)
    #expect(loaded.delta?.exposureEVDelta == 0.65)
    #expect(loaded.delta?.clarityOverride == 15.0)

    // Structurally incompatible optics object degrades optics to nil while preserving delta
    let corruptOpticsURL = dir.appendingPathComponent("FUTURE_OPTICS_SHAPE.ARW")
    let corruptOpticsJSON = """
    {
      "schemaVersion": 4,
      "updatedAt": "2028-01-01T00:00:00Z",
      "optics": "incompatible_string_shape",
      "delta": {
        "exposureEVDelta": -0.35
      }
    }
    """
    try corruptOpticsJSON.write(to: ChiaroSidecar.sidecarURL(for: corruptOpticsURL), atomically: true, encoding: .utf8)
    let loadedCorruptOptics = try #require(try ChiaroSidecar.loadIfExists(for: corruptOpticsURL))
    #expect(loadedCorruptOptics.optics == nil)
    #expect(loadedCorruptOptics.delta?.exposureEVDelta == -0.35)
}

@Test
func testSidecarConcurrentSaveWritesLeaveValidJSONAndNoTempFiles() async throws {
    let dir = try makeSidecarTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let rawURL = dir.appendingPathComponent("CONCURRENT.ARW")
    let writeCount = 24

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<writeCount {
            group.addTask {
                let sidecar = ChiaroSidecar(
                    presetID: "apple_heic",
                    demosaic: .amaze,
                    delta: PerPhotoDelta(
                        exposureEVDelta: Double(index) * 0.05,
                        clarityOverride: Double(index)
                    )
                )
                try ChiaroSidecar.save(sidecar, for: rawURL)
            }
        }
        try await group.waitForAll()
    }

    let loaded = try #require(try ChiaroSidecar.loadIfExists(for: rawURL))
    #expect(loaded.presetID == "apple_heic")
    #expect(loaded.demosaic == .amaze)
    let clarity = try #require(loaded.delta?.clarityOverride)
    #expect(clarity >= 0.0 && clarity < Double(writeCount))

    let dirContents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(dirContents == ["CONCURRENT.ARW.chiaro.json"])
}
