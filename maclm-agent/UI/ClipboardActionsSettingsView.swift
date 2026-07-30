import SwiftData
import SwiftUI

struct ClipboardActionsSettingsView: View {
    @Query(sort: \ClipboardAction.sortOrder)
    private var actions: [ClipboardAction]

    var body: some View {
        Form {
            Section("Действия с буфером") {
                ForEach(actions) { action in
                    actionRow(action)
                        .opacity(action.isEnabled ? 1 : 0.45)
                }
            }

            Text(
                "Действия применяются к содержимому буфера обмена. "
                    + "Редактирование и вызов по хоткею появятся в следующих обновлениях."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private func actionRow(_ action: ClipboardAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: action.iconSystemName)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.name)
                Text(promptPreview(action.promptTemplate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func promptPreview(_ template: String) -> String {
        let normalized = template
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let prefix = String(normalized.prefix(60))
        return normalized.count > 60 ? "\(prefix)…" : prefix
    }
}
