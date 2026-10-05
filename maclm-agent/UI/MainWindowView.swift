import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @Bindable var viewModel: ChatViewModel
    let sceneActions: SceneActions
    let sessionNotifications: SessionNotifications

    @AppStorage("workspace.inspectorPresented") private var inspectorPresented = false

    var body: some View {
        NavigationSplitView {
            ConversationListView(viewModel: viewModel)
        } detail: {
            ChatView(viewModel: viewModel)
        }
        .inspector(isPresented: $inspectorPresented) { WorkspaceInspectorView(viewModel: viewModel) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { inspectorPresented.toggle() } label: {
                    Label(String(localized: "Инспектор"), systemImage: "sidebar.right")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(MainWindowObserver(notifications: sessionNotifications))
        .onAppear {
            sceneActions.openMainWindowAction = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            sceneActions.openSettingsAction = {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private struct MainWindowObserver: NSViewRepresentable {
    let notifications: SessionNotifications
    func makeNSView(context _: Context) -> ObserverView {
        ObserverView(notifications: notifications)
    }

    func updateNSView(_: ObserverView, context _: Context) {}

    @MainActor final class ObserverView: NSView {
        let notifications: SessionNotifications
        init(notifications: SessionNotifications) {
            self.notifications = notifications
            super.init(frame: .zero)
        }

        required init?(coder _: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Rebind when SwiftUI moves the view to a different window.
            // swiftlint:disable:next notification_center_detachment
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didResignKeyNotification,
                    NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification,
                    NSWindow.willCloseNotification,
                ] {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(changed(_:)),
                        name: name,
                        object: window
                    )
                }
            }
            updateVisibility()
        }

        @objc func changed(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification {
                notifications.mainWindowIsVisible = false
                notifications.mainWindowIsKey = false
            } else {
                updateVisibility()
            }
        }

        func updateVisibility() {
            notifications.mainWindowIsVisible = window?.isVisible == true && window?.isMiniaturized == false
            notifications.mainWindowIsKey = window?.isKeyWindow == true
        }
    }
}
