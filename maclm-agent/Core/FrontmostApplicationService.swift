import AppKit

@MainActor
protocol FrontmostApplicationService: AnyObject {
    func captureTargetApplication()
    func activateTargetApplication() -> Bool
}

@MainActor
final class SystemFrontmostApplicationService: FrontmostApplicationService {
    private var targetApplication: NSRunningApplication?

    func captureTargetApplication() {
        targetApplication = nil

        guard
            let frontmostApplication = NSWorkspace.shared.frontmostApplication,
            frontmostApplication.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            return
        }
        targetApplication = frontmostApplication
    }

    func activateTargetApplication() -> Bool {
        guard let targetApplication, !targetApplication.isTerminated else {
            return false
        }
        return targetApplication.activate(options: [])
    }
}
