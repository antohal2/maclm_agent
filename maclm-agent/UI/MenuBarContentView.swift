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
            .help(String(localized: "Новая беседа"))
            .accessibilityLabel(String(localized: "Новая беседа"))

            Button(action: sceneActions.openSettings) {
                Image(systemName: "gearshape")
            }
            .help(String(localized: "Настройки"))
            .accessibilityLabel(String(localized: "Настройки"))

            Button(action: openMainWindow) {
                Image(systemName: "macwindow")
            }
            .help(String(localized: "Открыть главное окно"))
            .accessibilityLabel(String(localized: "Открыть главное окно"))
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private var clipboardActionMenu: some View {
        Menu {
            Section(String(localized: "Действия с буфером")) {
                if enabledClipboardActions.isEmpty {
                    Text(String(localized: "Нет включённых действий"))
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
        .help(String(localized: "Применить действие к тексту в буфере"))
        .accessibilityLabel(String(localized: "Действия с буфером"))
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
                Button(String(localized: "Настройки")) {
                    accessibilityPermissionService.openSystemSettings()
                }
                .controlSize(.small)
            }

            if !clipboardActionRunner.state.isRunning {
                Button(action: clipboardActionRunner.dismissStatus) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Скрыть статус"))
                .accessibilityLabel(String(localized: "Скрыть статус"))
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
            String(localized: "«\(actionName)»: обработка…")
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
            String(localized: "«\(actionName)»: результат вставлен.")
        case .disabled:
            String(localized: "«\(actionName)»: результат в буфере. Вставьте его вручную через ⌘V.")
        case .accessibilityDenied:
            String(localized: "«\(actionName)»: результат в буфере. Для авто-вставки нужен доступ ")
                + String(localized: "к Универсальному доступу.")
        case .targetApplicationUnavailable:
            String(localized: "«\(actionName)»: результат в буфере. Не удалось вернуть фокус — вставьте ")
                + String(localized: "его вручную через ⌘V.")
        case let .failed(message):
            String(localized: "«\(actionName)»: результат в буфере. Авто-вставка не выполнена: \(message) ")
                + String(localized: "Вставьте его вручную через ⌘V.")
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
            Section(String(localized: "Все беседы")) {
                ForEach(conversations) { conversation in
                    Button {
                        viewModel.selectConversation(conversation)
                    } label: {
                        if conversation.id == viewModel.selectedConversationID {
                            Label(conversation.interfaceTitle, systemImage: "checkmark")
                        } else {
                            Text(conversation.interfaceTitle)
                        }
                    }
                }
            }

            Divider()

            Button(action: createConversation) {
                Label(String(localized: "Новая беседа"), systemImage: "square.and.pencil")
            }
        } label: {
            HStack(spacing: 6) {
                Text(viewModel.selectedConversation?.interfaceTitle ?? Conversation.defaultTitle)
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
