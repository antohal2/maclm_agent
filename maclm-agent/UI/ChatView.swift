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
        .navigationTitle(viewModel.selectedConversation?.title ?? "maclm-agent")
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
                            Text("Локальный ассистент").font(.title2)
                            Text(emptyStateDescription)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            ForEach([
                                "Найди самые большие файлы в папке Загрузки",
                                "Прочитай файл и кратко перескажи его содержание",
                                "Что ты умеешь делать с файлами?"
                            ], id: \.self) { suggestion in
                                Button(suggestion) { viewModel.input = suggestion }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: style.emptyStateHeight)
                    } else {
                        ForEach(visibleMessages) { message in
                            MessageBubble(
                                message: message,
                                isWaiting: viewModel.isWaitingForFirstToken
                                    && message.id == viewModel.generatingMessageID,
                                horizontalInset: style.bubbleInset,
                                onConfirmationDecision: viewModel.resolveConfirmation
                            )
                            .id(message.id)
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
            "Провайдер недоступен — запустите LM Studio или Ollama."
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

private struct MessageBubble: View {
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
                        Text("Печатает…")
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
            "Система"
        case .user:
            "Вы"
        case .assistant:
            "Ассистент"
        case .tool:
            "Инструмент"
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
