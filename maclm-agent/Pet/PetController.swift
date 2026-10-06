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
        let sprite = loadBuiltin()
        panel.contentView = PetHostingView(rootView: PetView(runtime: runtime, sprite: sprite))
        panel.onDrag = { [weak self] value in self?.dragging = value; self?.updateState() }
        panel.onClick = { [weak self] in self?.openConversation() }
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

    private func openConversation() {
        if let id = PetState.conversationID(for: viewModel.registry.aggregate),
           let conversation = try? viewModel.modelContext.fetch(
               FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
           ).first
        {
            viewModel.selectConversation(conversation)
        }
        sceneActions.openMainWindow()
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
        defaults.set(point.x, forKey: "pet.x")
        defaults.set(point.y, forKey: "pet.y")
    }

    private func resetPosition() {
        restorePosition(nil)
        savePosition(panel.frame.origin)
    }

    @objc private func screensChanged() {
        restorePosition(panel.frame.origin)
    }

    @objc private func visibilityChanged() {
        runtime.paused = !panel.isVisible || !panel.occlusionState.contains(.visible)
    }

    @objc private func motionChanged() {
        runtime.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
