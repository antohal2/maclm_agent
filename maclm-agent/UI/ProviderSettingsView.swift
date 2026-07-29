import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var coordinator: ProviderCoordinator

    @State private var manualProvider: LLMProviderKind
    @State private var manualURL: String
    @State private var manualModel: String
    @State private var validationMessage: String?

    init(coordinator: ProviderCoordinator) {
        self.coordinator = coordinator
        let selection = coordinator.selection
        _manualProvider = State(initialValue: selection?.provider ?? .lmStudio)
        _manualURL = State(
            initialValue: selection?.baseURL.absoluteString
                ?? LLMProviderKind.lmStudio.defaultBaseURL.absoluteString
        )
        _manualModel = State(initialValue: selection?.model ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if coordinator.detectedProviders.isEmpty {
                Text(coordinator.isDiscovering ? "Поиск локальных серверов…" : "Серверы не найдены")
                    .foregroundStyle(.secondary)
            } else {
                detectedProviderList
            }

            Divider()
            manualConfiguration

            if let message = validationMessage ?? coordinator.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(validationMessage == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .task {
            await coordinator.discoverIfNeeded()
            syncManualFields()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("LLM-провайдер")
                    .font(.headline)
                Text(coordinator.activeProviderTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(
                    coordinator.connectionState.title,
                    systemImage: connectionStatusSymbol
                )
                .font(.caption)
                .foregroundStyle(connectionStatusColor)
            }

            Spacer()

            Button {
                Task {
                    await coordinator.refresh()
                    syncManualFields()
                }
            } label: {
                if coordinator.isDiscovering {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
            }
            .disabled(coordinator.isDiscovering)
        }
    }

    private var detectedProviderList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Обнаружены")
                .font(.subheadline.weight(.semibold))

            ForEach(coordinator.detectedProviders) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(provider.provider.displayName)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(provider.baseURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if provider.availableModels.isEmpty {
                        Text("Нет моделей")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(provider.availableModels, id: \.self) { model in
                            Button {
                                coordinator.select(provider, model: model)
                                syncManualFields()
                            } label: {
                                HStack {
                                    Image(
                                        systemName: isSelected(provider, model: model)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    Text(model)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var manualConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ручная настройка")
                .font(.subheadline.weight(.semibold))

            Picker("Тип", selection: $manualProvider) {
                ForEach(LLMProviderKind.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            TextField("http://localhost:1234", text: $manualURL)
                .textFieldStyle(.roundedBorder)

            TextField("Название модели", text: $manualModel)
                .textFieldStyle(.roundedBorder)

            Button("Применить") {
                do {
                    try coordinator.configureManually(
                        provider: manualProvider,
                        baseURLText: manualURL,
                        model: manualModel
                    )
                    validationMessage = nil
                    Task {
                        await coordinator.refresh()
                        syncManualFields()
                    }
                } catch {
                    validationMessage = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .onChange(of: manualProvider) {
            manualURL = manualProvider.defaultBaseURL.absoluteString
        }
    }

    private func isSelected(_ provider: DetectedProvider, model: String) -> Bool {
        guard let selection = coordinator.selection else {
            return false
        }
        return selection.provider == provider.provider
            && selection.baseURL.normalizedServerURL == provider.baseURL.normalizedServerURL
            && selection.model == model
    }

    private func syncManualFields() {
        guard let selection = coordinator.selection else {
            return
        }
        manualProvider = selection.provider
        manualURL = selection.baseURL.absoluteString
        manualModel = selection.model
        validationMessage = nil
    }

    private var connectionStatusSymbol: String {
        switch coordinator.connectionState {
        case .checking:
            "clock"
        case .available:
            "checkmark.circle.fill"
        case .unavailable:
            "xmark.circle.fill"
        }
    }

    private var connectionStatusColor: Color {
        switch coordinator.connectionState {
        case .checking:
            .secondary
        case .available:
            .green
        case .unavailable:
            .red
        }
    }
}
