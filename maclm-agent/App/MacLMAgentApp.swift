import SwiftUI

@main
struct MacLMAgentApp: App {
    @State private var chatViewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ChatView(viewModel: chatViewModel)
        }

        MenuBarExtra("maclm-agent", systemImage: "brain") {
            MenuBarContentView()
        }
    }
}
