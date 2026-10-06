import AppKit
import Observation
import SwiftData
import SwiftUI

@MainActor
final class PetController: NSObject {
    private let settings: AppSettings
    private let viewModel: ChatViewModel
    private let sceneActions: SceneActions
    private let defaults: UserDefaults
    private let panel: PetPanel
    let bubble = PetBubblePanel(
        contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false
    )
    private let bubbleModel: PetBubbleModel
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    var isVisible: Bool {
        settings.petEnabled && panel.isVisible
    }

    let runtime = PetRuntime()
    private var machine = PetStateMachine()
    private var dragging = false
    private var sleepTimer: Timer?

    init(
        settings: AppSettings,
        viewModel: ChatViewModel,
        sceneActions: SceneActions,
        defaults: UserDefaults = .standard
    ) {
        bubbleModel = PetBubbleModel(viewModel: viewModel, settings: settings)
        self.settings = settings
        self.viewModel = viewModel
        self.sceneActions = sceneActions
        self.defaults = defaults
        panel = PetPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        viewModel.togglePet = { settings.petEnabled.toggle() }
        configurePanel()
        configureBubble()
        let sprite = loadBuiltin()
        panel.contentView = PetHostingView(rootView: PetView(runtime: runtime, sprite: sprite))
        panel.onDrag = { [weak self] value in self?.dragging = value; self?.updateState() }
        panel.onClick = { [weak self] in self?.toggleBubble() }
        panel.onPosition = { [weak self] in self?.savePosition($0) }
        settings.resetPetPosition = { [weak self] in self?.resetPosition() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        motionChanged()
        observe()
    }

    private func configurePanel() {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
    }

    private func loadBuiltin() -> PetSprite? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Pets/bronya"),
              FileManager.default.fileExists(atPath: root.path) else { return nil }
        do {
            return try PetLoader.load(directory: root)
        } catch {
            NSLog("Builtin pet rejected: %@", error.localizedDescription)
            return nil
        }
    }

    private func observe() {
        withObservationTracking {
            _ = settings.petEnabled
            _ = settings.petScale
            _ = settings.petHideContent
            _ = viewModel.registry.aggregate
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        syncPanel()
        updateState()
    }

    private func syncPanel() {
        let size = CGSize(width: 64 * settings.petScale, height: 64 * settings.petScale)
        let wasVisible = panel.isVisible
        runtime.scale = settings.petScale
        runtime.hideContent = settings.petHideContent
        panel.setContentSize(size)
        if settings.petEnabled {
            if !wasVisible {
                let saved = (defaults.object(forKey: "pet.x") != nil && defaults.object(forKey: "pet.y") != nil)
                    ? CGPoint(x: defaults.double(forKey: "pet.x"), y: defaults.double(forKey: "pet.y")) : nil
                restorePosition(saved)
            } else {
                restorePosition(panel.frame.origin)
            }
            panel.orderFrontRegardless()
        } else {
            closeBubble()
            panel.orderOut(nil)
        }
        visibilityChanged()
    }

    private func updateState() {
        runtime.state = machine.update(kind: viewModel.registry.aggregate.kind, dragging: dragging)
        sleepTimer?.invalidate()
        sleepTimer = nil
        if let delay = machine.sleepDelay, delay > 0 {
            sleepTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.updateState() }
            }
        }
    }

    private func configureBubble() {
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.level = .floating
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bubble.hidesOnDeactivate = false
        bubble.isReleasedWhenClosed = false
        bubble.onDismiss = { [weak self] in self?.closeBubble() }
        bubbleModel.onOpen = { [weak self] id in self?.openConversation(id) }
        bubbleModel.onSent = { [weak self] in self?.bubble.finishInput() }
        bubbleModel.onResize = { [weak self] in self?.positionBubble() }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(anchorMoved), name: name, object: panel
            )
        }
    }

    func toggleBubble() {
        if bubble.isVisible {
            closeBubble(); return
        }
        guard isVisible else { return }
        bubble.contentView = NSHostingView(rootView: PetBubbleView(model: bubbleModel))
        bubbleModel.start()
        positionBubble()
        bubble.orderFrontRegardless()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.outsideClick() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if let self, event.window !== self.bubble, event.window !== self.panel {
                self.closeBubble()
            }
            return event
        }
    }

    func closeBubble() {
        bubble.finishInput()
        bubble.orderOut(nil)
        bubbleModel.stop()
        bubble.contentView = nil
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func outsideClick() {
        let point = NSEvent.mouseLocation
        if !bubble.frame.contains(point), !panel.frame.contains(point) {
            closeBubble()
        }
    }

    private func positionBubble() {
        guard let screen = panel.screen ?? NSScreen.screens.first else { return }
        bubbleModel.maxListHeight = max(60, screen.visibleFrame.height - 160)
        let height = max(170, bubble.contentView?.fittingSize.height ?? 170)
        bubble.setFrame(PetBubblePosition.frame(
            pet: panel.frame, size: CGSize(width: 280, height: height), screen: screen.visibleFrame
        ), display: true)
    }

    private func openConversation(_ id: UUID?) {
        if let id, let conversation = try? viewModel.modelContext.fetch(
            FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        ).first {
            viewModel.selectConversation(conversation)
        }
        sceneActions.openMainWindow()
        closeBubble()
    }

    private func restorePosition(_ saved: CGPoint?) {
        guard let main = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrameOrigin(PetPosition.restored(
            saved,
            size: panel.frame.size,
            screens: NSScreen.screens.map(\.visibleFrame),
            main: main.visibleFrame
        ))
    }

    private func savePosition(_ point: CGPoint) {
        if bubble.isVisible {
            positionBubble()
        }
        defaults.set(point.x, forKey: "pet.x")
        defaults.set(point.y, forKey: "pet.y")
    }

    private func resetPosition() {
        restorePosition(nil)
        savePosition(panel.frame.origin)
    }

    @objc private func anchorMoved() {
        if bubble.isVisible {
            positionBubble()
        }
    }

    @objc private func screensChanged() {
        restorePosition(panel.frame.origin)
        if bubble.isVisible {
            positionBubble()
        }
    }

    @objc private func visibilityChanged() {
        if !panel.isVisible {
            closeBubble()
        }
        runtime.paused = !panel.isVisible || !panel.occlusionState.contains(.visible)
    }

    @objc private func motionChanged() {
        runtime.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
