import AppKit
import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        HSplitView {
            SidebarQueueView(viewModel: viewModel)
            PreviewCanvasView(viewModel: viewModel)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            InspectorView(viewModel: viewModel)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    viewModel.presentImportFilesPanel()
                } label: {
                    Label("导入 ARW", systemImage: "plus.circle")
                }

                Button {
                    viewModel.toggleGainMapView()
                } label: {
                    Label("Gain Map [G]", systemImage: "square.stack.3d.down.right")
                }

                Button {
                    viewModel.showPublishingGuide = true
                } label: {
                    Label("发布防坑指南", systemImage: "book.pages")
                }

                Button {
                    viewModel.showExportSheet = true
                } label: {
                    Label("批量导出...", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.items.isEmpty)
            }
        }
        .sheet(isPresented: $viewModel.showExportSheet) {
            ExportAndComplianceSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showPublishingGuide) {
            PublishingGuideView()
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.alertMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {
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
                .frame(minWidth: 1180, minHeight: 760)
                .onOpenURL { url in
                    viewModel.importDroppedOrOpenedURLs([url])
                }
        }
        .commands {
            CommandMenu("检视") {
                Button("切换 Gain Map 直视") {
                    viewModel.toggleGainMapView()
                }
                .keyboardShortcut(KeyEquivalent("g"), modifiers: [])
            }
        }
    }
}
