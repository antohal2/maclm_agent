import SwiftUI

@main
struct MacLMAgentApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        MenuBarExtra("maclm-agent", systemImage: "brain") {
            MenuBarContentView()
        }
    }
}
