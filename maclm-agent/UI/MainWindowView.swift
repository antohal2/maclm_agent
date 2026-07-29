import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @Bindable var viewModel: ChatViewModel
    let sceneActions: SceneActions
    @State private var isShowingProviderSettings = false

    var body: some View {
        NavigationSplitView {
            ConversationListView(viewModel: viewModel)
        } detail: {
            ChatView(viewModel: viewModel)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            sceneActions.openMainWindowAction = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            sceneActions.openSettingsAction = {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isShowingProviderSettings.toggle()
                } label: {
                    Label(
                        viewModel.providerCoordinator.activeProviderTitle,
                        systemImage: "server.rack"
                    )
                }
                .help("Выбрать LLM-провайдер")
                .popover(isPresented: $isShowingProviderSettings) {
                    ProviderSettingsView(coordinator: viewModel.providerCoordinator)
                }
            }
        }
    }
}
