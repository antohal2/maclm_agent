import AppKit
@preconcurrency import ApplicationServices

@MainActor
protocol AccessibilityPermissionService: AnyObject {
    var isTrusted: Bool { get }
    func requestAccess()
    func openSystemSettings()
}

@MainActor
final class SystemAccessibilityPermissionService: AccessibilityPermissionService {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
