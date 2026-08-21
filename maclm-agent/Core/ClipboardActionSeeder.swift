import SwiftData

enum ClipboardActionSeeder {
    @MainActor
    static func seedIfNeeded(context: ModelContext) throws {
        var descriptor = FetchDescriptor<ClipboardAction>()
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else {
            try migrateLegacyBuiltInIDs(context: context)
            return
        }

        for definition in DefaultClipboardActions.definitions {
            context.insert(
                ClipboardAction(
                    id: definition.id,
                    name: definition.name,
                    promptTemplate: definition.promptTemplate,
                    iconSystemName: definition.iconSystemName,
                    sortOrder: definition.sortOrder,
                    isEnabled: definition.isEnabled,
                    isBuiltIn: definition.isBuiltIn
                )
            )
        }
        try context.save()
    }

    private static func migrateLegacyBuiltInIDs(context: ModelContext) throws {
        let actions = try context.fetch(FetchDescriptor<ClipboardAction>())
        let currentIDs = Set(actions.map(\.id))
        var didChange = false

        for definition in DefaultClipboardActions.definitions where !currentIDs.contains(definition.id) {
            guard let legacyAction = actions.first(where: {
                $0.isBuiltIn
                    && $0.name == definition.name
                    && $0.promptTemplate == definition.promptTemplate
                    && $0.iconSystemName == definition.iconSystemName
                    && $0.sortOrder == definition.sortOrder
            }) else {
                continue
            }
            legacyAction.id = definition.id
            didChange = true
        }

        if didChange {
            try context.save()
        }
    }
}
