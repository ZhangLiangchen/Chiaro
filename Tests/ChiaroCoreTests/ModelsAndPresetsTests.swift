import CLibAVIFBridge
import CLibRawBridge
import CUltraHDRBridge
import Foundation
import ChiaroCore
import Metal
import Testing

@Test
func testLoadAllSevenBuiltInPresetsFromBundle() throws {
    let presets = try PresetLoader.loadAllBuiltIn()
    #expect(presets.count == 7)

    let byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
    let expectedIDs: Set<String> = [
        "apple_heic",
        "apple_heic_compat",
        "xiaohongshu_jpg",
        "douyin_jpg",
        "douyin_hlg_mp4",
        "tri_format",
        "avif_archive",
    ]
    #expect(Set(byID.keys) == expectedIDs)

    let appleHEIC = try #require(byID["apple_heic"])
    #expect(appleHEIC.outputFormats == [.heic])
    #expect(appleHEIC.bitDepth == .bit10)
    #expect(appleHEIC.baseColorSpace == .displayP3)
    #expect(appleHEIC.gainMapChannels == .rgb3ch)
    #expect(appleHEIC.compatOptions.writeLegacyAppleHDRGainMap == false)
    #expect(appleHEIC.targetHeadroomStops == 2.5)
    #expect(appleHEIC.quality == 0.90)

    let appleCompat = try #require(byID["apple_heic_compat"])
    #expect(appleCompat.outputFormats == [.heic])
    #expect(appleCompat.bitDepth == .bit10)
    #expect(appleCompat.baseColorSpace == .displayP3)
    #expect(appleCompat.gainMapChannels == .mono1ch)
    #expect(appleCompat.compatOptions.writeLegacyAppleHDRGainMap == true)
    #expect(appleCompat.targetHeadroomStops == 2.5)
    #expect(appleCompat.quality == 0.90)

    let xhs = try #require(byID["xiaohongshu_jpg"])
    #expect(xhs.outputFormats == [.jpeg])
    #expect(xhs.bitDepth == .bit8)
    #expect(xhs.baseColorSpace == .displayP3)
    #expect(xhs.gainMapChannels == .mono1ch)
    #expect(xhs.maxLongEdge == 2048)
    #expect(xhs.cropAspect == .ratio3x4)
    #expect(xhs.targetMaxFileBytes == 4_194_304)
    #expect(xhs.compatOptions.closedLoopSDRCompensation == true)
    #expect(xhs.compatOptions.writeUltrahdrXMP == true)

    let douyinJPG = try #require(byID["douyin_jpg"])
    #expect(douyinJPG.outputFormats == [.jpeg])
    #expect(douyinJPG.bitDepth == .bit8)
    #expect(douyinJPG.baseColorSpace == .srgb)
    #expect(douyinJPG.gainMapChannels == .mono1ch)
    #expect(douyinJPG.maxLongEdge == 1440)
    #expect(douyinJPG.cropAspect == .ratio3x4)
    #expect(douyinJPG.targetMaxFileBytes == 3_145_728)
    #expect(douyinJPG.targetHeadroomStops == 2.25)
    #expect(douyinJPG.developDefaults.sdrContrast > 0)
    #expect(douyinJPG.developDefaults.sdrSaturation > 0)

    let douyinMP4 = try #require(byID["douyin_hlg_mp4"])
    #expect(douyinMP4.outputFormats == [.hlgMP4])
    #expect(douyinMP4.bitDepth == .bit10)
    #expect(douyinMP4.hlgVideoOptions == HLGVideoOptions(aspect: .portrait9x16, durationSeconds: 4.0, fps: 30, bitrateMbps: 14.0))
    #expect(douyinMP4.targetHeadroomStops == 2.75)
    #expect((douyinMP4.maxLongEdge ?? 0) <= 1920)

    let triFormat = try #require(byID["tri_format"])
    #expect(triFormat.outputFormats == [.heic, .jpeg, .avif])
    #expect(triFormat.bitDepth == .bit10)
    #expect(triFormat.gainMapChannels == .rgb3ch)
    #expect(triFormat.effectiveGainMapChannels(for: .jpeg) == .mono1ch)
    #expect(triFormat.effectiveGainMapChannels(for: .heic) == .rgb3ch)
    #expect(triFormat.effectiveGainMapChannels(for: .avif) == .rgb3ch)
    #expect(triFormat.effectiveBitDepth(for: .jpeg) == .bit8)
    #expect(triFormat.effectiveBitDepth(for: .heic) == .bit10)

    let avifArchive = try #require(byID["avif_archive"])
    #expect(avifArchive.outputFormats == [.avif])
    #expect(avifArchive.bitDepth == .bit10)
    #expect(avifArchive.quality == 0.80)
    #expect(avifArchive.gainMapQuality == 0.80)
    #expect(avifArchive.qualityPercent == 80)
    #expect(avifArchive.effectiveGainMapQualityPercent == 80)
}

@Test
func testPresetValidationRejectsInvalidConfigurations() throws {
    let base = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    var badLegacy = base
    badLegacy.gainMapChannels = .rgb3ch
    badLegacy.compatOptions.writeLegacyAppleHDRGainMap = true
    #expect(throws: PresetValidationError.legacyAppleGainMapRequiresMono1ch) {
        try PresetLoader.validate(badLegacy)
    }

    var badAnchorLow = base
    badAnchorLow.midtoneAnchorP = 0.64
    #expect(throws: PresetValidationError.midtoneAnchorOutOfBounds(0.64)) {
        try PresetLoader.validate(badAnchorLow)
    }

    var badAnchorHigh = base
    badAnchorHigh.midtoneAnchorP = 0.96
    #expect(throws: PresetValidationError.midtoneAnchorOutOfBounds(0.96)) {
        try PresetLoader.validate(badAnchorHigh)
    }

    let hlgBase = try PresetLoader.loadBuiltIn(id: .douyinHLGMP4)
    var bad4K = hlgBase
    bad4K.maxLongEdge = 3840
    #expect(throws: PresetValidationError.hlgVideo4KForbidden(3840)) {
        try PresetLoader.validate(bad4K)
    }

    var badDurShort = hlgBase
    badDurShort.hlgVideoOptions?.durationSeconds = 2.5
    #expect(throws: PresetValidationError.hlgVideoDurationOutOfBounds(2.5)) {
        try PresetLoader.validate(badDurShort)
    }

    var badDurLong = hlgBase
    badDurLong.hlgVideoOptions?.durationSeconds = 5.5
    #expect(throws: PresetValidationError.hlgVideoDurationOutOfBounds(5.5)) {
        try PresetLoader.validate(badDurLong)
    }

    var badFPS = hlgBase
    badFPS.hlgVideoOptions?.fps = 60
    #expect(throws: PresetValidationError.hlgVideoFPSOutOfBounds(60)) {
        try PresetLoader.validate(badFPS)
    }

    var badBitrate = hlgBase
    badBitrate.hlgVideoOptions?.bitrateMbps = 20.0
    #expect(throws: PresetValidationError.hlgVideoBitrateOutOfBounds(20.0)) {
        try PresetLoader.validate(badBitrate)
    }

    let jpegBase = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
    var badJPEG3chXMP = jpegBase
    badJPEG3chXMP.gainMapChannels = .rgb3ch
    badJPEG3chXMP.compatOptions.writeUltrahdrXMP = true
    #expect(throws: PresetValidationError.ultrahdrXMPRequiresMono1chForJPEGOnly) {
        try PresetLoader.validate(badJPEG3chXMP)
    }

    var badJPEG10Bit = jpegBase
    badJPEG10Bit.bitDepth = .bit10
    #expect(throws: PresetValidationError.jpegOnlyPresetMustBe8Bit) {
        try PresetLoader.validate(badJPEG10Bit)
    }

    var badQuality = base
    badQuality.quality = 80.0
    #expect(throws: PresetValidationError.qualityOutOfBounds(80.0)) {
        try PresetLoader.validate(badQuality)
    }

    var emptyFormats = base
    emptyFormats.outputFormats = []
    #expect(throws: PresetValidationError.emptyOutputFormats) {
        try PresetLoader.validate(emptyFormats)
    }

    var emptyID = base
    emptyID.id = "   "
    #expect(throws: PresetValidationError.emptyPresetID) {
        try PresetLoader.validate(emptyID)
    }

    var dupJPEG = jpegBase
    dupJPEG.outputFormats = [.jpeg, .jpeg]
    #expect(throws: PresetValidationError.duplicateOutputFormats) {
        try PresetLoader.validate(dupJPEG)
    }

    var dupJPEGBadDepth = jpegBase
    dupJPEGBadDepth.outputFormats = [.jpeg, .jpeg]
    dupJPEGBadDepth.bitDepth = .bit10
    #expect(throws: PresetValidationError.duplicateOutputFormats) {
        try PresetLoader.validate(dupJPEGBadDepth)
    }

    var badDevelopExposure = base
    badDevelopExposure.developDefaults.exposureEV = 100.0
    do {
        try PresetLoader.validate(badDevelopExposure)
        Issue.record("Expected developDefaultsOutOfBounds for exposureEV=100.0")
    } catch let error as PresetValidationError {
        if case .developDefaultsOutOfBounds = error {
            // expected
        } else {
            Issue.record("Unexpected error: \(error)")
        }
    }

    var badDevelopNaN = base
    badDevelopNaN.developDefaults.shadowRecovery = .nan
    do {
        try PresetLoader.validate(badDevelopNaN)
        Issue.record("Expected developDefaultsOutOfBounds for shadowRecovery=nan")
    } catch let error as PresetValidationError {
        if case .developDefaultsOutOfBounds = error {
            // expected
        } else {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test
func testHeadroomUnitsRoundTripMath() {
    #expect(HeadroomStops.sdr.toLinear().multiplier == 1.0)
    #expect(HeadroomStops.x4.toLinear().multiplier == 4.0)
    #expect(abs(HeadroomStops.defaultHDR.toLinear().multiplier - 5.656854249492381) < 1e-9)

    for stops in [0.0, 1.0, 2.0, 2.5, 3.0, 4.0] {
        let roundTripped = HeadroomStops(log2Value: stops).toLinear().toStops().log2Value
        #expect(abs(roundTripped - stops) < 1e-9)
    }

    #expect(LinearHeadroom(multiplier: 0.5).toStops().log2Value == 0.0)
}

@Test
func testPerPhotoDeltaResolutionAndClamping() throws {
    let appleHEIC = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    let delta = PerPhotoDelta(
        exposureEVDelta: -0.5,
        midtoneAnchorPOverride: 1.2,
        cropAspectOverride: .ratio9x16,
        cropOffset: CropOffset(normalizedCenterX: 0.25, normalizedCenterY: 0.75)
    )
    let resolved = EffectiveDevelopParams.resolve(preset: appleHEIC, delta: delta)
    #expect(resolved.develop.exposureEV == -0.5)
    #expect(resolved.midtoneAnchorP == 0.95)
    #expect(resolved.cropAspect == .ratio9x16)
    #expect(resolved.cropOffset == CropOffset(normalizedCenterX: 0.25, normalizedCenterY: 0.75))

    let clampDelta = PerPhotoDelta(
        exposureEVDelta: 5.0,
        midtoneAnchorPOverride: 0.1
    )
    let clamped = EffectiveDevelopParams.resolve(preset: appleHEIC, delta: clampDelta)
    #expect(clamped.develop.exposureEV == 3.0)
    #expect(clamped.midtoneAnchorP == 0.65)
}

@Test
func testWhitelistedExifHasNoMakerNoteProperty() {
    let exif = WhitelistedExif(make: "SONY", model: "ILCE-7CM2")
    #expect(exif.orientation == 1)
    let labels = Mirror(reflecting: exif).children.compactMap { $0.label?.lowercased() }
    #expect(!labels.contains(where: { $0.contains("makernote") }))
}

@Test
func testShadersMetalBundleResourceLookup() throws {
    let url = PresetLoader.resourceBundle.url(forResource: "Shaders", withExtension: "metal")
    let shaderURL = try #require(url)
    let source = try String(contentsOf: shaderURL, encoding: .utf8)
    #expect(!source.isEmpty)
    #expect(source.contains("hdr_passthrough_kernel"))

    if let device = MTLCreateSystemDefaultDevice() {
        let library = try device.makeLibrary(source: source, options: nil)
        #expect(library.functionNames.contains("hdr_passthrough_kernel"))
    }
}

@Test
func testCBridgeSymbolsLinked() {
    let rawVer = String(cString: hdr_libraw_version())
    let uhdrVer = String(cString: hdr_ultrahdr_version())
    let avifVer = String(cString: hdr_libavif_version())

    #expect(!rawVer.isEmpty)
    #expect(!uhdrVer.isEmpty)
    #expect(!avifVer.isEmpty)
}

@Test
func testCropOffsetJSONDecodeClampsAndSanitizes() throws {
    let json = """
    {
      "cropOffset": {
        "normalizedCenterX": -1.0,
        "normalizedCenterY": 2.5
      }
    }
    """
    let data = try #require(json.data(using: .utf8))
    let decodedDelta = try JSONDecoder().decode(PerPhotoDelta.self, from: data)
    #expect(decodedDelta.cropOffset == CropOffset(normalizedCenterX: 0.0, normalizedCenterY: 1.0))

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let resolved = EffectiveDevelopParams.resolve(preset: preset, delta: decodedDelta)
    #expect(resolved.cropOffset == CropOffset(normalizedCenterX: 0.0, normalizedCenterY: 1.0))

    let nonFiniteOffset = CropOffset(normalizedCenterX: .nan, normalizedCenterY: .infinity)
    #expect(nonFiniteOffset == CropOffset(normalizedCenterX: 0.5, normalizedCenterY: 0.5))
}

@Test
func testNonFiniteSanitizationAndNilDeltaClampingInResolve() throws {
    var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    preset.developDefaults.exposureEV = 100.0
    preset.developDefaults.shadowRecovery = -50.0
    preset.developDefaults.sdrExposureEV = 5.0
    preset.developDefaults.hdrHighlightExcitation = .nan

    // Even when delta == nil, developDefaults must be clamped and sanitized.
    let resolvedNilDelta = EffectiveDevelopParams.resolve(preset: preset, delta: nil)
    #expect(resolvedNilDelta.develop.exposureEV == 3.0)
    #expect(resolvedNilDelta.develop.shadowRecovery == 0.0)
    #expect(resolvedNilDelta.develop.sdrExposureEV == 1.0)
    #expect(resolvedNilDelta.develop.hdrHighlightExcitation == 60.0)

    // Non-finite deltas/overrides must not propagate NaN or Infinity.
    let cleanPreset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    var badOffset = CropOffset(normalizedCenterX: 0.25, normalizedCenterY: 0.75)
    badOffset.normalizedCenterX = .nan
    badOffset.normalizedCenterY = -.infinity

    let nanDelta = PerPhotoDelta(
        exposureEVDelta: .nan,
        sdrExposureEVDelta: .infinity,
        shadowRecoveryOverride: .nan,
        blackPointOverride: .infinity,
        vibranceOverride: -.infinity,
        sdrHighlightCompressionOverride: .nan,
        sdrContrastOverride: .nan,
        sdrSaturationOverride: .nan,
        hdrHighlightExcitationOverride: .nan,
        hdrRolloffSoftnessOverride: .nan,
        targetHeadroomStopsOverride: .nan,
        midtoneAnchorPOverride: .infinity,
        cropOffset: badOffset,
        maxLongEdgeOverride: 2049
    )
    let resolvedNaN = EffectiveDevelopParams.resolve(preset: cleanPreset, delta: nanDelta)
    #expect(resolvedNaN.develop.exposureEV == cleanPreset.developDefaults.exposureEV)
    #expect(resolvedNaN.develop.sdrExposureEV == cleanPreset.developDefaults.sdrExposureEV)
    #expect(resolvedNaN.develop.shadowRecovery == cleanPreset.developDefaults.shadowRecovery)
    #expect(resolvedNaN.develop.blackPoint == cleanPreset.developDefaults.blackPoint)
    #expect(resolvedNaN.develop.vibrance == cleanPreset.developDefaults.vibrance)
    #expect(resolvedNaN.develop.sdrHighlightCompression == cleanPreset.developDefaults.sdrHighlightCompression)
    #expect(resolvedNaN.develop.sdrContrast == cleanPreset.developDefaults.sdrContrast)
    #expect(resolvedNaN.develop.sdrSaturation == cleanPreset.developDefaults.sdrSaturation)
    #expect(resolvedNaN.develop.hdrHighlightExcitation == cleanPreset.developDefaults.hdrHighlightExcitation)
    #expect(resolvedNaN.develop.hdrRolloffSoftness == cleanPreset.developDefaults.hdrRolloffSoftness)
    #expect(resolvedNaN.targetHeadroom.log2Value == cleanPreset.targetHeadroomStops)
    #expect(resolvedNaN.midtoneAnchorP == cleanPreset.midtoneAnchorP)
    #expect(resolvedNaN.cropOffset == CropOffset(normalizedCenterX: 0.5, normalizedCenterY: 0.5))
    #expect(resolvedNaN.maxLongEdge == 2048)

    let tinyEdgeDelta = PerPhotoDelta(maxLongEdgeOverride: 31)
    let resolvedTinyEdge = EffectiveDevelopParams.resolve(preset: cleanPreset, delta: tinyEdgeDelta)
    #expect(resolvedTinyEdge.maxLongEdge == 64)
}

@Test
func testWhiteBalanceCustomValidationAndSanitization() throws {
    let base = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    // Valid boundary values pass validation.
    for (kelvin, tint) in [(2000.0, -150.0), (5500.0, 0.0), (15000.0, 150.0)] {
        var validPreset = base
        validPreset.developDefaults.whiteBalance = .custom(temperatureKelvin: kelvin, tint: tint)
        try PresetLoader.validate(validPreset)
    }

    // Non-finite and out-of-bounds values are rejected by PresetLoader.validate.
    let invalidCases: [(Double, Double)] = [
        (.nan, 0.0),
        (5500.0, .nan),
        (.infinity, 0.0),
        (-.infinity, 0.0),
        (5500.0, .infinity),
        (5500.0, -.infinity),
        (1999.0, 0.0),
        (15001.0, 0.0),
        (5500.0, -151.0),
        (5500.0, 151.0),
    ]
    for (kelvin, tint) in invalidCases {
        var badPreset = base
        badPreset.developDefaults.whiteBalance = .custom(temperatureKelvin: kelvin, tint: tint)
        #expect(throws: PresetValidationError.developDefaultsOutOfBounds("whiteBalance.custom")) {
            try PresetLoader.validate(badPreset)
        }
    }

    // EffectiveDevelopParams.resolve sanitizes preset.developDefaults.whiteBalance when delta == nil.
    let sanitizationCases: [(input: (Double, Double), expected: (Double, Double))] = [
        ((.nan, .nan), (5500.0, 0.0)),
        ((.infinity, -.infinity), (5500.0, 0.0)),
        ((-.infinity, .infinity), (5500.0, 0.0)),
        ((1999.0, -151.0), (2000.0, -150.0)),
        ((15001.0, 151.0), (15000.0, 150.0)),
        ((6500.0, .nan), (6500.0, 0.0)),
        ((.nan, 25.0), (5500.0, 25.0)),
    ]
    for testCase in sanitizationCases {
        var preset = base
        preset.developDefaults.whiteBalance = .custom(
            temperatureKelvin: testCase.input.0,
            tint: testCase.input.1
        )
        let resolvedPresetOnly = EffectiveDevelopParams.resolve(preset: preset, delta: nil)
        #expect(
            resolvedPresetOnly.develop.whiteBalance
                == .custom(temperatureKelvin: testCase.expected.0, tint: testCase.expected.1)
        )

        // EffectiveDevelopParams.resolve sanitizes delta.whiteBalanceOverride.
        let delta = PerPhotoDelta(
            whiteBalanceOverride: .custom(
                temperatureKelvin: testCase.input.0,
                tint: testCase.input.1
            )
        )
        let resolvedDelta = EffectiveDevelopParams.resolve(preset: base, delta: delta)
        #expect(
            resolvedDelta.develop.whiteBalance
                == .custom(temperatureKelvin: testCase.expected.0, tint: testCase.expected.1)
        )
    }
}
