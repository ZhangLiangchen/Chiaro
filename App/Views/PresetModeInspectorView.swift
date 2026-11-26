import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct PresetModeInspectorView: View {
    @Bindable var viewModel: AppViewModel
    private var isDraggingHDR = State(initialValue: false)
    private var isDraggingWB = State(initialValue: false)

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
            ChiaroGlassContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    if !viewModel.activeProOnlyOverrides.isEmpty {
                        proOverridesBanner
                    }

                    inlineDocsHeader
                    adjustmentsCard
                    autoEnhancementsCard
                    compositionAndExportCard
                }
                .padding(12)
            }
        }
        .frame(minWidth: 320, idealWidth: 345, maxWidth: 380)
        .background(.background)
    }

    private var proOverridesBanner: some View {
        let count = viewModel.activeProOnlyOverrides.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.below.square.and.square.filled")
                    .foregroundStyle(.orange)
                Text(ChiaroStrings.proOverridesBadge(count: count, lang: lang))
                    .font(.caption.weight(.semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                Button(ChiaroStrings.inspectInProButton(lang)) {
                    viewModel.workspaceMode = .pro
                }
                .chiaroGlassButtonStyle(prominent: false)
                .controlSize(.small)

                Button(ChiaroStrings.resetProOverridesButton(lang)) {
                    viewModel.resetProOnlyOverrides()
                }
                .chiaroGlassButtonStyle(prominent: false)
                .controlSize(.small)
            }
        }
        .padding(10)
        .chiaroGlassSurface(cornerRadius: 12, tint: Color.orange.opacity(0.22), interactive: true)
    }

    private var inlineDocsHeader: some View {
        HStack {
            DocumentedToggle(
                parameterID: .showInlineParameterSummaries,
                language: lang,
                showInlineSummary: false,
                isOn: $viewModel.showInlineParameterSummaries
            )
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var adjustmentsCard: some View {
        let rawHeadroom = effective.targetHeadroom.log2Value
        let clampedHeadroom = min(max(rawHeadroom, 1.0), 3.5)
        let isCustomWB: Bool = {
            if case .custom = effective.develop.whiteBalance { return true }
            return false
        }()
        let displayedKelvin: Double = {
            if case .custom(let kelvin, _) = effective.develop.whiteBalance {
                return kelvin
            }
            return min(max(viewModel.currentEstimatedKelvin ?? 5500.0, 2000.0), 15000.0)
        }()

        return VStack(alignment: .leading, spacing: 10) {
            Label(ChiaroStrings.presetSectionImageAdjustments(lang), systemImage: "sun.max.fill")
                .font(.subheadline.weight(.semibold))

            DocumentedSlider(
                parameterID: .exposureEV,
                language: lang,
                showInlineSummary: showInline,
                value: effective.develop.exposureEV,
                range: -3.0...3.0,
                format: "%+.2f EV"
            ) { viewModel.updateExposureEV($0) }

            VStack(alignment: .leading, spacing: 3) {
                DocumentedSlider(
                    parameterID: .targetHeadroomStops,
                    language: lang,
                    showInlineSummary: showInline,
                    value: clampedHeadroom,
                    range: 1.0...3.5,
                    format: "+%.2f EV",
                    displayOverrideText: String(format: "+%.2f EV", clampedHeadroom),
                    onEditingChanged: { editing in
                        isDraggingHDR.wrappedValue = editing
                    }
                ) { newVal in
                    if isDraggingHDR.wrappedValue || abs(newVal - clampedHeadroom) > 1e-3 {
                        viewModel.updatePresetModeHDRIntensity(newVal)
                    }
                }

                if rawHeadroom > 3.5 + 1e-3 {
                    Text(ChiaroStrings.proHeadroomPreservedHint(rawHeadroom, lang: lang))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            DocumentedSlider(
                parameterID: .shadowRecovery,
                language: lang,
                showInlineSummary: showInline,
                value: effective.develop.shadowRecovery,
                range: 0...100,
                format: "%.0f"
            ) { viewModel.updateShadowRecovery($0) }

            DocumentedSlider(
                parameterID: .clarity,
                language: lang,
                showInlineSummary: showInline,
                value: effective.develop.clarity,
                range: -100...100,
                format: "%+.0f"
            ) { viewModel.updateClarity($0) }

            DocumentedSlider(
                parameterID: .vibrance,
                language: lang,
                showInlineSummary: showInline,
                value: effective.develop.vibrance,
                range: -100...100,
                format: "%+.0f"
            ) { viewModel.updateVibrance($0) }

            VStack(alignment: .leading, spacing: 4) {
                DocumentedSlider(
                    parameterID: .whiteBalanceKelvin,
                    language: lang,
                    showInlineSummary: showInline,
                    value: displayedKelvin,
                    range: 2000...15000,
                    format: "%.0f K",
                    displayOverrideText: isCustomWB
                        ? String(format: "%.0f K", displayedKelvin)
                        : "\(ChiaroStrings.asShotLabel(lang)) · \(String(format: "%.0f K", displayedKelvin))",
                    onEditingChanged: { editing in
                        isDraggingWB.wrappedValue = editing
                    }
                ) { newKelvin in
                    if isDraggingWB.wrappedValue || abs(newKelvin - displayedKelvin) > 1.0 {
                        viewModel.updatePresetModeWhiteBalanceKelvin(newKelvin)
                    }
                }

                if isCustomWB {
                    HStack {
                        Spacer()
                        Button(ChiaroStrings.resetToAsShotButton(lang)) {
                            viewModel.updateWhiteBalance(.asShot)
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(12)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    private var autoEnhancementsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ChiaroStrings.presetSectionAutoEnhancements(lang), systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
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
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                DocumentedToggle(
                    parameterID: .denoiseEnabled,
                    language: lang,
                    showInlineSummary: showInline,
                    isOn: Binding(
                        get: { effective.denoise.mode != .off },
                        set: { viewModel.updateDenoiseEnabled($0) }
                    )
                )

                Text(ChiaroStrings.isoSpeedHint(viewModel.currentISO, lang: lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    private var compositionAndExportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ChiaroStrings.presetSectionCompositionExport(lang), systemImage: "crop")
                .font(.subheadline.weight(.semibold))

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

            Button {
                viewModel.showExportSheet = true
            } label: {
                HStack {
                    Spacer()
                    Label(
                        ChiaroStrings.exportWithActivePreset(
                            ChiaroStrings.presetName(viewModel.activePreset, lang: lang),
                            lang: lang
                        ),
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.callout.weight(.semibold))
                    Spacer()
                }
            }
            .chiaroGlassButtonStyle(prominent: true)
            .disabled(viewModel.items.isEmpty)
        }
        .padding(12)
        .chiaroGlassSurface(cornerRadius: 12)
    }
}
