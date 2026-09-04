import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowCoordinator()
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let controller = NSHostingController(
            rootView: SettingsView(close: { [weak self] in self?.closeWindow() })
                .environmentObject(AppState.shared)
        )
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

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }
}

private final class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
