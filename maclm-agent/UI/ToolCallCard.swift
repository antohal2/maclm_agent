import SwiftUI

struct ToolCallCard: View {
    let toolCall: ToolCall

    @State private var isArgumentsExpanded = false
    @State private var isResultExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                Text(toolCall.toolName)
                    .font(.subheadline.monospaced().weight(.semibold))
                Spacer(minLength: 8)
                statusLabel
            }

            DisclosureGroup("Аргументы", isExpanded: $isArgumentsExpanded) {
                payloadText(prettyJSON(toolCall.argumentsJSON))
            }

            DisclosureGroup("Результат", isExpanded: $isResultExpanded) {
                payloadText(toolCall.resultJSON ?? "Ожидание результата…")
            }
        }
        .padding(10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.45))
        }
    }

    private var statusLabel: some View {
        Label(statusTitle, systemImage: statusIcon)
            .font(.caption)
            .foregroundStyle(statusColor)
            .labelStyle(.titleAndIcon)
    }

    private func payloadText(_ value: String) -> some View {
        ScrollView(.horizontal) {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 4)
        }
    }

    private func prettyJSON(_ value: String) -> String {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return value
        }
        return String(data: formatted, encoding: .utf8) ?? value
    }

    private var statusTitle: String {
        switch toolCall.status {
        case .pending:
            "Ожидание"
        case .approved:
            "Разрешён"
        case .rejected:
            "Отклонён"
        case .completed:
            "Готово"
        case .failed:
            "Ошибка"
        }
    }

    private var statusIcon: String {
        switch toolCall.status {
        case .pending:
            "clock"
        case .approved:
            "checkmark.shield"
        case .rejected:
            "xmark.shield"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .pending, .approved:
            .secondary
        case .rejected, .failed:
            .red
        case .completed:
            .green
        }
    }
}
