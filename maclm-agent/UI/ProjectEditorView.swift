import AppKit
import SwiftData
import SwiftUI

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    let skillStore: SkillStore?
    let onSave: (Project) -> Void
    var onDirectoryChange: ((Project) -> Void)?
    @State private var name: String
    @State private var path: String
    @State private var instructions: String
    @State private var error: String?
    @State private var pendingPath: String?

    init(
        project: Project?, skillStore: SkillStore? = nil,
        onDirectoryChange: ((Project) -> Void)? = nil, onSave: @escaping (Project) -> Void
    ) {
        self.project = project
        self.skillStore = skillStore
        self.onDirectoryChange = onDirectoryChange
        self.onSave = onSave
        _name = State(initialValue: project?.name ?? "")
        _path = State(initialValue: project?.workingDirectoryPath ?? "")
        _instructions = State(initialValue: project?.instructions ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? String(localized: "Новый проект") : String(localized: "Настройки проекта"))
                .font(.headline)
            TextField(String(localized: "Название"), text: $name)
            HStack {
                TextField(String(localized: "Рабочая папка (необязательно)"), text: $path)
                Button(String(localized: "Выбрать папку…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK {
                        path = panel.url?.path ?? ""
                    }
                }
            }
            Text(String(localized: "Инструкции проекта"))
            TextEditor(text: $instructions).frame(height: 160).border(.quaternary)
                .onChange(of: instructions) { instructions = String(instructions.prefix(4000)) }
            Text("\(instructions.count) / 4000").font(.caption).foregroundStyle(.secondary)
            if let project, let skillStore {
                ProjectSkillsList(project: project, store: skillStore)
            }
            if let error {
                Text(NSLocalizedString(error, comment: "")).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(String(localized: "Отмена")) { dismiss() }
                Button(String(localized: "Сохранить"), action: validateAndSave)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .alert(String(localized: "Подтвердите рабочую папку"), isPresented: Binding(
            get: { pendingPath != nil }, set: {
                if !$0 {
                    pendingPath = nil
                }
            }
        )) {
            Button(String(localized: "Отмена"), role: .cancel) { pendingPath = nil }
            Button(String(localized: "Использовать папку")) {
                if let pendingPath {
                    save(path: pendingPath)
                }
            }
        } message: {
            Text(String(localized: "Вы выбрали домашнюю или системную папку целиком. Подтвердите выбор."))
        }
    }

    private func validateAndSave() {
        error = nil
        guard !path.isEmpty else { save(path: nil); return }
        switch WorkingDirectoryValidator.validate(path) {
        case let .valid(canonical): save(path: canonical)
        case let .requiresConfirmation(canonical): pendingPath = canonical
        case let .invalid(message): error = message
        }
    }

    private func save(path: String?) {
        let result = project ?? Project(name: name)
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.workingDirectoryPath != path {
            onDirectoryChange?(result)
        }
        result.workingDirectoryPath = path
        result.instructions = String(instructions.prefix(4000))
        onSave(result)
        dismiss()
    }
}

struct ProjectSkillsList: View {
    @Bindable var project: Project
    let store: SkillStore
    @Environment(\.modelContext) private var context
    @State private var error: String?
    var body: some View {
        GroupBox(String(localized: "Навыки")) {
            VStack(alignment: .leading) {
                if project.pinnedSkills.isEmpty {
                    Text(String(localized: "Нет закреплённых навыков"))
                }
                ForEach(project.pinnedSkills) { pin in
                    HStack {
                        Text(verbatim: pin.id)
                        Text(verbatim: String(pin.hash.prefix(12))).font(.caption.monospaced())
                        Spacer()
                        Button(String(localized: "Открепить")) {
                            Task {
                                do {
                                    try SkillProjectActions.unpin(pin.id, project: project, context: context)
                                    try await store.cleanupSnapshots()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
