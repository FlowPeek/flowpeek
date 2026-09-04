@preconcurrency import AppKit
import ApplicationServices
import FlowPeekCore
import OSLog

/// Hold the peek modifier and FlowPeek reads whatever text sits under the pointer; if it parses as
/// Mermaid it outlines that block. Nothing happens unless the modifier is down, so the cost is
/// paid only when asked for and no ordinary keystroke is ever intercepted.
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
    /// does not also type a non-breaking space into the app underneath; this class only decides
    /// whether Option is down.
    static let modifier: NSEvent.ModifierFlags = .option
    /// Compared against these alone: caps lock, the function flag and the numeric-pad flag ride
    /// along on real events and would break an equality test against the whole mask.
    private static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Five levels reached the whole page in measurement; four keeps the climb inside a block.
    private static let ancestorLimit = 4
    /// Two pieces on the same visual line differed by well under a point; a new line differs by a
    /// full line height.
    private static let lineTolerance: CGFloat = 3
    /// Under `AmbientPeekPolicy.readBudget`, so a single hung reply cannot on its own overrun the
    /// budget for the whole read. A responsive app answers in well under a millisecond.
    private static let messagingTimeout: Float = 0.15

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Ambient")
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
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
        guard flagsMonitor == nil, localFlagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let engaged = event.modifierFlags.intersection(Self.significantModifiers) == Self.modifier
            Task { @MainActor in self?.setEngaged(engaged) }
        }
        // The global monitor is blind to events delivered to FlowPeek itself, which is exactly the
        // case once a preview has opened, so the same change is observed locally too.
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let engaged = event.modifierFlags.intersection(Self.significantModifiers) == Self.modifier
            Task { @MainActor in self?.setEngaged(engaged) }
            return event
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
        logger.info("ambient peek armed")
    }

    func stop() {
        [flagsMonitor, localFlagsMonitor, moveMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        flagsMonitor = nil
        localFlagsMonitor = nil
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
        // The peek is spent. Opening the preview makes FlowPeek the active application, and a global
        // monitor never sees events delivered to its own app -- so the modifier's key-up went to the
        // preview and this monitor stayed engaged for good, redrawing the hint on every mouse move
        // long after the key was released. Disengaging here means the next press re-arms it.
        isEngaged = false
        lastPointer = nil
        lastRead = nil
        onActivate?()
    }

    private func retire() {
        guard showing else { return }
        showing = false
        onDismiss?()
    }

    private func evaluate() {
        // Belt and braces for the same missed-key-up problem: whatever the monitors saw, the live
        // modifier state is the truth, so a stale engagement corrects itself on the next event
        // rather than persisting until the app is relaunched.
        guard NSEvent.modifierFlags.intersection(Self.significantModifiers) == Self.modifier else {
            setEngaged(false)
            return
        }
        let pointer = NSEvent.mouseLocation
        let now = Date()
        guard AmbientPeekPolicy.shouldRead(
            pointer: pointer,
            lastPointer: lastPointer,
            now: now,
            lastRead: lastRead
        ) else { return }
        lastPointer = pointer

        // Every path from here that cannot say "a diagram is under the pointer" retires the outline
        // on the way out. The outline is drawn around a rectangle in someone else's window: the
        // moment FlowPeek stops being able to confirm that block is still there, leaving the frame
        // up means framing whatever has scrolled into its place. `.abandoned` is the one exception.
        guard AXIsProcessTrusted() else {
            retire()
            return
        }
        // Without a frontmost application there is nothing to attribute the read to, and no pid to
        // hold responsible if it hangs.
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            retire()
            lastRead = Date()
            return
        }
        let pid = application.processIdentifier
        guard !backoff.isSuppressed(pid: pid, now: now) else {
            // Nothing is read from this app for the length of the window, so this retires once and
            // then stays retired: there is no outline left to blink.
            retire()
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

        let screen = ScreenGeometry.visibleFrame(containing: pointer, visibleFrames: frames)?.size
            ?? frames.first?.size
            ?? .zero

        // The hit-test returns the innermost element, which in a code block is often one line or
        // one syntax-highlighted token: reading only that yields a fragment, and a fragment that
        // happens to start with a diagram keyword parses until it runs out of input. So climb --
        // but take the *first* level that detects, not the largest.
        //
        // The innermost enclosure that reads as a diagram is the block the pointer is actually on.
        // Every level above it only adds the page around it: the language tab's label glued to the
        // first line ("mermaideventmodeling", measured), the run hint, and eventually the other code
        // blocks on the page, at which point the largest text is some other diagram entirely.
        // A bare starter line cannot win here either, because a starter with no body detects as
        // `.weak` and `AmbientPeekPolicy` requires `.likely`.
        var cursor: AXUIElement? = hit
        for _ in 0..<Self.ancestorLimit {
            guard let element = cursor else { break }
            // The climb walks up through another process, one synchronous message per level, so it
            // is on the clock exactly like the descent is.
            guard Date() < deadline else { return .abandoned }
            defer { cursor = parent(of: element, before: deadline) }
            guard let axFrame = rect(element, "AXFrame", before: deadline) else { continue }
            let bounds = ScreenGeometry.axToAppKit(axFrame, flipReference: flip)
            // Cheap rejection before the descent, which is the expensive half. Once an ancestor is
            // too big to be a code block, every further ancestor is too, so stop.
            guard AmbientPeekPolicy.isPlausible(bounds: bounds, screen: screen) else { break }
            // The highlight clips its outline to the display and declines to draw a sliver, so a
            // block scrolled almost entirely off screen is refused here too: otherwise the monitor
            // would believe an outline is showing and the peek chord would open a diagram nobody
            // framed. `continue`, not `break`: an ancestor encloses this rectangle, so it is the one
            // level that can still have enough of itself on screen to frame.
            guard let visible = ScreenGeometry.clip(bounds, screenFrames: frames),
                  visible.width >= AmbientPeekPolicy.minimumSize.width,
                  visible.height >= AmbientPeekPolicy.minimumSize.height else { continue }

            // A fresh node and depth budget per level: those two bound the shape of one subtree,
            // and the deadline -- shared across the whole climb -- is what bounds the read in time.
            var descent = Descent(deadline: deadline)
            let text = text(under: element, descent: &descent)
            // A half-read subtree is reported as abandoned even when it did yield text: a code block
            // cut off mid-diagram is exactly the input that would outline the wrong thing and then
            // open it.
            guard !descent.isExpired else { return .abandoned }
            guard let text else { continue }

            if let candidate = AmbientPeekPolicy.candidate(
                text: text,
                bounds: bounds,
                screen: screen,
                applicationName: application.localizedName
            ) { return .found(candidate) }
        }
        return Date() < deadline ? .nothing : .abandoned
    }

    /// Rebuilds lines from the pieces' own frames. Joining every piece with a newline splits a
    /// line that arrives as several pieces -- two, in the measured case -- and mermaid then fails
    /// mid-statement. Pieces sharing a baseline are one line; a new baseline starts a new one.
    private func text(under element: AXUIElement, descent: inout Descent) -> String? {
        var pieces: [(text: String, frame: CGRect?)] = []
        collectText(element, depth: 0, descent: &descent, into: &pieces)
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1 { return pieces[0].text }

        var lines: [String] = []
        var current = ""
        var baseline: CGFloat?
        for piece in pieces {
            guard let top = piece.frame?.minY else {
                // No frame to place it by: treat it as its own line rather than guessing.
                if !current.isEmpty { lines.append(current); current = "" }
                lines.append(piece.text)
                baseline = nil
                continue
            }
            if let baseline, abs(top - baseline) <= Self.lineTolerance {
                current += piece.text
            } else {
                if !current.isEmpty { lines.append(current) }
                current = piece.text
            }
            baseline = top
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    /// Web content puts a code block's text in `AXStaticText` children rather than on the element
    /// the hit-test returns, so the walk has to go down. Bounded on node count, depth and the
    /// clock: neither a deep subtree nor a wedged app may stall the pointer. Each piece's frame
    /// comes back with it, because the frames are what make line reconstruction possible.
    ///
    /// A node that carries text of its own is a leaf for this walk. An editable code block exposes
    /// its whole content as the `AXTextArea`'s `AXValue` *and* re-exposes the same content as
    /// syntax-highlighted `AXStaticText` descendants; collecting both concatenates the diagram to
    /// itself, and mermaid then fails on the second starter. Measured on mermaid.ai's own docs: one
    /// `AXTextArea` yielded 884 characters, which is the 442-character diagram exactly twice.
    private func collectText(
        _ element: AXUIElement,
        depth: Int,
        descent: inout Descent,
        into pieces: inout [(text: String, frame: CGRect?)]
    ) {
        guard descent.mayVisit(depth: depth) else { return }
        if let role = string(element, kAXRoleAttribute as String, before: descent.deadline),
           role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField",
           let text = string(element, kAXValueAttribute as String, before: descent.deadline),
           !text.isEmpty {
            pieces.append((text, rect(element, "AXFrame", before: descent.deadline)))
            return
        }
        var children: CFTypeRef?
        guard Date() < descent.deadline,
              AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let array = children as? [AnyObject] else { return }
        for child in array where CFGetTypeID(child) == AXUIElementGetTypeID() {
            collectText(unsafeDowncast(child, to: AXUIElement.self), depth: depth + 1, descent: &descent, into: &pieces)
        }
    }

    private func parent(of element: AXUIElement, before deadline: Date) -> AXUIElement? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
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
