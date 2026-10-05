import Foundation

enum RiskLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case safe = 0
    case caution = 1
    case dangerous = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var requiresConfirmation: Bool { self != .safe }
    var canBeRemembered: Bool { self == .caution }
}

struct RiskAssessment: Equatable, Sendable {
    let level: RiskLevel
    let reason: String?

    init(level: RiskLevel, reason: String? = nil) {
        self.level = level
        self.reason = reason
    }
}

struct ToolRiskContext: Sendable {
    var allowedDirectories: [String] = []

    func contains(_ path: String?) -> Bool {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let target = normalized(path)
        return allowedDirectories.contains { directory in
            guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            let root = normalized(directory)
            return target == root || target.hasPrefix(root == "/" ? root : root + "/")
        }
    }

    private func normalized(_ path: String) -> String {
        var ancestor = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }
}

/// Security boundary owned by the caller, never dispatched through Tool.
/// Implementations can customize only computeRisk, not either invariant.
enum ToolRiskEvaluator {
    static func evaluate(
        _ tool: any Tool,
        arguments: [String: Any],
        context: ToolRiskContext
    ) -> RiskAssessment {
        let computed = tool.computeRisk(arguments: arguments, context: context)
        let level = max(type(of: tool).baseRiskLevel, computed.level)
        guard type(of: tool).isPolicyEnforceable else {
            return RiskAssessment(
                level: .dangerous,
                reason: "аргумент — произвольный код, политика неприменима"
            )
        }
        return RiskAssessment(level: level, reason: computed.reason)
    }
}
