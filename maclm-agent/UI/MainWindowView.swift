import SwiftUI

struct MainWindowView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var isShowingProviderSettings = false

    var body: some View {
        NavigationSplitView {
            ConversationListView(viewModel: viewModel)
        } detail: {
            ChatView(viewModel: viewModel)
        }
        .frame(minWidth: 760, minHeight: 480)
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
