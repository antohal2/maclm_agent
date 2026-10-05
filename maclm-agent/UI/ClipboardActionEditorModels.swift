import SwiftUI

struct ClipboardActionDraft: Equatable {
    var name: String
    var promptTemplate: String
    var iconSystemName: String

    static let empty = Self(
        name: "",
        promptTemplate: "{{input}}",
        iconSystemName: "wand.and.stars"
    )

    init(action: ClipboardAction) {
        name = action.name
        promptTemplate = action.promptTemplate
        iconSystemName = action.iconSystemName
    }

    private init(name: String, promptTemplate: String, iconSystemName: String) {
        self.name = name
        self.promptTemplate = promptTemplate
        self.iconSystemName = iconSystemName
    }
}

struct ClipboardActionListRow: View {
    let action: ClipboardAction
    let isSelected: Bool
    @Binding var isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: $isEnabled
            )
            .labelsHidden()

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: action.iconSystemName)
                        .frame(width: 18)
                    Text(action.interfaceName)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if action.isBuiltIn {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(.secondary)
                            .help(String(localized: "Встроенное действие"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .opacity(action.isEnabled ? 1 : 0.55)
    }
}
