import SwiftUI

struct MainWindowView: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        NavigationSplitView {
            ConversationListView(viewModel: viewModel)
        } detail: {
            ChatView(viewModel: viewModel)
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
