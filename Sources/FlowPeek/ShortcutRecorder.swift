import AppKit
import FlowPeekCore
import SwiftUI

/// Click to record, then press a combination. While a field is recording every global hot key is
/// suspended, otherwise Carbon would swallow the very keys being recorded.
struct ShortcutRecorder: View {
    let action: FlowPeekShortcutAction
    @ObservedObject var center: ShortcutCenter

    @State private var pressedModifiers: FlowPeekShortcut.Modifiers = []
    @State private var error: String?
    @State private var isHovered = false

    private var isRecording: Bool { center.recordingAction == action }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(fieldText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isRecording ? Color.accentColor : .primary)
                        .frame(minWidth: 82)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(isRecording ? 0.12 : isHovered ? 0.09 : 0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isRecording ? Color.accentColor.opacity(0.75) : .white.opacity(0.14))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("shortcut.record.help")

                Button {
                    center.reset(action)
                    error = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(center.shortcuts[action] == action.defaultShortcut)
                .help("shortcut.reset.help")
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else if center.unavailableActions.contains(action) {
                // Not transient like `error`: the clash can appear long after the shortcut was
                // recorded, whenever the app that owns the combination is next installed or started.
                Text("shortcut.unavailable")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .overlay {
            if isRecording {
                KeyCaptureView(
                    onCapture: capture,
                    onModifiers: { pressedModifiers = $0 },
                    onCancel: cancelRecording
                )
                .frame(width: 0, height: 0)
            }
        }
        .onDisappear { cancelRecording() }
        // Key events only reach the first responder of the active app's key window, so a field left
        // recording while the user works elsewhere can never capture anything — and until it stops,
        // every FlowPeek shortcut stays suspended.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelRecording()
        }
        .onChange(of: center.recordingAction) { _, current in
            // Another field took the keyboard; drop this one's transient state.
            if current != action { pressedModifiers = [] }
        }
    }

    private var fieldText: String {
        guard isRecording else { return center.shortcuts[action].display }
        return pressedModifiers.isEmpty ? String(localized: "shortcut.recording") : pressedModifiers.display
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        error = nil
        pressedModifiers = []
        center.beginRecording(action)
    }

    private func stopRecording() {
        pressedModifiers = []
        center.endRecording()
    }

    /// Every "the field lost the keyboard" route lands here, and each has to check first: by the time
    /// one of them fires another field may already own the recording, and ending it would strand
    /// that one instead.
    private func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
    }

    /// Core names the failure; the app owns the catalogue, matching how `mermaid.error.*` is handled.
    private static func message(for error: FlowPeekShortcut.ValidationError) -> String {
        let format = Bundle.main.localizedString(forKey: error.localizationKey, value: nil, table: nil)
        guard let argument = error.localizationArgument else { return format }
        return String(format: format, argument)
    }

    private func capture(keyCode: UInt16, modifiers: FlowPeekShortcut.Modifiers) {
        if let failure = center.assign(keyCode: keyCode, modifiers: modifiers, to: action) {
            error = Self.message(for: failure)
            pressedModifiers = []
            return
        }
        error = nil
        stopRecording()
    }
}

/// An invisible first responder. `⌘`-combinations never reach `keyDown` — AppKit routes them through
/// `performKeyEquivalent(with:)` first — so both paths have to be handled.
private struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (UInt16, FlowPeekShortcut.Modifiers) -> Void
    let onModifiers: (FlowPeekShortcut.Modifiers) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        view.onModifiers = onModifiers
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onModifiers = onModifiers
        nsView.onCancel = onCancel
    }

    final class CaptureView: NSView {
        var onCapture: ((UInt16, FlowPeekShortcut.Modifiers) -> Void)?
        var onModifiers: ((FlowPeekShortcut.Modifiers) -> Void)?
        var onCancel: (() -> Void)?
        /// The cancel this view is waiting to hand over, kept so a second resignation replaces it
        /// instead of stacking another waiter beside it.
        private var pendingCancel: (() -> Void)?
        /// What the wait is listening to, and the floor under it.
        private var mouseUpMonitor: Any?
        private var cancelDeadline: Task<Void, Never>?

        override var acceptsFirstResponder: Bool { true }

        /// The stranded case Escape cannot reach: the user clicked somewhere else in the window
        /// without pressing anything, so nothing else would ever end the recording. The window check
        /// skips the same call arriving during teardown, when the recording is already over.
        override func resignFirstResponder() -> Bool {
            guard window != nil else { return true }
            // Deferred, because ending the recording tears down this very view and AppKit is still
            // inside `makeFirstResponder` here — but not merely to the next main-queue turn. The
            // click that takes the keyboard away can be the second click on the record field, which
            // is the documented way to stop; that button's action arrives on mouse-up, and a cancel
            // that drains in between ends the session the button is about to toggle, so the click
            // starts a fresh recording instead of stopping it. Waiting for the button to come back
            // up leaves the toggle to decide, and `cancelRecording()` is a no-op once it has.
            // One wait per field, replacing any still in flight: AppKit can resign the same view
            // more than once for a single click, and every extra waiter is another cancel already
            // decided.
            dropWait()
            pendingCancel = onCancel
            guard NSEvent.pressedMouseButtons != 0 else {
                // Nothing is held, so there is no mouse-up on its way to wait for: the keyboard, or
                // the pane going away, took the responder. Still a turn late, to get off the
                // `makeFirstResponder` this is standing inside.
                Task { @MainActor [weak self] in self?.handOverCancel() }
                return true
            }
            // Watched rather than polled. The wait used to re-read `NSEvent.pressedMouseButtons`
            // every 16 ms for up to a second — sixty main-actor wakeups to learn something the event
            // stream announces once, and up to a frame of shortcuts held down after the button was
            // already back up. A local monitor sees the mouse-up before the window does, and the
            // hop below still leaves the record field's own action to run first.
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
            ) { [weak self] event in
                Task { @MainActor in self?.handOverCancel() }
                return event
            }
            // The floor under it: a drag that ends over another application delivers its mouse-up
            // there, where a local monitor never sees it, and without this every FlowPeek shortcut
            // would stay suspended for the rest of the session. A second is well past any click.
            cancelDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.handOverCancel()
            }
            return true
        }

        /// The recording can also end by a route that has nothing to do with this wait — Escape, or
        /// the Settings window closing — and that takes this view out of its window. Whatever it was
        /// waiting for is moot, and a monitor nobody is left to remove would sit in the event stream
        /// for the rest of the session.
        override func viewDidMoveToWindow() {
            if window == nil { dropWait() }
        }

        /// Whichever of the two gets here first, exactly once.
        private func handOverCancel() {
            let cancel = pendingCancel
            dropWait()
            cancel?()
        }

        private func dropWait() {
            pendingCancel = nil
            cancelDeadline?.cancel()
            cancelDeadline = nil
            if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
            mouseUpMonitor = nil
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            handle(event)
        }

        override func flagsChanged(with event: NSEvent) {
            onModifiers?(FlowPeekShortcut.Modifiers(event.modifierFlags))
        }

        /// Escape on its own abandons the recording; Escape with a modifier is a legitimate shortcut.
        private func handle(_ event: NSEvent) {
            let modifiers = FlowPeekShortcut.Modifiers(event.modifierFlags)
            if event.keyCode == 53, modifiers.isEmpty {
                onCancel?()
                return
            }
            onCapture?(event.keyCode, modifiers)
        }
    }
}
