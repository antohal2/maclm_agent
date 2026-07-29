import SwiftUI

struct ConfirmationCard: View {
    let toolCall: ToolCall
    let onDecision: (ConfirmationDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isDelete ? "trash.slash.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(accentColor)
                Text("Требуется подтверждение")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(toolCall.toolName)
                    .font(.caption.monospaced().weight(.semibold))
            }

            Text(actionDescription)
                .font(.callout)

            if isDelete {
                Text("Объект будет перемещён в Корзину. Это изменение файловой системы.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }

            argumentDetails

            if toolCall.status == .pending {
                HStack {
                    Button("Reject", role: .destructive) {
                        onDecision(.rejected)
                    }
                    Spacer()
                    Button("Approve") {
                        onDecision(.approved)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Разрешено. Выполняется…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(0.65), lineWidth: 1.5)
        }
    }

    private var argumentDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(exactArguments, id: \.label) { argument in
                VStack(alignment: .leading, spacing: 3) {
                    Text(argument.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(argument.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var exactArguments: [ConfirmationArgument] {
        guard
            let data = toolCall.argumentsJSON.data(using: .utf8),
            let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [ConfirmationArgument(label: "Аргументы (точный JSON)", value: toolCall.argumentsJSON)]
        }

        switch toolCall.toolName {
        case "write_file":
            return [
                argument("Путь", name: "path", in: arguments),
                argument("Режим", name: "mode", in: arguments),
                argument("Точное содержимое", name: "content", in: arguments),
            ]
        case "move_file":
            return [
                argument("Откуда", name: "from", in: arguments),
                argument("Куда", name: "to", in: arguments),
            ]
        case "delete_file":
            return [argument("Путь", name: "path", in: arguments)]
        case "run_shell":
            var values = [argument("Полная команда", name: "command", in: arguments)]
            if arguments["timeoutSeconds"] != nil {
                values.append(
                    argument("Таймаут, секунд", name: "timeoutSeconds", in: arguments)
                )
            }
            return values
        default:
            return [
                ConfirmationArgument(
                    label: "Аргументы (точный JSON)",
                    value: toolCall.argumentsJSON
                ),
            ]
        }
    }

    private func argument(
        _ label: String,
        name: String,
        in arguments: [String: Any]
    ) -> ConfirmationArgument {
        let value = arguments[name].map(String.init(describing:)) ?? "(не указан)"
        return ConfirmationArgument(label: label, value: value)
    }

    private var actionDescription: String {
        switch toolCall.toolName {
        case "write_file":
            "Записать данные в файл с указанными ниже точными параметрами."
        case "move_file":
            "Переместить файл или каталог."
        case "delete_file":
            "Переместить файл или каталог в Корзину."
        case "run_shell":
            "Выполнить указанную ниже команду через /bin/zsh -c."
        default:
            "Выполнить инструмент с уровнем риска, требующим подтверждения."
        }
    }

    private var isDelete: Bool {
        toolCall.toolName == "delete_file"
    }

    private var accentColor: Color {
        isDelete ? .red : .orange
    }
}

private struct ConfirmationArgument {
    let label: String
    let value: String
}
