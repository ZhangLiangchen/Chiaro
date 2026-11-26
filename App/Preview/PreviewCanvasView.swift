import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct PreviewCanvasView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    var body: some View {
        VStack(spacing: 10) {
            edrStatusAndControlsBar

            if viewModel.isSDRExternalMonitor {
                sdrMonitorBanner
            }

            previewViewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .chiaroGlassSurface(cornerRadius: 12)

            bottomMetadataAndHistogramBar
        }
        .padding(12)
        .background(.background)
    }

    private var edrStatusAndControlsBar: some View {
        ChiaroGlassContainer(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isSDRExternalMonitor ? (colorScheme == .dark ? Color.yellow : Color.orange) : Color.green)
                        .frame(width: 8, height: 8)
                    Text(ChiaroStrings.screenEDRBadge(
                        edr: viewModel.screenMaxEDR,
                        ev: log2(max(viewModel.screenMaxEDR, 1.0)),
                        lang: lang
                    ))
                    .font(.caption.monospacedDigit().weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .chiaroGlassSurface(in: Capsule())

                if viewModel.workspaceMode == .pro {
                    HStack(spacing: 4) {
                        Text(ChiaroStrings.iphoneSimulatorLabel(lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ParameterHelpButton(parameterID: .simulatedHeadroom, language: lang)

                        ForEach(AppViewModel.headroomPresetSteps, id: \.multiplier) { presetStep in
                            let selected = abs(viewModel.simulatedHeadroom.multiplier - presetStep.multiplier) < 0.05
                            Button {
                                viewModel.setSimulatedHeadroom(presetStep)
                            } label: {
                                let ev = Int(round(presetStep.toStops().log2Value))
                                Text("\(Int(presetStep.multiplier))× (+\(ev))")
                                    .font(.caption.monospacedDigit().weight(selected ? .semibold : .regular))
                            }
                            .chiaroGlassButtonStyle(prominent: selected)
                            .controlSize(.small)
                        }

                        Slider(
                            value: Binding(
                                get: { viewModel.simulatedHeadroom.multiplier },
                                set: { newVal in
                                    viewModel.setSimulatedHeadroom(LinearHeadroom(multiplier: newVal))
                                }
                            ),
                            in: 1.0...8.0,
                            onEditingChanged: { editing in
                                viewModel.isInteractingPreview = editing
                            }
                        )
                        .frame(width: 96)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    ParameterHelpButton(parameterID: .previewMode, language: lang)
                    modeButton(.standardEDR, systemImage: "sun.max")
                    modeButton(.splitScreenSwipe, systemImage: "rectangle.split.2x1")
                    if viewModel.workspaceMode == .pro {
                        modeButton(.falseColorHeatmap, systemImage: "flame")
                    }

                    Button {
                        viewModel.toggleGainMapView()
                    } label: {
                        Label(
                            ChiaroStrings.previewModeLabel(.gainMapDirectView, lang: lang),
                            systemImage: "square.stack.3d.down.right"
                        )
                        .font(.caption)
                    }
                    .chiaroGlassButtonStyle(prominent: viewModel.previewMode == .gainMapDirectView)
                    .tint(viewModel.previewMode == .gainMapDirectView ? .orange : .secondary)
                    .controlSize(.small)
                    .keyboardShortcut(KeyEquivalent("g"), modifiers: [])
                    .help(ChiaroStrings.gainMapHelpText(lang))
                }
            }
        }
    }

    private func modeButton(_ mode: EDRPreviewMode, systemImage: String) -> some View {
        let active = viewModel.previewMode == mode
        return Button {
            viewModel.previewMode = mode
        } label: {
            Label(ChiaroStrings.previewModeLabel(mode, lang: lang), systemImage: systemImage)
                .font(.caption)
        }
        .chiaroGlassButtonStyle(prominent: active)
        .controlSize(.small)
    }

    private var sdrMonitorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(colorScheme == .dark ? Color.yellow : Color.orange)
            Text(ChiaroStrings.sdrMonitorBannerText(lang))
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 4) {
                Toggle(ChiaroStrings.sdrExposureScaleToggle(lang), isOn: $viewModel.sdrExposureScaleEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                ParameterHelpButton(parameterID: .sdrExposureScaleEnabled, language: lang)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .chiaroGlassSurface(
            cornerRadius: 8,
            tint: colorScheme == .dark ? Color.yellow.opacity(0.22) : Color.orange.opacity(0.16)
        )
    }

    @ViewBuilder
    private var previewViewport: some View {
        GeometryReader { geo in
            let frame = viewModel.currentRenderedFrame
            let fitted: CGRect = {
                if let frame {
                    let imgSize = CGSize(width: max(1, frame.width), height: max(1, frame.height))
                    return fittedRect(imageSize: imgSize, in: geo.size)
                } else {
                    return CGRect(origin: .zero, size: geo.size)
                }
            }()

            ZStack {
                // Keep a single EDRMetalPreviewView instance mounted across empty/loading/rendered states
                // so first-frame load never tears down and recreates the underlying MTKView.
                EDRMetalPreviewView(
                    renderedFrame: frame,
                    sharedShaderLibrary: viewModel.sharedShaderLibrary,
                    previewMode: frame == nil ? .standardEDR : viewModel.previewMode,
                    displayHeadroom: viewModel.simulatedHeadroom,
                    sdrExposureScaleEnabled: frame == nil ? false : viewModel.sdrExposureScaleEnabled,
                    splitPosition: viewModel.splitPosition,
                    baseColorSpace: viewModel.effectivePreviewColorSpace,
                    isInteracting: frame == nil ? false : viewModel.isInteractingPreview,
                    onScreenMaxEDRChanged: { maxEDR in
                        viewModel.updateScreenMaxEDR(maxEDR)
                    }
                )
                .frame(width: max(1, fitted.width), height: max(1, fitted.height))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.black.opacity(frame == nil ? 0.0 : 0.12), radius: 10, y: 3)
                .overlay(alignment: .topLeading) {
                    if frame != nil, viewModel.previewMode == .splitScreenSwipe {
                        splitOverlay(in: fitted.size)
                    }
                }
                .position(x: fitted.midX, y: fitted.midY)
                .opacity(frame == nil ? 0.0 : 1.0)

                if let selectedItem = viewModel.selectedItem {
                    if frame == nil {
                        if let err = viewModel.previewError {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.octagon")
                                    .font(.title)
                                    .foregroundStyle(.red)
                                Text(ChiaroStrings.renderFailedPrefix(err, lang: lang))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                        } else {
                            ProgressView(ChiaroStrings.renderingFileMessage(selectedItem.fileName, lang: lang))
                                .controlSize(.regular)
                        }
                    }

                    // Corner HUD overlays only (never tint/refract over the main image)
                    ChiaroGlassContainer(spacing: 8) {
                        VStack {
                            HStack(alignment: .top) {
                                if let fallback = viewModel.currentFallbackReason {
                                    Label(ChiaroStrings.fallbackBannerText(fallback, lang: lang), systemImage: "info.circle.fill")
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .chiaroGlassSurface(in: Capsule())
                                }
                                Spacer()
                                if viewModel.isRenderingPreview {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(6)
                                        .chiaroGlassSurface(in: Circle())
                                }
                            }
                            .padding(10)

                            Spacer()

                            HStack {
                                if viewModel.previewMode == .falseColorHeatmap {
                                    heatmapLegend
                                } else if viewModel.previewMode == .gainMapDirectView,
                                          let gm = frame?.gainMap {
                                    gainMapInfoPill(gm)
                                }
                                Spacer()
                            }
                            .padding(10)
                        }
                    }
                    .allowsHitTesting(false)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text(ChiaroStrings.emptyCanvasTitle(lang))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(ChiaroStrings.emptyCanvasSubtitle(lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button(ChiaroStrings.chooseARWFilesButton(lang)) {
                                viewModel.presentImportFilesPanel()
                            }
                            .chiaroGlassButtonStyle(prominent: true)
                            Button(ChiaroStrings.chooseFolderButton(lang)) {
                                viewModel.presentImportFolderPanel()
                            }
                            .chiaroGlassButtonStyle(prominent: false)
                        }
                    }
                    .padding(24)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func splitOverlay(in size: CGSize) -> some View {
        let clamped = CGFloat(min(max(viewModel.splitPosition, 0.0), 1.0))
        let xPos = clamped * size.width
        let dragGesture = DragGesture(minimumDistance: 0, coordinateSpace: .named("splitCanvas"))
            .onChanged { value in
                viewModel.isInteractingPreview = true
                let next = Float(value.location.x / max(size.width, 1))
                viewModel.splitPosition = min(max(next, 0.0), 1.0)
            }
            .onEnded { _ in
                viewModel.isInteractingPreview = false
            }

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture)

            HStack {
                Text(ChiaroStrings.splitSDRBadge(lang))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .chiaroGlassSurface(in: Capsule())
                Spacer()
                Text(String(format: "EDR (%.1f×)", viewModel.simulatedHeadroom.multiplier))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.90), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                    )
                    .foregroundStyle(.black)
            }
            .padding(10)
            .allowsHitTesting(false)

            VStack {
                Spacer()
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }
                .font(.caption2.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(.white, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.black.opacity(0.18), lineWidth: 0.75)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 4, y: 1)
                Spacer()
            }
            .frame(width: 34, height: size.height)
            .contentShape(Rectangle())
            .offset(x: xPos - 17)
            .gesture(dragGesture)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "splitCanvas")
    }

    private var heatmapLegend: some View {
        HStack(spacing: 10) {
            legendChip(color: .gray, text: ChiaroStrings.heatmapSDRChip(lang))
            legendChip(color: .cyan, text: "0–1 EV")
            legendChip(color: .green, text: "1–2 EV")
            legendChip(color: .orange, text: "2–3+ EV")
            legendChip(color: .pink, text: ChiaroStrings.heatmapClipChip(lang))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .chiaroGlassSurface(in: Capsule())
    }

    private func legendChip(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.caption2)
        }
    }

    private func gainMapInfoPill(_ gm: GainMapResult) -> some View {
        let chLabel = gm.buffer.channels == .mono1ch ? "1ch L008" : "3ch BGRA"
        let minV = gm.metadata.gainMapMin.first ?? 0.0
        let maxV = gm.metadata.gainMapMax.first ?? 0.0
        let gammaV = gm.metadata.gamma.first ?? 1.0
        return Text(ChiaroStrings.gainMapPill(
            chLabel: chLabel,
            w: gm.buffer.width,
            h: gm.buffer.height,
            minV: Float(minV),
            maxV: Float(maxV),
            gammaV: Float(gammaV),
            lang: lang
        ))
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .chiaroGlassSurface(in: Capsule())
    }

    private var bottomMetadataAndHistogramBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let frame = viewModel.currentRenderedFrame {
                HStack(spacing: 10) {
                    Text(exifSummary(frame.exif, width: frame.width, height: frame.height))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let kelvin = viewModel.currentEstimatedKelvin {
                        Text(ChiaroStrings.measuredKelvinLabel(kelvin, lang: lang))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.workspaceMode == .pro, !viewModel.isSDRExternalMonitor {
                        HStack(spacing: 4) {
                            Toggle(ChiaroStrings.sdrExposureScaleCompactToggle(lang), isOn: $viewModel.sdrExposureScaleEnabled)
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .font(.caption2)
                            ParameterHelpButton(parameterID: .sdrExposureScaleEnabled, language: lang)
                        }
                    }
                }
            }

            if viewModel.workspaceMode == .pro {
                DualZoneHistogramView(
                    bins: viewModel.histogramBins,
                    displayHeadroom: viewModel.simulatedHeadroom,
                    language: lang
                )
            }
        }
    }

    private func exifSummary(_ exif: WhitelistedExif, width: Int, height: Int) -> String {
        var parts: [String] = []
        if let model = exif.model { parts.append(model) }
        if let focal = exif.focalLengthMM { parts.append(String(format: "%.0fmm", focal)) }
        if let f = exif.fNumber { parts.append(String(format: "f/%.1f", f)) }
        if let exp = exif.exposureTimeSeconds, exp > 0 {
            if exp < 1.0 {
                parts.append("1/\(Int(round(1.0 / exp)))s")
            } else {
                parts.append(String(format: "%.1fs", exp))
            }
        }
        if let iso = exif.isoSpeedRatings { parts.append("ISO \(iso)") }
        parts.append("\(width)×\(height) \(ChiaroStrings.previewDimensionsSuffix(lang))")
        return parts.joined(separator: " · ")
    }

    private func fittedRect(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let imgAspect = imageSize.width / imageSize.height
        let viewAspect = bounds.width / bounds.height
        let width: CGFloat
        let height: CGFloat
        if viewAspect > imgAspect {
            height = bounds.height
            width = height * imgAspect
        } else {
            width = bounds.width
            height = width / imgAspect
        }
        let x = (bounds.width - width) * 0.5
        let y = (bounds.height - height) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
