@preconcurrency import AppKit
import ApplicationServices
import FlowPeekCore
import OSLog

/// Hold the peek modifier and FlowPeek reads whatever text sits under the pointer; if it parses as
/// Mermaid it outlines that block. Nothing happens unless the modifier is down, so the cost is
/// paid only when asked for.
///
/// Measured: a hit-test plus a bounded descent costs 19-31 ms, and in web content the hit element's
/// `AXFrame` is the code block's own rectangle -- 760x146 for a `<pre>` -- so the outline lands
/// exactly on the text. Apps that render text themselves (a canvas terminal, Monaco without
/// `editor.accessibilitySupport`) expose no text here at all; the clipboard watch covers those.
@MainActor
final class AmbientPeekMonitor {
    var onCandidate: ((AmbientCandidate) -> Void)?
    var onDismiss: (() -> Void)?
    /// Fired when the peek key is pressed while an outline is showing.
    var onActivate: (() -> Void)?

    /// Option alone. macOS itself uses a held Option to reveal alternatives, and Space is the one
    /// key already under the hand that is holding it. The chord itself belongs to
    /// `FlowPeekShortcutAction.ambientPeek`, which is registered as a real hot key so pressing it
    /// does not also type into the app underneath; this class only decides whether Option is down.
    static let modifier: NSEvent.ModifierFlags = .option
    /// Compared against these alone: caps lock, the function flag and the numeric-pad flag ride
    /// along on real events and would break an equality test against the whole mask.
    private static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Under `AmbientPeekPolicy.readBudget`, so a single hung reply cannot on its own overrun the
    /// budget for the whole read. A responsive app answers in well under a millisecond.
    private static let messagingTimeout: Float = 0.15

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Ambient")
    private var flagsMonitor: Any?
    private var moveMonitor: Any?
    private var isEngaged = false
    private var lastPointer: CGPoint?
    private var lastRead: Date?
    private var showing = false
    private var backoff = AmbientPeekPolicy.ReadBackoff()
    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }()

    func start() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let engaged = event.modifierFlags.intersection(Self.significantModifiers) == Self.modifier
            Task { @MainActor in self?.setEngaged(engaged) }
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
        logger.info("ambient peek armed")
    }

    func stop() {
        [flagsMonitor, moveMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        flagsMonitor = nil
        moveMonitor = nil
        setEngaged(false)
        logger.info("ambient peek disarmed")
    }

    // MARK: - Engagement

    private func setEngaged(_ engaged: Bool) {
        guard engaged != isEngaged else { return }
        isEngaged = engaged
        if engaged {
            lastPointer = nil
            lastRead = nil
            evaluate()
        } else {
            retire()
        }
    }

    private func pointerMoved() {
        guard isEngaged else { return }
        evaluate()
    }

    /// The peek chord fired. Ignored unless an outline is actually on screen, so the hot key can be
    /// registered for as long as the experiment runs without doing anything unasked.
    func activate() {
        guard isEngaged, showing else { return }
        // Deliberately not `retire()`: that fires onDismiss, whose handler drops the candidate, and
        // the activation then had nothing left to open. The outline is dismissed by whoever handles
        // the activation, which needs the candidate first.
        showing = false
        onActivate?()
    }

    private func retire() {
        guard showing else { return }
        showing = false
        onDismiss?()
    }

    private func evaluate() {
        let pointer = NSEvent.mouseLocation
        let now = Date()
        guard AmbientPeekPolicy.shouldRead(
            pointer: pointer,
            lastPointer: lastPointer,
            now: now,
            lastRead: lastRead
        ) else { return }
        lastPointer = pointer

        guard AXIsProcessTrusted() else { return }
        // Without a frontmost application there is nothing to attribute the read to, and no pid to
        // hold responsible if it hangs.
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            lastRead = Date()
            return
        }
        let pid = application.processIdentifier
        guard !backoff.isSuppressed(pid: pid, now: now) else {
            lastRead = Date()
            return
        }

        let outcome = read(at: pointer, in: application, deadline: now + AmbientPeekPolicy.readBudget)
        // Stamped when the read *finishes*: timed from the start, a 200 ms read would already be
        // past the debounce by the time it returned and the next pointer move would re-run it.
        lastRead = Date()

        switch outcome {
        case .found(let candidate):
            backoff.noteCompleted(pid: pid)
            showing = true
            onCandidate?(candidate)
        case .nothing:
            backoff.noteCompleted(pid: pid)
            retire()
        case .abandoned:
            // Deliberately neither retiring nor showing: an unfinished read is not the answer "no
            // diagram here". Retiring would fire onDismiss, drop the candidate an activation needs,
            // and blink the outline off and on for as long as the app stayed slow.
            if backoff.noteAbandoned(pid: pid, now: now) {
                logger.info(
                    """
                    ambient reads paused for \(application.localizedName ?? "an app", privacy: .public): \
                    the accessibility read kept running out of its \
                    \(Int(AmbientPeekPolicy.readBudget * 1000), privacy: .public) ms budget
                    """
                )
            }
        }
    }

    // MARK: - Reading

    private enum Read {
        case found(AmbientCandidate)
        case nothing
        /// The budget ran out before the read could finish, so what is under the pointer is unknown.
        case abandoned
    }

    /// Bounded three ways: node count, depth, and a wall clock. The clock is the one that matters
    /// when the app being read is wedged — the other two count work, not the time it takes.
    private struct Descent {
        static let nodeLimit = 400
        static let depthLimit = 12

        let deadline: Date
        var visited = 0
        private(set) var isExpired = false

        mutating func mayVisit(depth: Int) -> Bool {
            guard !isExpired else { return false }
            guard visited < Self.nodeLimit, depth < Self.depthLimit else { return false }
            guard Date() < deadline else {
                isExpired = true
                return false
            }
            visited += 1
            return true
        }
    }

    private func read(at pointer: CGPoint, in application: NSRunningApplication, deadline: Date) -> Read {
        let frames = NSScreen.screens.map(\.frame)
        guard let flip = ScreenGeometry.flipReference(screenFrames: frames) else { return .nothing }

        var hit: AXUIElement?
        let axPoint = ScreenGeometry.appKitToAX(pointer, flipReference: flip)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit else { return Date() < deadline ? .nothing : .abandoned }
        _ = AXUIElementSetMessagingTimeout(hit, Self.messagingTimeout)

        guard let axFrame = rect(hit, "AXFrame", before: deadline) else {
            return Date() < deadline ? .nothing : .abandoned
        }
        let bounds = ScreenGeometry.axToAppKit(axFrame, flipReference: flip)
        let screen = ScreenGeometry.visibleFrame(containing: pointer, visibleFrames: frames)?.size
            ?? frames.first?.size
            ?? .zero

        // Cheap rejection before the descent: a sliver or a window-sized container is never the
        // thing we want to outline, and the descent is the expensive half.
        guard AmbientPeekPolicy.isPlausible(bounds: bounds, screen: screen) else { return .nothing }
        // The highlight clips its outline to the display and declines to draw a sliver, so a block
        // scrolled almost entirely off screen is refused here too: otherwise the monitor would
        // believe an outline is showing and the peek chord would open a diagram nobody framed.
        guard let visible = ScreenGeometry.clip(bounds, screenFrames: frames),
              visible.width >= AmbientPeekPolicy.minimumSize.width,
              visible.height >= AmbientPeekPolicy.minimumSize.height else { return .nothing }

        var pieces: [String] = []
        var descent = Descent(deadline: deadline)
        collectText(hit, depth: 0, descent: &descent, into: &pieces)
        // A half-read subtree is reported as abandoned even when it did yield text: a code block cut
        // off mid-diagram is exactly the input that would outline the wrong thing and then open it.
        guard !descent.isExpired else { return .abandoned }
        guard !pieces.isEmpty else { return .nothing }

        guard let candidate = AmbientPeekPolicy.candidate(
            text: pieces.joined(separator: "\n"),
            bounds: bounds,
            screen: screen,
            applicationName: application.localizedName
        ) else { return .nothing }
        return .found(candidate)
    }

    /// Web content puts a code block's text in `AXStaticText` children rather than on the element
    /// the hit-test returns, so the walk has to go down.
    private func collectText(_ element: AXUIElement, depth: Int, descent: inout Descent, into pieces: inout [String]) {
        guard descent.mayVisit(depth: depth) else { return }
        if let role = string(element, kAXRoleAttribute as String, before: descent.deadline),
           role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField",
           let text = string(element, kAXValueAttribute as String, before: descent.deadline),
           !text.isEmpty {
            pieces.append(text)
        }
        var children: CFTypeRef?
        guard Date() < descent.deadline,
              AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let array = children as? [AnyObject] else { return }
        for child in array where CFGetTypeID(child) == AXUIElementGetTypeID() {
            collectText(unsafeDowncast(child, to: AXUIElement.self), depth: depth + 1, descent: &descent, into: &pieces)
        }
    }

    /// Every accessibility call is a synchronous message to another process, so the clock is checked
    /// immediately before each one rather than once per node.
    private func string(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> String? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private func rect(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> CGRect? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
