import Foundation

enum PolicyDisposition: Equatable, Sendable {
    case noDecision, allowed, blocked
}

struct PolicyDecision: Equatable, Sendable {
    let disposition: PolicyDisposition
    let rule: SecurityRuleSnapshot?
    let explanation: String?
    var isAllowed: Bool {
        disposition != .blocked
    }

    static let noDecision = Self(disposition: .noDecision, rule: nil, explanation: nil)
}

struct SecurityPolicyEngine: Sendable {
    private let rules: [SecurityRuleSnapshot]

    let invocation: ToolInvocationContext

    init(rules: [SecurityRuleSnapshot], invocation: ToolInvocationContext) {
        self.invocation = invocation
        var effective = rules.filter { rule in
            if rule.isMandatory {
                return true
            }
            guard rule.isEnabled else { return false }
            guard invocation.workingDirectory != nil else { return rule.projectID == nil }
            if rule.action == .block {
                return rule.projectID == nil || rule.projectID == invocation.project?.id
            }
            return rule.projectID == invocation.project?.id && rule.projectID != nil
        }
        if let directory = invocation.workingDirectory {
            effective.append(.init(pattern: PathCanonicalizer.canonicalize(directory) + "/**", action: .allow))
        }
        self.rules = effective.sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.pattern < $1.pattern
        }
    }

    var blockRuleCount: Int {
        rules.filter { $0.dimension == .path && $0.action == .block }.count
    }

    func isInProjectAllowedZone(_ path: String) -> Bool {
        Self(rules: rules.filter { $0.action == .allow }, invocation: invocation)
            .decision(for: path, dimension: .path).disposition == .allowed
    }

    func decision(for value: String, dimension: RuleDimension) -> PolicyDecision {
        // command/application/host are storage-only in 3.1. Future host checks
        // cover explicit URLs only: npm install or arbitrary code can contact
        // destinations that static argument analysis cannot determine.
        guard dimension == .path else { return .noDecision }
        let canonical = PathCanonicalizer.canonicalize(value)
        let caseSensitive = PathCanonicalizer.isCaseSensitive(canonical)
        let matched = rules.filter { rule in
            guard rule.dimension == .path else { return false }
            let pattern = PathCanonicalizer.canonicalizePattern(rule.pattern)
            var ancestor = canonical
            while true {
                if PathGlob.matches(
                    caseSensitive ? ancestor : ancestor.lowercased(),
                    pattern: caseSensitive ? pattern : pattern.lowercased()
                ) {
                    return true
                }
                if ancestor == "/" {
                    return false
                }
                ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
            }
        }
        guard let rule = matched.first(where: { $0.action == .block }) ?? matched.first else {
            return .noDecision
        }
        let blocked = rule.action == .block
        return PolicyDecision(
            disposition: blocked ? .blocked : .allowed,
            rule: rule,
            explanation: "\(blocked ? "Запрещено" : "Разрешено") правилом '\(rule.pattern)': "
                + "\(rule.ruleDescription). Путь: \(canonical)"
        )
    }

    func decision(for tool: any Tool, arguments: [String: Any]) -> PolicyDecision {
        // Universal run_shell intentionally bypasses path policies. Even
        // `cat ~/.ssh/id_rsa` requires only human confirmation; do not parse code.
        guard type(of: tool).isPolicyEnforceable else { return .noDecision }
        var allowed: PolicyDecision = .noDecision
        let prepared = executionArguments(for: tool, arguments: arguments)
        for key in Self.pathKeys(for: tool) {
            guard let path = arguments[key] as? String else { continue }
            // Check POSIX traversal and the lexical normalization actually used
            // by the existing tools. Symlink/.. can resolve differently in these
            // two forms; neither form may bypass a block.
            let paths = [path, prepared[key] as? String ?? path]
            for candidate in paths {
                let decision = decision(for: candidate, dimension: .path)
                if !decision.isAllowed {
                    return decision
                }
                if decision.disposition == .allowed {
                    allowed = decision
                }
            }
        }
        return allowed
    }

    func executionArguments(for tool: any Tool, arguments: [String: Any]) -> [String: Any] {
        guard type(of: tool).isPolicyEnforceable else { return arguments }
        // Expand '~' and preserve the existing tools' lexical path semantics.
        // Do not substitute a symlink's target: atomic writes replace the link,
        // while move/delete operate on the link itself, not its target.
        var prepared = arguments
        for key in Self.pathKeys(for: tool) {
            if let path = arguments[key] as? String,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                    .expandingTildeInPath
                prepared[key] = URL(fileURLWithPath: expanded).standardizedFileURL.path
            }
        }
        return prepared
    }

    private static func pathKeys(for tool: any Tool) -> [String] {
        switch tool {
        case is ReadFileTool, is WriteFileTool, is DeleteFileTool, is ListDirectoryTool: ["path"]
        case is MoveFileTool: ["from", "to"]
        case is SearchFilesTool: ["root"]
        default: []
        }
    }
}
