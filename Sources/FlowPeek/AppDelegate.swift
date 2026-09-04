import AppKit
import FlowPeekCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Before the menu bar item exists, because the whole point is that a second one never appears.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isHostingTests else { return }
        standAsideForRunningInstance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The renderer test bundle is hosted by this app; starting the monitors, the hot key and
        // the onboarding window inside a test run would make the suite non-deterministic.
        guard !isHostingTests else { return }
        AppState.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }

    private var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `SingleInstanceGuard`'s answer, applied. Thin on purpose: everything that decides lives in
    /// FlowPeekCore, and this only knows how to ask AppKit who is running and how to leave.
    private func standAsideForRunningInstance() {
        let current = NSRunningApplication.current
        let decision = SingleInstanceGuard.decide(
            own: SingleInstanceGuard.Instance(current),
            running: NSWorkspace.shared.runningApplications.map(SingleInstanceGuard.Instance.init),
            isReplacingAnInstance: ProcessInfo.processInfo.arguments
                .contains(SingleInstanceGuard.replacementArgument)
        )
        guard case .deferTo(let pid) = decision else { return }
        // Bringing the copy that stays forward is the whole of the feedback: a second launch that
        // simply vanished would read as FlowPeek failing to start.
        NSRunningApplication(processIdentifier: pid)?.activate()
        // Not `NSApp.terminate`: nothing has been started yet, so there is nothing to tear down, and
        // terminate would let launching finish first -- which is what puts the second icon in the
        // menu bar this exists to prevent.
        exit(0)
    }
}

extension SingleInstanceGuard.Instance {
    init(_ application: NSRunningApplication) {
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            launchDate: application.launchDate
        )
    }
}
