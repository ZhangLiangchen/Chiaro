import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct InspectorView: View {
    @Bindable var viewModel: AppViewModel

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    private var effective: EffectiveDevelopParams {
        viewModel.selectedEffectiveParams
    }

    private var showInline: Bool {
        viewModel.showInlineParameterSummaries
    }

    var body: some View {
        ScrollView {
            ChiaroGlassContainer(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    scopeAndHeaderSection
                    group1DecodeDenoiseOpticsSection
                    group2SharedBaseSection
                    group3SDRControlsSection
                    group4HDRGainMapSection
                    group5CompositionSection
                }
                .padding(12)
            }
        }
        .frame(minWidth: 320, idealWidth: 345, maxWidth: 380)
        .background(.background)
    }

    // MARK: - Scope & Header

    private var scopeAndHeaderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DocumentedPicker(
                parameterID: .editScope,
                language: lang,
                showInlineSummary: showInline,
                selection: $viewModel.editScope,
                pickerStyleSegmented: true
            ) {
                ForEach(InspectorEditScope.allCases) { scope in
                    Text(scope.label(for: lang)).tag(scope)
                }
            }

            if viewModel.editScope == .perPhotoDelta {
                HStack(spacing: 6) {
                    Button(ChiaroStrings.resetSelectedDeltaButton(lang)) {
                        viewModel.resetSelectedDelta()
                    }
                    .controlSize(.small)
                    .disabled(!viewModel.selectedHasDelta)

                    Button(ChiaroStrings.syncToAllButton(lang)) {
                        viewModel.syncSelectedDeltaToAll()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.items.count < 2)

                    Spacer()

                    Menu(ChiaroStrings.deltaJSONMenu(lang)) {
                        Button(ChiaroStrings.importDeltaMenu(lang)) {
                            viewModel.presentImportDeltaPanel()
                        }
                        Button(ChiaroStrings.exportDeltaMenu(lang)) {
                            viewModel.presentExportDeltaPanel()
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                Text(ChiaroStrings.globalPresetNotice(
                    ChiaroStrings.presetName(viewModel.activePreset, lang: lang),
                    lang: lang
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            DocumentedToggle(
                parameterID: .autoSaveSidecar,
                language: lang,
                showInlineSummary: showInline,
                isOn: $viewModel.autoSaveSidecar
            )

            DocumentedToggle(
                parameterID: .showInlineParameterSummaries,
                language: lang,
                showInlineSummary: false,
                isOn: $viewModel.showInlineParameterSummaries
            )
        }
        .padding(10)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    // MARK: - Group 1: Decode, Denoise & Open-Source Optics

    private var group1DecodeDenoiseOpticsSection: some View {
        DisclosureGroup(ChiaroStrings.group1Title(lang), isExpanded: $viewModel.expandGroup1) {
            VStack(alignment: .leading, spacing: 10) {
                DocumentedPicker(
                    parameterID: .decodeBackend,
                    language: lang,
                    showInlineSummary: showInline,
                    selection: Binding(
                        get: { effective.decodeBackend },
                        set: { viewModel.updateDecodeBackend($0) }
                    )
                ) {
                    Text(ChiaroStrings.librawLabel(lang)).tag(RAWBackend.libraw)
                    Text(ChiaroStrings.ciraw9Label(lang)).tag(RAWBackend.ciraw9)
                }

                DocumentedPicker(
                    parameterID: .demosaicAlgorithm,
                    language: lang,
                    showInlineSummary: showInline,
                    selection: Binding(
                        get: { effective.demosaic },
                        set: { viewModel.updateDemosaicAlgorithm($0) }
                    )
                ) {
                    ForEach(DemosaicAlgorithm.allCases, id: \.self) { alg in
                        Text(ChiaroStrings.demosaicName(alg, lang: lang)).tag(alg)
                    }
                }
                .disabled(effective.decodeBackend == .ciraw9)

                DocumentedToggle(
                    parameterID: .writeCustomRenderedHDR,
                    language: lang,
                    showInlineSummary: showInline,
                    isOn: $viewModel.writeCustomRenderedHDR
                )

                Divider()

                DocumentedToggle(
                    parameterID: .denoiseEnabled,
                    language: lang,
                    showInlineSummary: showInline,
                    isOn: Binding(
                        get: { effective.denoise.mode != .off },
                        set: { viewModel.updateDenoiseEnabled($0) }
                    )
                )

                if effective.denoise.mode != .off {
                    DocumentedPicker(
                        parameterID: .denoiseMode,
                        language: lang,
                        showInlineSummary: showInline,
                        selection: Binding(
                            get: { effective.denoise.mode },
                            set: { viewModel.updateDenoiseMode($0) }
                        )
                    ) {
                        Text(ChiaroStrings.denoiseModeName(.profiledWavelet, lang: lang)).tag(DenoiseEngineMode.profiledWavelet)
                        Text(ChiaroStrings.denoiseModeName(.appleCIRAWv9ANE, lang: lang)).tag(DenoiseEngineMode.appleCIRAWv9ANE)
                        Text(ChiaroStrings.denoiseModeName(.off, lang: lang)).tag(DenoiseEngineMode.off)
                    }

                    DocumentedSlider(
                        parameterID: .denoiseChromaStrength,
                        language: lang,
                        showInlineSummary: showInline,
                        value: effective.denoise.chromaStrength,
                        range: 0...100,
                        format: "%.0f"
                    ) { viewModel.updateDenoiseChroma($0) }

                    DocumentedSlider(
                        parameterID: .denoiseLuminanceStrength,
                        language: lang,
                        showInlineSummary: showInline,
                        value: effective.denoise.luminanceStrength,
                        range: 0...100,
                        format: "%.0f"
                    ) { viewModel.updateDenoiseLuminance($0) }

                    DocumentedSlider(
                        parameterID: .denoiseDetailPreservation,
                        language: lang,
                        showInlineSummary: showInline,
                        value: effective.denoise.detailPreservation,
                        range: 0...100,
                        format: "%.0f"
                    ) { viewModel.updateDenoiseDetail($0) }
                }

                Divider()

                DocumentedToggle(
                    parameterID: .opticsEnabled,
                    language: lang,
                    showInlineSummary: showInline,
                    isOn: Binding(
                        get: { effective.optics.enabled },
                        set: { viewModel.updateOpticsEnabled($0) }
                    )
                )

                Text(ChiaroStrings.opticsResolutionBadge(viewModel.currentOpticsInfo, lang: lang))
                    .font(.caption2)
                    .foregroundStyle(viewModel.currentOpticsInfo.source == .none ? Color.secondary : Color.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (viewModel.currentOpticsInfo.source == .none ? Color.secondary : Color.green).opacity(0.14),
                        in: Capsule()
                    )

                if effective.optics.enabled {
                    DocumentedPicker(
                        parameterID: .opticsSource,
                        language: lang,
                        showInlineSummary: showInline,
                        selection: Binding(
                            get: { effective.optics.source },
                            set: { viewModel.updateOpticsSource($0) }
                        )
                    ) {
                        ForEach(OpticalProfileSource.allCases, id: \.self) { src in
                            Text(ChiaroStrings.opticsSourceName(src, lang: lang)).tag(src)
                        }
                    }

                    DocumentedToggle(
                        parameterID: .opticsDistortion,
                        language: lang,
                        showInlineSummary: showInline,
                        isOn: Binding(
                            get: { effective.optics.distortion },
                            set: { viewModel.updateOpticsDistortion($0) }
                        )
                    )

                    DocumentedToggle(
                        parameterID: .opticsAutoScale,
                        language: lang,
                        showInlineSummary: showInline,
                        isOn: Binding(
                            get: { effective.optics.autoScale },
                            set: { viewModel.updateOpticsAutoScale($0) }
                        )
                    )

                    DocumentedToggle(
                        parameterID: .opticsTCA,
                        language: lang,
                        showInlineSummary: showInline,
                        isOn: Binding(
                            get: { effective.optics.tca },
                            set: { viewModel.updateOpticsTCA($0) }
                        )
                    )

                    DocumentedToggle(
                        parameterID: .opticsVignetting,
                        language: lang,
                        showInlineSummary: showInline,
                        isOn: Binding(
                            get: { effective.optics.vignetting },
                            set: { viewModel.updateOpticsVignetting($0) }
                        )
                    )

                    if effective.optics.vignetting {
                        DocumentedSlider(
                            parameterID: .opticsVignettingStrength,
                            language: lang,
                            showInlineSummary: showInline,
                            value: effective.optics.vignettingStrength * 100.0,
                            range: 0...100,
                            format: "%.0f%%"
                        ) { viewModel.updateOpticsVignettingStrength($0 / 100.0) }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        DocumentedPicker(
                            parameterID: .opticsLensfunLensOverride,
                            language: lang,
                            showInlineSummary: showInline,
                            selection: Binding(
                                get: { effective.optics.lensfunLensOverride ?? "" },
                                set: { newVal in
                                    viewModel.updateLensfunOverride(lens: newVal.isEmpty ? nil : newVal)
                                }
                            )
                        ) {
                            Text(ChiaroStrings.lensfunAutoLabel(lang)).tag("")
                            ForEach(viewModel.availableLensfunLenses, id: \.self) { lensName in
                                Text(lensName).tag(lensName)
                            }
                        }

                        Button(ChiaroStrings.importLensfunXMLButton(lang)) {
                            viewModel.presentImportLensfunXMLPanel()
                        }
                        .chiaroGlassButtonStyle(prominent: false)
                        .controlSize(.small)
                    }
                    .onAppear {
                        if viewModel.availableLensfunLenses.isEmpty {
                            viewModel.refreshAvailableLensfunLenses()
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(10)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    // MARK: - Group 2: Shared Base Grading

    private var group2SharedBaseSection: some View {
        DisclosureGroup(ChiaroStrings.group2Title(lang), isExpanded: $viewModel.expandGroup2) {
            VStack(alignment: .leading, spacing: 10) {
                let isCustomWB: Bool = {
                    if case .custom = effective.develop.whiteBalance { return true }
                    return false
                }()

                DocumentedPicker(
                    parameterID: .whiteBalanceMode,
                    language: lang,
                    showInlineSummary: showInline,
                    selection: Binding(
                        get: { isCustomWB ? 1 : 0 },
                        set: { mode in
                            if mode == 0 {
                                viewModel.updateWhiteBalance(.asShot)
                            } else {
                                let k = viewModel.currentEstimatedKelvin ?? 5500.0
                                viewModel.updateWhiteBalance(.custom(temperatureKelvin: k, tint: 0.0))
                            }
                        }
                    )
                ) {
                    Text(ChiaroStrings.asShotLabel(lang)).tag(0)
                    Text(ChiaroStrings.customWBLabel(lang)).tag(1)
                }

                if case let .custom(kelvin, tint) = effective.develop.whiteBalance {
                    DocumentedSlider(
                        parameterID: .whiteBalanceKelvin,
                        language: lang,
                        showInlineSummary: showInline,
                        value: kelvin,
                        range: 2000...15000,
                        format: "%.0f K"
                    ) { newK in
                        viewModel.updateWhiteBalance(.custom(temperatureKelvin: newK, tint: tint))
                    }

                    DocumentedSlider(
                        parameterID: .whiteBalanceTint,
                        language: lang,
                        showInlineSummary: showInline,
                        value: tint,
                        range: -150...150,
                        format: "%+.0f"
                    ) { newT in
                        viewModel.updateWhiteBalance(.custom(temperatureKelvin: kelvin, tint: newT))
                    }
                } else if let estK = viewModel.currentEstimatedKelvin {
                    Text(ChiaroStrings.estimatedWBReadout(estK, lang: lang))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                DocumentedSlider(
                    parameterID: .exposureEV,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.exposureEV,
                    range: -3.0...3.0,
                    format: "%+.2f EV"
                ) { viewModel.updateExposureEV($0) }

                DocumentedSlider(
                    parameterID: .shadowRecovery,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.shadowRecovery,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateShadowRecovery($0) }

                DocumentedSlider(
                    parameterID: .blackPoint,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.blackPoint,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateBlackPoint($0) }

                DocumentedSlider(
                    parameterID: .clarity,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.clarity,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateClarity($0) }

                DocumentedSlider(
                    parameterID: .opticalSharpness,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.opticalSharpness,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateOpticalSharpness($0) }

                DocumentedSlider(
                    parameterID: .vibrance,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.vibrance,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateVibrance($0) }

                DocumentedPicker(
                    parameterID: .highlightReconstruction,
                    language: lang,
                    showInlineSummary: showInline,
                    selection: Binding(
                        get: { effective.develop.highlightReconstruction },
                        set: { viewModel.updateHighlightReconstruction($0) }
                    )
                ) {
                    ForEach(HighlightReconstructionMode.allCases, id: \.self) { mode in
                        Text(ChiaroStrings.highlightModeName(mode, lang: lang)).tag(mode)
                    }
                }

                // Camera Profile & Creative Look & DCP
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(ParameterDocumentationRegistry.doc(for: .cameraProfile).title.localized(for: lang))
                            .font(.caption)
                        ParameterHelpButton(parameterID: .cameraProfile, language: lang)
                        Spacer()
                        Menu(ChiaroStrings.cameraProfileLabel(effective.develop.cameraProfile, lang: lang)) {
                            Button(ChiaroStrings.cameraProfileLabel(.standard, lang: lang)) {
                                viewModel.updateCameraProfile(.standard)
                            }
                            Divider()
                            ForEach(CreativeLookOption.allCases) { look in
                                Button("Creative Look: \(look.displayName)") {
                                    viewModel.updateCameraProfile(.creativeLook(look.rawValue))
                                }
                            }
                            Divider()
                            Button(ChiaroStrings.loadDCPButton(lang)) {
                                viewModel.presentPickDCPPanel()
                            }
                        }
                        .controlSize(.small)
                    }
                    if showInline {
                        Text(ParameterDocumentationRegistry.doc(for: .cameraProfile).shortSummary.localized(for: lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Text(ParameterDocumentationRegistry.doc(for: .cubeLUT).title.localized(for: lang))
                            .font(.caption)
                        ParameterHelpButton(parameterID: .cubeLUT, language: lang)
                        Spacer()
                        if let lutPath = effective.develop.cubeLUTPath {
                            Text(URL(fileURLWithPath: lutPath).lastPathComponent)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(ChiaroStrings.clearShortButton(lang)) {
                                viewModel.clearCubeLUT()
                            }
                            .controlSize(.mini)
                        }
                        Button(ChiaroStrings.chooseCubeButton(lang)) {
                            viewModel.presentPickCubeLUTPanel()
                        }
                        .controlSize(.small)
                    }
                    if showInline {
                        Text(ParameterDocumentationRegistry.doc(for: .cubeLUT).shortSummary.localized(for: lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(10)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    // MARK: - Group 3: SDR Controls

    private var group3SDRControlsSection: some View {
        DisclosureGroup(ChiaroStrings.group3Title(lang), isExpanded: $viewModel.expandGroup3) {
            VStack(alignment: .leading, spacing: 10) {
                DocumentedPicker(
                    parameterID: .sdrToneMapper,
                    language: lang,
                    showInlineSummary: showInline,
                    selection: Binding(
                        get: { effective.sdrToneMapper },
                        set: { viewModel.updateSDRToneMapper($0) }
                    )
                ) {
                    ForEach(SDRToneMapper.allCases, id: \.self) { mapper in
                        Text(ChiaroStrings.toneMapperName(mapper, lang: lang)).tag(mapper)
                    }
                }

                DocumentedSlider(
                    parameterID: .sdrExposureEV,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.sdrExposureEV,
                    range: -1.0...1.0,
                    format: "%+.2f EV"
                ) { viewModel.updateSDRExposureEV($0) }

                DocumentedSlider(
                    parameterID: .sdrHighlightCompression,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.sdrHighlightCompression,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateSDRHighlightCompression($0) }

                DocumentedSlider(
                    parameterID: .sdrContrast,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.sdrContrast,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateSDRContrast($0) }

                DocumentedSlider(
                    parameterID: .sdrSaturation,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.sdrSaturation,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateSDRSaturation($0) }
            }
            .padding(.top, 6)
        }
        .padding(10)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    // MARK: - Group 4: HDR & Gain Map

    private var group4HDRGainMapSection: some View {
        DisclosureGroup(ChiaroStrings.group4Title(lang), isExpanded: $viewModel.expandGroup4) {
            VStack(alignment: .leading, spacing: 10) {
                DocumentedSlider(
                    parameterID: .targetHeadroomStops,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.targetHeadroom.log2Value,
                    range: 1.0...4.0,
                    format: "+%.2f EV"
                ) { viewModel.updateTargetHeadroomStops($0) }

                DocumentedSlider(
                    parameterID: .midtoneAnchorP,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.midtoneAnchorP,
                    range: 0.65...0.95,
                    format: "%.2f"
                ) { viewModel.updateMidtoneAnchorP($0) }

                DocumentedSlider(
                    parameterID: .hdrHighlightExcitation,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.hdrHighlightExcitation,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateHDRHighlightExcitation($0) }

                DocumentedSlider(
                    parameterID: .hdrRolloffSoftness,
                    language: lang,
                    showInlineSummary: showInline,
                    value: effective.develop.hdrRolloffSoftness,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateHDRRolloffSoftness($0) }

                VStack(alignment: .leading, spacing: 4) {
                    DocumentedPicker(
                        parameterID: .gainMapChannels,
                        language: lang,
                        showInlineSummary: showInline,
                        selection: Binding(
                            get: { viewModel.activePreset.gainMapChannels },
                            set: { viewModel.setGainMapChannels($0) }
                        ),
                        pickerStyleSegmented: true,
                        pickerWidth: 165
                    ) {
                        Text(ChiaroStrings.mono1chLabel(lang)).tag(GainMapChannels.mono1ch)
                        Text(ChiaroStrings.rgb3chLabel(lang)).tag(GainMapChannels.rgb3ch)
                    }
                    .disabled(viewModel.isRGB3chGainMapRestricted)

                    if viewModel.isRGB3chGainMapRestricted {
                        Text(ChiaroStrings.rgb3chRestrictedNotice(lang))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                DocumentedPicker(
                    parameterID: .gainMapResolution,
                    language: lang,
                    showInlineSummary: showInline,
                    selection: Binding(
                        get: { viewModel.activePreset.gainMapResolution },
                        set: { viewModel.setGainMapResolution($0) }
                    ),
                    pickerStyleSegmented: true,
                    pickerWidth: 165
                ) {
                    Text(ChiaroStrings.halfResLabel(lang)).tag(GainMapResolution.half)
                    Text(ChiaroStrings.fullResLabel(lang)).tag(GainMapResolution.full)
                }

                DocumentedSlider(
                    parameterID: .gainMapGamma,
                    language: lang,
                    showInlineSummary: showInline,
                    value: viewModel.activePreset.gainMapGamma,
                    range: 0.25...4.0,
                    format: "%.2f"
                ) { viewModel.setGainMapGamma($0) }

                DocumentedToggle(
                    parameterID: .closedLoopSDRCompensation,
                    language: lang,
                    showInlineSummary: showInline,
                    isOn: $viewModel.activePreset.compatOptions.closedLoopSDRCompensation
                )

                DocumentedToggle(
                    parameterID: .writeLegacyAppleHDRGainMap,
                    language: lang,
                    showInlineSummary: showInline,
                    isOn: Binding(
                        get: { viewModel.activePreset.compatOptions.writeLegacyAppleHDRGainMap },
                        set: { viewModel.setLegacyAppleGainMap($0) }
                    )
                )
            }
            .padding(.top, 6)
        }
        .padding(10)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    // MARK: - Group 5: Composition & Output Guardrails

    private var group5CompositionSection: some View {
        DisclosureGroup(ChiaroStrings.group5Title(lang), isExpanded: $viewModel.expandGroup5) {
            VStack(alignment: .leading, spacing: 10) {
                DocumentedPicker(
                    parameterID: .cropAspect,
                    language: lang,
                    showInlineSummary: showInline,
                    selection: Binding(
                        get: { effective.cropAspect },
                        set: { viewModel.updateCropAspect($0) }
                    )
                ) {
                    ForEach(AspectRatio.allCases, id: \.self) { aspect in
                        Text(ChiaroStrings.aspectLabel(aspect, lang: lang)).tag(aspect)
                    }
                }

                if effective.cropAspect != .original {
                    DocumentedSlider(
                        parameterID: .cropOffsetX,
                        language: lang,
                        showInlineSummary: showInline,
                        value: effective.cropOffset.normalizedCenterX,
                        range: 0.0...1.0,
                        format: "%.2f"
                    ) { viewModel.updateCropOffsetX($0) }

                    DocumentedSlider(
                        parameterID: .cropOffsetY,
                        language: lang,
                        showInlineSummary: showInline,
                        value: effective.cropOffset.normalizedCenterY,
                        range: 0.0...1.0,
                        format: "%.2f"
                    ) { viewModel.updateCropOffsetY($0) }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(ParameterDocumentationRegistry.doc(for: .maxLongEdge).title.localized(for: lang))
                            .font(.caption)
                        ParameterHelpButton(parameterID: .maxLongEdge, language: lang)
                        Spacer()
                        Menu(ChiaroStrings.maxLongEdgeLabel(effective.maxLongEdge, lang: lang)) {
                            Button(ChiaroStrings.maxLongEdgeLabel(nil, lang: lang)) {
                                viewModel.updateMaxLongEdge(nil)
                            }
                            if !viewModel.activePreset.outputFormats.contains(.hlgMP4) {
                                Button("4096 px") { viewModel.updateMaxLongEdge(4096) }
                                Button(ChiaroStrings.maxLongEdgeMenu2048(lang)) {
                                    viewModel.updateMaxLongEdge(2048)
                                }
                            }
                            Button(ChiaroStrings.maxLongEdgeMenu1920(lang)) {
                                viewModel.updateMaxLongEdge(1920)
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Text(ChiaroStrings.customLongEdgeLabel(lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField(
                            ChiaroStrings.customLongEdgePlaceholder(lang),
                            value: Binding(
                                get: { effective.maxLongEdge },
                                set: { viewModel.updateMaxLongEdge($0) }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 85)
                        .controlSize(.small)
                    }

                    if showInline {
                        Text(ParameterDocumentationRegistry.doc(for: .maxLongEdge).shortSummary.localized(for: lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.activePreset.outputFormats.contains(.hlgMP4) {
                        Text(ChiaroStrings.hlgMaxEdgeNotice(lang))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(10)
        .chiaroGlassSurface(cornerRadius: 12)
    }
}
