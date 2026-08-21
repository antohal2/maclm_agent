import AppKit
import SwiftData
import SwiftUI

struct MenuBarContentView: View {
    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]
    @Query(sort: \ClipboardAction.sortOrder)
    private var clipboardActions: [ClipboardAction]

    @Bindable var viewModel: ChatViewModel
    @Bindable var clipboardActionRunner: ClipboardActionRunner
    let sceneActions: SceneActions
    let accessibilityPermissionService: any AccessibilityPermissionService

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if clipboardActionRunner.state != .idle {
                clipboardActionStatus
                Divider()
            }
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

            clipboardActionMenu

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

    private var clipboardActionMenu: some View {
        Menu {
            Section("Действия с буфером") {
                if enabledClipboardActions.isEmpty {
                    Text("Нет включённых действий")
                } else {
                    ForEach(enabledClipboardActions) { action in
                        Button {
                            clipboardActionRunner.run(action: action)
                        } label: {
                            Label(action.name, systemImage: action.iconSystemName)
                        }
                    }
                }
            }
        } label: {
            if clipboardActionRunner.state.isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "clipboard")
            }
        }
        .help("Применить действие к тексту в буфере")
        .accessibilityLabel("Действия с буфером")
        .disabled(clipboardActionRunner.state.isRunning)
    }

    private var clipboardActionStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            if shouldOfferAccessibilitySettings {
                Button("Настройки") {
                    accessibilityPermissionService.openSystemSettings()
                }
                .controlSize(.small)
            }

            if !clipboardActionRunner.state.isRunning {
                Button(action: clipboardActionRunner.dismissStatus) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Скрыть статус")
                .accessibilityLabel("Скрыть статус")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch clipboardActionRunner.state {
        case .idle:
            EmptyView()
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusMessage: String {
        switch clipboardActionRunner.state {
        case .idle:
            ""
        case let .running(_, actionName):
            "«\(actionName)»: обработка…"
        case let .succeeded(actionName, outcome):
            successMessage(actionName: actionName, outcome: outcome)
        case let .failed(actionName, message):
            "«\(actionName)»: \(message)"
        }
    }

    private var shouldOfferAccessibilitySettings: Bool {
        guard case let .succeeded(_, outcome) = clipboardActionRunner.state else {
            return false
        }
        return outcome.pasteResult == .accessibilityDenied
    }

    private func successMessage(
        actionName: String,
        outcome: ClipboardActionOutcome
    ) -> String {
        switch outcome.pasteResult {
        case .pasted:
            "«\(actionName)»: результат вставлен."
        case .disabled:
            "«\(actionName)»: результат в буфере. Вставьте его вручную через ⌘V."
        case .accessibilityDenied:
            "«\(actionName)»: результат в буфере. Для авто-вставки нужен доступ "
                + "к Универсальному доступу."
        case .targetApplicationUnavailable:
            "«\(actionName)»: результат в буфере. Не удалось вернуть фокус — вставьте "
                + "его вручную через ⌘V."
        case let .failed(message):
            "«\(actionName)»: результат в буфере. Авто-вставка не выполнена: \(message) "
                + "Вставьте его вручную через ⌘V."
        }
    }

    private var statusColor: Color {
        if case .failed = clipboardActionRunner.state {
            return .red
        }
        return .secondary
    }

    private var enabledClipboardActions: [ClipboardAction] {
        clipboardActions.filter(\.isEnabled)
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
