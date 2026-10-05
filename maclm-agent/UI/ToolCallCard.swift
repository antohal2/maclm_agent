import SwiftUI

struct ToolCallCard: View {
    let toolCall: ToolCall
    var rawResult: String?

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

            let risk = toolCall.confirmationRiskLevel
            Group {
                Label(
                    risk == .dangerous ? String(localized: "Опасно · dangerous")
                        : risk == .caution ? String(localized: "Осторожно · caution") :
                        String(localized: "Безопасно · safe"),
                    systemImage: risk == .dangerous ? "exclamationmark.shield.fill"
                        : risk == .caution ? "exclamationmark.triangle.fill" : "checkmark.shield"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(risk == .dangerous ? Color.red : risk == .caution ? Color.orange : Color.green)
            }
            if risk == .dangerous {
                payloadText(prettyJSON(toolCall.argumentsJSON))
            } else {
                DisclosureGroup(String(localized: "Аргументы"), isExpanded: $isArgumentsExpanded) {
                    payloadText(prettyJSON(toolCall.argumentsJSON))
                }
            }

            let result = rawResult ?? toolCall.resultJSON ?? String(localized: "Ожидание результата…")
            if toolCall.toolName == "run_shell", let data = result.data(using: .utf8),
               let output = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Text(
                    "exitCode: \(output["exitCode"] as? Int ?? -1) · timedOut: \(output["timedOut"] as? Bool ?? false)"
                )
                .font(.caption.monospaced())
                if let note = output["lifecycleNote"] as? String {
                    payloadText(note)
                }
            }
            let output = resultText(result)
            let lines = output.components(separatedBy: "\n")
            payloadText(isResultExpanded ? output : lines.prefix(20).joined(separator: "\n"))
            if lines.count > 20 {
                Button(isResultExpanded ? String(localized: "Свернуть") : String(localized: "Показать всё")) {
                    isResultExpanded.toggle()
                }.font(.caption)
            }
        }
        .padding(10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.45))
        }
    }

    private func resultText(_ raw: String) -> String {
        guard toolCall.toolName == "run_shell", let data = raw.data(using: .utf8),
              let output = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
        return "stdout:\n" + (output["stdout"] as? String ?? "")
            + "\nstderr:\n" + (output["stderr"] as? String ?? "")
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
            String(localized: "Ожидание")
        case .approved:
            String(localized: "Разрешён")
        case .rejected:
            String(localized: "Отклонён")
        case .completed:
            String(localized: "Готово")
        case .failed:
            String(localized: "Ошибка")
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
