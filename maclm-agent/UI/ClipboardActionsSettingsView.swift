import AppKit
import SwiftData
import SwiftUI

struct ClipboardActionsSettingsView: View {
    @Query(sort: \ClipboardAction.sortOrder)
    private var actions: [ClipboardAction]
    @Bindable var settings: AppSettings
    let accessibilityPermissionService: any AccessibilityPermissionService
    @State private var isAccessibilityTrusted = false

    var body: some View {
        Form {
            Section("Действия с буфером") {
                Toggle(
                    "Вставлять результат автоматически",
                    isOn: $settings.automaticallyPasteClipboardActionResults
                )

                if shouldShowAccessibilityWarning {
                    accessibilityWarning
                }

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
        .onAppear(perform: refreshAccessibilityStatus)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshAccessibilityStatus()
        }
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Для авто-вставки нужен доступ к Универсальному доступу.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            HStack {
                Button("Запросить доступ") {
                    accessibilityPermissionService.requestAccess()
                    refreshAccessibilityStatus()
                }
                Button("Открыть настройки системы") {
                    accessibilityPermissionService.openSystemSettings()
                }
            }
        }
    }

    private var shouldShowAccessibilityWarning: Bool {
        settings.automaticallyPasteClipboardActionResults && !isAccessibilityTrusted
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

    private func refreshAccessibilityStatus() {
        isAccessibilityTrusted = accessibilityPermissionService.isTrusted
    }
}
