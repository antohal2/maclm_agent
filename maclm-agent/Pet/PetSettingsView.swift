import AppKit
import SwiftUI

struct PetSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var library: PetLibrary
    @State private var pendingImport: PetImport?
    @State private var pendingDelete: String?

    var body: some View {
        Form {
            Section(String(localized: "Выбор питомца")) {
                petRow(id: "bronya", name: String(localized: "Встроенный питомец"), sprite: nil, problem: nil)
                ForEach(library.entries) { entry in
                    petRow(id: entry.id, name: entry.name, sprite: entry.sprite, problem: entry.problem)
                }
                HStack {
                    Button(String(localized: "Добавить питомца…")) { chooseFolder() }
                    Button(String(localized: "Обновить список")) { library.refresh() }
                }
            }

            Toggle(String(localized: "Включить питомца"), isOn: $settings.petEnabled)
            Toggle(String(localized: "Скрывать содержимое"), isOn: $settings.petHideContent)
            Toggle(
                String(localized: "Не дублировать уведомления о завершении, пока питомец на экране"),
                isOn: $settings.petSuppressCompletion
            )
            Picker(String(localized: "Размер питомца"), selection: $settings.petScale) {
                ForEach(1 ... 3, id: \.self) { scale in Text(verbatim: "×\(scale)").tag(scale) }
            }.pickerStyle(.segmented)
            Button(String(localized: "Вернуть в угол экрана")) { settings.resetPetPosition?() }
        }
        .formStyle(.grouped)
        .padding()
        .alert(String(localized: "Ошибка питомца"), isPresented: Binding(
            get: { library.errorMessage != nil }, set: {
                if !$0 {
                    library.errorMessage = nil
                }
            }
        )) {
            Button(String(localized: "OK")) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .confirmationDialog(String(localized: "Заменить питомца?"), isPresented: Binding(
            get: { pendingImport != nil }, set: {
                if !$0 {
                    pendingImport = nil
                }
            }
        )) {
            Button(String(localized: "Заменить"), role: .destructive) {
                if let pendingImport {
                    library.install(pendingImport, replacing: true)
                }
                pendingImport = nil
            }
        }
        .confirmationDialog(String(localized: "Удалить питомца?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            }
        )) {
            Button(String(localized: "Удалить"), role: .destructive) {
                if let pendingDelete {
                    library.delete(pendingDelete)
                }
                pendingDelete = nil
            }
        }
    }

    private func petRow(id: String, name: String, sprite: PetSprite?, problem: String?) -> some View {
        HStack {
            if let frame = sprite?.frames[.idle]?.first {
                Image(decorative: frame, scale: 1).resizable().interpolation(.none).frame(width: 40, height: 40)
            } else {
                PetPlaceholder(state: .idle, elapsed: 0).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading) {
                Text(verbatim: name)
                Text(verbatim: id).font(.caption).foregroundStyle(.secondary)
                if let problem {
                    Text(String(localized: "Неисправный питомец")).foregroundStyle(.red)
                    Text(problem).font(.caption)
                }
            }
            Spacer()
            Button {
                if settings.petSelectedID != id {
                    library.select(id)
                }
            } label: {
                Image(systemName: settings.petSelectedID == id ? "checkmark.circle.fill" : "circle")
            }
            .accessibilityLabel(String(localized: "Выбрать питомца"))
            .disabled(problem != nil)
            if id != "bronya" {
                Button(String(localized: "Удалить"), role: .destructive) { pendingDelete = id }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let imported = try library.store.prepare(source: source)
            if try library.store.existingID(for: imported.sprite.manifest.id) != nil {
                pendingImport = imported
            } else {
                library.install(imported, replacing: false)
            }
        } catch { library.errorMessage = PetStorageError.message(error) }
    }
}
