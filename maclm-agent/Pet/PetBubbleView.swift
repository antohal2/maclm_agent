import AppKit
import SwiftUI

struct PetBubbleView: View {
    @Bindable var model: PetBubbleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.rows.isEmpty {
                Text(String(localized: "Сессий нет"))
                Button(String(localized: "Открыть главное окно")) { model.onOpen?(nil) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            session(row, index: index).frame(height: model.rowHeight(row), alignment: .top)
                        }
                    }
                }.frame(height: model.listHeight)
            }
            Divider()
            PetQuickInput(model: model)
                .frame(height: 24)
            if !model.settings.petHideContent, !model.newChat, !model.forcesNewChat,
               let target = model.viewModel.selectedConversation
            {
                Text(verbatim: "→ " + target.interfaceTitle).font(.caption).lineLimit(1)
            }
            Toggle(String(localized: "Новый чат"), isOn: Binding(
                get: { model.newChat || model.forcesNewChat },
                set: { model.newChat = $0 }
            )).disabled(model.forcesNewChat)
        }
        .padding(12)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func session(_ row: PetBubbleRow, index: Int) -> some View {
        let hidden = model.settings.petHideContent
        let title = hidden ? String(localized: "Сессия \(index + 1)") : row.title
        return VStack(alignment: .leading, spacing: 4) {
            Button { model.onOpen?(row.id) } label: {
                HStack {
                    Image(systemName: symbol(row.state))
                    Text(verbatim: title).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + ", " + row.state.accessibilityTitle)
            if !hidden, let tool = row.tool {
                HStack {
                    Text(verbatim: tool).lineLimit(1)
                    if let request = row.request {
                        Text(request.riskLevel == .caution
                            ? String(localized: "Осторожно") : String(localized: "Опасно"))
                    }
                }.font(.caption)
            }
            if let request = row.request {
                if PetApprovalPolicy.allows(risk: request.riskLevel, source: .pet, hidden: hidden) {
                    Text(verbatim: summary(request)).font(.caption).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button(String(localized: "Разрешить")) { model.resolve(row, decision: .approved) }
                        Button(String(localized: "Отклонить")) { model.resolve(row, decision: .rejected) }
                    }
                } else {
                    Button(String(localized: "Открыть в чате")) { model.onOpen?(row.id) }
                }
            }
        }
    }

    private func summary(_ request: ConfirmationRequest) -> String {
        let data = Data(request.toolCall.function.arguments.utf8)
        let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let path = arguments?["path"] as? String ?? arguments?["source"] as? String ?? ""
        return request.toolCall.function.name + " " + path
    }

    private func symbol(_ state: PetState) -> String {
        switch state {
        case .needsApproval: "exclamationmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .toolRunning: "gearshape"
        case .running: "ellipsis.circle"
        case .ready: "checkmark.circle"
        default: "circle"
        }
    }
}

struct PetQuickInput: NSViewRepresentable {
    let model: PetBubbleModel

    func makeNSView(context _: Context) -> PetQuickField {
        let field = PetQuickField()
        field.placeholderString = String(localized: "Быстрый запрос")
        field.setAccessibilityLabel(String(localized: "Быстрый запрос"))
        field.onChange = { model.input = $0 }
        field.onSubmit = { model.send() }
        return field
    }

    func updateNSView(_ field: PetQuickField, context _: Context) {
        if field.stringValue != model.input {
            field.stringValue = model.input
        }
    }
}

final class PetQuickField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder); delegate = self
    }

    override var acceptsFirstResponder: Bool {
        (window as? PetBubblePanel)?.inputFocused == true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let panel = window as? PetBubblePanel else { return false }
        panel.inputFocused = true
        panel.makeKey()
        return panel.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? PetBubblePanel {
            panel.inputFocused = true
            panel.makeKey()
        }
        super.mouseDown(with: event)
        if currentEditor() != nil, let panel = window as? PetBubblePanel {
            panel.inputFocused = true
            panel.makeKey()
        }
    }

    func controlTextDidBeginEditing(_: Notification) {
        if let panel = window as? PetBubblePanel {
            panel.inputFocused = true
            panel.makeKey()
        }
    }

    func controlTextDidChange(_: Notification) {
        onChange?(stringValue)
    }

    func controlTextDidEndEditing(_: Notification) {
        (window as? PetBubblePanel)?.finishInput()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if onSubmit?() == true {
                (window as? PetBubblePanel)?.finishInput()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            (window as? PetBubblePanel)?.onDismiss?()
            return true
        }
        return false
    }
}
