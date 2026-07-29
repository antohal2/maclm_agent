import Foundation

struct DetectedProvider: Identifiable, Equatable, Sendable {
    let provider: LLMProviderKind
    let availableModels: [String]
    let baseURL: URL

    var id: String {
        "\(provider.rawValue)|\(baseURL.absoluteString)"
    }
}

struct ProviderEndpoint: Hashable, Sendable {
    let provider: LLMProviderKind
    let baseURL: URL
}

struct ProviderDiscovery: Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 1.5) {
        self.session = session
        self.timeout = timeout
    }

    func discover(additionalEndpoints: [ProviderEndpoint] = []) async -> [DetectedProvider] {
        let defaults = LLMProviderKind.allCases.map {
            ProviderEndpoint(provider: $0, baseURL: $0.defaultBaseURL)
        }
        let endpoints = uniqueEndpoints(defaults + additionalEndpoints)

        return await withTaskGroup(
            of: DetectedProvider?.self,
            returning: [DetectedProvider].self
        ) { group in
            for endpoint in endpoints {
                group.addTask {
                    await probe(endpoint)
                }
            }

            var detected: [DetectedProvider] = []
            for await result in group {
                if let result {
                    detected.append(result)
                }
            }
            return detected.sorted(by: detectedProviderOrder)
        }
    }

    private func probe(_ endpoint: ProviderEndpoint) async -> DetectedProvider? {
        let modelsURL: URL = switch endpoint.provider {
        case .lmStudio:
            endpoint.baseURL.lmStudioAPIBaseURL.appending(path: "models")
        case .ollama:
            endpoint.baseURL.appending(path: "api/tags")
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard
                let response = response as? HTTPURLResponse,
                (200 ..< 300).contains(response.statusCode)
            else {
                return nil
            }

            let models: [String] = switch endpoint.provider {
            case .lmStudio:
                try JSONDecoder()
                    .decode(LMStudioModelsResponse.self, from: data)
                    .data
                    .map(\.id)
            case .ollama:
                try JSONDecoder()
                    .decode(OllamaModelsResponse.self, from: data)
                    .models
                    .map(\.resolvedName)
            }

            return DetectedProvider(
                provider: endpoint.provider,
                availableModels: Array(Set(models.filter { !$0.isEmpty })).sorted(),
                baseURL: endpoint.baseURL.normalizedServerURL
            )
        } catch {
            return nil
        }
    }

    private func uniqueEndpoints(_ endpoints: [ProviderEndpoint]) -> [ProviderEndpoint] {
        var seen = Set<String>()
        return endpoints.compactMap { endpoint in
            let normalized = endpoint.baseURL.normalizedServerURL
            let key = "\(endpoint.provider.rawValue)|\(normalized.absoluteString)"
            guard seen.insert(key).inserted else {
                return nil
            }
            return ProviderEndpoint(provider: endpoint.provider, baseURL: normalized)
        }
    }

    private func detectedProviderOrder(
        _ lhs: DetectedProvider,
        _ rhs: DetectedProvider
    ) -> Bool {
        let lhsIndex = LLMProviderKind.allCases.firstIndex(of: lhs.provider) ?? 0
        let rhsIndex = LLMProviderKind.allCases.firstIndex(of: rhs.provider) ?? 0
        if lhsIndex != rhsIndex {
            return lhsIndex < rhsIndex
        }
        return lhs.baseURL.absoluteString < rhs.baseURL.absoluteString
    }
}

extension URL {
    var normalizedServerURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url ?? self
    }
}

private struct LMStudioModelsResponse: Decodable {
    let data: [LMStudioModel]
}

private struct LMStudioModel: Decodable {
    let id: String
}

private struct OllamaModelsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String?
    let model: String?

    var resolvedName: String {
        name ?? model ?? ""
    }
}
