import ChiaroAppCore
import ChiaroCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarQueueView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetSection
            Divider()
            queueHeaderSection
            queueListSection
        }
        .padding(12)
        .frame(minWidth: 265, idealWidth: 285, maxWidth: 320)
        .background(.background)
        .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if viewModel.isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("预设配置", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("导入") {
                    viewModel.presentImportPresetPanel()
                }
                .controlSize(.small)
                Button("导出") {
                    viewModel.presentExportPresetPanel()
                }
                .controlSize(.small)
            }

            Picker("预设", selection: Binding(
                get: { viewModel.activePreset.id },
                set: { newID in
                    if let found = viewModel.allPresets.first(where: { $0.id == newID }) {
                        viewModel.selectPreset(found)
                    }
                }
            )) {
                ForEach(viewModel.allPresets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            // Always show active preset platformAdvisory banner
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.orange)
                    Text("平台发布提示")
                        .font(.caption.weight(.semibold))
                }
                Text(viewModel.activePreset.platformAdvisory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.28), lineWidth: 1)
            )
        }
    }

    private var queueHeaderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("待处理队列 (\(viewModel.items.count))", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                if !viewModel.items.isEmpty {
                    Button("清空") {
                        viewModel.clearQueue()
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .disabled(viewModel.isExporting)
                }
            }

            HStack(spacing: 6) {
                Button {
                    viewModel.presentImportFilesPanel()
                } label: {
                    Label("文件", systemImage: "doc.badge.plus")
                }
                .controlSize(.small)

                Button {
                    viewModel.presentImportFolderPanel()
                } label: {
                    Label("文件夹", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)

                Spacer()

                Toggle("递归", isOn: $viewModel.recursiveImport)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help("导入文件夹时递归扫描子目录中的 .ARW 文件")
            }
        }
    }

    private var queueListSection: some View {
        Group {
            if viewModel.items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "arrow.down.doc")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("拖拽 .ARW 文件或目录到此处")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("自动忽略 .HIF 及 *.ARW/ 目录，路径去重")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.items, selection: Binding(
                    get: { viewModel.selectedItem?.id },
                    set: { newID in
                        if let newID, let item = viewModel.items.first(where: { $0.id == newID }) {
                            viewModel.selectItem(item)
                        }
                    }
                )) { item in
                    queueRow(for: item)
                        .tag(item.id)
                        .contextMenu {
                            if viewModel.hasDelta(for: item) {
                                Button("重置此图微调") {
                                    viewModel.perPhotoDeltas.removeValue(forKey: item.sourceURL)
                                    if viewModel.selectedItem?.id == item.id {
                                        viewModel.schedulePreviewRender(immediate: true)
                                    }
                                }
                            }
                            Button("从队列移除", role: .destructive) {
                                viewModel.removeItem(item)
                            }
                            .disabled(viewModel.isExporting)
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    private func queueRow(for item: BatchItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if viewModel.hasDelta(for: item) {
                    Text("Delta")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2), in: Capsule())
                        .foregroundStyle(.blue)
                }

                statusBadge(for: item)
            }

            if let fallback = item.lastFallbackReason {
                Text("回退 LibRaw: \(fallback)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            if let result = item.result, !result.artifacts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(result.artifacts, id: \.outputURL) { artifact in
                        compactArtifactBadge(artifact)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func statusBadge(for item: BatchItem) -> some View {
        switch item.status {
        case .idle:
            EmptyView()
        case .queued:
            Text("排队")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .decoding, .rendered:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .help(msg)
        }
    }

    private func compactArtifactBadge(_ artifact: ExportArtifact) -> some View {
        let label = artifact.format.fileExtension.uppercased()
        let badgeText: String
        let tint: Color
        if let report = artifact.compliance {
            let hasWarning = report.checks.contains(where: { $0.severity == .warning })
            if !report.passed {
                badgeText = "\(label) ❌"
                tint = .red
            } else if hasWarning {
                badgeText = "\(label) ⚠️"
                tint = .orange
            } else {
                badgeText = "\(label) ✅"
                tint = .green
            }
        } else {
            badgeText = "\(label) —"
            tint = .secondary
        }
        return Text(badgeText)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let validProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !validProviders.isEmpty else { return false }

        Task {
            var droppedURLs: [URL] = []
            for provider in validProviders {
                if let url = await loadFileURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            if !droppedURLs.isEmpty {
                await MainActor.run {
                    viewModel.importDroppedOrOpenedURLs(droppedURLs)
                }
            }
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
