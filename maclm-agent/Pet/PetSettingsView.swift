import SwiftUI

struct PetSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
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
    }
}
