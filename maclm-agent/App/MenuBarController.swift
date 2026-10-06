import AppKit
import SwiftData
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let settings: AppSettings
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let clipboardActionRunner: ClipboardActionRunner
    private let hotKeyController: GlobalHotKeyController
    private let clipboardHotkeyService: ClipboardHotkeyService
    private let quickActionPickerController: QuickActionPickerController

    init(
        viewModel: ChatViewModel,
        clipboardActionRunner: ClipboardActionRunner,
        modelContainer: ModelContainer,
        settings: AppSettings,
        hotKeyController: GlobalHotKeyController,
        clipboardHotkeyService: ClipboardHotkeyService,
        sceneActions: SceneActions,
        accessibilityPermissionService: any AccessibilityPermissionService
    ) {
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        self.clipboardActionRunner = clipboardActionRunner
        self.hotKeyController = hotKeyController
        self.clipboardHotkeyService = clipboardHotkeyService
        quickActionPickerController = QuickActionPickerController(
            modelContainer: modelContainer,
            clipboardActionRunner: clipboardActionRunner
        )
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "brain",
                accessibilityDescription: "maclm-agent"
            )
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        clipboardHotkeyService.action = { [weak self] in
            self?.quickActionPickerController.toggle()
        }
        clipboardHotkeyService.start(with: settings.clipboardActionShortcut)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc
    private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            let menu = NSMenu()
            let title = settings.petEnabled
                ? String(localized: "Спрятать питомца") : String(localized: "Показать питомца")
            let item = NSMenuItem(title: title, action: #selector(togglePet), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else {
            togglePopover()
        }
    }

    @objc private func togglePet() {
        settings.petEnabled.toggle()
    }

    @objc
    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @objc
    private func applicationWillTerminate() {
        quickActionPickerController.close()
        hotKeyController.stop()
        clipboardHotkeyService.stop()
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
