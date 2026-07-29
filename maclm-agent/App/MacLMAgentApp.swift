import SwiftData
import SwiftUI

@main
struct MacLMAgentApp: App {
    private let modelContainer: ModelContainer
    @State private var chatViewModel: ChatViewModel

    init() {
        do {
            let container = try ModelContainer(
                for: Conversation.self,
                Message.self,
                ToolCall.self
            )
            modelContainer = container
            _chatViewModel = State(
                initialValue: ChatViewModel(
                    modelContext: container.mainContext
                )
            )
        } catch {
            fatalError("Unable to initialize SwiftData: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        // App-owned state is injected into both scenes so they always observe
        // the same active conversation, draft, and streaming response.
        Window("maclm-agent", id: "main") {
            MainWindowView(viewModel: chatViewModel)
        }
        .modelContainer(modelContainer)

        MenuBarExtra("maclm-agent", systemImage: "brain") {
            MenuBarContentView(viewModel: chatViewModel)
        }
        .modelContainer(modelContainer)
        .menuBarExtraStyle(.window)
    }
}
