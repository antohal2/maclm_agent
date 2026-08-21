import AppKit
import Foundation
import SwiftData

enum ClipboardActionStoreError: Error, Equatable, LocalizedError {
    case emptyName
    case nameTooLong
    case duplicateName
    case invalidTemplate(ClipboardActionTemplate.TemplateError)
    case invalidIcon

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Введите название действия."
        case .nameTooLong:
            "Название должно быть не длиннее 60 символов."
        case .duplicateName:
            "Действие с таким названием уже существует."
        case let .invalidTemplate(error):
            switch error {
            case .emptyTemplate:
                "Шаблон промпта не может быть пустым."
            case .missingInputPlaceholder:
                "Добавьте {{input}} — место для текста из буфера обмена."
            }
        case .invalidIcon:
            "Укажите имя существующего SF Symbol."
        }
    }
}

@MainActor
final class ClipboardActionStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    func create(
        name: String,
        promptTemplate: String,
        iconSystemName: String
    ) throws -> ClipboardAction {
        let values = try validatedValues(
            name: name,
            promptTemplate: promptTemplate,
            iconSystemName: iconSystemName,
            excluding: nil
        )
        let actions = try fetchActions()
        let action = ClipboardAction(
            name: values.name,
            promptTemplate: promptTemplate,
            iconSystemName: values.iconSystemName,
            sortOrder: (actions.map(\.sortOrder).max() ?? 0) + 100,
            isBuiltIn: false
        )
        context.insert(action)
        try context.save()
        return action
    }

    func update(
        _ action: ClipboardAction,
        name: String,
        promptTemplate: String,
        iconSystemName: String
    ) throws {
        let values = try validatedValues(
            name: name,
            promptTemplate: promptTemplate,
            iconSystemName: iconSystemName,
            excluding: action.id
        )
        action.name = values.name
        action.promptTemplate = promptTemplate
        action.iconSystemName = values.iconSystemName
        touch(action)
        try context.save()
    }

    func delete(_ action: ClipboardAction) throws {
        context.delete(action)
        try context.save()
    }

    func setEnabled(_ action: ClipboardAction, enabled: Bool) throws {
        action.isEnabled = enabled
        touch(action)
        try context.save()
    }

    func move(from sourceIndex: Int, to destinationIndex: Int) throws {
        var actions = try fetchActions()
        guard
            actions.indices.contains(sourceIndex),
            actions.indices.contains(destinationIndex),
            sourceIndex != destinationIndex
        else {
            return
        }

        let action = actions.remove(at: sourceIndex)
        actions.insert(action, at: destinationIndex)
        for (index, action) in actions.enumerated() {
            let newOrder = (index + 1) * 100
            if action.sortOrder != newOrder {
                action.sortOrder = newOrder
                touch(action)
            }
        }
        try context.save()
    }

    func resetBuiltInsToDefaults() throws {
        let actions = try context.fetch(FetchDescriptor<ClipboardAction>())
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })

        for definition in DefaultClipboardActions.definitions {
            if let action = actionsByID[definition.id] {
                apply(definition, to: action)
            } else {
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
        }
        try context.save()
    }

    func validationError(
        name: String,
        promptTemplate: String,
        iconSystemName: String,
        excluding actionID: UUID?
    ) -> ClipboardActionStoreError? {
        do {
            _ = try validatedValues(
                name: name,
                promptTemplate: promptTemplate,
                iconSystemName: iconSystemName,
                excluding: actionID
            )
            return nil
        } catch let error as ClipboardActionStoreError {
            return error
        } catch {
            return .emptyName
        }
    }

    private func validatedValues(
        name: String,
        promptTemplate: String,
        iconSystemName: String,
        excluding actionID: UUID?
    ) throws -> (name: String, iconSystemName: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ClipboardActionStoreError.emptyName
        }
        guard trimmedName.count <= 60 else {
            throw ClipboardActionStoreError.nameTooLong
        }
        let actions = try fetchActions()
        guard !actions.contains(where: {
            $0.id != actionID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            throw ClipboardActionStoreError.duplicateName
        }
        if case let .failure(error) = ClipboardActionTemplate.validate(promptTemplate) {
            throw ClipboardActionStoreError.invalidTemplate(error)
        }
        let trimmedIcon = iconSystemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NSImage(systemSymbolName: trimmedIcon, accessibilityDescription: nil) != nil else {
            throw ClipboardActionStoreError.invalidIcon
        }
        return (trimmedName, trimmedIcon)
    }

    private func fetchActions() throws -> [ClipboardAction] {
        let descriptor = FetchDescriptor<ClipboardAction>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    private func apply(
        _ definition: DefaultClipboardActions.Definition,
        to action: ClipboardAction
    ) {
        guard
            action.name != definition.name
            || action.promptTemplate != definition.promptTemplate
            || action.iconSystemName != definition.iconSystemName
            || action.sortOrder != definition.sortOrder
            || action.isEnabled != definition.isEnabled
            || action.isBuiltIn != definition.isBuiltIn
        else {
            return
        }
        action.name = definition.name
        action.promptTemplate = definition.promptTemplate
        action.iconSystemName = definition.iconSystemName
        action.sortOrder = definition.sortOrder
        action.isEnabled = definition.isEnabled
        action.isBuiltIn = definition.isBuiltIn
        touch(action)
    }

    private func touch(_ action: ClipboardAction) {
        let now = Date.now
        action.updatedAt = now > action.updatedAt
            ? now
            : action.updatedAt.addingTimeInterval(0.001)
    }
}
