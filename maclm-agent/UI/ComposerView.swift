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
    @State private var modelPresented = false
    @State private var policyPresented = false
    @Environment(\.openSettings) private var openSettings

    private var contextUsage: ContextUsage {
        ContextUsage(
            used: viewModel.selectedConversation?.lastContextTokens,
            model: viewModel.providerCoordinator.modelInfo(for: viewModel.selectedConversation),
            fallback: viewModel.providerCoordinator.defaultContextLimit
        )
    }

    private var contextHelp: String {
        var text = contextUsage
            .approximate ? String(localized: "Фактический лимит неизвестен; используется настройка по умолчанию.") : ""
        if let maximum = viewModel.providerCoordinator.modelInfo(for: viewModel.selectedConversation)?.contextLength {
            text += " " + String(localized: "Максимум модели:") + " " + ContextUsage.format(maximum)
        }
        if contextUsage.level == .critical {
            text += " " +
                String(localized: "Контекст почти заполнен — начните новую сессию или сделайте ветку от нужного ответа")
        }
        return text
    }

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
                       editor.hasMarkedText()
                    {
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
                Button { modelPresented.toggle() } label: {
                    Text(ComposerRules.shortModelName(viewModel.providerCoordinator
                            .sessionSelection(viewModel.selectedConversation)?
                            .model ?? String(localized: "Модель не выбрана")))
                        .font(.caption).padding(6).background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isGenerating)
                .popover(isPresented: $modelPresented) {
                    VStack(alignment: .leading) {
                        Button(String(localized: "По умолчанию")) {
                            viewModel.selectedConversation?.modelID = nil
                            viewModel.selectedConversation?.providerID = nil
                            viewModel.saveContext()
                            modelPresented = false
                        }
                        ForEach(viewModel.providerCoordinator.endpoints, id: \.self) { endpoint in
                            Text(endpoint.provider.displayName + " · " + endpoint.baseURL.absoluteString)
                                .font(.caption).foregroundStyle(.secondary)
                            if let provider = viewModel.providerCoordinator.detectedProviders
                                .first(where: { $0.id == endpoint.id })
                            {
                                ForEach(provider.availableModels.filter { !$0.isEmbedding }) { model in
                                    Button {
                                        viewModel.selectedConversation?.modelID = model.id
                                        viewModel.selectedConversation?.providerID = endpoint.id
                                        viewModel.selectedConversation?.lastContextTokens = nil
                                        viewModel.saveContext()
                                        modelPresented = false
                                    } label: {
                                        HStack {
                                            Text(model.id)
                                            if model.isLoaded == true {
                                                Text(String(localized: "загружена"))
                                            }
                                            if let limit = model.loadedContextLength {
                                                Text(ContextUsage.format(limit))
                                            }
                                            if model.supportsTools == true {
                                                Text(verbatim: "tools")
                                            }
                                            if model.supportsTools == false {
                                                Text(String(localized: "Инструменты недоступны для этой модели"))
                                            }
                                        }
                                    }
                                    .help(model
                                        .supportsTools == false ?
                                        String(localized: "Инструменты недоступны для этой модели") : model.id)
                                }
                            } else {
                                Text(String(localized: "Не найден"))
                            }
                        }
                        Divider()
                        Button(String(localized: "Настройки моделей…")) {
                            UserDefaults.standard.set("models", forKey: "settings.selectedTab")
                            openSettings()
                            modelPresented = false
                        }
                    }.padding().frame(maxWidth: 560)
                        .task { await viewModel.providerCoordinator.refresh() }
                }
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
            HStack {
                if let project = viewModel.selectedConversation?.project {
                    Text(project.name)
                    if let path = project.workingDirectoryPath,
                       let branch = GitHeadReader.read(workingDirectory: path)
                    {
                        Text(branch)
                    }
                }
                Spacer()
                if !viewModel.messages.isEmpty {
                    let usage = contextUsage
                    Text(String(localized: "Контекст:") + " " + (usage.used.map { ContextUsage.format($0) } ?? "—")
                        + " / " + (usage.approximate ? "≈ " : "") + ContextUsage.format(usage.limit))
                        .foregroundStyle(usage.level == .critical ? Color.red : usage.level == .warning ? Color
                            .yellow : Color.secondary)
                        .help(contextHelp)
                }
            }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if viewModel.providerCoordinator.modelInfo(for: viewModel.selectedConversation)?.supportsTools == false {
                Text(String(localized: "Инструменты недоступны для этой модели")).font(.caption)
            }
            if !viewModel.messages.isEmpty, contextUsage.level == .critical {
                Text(
                    String(
                        localized: "Контекст почти заполнен — начните новую сессию или сделайте ветку от нужного ответа"
                    )
                )
                .font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: viewModel.isGenerating) { _, generating in
            if generating {
                modelPresented = false
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
