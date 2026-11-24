import AppKit
import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct ExportAndComplianceSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            // Active preset advisory banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                Text(viewModel.activePreset.platformAdvisory)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button("防坑指南") {
                    viewModel.showGuideFromExportSheet = true
                }
                .controlSize(.small)
                .sheet(isPresented: $viewModel.showGuideFromExportSheet) {
                    PublishingGuideView()
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 16) {
                exportOptionsColumn
                    .frame(width: 370)

                Divider()

                resultsAndComplianceColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footerActionBar
        }
        .padding(16)
        .frame(minWidth: 880, minHeight: 580)
        .sheet(item: Binding(
            get: { viewModel.inspectingArtifact.map { InspectableArtifact(artifact: $0) } },
            set: { viewModel.inspectingArtifact = $0?.artifact }
        )) { wrapped in
            ComplianceDetailSheet(artifact: wrapped.artifact)
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("批量导出与 ISO/IEC 21496-1 合规校验")
                    .font(.title3.bold())
                Text("当前预设: \(viewModel.activePreset.name) · 队列共 \(viewModel.items.count) 张 .ARW")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var exportOptionsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("输出格式（可多选单次解码并发扇出）") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            formatToggle(.heic, label: "HEIC")
                            formatToggle(.jpeg, label: "JPEG")
                            formatToggle(.avif, label: "AVIF")
                            formatToggle(.hlgMP4, label: "HLG MP4")
                        }

                        if viewModel.activePreset.outputFormats.contains(.heic)
                            || viewModel.activePreset.outputFormats.contains(.avif) {
                            HStack {
                                Text("基础色深:")
                                    .font(.caption)
                                Spacer()
                                Picker("色深", selection: $viewModel.activePreset.bitDepth) {
                                    Text("10-bit").tag(BitDepth.bit10)
                                    Text("8-bit").tag(BitDepth.bit8)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 150)
                                .controlSize(.small)
                            }
                        }

                        HStack {
                            Text("基础色域:")
                                .font(.caption)
                            Spacer()
                            Picker("色域", selection: Binding(
                                get: { viewModel.activePreset.baseColorSpace },
                                set: { viewModel.setBaseColorSpace($0) }
                            )) {
                                Text("Display P3").tag(BaseColorSpace.displayP3)
                                Text("sRGB").tag(BaseColorSpace.srgb)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                            .controlSize(.small)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("图像质量:")
                                    .font(.caption)
                                Spacer()
                                Text("\(viewModel.activePreset.qualityPercent)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $viewModel.activePreset.quality, in: 0.4...1.0)
                                .controlSize(.small)
                        }

                        if viewModel.activePreset.outputFormats.contains(.avif) {
                            HStack {
                                Text("AVIF 编码器:")
                                    .font(.caption)
                                Spacer()
                                Picker("AVIF 编码器", selection: $viewModel.activePreset.avifCodec) {
                                    Text("SVT-AV1").tag(AVIFCodecChoice.svtAV1)
                                    Text("libaom").tag(AVIFCodecChoice.libaom)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 170)
                                .controlSize(.small)
                            }
                        }

                        if viewModel.activePreset.outputFormats.contains(.hlgMP4) {
                            hlgVideoConfigSection
                        }
                    }
                    .padding(6)
                }

                GroupBox("输出路径与命名规则") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(viewModel.outputDirectory.path)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("选择目录...") {
                                viewModel.presentOutputDirectoryPanel()
                            }
                            .controlSize(.small)
                        }

                        Toggle("按格式分子目录 (--format-subdirs: heic/ jpeg/ avif/ mp4/)", isOn: $viewModel.useFormatSubdirectories)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption)

                        HStack {
                            Text("命名模板:")
                                .font(.caption)
                            TextField("{name}_HDR.{ext}", text: $viewModel.namingTemplate)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                        }

                        if let sampleItem = viewModel.selectedItem ?? viewModel.items.first,
                           let firstFormat = viewModel.activePreset.outputFormats.first {
                            let previewName = OutputPathCoordinator.renderFilename(
                                template: viewModel.namingTemplate,
                                inputURL: sampleItem.sourceURL,
                                presetID: viewModel.activePreset.id,
                                format: firstFormat
                            )
                            Text("文件名预览: \(previewName)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("同名冲突:")
                                .font(.caption)
                            Spacer()
                            Picker("冲突策略", selection: $viewModel.conflictPolicy) {
                                Text("覆盖").tag(ConflictPolicy.overwrite)
                                Text("跳过").tag(ConflictPolicy.skip)
                                Text("自动编号").tag(ConflictPolicy.autoNumber)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 185)
                            .controlSize(.small)
                        }

                        Toggle("导出后自动执行 ISO 21496-1 / HLG 合规校验", isOn: $viewModel.verifyAfterExport)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption)
                    }
                    .padding(6)
                }
            }
        }
    }

    private func formatToggle(_ format: OutputFormat, label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { viewModel.activePreset.outputFormats.contains(format) },
            set: { _ in viewModel.toggleOutputFormat(format) }
        ))
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.caption)
    }

    private var hlgVideoConfigSection: some View {
        let opts = viewModel.activePreset.hlgVideoOptions ?? HLGVideoOptions()
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("抖音 10-bit BT.2020 HLG MP4 参数 (30fps · 禁 4K)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("视频画幅:")
                    .font(.caption)
                Spacer()
                Picker("画幅", selection: Binding(
                    get: { opts.aspect },
                    set: { newAspect in
                        var updated = opts
                        updated.aspect = newAspect
                        viewModel.activePreset.hlgVideoOptions = updated
                    }
                )) {
                    Text("9:16 (1080×1920)").tag(HLGVideoAspect.portrait9x16)
                    Text("3:4 (1080×1440)").tag(HLGVideoAspect.portrait3x4)
                }
                .labelsHidden()
                .controlSize(.small)
            }

            HStack {
                Text("时长:")
                    .font(.caption)
                Slider(value: Binding(
                    get: { opts.durationSeconds },
                    set: { val in
                        var updated = opts
                        updated.durationSeconds = val
                        viewModel.activePreset.hlgVideoOptions = updated
                    }
                ), in: 3.0...5.0, step: 0.5)
                .controlSize(.small)
                Text(String(format: "%.1fs", opts.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            HStack {
                Text("码率:")
                    .font(.caption)
                Slider(value: Binding(
                    get: { opts.bitrateMbps },
                    set: { val in
                        var updated = opts
                        updated.bitrateMbps = val
                        viewModel.activePreset.hlgVideoOptions = updated
                    }
                ), in: 12.0...16.0, step: 0.5)
                .controlSize(.small)
                Text(String(format: "%.1f Mbps", opts.bitrateMbps))
                    .font(.caption.monospacedDigit())
                    .frame(width: 68, alignment: .trailing)
            }
        }
    }

    private var resultsAndComplianceColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("导出进度与合规徽章")
                    .font(.headline)
                Spacer()
                if let summary = viewModel.batchSummary {
                    Text(String(
                        format: "完成 %d/%d（失败 %d）· %.2fs",
                        summary.succeeded, summary.totalJobs, summary.failed, summary.elapsedSeconds
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(summary.failed == 0 ? .green : .orange)
                }
            }

            if viewModel.isExporting {
                ProgressView(
                    value: Double(viewModel.exportCompletedCount),
                    total: Double(max(1, viewModel.exportTotalCount))
                ) {
                    Text("正在处理 \(viewModel.exportCompletedCount) / \(viewModel.exportTotalCount)...")
                        .font(.caption)
                }
            }

            List(viewModel.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.fileName)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(item.status.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let fallback = item.lastFallbackReason {
                        Text("解码回退: \(fallback)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if let result = item.result {
                        if let err = result.errorDescription {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        ForEach(result.artifacts, id: \.outputURL) { artifact in
                            artifactComplianceRow(artifact)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    private func artifactComplianceRow(_ artifact: ExportArtifact) -> some View {
        let report = artifact.compliance
        let badgeTitle: String
        let tint: Color
        if let report {
            let hasWarning = report.checks.contains(where: { $0.severity == .warning })
            if !report.passed {
                badgeTitle = "HDR 合规失败 ❌"
                tint = .red
            } else if hasWarning {
                badgeTitle = "警告 ⚠️"
                tint = .orange
            } else {
                badgeTitle = "HDR 合规通过 ✅"
                tint = .green
            }
        } else {
            badgeTitle = "未校验"
            tint = .secondary
        }

        return HStack(spacing: 8) {
            Button {
                viewModel.inspectingArtifact = artifact
            } label: {
                Text(badgeTitle)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)

            Text(artifact.outputURL.lastPathComponent)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Branch cleanly on .hlgMP4 vs still image formats
            if artifact.format == .hlgMP4 {
                Text("BT.2020 HLG 10-bit")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                if let hr = report?.measuredHeadroom {
                    Text(String(format: "%.2f× / +%.1f EV", hr.multiplier, hr.toStops().log2Value))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let depth = report?.measuredBitDepth {
                    Text("\(depth)-bit")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if artifact.usedGridTiling, let r = artifact.gridRows, let c = artifact.gridColumns {
                    Text("Grid \(r)×\(c)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(ByteCountFormatter.string(fromByteCount: artifact.fileSizeBytes, countStyle: .file))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([artifact.outputURL])
            }
            .controlSize(.mini)
        }
    }

    private var footerActionBar: some View {
        HStack {
            Button("打开输出目录") {
                try? FileManager.default.createDirectory(at: viewModel.outputDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(viewModel.outputDirectory)
            }
            .controlSize(.regular)

            Spacer()

            if viewModel.isExporting {
                Button("取消导出", role: .destructive) {
                    viewModel.cancelBatchExport()
                }
                .buttonStyle(.bordered)
            }

            Button("开始批量导出") {
                viewModel.startBatchExport()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExporting || viewModel.items.isEmpty)
        }
    }
}

private struct InspectableArtifact: Identifiable {
    var id: URL { artifact.outputURL }
    let artifact: ExportArtifact
}

private struct ComplianceDetailSheet: View {
    let artifact: ExportArtifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.outputURL.lastPathComponent)
                        .font(.headline)
                    Text(artifact.outputURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            if let report = artifact.compliance {
                HStack(spacing: 14) {
                    Text(report.passed ? "校验结论: 通过 ✅" : "校验结论: 未通过 ❌")
                        .font(.subheadline.weight(.semibold))
                    if let hr = report.measuredHeadroom {
                        Text(String(format: "实测 Headroom: %.2f× (+%.2f EV)", hr.multiplier, hr.toStops().log2Value))
                            .font(.caption.monospacedDigit())
                    }
                    if let depth = report.measuredBitDepth {
                        Text("色深: \(depth)-bit")
                            .font(.caption)
                    }
                    if let orient = report.measuredOrientation {
                        Text("Orientation: \(orient)")
                            .font(.caption)
                    }
                }

                List(report.checks, id: \.name) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(severityIcon(item.severity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.caption.monospaced().weight(.semibold))
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Text("此导出产物未运行自动合规探针（已关闭导出后校验）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
    }

    private func severityIcon(_ severity: ComplianceSeverity) -> String {
        switch severity {
        case .pass: return "✅"
        case .warning: return "⚠️"
        case .fail: return "❌"
        }
    }
}
