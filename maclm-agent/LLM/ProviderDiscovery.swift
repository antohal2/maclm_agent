import Foundation

struct DetectedProvider: Identifiable, Equatable, Sendable {
    let provider: LLMProviderKind
    let availableModels: [ModelInfo]
    let baseURL: URL

    var id: String {
        "\(provider.rawValue)|\(baseURL.absoluteString)"
    }
}

struct ProviderEndpoint: Codable, Hashable, Sendable {
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
            let (data, response) = try await session.data(
                for: request,
                delegate: ProviderRedirectPolicy(origin: request.url!)
            )
            guard
                let response = response as? HTTPURLResponse,
                (200 ..< 300).contains(response.statusCode)
            else {
                return nil
            }

            let models = try await metadata(endpoint: endpoint, data: data)

            return DetectedProvider(
                provider: endpoint.provider,
                availableModels: Self.uniqueModels(models),
                baseURL: endpoint.baseURL.normalizedServerURL
            )
        } catch {
            return nil
        }
    }

    private func metadata(endpoint: ProviderEndpoint, data: Data) async throws -> [ModelInfo] {
        var models: [ModelInfo]
        switch endpoint.provider {
        case .lmStudio:
            models = try ModelMetadataParser.lmStudio(data)
            if let metadata = await fetch(endpoint.baseURL.lmStudioMetadataBaseURL.appending(path: "api/v1/models")),
               let detailed = try? ModelMetadataParser.lmStudio(metadata), !detailed.isEmpty {
                models = detailed
            } else if let metadata = await fetch(endpoint.baseURL.lmStudioMetadataBaseURL
                .appending(path: "api/v0/models")),
                let detailed = try? ModelMetadataParser.lmStudio(metadata), !detailed.isEmpty {
                models = detailed
            }
        case .ollama:
            models = try ModelMetadataParser.ollamaTags(data)
            let running = await fetch(endpoint.baseURL.appending(path: "api/ps"))
            models = await withTaskGroup(of: ModelInfo.self) { group in
                for model in models {
                    group.addTask {
                        let body = try? JSONSerialization.data(withJSONObject: ["model": model.id])
                        let show = await fetch(endpoint.baseURL.appending(path: "api/show"), body: body)
                        return ModelMetadataParser.enrichOllama(model, show: show, running: running)
                    }
                }
                var enriched: [ModelInfo] = []
                for await model in group {
                    enriched.append(model)
                }
                return enriched
            }
        }
        return models
    }

    static func uniqueModels(_ models: [ModelInfo]) -> [ModelInfo] {
        var result: [String: ModelInfo] = [:]
        for model in models where !model.id.isEmpty {
            if result[model.id] == nil || model.isLoaded == true {
                result[model.id] = model
            }
        }
        return result.values.sorted { $0.id < $1.id }
    }

    private func fetch(_ url: URL, body: Data? = nil) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpBody = body
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(
            for: request,
            delegate: ProviderRedirectPolicy(origin: request.url!)
        ),
            let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return nil }
        return data
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
    var lmStudioMetadataBaseURL: URL {
        lastPathComponent.lowercased() == "v1" ? deletingLastPathComponent() : self
    }

    var normalizedServerURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        if components.path == "/" {
            components.path = ""
        }
        components.query = nil
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url ?? self
    }
}

/// Metadata discovery must never follow a redirect to another host.
private final class ProviderRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let origin: URL
    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.host == origin.host,
              url.scheme == origin.scheme, url.port == origin.port
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
