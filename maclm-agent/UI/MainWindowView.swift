import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @Bindable var viewModel: ChatViewModel
    let sceneActions: SceneActions

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
    }
}
