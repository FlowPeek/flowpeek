import AppKit
import FlowPeekCore
import OSLog

/// Watches for Option pressed twice, quickly, and nothing else.
///
/// Deliberately not a registered hot key. A hot key is taken from every other application for as
/// long as it is held, which is why hold to peek is a switch the user has to turn on; this takes
/// nothing away from anybody, because Option on its own does nothing in the first place. It only
/// watches.
///
/// The deciding is all in `ModifierDoubleTap`. What lives here is the part that cannot be tested
/// without a Mac: which events to listen to, and the fact that a global monitor is blind to events
/// delivered to FlowPeek itself.
@MainActor
final class DoubleTapMonitor {
    /// Called on the main actor when the gesture completes.
    var onDoubleTap: (() -> Void)?

    private var recogniser = ModifierDoubleTap()
    private var monitors: [Any] = []
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "DoubleTap")

    /// Everything that is not the modifier itself. Any of these between a press and a release, or
    /// between two taps, means the user is doing something rather than gesturing.
    private static let interrupting: NSEvent.EventTypeMask = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    var interval: TimeInterval { recogniser.interval }

    func setInterval(_ value: TimeInterval) {
        recogniser.setInterval(value)
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        recogniser.forget()
        add(NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.flagsChanged(event) }
        })
        // The global monitor never sees what is delivered to FlowPeek, and once a preview is open
        // that is where the keys go. Without this, the gesture stops working the moment it has
        // worked once.
        add(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.flagsChanged(event) }
            return event
        })
        add(NSEvent.addGlobalMonitorForEvents(matching: Self.interrupting) { [weak self] _ in
            Task { @MainActor in self?.recogniser.interrupt() }
        })
        add(NSEvent.addLocalMonitorForEvents(matching: Self.interrupting) { [weak self] event in
            Task { @MainActor in self?.recogniser.interrupt() }
            return event
        })
        logger.info("double tap armed at \(Int(self.recogniser.interval * 1000), privacy: .public)ms")
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        recogniser.forget()
        logger.info("double tap disarmed")
    }

    private func add(_ monitor: Any?) {
        guard let monitor else { return }
        monitors.append(monitor)
    }

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let others = flags.intersection([.command, .shift, .control, .function])
        if flags.contains(.option) {
            recogniser.press(alone: others.isEmpty, at: event.timestamp)
        } else if recogniser.release(at: event.timestamp) {
            logger.info("double tap")
            onDoubleTap?()
        }
    }
}
