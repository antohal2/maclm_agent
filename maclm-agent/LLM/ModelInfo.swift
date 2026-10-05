import Foundation

struct ModelInfo: Identifiable, Equatable, Sendable, ExpressibleByStringLiteral {
    enum Kind: String, Sendable { case chat, embedding, unknown }
    let id: String
    var kind: Kind?
    var isLoaded: Bool?
    var contextLength: Int?
    var supportsTools: Bool?

    init(id: String, kind: Kind? = nil, isLoaded: Bool? = nil, contextLength: Int? = nil, supportsTools: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.isLoaded = isLoaded
        self.contextLength = contextLength
        self.supportsTools = supportsTools
    }

    init(stringLiteral value: String) {
        self.init(id: value)
    }

    var isEmbedding: Bool {
        if let kind, kind != .unknown {
            return kind == .embedding
        }
        return id.range(of: "embed", options: .caseInsensitive) != nil
    }
}

enum ModelMetadataParser {
    static func lmStudio(_ data: Data) throws -> [ModelInfo] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((root?["data"] ?? root?["models"]) as? [[String: Any]] ?? []).compactMap { row in
            guard let id = (row["key"] ?? row["id"]) as? String else { return nil }
            let kind: ModelInfo.Kind? = switch row["type"] as? String {
            case "llm", "vlm": .chat
            case "embeddings", "embedding": .embedding
            case nil: nil
            default: .unknown
            }
            let state = row["state"] as? String
            return ModelInfo(
                id: id,
                kind: kind,
                isLoaded: (row["loaded_instances"] as? [[String: Any]])
                    .map { !$0.isEmpty } ?? (state == "loaded" ? true : state == "not-loaded" ? false : nil),
                contextLength: row["max_context_length"] as? Int,
                supportsTools: (row["capabilities"] as? [String: Any])?["trained_for_tool_use"] as? Bool
            )
        }
    }

    static func ollamaTags(_ data: Data) throws -> [ModelInfo] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["models"] as? [[String: Any]] ?? []).compactMap {
            guard let id = ($0["name"] ?? $0["model"]) as? String else { return nil }
            return ModelInfo(id: id)
        }
    }

    static func enrichOllama(_ model: ModelInfo, show: Data?, running: Data?) -> ModelInfo {
        var result = model
        if let show, let root = (try? JSONSerialization.jsonObject(with: show)) as? [String: Any] {
            if let capabilities = root["capabilities"] as? [String] {
                result.supportsTools = capabilities.contains("tools")
                result.kind = capabilities.contains("completion") ? .chat : capabilities
                    .contains("embedding") ? .embedding : .unknown
            }
            if let info = root["model_info"] as? [String: Any],
               let architecture = info["general.architecture"] as? String {
                result.contextLength = info["\(architecture).context_length"] as? Int
            }
        }
        if let running, let root = (try? JSONSerialization.jsonObject(with: running)) as? [String: Any],
           let models = root["models"] as? [[String: Any]] {
            result.isLoaded = models.contains { ($0["name"] as? String ?? $0["model"] as? String) == model.id }
        }
        return result
    }
}
