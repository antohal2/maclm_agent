import SwiftData
import SwiftUI

struct ConversationListView: View {
    @Query private var conversations: [Conversation]
    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @Bindable var viewModel: ChatViewModel
    @State private var showArchive = false
    @State private var conversationToDelete: Conversation?
    @State private var conversationToRename: Conversation?
    @State private var projectToRename: Project?
    @State private var projectToDelete: Project?
    @State private var editingProject: Project?
    @State private var showProjectEditor = false
    @State private var renameTitle = ""
    @State private var deleteProjectSessions = false

    var body: some View {
        List(selection: selection) {
            Section(String(localized: "Проекты")) {
                Button(String(localized: "Новый проект…")) {
                    editingProject = nil
                    showProjectEditor = true
                }
                ForEach(projects) { project in
                    DisclosureGroup {
                        ForEach(SessionOrdering.sorted(
                            project.conversations,
                            showingArchive: showArchive
                        )) { conversation in
                            row(conversation)
                        }
                    } label: { Text(project.name) }
                        .contextMenu {
                            Button(String(localized: "Новая сессия")) { viewModel.createConversation(project: project) }
                            Button(String(localized: "Переименовать…")) {
                                renameTitle = project.name
                                projectToRename = project
                            }
                            Button(String(localized: "Настройки проекта…")) {
                                editingProject = project
                                showProjectEditor = true
                            }
                            Button(String(localized: "Удалить…"), role: .destructive) {
                                deleteProjectSessions = false
                                projectToDelete = project
                            }
                        }
                }
            }
            Section(String(localized: "Чаты")) {
                Button(String(localized: "Новый чат")) { viewModel.createConversation() }
                ForEach(SessionOrdering.sorted(
                    conversations.filter { $0.project == nil },
                    showingArchive: showArchive
                )) { conversation in
                    row(conversation)
                }
            }
            Toggle(String(localized: "Показать архив"), isOn: $showArchive)
        }
        .listStyle(.sidebar)
        .navigationTitle(String(localized: "Беседы"))
        .toolbar {
            Button {
                viewModel.createConversation(project: viewModel.selectedConversation?.project)
            } label: {
                Label(String(localized: "Новая беседа"), systemImage: "square.and.pencil")
            }
        }
        .sheet(isPresented: $showProjectEditor) {
            ProjectEditorView(project: editingProject) { project in
                if editingProject == nil {
                    project.sortOrder = (projects.map(\.sortOrder).max() ?? -1) + 1
                }
                viewModel.saveProject(project)
            }
        }
        .onAppear { viewModel.ensureConversationSelected() }
        .alert(String(localized: "Переименовать"), isPresented: Binding(
            get: { conversationToRename != nil || projectToRename != nil },
            set: {
                if !$0 {
                    conversationToRename = nil; projectToRename = nil
                }
            }
        )) {
            TextField(String(localized: "Название"), text: $renameTitle)
            Button(String(localized: "Отмена"), role: .cancel) {}
            Button(String(localized: "Сохранить")) {
                if let conversationToRename {
                    viewModel.renameConversation(conversationToRename, to: renameTitle)
                }
                if let projectToRename {
                    projectToRename.name = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.saveProject(projectToRename)
                }
            }.disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(String(localized: "Удалить беседу?"), isPresented: Binding(
            get: { conversationToDelete != nil }, set: {
                if !$0 {
                    conversationToDelete = nil
                }
            }
        )) {
            Button(String(localized: "Отмена"), role: .cancel) {}
            Button(String(localized: "Удалить"), role: .destructive) {
                if let conversationToDelete {
                    viewModel.deleteConversation(conversationToDelete)
                }
            }
        } message: {
            Text(String(localized: "Беседа и все её сообщения будут удалены без возможности восстановления."))
            if conversationToDelete?.id == viewModel.generatingConversationID {
                Text(String(localized: "Генерация и ожидание подтверждения будут остановлены."))
            }
        }
        .sheet(item: $projectToDelete) { project in
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Удалить проект?")).font(.headline)
                Picker(String(localized: "Сессии проекта"), selection: $deleteProjectSessions) {
                    Text(String(localized: "Перенести сессии в «Чаты»")).tag(false)
                    Text(String(localized: "Удалить вместе с сессиями")).tag(true)
                }
                if deleteProjectSessions {
                    Text(String(localized: "Беседа и все её сообщения будут удалены без возможности восстановления."))
                    if project.conversations.contains(where: { $0.id == viewModel.generatingConversationID }) {
                        Text(String(localized: "Генерация и ожидание подтверждения будут остановлены."))
                    }
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Отмена")) { projectToDelete = nil }
                    Button(String(localized: "Удалить"), role: .destructive) {
                        viewModel.deleteProject(project, includingConversations: deleteProjectSessions)
                        projectToDelete = nil
                    }
                }
            }.padding(24).frame(width: 440)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack {
            if conversation.isPinned {
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
            }
            if conversation.isArchived {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
            }
            Text(conversation.interfaceTitle).lineLimit(2)
            Spacer()
            SessionStatusIndicator(
                status: viewModel.registry.runners[conversation.id]?.status ?? .idle,
                unread: conversation.hasUnreadResult
            )
        }
        .tag(conversation.id)
        .contextMenu {
            Button(conversation.isPinned ? String(localized: "Открепить") : String(localized: "Закрепить")) {
                viewModel.togglePin(conversation)
            }
            Button(String(localized: "Переименовать…")) {
                renameTitle = conversation.title
                conversationToRename = conversation
            }
            Menu(String(localized: "Переместить в проект")) {
                Button(String(localized: "Без проекта")) { viewModel.moveConversation(conversation, to: nil) }
                ForEach(projects) { project in
                    Button(project.name) { viewModel.moveConversation(conversation, to: project) }
                }
            }
            Button(conversation.isArchived ? String(localized: "Разархивировать") : String(localized: "Архивировать")) {
                viewModel.toggleArchive(conversation)
            }
            Button(String(localized: "Удалить…"), role: .destructive) { conversationToDelete = conversation }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(get: { viewModel.selectedConversationID }, set: { id in
            if let conversation = conversations.first(where: { $0.id == id }) {
                viewModel.selectConversation(conversation)
            }
        })
    }
}

private struct SessionStatusIndicator: View {
    let status: SessionStatus
    let unread: Bool
    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .running, .toolRunning: ProgressView().controlSize(.mini)
            case .needsApproval: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .idle: EmptyView()
            }
            if unread {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.title + (unread ? ", " + String(localized: "Непрочитанный результат") : ""))
        .help(status.title)
    }
}
