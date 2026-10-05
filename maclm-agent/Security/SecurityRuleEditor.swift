import Foundation
import SwiftData

struct SecurityRuleDraft: Equatable {
    var dimension: RuleDimension = .path
    var pattern = ""
    var action: RuleAction = .block
    var ruleDescription = ""
    var isEnabled = true

    init() {}
    init(_ rule: SecurityRule) {
        dimension = rule.dimension
        pattern = rule.pattern
        action = rule.action
        ruleDescription = rule.ruleDescription
        isEnabled = rule.isEnabled
    }

    var snapshot: SecurityRuleSnapshot {
        .init(
            dimension: dimension,
            pattern: pattern,
            action: action,
            isEnabled: isEnabled,
            ruleDescription: ruleDescription
        )
    }
}

enum SecurityPattern {
    static func error(_ pattern: String, dimension: RuleDimension) -> String? {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Паттерн не должен быть пустым."
        }
        guard !pattern.contains("\0") else { return "Недопустимый нулевой символ." }
        switch dimension {
        case .path:
            return pathError(pattern)
        case .command:
            do { _ = try NSRegularExpression(pattern: pattern) } catch {
                // Foundation omits the offset. ICU's public parser supplies it.
                return "Ошибка regex: \(error.localizedDescription). \(RegexErrorPosition.describe(pattern))"
            }
        case .application:
            if !matchesRegex(pattern, "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$") {
                return "Нужен bundle ID в обратной доменной записи: com.example.app."
            }
        case .host:
            let host = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            if host.utf8.count > 253 || labels.contains(where: {
                $0.utf8.count > 63 || !matchesRegex(String($0), "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")
            }) {
                return "Нужен hostname или домен с wildcard: example.com, *.example.com."
            }
        }
        return nil
    }

    private static func pathError(_ pattern: String) -> String? {
        // The engine supports only *, ** and ?; reject shell glob extensions.
        if pattern.contains(where: { "[]{}\\".contains($0) }) {
            return "Поддерживаются только *, ** и ?. Классы [], группы {} и экранирование не поддерживаются."
        }
        if pattern.contains("***") {
            return "Используйте * или **, не ***."
        }
        return nil
    }

    static func matchesRegex(_ value: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    static func matches(_ value: String, draft: SecurityRuleDraft) -> Bool {
        guard error(draft.pattern, dimension: draft.dimension) == nil else { return false }
        switch draft.dimension {
        case .path:
            var rule = draft.snapshot
            rule.action = .allow
            rule.isEnabled = true
            return SecurityPolicyEngine(rules: [rule]).decision(for: ReadFileTool(), arguments: ["path": value])
                .disposition == .allowed
        case .command: return matchesRegex(value, draft.pattern)
        case .application: return value == draft.pattern
        case .host:
            let host = value.lowercased()
            let pattern = draft.pattern.lowercased()
            if pattern.hasPrefix("*.") {
                return host.hasSuffix(String(pattern.dropFirst())) && host != String(pattern.dropFirst(2))
            }
            return host == pattern
        }
    }

    static func preview(
        _ value: String,
        draft: SecurityRuleDraft,
        replacing: SecurityRuleSnapshot?,
        rules: [SecurityRuleSnapshot]
    ) -> PolicyDecision {
        guard error(draft.pattern, dimension: draft.dimension) == nil else { return .noDecision }
        var candidates = rules
        var edited = draft.snapshot
        if let replacing, let index = candidates.firstIndex(of: replacing) {
            edited.order = replacing.order
            edited.createdAt = replacing.createdAt
            candidates[index] = edited
        } else {
            edited.order = (rules.filter { $0.dimension == draft.dimension }.map(\.order).max() ?? -1) + 1
            candidates.append(edited)
        }
        let engine = SecurityPolicyEngine(rules: candidates)
        return draft.dimension == .path
            ? engine.decision(for: ReadFileTool(), arguments: ["path": value])
            : engine.decision(for: value, dimension: draft.dimension)
    }
}

@MainActor
struct SecurityRuleStore {
    let context: ModelContext
    func rules() throws -> [SecurityRule] {
        try context.fetch(FetchDescriptor<SecurityRule>()).sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.pattern < $1.pattern
        }
    }

    @discardableResult
    func save(_ draft: SecurityRuleDraft, rule: SecurityRule? = nil) throws -> SecurityRule {
        if let rule, rule.isBuiltIn {
            guard draft.dimension == rule.dimension, draft.pattern == rule.pattern,
                  draft.action == rule.action, draft.ruleDescription == rule.ruleDescription
            else {
                throw failure("У встроенного правила меняется только включение.")
            }
            rule.isEnabled = draft.isEnabled
            try context.save()
            return rule
        }
        if let error = SecurityPattern.error(draft.pattern, dimension: draft.dimension) {
            throw failure(error)
        }
        let order = try (rules().filter { $0.dimension == draft.dimension }.map(\.order).max() ?? -1) + 1
        let target = rule ?? SecurityRule(
            dimension: draft.dimension,
            pattern: draft.pattern,
            action: draft.action,
            order: order
        )
        if rule == nil {
            context.insert(target)
        }
        if target.dimension != draft.dimension {
            target.order = order
        }
        target.dimension = draft.dimension
        target.pattern = draft.pattern
        target.action = draft.action
        target.ruleDescription = draft.ruleDescription
        target.isEnabled = draft.isEnabled
        try context.save()
        return target
    }

    func delete(_ rule: SecurityRule) throws {
        guard !rule.isBuiltIn else { throw failure("Встроенные правила нельзя удалить; отключите переключателем.") }
        context.delete(rule)
        try context.save()
    }

    func setEnabled(_ rule: SecurityRule, _ enabled: Bool) throws {
        rule.isEnabled = enabled
        try context.save()
    }

    func move(dimension: RuleDimension, from: IndexSet, to: Int) throws {
        var group = try rules().filter { $0.dimension == dimension }
        let moved = from.sorted().map { group[$0] }
        for index in from.sorted(by: >) {
            group.remove(at: index)
        }
        group.insert(contentsOf: moved, at: to - from.filter { $0 < to }.count)
        for (index, rule) in group.enumerated() {
            rule.order = index
        }
        try context.save()
    }

    func resetBuiltIns() throws {
        let existing = try rules().filter(\.isBuiltIn)
        for rule in existing {
            context.delete(rule)
        }
        for rule in DefaultSecurityRules.rules {
            context.insert(SecurityRule(
                dimension: rule.dimension,
                pattern: rule.pattern,
                action: rule.action,
                order: rule.order,
                isBuiltIn: true,
                ruleDescription: rule.ruleDescription
            ))
        }
        try context.save()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "SecurityRuleEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum RegexErrorPosition {
    static func describe(_ pattern: String) -> String {
        let units = Array(pattern.utf16)
        let offset = units.withUnsafeBufferPointer {
            securityRegexErrorOffset($0.baseAddress, Int32($0.count))
        }
        return "Позиция UTF-16: \(max(0, offset) + 1)."
    }
}
