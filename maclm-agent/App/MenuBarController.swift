import AppKit
import SwiftData
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let clipboardActionRunner: ClipboardActionRunner

    init(
        viewModel: ChatViewModel,
        clipboardActionRunner: ClipboardActionRunner,
        modelContainer: ModelContainer,
        settings: AppSettings,
        hotKeyController: GlobalHotKeyController,
        sceneActions: SceneActions,
        accessibilityPermissionService: any AccessibilityPermissionService
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        self.clipboardActionRunner = clipboardActionRunner
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "brain",
                accessibilityDescription: "maclm-agent"
            )
            button.target = self
            button.action = #selector(togglePopover)
        }

        let content = MenuBarPanelRootView(
            viewModel: viewModel,
            clipboardActionRunner: clipboardActionRunner,
            settings: settings,
            sceneActions: sceneActions,
            accessibilityPermissionService: accessibilityPermissionService
        )
        .modelContainer(modelContainer)
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.behavior = .transient
        popover.delegate = self

        hotKeyController.action = { [weak self] in
            self?.togglePopover()
        }
        hotKeyController.start(with: settings.shortcut)
    }

    @objc
    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            return
        }
        clipboardActionRunner.captureTargetApplication()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
    }
}

private struct MenuBarPanelRootView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var clipboardActionRunner: ClipboardActionRunner
    @Bindable var settings: AppSettings
    let sceneActions: SceneActions
    let accessibilityPermissionService: any AccessibilityPermissionService

    var body: some View {
        MenuBarContentView(
            viewModel: viewModel,
            clipboardActionRunner: clipboardActionRunner,
            sceneActions: sceneActions,
            accessibilityPermissionService: accessibilityPermissionService
        )
        .preferredColorScheme(settings.theme.colorScheme)
    }
}
