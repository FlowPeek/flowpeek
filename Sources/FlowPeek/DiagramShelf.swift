import AppKit
import FlowPeekCore
import SwiftUI

/// The way back to a diagram: a shelf that rises from the bottom of the screen, showing the
/// diagrams themselves.
///
/// A shelf rather than a window, and pictures rather than rows of text, because what a person is
/// looking for here is a shape they recognise. The list used to name each diagram in words --
/// "Order -> Pay -> Ship" -- which is a good name and still a worse way to find a diagram than
/// seeing it. Every other surface in FlowPeek is a borderless glass panel that comes and goes; the
/// history was the one window, and being a window is what made it feel like somewhere you go
/// instead of something you glance at.
@MainActor
final class DiagramHistoryCoordinator: NSObject, NSWindowDelegate {
    static let shared = DiagramHistoryCoordinator()

    private var panel: FlowPeekGlassPanel?
    private var dismissMonitor: Any?

    /// Tall enough for a card that can be recognised, short enough to leave the screen behind it
    /// readable: this is a glance, not a workspace.
    private static let height: CGFloat = 244
    /// Never the full width of a large display, where the cards would strand themselves at one end.
    private static let maximumWidth: CGFloat = 1180
    private static let sideMargin: CGFloat = 32
    private static let bottomMargin: CGFloat = 26

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // Time has passed since the last recording, and this is the moment the list is about to be
        // believed.
        DiagramHistoryStore.shared.pruneExpired()
        guard let screen = Self.screenUnderPointer() else { return }
        let frame = Self.frame(in: screen)

        let panel = FlowPeekGlassPanel(
            contentRect: frame,
            // Deliberately not `.nonactivatingPanel`, which the quick preview is: that one appears
            // beside what you are reading and must not take the keyboard away from it. This one is
            // asked for, and it has a search field -- a field that cannot be typed into is not a
            // search field. Measured: with the nonactivating mask, keystrokes went to whatever was
            // in front instead.
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // Follows the user rather than the desktop it was opened on, and stays out of the window
        // list: it is a glance at a shelf, not a document.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: DiagramShelfView(
                store: DiagramHistoryStore.shared,
                open: { [weak self] document in
                    self?.close()
                    AppState.shared.previews.openWindow(document: document)
                },
                close: { [weak self] in self?.close() }
            )
        )
        self.panel = panel

        // Rises from under the edge. The one bit of motion in the app that is not a fade: a shelf
        // that appears where it will be says nothing about where it came from, and the whole idea
        // of this surface is that it lives just off the bottom of the screen.
        panel.setFrame(frame.offsetBy(dx: 0, dy: -(frame.height + Self.bottomMargin)), display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        installDismissMonitor()
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        removeDismissMonitor()
        panel.delegate = nil
        let away = panel.frame.offsetBy(dx: 0, dy: -(panel.frame.height + Self.bottomMargin))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(away, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            // AppKit runs this on the main thread; saying so is what lets the panel be touched from
            // a closure the compiler sees as nonisolated.
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        removeDismissMonitor()
    }

    /// A click anywhere else puts the shelf away, the way it does for the menu-bar panel and the
    /// quick preview. Global, because the click that dismisses it is by definition not ours.
    private func installDismissMonitor() {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeDismissMonitor() {
        guard let dismissMonitor else { return }
        NSEvent.removeMonitor(dismissMonitor)
        self.dismissMonitor = nil
    }

    /// The screen the user is looking at, which is the one the pointer is on -- not the one with
    /// the menu bar, and not the one the app happens to have a window on.
    private static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    private static func frame(in screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(visible.width - sideMargin * 2, maximumWidth)
        return CGRect(
            x: visible.midX - width / 2,
            y: visible.minY + bottomMargin,
            width: width,
            height: height
        )
    }
}
