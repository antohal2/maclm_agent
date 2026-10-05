import AppKit
import SwiftData
import SwiftUI

struct ClipboardActionsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardAction.sortOrder) private var actions: [ClipboardAction]
    @Bindable var settings: AppSettings
    @Bindable var clipboardHotkeyService: ClipboardHotkeyService
    let accessibilityPermissionService: any AccessibilityPermissionService

    @State private var selectedActionID: UUID?
    @State private var draft: ClipboardActionDraft?
    @State private var savedDraft: ClipboardActionDraft?
    @State private var isCreating = false
    @State private var selectionBeforeCreating: UUID?
    @State private var pendingDestination: EditorDestination?
    @State private var actionPendingDeletion: ClipboardAction?
    @State private var isAccessibilityTrusted = false
    @State private var showsDiscardConfirmation = false
    @State private var showsDeleteConfirmation = false
    @State private var showsResetConfirmation = false
    @State private var operationError: String?

    var body: some View {
        Form {
            clipboardBehaviorSection

            Section(String(localized: "Редактор действий")) {
                HSplitView {
                    actionList
                    editor
                }
                .frame(minHeight: 430)
            }

            Section {
                Button(String(localized: "Сбросить встроенные действия"), role: .destructive) {
                    showsResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            refreshAccessibilityStatus()
            ensureSelection()
        }
        .onChange(of: actions.map(\.id)) {
            ensureSelection()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshAccessibilityStatus()
        }
        .alert(String(localized: "Несохранённые изменения"), isPresented: $showsDiscardConfirmation) {
            Button(String(localized: "Отменить"), role: .cancel) {
                pendingDestination = nil
            }
            Button(String(localized: "Не сохранять"), role: .destructive) {
                applyPendingDestination()
            }
        } message: {
            Text(String(localized: "Изменения текущего действия будут потеряны."))
        }
        .alert(String(localized: "Удалить действие?"), isPresented: $showsDeleteConfirmation) {
            Button(String(localized: "Отменить"), role: .cancel) {}
            Button(String(localized: "Удалить"), role: .destructive, action: deletePendingAction)
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(String(localized: "Сбросить встроенные действия?"), isPresented: $showsResetConfirmation) {
            Button(String(localized: "Отменить"), role: .cancel) {}
            Button(String(localized: "Сбросить"), role: .destructive, action: resetBuiltIns)
        } message: {
            Text(
                String(
                    localized: "Все 6 встроенных действий будут восстановлены: изменённые поля, порядок и включённость "
                )
                    + String(localized: "вернутся к исходным, а удалённые действия будут созданы заново. ")
                    + String(localized: "Пользовательские действия и их порядок не изменятся.")
            )
        }
        .alert(String(localized: "Не удалось сохранить изменения"), isPresented: showsOperationError) {
            Button("OK", role: .cancel) {
                operationError = nil
            }
        } message: {
            Text(operationError ?? String(localized: "Неизвестная ошибка."))
        }
    }

    private var clipboardBehaviorSection: some View {
        Section(String(localized: "Действия с буфером")) {
            Toggle(
                String(localized: "Вставлять результат автоматически"),
                isOn: $settings.automaticallyPasteClipboardActionResults
            )

            LabeledContent(String(localized: "Быстрый пикер")) {
                HStack(spacing: 8) {
                    ShortcutRecorder(
                        shortcut: settings.clipboardActionShortcut,
                        onShortcut: updateShortcut
                    )
                    .frame(width: 150)

                    Button(String(localized: "Сбросить")) {
                        updateShortcut(.defaultClipboardActionShortcut)
                    }
                    .disabled(
                        settings.clipboardActionShortcut == .defaultClipboardActionShortcut
                    )
                }
            }

            Text(String(localized: "Нажмите поле и введите сочетание. По умолчанию — ⌘⇧Space."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = clipboardHotkeyService.registrationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if shouldShowAccessibilityWarning {
                accessibilityWarning
            }
        }
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(actions) { action in
                    ClipboardActionListRow(
                        action: action,
                        isSelected: selectedActionID == action.id && !isCreating,
                        isEnabled: Binding(
                            get: { action.isEnabled },
                            set: { enabled in
                                setEnabled(action, enabled: enabled)
                            }
                        ),
                        onSelect: { requestDestination(.action(action.id)) }
                    )
                }
                .onMove(perform: moveActions)
            }
            .overlay {
                if actions.isEmpty, !isCreating {
                    ContentUnavailableView(
                        String(localized: "Нет действий"),
                        systemImage: "clipboard",
                        description: Text(String(localized: "Создайте действие кнопкой +"))
                    )
                }
            }

            Divider()
            HStack(spacing: 4) {
                Button {
                    requestDestination(.newAction)
                } label: {
                    Image(systemName: "plus")
                }
                .help(String(localized: "Создать действие"))

                Button {
                    prepareDeletion()
                } label: {
                    Image(systemName: "minus")
                }
                .help(String(localized: "Удалить выбранное действие"))
                .disabled(selectedAction == nil || isCreating)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
    }

    @ViewBuilder
    private var editor: some View {
        if let draftBinding {
            ClipboardActionEditorView(
                draft: draftBinding,
                validationError: validationError,
                isCreating: isCreating,
                onSave: saveDraft,
                onCancel: cancelEditing
            )
            .padding(.leading, 12)
        } else {
            ContentUnavailableView(
                String(localized: "Выберите действие"),
                systemImage: "slider.horizontal.3",
                description: Text(String(localized: "Выберите действие слева или создайте новое"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                String(localized: "Для авто-вставки нужен доступ к Универсальному доступу."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            HStack {
                Button(String(localized: "Запросить доступ")) {
                    accessibilityPermissionService.requestAccess()
                    refreshAccessibilityStatus()
                }
                Button(String(localized: "Открыть настройки системы")) {
                    accessibilityPermissionService.openSystemSettings()
                }
            }
        }
    }
}

private extension ClipboardActionsSettingsView {
    private var selectedAction: ClipboardAction? {
        guard let selectedActionID else {
            return nil
        }
        return actions.first { $0.id == selectedActionID }
    }

    private var draftBinding: Binding<ClipboardActionDraft>? {
        guard draft != nil else {
            return nil
        }
        return Binding(
            get: { draft ?? .empty },
            set: { draft = $0 }
        )
    }

    private var hasUnsavedChanges: Bool {
        draft != savedDraft
    }

    private var validationError: ClipboardActionStoreError? {
        guard let draft else {
            return nil
        }
        return store.validationError(
            name: draft.name,
            promptTemplate: draft.promptTemplate,
            iconSystemName: draft.iconSystemName,
            excluding: isCreating ? nil : selectedActionID
        )
    }

    private var store: ClipboardActionStore {
        ClipboardActionStore(context: modelContext)
    }

    private var shouldShowAccessibilityWarning: Bool {
        settings.automaticallyPasteClipboardActionResults && !isAccessibilityTrusted
    }

    private var showsOperationError: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { isPresented in
                if !isPresented {
                    operationError = nil
                }
            }
        )
    }

    private var deleteConfirmationMessage: String {
        guard let actionPendingDeletion else {
            return String(localized: "Действие будет удалено.")
        }
        if actionPendingDeletion.isBuiltIn {
            return String(localized: "Встроенное действие «\(actionPendingDeletion.name)» будет удалено. ")
                + String(localized: "Его можно вернуть кнопкой «Сбросить встроенные действия».")
        }
        return String(localized: "Действие «\(actionPendingDeletion.name)» будет удалено без возможности отмены.")
    }

    private func requestDestination(_ destination: EditorDestination) {
        if hasUnsavedChanges {
            pendingDestination = destination
            showsDiscardConfirmation = true
        } else {
            apply(destination)
        }
    }

    private func applyPendingDestination() {
        guard let pendingDestination else {
            return
        }
        self.pendingDestination = nil
        apply(pendingDestination)
    }

    private func apply(_ destination: EditorDestination) {
        switch destination {
        case let .action(actionID):
            guard let action = actions.first(where: { $0.id == actionID }) else {
                clearEditor()
                return
            }
            load(action)
        case .newAction:
            selectionBeforeCreating = selectedActionID
            selectedActionID = nil
            isCreating = true
            let newDraft = ClipboardActionDraft.empty
            draft = newDraft
            savedDraft = nil
        }
    }

    private func load(_ action: ClipboardAction) {
        let actionDraft = ClipboardActionDraft(action: action)
        selectedActionID = action.id
        draft = actionDraft
        savedDraft = actionDraft
        isCreating = false
        selectionBeforeCreating = nil
    }

    private func ensureSelection() {
        if isCreating {
            return
        }
        if let selectedActionID, let action = actions.first(where: { $0.id == selectedActionID }) {
            if !hasUnsavedChanges {
                load(action)
            }
            return
        }
        if let first = actions.first {
            load(first)
        } else {
            clearEditor()
        }
    }

    private func clearEditor() {
        selectedActionID = nil
        draft = nil
        savedDraft = nil
        isCreating = false
        selectionBeforeCreating = nil
    }

    private func saveDraft() {
        guard let draft else {
            return
        }
        do {
            if isCreating {
                let action = try store.create(
                    name: draft.name,
                    promptTemplate: draft.promptTemplate,
                    iconSystemName: draft.iconSystemName
                )
                load(action)
            } else if let selectedAction {
                try store.update(
                    selectedAction,
                    name: draft.name,
                    promptTemplate: draft.promptTemplate,
                    iconSystemName: draft.iconSystemName
                )
                load(selectedAction)
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func cancelEditing() {
        if isCreating {
            let previousAction = selectionBeforeCreating.flatMap { previousID in
                actions.first(where: { $0.id == previousID })
            }
            if let action = previousAction {
                load(action)
            } else if let first = actions.first {
                load(first)
            } else {
                clearEditor()
            }
        } else if let selectedAction {
            load(selectedAction)
        }
    }

    private func prepareDeletion() {
        guard let selectedAction else {
            return
        }
        actionPendingDeletion = selectedAction
        showsDeleteConfirmation = true
    }

    private func deletePendingAction() {
        guard let actionPendingDeletion else {
            return
        }
        do {
            try store.delete(actionPendingDeletion)
            self.actionPendingDeletion = nil
            clearEditor()
            ensureSelection()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func resetBuiltIns() {
        do {
            try store.resetBuiltInsToDefaults()
            if let selectedActionID, let action = actions.first(where: { $0.id == selectedActionID }) {
                load(action)
            } else {
                clearEditor()
                ensureSelection()
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func setEnabled(_ action: ClipboardAction, enabled: Bool) {
        do {
            try store.setEnabled(action, enabled: enabled)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func moveActions(fromOffsets: IndexSet, toOffset: Int) {
        guard let sourceIndex = fromOffsets.first else {
            return
        }
        let destinationIndex = toOffset > sourceIndex ? toOffset - 1 : toOffset
        do {
            try store.move(from: sourceIndex, to: destinationIndex)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func refreshAccessibilityStatus() {
        isAccessibilityTrusted = accessibilityPermissionService.isTrusted
    }

    private func updateShortcut(_ shortcut: GlobalShortcut) {
        if clipboardHotkeyService.update(
            to: shortcut,
            conflictingWith: settings.shortcut
        ) {
            settings.clipboardActionShortcut = shortcut
        }
    }
}

enum EditorDestination {
    case action(UUID)
    case newAction
}
