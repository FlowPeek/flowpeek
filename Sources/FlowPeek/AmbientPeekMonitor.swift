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
/// exactly on the text. An editor that exposes only its focused document, VS Code among them, has
/// nothing under the pointer to read and is served by the caret fallback instead. Apps that render
/// text themselves (a canvas terminal) expose neither; the clipboard watch covers those.
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

        // Chromium and Electron hand out an accessibility tree of empty `AXGroup`s until this is
        // set: measured in VS Code, the descent found zero text before it and the document
        // immediately after. Memoised per pid and shared with the selection route, which warms the
        // same processes when they activate -- so an app the user has been working in is usually
        // already warm by the time Option goes down, and the message is not sent at all. The
        // renderer switches over asynchronously, so the first hold after a cold launch can still
        // read nothing; the next one reads.
        //
        // Inside the read's own budget, not before it. The set is a synchronous message to the very
        // app the read is about to question, so an app that answers only when its timeout expires
        // would stall the pointer for that timeout and *then* get a full budget to stall in again --
        // with the read still reporting `.nothing`, which clears the backoff instead of engaging it.
        // Charged here, a wedged app spends the budget it was given, the read comes back
        // `.abandoned`, and three holds put it away for ten seconds.
        let deadline = Date() + AmbientPeekPolicy.readBudget
        AccessibilityTreeWarmUp.shared.warmUp(pid, before: deadline)

        let outcome = read(at: pointer, in: application, deadline: deadline)
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

        let screen = ScreenGeometry.visibleFrame(containing: pointer, visibleFrames: frames)?.size
            ?? frames.first?.size
            ?? .zero

        var hit: AXUIElement?
        let axPoint = ScreenGeometry.appKitToAX(pointer, flipReference: flip)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit else { return Date() < deadline ? .nothing : .abandoned }
        _ = AXUIElementSetMessagingTimeout(hit, Self.messagingTimeout)

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
        // Nothing under the pointer reads as a diagram. In an editor that is the normal answer
        // rather than a "no", so the caret gets one attempt on what is left of the same budget --
        // but only while the pointer really is over that editor. This is the cheap half of that
        // test: the element under the pointer has to belong to the application whose focused
        // document is about to be read, or pointing at a Finder window with an editor frontmost
        // would put an outline where the pointer has never been. `AXUIElementGetPid` is a local
        // lookup rather than a message to the other process. The other half, that the pointer is
        // over the editor rather than merely over the same application, needs the editor's own
        // rectangle and so belongs to the read.
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner == application.processIdentifier else {
            return Date() < deadline ? .nothing : .abandoned
        }
        return caretRead(at: pointer, in: application, screen: screen, flip: flip, frames: frames, deadline: deadline)
    }

    /// The read the descent cannot do. VS Code's editor exposes the whole file as the focused
    /// `AXTextArea`'s `AXValue` -- 30031 characters for a 2000-line document, with real newlines,
    /// unvirtualised -- and hands out nothing at all through the elements under the pointer.
    ///
    /// So this anchors on the caret, which it has to: `AXTextMarkerForPosition` is advertised and
    /// answers nil, `AXBoundsForRange` answers 0x0 at (0,1080), `AXStringForRange` answers nil, and
    /// every line's `AXTextMarkerRangeForLine` bounds is the whole editor rectangle -- so there is
    /// no attribute left that maps a pointer to a line, and a binary search has nothing to search.
    /// In an editor the caret is where the user is working, so the hint names it and the outline
    /// frames the caret's line or the pane rather than pretending to frame the block.
    ///
    /// Kept as a fallback and never a primary read: in Chrome the same marker attributes answer,
    /// but with no newlines between block elements ("Introduction#Event Modeling (EM) is..."), which
    /// is worse than what the descent already gets there.
    private func caretRead(
        at pointer: CGPoint,
        in application: NSRunningApplication,
        screen: CGSize,
        flip: CGFloat,
        frames: [CGRect],
        deadline: Date
    ) -> Read {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        guard let focused = element(app, kAXFocusedUIElementAttribute as String, before: deadline) else {
            return Date() < deadline ? .nothing : .abandoned
        }
        _ = AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
        // A focused button or list is not a document, and reading its value would anchor the peek
        // on whatever label it carries.
        guard let role = string(focused, kAXRoleAttribute as String, before: deadline),
              role == "AXTextArea" || role == "AXTextField" else {
            return Date() < deadline ? .nothing : .abandoned
        }

        // Geometry before content, because the same two rectangles answer both questions this read
        // has: whether the pointer is over this editor at all, and where the outline may go once
        // the diagram is found. Neither is read speculatively -- a read that gets past the gate
        // needs both, and one that does not was going to be refused anyway.
        let line = rect(focused, "AXFrame", before: deadline)
            .map { ScreenGeometry.axToAppKit($0, flipReference: flip) }
        let pane = parent(of: focused, before: deadline)
            .flatMap { rect($0, "AXFrame", before: deadline) }
            .map { ScreenGeometry.axToAppKit($0, flipReference: flip) }
        guard AmbientPeekPolicy.caretAnchorFits(pointer: pointer, focused: line, container: pane) else {
            return Date() < deadline ? .nothing : .abandoned
        }

        // How long the document is, before it is copied. The value arrives as one string across
        // IPC and the slice that follows is not an accessibility message, so neither the messaging
        // timeout nor the deadline can keep either of them small -- one attribute that answers with
        // a number can, and it costs the same single message the read was going to spend anyway. An
        // editor that will not answer it is still bounded, by the slicer's own cap, but pays for
        // the copy before it is turned down.
        if let length = number(focused, kAXNumberOfCharactersAttribute as String, before: deadline),
           length > AmbientPeekPolicy.maximumDocumentCharacters {
            return .nothing
        }
        // Without a selection range there is no anchor at all: the pointer cannot be placed, so a
        // document that will not say where its caret is has no position to slice around.
        guard let document = string(focused, kAXValueAttribute as String, before: deadline),
              !document.isEmpty,
              let selected = range(focused, kAXSelectedTextRangeAttribute as String, before: deadline),
              let slice = DocumentCaretSlicer.slice(
                  document: document,
                  caret: selected.location,
                  before: deadline
              ) else {
            return Date() < deadline ? .nothing : .abandoned
        }

        for bounds in outlineBounds(
            of: focused,
            line: line,
            pane: pane,
            hasSelection: selected.length > 0,
            document: document,
            caret: selected.location,
            slice: slice,
            flip: flip,
            before: deadline
        ) {
            let grown = AmbientPeekPolicy.grownToMinimum(bounds)
            // Same refusal as the climb: the highlight declines to draw a sliver, and the monitor
            // must not believe an outline is showing when none was drawn -- the peek chord would
            // then open a diagram nobody framed.
            guard let visible = ScreenGeometry.clip(grown, screenFrames: frames),
                  visible.width >= AmbientPeekPolicy.minimumSize.width,
                  visible.height >= AmbientPeekPolicy.minimumSize.height else { continue }
            guard let candidate = AmbientPeekPolicy.candidate(
                slice: slice,
                bounds: grown,
                screen: screen,
                applicationName: application.localizedName
            ) else { continue }
            // Offsets and sizes only: the document itself is never logged.
            logger.debug(
                """
                caret anchor in \(application.localizedName ?? "an app", privacy: .public): \
                \(slice.range.length, privacy: .public) characters at offset \
                \(slice.range.location, privacy: .public) of \(document.utf16.count, privacy: .public)
                """
            )
            return .found(candidate)
        }
        return Date() < deadline ? .nothing : .abandoned
    }

    /// Where the caret's outline can go, best first, in AppKit coordinates.
    ///
    /// The selected marker range's bounds is the only geometry VS Code answers with -- measured
    /// 185x68 at (703,167) for a 31-character selection -- and it is asked for only when something
    /// is actually selected, which is the case it was measured in and the only case where it is the
    /// best of the three. Then the focused element's own frame, which is the caret's line (1078x18
    /// at (703,219)), and then the pane around it, the editor's rectangle. Both of those were
    /// already read to place the pointer, so this spends one more message only when it is the one
    /// that wins. None of the three is the diagram's own box; no attribute reports that.
    private func outlineBounds(
        of focused: AXUIElement,
        line: CGRect?,
        pane: CGRect?,
        hasSelection: Bool,
        document: String,
        caret: Int,
        slice: CaretDiagramSlice,
        flip: CGFloat,
        before deadline: Date
    ) -> [CGRect] {
        var bounds: [CGRect] = []
        if hasSelection,
           let markers = attribute(focused, "AXSelectedTextMarkerRange", before: deadline),
           let selection = rect(
               focused,
               parameterized: "AXBoundsForTextMarkerRange",
               argument: markers,
               before: deadline
           ) {
            bounds.append(ScreenGeometry.axToAppKit(selection, flipReference: flip))
        }
        if let line, let block = blockBounds(
            of: focused,
            caretLine: line,
            document: document,
            caret: caret,
            slice: slice,
            before: deadline
        ) {
            bounds.append(block)
        }
        if let line { bounds.append(line) }
        if let pane { bounds.append(pane) }
        return bounds
    }

    /// The whole diagram's rectangle, worked out from the caret's line, or nil when the editor does
    /// not agree that the arithmetic applies.
    ///
    /// The estimate assumes one row per document line. Soft wrapping and folded regions break that,
    /// and neither is announced -- so instead of trusting it, the editor is asked what text it has
    /// on the block's first line. `AXTextMarkerRangeForLine` answers the wrong *rectangle* for any
    /// line but the caret's, which is why the geometry has to be computed at all, but it answers the
    /// right *text*, and that is enough to catch a document whose rows and lines have stopped
    /// matching. One extra accessibility message, only on the caret route.
    private func blockBounds(
        of focused: AXUIElement,
        caretLine: CGRect,
        document: String,
        caret: Int,
        slice: CaretDiagramSlice,
        before deadline: Date
    ) -> CGRect? {
        guard let caretLineNumber = CaretBlockGeometry.lineNumber(of: caret, in: document),
              let lines = CaretBlockGeometry.lines(of: slice.range, in: document),
              lines.last > lines.first,
              let block = CaretBlockGeometry.rectangle(
                  caretLine: caretLine,
                  caretLineNumber: caretLineNumber,
                  firstLine: lines.first,
                  lastLine: lines.last
              ) else { return nil }
        guard agreesOnLine(lines.first, of: focused, in: document, before: deadline) else { return nil }
        return block
    }

    /// Whether the editor puts the same text on `line` as the document string does. Line numbers are
    /// zero-based here and one-based everywhere else in this file, which is the only reason the
    /// conversion is spelled out.
    private func agreesOnLine(
        _ line: Int,
        of focused: AXUIElement,
        in document: String,
        before deadline: Date
    ) -> Bool {
        let documentLines = document.components(separatedBy: "\n")
        guard line >= 1, line <= documentLines.count else { return false }
        let expected = documentLines[line - 1].trimmingCharacters(in: .whitespaces)
        guard !expected.isEmpty else { return false }
        guard let range = attribute(
            focused,
            parameterized: "AXTextMarkerRangeForLine",
            argument: NSNumber(value: line - 1),
            before: deadline
        ), let text = string(
            focused,
            parameterized: "AXStringForTextMarkerRange",
            argument: range,
            before: deadline
        ) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == expected
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
        self.element(element, kAXParentAttribute as String, before: deadline)
    }

    private func element(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> AXUIElement? {
        guard let value = self.attribute(element, attribute, before: deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// The raw value, for the one attribute FlowPeek never looks inside: an `AXTextMarkerRange` is
    /// opaque and is only ever handed straight back as the argument to `AXBoundsForTextMarkerRange`.
    private func attribute(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
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

    /// `AXNumberOfCharacters` arrives as a `CFNumber`, and is the one way to ask how big a
    /// document is without asking for the document.
    private func number(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> Int? {
        guard let value = self.attribute(element, attribute, before: deadline) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func rect(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> CGRect? {
        guard let value = self.attribute(element, attribute, before: deadline) else { return nil }
        return Self.cgRect(value)
    }

    /// The parameterized twin of `attribute(_:_:before:)`, for the one range this file asks for by
    /// line number rather than by marker.
    private func attribute(
        _ element: AXUIElement,
        parameterized attribute: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            argument,
            &value
        ) == .success else { return nil }
        return value
    }

    private func string(
        _ element: AXUIElement,
        parameterized attribute: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> String? {
        guard let value = self.attribute(element, parameterized: attribute, argument: argument, before: deadline) else {
            return nil
        }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private func rect(
        _ element: AXUIElement,
        parameterized attribute: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> CGRect? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            argument,
            &value
        ) == .success, let value else { return nil }
        return Self.cgRect(value)
    }

    private static func cgRect(_ value: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// `AXSelectedTextRange` arrives as a `CFRange` whose location counts UTF-16 code units of the
    /// element's own value -- measured loc=45 len=31 in VS Code -- which is the unit
    /// `DocumentCaretSlicer` slices in.
    private func range(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> CFRange? {
        guard let value = self.attribute(element, attribute, before: deadline),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        // A negative location is not a position in any document; a caret is clamped by the slicer,
        // but this is nonsense rather than staleness.
        guard range.location >= 0 else { return nil }
        return range
    }
}
