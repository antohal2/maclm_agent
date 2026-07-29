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
        WindowGroup {
            MainWindowView(viewModel: chatViewModel)
        }
        .modelContainer(modelContainer)

        MenuBarExtra("maclm-agent", systemImage: "brain") {
            MenuBarContentView()
        }
    }
}
