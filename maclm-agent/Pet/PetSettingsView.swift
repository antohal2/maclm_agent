import SwiftUI

struct PetSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Toggle(String(localized: "Включить питомца"), isOn: $settings.petEnabled)
            Picker(String(localized: "Размер питомца"), selection: $settings.petScale) {
                ForEach(1 ... 3, id: \.self) { scale in Text(verbatim: "×\(scale)").tag(scale) }
            }.pickerStyle(.segmented)
            Button(String(localized: "Вернуть в угол экрана")) { settings.resetPetPosition?() }
        }
        .formStyle(.grouped)
        .padding()
    }
}
