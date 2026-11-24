import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct InspectorView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                scopeAndBackendSection
                Divider()
                group1SharedBaseSection
                Divider()
                group2SDRControlsSection
                Divider()
                group3HDRGainMapSection
                Divider()
                group4CompositionSection
            }
            .padding(12)
        }
        .frame(minWidth: 320, idealWidth: 345, maxWidth: 380)
        .background(.background)
    }

    private var effective: EffectiveDevelopParams {
        viewModel.selectedEffectiveParams
    }

    // MARK: - Scope & Backend Header

    private var scopeAndBackendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("编辑作用域", selection: $viewModel.editScope) {
                ForEach(InspectorEditScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.editScope == .perPhotoDelta {
                HStack(spacing: 6) {
                    Button("重置此图微调") {
                        viewModel.resetSelectedDelta()
                    }
                    .controlSize(.small)
                    .disabled(!viewModel.selectedHasDelta)

                    Button("同步到全部") {
                        viewModel.syncSelectedDeltaToAll()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.items.count < 2)

                    Spacer()

                    Menu("Delta JSON") {
                        Button("导入 Delta JSON...") {
                            viewModel.presentImportDeltaPanel()
                        }
                        Button("导出 Delta JSON...") {
                            viewModel.presentExportDeltaPanel()
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Text("当前修改将应用于批量预设「\(viewModel.activePreset.name)」")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack {
                Text("RAW 解码后端")
                    .font(.caption.weight(.medium))
                Spacer()
                Picker("解码后端", selection: $viewModel.decodeBackend) {
                    Text("LibRaw 0.22+").tag(RAWBackend.libraw)
                    Text("Apple CIRAWv9").tag(RAWBackend.ciraw9)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            Toggle("写入 macOS 照片 HDR 标记 (CustomRendered = 3)", isOn: $viewModel.writeCustomRenderedHDR)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
        }
    }

    // MARK: - Group 1: Shared Base

    private var group1SharedBaseSection: some View {
        DisclosureGroup("1. 共享基础调色 (Linear Rec.2020)", isExpanded: $viewModel.expandGroup1) {
            VStack(alignment: .leading, spacing: 10) {
                // White Balance
                let isCustomWB: Bool = {
                    if case .custom = effective.develop.whiteBalance { return true }
                    return false
                }()
                HStack {
                    Text("白平衡")
                        .font(.caption)
                    Spacer()
                    Picker("白平衡", selection: Binding(
                        get: { isCustomWB ? 1 : 0 },
                        set: { mode in
                            if mode == 0 {
                                viewModel.updateWhiteBalance(.asShot)
                            } else {
                                let k = viewModel.currentEstimatedKelvin ?? 5500.0
                                viewModel.updateWhiteBalance(.custom(temperatureKelvin: k, tint: 0.0))
                            }
                        }
                    )) {
                        Text("按拍摄 (As-Shot)").tag(0)
                        Text("自定义色温").tag(1)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                if case let .custom(kelvin, tint) = effective.develop.whiteBalance {
                    parameterSlider(
                        title: "色温",
                        value: kelvin,
                        range: 2000...15000,
                        format: "%.0f K"
                    ) { newK in
                        viewModel.updateWhiteBalance(.custom(temperatureKelvin: newK, tint: tint))
                    }
                    parameterSlider(
                        title: "色调 (Tint)",
                        value: tint,
                        range: -150...150,
                        format: "%+.0f"
                    ) { newT in
                        viewModel.updateWhiteBalance(.custom(temperatureKelvin: kelvin, tint: newT))
                    }
                } else if let estK = viewModel.currentEstimatedKelvin {
                    Text(String(format: "As-Shot 估算色温: %.0f K", estK))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                parameterSlider(
                    title: "曝光 (EV)",
                    value: effective.develop.exposureEV,
                    range: -3.0...3.0,
                    format: "%+.2f EV"
                ) { viewModel.updateExposureEV($0) }

                parameterSlider(
                    title: "阴影恢复",
                    value: effective.develop.shadowRecovery,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateShadowRecovery($0) }

                parameterSlider(
                    title: "黑位 (Black Point)",
                    value: effective.develop.blackPoint,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateBlackPoint($0) }

                parameterSlider(
                    title: "自然饱和度 (Vibrance)",
                    value: effective.develop.vibrance,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateVibrance($0) }

                HStack {
                    Text("高光重构")
                        .font(.caption)
                    Spacer()
                    Picker("高光重构", selection: Binding(
                        get: { effective.develop.highlightReconstruction },
                        set: { viewModel.updateHighlightReconstruction($0) }
                    )) {
                        Text("Opposed Inpaint").tag(HighlightReconstructionMode.opposedInpaint)
                        Text("Blend").tag(HighlightReconstructionMode.blend)
                        Text("Rebuild").tag(HighlightReconstructionMode.rebuild)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                // Camera Profile & Creative Look & DCP
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("相机色彩配置")
                            .font(.caption)
                        Spacer()
                        Menu(cameraProfileLabel(effective.develop.cameraProfile)) {
                            Button("标准 (Camera Matrix / D65)") {
                                viewModel.updateCameraProfile(.standard)
                            }
                            Divider()
                            ForEach(CreativeLookOption.allCases) { look in
                                Button("Creative Look: \(look.displayName)") {
                                    viewModel.updateCameraProfile(.creativeLook(look.rawValue))
                                }
                            }
                            Divider()
                            Button("加载外部 .dcp 文件...") {
                                viewModel.presentPickDCPPanel()
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Text("3D/1D .cube LUT")
                            .font(.caption)
                        Spacer()
                        if let lutPath = effective.develop.cubeLUTPath {
                            Text(URL(fileURLWithPath: lutPath).lastPathComponent)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("清除") {
                                viewModel.clearCubeLUT()
                            }
                            .controlSize(.mini)
                        }
                        Button("选择 .cube...") {
                            viewModel.presentPickCubeLUTPanel()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Group 2: SDR Controls

    private var group2SDRControlsSection: some View {
        DisclosureGroup("2. SDR 基准支路控制 (中灰锁定)", isExpanded: $viewModel.expandGroup2) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SDR 色调映射器")
                        .font(.caption)
                    Spacer()
                    Picker("色调映射器", selection: Binding(
                        get: { effective.sdrToneMapper },
                        set: { viewModel.updateSDRToneMapper($0) }
                    )) {
                        Text("AgX").tag(SDRToneMapper.agx)
                        Text("Neutral Rational").tag(SDRToneMapper.neutralRational)
                        Text("OpenDRT").tag(SDRToneMapper.openDRT)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                parameterSlider(
                    title: "SDR 独立曝光",
                    value: effective.develop.sdrExposureEV,
                    range: -1.0...1.0,
                    format: "%+.2f EV"
                ) { viewModel.updateSDRExposureEV($0) }

                parameterSlider(
                    title: "SDR 高光压缩",
                    value: effective.develop.sdrHighlightCompression,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateSDRHighlightCompression($0) }

                parameterSlider(
                    title: "SDR 反差",
                    value: effective.develop.sdrContrast,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateSDRContrast($0) }

                parameterSlider(
                    title: "SDR 饱和度",
                    value: effective.develop.sdrSaturation,
                    range: -100...100,
                    format: "%+.0f"
                ) { viewModel.updateSDRSaturation($0) }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Group 3: HDR & Gain Map

    private var group3HDRGainMapSection: some View {
        DisclosureGroup("3. HDR 与 Gain Map 引擎", isExpanded: $viewModel.expandGroup3) {
            VStack(alignment: .leading, spacing: 10) {
                parameterSlider(
                    title: "目标 Headroom",
                    value: effective.targetHeadroom.log2Value,
                    range: 1.0...4.0,
                    format: "+%.2f EV"
                ) { viewModel.updateTargetHeadroomStops($0) }

                parameterSlider(
                    title: "中灰锁定锚点 P",
                    value: effective.midtoneAnchorP,
                    range: 0.65...0.95,
                    format: "%.2f"
                ) { viewModel.updateMidtoneAnchorP($0) }

                parameterSlider(
                    title: "HDR 高光激励",
                    value: effective.develop.hdrHighlightExcitation,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateHDRHighlightExcitation($0) }

                parameterSlider(
                    title: "HDR 肩部柔化",
                    value: effective.develop.hdrRolloffSoftness,
                    range: 0...100,
                    format: "%.0f"
                ) { viewModel.updateHDRRolloffSoftness($0) }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gain Map 通道")
                            .font(.caption)
                        Spacer()
                        Picker("通道", selection: Binding(
                            get: { viewModel.activePreset.gainMapChannels },
                            set: { viewModel.setGainMapChannels($0) }
                        )) {
                            Text("1ch 单色 (L008)").tag(GainMapChannels.mono1ch)
                            Text("3ch 彩色 (BGRA)").tag(GainMapChannels.rgb3ch)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 175)
                        .disabled(viewModel.isRGB3chGainMapRestricted)
                        .help(viewModel.isRGB3chGainMapRestricted
                              ? "纯 JPEG + Ultra HDR XMP 模式仅支持 1ch 单色 Gain Map"
                              : "选择 1ch 单色或 3ch 彩色 Gain Map")
                    }
                    if viewModel.isRGB3chGainMapRestricted {
                        Text("JPEG + Ultra HDR XMP 模式已锁定 1ch 单色（如需 3ch 请先启用 HEIC/AVIF 或关闭 XMP）")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Text("Gain Map 分辨率")
                        .font(.caption)
                    Spacer()
                    Picker("分辨率", selection: Binding(
                        get: { viewModel.activePreset.gainMapResolution },
                        set: { viewModel.setGainMapResolution($0) }
                    )) {
                        Text("1/2 抗光晕").tag(GainMapResolution.half)
                        Text("1:1 全尺寸").tag(GainMapResolution.full)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 175)
                }

                parameterSlider(
                    title: "Gain Map Gamma",
                    value: viewModel.activePreset.gainMapGamma,
                    range: 0.25...4.0,
                    format: "%.2f"
                ) { viewModel.setGainMapGamma($0) }

                Toggle("JPEG 闭环 SDR 压缩补偿", isOn: $viewModel.activePreset.compatOptions.closedLoopSDRCompensation)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)

                Toggle("兼容 iOS 14–17 仅单通道双写 (自动锁定 1ch)", isOn: Binding(
                    get: { viewModel.activePreset.compatOptions.writeLegacyAppleHDRGainMap },
                    set: { viewModel.setLegacyAppleGainMap($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Group 4: Composition & Export Guardrails

    private var group4CompositionSection: some View {
        DisclosureGroup("4. 构图裁剪与分辨率保护", isExpanded: $viewModel.expandGroup4) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("画幅比例")
                        .font(.caption)
                    Spacer()
                    Picker("画幅比例", selection: Binding(
                        get: { effective.cropAspect },
                        set: { viewModel.updateCropAspect($0) }
                    )) {
                        ForEach(AspectRatio.allCases, id: \.self) { aspect in
                            Text(aspect == .original ? "原画幅" : aspect.rawValue).tag(aspect)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                if effective.cropAspect != .original {
                    parameterSlider(
                        title: "裁剪中心 X",
                        value: effective.cropOffset.normalizedCenterX,
                        range: 0.0...1.0,
                        format: "%.2f"
                    ) { viewModel.updateCropOffsetX($0) }

                    parameterSlider(
                        title: "裁剪中心 Y",
                        value: effective.cropOffset.normalizedCenterY,
                        range: 0.0...1.0,
                        format: "%.2f"
                    ) { viewModel.updateCropOffsetY($0) }
                }

                HStack {
                    Text("最大长边")
                        .font(.caption)
                    Spacer()
                    Menu(maxLongEdgeLabel(effective.maxLongEdge)) {
                        Button("原图尺寸") { viewModel.updateMaxLongEdge(nil) }
                        if !viewModel.activePreset.outputFormats.contains(.hlgMP4) {
                            Button("4096 px") { viewModel.updateMaxLongEdge(4096) }
                            Button("2048 px (小红书推荐)") { viewModel.updateMaxLongEdge(2048) }
                        }
                        Button("1920 px (HLG MP4 上限)") { viewModel.updateMaxLongEdge(1920) }
                    }
                    .controlSize(.small)
                }

                HStack {
                    Text("自定义长边 (偶数≥64):")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("原图", value: Binding(
                        get: { effective.maxLongEdge },
                        set: { viewModel.updateMaxLongEdge($0) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 85)
                    .controlSize(.small)
                }

                if viewModel.activePreset.outputFormats.contains(.hlgMP4) {
                    Text("已启用 HLG MP4：长边自动限制 ≤ 1920 px（禁止 4K 防止抖音二次压缩）")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Helpers

    private func parameterSlider(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        format: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { min(max(value, range.lowerBound), range.upperBound) },
                    set: { onChange($0) }
                ),
                in: range
            )
            .controlSize(.small)
        }
    }

    private func cameraProfileLabel(_ profile: CameraColorProfile) -> String {
        switch profile {
        case .standard: return "标准 (D65)"
        case let .creativeLook(name): return "Look: \(name)"
        case let .dcp(path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func maxLongEdgeLabel(_ edge: Int?) -> String {
        if let edge {
            return "\(edge) px"
        }
        return "原图尺寸"
    }
}
