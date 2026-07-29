import Foundation

protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersSchema: JSONSchema { get }
    var riskLevel: RiskLevel { get }

    func execute(arguments: [String: Any]) async throws -> ToolExecutionResult
}

enum RiskLevel: String, Codable, Equatable, Sendable {
    case safe
    case confirm
    case deny
}

struct ToolExecutionResult: Equatable, Sendable {
    let content: String
    let displayContent: String?
    let isError: Bool

    static func success(
        content: String,
        displayContent: String? = nil
    ) -> Self {
        Self(
            content: content,
            displayContent: displayContent,
            isError: false
        )
    }

    static func failure(_ message: String) -> Self {
        Self(
            content: "Error: \(message)",
            displayContent: message,
            isError: true
        )
    }
}

indirect enum JSONSchema: Codable, Equatable, Sendable {
    case object(
        properties: [String: Self],
        required: [String],
        description: String? = nil
    )
    case string(description: String? = nil, enumValues: [String]? = nil)
    case integer(description: String? = nil)
    case array(items: Self, description: String? = nil)

    private enum SchemaType: String, Codable {
        case object
        case string
        case integer
        case array
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case properties
        case required
        case items
        case enumValues = "enum"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SchemaType.self, forKey: .type)
        let description = try container.decodeIfPresent(String.self, forKey: .description)

        switch type {
        case .object:
            self = try .object(
                properties: container.decodeIfPresent(
                    [String: Self].self,
                    forKey: .properties
                ) ?? [:],
                required: container.decodeIfPresent(
                    [String].self,
                    forKey: .required
                ) ?? [],
                description: description
            )
        case .string:
            self = try .string(
                description: description,
                enumValues: container.decodeIfPresent([String].self, forKey: .enumValues)
            )
        case .integer:
            self = .integer(description: description)
        case .array:
            self = try .array(
                items: container.decode(Self.self, forKey: .items),
                description: description
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .object(properties, required, description):
            try container.encode(SchemaType.object, forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encode(required, forKey: .required)
            try container.encodeIfPresent(description, forKey: .description)
        case let .string(description, enumValues):
            try container.encode(SchemaType.string, forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(enumValues, forKey: .enumValues)
        case let .integer(description):
            try container.encode(SchemaType.integer, forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
        case let .array(items, description):
            try container.encode(SchemaType.array, forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }
}

struct ToolRegistry: Sendable {
    private var toolsByName: [String: any Tool] = [:]

    init(tools: [any Tool] = []) {
        for tool in tools {
            toolsByName[tool.name] = tool
        }
    }

    mutating func register(_ tool: any Tool) {
        toolsByName[tool.name] = tool
    }

    func tool(named name: String) -> (any Tool)? {
        toolsByName[name]
    }

    var definitions: [ToolDefinition] {
        toolsByName.values
            .sorted { $0.name < $1.name }
            .map { tool in
                ToolDefinition(
                    function: ToolFunctionDefinition(
                        name: tool.name,
                        description: tool.description,
                        parameters: tool.parametersSchema
                    )
                )
            }
    }

    static var readOnly: Self {
        Self(
            tools: [
                ReadFileTool(),
                ListDirectoryTool(),
                SearchFilesTool(),
            ]
        )
    }

    static var all: Self {
        Self(
            tools: [
                ReadFileTool(),
                ListDirectoryTool(),
                SearchFilesTool(),
                WriteFileTool(),
                MoveFileTool(),
                DeleteFileTool(),
                RunShellTool(),
            ]
        )
    }
}

enum ToolArgument {
    enum StringValue {
        case value(String)
        case error(ToolExecutionResult)
    }

    static func requiredString(
        named name: String,
        in arguments: [String: Any]
    ) -> StringValue {
        guard let value = arguments[name] as? String else {
            return .error(.failure("Argument '\(name)' must be a string."))
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error(.failure("Argument '\(name)' must not be empty."))
        }
        return .value(trimmed)
    }

    static func requiredRawString(
        named name: String,
        in arguments: [String: Any]
    ) -> StringValue {
        guard let value = arguments[name] as? String else {
            return .error(.failure("Argument '\(name)' must be a string."))
        }
        return .value(value)
    }
}
