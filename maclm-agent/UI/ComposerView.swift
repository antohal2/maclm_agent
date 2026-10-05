import AppKit
import SwiftUI

// Shared by the full window and status-item popover.
enum ComposerRules {
    static func canSubmit(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shortModelName(_ id: String, limit: Int = 28) -> String {
        let name = String(id.split(separator: "/").last ?? "")
        let limit = max(1, limit)
        guard name.count > limit else { return name }
        let head = (limit - 1 + 1) / 2
        return String(name.prefix(head)) + "…" + String(name.suffix(limit - 1 - head))
    }
}

struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isFocused: Bool
    @State private var showsProvider = false

    var body: some View {
        VStack(spacing: 10) {
            TextField("Сообщение для локальной модели", text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.return], phases: .down) { press in
                    // The native field editor owns marked-text commits (IME).
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                       editor.hasMarkedText() {
                        return .ignored
                    }
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    if viewModel.canSend { viewModel.send() }
                    return .handled
                }
            HStack {
                Spacer(minLength: 0)
                Button { showsProvider = true } label: {
                    Text(ComposerRules.shortModelName(viewModel.providerCoordinator.selection?.model ?? "Модель не выбрана"))
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(viewModel.providerCoordinator.selection?.model ?? "Настройки провайдера")
                .popover(isPresented: $showsProvider) {
                    ProviderSettingsView(coordinator: viewModel.providerCoordinator)
                }
                Button {
                    if viewModel.isGenerating { viewModel.stopGeneration() }
                    else { viewModel.send() }
                } label: {
                    Image(systemName: viewModel.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isGenerating && !viewModel.canSend)
                .accessibilityLabel(viewModel.isGenerating ? "Остановить" : "Отправить")
                .help(viewModel.isGenerating ? "Остановить генерацию" : "Отправить")
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isFocused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
        }
    }
}
