import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var coordinator: ProviderCoordinator
    @State private var manualProvider: LLMProviderKind = .lmStudio
    @State private var manualURL = "http://localhost:1234"
    @State private var showHidden = false
    @State private var confirmEndpoint = false
    @State private var validationMessage: String?

    var body: some View {
        Form {
            Text(String(localized: "Модель по умолчанию используется в беседах без собственного выбора."))
                .font(.caption).foregroundStyle(.secondary)
            TextField(
                String(localized: "Лимит контекста по умолчанию"),
                value: $coordinator.defaultContextLimit,
                format: .number
            )
            Toggle(String(localized: "Показать скрытые модели"), isOn: $showHidden)
            ForEach(coordinator.endpoints, id: \.self) { endpoint in
                Section(endpoint.provider.displayName) {
                    Text(endpoint.baseURL.absoluteString).textSelection(.enabled)
                    exposureLabel(endpoint.baseURL.absoluteString)
                    HStack {
                        if coordinator.detectedProviders
                            .contains(where: { $0.provider == endpoint.provider && $0.baseURL == endpoint.baseURL }) {
                            Label(String(localized: "Доступен"), systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        } else {
                            Label("Не найден (\(endpoint.baseURL.absoluteString))", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Проверить")) { Task { await coordinator.refresh() } }
                            .disabled(coordinator.isDiscovering)
                    }
                    if let detected = coordinator.detectedProviders
                        .first(where: { $0.provider == endpoint.provider && $0.baseURL == endpoint.baseURL }) {
                        ForEach(detected.availableModels.filter { showHidden || !$0.isEmbedding }) { model in
                            Button {
                                coordinator.select(detected, model: model.id)
                            } label: {
                                HStack {
                                    Image(systemName: coordinator.selection == ProviderSelection(
                                        provider: endpoint.provider,
                                        baseURL: endpoint.baseURL,
                                        model: model.id
                                    ) ? "checkmark.circle.fill" : "circle")
                                    Text(model.id)
                                    Spacer()
                                    if model.isLoaded == true {
                                        Text(String(localized: "загружена")).font(.caption)
                                    }
                                    if let context = model.contextLength {
                                        Text(context >= 1024 ? "\(context / 1024)K" : "\(context)").font(.caption)
                                    }
                                    if model.supportsTools == true {
                                        Text(verbatim: "tools").font(.caption)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isEmbedding)
                            .foregroundStyle(model.isEmbedding ? .secondary : .primary)
                        }
                        if detected.availableModels.isEmpty {
                            Text(String(localized: "Нет моделей"))
                        }
                    }
                }
            }
            Section {
                DisclosureGroup(String(localized: "Свой эндпоинт…")) {
                    Picker(String(localized: "Тип"), selection: $manualProvider) {
                        ForEach(LLMProviderKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField(String(localized: "Адрес"), text: $manualURL)
                    exposureLabel(manualURL)
                    Button(String(localized: "Добавить")) {
                        let exposure = EndpointClassifier
                            .classify(manualURL.trimmingCharacters(in: .whitespacesAndNewlines))
                        if exposure == .lan || exposure == .external {
                            confirmEndpoint = true
                        } else {
                            addEndpoint(confirmed: false)
                        }
                    }
                    if let validationMessage {
                        Text(validationMessage).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await coordinator.discoverIfNeeded() }
        .alert(String(localized: "Добавить эндпоинт?"), isPresented: $confirmEndpoint) {
            Button(String(localized: "Отмена"), role: .cancel) {}
            Button(String(localized: "Подтвердить")) { addEndpoint(confirmed: true) }
        } message: {
            Text(String(localized: "Переписка и содержимое файлов будут отправляться на этот хост"))
            Text(manualURL)
        }
    }

    @ViewBuilder private func exposureLabel(_ address: String) -> some View {
        switch EndpointClassifier.classify(address) {
        case .lan: Text(verbatim: "LAN").foregroundStyle(.orange)
        case .external: Text(String(localized: "Переписка и содержимое файлов будут отправляться на этот хост"))
            .foregroundStyle(.red)
        default: EmptyView()
        }
    }

    private func addEndpoint(confirmed: Bool) {
        do {
            try coordinator.addEndpoint(provider: manualProvider, address: manualURL, confirmed: confirmed)
            validationMessage = nil
            Task { await coordinator.refresh() }
        } catch { validationMessage = error.localizedDescription }
    }
}
