import AppKit
import SwiftData
import SwiftUI

struct MenuBarContentView: View {
    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    @Bindable var viewModel: ChatViewModel
    let sceneActions: SceneActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ChatView(viewModel: viewModel, style: .compact)
        }
        .frame(width: 420, height: 560)
        .onAppear {
            viewModel.ensureConversationSelected()
        }
        .onChange(of: conversations.map(\.id)) {
            viewModel.ensureConversationSelected()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            conversationMenu

            Spacer(minLength: 8)

            Button(action: createConversation) {
                Image(systemName: "square.and.pencil")
            }
            .help("Новая беседа")
            .accessibilityLabel("Новая беседа")

            Button(action: sceneActions.openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Настройки")
            .accessibilityLabel("Настройки")

            Button(action: openMainWindow) {
                Image(systemName: "macwindow")
            }
            .help("Открыть главное окно")
            .accessibilityLabel("Открыть главное окно")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private var conversationMenu: some View {
        Menu {
            Section("Все беседы") {
                ForEach(conversations) { conversation in
                    Button {
                        viewModel.selectConversation(conversation)
                    } label: {
                        if conversation.id == viewModel.selectedConversationID {
                            Label(conversation.title, systemImage: "checkmark")
                        } else {
                            Text(conversation.title)
                        }
                    }
                }
            }

            Divider()

            Button(action: createConversation) {
                Label("Новая беседа", systemImage: "square.and.pencil")
            }
        } label: {
            HStack(spacing: 6) {
                Text(viewModel.selectedConversation?.title ?? Conversation.defaultTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func createConversation() {
        _ = viewModel.createConversation()
    }

    private func openMainWindow() {
        sceneActions.openMainWindow()
    }
}
