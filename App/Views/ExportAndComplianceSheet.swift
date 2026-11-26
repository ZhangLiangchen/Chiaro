import AppKit
import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct ExportAndComplianceSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                Text(ChiaroStrings.presetAdvisory(viewModel.activePreset, lang: lang))
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button(ChiaroStrings.shortGuideButton(lang)) {
                    viewModel.showGuideFromExportSheet = true
                }
                .controlSize(.small)
                .sheet(isPresented: $viewModel.showGuideFromExportSheet) {
                    PublishingGuideView(language: lang)
                }
            }
            .padding(10)
            .chiaroGlassSurface(cornerRadius: 8, tint: Color.orange.opacity(0.18))

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
            ComplianceDetailSheet(artifact: wrapped.artifact, language: lang)
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ChiaroStrings.exportSheetTitle(lang))
                    .font(.title3.bold())
                Text(ChiaroStrings.exportSheetSubtitle(
                    presetName: ChiaroStrings.presetName(viewModel.activePreset, lang: lang),
                    count: viewModel.items.count,
                    lang: lang
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(ChiaroStrings.closeButton(lang)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var exportOptionsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(ChiaroStrings.outputFormatsGroup(lang)) {
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
                                Text(ChiaroStrings.baseBitDepthLabel(lang))
                                    .font(.caption)
                                Spacer()
                                Picker(ChiaroStrings.baseBitDepthLabel(lang), selection: $viewModel.activePreset.bitDepth) {
                                    Text("10-bit").tag(BitDepth.bit10)
                                    Text("8-bit").tag(BitDepth.bit8)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 150)
                                .controlSize(.small)
                            }
                        }

                        DocumentedPicker(
                            parameterID: .baseColorSpace,
                            language: lang,
                            showInlineSummary: viewModel.showInlineParameterSummaries,
                            selection: Binding(
                                get: { viewModel.activePreset.baseColorSpace },
                                set: { viewModel.setBaseColorSpace($0) }
                            ),
                            pickerStyleSegmented: true,
                            pickerWidth: 170
                        ) {
                            Text("Display P3").tag(BaseColorSpace.displayP3)
                            Text("sRGB").tag(BaseColorSpace.srgb)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(ChiaroStrings.imageQualityLabel(lang))
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
                                Text(ChiaroStrings.avifEncoderLabel(lang))
                                    .font(.caption)
                                Spacer()
                                Picker(ChiaroStrings.avifEncoderLabel(lang), selection: $viewModel.activePreset.avifCodec) {
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

                GroupBox(ChiaroStrings.outputPathGroup(lang)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(viewModel.outputDirectory.path)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(ChiaroStrings.chooseFolderShort(lang)) {
                                viewModel.presentOutputDirectoryPanel()
                            }
                            .controlSize(.small)
                        }

                        Toggle(ChiaroStrings.formatSubdirsToggle(lang), isOn: $viewModel.useFormatSubdirectories)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption)

                        HStack {
                            Text(ChiaroStrings.namingTemplateLabel(lang))
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
                            Text(ChiaroStrings.filenamePreview(previewName, lang: lang))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(ChiaroStrings.conflictPolicyLabel(lang))
                                .font(.caption)
                            Spacer()
                            Picker(ChiaroStrings.conflictPolicyLabel(lang), selection: $viewModel.conflictPolicy) {
                                Text(ChiaroStrings.conflictPolicyName(.overwrite, lang: lang)).tag(ConflictPolicy.overwrite)
                                Text(ChiaroStrings.conflictPolicyName(.skip, lang: lang)).tag(ConflictPolicy.skip)
                                Text(ChiaroStrings.conflictPolicyName(.autoNumber, lang: lang)).tag(ConflictPolicy.autoNumber)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 210)
                            .controlSize(.small)
                        }

                        Toggle(ChiaroStrings.verifyAfterExportToggle(lang), isOn: $viewModel.verifyAfterExport)
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
            Text(ChiaroStrings.hlgVideoSectionHeader(lang))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text(ChiaroStrings.videoAspectLabel(lang))
                    .font(.caption)
                Spacer()
                Picker(ChiaroStrings.videoAspectLabel(lang), selection: Binding(
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
                Text(ChiaroStrings.videoDurationLabel(lang))
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
                Text(ChiaroStrings.videoBitrateLabel(lang))
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
                Text(ChiaroStrings.exportProgressTitle(lang))
                    .font(.headline)
                Spacer()
                if let summary = viewModel.batchSummary {
                    Text(ChiaroStrings.exportSummaryText(summary, lang: lang))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(summary.failed == 0 ? .green : .orange)
                }
            }

            if viewModel.isExporting {
                ProgressView(
                    value: Double(viewModel.exportCompletedCount),
                    total: Double(max(1, viewModel.exportTotalCount))
                ) {
                    Text(ChiaroStrings.processingCount(
                        done: viewModel.exportCompletedCount,
                        total: viewModel.exportTotalCount,
                        lang: lang
                    ))
                    .font(.caption)
                }
            }

            List(viewModel.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.fileName)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(item.status.label(for: lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let fallback = item.lastFallbackReason {
                        Text(ChiaroStrings.decodeFallbackRow(fallback, lang: lang))
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
                badgeTitle = ChiaroStrings.complianceFailBadge(lang)
                tint = .red
            } else if hasWarning {
                badgeTitle = ChiaroStrings.complianceWarnBadge(lang)
                tint = .orange
            } else {
                badgeTitle = ChiaroStrings.compliancePassBadge(lang)
                tint = .green
            }
        } else {
            badgeTitle = ChiaroStrings.complianceUnverifiedBadge(lang)
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
        ChiaroGlassContainer(spacing: 10) {
            HStack {
                Button(ChiaroStrings.openOutputDirButton(lang)) {
                    try? FileManager.default.createDirectory(at: viewModel.outputDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(viewModel.outputDirectory)
                }
                .chiaroGlassButtonStyle(prominent: false)

                Spacer()

                if viewModel.isExporting {
                    Button(ChiaroStrings.cancelExportButton(lang), role: .destructive) {
                        viewModel.cancelBatchExport()
                    }
                    .chiaroGlassButtonStyle(prominent: false)
                }

                Button(ChiaroStrings.startBatchExportButton(lang)) {
                    viewModel.startBatchExport()
                }
                .chiaroGlassButtonStyle(prominent: true)
                .disabled(viewModel.isExporting || viewModel.items.isEmpty)
            }
        }
    }
}

private struct InspectableArtifact: Identifiable {
    var id: URL { artifact.outputURL }
    let artifact: ExportArtifact
}

private struct ComplianceDetailSheet: View {
    let artifact: ExportArtifact
    let language: ResolvedLanguage
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
                Button(ChiaroStrings.closeButton(language)) { dismiss() }
            }

            if let report = artifact.compliance {
                HStack(spacing: 14) {
                    Text(ChiaroStrings.complianceVerdict(passed: report.passed, lang: language))
                        .font(.subheadline.weight(.semibold))
                    if let hr = report.measuredHeadroom {
                        Text(ChiaroStrings.complianceMeasuredHeadroom(
                            mult: hr.multiplier,
                            ev: hr.toStops().log2Value,
                            lang: language
                        ))
                        .font(.caption.monospacedDigit())
                    }
                    if let depth = report.measuredBitDepth {
                        Text(ChiaroStrings.complianceBitDepth(depth, lang: language))
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
                Text(ChiaroStrings.complianceNotRun(language))
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
