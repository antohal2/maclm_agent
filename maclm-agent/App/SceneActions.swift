import Foundation

@MainActor
final class SceneActions {
    var openMainWindowAction: (() -> Void)?
    var openSettingsAction: (() -> Void)?

    func openMainWindow() {
        openMainWindowAction?()
    }

    func openSettings() {
        UserDefaults.standard.set("models", forKey: "settings.selectedTab")
        openSettingsAction?()
    }
}
