import SwiftUI

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("maclm-agent")
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if viewModel.messages.isEmpty {
                        ContentUnavailableView(
                            "Локальный ассистент",
                            systemImage: "brain",
                            description: Text("Запустите сервер LM Studio и отправьте сообщение.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(
                                message: message,
                                isWaiting: viewModel.isWaitingForFirstToken
                                    && message.id == viewModel.messages.last?.id
                            )
                            .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.last?.content) {
                guard let messageID = viewModel.messages.last?.id else {
                    return
                }
                proxy.scrollTo(messageID, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "Сообщение для LM Studio",
                text: $viewModel.input,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1 ... 6)
            .onSubmit(viewModel.send)

            Button(action: viewModel.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canSend ? Color.accentColor : Color.secondary)
            .disabled(!viewModel.canSend)
            .accessibilityLabel("Отправить")
        }
        .padding()
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let isWaiting: Bool

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 72)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(roleTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isWaiting, message.content.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Печатает…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14))

            if message.role != .user {
                Spacer(minLength: 72)
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
}
