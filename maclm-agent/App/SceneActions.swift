import Foundation

@MainActor
final class SceneActions {
    var openMainWindowAction: (() -> Void)?
    var openSettingsAction: (() -> Void)?

    func openMainWindow() {
        openMainWindowAction?()
    }

    func openSettings() {
        openSettingsAction?()
    }
}
