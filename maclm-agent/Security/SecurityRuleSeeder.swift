import Foundation
import SwiftData

enum DefaultSecurityRules {
    static let rules: [SecurityRuleSnapshot] = [
        ("/System/**", "системные файлы"),
        ("/Library/**", "системная библиотека"),
        ("/private/**", "системные внутренности, включая /etc, /var и /tmp"),
        ("/usr/bin/**", "системные бинарники"),
        ("/usr/sbin/**", "системные бинарники"),
        ("/usr/lib/**", "системные библиотеки"),
        ("/usr/libexec/**", "системные вспомогательные программы"),
        ("/usr/share/**", "системные ресурсы"),
        ("/bin/**", "системные бинарники"),
        ("/sbin/**", "системные бинарники"),
        ("~/Library/Keychains/**", "связки ключей"),
        ("~/.ssh/**", "приватные ключи"),
        ("~/.aws/**", "облачные креденшелы"),
        ("~/.config/gcloud/**", "облачные креденшелы"),
        ("**/.env", "файлы с секретами"),
        ("**/.git/config", "конфигурация Git может содержать токены"),
    ].enumerated().map { index, definition in
        SecurityRuleSnapshot(pattern: definition.0, action: .block, order: index,
                             isBuiltIn: true, ruleDescription: definition.1)
    }
}

enum SecurityRuleSeeder {
    @MainActor
    static func seedIfNeeded(context: ModelContext) throws {
        var descriptor = FetchDescriptor<SecurityRule>(predicate: #Predicate { $0.isBuiltIn })
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return }
        for rule in DefaultSecurityRules.rules {
            context.insert(SecurityRule(
                dimension: rule.dimension, pattern: rule.pattern, action: rule.action,
                order: rule.order, isBuiltIn: true, ruleDescription: rule.ruleDescription
            ))
        }
        try context.save()
    }

    @MainActor
    static func snapshots(context: ModelContext) throws -> [SecurityRuleSnapshot] {
        try context.fetch(FetchDescriptor<SecurityRule>()).map(\.snapshot)
    }
}
