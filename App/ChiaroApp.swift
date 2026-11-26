import AppKit
import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: AppViewModel

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    var body: some View {
        HSplitView {
            SidebarQueueView(viewModel: viewModel)
            PreviewCanvasView(viewModel: viewModel)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("chiaro.canvas.\(LiquidGlassSystem.neutralCanvasHex)")
            if viewModel.workspaceMode == .preset {
                PresetModeInspectorView(viewModel: viewModel)
            } else {
                InspectorView(viewModel: viewModel)
            }
        }
        .environment(\.locale, viewModel.appLanguage.locale)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(ChiaroStrings.workspaceModeLabel(viewModel.workspaceMode, lang: lang), selection: $viewModel.workspaceMode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(ChiaroStrings.workspaceModeLabel(mode, lang: lang)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                .help(ParameterDocumentationRegistry.doc(for: .workspaceMode).shortSummary.localized(for: lang))
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    viewModel.presentImportFilesPanel()
                } label: {
                    Label(ChiaroStrings.toolbarImportARW(lang), systemImage: "plus.circle")
                }

                Button {
                    viewModel.toggleGainMapView()
                } label: {
                    Label(ChiaroStrings.toolbarGainMap(lang), systemImage: "square.stack.3d.down.right")
                }

                Button {
                    viewModel.showInlineParameterSummaries.toggle()
                } label: {
                    Label(
                        ChiaroStrings.toolbarInlineDocs(lang),
                        systemImage: viewModel.showInlineParameterSummaries ? "questionmark.circle.fill" : "questionmark.circle"
                    )
                }
                .help(ParameterDocumentationRegistry.doc(for: .showInlineParameterSummaries).shortSummary.localized(for: lang))

                Menu {
                    Picker(ChiaroStrings.toolbarLanguage(lang), selection: $viewModel.appLanguage) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(ChiaroStrings.appLanguageLabel(option, lang: lang)).tag(option)
                        }
                    }
                } label: {
                    Label(ChiaroStrings.toolbarLanguage(lang), systemImage: "globe")
                }
                .help(ParameterDocumentationRegistry.doc(for: .appLanguage).shortSummary.localized(for: lang))

                Button {
                    viewModel.showPublishingGuide = true
                } label: {
                    Label(ChiaroStrings.toolbarGuide(lang), systemImage: "book.pages")
                }

                Button {
                    viewModel.showExportSheet = true
                } label: {
                    Label(ChiaroStrings.toolbarBatchExport(lang), systemImage: "square.and.arrow.up")
                }
                .chiaroGlassButtonStyle(prominent: true)
                .disabled(viewModel.items.isEmpty)
            }
        }
        .sheet(isPresented: $viewModel.showExportSheet) {
            ExportAndComplianceSheet(viewModel: viewModel)
                .environment(\.locale, viewModel.appLanguage.locale)
        }
        .sheet(isPresented: $viewModel.showPublishingGuide) {
            PublishingGuideView(language: lang)
                .environment(\.locale, viewModel.appLanguage.locale)
        }
        .alert(
            ChiaroStrings.alertTitle(lang),
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.alertMessage = nil } }
            )
        ) {
            Button(ChiaroStrings.okButton(lang), role: .cancel) {
                viewModel.alertMessage = nil
            }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }
}

@main
struct ChiaroApp: App {
    private let viewModel: AppViewModel

    init() {
        let vm = AppViewModel()
        vm.importLaunchArguments(CommandLine.arguments)
        self.viewModel = vm
    }

    var body: some Scene {
        WindowGroup("Chiaro") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1200, minHeight: 760)
                .onOpenURL { url in
                    viewModel.importDroppedOrOpenedURLs([url])
                }
                .onDisappear {
                    Task { await viewModel.flushPendingSidecarSaves() }
                }
        }
        .commands {
            CommandMenu(ChiaroStrings.menuView(viewModel.resolvedLanguage)) {
                Button(ChiaroStrings.menuToggleGainMap(viewModel.resolvedLanguage)) {
                    viewModel.toggleGainMapView()
                }
                .keyboardShortcut(KeyEquivalent("g"), modifiers: [])

                Button(ChiaroStrings.menuToggleWorkspaceMode(viewModel.resolvedLanguage)) {
                    viewModel.toggleWorkspaceMode()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
