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

@Test
func testV1PresetsBackwardCompatibilityClarityAndSharpnessDefaults() throws {
    let presets = try PresetLoader.loadAllBuiltIn()
    #expect(presets.count == 7)
    for preset in presets {
        #expect(preset.developDefaults.clarity == 0.0)
        #expect(preset.developDefaults.opticalSharpness == 0.0)
        let resolved = EffectiveDevelopParams.resolve(preset: preset)
        #expect(resolved.develop.clarity == 0.0)
        #expect(resolved.develop.opticalSharpness == 0.0)
        #expect(resolved.decodeBackend == .libraw)
        #expect(resolved.demosaic == .amaze)
        #expect(resolved.optics == .default)
        #expect(resolved.denoise == .default)
        #expect(resolved.aiColor == nil)
    }
}

@Test
func testPresetLoaderRejectsInvalidClarityAndOpticalSharpness() throws {
    let base = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    for badClarity in [-100.1, 100.1, Double.nan, Double.infinity, -Double.infinity] {
        var preset = base
        preset.developDefaults.clarity = badClarity
        do {
            try PresetLoader.validate(preset)
            Issue.record("Expected developDefaultsOutOfBounds for clarity=\(badClarity)")
        } catch let error as PresetValidationError {
            if case .developDefaultsOutOfBounds(let detail) = error {
                #expect(detail.contains("clarity"))
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    for badSharpness in [-0.1, 100.1, Double.nan, Double.infinity, -Double.infinity] {
        var preset = base
        preset.developDefaults.opticalSharpness = badSharpness
        do {
            try PresetLoader.validate(preset)
            Issue.record("Expected developDefaultsOutOfBounds for opticalSharpness=\(badSharpness)")
        } catch let error as PresetValidationError {
            if case .developDefaultsOutOfBounds(let detail) = error {
                #expect(detail.contains("opticalSharpness"))
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    var boundaryValid = base
    boundaryValid.developDefaults.clarity = -100.0
    boundaryValid.developDefaults.opticalSharpness = 100.0
    try PresetLoader.validate(boundaryValid)
}

@Test
func testSDRToneMapperSigmoidCodableRoundTrip() throws {
    #expect(SDRToneMapper.allCases.contains(.sigmoid))
    let encoded = try JSONEncoder().encode(SDRToneMapper.sigmoid)
    #expect(String(data: encoded, encoding: .utf8) == "\"sigmoid\"")
    let decoded = try JSONDecoder().decode(SDRToneMapper.self, from: encoded)
    #expect(decoded == .sigmoid)
}

@Test
func testEffectiveDevelopParamsResolveClampingAndFourTierPrecedence() throws {
    let appleHEIC = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let douyinJPG = try PresetLoader.loadBuiltIn(id: .douyinJPG)
    let xhsJPG = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)

    let presetsByID: [String: PresetSchema] = [
        appleHEIC.id: appleHEIC,
        douyinJPG.id: douyinJPG,
        xhsJPG.id: xhsJPG,
    ]

    let sidecar = ChiaroSidecar(
        presetID: xhsJPG.id,
        decodeBackend: .ciraw9,
        demosaic: .lmmse,
        optics: OpticalCorrectionParameters(
            enabled: true,
            source: .embedded,
            distortion: true,
            autoScale: false,
            tca: true,
            vignetting: true,
            vignettingStrength: 0.65
        ),
        delta: PerPhotoDelta(
            exposureEVDelta: 0.40,
            sdrExposureEVDelta: 0.25,
            shadowRecoveryOverride: 30.0,
            sdrToneMapperOverride: .neutralRational,
            maxLongEdgeOverride: 2048,
            clarityOverride: 18.0,
            opticalSharpnessOverride: 35.0
        ),
        denoise: DenoiseParameters(
            mode: .profiledWavelet,
            luminanceStrength: 30.0,
            chromaStrength: 70.0,
            detailPreservation: 60.0
        ),
        aiColor: AIColorGradingParameters(
            enabled: true,
            brilliance: 12.0,
            chroma: -8.0,
            toneEqualizerEV: [0.5, -0.5]
        )
    )

    // 1. Sidecar presetID applies when CLI preset was NOT explicitly specified.
    let resolvedSidecarPreset = EffectiveDevelopParams.resolve(
        preset: appleHEIC,
        delta: nil,
        sidecar: sidecar,
        cliOverrides: CLIDevelopOverrides(presetExplicitlySpecified: false),
        presetResolver: { presetsByID[$0] }
    )
    #expect(resolvedSidecarPreset.cropAspect == xhsJPG.cropAspect)
    #expect(resolvedSidecarPreset.decodeBackend == .ciraw9)
    #expect(resolvedSidecarPreset.demosaic == .lmmse)
    #expect(resolvedSidecarPreset.develop.clarity == 18.0)
    #expect(resolvedSidecarPreset.develop.opticalSharpness == 35.0)
    #expect(resolvedSidecarPreset.develop.exposureEV == 0.40)
    #expect(resolvedSidecarPreset.aiColor?.toneEqualizerEV.count == 8)

    // 2. Explicit CLI preset wins over sidecar.presetID.
    let resolvedExplicitPreset = EffectiveDevelopParams.resolve(
        preset: douyinJPG,
        delta: nil,
        sidecar: sidecar,
        cliOverrides: CLIDevelopOverrides(presetExplicitlySpecified: true),
        presetResolver: { presetsByID[$0] }
    )
    #expect(resolvedExplicitPreset.develop.sdrContrast == douyinJPG.developDefaults.sdrContrast)
    #expect(resolvedExplicitPreset.targetHeadroom.log2Value == douyinJPG.targetHeadroomStops)

    // 3. Full 4-tier merge: CLI > --delta-file > .chiaro.json > Preset.
    //    Also tests non-stacking exposureEVDelta and clearMaxLongEdgeOverride.
    let deltaFile = PerPhotoDelta(
        exposureEVDelta: 0.75, // Replaces sidecar 0.40 (does NOT stack to 1.15)
        sdrExposureEVDelta: -0.20, // Replaces sidecar 0.25
        sdrToneMapperOverride: .openDRT,
        clearMaxLongEdgeOverride: true, // Clears sidecar's 2048 and preset's 2048
        clarityOverride: 42.0,
        opticalSharpnessOverride: 55.0,
        demosaicOverride: .dcb
    )
    let cli = CLIDevelopOverrides(
        presetExplicitlySpecified: true,
        backend: .libraw,
        demosaic: .dht, // CLI beats deltaFile (.dcb) and sidecar (.lmmse)
        denoiseMode: .off,
        denoiseLuma: 150.0, // Clamped to 100.0
        denoiseChroma: -10.0, // Clamped to 0.0
        lensSource: .lensfun,
        lensVignettingStrength: 1.5, // Clamped to 1.0
        toneMapper: .sigmoid, // CLI beats deltaFile (.openDRT) and sidecar (.neutralRational)
        clarity: 150.0, // Clamped to 100.0
        opticalSharpness: -20.0 // Clamped to 0.0
    )

    let resolvedAll = EffectiveDevelopParams.resolve(
        preset: appleHEIC,
        delta: deltaFile,
        sidecar: sidecar,
        cliOverrides: cli,
        presetResolver: { presetsByID[$0] }
    )
    #expect(abs(resolvedAll.develop.exposureEV - 0.75) < 1e-9)
    #expect(abs(resolvedAll.develop.sdrExposureEV - (-0.20)) < 1e-9)
    #expect(resolvedAll.develop.shadowRecovery == 30.0) // Preserved from sidecar
    #expect(resolvedAll.develop.clarity == 100.0)
    #expect(resolvedAll.develop.opticalSharpness == 0.0)
    #expect(resolvedAll.sdrToneMapper == .sigmoid)
    #expect(resolvedAll.maxLongEdge == nil)
    #expect(resolvedAll.decodeBackend == .libraw)
    #expect(resolvedAll.demosaic == .dht)
    #expect(resolvedAll.optics.source == .lensfun)
    #expect(resolvedAll.optics.autoScale == false) // Preserved from sidecar
    #expect(resolvedAll.optics.vignettingStrength == 1.0)
    #expect(resolvedAll.denoise.mode == .off)
    #expect(resolvedAll.denoise.luminanceStrength == 100.0)
    #expect(resolvedAll.denoise.chromaStrength == 0.0)

    // 4. NaN sanitization in clarity, opticalSharpness, optics, denoise.
    let nanDelta = PerPhotoDelta(
        clarityOverride: .nan,
        opticalSharpnessOverride: .infinity,
        opticsOverride: OpticalCorrectionParameters(vignettingStrength: .nan),
        denoiseOverride: DenoiseParameters(luminanceStrength: .nan, chromaStrength: .infinity, detailPreservation: -.infinity)
    )
    let resolvedSanitized = EffectiveDevelopParams.resolve(preset: appleHEIC, delta: nanDelta)
    #expect(resolvedSanitized.develop.clarity == 0.0)
    #expect(resolvedSanitized.develop.opticalSharpness == 0.0)
    #expect(resolvedSanitized.optics.vignettingStrength == 1.0)
    #expect(resolvedSanitized.denoise.luminanceStrength == 25.0)
    #expect(resolvedSanitized.denoise.chromaStrength == 65.0)
    #expect(resolvedSanitized.denoise.detailPreservation == 70.0)
}

@Test
func testSensorNoiseProfileLogISOInterpolationAndBoundaryClamping() throws {
    // Unsorted ISO points + slightly negative input to verify non-negative clamping.
    let profile = SensorNoiseProfile(
        maker: "SONY",
        model: "ILCE-7CM2",
        profiles: [
            SensorNoiseProfilePoint(name: "ISO 1600", iso: 1600, a: [3.0e-5, 2.0e-5, 4.0e-5], b: [3.0e-7, 2.0e-7, 4.0e-7]),
            SensorNoiseProfilePoint(name: "ISO 400", iso: 400, a: [1.0e-5, 0.8e-5, 1.2e-5], b: [1.0e-7, 0.8e-7, 1.2e-7]),
            SensorNoiseProfilePoint(name: "ISO 6400", iso: 6400, a: [1.2e-4, 0.8e-4, 1.6e-4], b: [1.2e-6, 0.8e-6, 1.6e-6]),
            SensorNoiseProfilePoint(name: "ISO 12800", iso: 12800, a: [2.4e-4, 1.6e-4, 3.2e-4], b: [2.4e-6, 1.6e-6, 3.2e-6]),
        ]
    )

    // Below minimum ISO clamps to lowest calibration point (ISO 400).
    let low = try #require(profile.interpolatedParameters(forISO: 50))
    #expect(abs(low.a.x - 1.0e-5) < 1e-12)
    #expect(abs(low.b.y - 0.8e-7) < 1e-14)

    // Above maximum ISO clamps to highest calibration point (ISO 12800).
    let high = try #require(profile.interpolatedParameters(forISO: 102400))
    #expect(abs(high.a.x - 2.4e-4) < 1e-12)
    #expect(abs(high.b.z - 3.2e-6) < 1e-14)

    // Exact log-domain midpoint between 400 and 1600 is geometric mean sqrt(400 * 1600) = 800 (t = 0.5).
    let mid800 = try #require(profile.interpolatedParameters(forISO: 800))
    #expect(abs(mid800.a.x - 2.0e-5) < 1e-12)
    #expect(abs(mid800.a.y - 1.4e-5) < 1e-12)
    #expect(abs(mid800.b.z - 2.6e-7) < 1e-14)

    // Intermediate ISO 10000 between 6400 and 12800 uses log(10000/6400)/log(2).
    let tExpected = (log(10000.0) - log(6400.0)) / (log(12800.0) - log(6400.0))
    let mid10000 = try #require(profile.interpolatedParameters(forISO: 10000))
    let expectedAX = (1.0 - tExpected) * 1.2e-4 + tExpected * 2.4e-4
    #expect(abs(mid10000.a.x - expectedAX) < 1e-12)

    // Empty or invalid profile returns nil.
    let emptyProfile = SensorNoiseProfile(maker: "SONY", model: "NONE", profiles: [])
    #expect(emptyProfile.interpolatedParameters(forISO: 800) == nil)

    // Darktable database wrapper round-trip & lookup.
    let dbJSON = """
    {
      "version": 0,
      "noiseprofiles": [
        {
          "maker": "SONY",
          "models": [
            {
              "model": "ILCE-7CM2",
              "profiles": [
                { "name": "ILCE-7CM2 iso 100", "iso": 100, "a": [1e-6, 1e-6, 1e-6], "b": [1e-8, 1e-8, 1e-8] }
              ]
            }
          ]
        }
      ]
    }
    """
    let db = try JSONDecoder().decode(SensorNoiseProfileDatabase.self, from: Data(dbJSON.utf8))
    let lookedUp = try #require(db.profile(maker: "sony", model: "ilce-7cm2"))
    #expect(lookedUp.profiles.count == 1)
}

@Test
func testEmbeddedSonyOpticsPayloadActiveNodeSlicing() throws {
    // Full-frame 16-node payload
    let ffNodes: [Int16] = [0, 0, 5, 14, 27, 45, 68, 96, 130, 169, 213, 263, 318, 378, 440, 501]
    let ffPayload = EmbeddedSonyOpticsPayload(
        distortionNodeCount: 16,
        distortionParams: ffNodes,
        caNodeCount: 16,
        caRedParams: ffNodes,
        caBlueParams: ffNodes.map { -$0 },
        vignettingNodeCount: 16,
        vignettingParams: ffNodes,
        focalLengthMM: 49.0,
        fNumber: 4.0,
        sensorAspectRatio: 1.5,
        cropFactor: 1.0
    )
    #expect(ffPayload.distortionNodeCount == 16)
    #expect(ffPayload.distortionParams.count == 16)
    #expect(ffPayload.hasDistortion)
    #expect(ffPayload.hasTCA)
    #expect(ffPayload.hasVignetting)
    #expect(ffPayload.hasAnyCorrection)

    // APS-C 11-node payload with trailing non-zero FF values (Empirical Edge Case #2 from DSC02556.ARW)
    let rawAPSCWithTrailingFF: [Int16] = [-4, 0, 9, 21, 38, 60, 88, 122, 163, 210, 264, 320, 383, 451, 528, 611]
    let apscPayload = EmbeddedSonyOpticsPayload(
        distortionNodeCount: 11,
        distortionParams: rawAPSCWithTrailingFF,
        caNodeCount: 11,
        caRedParams: rawAPSCWithTrailingFF,
        caBlueParams: rawAPSCWithTrailingFF,
        vignettingNodeCount: 11,
        vignettingParams: rawAPSCWithTrailingFF,
        focalLengthMM: 200.0,
        fNumber: 5.6,
        sensorAspectRatio: 1.5,
        cropFactor: 1.5
    )
    #expect(apscPayload.distortionNodeCount == 11)
    #expect(apscPayload.distortionParams == Array(rawAPSCWithTrailingFF.prefix(11)))
    #expect(apscPayload.distortionParams.last == 264)
    #expect(apscPayload.caNodeCount == 11)
    #expect(apscPayload.caRedParams.count == 11)
    #expect(apscPayload.caBlueParams.count == 11)
    #expect(apscPayload.vignettingNodeCount == 11)
    #expect(apscPayload.vignettingParams.count == 11)

    // Out-of-bounds nc (>16 or <0) safely clamped
    let clampedPayload = EmbeddedSonyOpticsPayload(
        distortionNodeCount: 99,
        distortionParams: Array(repeating: Int16(1), count: 20),
        caNodeCount: -3,
        caRedParams: [1, 2],
        caBlueParams: [3, 4]
    )
    #expect(clampedPayload.distortionNodeCount == 16)
    #expect(clampedPayload.distortionParams.count == 16)
    #expect(clampedPayload.caNodeCount == 0)
    #expect(!clampedPayload.hasTCA)
    #expect(!clampedPayload.hasVignetting)

    // Keep EmbeddedSonyOpticsPayload strictly off WhitelistedExif (zero MakerNote property invariant)
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/DSC02532.ARW"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: 2, height: 2, colorSpace: .linearRec2020, data: Data()),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: 2, height: 2),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif(make: "SONY", model: "ILCE-7CM2", lensModel: "TAMRON 25-200mm F2.8-5.6 A075", focalLengthMM: 49.0, fNumber: 4.0, isoSpeedRatings: 1600),
        demosaicUsed: .amaze,
        embeddedSonyOptics: ffPayload,
        fullSensorDimensions: PixelDimensions(width: 7008, height: 4672),
        cropFactor: 1.0
    )
    #expect(frame.demosaicUsed == .amaze)
    #expect(frame.embeddedSonyOptics == ffPayload)
    #expect(frame.lensModel == "TAMRON 25-200mm F2.8-5.6 A075")
    #expect(frame.focalLengthMM == 49.0)
    #expect(frame.apertureFNumber == 4.0)
    #expect(frame.isoSpeed == 1600)
    let exifLabels = Mirror(reflecting: frame.exif).children.compactMap { $0.label?.lowercased() }
    #expect(!exifLabels.contains(where: { $0.contains("makernote") || $0.contains("optics") }))
}

@Test
func testAIFutureContractsCodableAndNormalization() throws {
    // Unknown future denoise mode safely falls back to .off
    let futureDenoiseJSON = """
    {
      "mode": "v5QuantumANE",
      "luminanceStrength": 40.0,
      "chromaStrength": 120.0,
      "detailPreservation": -5.0,
      "preferANE": true,
      "modelID": "chiaro-nafnet-v2"
    }
    """
    let decodedDenoise = try JSONDecoder().decode(DenoiseParameters.self, from: Data(futureDenoiseJSON.utf8))
    #expect(decodedDenoise.mode == .off)
    #expect(decodedDenoise.luminanceStrength == 40.0)
    #expect(decodedDenoise.chromaStrength == 100.0)
    #expect(decodedDenoise.detailPreservation == 0.0)
    #expect(decodedDenoise.modelID == "chiaro-nafnet-v2")

    // AIColorGradingParameters normalizes toneEqualizerEV to 8 bands clamped to [-3, +3]
    let aiColor = AIColorGradingParameters(
        enabled: true,
        shadows: ColorBalanceWheelAdjustment(hueDegrees: 220.0, chroma: 0.3, luminanceOffset: -0.1),
        midtones: ColorBalanceWheelAdjustment(hueDegrees: 45.0, chroma: 0.2, luminanceOffset: 0.05),
        highlights: ColorBalanceWheelAdjustment(hueDegrees: 35.0, chroma: 0.4, luminanceOffset: 0.15),
        global: ColorBalanceWheelAdjustment(hueDegrees: 0.0, chroma: 0.0, luminanceOffset: 0.0),
        brilliance: 150.0,
        chroma: -150.0,
        toneEqualizerEV: [-5.0, 1.5, .nan]
    )
    #expect(aiColor.brilliance == 100.0)
    #expect(aiColor.chroma == -100.0)
    #expect(aiColor.toneEqualizerEV == [-3.0, 1.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    let aiColorData = try JSONEncoder().encode(aiColor)
    let aiColorRoundTrip = try JSONDecoder().decode(AIColorGradingParameters.self, from: aiColorData)
    #expect(aiColorRoundTrip == aiColor)

    // ChiaroAgentRecipe & AgentImageContext Codable round-trip
    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let context = AgentImageContext(
        previewJPEGData: Data([0xFF, 0xD8, 0xFF]),
        heatmapJPEGData: nil,
        exif: WhitelistedExif(make: "SONY", model: "ILCE-7CM2", isoSpeedRatings: 6400),
        estimatedSceneKelvin: 4200.0,
        histogram: AgentHistogramSummary(
            shadowFraction: 0.45,
            midtoneFraction: 0.35,
            highlightFraction: 0.15,
            hdrAboveWhiteFraction: 0.05
        ),
        currentParams: EffectiveDevelopParams.resolve(preset: preset),
        userPrompt: "Keep warm lantern highlights and clean dark sky."
    )
    let contextData = try JSONEncoder().encode(context)
    let contextRoundTrip = try JSONDecoder().decode(AgentImageContext.self, from: contextData)
    #expect(contextRoundTrip == context)

    let recipe = ChiaroAgentRecipe(
        developPatch: PerPhotoDelta(exposureEVDelta: -0.25, clarityOverride: 10.0),
        colorGradingNodes: aiColor,
        recommendedDenoise: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 35.0, chromaStrength: 75.0),
        rationale: LocalizedText(zhHans: "保留灯笼暖调并压低夜空噪点。", en: "Preserve warm lantern highlights and reduce night sky noise.")
    )
    let recipeData = try JSONEncoder().encode(recipe)
    let recipeRoundTrip = try JSONDecoder().decode(ChiaroAgentRecipe.self, from: recipeData)
    #expect(recipeRoundTrip == recipe)
}

@Test
func testEffectiveDevelopParamsHonorsSidecarDeltaOverridesAndNonFiniteFallback() throws {
    let appleHEIC = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    let scOptics = OpticalCorrectionParameters(
        enabled: true,
        source: .lensfun,
        distortion: false,
        autoScale: false,
        tca: true,
        vignetting: true,
        vignettingStrength: 0.45
    )
    let scDenoise = DenoiseParameters(
        mode: .coreMLANE,
        luminanceStrength: 42.0,
        chromaStrength: 78.0,
        detailPreservation: 55.0,
        preferANE: true,
        modelID: "chiaro-nafnet-v2"
    )
    let scAIColor = AIColorGradingParameters(
        enabled: true,
        brilliance: 15.0,
        chroma: -12.0,
        toneEqualizerEV: [0.25, -0.25]
    )

    // 1. All 5 sidecar.delta.*Override fields honored when top-level sidecar fields are nil.
    let sidecarDeltaOnly = ChiaroSidecar(
        decodeBackend: nil,
        demosaic: nil,
        optics: nil,
        delta: PerPhotoDelta(
            targetHeadroomStopsOverride: 3.2,
            midtoneAnchorPOverride: 0.88,
            decodeBackendOverride: .ciraw9,
            demosaicOverride: .lmmse,
            opticsOverride: scOptics,
            denoiseOverride: scDenoise,
            aiColorOverride: scAIColor
        ),
        denoise: nil,
        aiColor: nil
    )

    let resolvedFromSidecarDelta = EffectiveDevelopParams.resolve(
        preset: appleHEIC,
        delta: nil,
        sidecar: sidecarDeltaOnly
    )
    #expect(resolvedFromSidecarDelta.decodeBackend == .ciraw9)
    #expect(resolvedFromSidecarDelta.demosaic == .lmmse)
    #expect(resolvedFromSidecarDelta.optics == scOptics)
    #expect(resolvedFromSidecarDelta.denoise == scDenoise)
    #expect(resolvedFromSidecarDelta.aiColor == scAIColor)
    #expect(resolvedFromSidecarDelta.targetHeadroom.log2Value == 3.2)
    #expect(resolvedFromSidecarDelta.midtoneAnchorP == 0.88)

    // 2. When sidecar.delta.*Override is nil, top-level sidecar.* is used.
    let sidecarTopLevel = ChiaroSidecar(
        decodeBackend: .ciraw9,
        demosaic: .dcb,
        optics: scOptics,
        delta: PerPhotoDelta(exposureEVDelta: 0.2),
        denoise: scDenoise,
        aiColor: scAIColor
    )
    let resolvedTopLevel = EffectiveDevelopParams.resolve(
        preset: appleHEIC,
        delta: nil,
        sidecar: sidecarTopLevel
    )
    #expect(resolvedTopLevel.decodeBackend == .ciraw9)
    #expect(resolvedTopLevel.demosaic == .dcb)
    #expect(resolvedTopLevel.optics == scOptics)
    #expect(resolvedTopLevel.denoise == scDenoise)
    #expect(resolvedTopLevel.aiColor == scAIColor)

    // 3. NaN/Inf in delta headroom & anchorP falls back cleanly to sidecar (not skipping sidecar to preset),
    //    and deltaFile + CLI override sidecar.delta.*Override.
    let deltaOverrides = PerPhotoDelta(
        exposureEVDelta: 10.0, // Finite out-of-range kept by sanitized() and clamped to 3.0 by resolve
        targetHeadroomStopsOverride: .nan,
        midtoneAnchorPOverride: .infinity,
        decodeBackendOverride: .libraw,
        demosaicOverride: .dht,
        opticsOverride: OpticalCorrectionParameters(source: .embedded, vignettingStrength: 0.9),
        denoiseOverride: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 12.0),
        aiColorOverride: AIColorGradingParameters(enabled: false, brilliance: 5.0)
    )
    #expect(deltaOverrides.sanitized().exposureEVDelta == 10.0)

    let resolvedDeltaOverSidecar = EffectiveDevelopParams.resolve(
        preset: appleHEIC,
        delta: deltaOverrides,
        sidecar: sidecarDeltaOnly
    )
    #expect(resolvedDeltaOverSidecar.develop.exposureEV == 3.0)
    #expect(resolvedDeltaOverSidecar.targetHeadroom.log2Value == 3.2)
    #expect(resolvedDeltaOverSidecar.midtoneAnchorP == 0.88)
    #expect(resolvedDeltaOverSidecar.decodeBackend == .libraw)
    #expect(resolvedDeltaOverSidecar.demosaic == .dht)
    #expect(resolvedDeltaOverSidecar.optics.source == .embedded)
    #expect(resolvedDeltaOverSidecar.denoise.mode == .profiledWavelet)
    #expect(resolvedDeltaOverSidecar.aiColor?.brilliance == 5.0)

    let cliOverrides = CLIDevelopOverrides(
        backend: .ciraw9,
        demosaic: .ahd,
        denoiseMode: .off,
        lensSource: .auto
    )
    let resolvedCLI = EffectiveDevelopParams.resolve(
        preset: appleHEIC,
        delta: deltaOverrides,
        sidecar: sidecarDeltaOnly,
        cliOverrides: cliOverrides
    )
    #expect(resolvedCLI.decodeBackend == .ciraw9)
    #expect(resolvedCLI.demosaic == .ahd)
    #expect(resolvedCLI.denoise.mode == .off)
    #expect(resolvedCLI.optics.source == .auto)
}
