import AppKit
import SwiftData
import SwiftUI

enum ChatViewStyle {
    case mainWindow
    case compact

    var emptyStateHeight: CGFloat {
        switch self {
        case .mainWindow:
            300
        case .compact:
            220
        }
    }

    var bubbleInset: CGFloat {
        switch self {
        case .mainWindow:
            72
        case .compact:
            36
        }
    }
}

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    var style: ChatViewStyle = .mainWindow
    @Environment(\.openWindow) private var openWindow
    @State private var turns: [TraceTurn] = []
    @State private var retryTarget: Message?

    var body: some View {
        VStack(spacing: 0) {
            if let statusMessage = viewModel.providerCoordinator.statusMessage {
                providerStatus(message: statusMessage)
                Divider()
            }
            messageList
            Divider()
            composer
        }
        .navigationTitle(viewModel.selectedConversation?.interfaceTitle ?? "maclm-agent")
        .onChange(of: traceSignature, initial: true) { rebuildTrace() }
        .alert(String(localized: "Повторить"), isPresented: Binding(
            get: { retryTarget != nil }, set: {
                if !$0 {
                    retryTarget = nil
                }
            }
        )) {
            Button(String(localized: "Повторить"), role: .destructive) {
                if let target = retryTarget {
                    viewModel.retryMessage(target)
                }
                retryTarget = nil
            }
            Button(String(localized: "Отмена"), role: .cancel) { retryTarget = nil }
        } message: {
            Text(
                String(
                    // swiftlint:disable:next line_length
                    localized: "Ответы после этого сообщения будут удалены. Уже выполненные действия с файлами не отменяются"
                )
            )
        }
        .task {
            await viewModel.discoverProvidersIfNeeded()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if visibleMessages.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "brain").font(.largeTitle)
                            Text(String(localized: "Локальный ассистент")).font(.title2)
                            Text(emptyStateDescription)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            ForEach([
                                String(localized: "Найди самые большие файлы в папке Загрузки"),
                                String(localized: "Прочитай файл и кратко перескажи его содержание"),
                                String(localized: "Что ты умеешь делать с файлами?"),
                            ], id: \.self) { suggestion in
                                Button(suggestion) { viewModel.input = suggestion }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: style.emptyStateHeight)
                    } else {
                        ForEach(turns) { turn in
                            bubble(turn.user, final: false)
                            RunTraceView(turn: turn, viewModel: viewModel)
                            if let final = turn.final {
                                bubble(final, final: true)
                            }
                            if let live = turn.liveResponse {
                                bubble(live, final: false)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: visibleMessages.last?.content) {
                guard let messageID = visibleMessages.last?.id else {
                    return
                }
                proxy.scrollTo(messageID, anchor: .bottom)
            }
        }
    }

    private var visibleMessages: [Message] {
        viewModel.messages.filter { $0.role != .tool }
    }

    private var traceSignature: TraceRevision {
        TraceRevision(
            conversationID: viewModel.selectedConversationID,
            active: viewModel.isGenerating,
            cancelled: viewModel.currentRunner?.lastRunCancelled ?? false,
            status: String(describing: viewModel.currentRunner?.status),
            messages: viewModel.messages.map(TraceMessageRevision.init)
        )
    }

    private func rebuildTrace() {
        let failed = if case .failed = viewModel.currentRunner?.status {
            true
        } else {
            false
        }
        turns = RunTraceGrouping.group(
            viewModel.messages,
            active: viewModel.isGenerating,
            failed: failed,
            cancelled: viewModel.currentRunner?.lastRunCancelled ?? false,
            endings: viewModel.currentRunner?.traceEndings ?? [:]
        )
    }

    private func bubble(_ message: Message, final: Bool) -> some View {
        MessageActionBubble(
            message: message,
            isWaiting: viewModel.isWaitingForFirstToken
                && message.id == viewModel.generatingMessageID,
            horizontalInset: style.bubbleInset,
            isFinal: final,
            canRetry: viewModel.canRetryMessage,
            retry: { retryTarget = message },
            fork: {
                if viewModel.fork(at: message) != nil {
                    openWindow(id: "main")
                }
            },
            onConfirmationDecision: viewModel.resolveConfirmation
        )
        .id(message.id)
    }

    private var composer: some View {
        ComposerView(viewModel: viewModel)
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
    }

    private var emptyStateDescription: String {
        if let selection = viewModel.providerCoordinator.selection {
            "\(selection.provider.displayName) · \(ComposerRules.shortModelName(selection.model))"
        } else {
            String(localized: "Провайдер недоступен — запустите LM Studio или Ollama.")
        }
    }

    private func providerStatus(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct MessageActionBubble: View {
    let message: Message
    let isWaiting: Bool
    let horizontalInset: CGFloat
    let isFinal: Bool
    let canRetry: Bool
    let retry: () -> Void
    let fork: () -> Void
    let onConfirmationDecision: (UUID, ConfirmationDecision, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            MessageBubble(
                message: message,
                isWaiting: isWaiting,
                horizontalInset: horizontalInset,
                onConfirmationDecision: onConfirmationDecision
            )
            HStack { actions }
                .buttonStyle(.borderless).font(.caption)
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(!hovering)
        }
        .onHover { hovering = $0 }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button(String(localized: "Копировать")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        }
        if message.role == .user {
            Button(String(localized: "Повторить"), action: retry).disabled(!canRetry)
        }
        if isFinal {
            Button(String(localized: "Ветка"), action: fork)
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let isWaiting: Bool
    let horizontalInset: CGFloat
    let onConfirmationDecision: (UUID, ConfirmationDecision, Bool) -> Void

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: horizontalInset)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(roleTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isWaiting, message.content.isEmpty, message.toolCalls.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Печатает…"))
                            .foregroundStyle(.secondary)
                    }
                } else if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                }

                ForEach(orderedToolCalls) { toolCall in
                    if toolCall.status == .pending || toolCall.status == .approved {
                        ConfirmationCard(toolCall: toolCall) { decision, remember in
                            onConfirmationDecision(toolCall.id, decision, remember)
                        }
                    } else {
                        ToolCallCard(toolCall: toolCall)
                    }
                }
            }
            .padding(12)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14))

            if message.role != .user {
                Spacer(minLength: horizontalInset)
            }
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .system:
            String(localized: "Система")
        case .user:
            String(localized: "Вы")
        case .assistant:
            String(localized: "Ассистент")
        case .tool:
            String(localized: "Инструмент")
        }
    }

    private var bubbleColor: Color {
        message.role == .user
            ? Color.accentColor.opacity(0.18)
            : Color.secondary.opacity(0.12)
    }

    private var orderedToolCalls: [ToolCall] {
        message.toolCalls.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }
    }
}
