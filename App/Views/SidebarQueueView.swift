import ChiaroAppCore
import ChiaroCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarQueueView: View {
    @Bindable var viewModel: AppViewModel

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetSection
            Divider()
            queueHeaderSection
            queueListSection
        }
        .padding(12)
        .frame(minWidth: 270, idealWidth: 295, maxWidth: 335)
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
                Label(ChiaroStrings.presetsTitle(lang), systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                if viewModel.workspaceMode == .pro {
                    Button(ChiaroStrings.importButton(lang)) {
                        viewModel.presentImportPresetPanel()
                    }
                    .controlSize(.small)
                    Button(ChiaroStrings.exportButton(lang)) {
                        viewModel.presentExportPresetPanel()
                    }
                    .controlSize(.small)
                }
            }

            if viewModel.workspaceMode == .preset {
                ScrollView {
                    ChiaroGlassContainer(spacing: 6) {
                        VStack(spacing: 6) {
                            ForEach(viewModel.allPresets) { preset in
                                presetCard(preset)
                            }
                        }
                    }
                }
                .frame(maxHeight: 245)
            } else {
                Picker(ChiaroStrings.presetsTitle(lang), selection: Binding(
                    get: { viewModel.activePreset.id },
                    set: { newID in
                        if let found = viewModel.allPresets.first(where: { $0.id == newID }) {
                            viewModel.selectPreset(found)
                        }
                    }
                )) {
                    ForEach(viewModel.allPresets) { preset in
                        Text(ChiaroStrings.presetName(preset, lang: lang)).tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.orange)
                    Text(ChiaroStrings.platformAdvisoryTitle(lang))
                        .font(.caption.weight(.semibold))
                }
                Text(ChiaroStrings.presetAdvisory(viewModel.activePreset, lang: lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chiaroGlassSurface(cornerRadius: 8, tint: Color.orange.opacity(0.16))
        }
    }

    private func presetCard(_ preset: PresetSchema) -> some View {
        let selected = preset.id == viewModel.activePreset.id
        return Button {
            viewModel.selectPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ChiaroStrings.presetName(preset, lang: lang))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(ChiaroStrings.presetDescription(preset, lang: lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    ForEach(ChiaroStrings.presetSpecTags(preset, lang: lang), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chiaroGlassSurface(
                cornerRadius: 9,
                tint: selected ? Color.accentColor.opacity(0.24) : nil,
                interactive: true
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    private var queueHeaderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(ChiaroStrings.queueTitle(count: viewModel.items.count, lang: lang), systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                if !viewModel.items.isEmpty {
                    Button(ChiaroStrings.clearButton(lang)) {
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
                    Label(ChiaroStrings.filesButton(lang), systemImage: "doc.badge.plus")
                }
                .controlSize(.small)

                Button {
                    viewModel.presentImportFolderPanel()
                } label: {
                    Label(ChiaroStrings.folderButton(lang), systemImage: "folder.badge.plus")
                }
                .controlSize(.small)

                Spacer()

                Toggle(ChiaroStrings.recursiveToggle(lang), isOn: $viewModel.recursiveImport)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help(ChiaroStrings.recursiveHelp(lang))
            }

            Toggle(ChiaroStrings.autoSaveSidecarLabel(lang), isOn: $viewModel.autoSaveSidecar)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                    Text(ChiaroStrings.dropzoneTitle(lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(ChiaroStrings.dropzoneSubtitle(lang))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
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
                                Button(ChiaroStrings.resetDeltaMenu(lang)) {
                                    viewModel.resetDelta(for: item)
                                }
                            }
                            if viewModel.hasSidecar(for: item) {
                                Button(ChiaroStrings.deleteSidecarMenu(lang)) {
                                    viewModel.deleteSidecar(for: item)
                                }
                            }
                            Button(ChiaroStrings.removeFromQueueMenu(lang), role: .destructive) {
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

                if viewModel.hasSidecar(for: item) {
                    Text(ChiaroStrings.sidecarBadge(lang))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.2), in: Capsule())
                        .foregroundStyle(.teal)
                }

                if viewModel.hasDelta(for: item) {
                    Text(ChiaroStrings.deltaBadge(lang))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2), in: Capsule())
                        .foregroundStyle(.blue)
                }

                statusBadge(for: item)
            }

            if let fallback = item.lastFallbackReason {
                Text(ChiaroStrings.fallbackPrefix(fallback, lang: lang))
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
            Text(ChiaroStrings.queuedBadge(lang))
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
