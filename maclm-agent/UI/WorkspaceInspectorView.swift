import AppKit
import Observation
import Quartz
import SwiftData
import SwiftUI

struct SessionPolicyView: View {
    @Bindable var viewModel: ChatViewModel
    @Query private var rules: [SecurityRule]
    private var invocation: ToolInvocationContext? {
        viewModel.selectedConversation.map { conversation in
            .init(conversationID: conversation.id, project: conversation.project.map {
                .init(id: $0.id, workingDirectoryPath: $0.workingDirectoryPath)
            })
        }
    }

    var body: some View {
        if let invocation {
            let policy = SecurityPolicyEngine(rules: rules.map(\.snapshot), invocation: invocation)
            VStack(alignment: .leading, spacing: 8) {
                if let directory = invocation.workingDirectory {
                    Text(String(localized: "Разрешённая зона: \(directory)")).textSelection(.enabled)
                } else {
                    Text(String(localized: "Глобальные правила"))
                }
                Text(String(localized: "Действующих block-правил: \(policy.blockRuleCount)"))
                Text(String(localized: """
                Периметр и правила действуют на файловые инструменты. Чтение вне зоны ограничивают \
                только block-правила. run_shell не ограничен периметром: читайте команду на карточке \
                подтверждения.
                """))
                .font(.caption).foregroundStyle(.secondary)
                ForEach(viewModel.sessionPermissions.permissions(for: invocation.conversationID)) { permission in
                    HStack {
                        Text(permission.toolName).font(.caption.monospaced())
                        Spacer()
                        Button(String(localized: "Отозвать")) { viewModel.sessionPermissions.revoke(permission) }
                    }
                }
                Button(String(localized: "Сбросить все")) {
                    viewModel.sessionPermissions.reset(conversationID: invocation.conversationID)
                }
            }
        }
    }
}

struct WorkspaceInspectorView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.openWindow) private var openWindow
    @Query private var projects: [Project]
    @State private var editing = false
    @State private var moving = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox(String(localized: "Проект")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let project = viewModel.selectedConversation?.project {
                            Text(project.name).font(.headline)
                            if let path = project.workingDirectoryPath {
                                Text(path).lineLimit(1).truncationMode(.middle).help(path)
                                Button(String(localized: "Показать в Finder")) { NSWorkspace.shared.selectFile(
                                    nil,
                                    inFileViewerRootedAtPath: path
                                ) }
                                if let branch = GitHeadReader.read(workingDirectory: path) {
                                    Text(branch).font(.caption.monospaced())
                                }
                            } else {
                                Text(String(localized: "Рабочая папка не задана"))
                            }
                            Button(String(localized: "Изменить папку…")) { editing = true }
                        } else {
                            Text(String(localized: "Без проекта"))
                            Button(String(localized: "Переместить в проект…")) { moving = true }
                                .popover(isPresented: $moving) {
                                    VStack {
                                        ForEach(projects) { project in
                                            Button(project.name) {
                                                if let conversation = viewModel.selectedConversation {
                                                    viewModel.moveConversation(conversation, to: project)
                                                }
                                                moving = false
                                            }
                                        }
                                        if projects.isEmpty {
                                            Text(String(localized: "Нет проектов"))
                                        }
                                    }.padding()
                                }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(String(localized: "Файлы")) {
                    if let path = viewModel.selectedConversation?.project?.workingDirectoryPath {
                        WorkspaceDirectoryView(url: URL(fileURLWithPath: path)).id(path)
                    } else {
                        Text(String(localized: "Рабочая папка не задана"))
                    }
                }
                GroupBox(String(localized: "Безопасность сессии")) { SessionPolicyView(viewModel: viewModel) }
                GroupBox(String(localized: "Аудит")) {
                    ConversationAuditPreview(conversationID: viewModel.selectedConversationID)
                }
            }.padding()
        }
        .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        .sheet(isPresented: $editing) {
            if let project = viewModel.selectedConversation?.project {
                ProjectEditorView(project: project, onDirectoryChange: viewModel.resetProjectPermissions) {
                    viewModel.saveProject($0)
                }
            }
        }
    }
}

private struct ConversationAuditPreview: View {
    let conversationID: UUID?
    @Query private var entries: [AuditEntry]
    @Environment(\.openWindow) private var openWindow
    init(conversationID: UUID?) {
        self.conversationID = conversationID
        let id = conversationID
        var descriptor = FetchDescriptor<AuditEntry>(
            predicate: #Predicate { id != nil && $0.conversationID == id },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 20
        _entries = Query(descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                HStack {
                    Text(entry.timestamp, style: .time)
                    Text(entry.toolName)
                    Text(entry.riskLevel == .safe ? "safe" : entry.riskLevel == .caution ? "caution" : "dangerous")
                    Text(entry.decisionRaw)
                }.font(.caption)
            }
            Button(String(localized: "Открыть журнал…")) {
                UserDefaults.standard.set(conversationID?.uuidString, forKey: "audit.conversationFilter")
                openWindow(id: "audit")
            }.disabled(conversationID == nil)
        }
    }
}

/// The placeholder child is rendered only after OutlineGroup expands the node.
/// Replacing it with the directory page keeps enumeration lazy and cached.
@MainActor @Observable private final class WorkspaceTreeNode: Identifiable {
    let id: String
    let file: WorkspaceFile?
    let text: String?
    weak var parent: WorkspaceTreeNode?
    var children: [WorkspaceTreeNode]?
    init(file: WorkspaceFile) {
        self.file = file
        id = file.id
        text = nil
        if file.isDirectory {
            let placeholder = WorkspaceTreeNode(id: file.id + "/:loading", text: nil)
            placeholder.parent = self
            children = [placeholder]
        }
    }

    init(id: String, text: String?) {
        self.id = id
        self.text = text
        file = nil
    }
}

private struct WorkspaceDirectoryView: View {
    let url: URL
    @State private var nodes: [WorkspaceTreeNode] = []
    @State private var remaining = 0
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OutlineGroup(nodes, children: \.children) { node in WorkspaceTreeRow(node: node) }
            if remaining > 0 {
                Text(String(localized: "Ещё \(remaining)")).font(.caption)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: url) {
                do {
                    let page = try await Task.detached { try WorkspaceDirectoryPage.read(url) }.value
                    nodes = page.files.map { WorkspaceTreeNode(file: $0) }
                    remaining = page.remaining
                } catch { self.error = error.localizedDescription }
            }
    }
}

private struct WorkspaceTreeRow: View {
    @Bindable var node: WorkspaceTreeNode
    var body: some View {
        if let file = node.file {
            Label(file.url.lastPathComponent, systemImage: file.isDirectory ? "folder" : "doc")
                .lineLimit(1).truncationMode(.middle).font(.caption)
                .onTapGesture(count: 2) { QuickLookPreview.shared.show(file.url) }
                .contextMenu {
                    Button(String(localized: "Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                }
        } else if let text = node.text {
            Text(text).font(.caption)
        } else {
            ProgressView().controlSize(.small)
                .task {
                    guard let parent = node.parent, let file = parent.file else { return }
                    do {
                        let page = try await Task.detached { try WorkspaceDirectoryPage.read(file.url) }.value
                        var children = page.files.map { WorkspaceTreeNode(file: $0) }
                        if page.remaining > 0 {
                            children.append(.init(
                                id: file.id + "/:more",
                                text: String(localized: "Ещё \(page.remaining)")
                            ))
                        }
                        parent.children = children
                    } catch { parent.children = [.init(id: file.id + "/:error", text: error.localizedDescription)] }
                }
        }
    }
}

@MainActor private final class QuickLookPreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPreview()
    private var url: NSURL?
    func show(_ url: URL) {
        self.url = url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> (any QLPreviewItem)! {
        url
    }
}
