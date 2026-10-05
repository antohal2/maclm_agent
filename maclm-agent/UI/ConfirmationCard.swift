import SwiftUI

struct ConfirmationCard: View {
    let toolCall: ToolCall
    let onDecision: (ConfirmationDecision, Bool) -> Void
    @State private var isArgumentsExpanded = false
    @State private var rememberForSession = false

    private var riskLevel: RiskLevel {
        toolCall.confirmationRiskLevel
    }

    private var isDangerous: Bool {
        riskLevel == .dangerous
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isDangerous ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(accentColor)
                Text(isDangerous ? String(localized: "Опасно · dangerous") : String(localized: "Осторожно · caution"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(toolCall.toolName)
                    .font(.caption.monospaced().weight(.semibold))
            }

            if isDangerous {
                Text(dangerousReason)
                    .font(.callout.weight(.semibold))
            }

            Text(actionDescription)
                .font(.callout)

            if let preview = toolCall.filePreview {
                FilePreviewView(toolName: toolCall.toolName, preview: preview)
            }

            if isDelete {
                if toolCall.filePreview?.canRestore == false {
                    Text(String(localized: "Объект можно восстановить из Корзины вручную")).font(.caption)
                        .foregroundStyle(.red)
                }
                Text(String(localized: "Объект будет перемещён в Корзину. Это изменение файловой системы."))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if isDangerous {
                argumentDetails
            } else {
                DisclosureGroup(String(localized: "Аргументы"), isExpanded: $isArgumentsExpanded) {
                    argumentDetails
                }
            }

            if toolCall.status == .pending {
                if riskLevel.canBeRemembered {
                    Toggle(String(localized: "Не спрашивать снова в этой сессии"), isOn: $rememberForSession)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
                HStack {
                    Button("Reject", role: .destructive) {
                        onDecision(.rejected, false)
                    }
                    Spacer()
                    Button("Approve") {
                        onDecision(.approved, riskLevel.canBeRemembered && rememberForSession)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Разрешено. Выполняется…"))
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
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var exactArguments: [ConfirmationArgument] {
        guard
            let data = toolCall.argumentsJSON.data(using: .utf8),
            let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [
                ConfirmationArgument(
                    label: String(localized: "Аргументы (точный JSON)"),
                    value: toolCall.argumentsJSON
                ),
            ]
        }

        switch toolCall.toolName {
        case "write_file":
            return [
                argument(String(localized: "Путь"), name: "path", in: arguments),
                argument(String(localized: "Режим"), name: "mode", in: arguments),
                argument(String(localized: "Точное содержимое"), name: "content", in: arguments),
            ]
        case "move_file":
            return [
                argument(String(localized: "Откуда"), name: "from", in: arguments),
                argument(String(localized: "Куда"), name: "to", in: arguments),
            ]
        case "delete_file":
            return [argument(String(localized: "Путь"), name: "path", in: arguments)]
        case "run_shell":
            var values = [argument(String(localized: "Полная команда"), name: "command", in: arguments)]
            if arguments["timeoutSeconds"] != nil {
                values.append(
                    argument(String(localized: "Таймаут, секунд"), name: "timeoutSeconds", in: arguments)
                )
            }
            return values
        default:
            return [
                ConfirmationArgument(
                    label: String(localized: "Аргументы (точный JSON)"),
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
        let value = arguments[name].map(String.init(describing:)) ?? String(localized: "(не указан)")
        return ConfirmationArgument(label: label, value: value)
    }

    private var actionDescription: String {
        switch toolCall.toolName {
        case "write_file":
            String(localized: "Записать данные в файл с указанными ниже точными параметрами.")
        case "move_file":
            String(localized: "Переместить файл или каталог.")
        case "delete_file":
            String(localized: "Переместить файл или каталог в Корзину.")
        case "run_shell":
            String(localized: "Выполнить указанную ниже команду через /bin/zsh -c.\n")
                + String(localized: "По завершении команды все оставшиеся фоновые процессы останавливаются.")
        default:
            String(localized: "Выполнить инструмент с уровнем риска, требующим подтверждения.")
        }
    }

    private var dangerousReason: String {
        if let reason = toolCall.confirmationRiskReason, !reason.isEmpty {
            return InterfaceLocalization.text(reason)
        }
        switch toolCall.toolName {
        case "run_shell":
            return String(localized: "аргумент — произвольный код, политика неприменима")
        case "delete_file":
            return String(localized: "Перемещение в Корзину требует отдельного подтверждения.")
        default:
            return String(localized: "Инструмент имеет базовый уровень dangerous и требует отдельного подтверждения.")
        }
    }

    private var isDelete: Bool {
        toolCall.toolName == "delete_file"
    }

    private var accentColor: Color {
        isDangerous ? .red : .orange
    }
}

private struct ConfirmationArgument {
    let label: String
    let value: String
}
