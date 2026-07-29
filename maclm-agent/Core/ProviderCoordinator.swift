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

            let model = matchingProvider.availableModels.contains(saved.model)
                ? saved.model
                : matchingProvider.availableModels.first
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
            let provider = detected.first(where: { !$0.availableModels.isEmpty }),
            let model = provider.availableModels.first
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

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            "LLM-провайдер не настроен. Выберите обнаруженную модель или задайте URL вручную."
        case .invalidBaseURL:
            "Укажите полный HTTP(S)-адрес LLM-сервера."
        case .modelRequired:
            "Укажите модель."
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
            "Проверка…"
        case .available:
            "Доступен"
        case .unavailable:
            "Недоступен"
        }
    }
}

@MainActor
@Observable
final class ProviderCoordinator {
    private(set) var detectedProviders: [DetectedProvider] = []
    private(set) var selection: ProviderSelection?
    private(set) var isDiscovering = false
    private(set) var statusMessage: String?

    var hasActiveProvider: Bool {
        selection != nil
    }

    var activeProviderTitle: String {
        guard let selection else {
            return "Провайдер не выбран"
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

        let additionalEndpoints = selection.map {
            [ProviderEndpoint(provider: $0.provider, baseURL: $0.baseURL)]
        } ?? []
        let results = await discovery.discover(additionalEndpoints: additionalEndpoints)
        detectedProviders = results

        let resolved = ProviderSelectionResolver.resolve(saved: selection, detected: results)
        if let resolved {
            selection = resolved
            store.save(resolved)
        }

        if results.isEmpty {
            statusMessage = selection == nil
                ? "Локальные LLM-серверы не найдены. Запустите LM Studio или Ollama либо задайте URL вручную."
                : "Сохранённый сервер сейчас не отвечает. Выбор сохранён; проверьте сервер или задайте другой URL."
        } else if let selection, !isDetected(selection) {
            statusMessage = "Сохранённый сервер сейчас не отвечает. Можно выбрать один из обнаруженных."
        } else if results.allSatisfy(\.availableModels.isEmpty) {
            statusMessage = "LLM-сервер найден, но на нём нет доступных моделей."
        }
        isDiscovering = false
    }

    func select(_ provider: DetectedProvider, model: String) {
        guard provider.availableModels.contains(model) else {
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

    func configureManually(
        provider: LLMProviderKind,
        baseURLText: String,
        model: String
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

        apply(
            ProviderSelection(
                provider: provider,
                baseURL: baseURL.normalizedServerURL,
                model: trimmedModel
            )
        )
    }

    func makeProvider() throws -> any LLMProvider {
        guard let selection else {
            throw ProviderRoutingError.noProviderConfigured
        }

        switch selection.provider {
        case .lmStudio:
            return LMStudioProvider(baseURL: selection.baseURL, model: selection.model)
        case .ollama:
            return OllamaProvider(baseURL: selection.baseURL, model: selection.model)
        }
    }

    private func apply(_ newSelection: ProviderSelection) {
        selection = newSelection
        store.save(newSelection)
        statusMessage = isDetected(newSelection)
            ? nil
            : "Используется заданный вручную сервер. Проверка соединения выполнится при отправке."
    }

    private func isDetected(_ selection: ProviderSelection) -> Bool {
        detectedProviders.contains {
            $0.provider == selection.provider
                && $0.baseURL.normalizedServerURL == selection.baseURL.normalizedServerURL
        }
    }
}
