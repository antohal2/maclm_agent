import SwiftData
import SwiftUI

struct ConversationListView: View {
    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    @Bindable var viewModel: ChatViewModel

    @State private var conversationToDelete: Conversation?
    @State private var conversationToRename: Conversation?
    @State private var renameTitle = ""

    var body: some View {
        List(selection: selection) {
            ForEach(conversations) { conversation in
                ConversationRow(
                    conversation: conversation,
                    onRename: {
                        beginRenaming(conversation)
                    },
                    onDelete: {
                        conversationToDelete = conversation
                    }
                )
                .tag(conversation.id)
            }
        }
        .navigationTitle("Беседы")
        .toolbar {
            Button(action: createConversation) {
                Label("Новая беседа", systemImage: "square.and.pencil")
            }
        }
        .onAppear {
            ensureSelection()
        }
        .onChange(of: conversations.map(\.id)) {
            ensureSelection()
        }
        .alert("Переименовать беседу", isPresented: renamePresented) {
            TextField("Название", text: $renameTitle)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") {
                guard let conversationToRename else {
                    return
                }
                viewModel.renameConversation(conversationToRename, to: renameTitle)
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Удалить беседу?", isPresented: deletePresented) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                guard let conversationToDelete else {
                    return
                }
                viewModel.deleteConversation(conversationToDelete)
                ensureSelection(excluding: conversationToDelete.id)
            }
        } message: {
            Text("Беседа и все её сообщения будут удалены без возможности восстановления.")
        }
    }

    private var selection: Binding<UUID?> {
        Binding {
            viewModel.selectedConversationID
        } set: { conversationID in
            guard
                let conversationID,
                let conversation = conversations.first(where: { $0.id == conversationID })
            else {
                return
            }
            viewModel.selectConversation(conversation)
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding {
            conversationToRename != nil
        } set: { isPresented in
            if !isPresented {
                conversationToRename = nil
            }
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding {
            conversationToDelete != nil
        } set: { isPresented in
            if !isPresented {
                conversationToDelete = nil
            }
        }
    }

    private func createConversation() {
        _ = viewModel.createConversation()
    }

    private func beginRenaming(_ conversation: Conversation) {
        renameTitle = conversation.title
        conversationToRename = conversation
    }

    private func ensureSelection(excluding excludedID: UUID? = nil) {
        if excludedID == nil, viewModel.selectedConversation == nil {
            viewModel.ensureConversationSelected()
        }

        if let selectedID = viewModel.selectedConversationID, selectedID != excludedID {
            let selectedConversationExists = conversations.contains { $0.id == selectedID }
            if selectedConversationExists {
                return
            }
        }

        if let conversation = conversations.first(where: { $0.id != excludedID }) {
            viewModel.selectConversation(conversation)
        } else {
            _ = viewModel.createConversation()
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Text(conversation.title)
            .lineLimit(2)
            .contextMenu {
                Button(action: onRename) {
                    Label("Переименовать…", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive, action: onDelete) {
                    Label("Удалить…", systemImage: "trash")
                }
            }
    }
}
