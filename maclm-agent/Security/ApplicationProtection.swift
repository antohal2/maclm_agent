import Foundation
import SwiftData

enum ApplicationProtection {
    static func rules(
        storeURL: URL,
        bundleID: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SecurityRuleSnapshot] {
        let patterns = [
            storeURL.path + "*",
            home.appendingPathComponent("Library/Application Support/" + bundleID).path + "/**",
            home.appendingPathComponent("Library/Preferences/" + bundleID + ".plist").path,
            home.appendingPathComponent("Library/LaunchAgents").path + "/**",
        ]
        return patterns.enumerated().map { index, pattern in
            .init(
                pattern: pattern,
                action: .block,
                order: -100 + index,
                isBuiltIn: true,
                ruleDescription: "Защита данных и конфигурации приложения",
                isMandatory: true
            )
        }
    }

    @MainActor static func ensure(context: ModelContext, storeURL: URL, bundleID: String) throws {
        guard !bundleID.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        let required = rules(storeURL: storeURL, bundleID: bundleID)
        let existing = try context.fetch(FetchDescriptor<SecurityRule>())
        for snapshot in required {
            let rule = existing.first { $0.isMandatory && $0.pattern == snapshot.pattern }
                ?? SecurityRule(
                    dimension: .path,
                    pattern: snapshot.pattern,
                    action: .block,
                    order: snapshot.order,
                    isBuiltIn: true,
                    ruleDescription: snapshot.ruleDescription
                )
            if rule.modelContext == nil {
                context.insert(rule)
            }
            rule.isMandatory = true
            rule.isBuiltIn = true
            rule.isEnabled = true
            rule.action = .block
            rule.dimension = .path
            rule.project = nil
        }
        try context.save()
        let verified = try context.fetch(FetchDescriptor<SecurityRule>())
        guard required.allSatisfy({ wanted in verified.contains {
            $0.pattern == wanted.pattern && $0.isMandatory && $0.isBuiltIn && $0.isEnabled && $0.action == .block && $0
                .project == nil
        } }) else { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}
