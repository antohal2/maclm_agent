import SwiftData

enum ClipboardActionSeeder {
    @MainActor
    static func seedIfNeeded(context: ModelContext) throws {
        var descriptor = FetchDescriptor<ClipboardAction>()
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else {
            return
        }

        for definition in DefaultClipboardActions.definitions {
            context.insert(
                ClipboardAction(
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
}
