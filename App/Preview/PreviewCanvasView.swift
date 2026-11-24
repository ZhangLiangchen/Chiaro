import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct PreviewCanvasView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
            edrStatusAndControlsBar

            if viewModel.isSDRExternalMonitor {
                sdrMonitorBanner
            }

            previewViewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            bottomMetadataAndHistogramBar
        }
        .padding(12)
    }

    private var edrStatusAndControlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Screen EDR readout badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isSDRExternalMonitor ? Color.yellow : Color.green)
                        .frame(width: 8, height: 8)
                    Text(String(
                        format: "屏幕 EDR: %.2f× (+%.1f EV)",
                        viewModel.screenMaxEDR,
                        log2(max(viewModel.screenMaxEDR, 1.0))
                    ))
                    .font(.caption.monospacedDigit().weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: Capsule())

                // iPhone Headroom Simulator presets: 1x, 2x, 4x, 8x
                HStack(spacing: 4) {
                    Text("iPhone 模拟:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(AppViewModel.headroomPresetSteps, id: \.multiplier) { presetStep in
                        let selected = abs(viewModel.simulatedHeadroom.multiplier - presetStep.multiplier) < 0.05
                        Button {
                            viewModel.setSimulatedHeadroom(presetStep)
                        } label: {
                            let ev = Int(round(presetStep.toStops().log2Value))
                            Text("\(Int(presetStep.multiplier))× (+\(ev))")
                                .font(.caption.monospacedDigit().weight(selected ? .semibold : .regular))
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? .accentColor : .secondary)
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
                    .frame(width: 105)
                }

                Spacer()

                // 4 Inspection modes
                HStack(spacing: 4) {
                    modeButton(.standardEDR, title: "标准 EDR", systemImage: "sun.max")
                    modeButton(.splitScreenSwipe, title: "分屏对比", systemImage: "rectangle.split.2x1")
                    modeButton(.falseColorHeatmap, title: "假彩色热力图", systemImage: "flame")

                    Button {
                        viewModel.toggleGainMapView()
                    } label: {
                        Label("Gain Map [G]", systemImage: "square.stack.3d.down.right")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.previewMode == .gainMapDirectView ? .orange : .secondary)
                    .controlSize(.small)
                    .keyboardShortcut(KeyEquivalent("g"), modifiers: [])
                    .help("快捷键 G：直接检视 Gain Map（单通道 L008 / 三通道 BGRA）")
                }
            }
        }
    }

    private func modeButton(_ mode: EDRPreviewMode, title: String, systemImage: String) -> some View {
        let active = viewModel.previewMode == mode
        return Button {
            viewModel.previewMode = mode
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
        .controlSize(.small)
    }

    private var sdrMonitorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("当前显示器为标准 SDR 外接屏 (EDR = 1.0×)，高光超过 0 EV 会受硬件上限限制。可开启「曝光缩放检视」按 1/H_sim 压缩全图亮度以检查高光纹理。")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Toggle("曝光缩放检视 (1/H)", isOn: $viewModel.sdrExposureScaleEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.45), lineWidth: 1)
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
                .overlay(alignment: .topLeading) {
                    if frame != nil, viewModel.previewMode == .splitScreenSwipe {
                        splitOverlay(in: fitted.size)
                    }
                }
                .position(x: fitted.midX, y: fitted.midY)
                .opacity(frame == nil ? 0.15 : 1.0)

                if let selectedItem = viewModel.selectedItem {
                    if frame == nil {
                        if let err = viewModel.previewError {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.octagon")
                                    .font(.title)
                                    .foregroundStyle(.red)
                                Text("预览渲染失败: \(err)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                        } else {
                            ProgressView("正在解码与渲染 \(selectedItem.fileName)...")
                                .controlSize(.regular)
                        }
                    }

                    // Top-left / bottom-left overlays for heatmap legend, Gain Map mode, or decode fallback notice
                    VStack {
                        HStack(alignment: .top) {
                            if let fallback = viewModel.currentFallbackReason {
                                Label("已自动回退至 LibRaw: \(fallback)", systemImage: "info.circle.fill")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            Spacer()
                            if viewModel.isRenderingPreview {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(6)
                                    .background(.ultraThinMaterial, in: Circle())
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
                    .allowsHitTesting(false)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("拖入索尼 .ARW 文件或文件夹开始预览")
                            .font(.headline)
                        Text("支持单张/批量导入、自动忽略 .HIF、120Hz 原生 EDR 实时调色与 ISO 21496-1 合规校验")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("选择 ARW 文件...") {
                                viewModel.presentImportFilesPanel()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("选择文件夹...") {
                                viewModel.presentImportFolderPanel()
                            }
                            .buttonStyle(.bordered)
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
                Text("SDR 基准 (W=0)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "EDR (%.1f×)", viewModel.simulatedHeadroom.multiplier))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
            }
            .padding(10)
            .allowsHitTesting(false)

            // Drag handle pill on the vertical split line
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
                .shadow(radius: 3)
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
            legendChip(color: .gray, text: "≤0 EV SDR")
            legendChip(color: .cyan, text: "0–1 EV")
            legendChip(color: .green, text: "1–2 EV")
            legendChip(color: .orange, text: "2–3+ EV")
            legendChip(color: .pink, text: "裁切过曝")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
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
        return Text(String(
            format: "Gain Map 直视 · %@ (%d×%d) · min=%.2f max=%.2f γ=%.2f",
            chLabel, gm.buffer.width, gm.buffer.height, minV, maxV, gammaV
        ))
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
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
                        Text(String(format: "机身测光色温: %.0fK", kelvin))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if !viewModel.isSDRExternalMonitor {
                        Toggle("曝光缩放 (1/H)", isOn: $viewModel.sdrExposureScaleEnabled)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption2)
                    }
                }
            }

            DualZoneHistogramView(
                bins: viewModel.histogramBins,
                displayHeadroom: viewModel.simulatedHeadroom
            )
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
        parts.append("\(width)×\(height) 预览")
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
