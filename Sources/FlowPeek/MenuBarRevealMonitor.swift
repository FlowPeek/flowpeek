import AppKit
import FlowPeekCore
import OSLog

/// Watches for Option held down on its own, so an app that has taken its own icon out of the menu
/// bar can be brought back.
///
/// Polled rather than monitored, and that is the whole design. `NSEvent.addGlobalMonitorForEvents`
/// does not see a keystroke unless the process is trusted for Accessibility, and this is the one
/// feature in FlowPeek that must work when it is not: the gesture is the way back to a hidden app,
/// so a version of it that stops working when a permission is withdrawn would lock a user out of
/// their own settings. `NSEvent.modifierFlags` is a plain snapshot of the keyboard, needs no
/// permission at all, and answers the same question.
///
/// The cost of polling is paid only while it is needed. Nothing runs at all until the icon is
/// actually hidden, and a five-per-second read of a static is not measurable against an app that is
/// already reading accessibility trees four times a second.
@MainActor
final class MenuBarRevealMonitor {
    /// Called on the main actor whenever the answer changes.
    var onChange: ((Bool) -> Void)?

    /// Often enough that a hold feels answered rather than laggy, rarely enough to be free. Against
    /// a five-second gesture, a fifth of a second is four per cent of it.
    private static let interval: TimeInterval = 0.2

    /// Everything that means the key is being used rather than held: the modifiers a shortcut is
    /// built from.
    ///
    /// Caps lock and fn are deliberately not among them. Both are states a reader may simply be in
    /// rather than things they are doing -- fn is latched by the globe key for switching input
    /// source, and on a laptop it is under the same hand as Option. Counting either would mean a
    /// gesture that silently never fires for the people who happen to be in that state, and the
    /// failure this feature cannot have is the one where the way back does not work. A wider accept
    /// costs nothing: the worst it can do is show an icon.
    private static let significant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private var hold = ModifierHold()
    private var timer: Timer?
    private var announced = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "MenuBarReveal")

    var isRevealed: Bool { hold.isRevealed }

    var isRunning: Bool { timer != nil }

    /// Start watching. `primed` shows the icon for the usual grace straight away, which is what the
    /// moment of switching the setting on wants: an icon that blinks out as the switch moves has
    /// not told the reader where it went.
    func start(primed: Bool) {
        stop()
        hold = ModifierHold()
        if primed { hold.prime(at: Self.now) }
        announced = hold.isRevealed
        onChange?(hold.isRevealed)
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        // The menu this reveals is tracked in its own run loop mode, and a timer on the default
        // mode alone stops firing for as long as one is open -- which is exactly when the icon must
        // not be allowed to disappear.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("menu bar reveal armed")
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        hold.forget()
        announced = false
        onChange?(false)
        logger.info("menu bar reveal disarmed")
    }

    /// The panel is open, so the icon it hangs off may not be taken away underneath it.
    func setPanelOpen(_ open: Bool) {
        hold.setPinned(open, at: Self.now)
        look()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func look() {
        let flags = NSEvent.modifierFlags.intersection(Self.significant)
        let revealed = hold.observe(alone: flags == .option, at: Self.now)
        guard revealed != announced else { return }
        announced = revealed
        logger.info("menu bar icon \(revealed ? "revealed" : "hidden", privacy: .public)")
        onChange?(revealed)
    }
}
