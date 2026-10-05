import AppKit
import SwiftUI

/// Shared by the full window and status-item popover.
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
    @State private var policyPresented = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            TextField(String(localized: "Сообщение для локальной модели"), text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 8)
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.return], phases: .down) { press in
                    // The native field editor owns marked-text commits (IME).
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                       editor.hasMarkedText() {
                        return .ignored
                    }
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    if viewModel.canSend {
                        viewModel.send()
                    }
                    return .handled
                }
            HStack {
                Button { policyPresented.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shield")
                        Text(viewModel.selectedConversation?.project?.workingDirectoryPath == nil
                            ? String(localized: "Глобально") : String(localized: "Проект"))
                        if let id = viewModel.selectedConversationID {
                            let count = viewModel.sessionPermissions.permissions(for: id).count
                            if count > 0 {
                                Text(count.description)
                            }
                        }
                    }.font(.caption)
                }.buttonStyle(.plain)
                    .popover(isPresented: $policyPresented) {
                        SessionPolicyView(viewModel: viewModel).padding().frame(width: 320)
                    }
                Spacer(minLength: 0)
                Button {
                    UserDefaults.standard.set("models", forKey: "settings.selectedTab")
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text(ComposerRules
                        .shortModelName(viewModel.providerCoordinator.selection?
                            .model ?? String(localized: "Модель не выбрана")))
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(viewModel.providerCoordinator.selection?.model ?? String(localized: "Настройки провайдера"))
                Button {
                    if viewModel.isGenerating {
                        viewModel.stopGeneration()
                    } else {
                        viewModel.send()
                    }
                } label: {
                    Image(systemName: viewModel.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isGenerating && !viewModel.canSend)
                .accessibilityLabel(viewModel
                    .isGenerating ? String(localized: "Остановить") : String(localized: "Отправить"))
                .help(viewModel
                    .isGenerating ? String(localized: "Остановить генерацию") : String(localized: "Отправить"))
            }
            if let project = viewModel.selectedConversation?.project {
                HStack {
                    Text(project.name)
                    if let path = project.workingDirectoryPath,
                       let branch = GitHeadReader.read(workingDirectory: path) {
                        Text(branch)
                    }
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
