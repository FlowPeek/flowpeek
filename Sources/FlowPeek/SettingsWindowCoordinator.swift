import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowCoordinator()
    private var window: NSWindow?
    /// Kept so a window that is already open can be sent to a different pane. Typed as `AnyView`
    /// because the alternative is spelling out the modifier chain SwiftUI infers for the root view.
    private var controller: NSHostingController<AnyView>?

    /// `section` is what the caller wants looked at: the menu bar's shortcut row asks for the
    /// Shortcuts pane and has to get it on an already-open window too. `nil` is the plain "open
    /// Settings" of the menu and the command router, which has no pane in mind and must not drag a
    /// window the user is reading back to General.
    func show(section: SettingsView.SettingsSection? = nil) {
        if let window {
            // Only for a caller that named one. Re-rooting is not by itself enough to move the
            // pane — `SettingsView` seeds its selection into `@State`, and SwiftUI keeps the state
            // it already has for a root view of the same identity, so the seed is discarded — which
            // is why `rootView` tags the view with the section it was built for.
            if let section { controller?.rootView = rootView(section: section) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let controller = NSHostingController(rootView: rootView(section: section ?? .general))
        self.controller = controller
        let window = SettingsWindow(contentViewController: controller)
        window.title = String(localized: "settings.window.title")
        window.styleMask = [.borderless, .closable, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        // The content draws its own shadow inside `.padding`, so AppKit must not draw a second one:
        // its shadow traces the whole window rect, which extends well beyond the visible card and
        // reads as a rounded halo floating outside it.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(NSSize(width: 820, height: 580))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        AppState.shared.refreshPermission()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func rootView(section: SettingsView.SettingsSection) -> AnyView {
        AnyView(
            SettingsView(section: section, close: { [weak self] in self?.closeWindow() })
                .environmentObject(AppState.shared)
                // The identity that makes a re-root count as a different view, so the pane the
                // caller asked for is the one that appears.
                .id(section)
        )
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window with a field still recording would leave every global shortcut
        // suspended for the rest of the session. Idempotent, so it is safe next to `onDisappear`,
        // which SwiftUI is not guaranteed to run before the window goes away.
        AppState.shared.shortcuts.endRecording()
        window = nil
        controller = nil
    }

    private func closeWindow() {
        AppState.shared.shortcuts.endRecording()
        window?.close()
        window = nil
        controller = nil
    }
}

private final class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Escape means the same thing on every FlowPeek surface. `windowWillClose` already clears the
    /// coordinator's reference, so this needs no route through it. A shortcut recorder mid-capture
    /// swallows the key in its own `keyDown`, so this never fires while one is listening.
    override func cancelOperation(_ sender: Any?) { close() }
}
