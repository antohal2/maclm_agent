import Foundation

extension MessageRole {
    init(_ role: ChatRole) {
        self = MessageRole(rawValue: role.rawValue) ?? .system
    }

    var chatRole: ChatRole {
        ChatRole(rawValue: rawValue) ?? .system
    }
}

extension Message {
    convenience init(
        chatMessage: ChatMessage,
        timestamp: Date = Date(),
        conversation: Conversation? = nil
    ) {
        self.init(
            id: chatMessage.id,
            role: MessageRole(chatMessage.role),
            content: chatMessage.content,
            toolCallID: chatMessage.toolCallID,
            timestamp: timestamp,
            conversation: conversation
        )

        toolCalls = chatMessage.toolCalls?.map { call in
            ToolCall(
                providerCallID: call.id,
                toolName: call.function.name,
                argumentsJSON: call.function.arguments,
                timestamp: timestamp,
                message: self
            )
        } ?? []
    }

    var chatMessage: ChatMessage {
        let mappedToolCalls = toolCalls
            .sorted { $0.timestamp < $1.timestamp }
            .map { call in
                ChatToolCall(
                    id: call.providerCallID ?? call.id.uuidString,
                    type: "function",
                    function: ChatToolFunction(
                        name: call.toolName,
                        arguments: call.argumentsJSON
                    )
                )
            }

        return ChatMessage(
            id: id,
            role: role.chatRole,
            content: content,
            toolCalls: mappedToolCalls.isEmpty ? nil : mappedToolCalls,
            toolCallID: toolCallID
        )
    }
}
