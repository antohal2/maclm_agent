import AppKit
import SwiftUI

struct ClipboardActionEditorView: View {
    @Binding var draft: ClipboardActionDraft
    let validationError: ClipboardActionStoreError?
    let isCreating: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @State private var placeholderInsertionToken = 0

    private let iconColumns = [GridItem(.adaptive(minimum: 32), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCreating ? "Новое действие" : "Параметры действия")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Название")
                    .font(.subheadline.weight(.medium))
                TextField("Название действия", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            iconEditor
            templateEditor

            if let validationError {
                Label(
                    validationError.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Отменить", action: onCancel)
                Button("Сохранить", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
        }
    }

    private var iconEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SF Symbol")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 8) {
                Image(systemName: draft.iconSystemName)
                    .font(.title2)
                    .frame(width: 34, height: 30)
                TextField("Имя SF Symbol", text: $draft.iconSystemName)
                    .textFieldStyle(.roundedBorder)
            }

            ScrollView {
                LazyVGrid(columns: iconColumns, spacing: 6) {
                    ForEach(Self.suggestedIcons, id: \.self) { icon in
                        Button {
                            draft.iconSystemName = icon
                        } label: {
                            Image(systemName: icon)
                                .frame(width: 28, height: 26)
                                .background(
                                    draft.iconSystemName == icon
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(icon)
                    }
                }
                .padding(4)
            }
            .frame(height: 82)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Шаблон промпта")
                .font(.subheadline.weight(.medium))

            PromptTemplateTextView(
                text: $draft.promptTemplate,
                placeholderInsertionToken: placeholderInsertionToken
            )
            .frame(minHeight: 170)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }

            HStack {
                Text("{{input}} будет заменён текстом из буфера обмена.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Вставить {{input}}") {
                    placeholderInsertionToken += 1
                }
                .controlSize(.small)
            }
        }
    }

    private static let suggestedIcons = [
        "globe",
        "wand.and.stars",
        "text.append",
        "questionmark.circle",
        "briefcase",
        "bubble.left.and.bubble.right",
        "star",
        "bolt",
        "lightbulb",
        "brain",
        "doc.text",
        "text.alignleft",
        "list.bullet",
        "checkmark.circle",
        "exclamationmark.triangle",
        "magnifyingglass",
        "curlybraces",
        "chevron.left.forwardslash.chevron.right",
        "terminal",
        "envelope",
        "paperplane",
        "person.2",
        "message",
        "bubble.left",
        "book",
        "bookmark",
        "tag",
        "flag",
        "clock",
        "calendar",
        "tray",
        "archivebox",
        "folder",
        "doc.on.clipboard",
        "scissors",
        "link",
        "lock",
        "shield",
    ]
}

private struct PromptTemplateTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholderInsertionToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.parent = self
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(
                    location: min(selectedRange.location, textView.string.utf16.count),
                    length: 0
                )
            )
        }
        if context.coordinator.lastInsertionToken != placeholderInsertionToken {
            context.coordinator.lastInsertionToken = placeholderInsertionToken
            textView.window?.makeFirstResponder(textView)
            textView.insertText(
                ClipboardActionTemplate.inputPlaceholder,
                replacementRange: textView.selectedRange()
            )
            self.text = textView.string
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTemplateTextView
        var lastInsertionToken: Int

        init(parent: PromptTemplateTextView) {
            self.parent = parent
            lastInsertionToken = parent.placeholderInsertionToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
        }
    }
}
