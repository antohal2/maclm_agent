import Foundation
import Observation

struct ProviderSelection: Codable, Equatable, Sendable {
    let provider: LLMProviderKind
    let baseURL: URL
    let model: String
}

struct ProviderSelectionStore {
    private enum Key {
        static let provider = "llm.selectedProvider"
        static let baseURL = "llm.baseURL"
        static let model = "llm.selectedModel"
    }

    var contextLimit: Int {
        get { defaults.object(forKey: "llm.defaultContextLimit") as? Int ?? 8192 }
        nonmutating set { defaults.set(newValue, forKey: "llm.defaultContextLimit") }
    }

    func loadEndpoints() -> [ProviderEndpoint] {
        var endpoints = defaults.data(forKey: "llm.endpoints").flatMap { try? JSONDecoder().decode(
            [ProviderEndpoint].self,
            from: $0
        ) } ?? []
        if let saved = load() {
            let endpoint = ProviderEndpoint(provider: saved.provider, baseURL: saved.baseURL)
            if !endpoints.contains(endpoint) {
                endpoints.append(endpoint)
            }
        }
        return endpoints
    }

    func saveEndpoints(_ endpoints: [ProviderEndpoint]) {
        defaults.set(try? JSONEncoder().encode(endpoints), forKey: "llm.endpoints")
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ProviderSelection? {
        guard
            let providerValue = defaults.string(forKey: Key.provider),
            let provider = LLMProviderKind(rawValue: providerValue),
            let baseURLValue = defaults.string(forKey: Key.baseURL),
            let baseURL = URL(string: baseURLValue),
            let model = defaults.string(forKey: Key.model),
            !model.isEmpty
        else {
            return nil
        }

        return ProviderSelection(
            provider: provider,
            baseURL: baseURL.normalizedServerURL,
            model: model
        )
    }

    func save(_ selection: ProviderSelection) {
        defaults.set(selection.provider.rawValue, forKey: Key.provider)
        defaults.set(selection.baseURL.absoluteString, forKey: Key.baseURL)
        defaults.set(selection.model, forKey: Key.model)
    }
}

enum ProviderSelectionResolver {
    static func resolve(
        saved: ProviderSelection?,
        detected: [DetectedProvider]
    ) -> ProviderSelection? {
        if let saved {
            guard let matchingProvider = detected.first(where: {
                $0.provider == saved.provider
                    && $0.baseURL.normalizedServerURL == saved.baseURL.normalizedServerURL
            }) else {
                // Keep an offline or manually configured endpoint selected so a
                // temporary discovery failure does not overwrite user intent.
                return saved
            }

            let model = matchingProvider.availableModels.contains { $0.id == saved.model && !$0.isEmbedding }
                ? saved.model
                : matchingProvider.availableModels.first(where: { !$0.isEmbedding })?.id
            guard let model else {
                return saved
            }
            return ProviderSelection(
                provider: saved.provider,
                baseURL: matchingProvider.baseURL,
                model: model
            )
        }

        guard
            let provider = detected.first(where: { $0.availableModels.contains { !$0.isEmbedding } }),
            let model = provider.availableModels.first(where: { !$0.isEmbedding })?.id
        else {
            return nil
        }
        return ProviderSelection(
            provider: provider.provider,
            baseURL: provider.baseURL,
            model: model
        )
    }
}

enum ProviderRoutingError: Error, LocalizedError {
    case noProviderConfigured
    case invalidBaseURL
    case modelRequired
    case confirmationRequired

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            String(localized: "LLM-провайдер не настроен. Выберите обнаруженную модель или задайте URL вручную.")
        case .invalidBaseURL:
            String(localized: "Укажите полный HTTP(S)-адрес LLM-сервера.")
        case .confirmationRequired:
            String(localized: "Подтвердите отправку данных на этот хост.")
        case .modelRequired:
            String(localized: "Укажите модель.")
        }
    }
}

enum ProviderConnectionState {
    case checking
    case available
    case unavailable

    var title: String {
        switch self {
        case .checking:
            String(localized: "Проверка…")
        case .available:
            String(localized: "Доступен")
        case .unavailable:
            String(localized: "Недоступен")
        }
    }
}

@MainActor
@Observable
final class ProviderCoordinator {
    private(set) var customEndpoints: [ProviderEndpoint]
    private(set) var detectedProviders: [DetectedProvider] = []
    private(set) var selection: ProviderSelection?
    private(set) var isDiscovering = false
    private(set) var statusMessage: String?

    var hasActiveProvider: Bool {
        selection != nil && !selectionIsEmbedding
    }

    var activeProviderTitle: String {
        guard let selection else {
            return String(localized: "Провайдер не выбран")
        }
        return "\(selection.provider.displayName) · \(selection.model)"
    }

    var connectionState: ProviderConnectionState {
        if isDiscovering {
            return .checking
        }
        guard let selection, isDetected(selection) else {
            return .unavailable
        }
        return .available
    }

    private let store: ProviderSelectionStore
    private let discovery: ProviderDiscovery
    private var hasStartedDiscovery = false

    init(
        store: ProviderSelectionStore = ProviderSelectionStore(),
        discovery: ProviderDiscovery = ProviderDiscovery()
    ) {
        self.store = store
        self.discovery = discovery
        selection = store.load()
        customEndpoints = store.loadEndpoints()
        defaultContextLimit = max(1, store.contextLimit)
    }

    func discoverIfNeeded() async {
        guard !hasStartedDiscovery else {
            return
        }
        hasStartedDiscovery = true
        await refresh()
    }

    func refresh() async {
        guard !isDiscovering else {
            return
        }
        isDiscovering = true
        statusMessage = nil

        let results = await discovery.discover(additionalEndpoints: customEndpoints)
        detectedProviders = results

        let resolved = ProviderSelectionResolver.resolve(saved: selection, detected: results)
        if let resolved {
            selection = resolved
            store.save(resolved)
        }

        if results.isEmpty {
            statusMessage = selection == nil
                ?
                String(
                    localized: """
                    Локальные LLM-серверы не найдены. Запустите LM Studio или Ollama либо задайте URL \
                    вручную.
                    """
                )
                :
                String(
                    localized: """
                    Сохранённый сервер сейчас не отвечает. Выбор сохранён; проверьте сервер или задайте \
                    другой URL.
                    """
                )
        } else if let selection, !isDetected(selection) {
            statusMessage =
                String(localized: "Сохранённый сервер сейчас не отвечает. Можно выбрать один из обнаруженных.")
        } else if results.allSatisfy(\.availableModels.isEmpty) {
            statusMessage = String(localized: "LLM-сервер найден, но на нём нет доступных моделей.")
        }
        isDiscovering = false
    }

    func select(_ provider: DetectedProvider, model: String) {
        guard provider.availableModels.contains(where: { $0.id == model && !$0.isEmbedding }) else {
            return
        }
        apply(
            ProviderSelection(
                provider: provider.provider,
                baseURL: provider.baseURL,
                model: model
            )
        )
    }

    var endpoints: [ProviderEndpoint] {
        var result = LLMProviderKind.allCases.map { ProviderEndpoint(provider: $0, baseURL: $0.defaultBaseURL) }
        for endpoint in customEndpoints where !result.contains(endpoint) {
            result.append(endpoint)
        }
        return result
    }

    func addEndpoint(provider: LLMProviderKind, address: String, confirmed: Bool = false) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let exposure = EndpointClassifier.classify(address)
        guard exposure != .invalid, let url = URL(string: address) else { throw ProviderRoutingError.invalidBaseURL }
        guard exposure == .loopback || confirmed else { throw ProviderRoutingError.confirmationRequired }
        let endpoint = ProviderEndpoint(provider: provider, baseURL: url.normalizedServerURL)
        if !endpoints.contains(endpoint) {
            customEndpoints.append(endpoint); store.saveEndpoints(customEndpoints)
        }
    }

    func configureManually(
        provider: LLMProviderKind,
        baseURLText: String,
        model: String,
        confirmed: Bool = false
    ) throws {
        let trimmedURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let baseURL = URL(string: trimmedURL),
            ["http", "https"].contains(baseURL.scheme?.lowercased()),
            baseURL.host != nil
        else {
            throw ProviderRoutingError.invalidBaseURL
        }
        guard !trimmedModel.isEmpty else {
            throw ProviderRoutingError.modelRequired
        }

        let endpoint = ProviderEndpoint(provider: provider, baseURL: baseURL.normalizedServerURL)
        if !endpoints.contains(endpoint) {
            try addEndpoint(provider: provider, address: trimmedURL, confirmed: confirmed)
        }

        apply(
            ProviderSelection(
                provider: provider,
                baseURL: baseURL.normalizedServerURL,
                model: trimmedModel
            )
        )
    }

    func makeProvider() throws -> any LLMProvider {
        try makeProvider(for: nil)
    }

    func makeProvider(for conversation: Conversation?) throws -> any LLMProvider {
        guard let selection = sessionSelection(conversation) else {
            throw ProviderRoutingError.noProviderConfigured
        }

        guard !(modelInfo(for: conversation) ?? ModelInfo(id: selection.model)).isEmbedding
        else { throw ProviderRoutingError.modelRequired }
        switch selection.provider {
        case .lmStudio:
            return LMStudioProvider(baseURL: selection.baseURL, model: selection.model)
        case .ollama:
            return OllamaProvider(baseURL: selection.baseURL, model: selection.model)
        }
    }

    var defaultContextLimit: Int {
        didSet { store.contextLimit = max(1, defaultContextLimit) }
    }

    func sessionSelection(_ conversation: Conversation?) -> ProviderSelection? {
        guard let conversation else { return selection }
        if let id = conversation.providerID {
            guard let endpoint = endpoints.first(where: { $0.id == id }),
                  let model = conversation.modelID ?? selection?.model else { return nil }
            return ProviderSelection(provider: endpoint.provider, baseURL: endpoint.baseURL, model: model)
        }
        guard let selection else { return nil }
        return ProviderSelection(
            provider: selection.provider,
            baseURL: selection.baseURL,
            model: conversation.modelID ?? selection.model
        )
    }

    func modelInfo(for conversation: Conversation?) -> ModelInfo? {
        guard let selected = sessionSelection(conversation) else { return nil }
        return detectedProviders.first { $0.provider == selected.provider && $0.baseURL == selected.baseURL }?
            .availableModels.first { $0.id == selected.model }
    }

    private var selectionIsEmbedding: Bool {
        guard let selection else { return false }
        let info = detectedProviders.first { $0.provider == selection.provider && $0.baseURL == selection.baseURL }?
            .availableModels.first { $0.id == selection.model }
        return (info ?? ModelInfo(id: selection.model)).isEmbedding
    }

    private func apply(_ newSelection: ProviderSelection) {
        selection = newSelection
        store.save(newSelection)
        statusMessage = isDetected(newSelection)
            ? nil
            : String(localized: "Используется заданный вручную сервер. Проверка соединения выполнится при отправке.")
    }

    private func isDetected(_ selection: ProviderSelection) -> Bool {
        detectedProviders.contains {
            $0.provider == selection.provider
                && $0.baseURL.normalizedServerURL == selection.baseURL.normalizedServerURL
        }
    }
}
