@preconcurrency import AppKit
import ApplicationServices
import FlowPeekCore
import OSLog

/// Watches the terminal the user is looking at and outlines a Mermaid diagram the moment one is on
/// screen -- nothing selected, nothing copied, nothing held down.
///
/// A terminal is the one place where a diagram arrives as plain output: `cat design.mmd`, a diff, a
/// generator's stdout. There is no selection to read and no document to anchor on, so both of the
/// other accessibility routes have nothing to work with. What a terminal does expose is its whole
/// buffer as one `AXTextArea`, and that is enough to find the block and put a frame around it.
///
/// Two ways of reading, decided from the attributes the text area answers with rather than from
/// which terminal it is:
///
/// - **by character range.** Terminal.app and iTerm2 answer `AXBoundsForRange`, so the block's own
///   rows come back as a rectangle. The viewport is `AXVisibleCharacterRange` where it narrows
///   (Terminal.app: 1639 of 8808 characters, measured) and `AXRangeForPosition` at the content
///   corners where it does not (iTerm2 reports the whole buffer as visible).
/// - **by grid arithmetic.** Ghostty answers neither, so the geometry is solved for instead: its
///   scroll area reports `rows * rowHeight + padding` as its content height, and the rows are the
///   rows of the lines its `AXValue` holds, so the column count -- the one thing that decides how
///   many rows a line takes -- can be worked out from the height. `TerminalGridInference` does
///   that, sieving candidates across several looks until they agree; measured on Ghostty, 138
///   columns of 16 points with 6 points of padding. Until they agree, and for a buffer too big to
///   read, the row height is the content height over the line count as before, which is right only
///   while nothing wraps.
///
/// A terminal that renders into a canvas inside a web view exposes no text at all -- Orca's
/// embedded Ghostty answers with one `AXWebArea` whose value is empty, and anything on xterm.js is
/// the same -- so it cannot be read this way and is not on the list. The clipboard watch is what
/// serves those.
///
/// Polling, because no terminal posts an accessibility notification for its own output or for a
/// scroll. Only while one of the three is frontmost, and in two halves: a poll over a terminal
/// nobody is changing asks four or five questions and stops, at 0.2 ms in Terminal.app, 0.9 ms in
/// iTerm2 and 1.2 ms in Ghostty. The half that scans the buffer runs only when those answers move,
/// and costs 2.6 to 4.9 ms.
@MainActor
final class TerminalPeekMonitor {
    /// Every diagram on screen, in the order they sit in the buffer.
    var onCandidates: (([AmbientCandidate]) -> Void)?
    var onDismiss: (() -> Void)?

    /// Under `TerminalPeekPolicy.readBudget`, so one hung reply cannot spend the whole read's
    /// budget on its own. All three terminals answer in well under a millisecond.
    private static let messagingTimeout: Float = 0.1
    /// How deep the walk for the text area goes. Measured: Terminal.app puts it three levels under
    /// the window, iTerm2 four, Ghostty four.
    private static let descentLimit = 8
    /// How much further to look once a web area has been entered. Measured in Orca: the row list
    /// sits twenty levels below the window, eighteen of them Chromium's own wrappers.
    private static let webDescentLimit = 20
    /// The class xterm.js puts on the list it publishes the visible rows into.
    private static let rowListClass = "xterm-accessibility-tree"
    /// How far inside the content rectangle the corner probes sit, in points. Far enough to be
    /// inside the first and last row, close enough not to skip one.
    private static let cornerInset: CGFloat = 4
    /// Rows read either side of the viewport when the buffer is walked by row rather than by
    /// character range -- the grid path's equivalent of `TerminalPeekPolicy.characterMargin`, and
    /// there for the same reason: a block half off the top has to be found whole.
    private static let lineMargin = 120

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Terminal")
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var scrollMonitor: Any?
    private var showing = false
    private var settle = TerminalPeekPolicy.Settle()
    private var backoff = AmbientPeekPolicy.ReadBackoff()
    private var isRunning = false
    /// The window the cached pane was found under, and the pane itself. Descending to the text area
    /// costs 0.6-0.8 ms of accessibility messages, which is most of what a poll that finds nothing
    /// new would otherwise spend.
    private var cached: (window: AXUIElement, pane: Pane, strategy: Strategy)?
    /// What the last read looked at, and whether it reached a conclusion it acted on. A poll that
    /// sees the same numbers as a settled read has nothing to recompute.
    private var lastLook: (fingerprint: Fingerprint, settled: Bool)?
    /// The row height last divided out of an overflowing buffer, per terminal process.
    ///
    /// The grid strategy cannot measure a row while the buffer fits its viewport, because a scroll
    /// area that has nothing to scroll reports the viewport's height as its content's -- so this is
    /// what places a diagram in a window that has not filled up yet, which is every fresh one.
    /// Keyed by process rather than by window: a second window of the same terminal is the same
    /// font, and keying it to the pane cache would throw the answer away on every window switch,
    /// leaving exactly the fresh-window case with nothing to fall back on. A font change while no
    /// buffer overflows is the price, and it corrects itself on the next read that does.
    private var rowHeights: [pid_t: CGFloat] = [:]
    /// The last reading taken of each pane. Two readings of one pane solve the grid outright, and a
    /// terminal that is printing produces the second within seconds of the first.
    private var lastSamples: [pid_t: TerminalRowMetrics.Sample] = [:]
    /// The terminal's own account of its grid, read from the ptys it owns. Asked before anything is
    /// solved, because it is a reading rather than an inference: it needs no scrollback, no second
    /// look and no remembered value, which between them are everything a full-screen program denies.
    private let ptyProbe = TerminalPtyProbe()
    /// Grids that still explain everything this pane has reported. Sieved on every look and used
    /// only once they agree, so a wrong column count cannot place an outline; see
    /// `TerminalGridInference`.
    private var gridCandidates: [pid_t: [TerminalGrid]] = [:]
    /// Which terminal the read in flight is looking at, for the row height kept between runs.
    private var readingApp: TerminalApp?
    /// Whose buffer the read in flight is looking at, for `rowHeights`.
    private var reading: pid_t?
    /// How many polls in a row have been answered from `lastLook` without reading the buffer.
    private var shortcutsTaken = 0

    /// Why the watch is standing down. A set rather than a flag because the reasons arrive from
    /// unrelated places and overlap: opening a diagram from an outline raises `preview` while the
    /// pointer route may hold `pointerRoute`, and one of them clearing must not speak for the other.
    enum Suppression {
        /// The pointer route owns the outline. Two frames over the same window would fight over the
        /// same rectangle, and the one the user is holding a key for wins.
        case pointerRoute
        /// A FlowPeek preview is on screen. The outline draws above every ordinary window, so
        /// leaving it up would put a frame across the diagram the user just opened.
        case preview
    }

    private var suppressions: Set<Suppression> = []

    var isSuppressed: Bool { !suppressions.isEmpty }

    func suppress(_ reason: Suppression, _ on: Bool) {
        let before = isSuppressed
        if on { suppressions.insert(reason) } else { suppressions.remove(reason) }
        guard isSuppressed != before else { return }
        // Both directions invalidate the gate. Coming back is the direction that matters: the
        // terminal looks exactly as it did when the outline was taken down, so a poll that trusted
        // its last settled answer would decide nothing had changed and never draw again. That is
        // what made an outline unclickable after one preview -- opening a diagram left the screen
        // untouched, so nothing ever brought the frame back short of a scroll.
        lastLook = nil
        if isSuppressed { retire() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        }
        // A scroll takes the outline down at once rather than a poll later. The rectangle was
        // computed from where the rows were, and while the buffer is moving under it the frame is
        // around whatever has slid into its place -- so it goes, and the next read puts it back a
        // quarter of a second after the scrolling stops. Costs nothing: no accessibility call.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            Task { @MainActor in self?.scrolled() }
        }
        frontmostChanged()
        logger.info("terminal watch armed")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        suspend()
        suppressions.removeAll()
        retire()
        logger.info("terminal watch disarmed")
    }

    // MARK: - When to look

    /// The watch follows the frontmost application: a terminal in the background is not the
    /// terminal the user is reading, and polling one would spend the cost with nothing to show.
    private func frontmostChanged() {
        guard isRunning else { return }
        // A different application means a different window, and with it a different text area.
        forgetPane()
        forgetDeadProcesses()
        guard TerminalApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != nil else {
            suspend()
            retire()
            return
        }
        resume()
        evaluate()
    }

    private func resume() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: TerminalPeekPolicy.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = TerminalPeekPolicy.pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func suspend() {
        timer?.invalidate()
        timer = nil
        settle.forget()
        forgetPane()
    }

    private func forgetPane() {
        cached = nil
        lastLook = nil
        shortcutsTaken = 0
    }

    /// Forgets the row heights of terminals that are no longer running, so a recycled process
    /// identifier cannot inherit another terminal's font. Cheap: the dictionary holds one entry per
    /// terminal the user has looked at this session.
    private func forgetDeadProcesses() {
        guard rowHeights.count > 1 || gridCandidates.count > 1 else { return }
        let alive = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        rowHeights = rowHeights.filter { alive.contains($0.key) }
        lastSamples = lastSamples.filter { alive.contains($0.key) }
        ptyProbe.forgetDeadProcesses(alive: alive)
        gridCandidates = gridCandidates.filter { alive.contains($0.key) }
    }

    private func scrolled() {
        guard isRunning, showing else { return }
        settle.forget()
        retire()
    }

    /// Takes the outline down, and makes the next poll a full read.
    ///
    /// The second half matters as much as the first. An outline taken down by something other than
    /// a read -- a scroll, the pointer route claiming the screen -- leaves the terminal looking
    /// exactly as it did when the outline was put up, so the next poll's fingerprint matches a
    /// settled read and the shortcut would fire. The frame would then never come back. Measured by
    /// scrolling Ghostty to the bottom twice: the block returned to the rows it had been outlined
    /// on, and nothing was drawn around it again.
    ///
    /// It costs nothing in the steady state: with no outline up this is already a no-op, which is
    /// the case the shortcut exists for.
    private func retire() {
        guard showing else { return }
        showing = false
        lastLook = nil
        onDismiss?()
    }

    // MARK: - One look

    func evaluate() {
        guard isRunning, !isSuppressed else { return }
        guard AXIsProcessTrusted() else {
            retire()
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              let terminal = TerminalApp(bundleIdentifier: application.bundleIdentifier) else {
            suspend()
            retire()
            return
        }
        let now = Date()
        let pid = application.processIdentifier
        guard !backoff.isSuppressed(pid: pid, now: now) else {
            retire()
            return
        }

        switch read(terminal, in: application, deadline: now + TerminalPeekPolicy.readBudget) {
        case .found(let candidates):
            backoff.noteCompleted(pid: pid)
            showing = true
            onCandidates?(candidates)
        case .nothing, .settling:
            backoff.noteCompleted(pid: pid)
            retire()
        case .unchanged:
            backoff.noteCompleted(pid: pid)
        case .abandoned:
            // An unfinished read is not the answer "nothing on screen", but the frame it would keep
            // up was computed from rows this read could not confirm are still there -- and unlike
            // the pointer route, nothing here is waiting to be opened by a key that is still down.
            // So the outline goes and the next read, a quarter of a second later, puts it back.
            retire()
            if backoff.noteAbandoned(pid: pid, now: now) {
                logger.info(
                    """
                    terminal reads paused for \(application.localizedName ?? "a terminal", privacy: .public): \
                    the accessibility read kept running out of its \
                    \(Int(TerminalPeekPolicy.readBudget * 1000), privacy: .public) ms budget
                    """
                )
            }
        }
    }

    private enum Read {
        case found([AmbientCandidate])
        case nothing
        /// A block is on screen but two reads have not yet agreed about it. Distinct from
        /// `nothing`, because the next poll has to do the whole read again to be the second of the
        /// two -- taking the unchanged shortcut here would mean an outline that never appears.
        case settling
        /// Nothing the outline depends on has moved since the last read that reached a conclusion.
        case unchanged
        /// The budget ran out before the read could finish, so what is on screen is unknown.
        case abandoned
    }

    /// Everything a read's answer depends on, in the four or five accessibility messages it takes
    /// to ask. Output arriving changes the character count; scrolling changes the visible range or
    /// the scroll bar's value; moving or resizing the window changes the content rectangle.
    ///
    /// The one thing it cannot see is a full-screen program redrawing its own grid in place, which
    /// keeps the count and the position identical. That is deliberate: a terminal user interface
    /// repainting itself is not a diagram arriving, and following it would put an outline on
    /// whatever the redraw happened to leave on those rows.
    private struct Fingerprint: Equatable {
        let characters: Int
        let content: CGRect
        let visible: NSRange?
        let scroll: Double?
        /// A hash of the text itself, where reading all of it is cheap enough to do every poll.
        /// The other three terms are geometry, and geometry is what a repaint holds constant while
        /// changing everything on screen.
        let digest: Int?

        init(characters: Int, content: CGRect, visible: NSRange?, scroll: Double?, digest: Int? = nil) {
            self.characters = characters
            self.content = content
            self.visible = visible
            self.scroll = scroll
            self.digest = digest
        }
    }

    private func read(_ terminal: TerminalApp, in application: NSRunningApplication, deadline: Date) -> Read {
        reading = application.processIdentifier
        readingApp = terminal
        // A web-view terminal publishes nothing until an assistive client announces itself, and on
        // this route nothing else does the announcing: the pointer route warms the app it is about
        // to read, but it defers to this watch over a terminal and so never gets that far. Without
        // this, a terminal that turns its accessibility tree on when one is attached would wait for
        // an attachment that never comes. Memoised per process, so this is one message the first
        // time and none after it.
        if terminal.needsAccessibilityWarmUp {
            AccessibilityTreeWarmUp.shared.warmUp(application.processIdentifier, before: deadline)
        }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        guard let window = AccessibilityRead.element(app, kAXFocusedWindowAttribute as String, before: deadline) else {
            forgetPane()
            return Date() < deadline ? .nothing : .abandoned
        }
        guard let found = look(window, in: app, terminal: terminal, deadline: deadline) else {
            return Date() < deadline ? .nothing : .abandoned
        }
        guard case .blocks(let located) = found else { return found.read }

        // Confirmed before they are drawn, but only on the way in: output that is still arriving
        // moves every row on every read, and outlines that chased it down the screen while a file
        // printed would be worse than none. Once they are up they follow immediately --
        // re-confirming would blink them off for a read every time the buffer moved by one row.
        guard settle.confirm(located.map(\.block)) || showing else {
            lastLook = lastLook.map { ($0.fingerprint, false) }
            return .settling
        }
        let candidates = located.compactMap { candidate($0, terminal: terminal, application: application) }
        guard !candidates.isEmpty else { return .nothing }
        // Counts and sizes only. What the terminal is showing is the user's, and none of it is logged.
        logger.debug(
            """
            \(candidates.count, privacy: .public) terminal block(s) in \
            \(application.localizedName ?? "a terminal", privacy: .public): \
            \(located.map { $0.block.detection.diagramKeyword ?? "unknown" }.joined(separator: ", "), privacy: .public)
            """
        )
        return .found(candidates)
    }

    /// What one look at the terminal came back with.
    private enum Look {
        case blocks([Located])
        case nothing
        case unchanged

        var read: Read {
            switch self {
            case .blocks: .nothing
            case .nothing: .nothing
            case .unchanged: .unchanged
            }
        }
    }

    /// The cheap half of a read, then the expensive half only if the cheap half says something has
    /// moved.
    ///
    /// The expensive half is not the accessibility traffic -- it is scanning the window, which
    /// costs about 0.25 microseconds a character and so a couple of milliseconds over a terminal's
    /// viewport plus its margins. Four of those a second, forever, for a screen nobody is changing
    /// is the wrong shape; four fingerprints a second is 0.3 ms. So a poll over a still terminal
    /// asks its four or five questions and stops.
    private func look(
        _ window: AXUIElement,
        in app: AXUIElement,
        terminal: TerminalApp,
        deadline: Date
    ) -> Look? {
        guard let pane = pane(under: window, terminal: terminal, before: deadline) else {
            forgetPane()
            return nil
        }
        // A row list is read from the rows, not from a character count -- Chromium reports the
        // list's own `AXNumberOfCharacters` as zero, because its text lives in the rows below it --
        // so it brings its own cheap half and skips the preamble below entirely.
        if case .rows = pane.strategy {
            return rowsLook(pane.pane, deadline: deadline)
        }
        // What the terminal is *showing*, which is not the text area's own frame: Terminal.app's
        // text area measured 2145 points tall inside a 385-point window, because the frame covers
        // the whole scrollback. The scroll area around it is the viewport, and where there is none
        // the window itself is the closest honest answer.
        guard let content = AccessibilityRead.rect(pane.pane.scroll ?? window, "AXFrame", before: deadline),
              let characters = AccessibilityRead.number(
                  pane.pane.text,
                  kAXNumberOfCharactersAttribute as String,
                  before: deadline
              ), characters > 0 else {
            // The window is still there but the element under it no longer answers, which is what
            // a replaced text view looks like. Dropping the cache lets the next poll re-descend
            // rather than asking a dead element forever.
            forgetPane()
            return nil
        }

        switch pane.strategy {
        case .ranged:
            let visible = visibleRange(
                of: pane.pane.text,
                characters: characters,
                content: content,
                before: deadline
            )
            let fingerprint = Fingerprint(
                characters: characters,
                content: content,
                visible: visible,
                scroll: nil
            )
            if let shortcut = shortcut(for: fingerprint) { return shortcut }
            guard let visible else { return .nothing }
            let located = rangedRead(
                pane.pane,
                visible: visible,
                characters: characters,
                content: content,
                deadline: deadline
            )
            return located.isEmpty ? .nothing : .blocks(located)
        case .rows:
            // Handled before the preamble above; a row list never reaches this switch.
            return .nothing
        case .grid:
            guard let grid = grid(pane.pane, characters: characters, before: deadline) else { return .nothing }
            let fingerprint = Fingerprint(
                characters: characters,
                content: grid.viewport,
                visible: nil,
                scroll: grid.value
            )
            if let shortcut = shortcut(for: fingerprint) { return shortcut }
            let located = gridRead(pane.pane, grid: grid, characters: characters, deadline: deadline)
            return located.isEmpty ? .nothing : .blocks(located)
        }
    }

    /// Whether this look can stop here, and what to record for the next one.
    ///
    /// Matching fingerprints are necessary but not sufficient: none of the terms is derived from the
    /// text, so `mustRescan` decides how long they may speak for it.
    private func shortcut(for fingerprint: Fingerprint) -> Look? {
        if let lastLook, lastLook.settled, lastLook.fingerprint == fingerprint,
           !TerminalPeekPolicy.mustRescan(isShowing: showing, shortcutsTaken: shortcutsTaken) {
            shortcutsTaken += 1
            return .unchanged
        }
        shortcutsTaken = 0
        self.lastLook = (fingerprint, true)
        return nil
    }

    /// A block and the rectangle it occupies, in accessibility coordinates.
    private struct Located {
        let block: TerminalDiagramBlock
        let rectangle: CGRect
        let content: CGRect
    }

    private func candidate(
        _ found: Located,
        terminal: TerminalApp,
        application: NSRunningApplication
    ) -> AmbientCandidate? {
        // A block bigger than this is not one diagram, and the preview would refuse it anyway.
        guard found.block.detection.extractedSource.count <= AmbientPeekPolicy.maximumCharacters else { return nil }
        let frames = NSScreen.screens.map(\.frame)
        guard let flip = ScreenGeometry.flipReference(screenFrames: frames) else { return nil }
        let bounds = ScreenGeometry.axToAppKit(found.rectangle, flipReference: flip)
        let content = ScreenGeometry.axToAppKit(found.content, flipReference: flip)
        // Trimmed to what the terminal is showing, then to the display. Both matter: a block
        // scrolled half into the scrollback keeps a rectangle that runs off the top of the window,
        // and a window pushed half off the screen keeps one that runs off the display.
        guard let inWindow = TerminalPeekPolicy.onScreenPortion(of: bounds, showing: content),
              let onDisplay = ScreenGeometry.clip(inWindow, screenFrames: frames),
              onDisplay.height >= AmbientPeekPolicy.minimumSize.height,
              onDisplay.width >= AmbientPeekPolicy.minimumSize.width else { return nil }
        return AmbientCandidate(
            text: found.block.text,
            detection: found.block.detection,
            bounds: onDisplay,
            applicationName: application.localizedName,
            anchor: .terminal,
            // Both trims in one comparison: a block scrolled into the scrollback and a window
            // pushed off the display cut the same rectangle, and either cut means the frame's edge
            // is the viewport's rather than the diagram's.
            openEdges: AmbientPeekPolicy.openEdges(trimmed: onDisplay, from: bounds)
        )
    }

    // MARK: - Reading by character range

    private func rangedRead(
        _ pane: Pane,
        visible: NSRange,
        characters: Int,
        content: CGRect,
        deadline: Date
    ) -> [Located] {
        guard let window = TerminalPeekPolicy.window(around: visible, in: characters),
              let text = string(pane.text, in: window, before: deadline) else { return [] }
        let local = NSRange(location: visible.location - window.location, length: visible.length)
        guard let span = TerminalPeekPolicy.lineSpan(of: local, in: text) else { return [] }
        let blocks = TerminalBufferScanner.blocks(in: text, visible: span)
        guard !blocks.isEmpty, let width = textWidth(of: pane.text, within: content, before: deadline) else {
            return []
        }
        return blocks.compactMap { block in
            // One row at a time, because a six-row range measured 21 points wide in iTerm2. A
            // single character is enough to place a row: the rectangle that comes back is the row's.
            //
            // The bottom is asked about the last row's last character, not its first. A row wider
            // than the terminal is drawn on more than one row of screen -- Terminal.app measured a
            // 180-character line in an 80-column window as 42 points, three rows -- and its first
            // character answers only for the first of them.
            guard let first = rowRectangle(at: window.location + block.range.location, in: pane.text, before: deadline),
                  let last = rowRectangle(at: window.location + block.lastCharacter, in: pane.text, before: deadline),
                  let rectangle = TerminalPeekPolicy.band(from: first, to: last, across: width) else { return nil }
            return Located(block: block, rectangle: rectangle, content: content)
        }
    }

    private func rowRectangle(at offset: Int, in text: AXUIElement, before deadline: Date) -> CGRect? {
        guard let argument = AccessibilityRead.argument(NSRange(location: offset, length: 1)),
              let rectangle = AccessibilityRead.rect(
                  text,
                  parameterized: "AXBoundsForRange",
                  argument: argument,
                  before: deadline
              ), ScreenGeometry.isUsable(rectangle) else { return nil }
        return rectangle
    }

    /// How wide the terminal's text is: the text area's own columns, clipped to what the viewport
    /// shows. Terminal.app's text area measured 580 points inside a 597-point scroll area, the
    /// difference being the scroll bar, and a band drawn to the scroll area's edge would run under
    /// it.
    private func textWidth(
        of text: AXUIElement,
        within content: CGRect,
        before deadline: Date
    ) -> ClosedRange<CGFloat>? {
        guard let frame = AccessibilityRead.rect(text, "AXFrame", before: deadline),
              ScreenGeometry.isUsable(frame), ScreenGeometry.isUsable(content) else { return nil }
        let left = max(frame.minX, content.minX)
        let right = min(frame.maxX, content.maxX)
        guard right > left else { return nil }
        return left...right
    }

    /// Which characters the viewport is showing.
    ///
    /// `AXVisibleCharacterRange` is the attribute for exactly this and is answered by both ranged
    /// terminals -- but iTerm2 answers with the whole buffer, which is not an answer. So a range
    /// that covers everything is treated as no answer and the corners are asked instead: the
    /// character at the top-left of the content rectangle and the one at the bottom-left. Measured
    /// in iTerm2 as 7080 and 8784 of 8788, against a window showing 24 rows of a 131-line buffer.
    private func visibleRange(
        of text: AXUIElement,
        characters: Int,
        content: CGRect,
        before deadline: Date
    ) -> NSRange? {
        if let range = AccessibilityRead.range(text, "AXVisibleCharacterRange", before: deadline),
           range.length > 0,
           range.length < characters,
           range.location + range.length <= characters {
            return NSRange(location: range.location, length: range.length)
        }
        guard ScreenGeometry.isUsable(content) else { return nil }
        let x = content.minX + Self.cornerInset
        guard let first = offset(in: text, at: CGPoint(x: x, y: content.minY + Self.cornerInset), before: deadline),
              let last = offset(in: text, at: CGPoint(x: x, y: content.maxY - Self.cornerInset), before: deadline),
              last >= first else { return nil }
        return NSRange(location: first, length: min(characters, last + 1) - first)
    }

    private func offset(in text: AXUIElement, at point: CGPoint, before deadline: Date) -> Int? {
        guard let argument = AccessibilityRead.argument(point),
              let range = AccessibilityRead.range(
                  text,
                  parameterized: "AXRangeForPosition",
                  argument: argument,
                  before: deadline
              ) else { return nil }
        return range.location
    }

    // MARK: - Reading by grid

    /// Ghostty's path. It answers no per-range bounds and no position-to-character mapping, so the
    /// viewport is worked out from the scroll area: total content height over line count is one
    /// row, and the scroll bar's value is the fraction of the overflow above the viewport.
    ///
    /// The buffer is never copied whole. `AXLineForIndex` maps a character offset to a row, and a
    /// binary search over it finds where the window's first and last rows begin -- fourteen
    /// messages each at 0.03 ms, constant however long the scrollback has grown. Reading `AXValue`
    /// instead would copy the entire scrollback on every poll.
    /// Where the viewport sits in the buffer, measured off the scroll area. The cheap half of the
    /// grid path, and the half the fingerprint is taken from.
    private struct Grid {
        let viewport: CGRect
        let rowHeight: CGFloat
        let offset: CGFloat
        let value: Double
        let lineCount: Int
        /// Which lines the viewport shows, for choosing what to scan.
        let visible: ClosedRange<Int>
        /// The grid the pane's own numbers gave up, and the line lengths it was worked out from.
        /// Present only once the sieve has settled; without it the rows below are lines, which is
        /// what this path assumed before any of them could be told apart.
        let inferred: (grid: TerminalGrid, lineLengths: [Int])?
        /// Which rows the viewport shows. Rows, not lines, so only present alongside `inferred`.
        let visibleRows: ClosedRange<Int>?
    }

    /// The grid the terminal published for this pane, or nil when nothing published one that can be
    /// shown to belong to it.
    ///
    /// Only Ghostty is asked. `ws_ypixel` is the padding-free height of the grid there, which is
    /// what makes the arithmetic exact, and that is a convention rather than a standard: a terminal
    /// that wrote the padded height instead would shift the bracket by a whole pixel once its
    /// padding passed about a cell and a half, and say nothing about having done so. Terminal.app
    /// and iTerm2 answer per-range bounds and never reach this code at all.
    ///
    /// One process owns every window, tab and split, and a pty for each. When it owns exactly one,
    /// there is nothing to match and that reading is this pane's. When it owns several, a reading is
    /// only accepted if the survivors agree about the cell, because two surfaces of one process can
    /// be at different font sizes and their pixel sizes are then identical while their grids are
    /// not. A buffer that fits its viewport adds the one discriminator that exists: its value is the
    /// screen, so its line count must be the terminal's row count.
    private func ptyCellGrid(
        viewport: CGRect,
        lineCount: Int,
        contentSize: CGSize,
        before deadline: Date
    ) -> TerminalCellGrid? {
        guard readingApp == .ghostty, let pid = reading else { return nil }
        guard let scale = Self.backingScale(of: viewport) else { return nil }
        let survey = ptyProbe.survey(of: pid, before: deadline)
        guard !survey.readings.isEmpty else { return nil }

        // A buffer that fits is the whole screen, so its lines are the terminal's rows. This is what
        // tells two same-sized surfaces apart, and it is exactly the case -- a full-screen program --
        // that has no other evidence in it.
        let fits = contentSize.height <= viewport.height + TerminalPeekPolicy.overflowTolerance
        let candidates = survey.readings
            .filter { !fits || $0.winsize.rows == lineCount }
            .compactMap { $0.winsize.grid(viewportSize: viewport.size, scale: scale) }
        guard let first = candidates.first else { return nil }
        // Agreement, not a vote: a disagreement means the pane could be either, and either is a
        // guess.
        guard candidates.allSatisfy({ abs($0.rowHeight - first.rowHeight) < 0.001 }) else { return nil }
        return first
    }

    /// The backing scale of the screen a pane is on. A window on a second display of a different
    /// scale has a different cell in pixels for the same font, so the scale is the window's rather
    /// than the main screen's.
    private static func backingScale(of viewport: CGRect) -> CGFloat? {
        guard let flip = ScreenGeometry.flipReference(screenFrames: NSScreen.screens.map(\.frame)) else {
            return nil
        }
        let appKit = ScreenGeometry.axToAppKit(viewport, flipReference: flip)
        let screen = NSScreen.screens.first { $0.frame.intersects(appKit) } ?? NSScreen.main
        return screen?.backingScaleFactor
    }

    /// The row height solved for a terminal, kept between runs.
    ///
    /// A row is as tall as the font the reader chose, so it outlives the window, the buffer and the
    /// process: measured unchanged across three viewport heights and every buffer length tried. Kept
    /// so the first diagram of a session is framed correctly rather than after whatever output
    /// happens to arrive next, and re-solved and overwritten whenever two readings say otherwise.
    private static func rememberedRowHeight(for terminal: TerminalApp) -> CGFloat? {
        let stored = UserDefaults.standard.double(forKey: rowHeightKey(terminal))
        guard stored > 0, TerminalPeekPolicy.rowHeightRange.contains(CGFloat(stored)) else { return nil }
        return CGFloat(stored)
    }

    private static func remember(_ rowHeight: CGFloat, for terminal: TerminalApp) {
        guard TerminalPeekPolicy.rowHeightRange.contains(rowHeight) else { return }
        UserDefaults.standard.set(Double(rowHeight), forKey: rowHeightKey(terminal))
    }

    private static func rowHeightKey(_ terminal: TerminalApp) -> String {
        "flowpeek.terminal.rowHeight.\(terminal.rawValue)"
    }

    private func grid(_ pane: Pane, characters: Int, before deadline: Date) -> Grid? {
        guard let scroll = pane.scroll,
              let contentSize = AccessibilityRead.size(scroll, "AXContentSize", before: deadline),
              let viewport = AccessibilityRead.rect(scroll, "AXFrame", before: deadline),
              let lastLine = line(of: characters - 1, in: pane.text, before: deadline) else { return nil }
        let lineCount = lastLine + 1
        // No scroll bar means nothing has scrolled off, and the offset is then zero whatever value
        // is assumed -- `scrollOffset` multiplies by an overflow of nothing. A bar with no readable
        // value is taken to be at the bottom, which is where a terminal sits unless someone moved it.
        let value = AccessibilityRead.element(scroll, "AXVerticalScrollBar", before: deadline)
            .flatMap { AccessibilityRead.double($0, kAXValueAttribute as String, before: deadline) } ?? 1
        let offset = TerminalPeekPolicy.scrollOffset(
            value: value,
            contentHeight: contentSize.height,
            viewportHeight: viewport.height
        )

        if let inferred = inferredGrid(
            pane,
            characters: characters,
            lineCount: lineCount,
            contentHeight: contentSize.height,
            viewport: viewport,
            before: deadline
        ), let rows = TerminalGridInference.visibleRows(
            offset: offset,
            viewportHeight: viewport.height,
            grid: inferred.grid,
            totalRows: TerminalGridInference.rowStarts(
                inferred.lineLengths,
                columns: inferred.grid.columns
            )[inferred.lineLengths.count]
        ), let first = TerminalGridInference.line(
            ofRow: rows.lowerBound,
            lineLengths: inferred.lineLengths,
            columns: inferred.grid.columns
        ), let last = TerminalGridInference.line(
            ofRow: rows.upperBound,
            lineLengths: inferred.lineLengths,
            columns: inferred.grid.columns
        ) {
            return Grid(
                viewport: viewport,
                rowHeight: inferred.grid.rowHeight,
                // The rows start below the pane's own padding, so the offset a row is placed
                // against is the scrolled distance less that padding.
                offset: offset - inferred.grid.topPadding,
                value: value,
                lineCount: inferred.lineLengths.count,
                visible: first...max(first, last),
                inferred: inferred,
                visibleRows: rows
            )
        }

        // What the terminal itself says, asked before anything is solved. Measured on Ghostty
        // 1.3.1: one ioctl answered a 16.000-point row where three readings of AXContentSize had
        // been needed to solve the same number, and it answers in a full-screen program, where
        // there is nothing to solve from at all.
        if let cell = ptyCellGrid(viewport: viewport, lineCount: lineCount, contentSize: contentSize, before: deadline) {
            guard let visible = TerminalPeekPolicy.visibleLines(
                offset: offset,
                viewportHeight: viewport.height,
                rowHeight: cell.rowHeight,
                lineCount: lineCount
            ) else { return nil }
            return Grid(
                viewport: viewport,
                rowHeight: cell.rowHeight,
                offset: offset - cell.topPadding,
                value: value,
                lineCount: lineCount,
                visible: visible,
                inferred: nil,
                visibleRows: nil
            )
        }

        // Two readings of the same pane solve the row height exactly, because the residual is the
        // same in both and cancels. Dividing the content height by the line count instead counts
        // that residual as rows: measured on Ghostty 1.3.1, half a point too tall per row, which is
        // a row and a half of error by the bottom of a full screen.
        let sample = TerminalRowMetrics.Sample(
            lineCount: lineCount,
            contentHeight: contentSize.height,
            viewportHeight: viewport.height
        )
        var solved: CGFloat?
        if let reading {
            if let previous = lastSamples[reading],
               let height = TerminalRowMetrics.rowHeight(previous, sample) {
                rowHeights[reading] = height
                if let app = readingApp { Self.remember(height, for: app) }
            }
            if sample.isUsable { lastSamples[reading] = sample }
            // A height solved for this pane, or one solved for this terminal in an earlier run. The
            // row is a property of the font rather than of the window: measured unchanged at three
            // viewport heights, so it is worth keeping and the residual is not.
            solved = rowHeights[reading] ?? readingApp.flatMap(Self.rememberedRowHeight(for:))
        }

        let rowHeight: CGFloat
        let topPadding: CGFloat
        if let solved, let residual = TerminalRowMetrics.residual(of: sample, rowHeight: solved) {
            rowHeight = solved
            topPadding = TerminalRowMetrics.topPadding(residual: residual)
        } else {
            // Nothing solved yet, and nothing remembered. The old division, which is right for a
            // pane whose residual is small and is the only answer available for the first reading
            // of a new one.
            // `solved` rather than this pane's own history: a buffer that fits its viewport says
            // nothing about the grid, and without the height carried over from an earlier window or
            // an earlier run there is nothing to draw from at all. That is the case the reader
            // meets most often -- a short diagram printed into a fresh window -- and it was silent.
            guard let measurement = TerminalPeekPolicy.rowHeight(
                contentHeight: contentSize.height,
                viewportHeight: viewport.height,
                lineCount: lineCount,
                remembered: solved
            ) else { return nil }
            rowHeight = measurement.height
            topPadding = 0
        }
        guard let visible = TerminalPeekPolicy.visibleLines(
            offset: offset,
            viewportHeight: viewport.height,
            rowHeight: rowHeight,
            lineCount: lineCount
        ) else { return nil }
        return Grid(
            viewport: viewport,
            rowHeight: rowHeight,
            // The rows start below whatever the pane puts above them, the same correction the
            // solved path above applies.
            offset: offset - topPadding,
            value: value,
            lineCount: lineCount,
            visible: visible,
            inferred: nil,
            visibleRows: nil
        )
    }

    /// The pane's grid, once its own numbers have narrowed to one answer.
    ///
    /// A terminal that answers nothing about where a character is drawn still reports how tall its
    /// content is, and that height is a fact about the rows the text occupies -- so the column count
    /// can be solved for. One look is not enough (a wrong column count explains one height as well
    /// as the right one does), so candidates are kept and sieved against every later look, and
    /// nothing is drawn from them until the survivors agree. See `TerminalGridInference`.
    ///
    /// The line lengths come from `AXValue`. Ghostty caps what it exposes at about 32,000
    /// characters and answered in 0.07 to 0.21 ms at every buffer size measured, up to 20,000 lines
    /// printed; the cap here is the same one the scanner refuses to look past, so a terminal that
    /// hands over an unbounded buffer is left to the path below rather than copied every poll.
    private func inferredGrid(
        _ pane: Pane,
        characters: Int,
        lineCount: Int,
        contentHeight: CGFloat,
        viewport: CGRect,
        before deadline: Date
    ) -> (grid: TerminalGrid, lineLengths: [Int])? {
        guard characters <= TerminalBufferScanner.maximumWindowCharacters,
              contentHeight > viewport.height + TerminalPeekPolicy.overflowTolerance,
              let pid = reading,
              let buffer = AccessibilityRead.string(pane.text, kAXValueAttribute as String, before: deadline)
        else { return nil }
        let lengths = TerminalGridInference.lineLengths(of: buffer)
        // The slice this path reads is cut with `AXLineForIndex`, so the terminal's lines and the
        // value's lines have to be the same lines. Ghostty's are: it counts whole lines in both,
        // and its buffer ends on a prompt rather than a newline, so the two counts match. A
        // terminal that counted rows there would report more of them than the value holds lines,
        // and its rows are already correct without any of this -- so it is left alone rather than
        // sliced with numbers from the wrong count.
        guard !lengths.isEmpty, lineCount <= lengths.count else { return nil }

        var candidates = (gridCandidates[pid] ?? []).filter {
            TerminalGridInference.explains(
                $0,
                contentHeight: contentHeight,
                viewportHeight: viewport.height,
                lineLengths: lengths
            )
        }
        // Nothing survived, so either this is the first look or the pane was resized or its font
        // changed. Either way the answer starts again from what is on screen now.
        if candidates.isEmpty {
            // With the row height already solved for this pane, the sieve only has to find the
            // column count, and the padding it has to tolerate can be what the pane really leaves:
            // Ghostty 1.3 leaves two rows of it, which is past what the blind limit allows.
            candidates = TerminalGridInference.candidates(
                contentHeight: contentHeight,
                viewportHeight: viewport.height,
                paneWidth: viewport.width,
                lineLengths: lengths,
                rowHeight: rowHeights[pid] ?? readingApp.flatMap(Self.rememberedRowHeight(for:))
            )
        }
        gridCandidates[pid] = candidates
        guard let grid = TerminalGridInference.agreed(candidates, lineLengths: lengths) else { return nil }
        return (grid, lengths)
    }

    private func gridRead(_ pane: Pane, grid: Grid, characters: Int, deadline: Date) -> [Located] {
        let first = max(0, grid.visible.lowerBound - Self.lineMargin)
        let last = min(grid.lineCount - 1, grid.visible.upperBound + Self.lineMargin)
        guard let start = index(ofLine: first, in: pane.text, characters: characters, before: deadline) else {
            return []
        }
        let end = last >= grid.lineCount - 1
            ? characters
            : (index(ofLine: last + 1, in: pane.text, characters: characters, before: deadline) ?? characters)
        guard end > start,
              let text = string(pane.text, in: NSRange(location: start, length: end - start), before: deadline)
        else { return [] }
        // With the grid known, the block's rows are counted from the line lengths -- a line wider
        // than the pane occupies as many rows as it wraps to -- and the on-screen test is rows
        // against rows.
        if let inferred = grid.inferred, let visibleRows = grid.visibleRows {
            return TerminalBufferScanner.blocks(in: text).compactMap { block in
                guard let rows = TerminalGridInference.rowSpan(
                    ofLines: (first + block.lines.lowerBound)...(first + block.lines.upperBound),
                    lineLengths: inferred.lineLengths,
                    columns: inferred.grid.columns
                ), rows.overlaps(visibleRows),
                    let rectangle = TerminalPeekPolicy.rowsRectangle(
                        lines: rows,
                        viewport: grid.viewport,
                        rowHeight: grid.rowHeight,
                        offset: grid.offset
                    ) else { return nil }
                return Located(block: block, rectangle: rectangle, content: grid.viewport)
            }
        }
        // Without it, the scanner counts newlines while this arithmetic wants whatever
        // `AXLineForIndex` counts, and adding `first` -- a number from the terminal -- to the
        // scanner's own line numbers mixed the two. The terminal is asked about the block's ends
        // directly instead, and the on-screen test compares its answers with its own visible range.
        return TerminalBufferScanner.blocks(in: text).compactMap { block in
            guard let rows = TerminalPeekPolicy.rows(
                ofBlockFrom: start + block.range.location,
                to: start + block.lastCharacter,
                line: { self.line(of: $0, in: pane.text, before: deadline) }
            ), rows.overlaps(grid.visible),
                let rectangle = TerminalPeekPolicy.rowsRectangle(
                    lines: rows,
                    viewport: grid.viewport,
                    rowHeight: grid.rowHeight,
                    offset: grid.offset
                ) else { return nil }
            return Located(block: block, rectangle: rectangle, content: grid.viewport)
        }
    }

    /// One look at a web view's row list.
    ///
    /// The cheap half is the whole viewport as one string: two marker calls, 0.33 ms measured, and
    /// -- unlike every other fingerprint in this file -- it is made of the text itself, so a
    /// repaint that leaves the geometry alone cannot hide behind it. That is the failure this
    /// route was built knowing about.
    private func rowsLook(_ pane: Pane, deadline: Date) -> Look? {
        var texts: [String] = []
        var frames: [CGRect] = []
        for list in pane.rowLists {
            guard let text = AccessibilityRead.markerText(list, before: deadline),
                  let frame = AccessibilityRead.rect(list, "AXFrame", before: deadline),
                  ScreenGeometry.isUsable(frame)
            else {
                // A list stopped answering, which is what a closed or replaced pane looks like.
                forgetPane()
                return nil
            }
            texts.append(text)
            frames.append(frame)
        }
        guard let first = frames.first else {
            forgetPane()
            return nil
        }
        // One fingerprint over every pane, joined on a character no terminal prints, so that two
        // panes swapping content cannot cancel out and a pane opening or closing is a change.
        let joined = texts.joined(separator: "\u{0}")
        let fingerprint = Fingerprint(
            characters: joined.utf16.count,
            content: frames.dropFirst().reduce(first) { $0.union($1) },
            visible: nil,
            scroll: nil,
            digest: joined.hashValue
        )
        if let shortcut = shortcut(for: fingerprint) { return shortcut }
        // Each pane's own frame, not the union: it is what the block's rectangle is clipped to, and
        // clipping one pane's diagram to both panes would let it run over its neighbour.
        let located = zip(pane.rowLists, frames).flatMap { list, frame in
            rowsRead(list, content: frame, deadline: deadline)
        }
        return located.isEmpty ? .nothing : .blocks(located)
    }

    /// Reads a web view's row list: one element per visible row, each answering for its own text
    /// and its own frame.
    ///
    /// The exact strategy of the three. A row's rectangle is measured rather than divided out of a
    /// content height, so nothing here can be wrong about how tall a row is -- and the rows the
    /// list holds are by construction the rows on screen, so there is no scroll offset to apply and
    /// no visible range to intersect.
    ///
    /// Read row by row rather than in one call, because the single call that returns the whole
    /// viewport returns it with no line breaks at all: the rows arrive concatenated, and
    /// `cat x` followed by a diagram came back as one 857-character line. Per row it is 2.45 ms
    /// measured against Orca, and the fingerprint above is what keeps that off an idle poll.
    private func rowsRead(_ list: AXUIElement, content: CGRect, deadline: Date) -> [Located] {
        guard let children = AccessibilityRead.attribute(
            list,
            kAXChildrenAttribute as String,
            before: deadline
        ) as? [AnyObject] else { return [] }
        let rows: [AXUIElement] = children
            .filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
            .map { unsafeDowncast($0, to: AXUIElement.self) }
        guard !rows.isEmpty else { return [] }
        let lines = rows.map { AccessibilityRead.markerText($0, before: deadline) ?? "" }
        let window = lines.joined(separator: "\n")
        guard !window.isEmpty else { return [] }
        let blocks = TerminalBufferScanner.blocks(in: window, visible: 0...(rows.count - 1))
        guard !blocks.isEmpty else { return [] }
        let width = content.minX...content.maxX
        return blocks.compactMap { block in
            guard block.lines.lowerBound >= 0, block.lines.upperBound < rows.count,
                  let first = AccessibilityRead.rect(rows[block.lines.lowerBound], "AXFrame", before: deadline),
                  let last = AccessibilityRead.rect(rows[block.lines.upperBound], "AXFrame", before: deadline),
                  let rectangle = TerminalPeekPolicy.band(from: first, to: last, across: width) else { return nil }
            return Located(block: block, rectangle: rectangle, content: content)
        }
    }

    private func line(of index: Int, in text: AXUIElement, before deadline: Date) -> Int? {
        guard index >= 0 else { return nil }
        return AccessibilityRead.number(
            text,
            parameterized: "AXLineForIndex",
            argument: NSNumber(value: index),
            before: deadline
        )
    }

    /// The first character offset that belongs to `line`, by binary search over `AXLineForIndex`.
    /// Returns the buffer's length when the line begins past its end, which is what a caller
    /// slicing to the end of the buffer wants.
    private func index(ofLine line: Int, in text: AXUIElement, characters: Int, before deadline: Date) -> Int? {
        guard line > 0 else { return 0 }
        var low = 0
        var high = characters - 1
        var answer = characters
        while low <= high {
            guard Date() < deadline else { return nil }
            let middle = low + (high - low) / 2
            guard let found = self.line(of: middle, in: text, before: deadline) else { return nil }
            if found >= line {
                answer = middle
                high = middle - 1
            } else {
                low = middle + 1
            }
        }
        return answer
    }

    // MARK: - The pane

    private struct Pane {
        let text: AXUIElement
        /// The scroll area around the text, where there is one. Both of the character-range
        /// strategies need it: the ranged one for the viewport rectangle, the grid one for the
        /// content size and the scroll bar.
        let scroll: AXUIElement?
        /// Every row list under the window, when the terminal publishes them -- empty for a native
        /// one, whose text is `text`.
        ///
        /// A list rather than the single `text` because a web-view terminal shows several panes in
        /// one window and each publishes its own: a split Orca window carries two, and reading only
        /// the first left the other one unframed.
        let rowLists: [AXUIElement]

        /// True when this pane is read from row elements rather than from a string with offsets --
        /// a different shape entirely.
        var isRowList: Bool { !rowLists.isEmpty }

        init(text: AXUIElement, scroll: AXUIElement?, rowLists: [AXUIElement] = []) {
            self.text = text
            self.scroll = scroll
            self.rowLists = rowLists
        }
    }

    /// How a terminal answers, from what it says it can answer. Deliberately not a per-terminal
    /// table: a terminal that gains `AXBoundsForRange` in a future version starts using the better
    /// path without FlowPeek being changed, and one that loses it stops drawing frames in the wrong
    /// place instead of drawing them from arithmetic that no longer holds.
    private enum Strategy {
        case ranged
        case grid
        /// One element per visible row, each answering for its own text and its own frame. No
        /// arithmetic: the rectangle a block occupies is measured rather than derived, so the
        /// mistakes the other two can make about row height cannot happen here.
        case rows
    }

    private func strategy(of text: AXUIElement, before deadline: Date) -> Strategy? {
        guard Date() < deadline else { return nil }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(text, &names) == .success,
              let available = names as? [String] else { return nil }
        if available.contains("AXBoundsForRange") { return .ranged }
        if available.contains("AXLineForIndex") { return .grid }
        return nil
    }

    /// The pane under the focused window, from the cache where the window has not changed.
    ///
    /// Held across polls because finding it costs a walk down the tree -- 0.6-0.8 ms of
    /// accessibility messages, measured in all three terminals -- and the answer only changes when
    /// the focused window does. A window that keeps its identity while replacing its text view
    /// would leave a dead element here; the caller drops the cache the moment it stops answering.
    private func pane(
        under window: AXUIElement,
        terminal: TerminalApp,
        before deadline: Date
    ) -> (pane: Pane, strategy: Strategy)? {
        if let cached, CFEqual(cached.window, window) { return (cached.pane, cached.strategy) }
        guard let pane = descend(
            to: window,
            isWebView: terminal.needsAccessibilityWarmUp,
            before: deadline
        ) else { return nil }
        for element in pane.rowLists.isEmpty ? [pane.text] : pane.rowLists {
            _ = AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        }
        // A row list advertises the same parameterized attributes as everything else in a Chromium
        // tree and answers none of them usefully, so what was found decides how it is read.
        let strategy: Strategy? = pane.isRowList ? .rows : strategy(of: pane.text, before: deadline)
        guard let strategy else { return nil }
        cached = (window, pane, strategy)
        return (pane, strategy)
    }

    /// The first text area under the window, and the scroll area it sits in. Measured: three levels
    /// down in Terminal.app, four in iTerm2 and Ghostty, always inside an `AXScrollArea` whose
    /// frame is the viewport.
    /// - Parameter isWebView: whether this terminal draws into a web view. It decides what the
    ///   descent is looking for, and how much of the tree it is worth walking: a native terminal
    ///   has one text area and stops at it, while a web view can hold several row lists and has to
    ///   be walked out to find them all.
    private func descend(to window: AXUIElement, isWebView: Bool, before deadline: Date) -> Pane? {
        var rowLists: [AXUIElement] = []
        var textArea: (element: AXUIElement, scroll: AXUIElement?)?
        var finished = false

        func walk(_ element: AXUIElement, depth: Int, limit: Int, scroll: AXUIElement?) {
            guard !finished, depth < limit, Date() < deadline else { return }
            let role = AccessibilityRead.string(element, kAXRoleAttribute as String, before: deadline)
            if role == "AXTextArea", textArea == nil {
                textArea = (element, scroll)
                // A native terminal's tree holds one text area and no row lists, so there is
                // nothing further to look for and the descent costs what it always did.
                if !isWebView { finished = true }
                return
            }
            // A web view's rows are a list, and every Electron window is full of lists, so the DOM
            // class is what identifies this one. Only asked for in a web view: it is one more
            // message per node, and a native terminal has no DOM to ask about.
            if isWebView, role == "AXList",
               AccessibilityRead.classList(element, before: deadline).contains(Self.rowListClass) {
                rowLists.append(element)
                // Its children are rows, not another pane.
                return
            }
            let scroll = role == "AXScrollArea" ? element : scroll
            // Chromium nests its content far deeper than a native view does -- Orca's row lists
            // measured twenty levels down -- so entering a web area buys the extra depth rather
            // than spending it on every window.
            let limit = role == "AXWebArea" ? depth + Self.webDescentLimit : limit
            guard let children = AccessibilityRead.attribute(
                element,
                kAXChildrenAttribute as String,
                before: deadline
            ) as? [AnyObject] else { return }
            for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                walk(unsafeDowncast(child, to: AXUIElement.self), depth: depth + 1, limit: limit, scroll: scroll)
            }
        }
        walk(window, depth: 0, limit: Self.descentLimit, scroll: nil)

        // A row list wins over a text area. A web view exposes text areas of its own -- xterm's
        // hidden helper textarea is one, and every search field in the window is another -- and
        // whichever the walk happened to reach first would otherwise decide how the terminal is
        // read. That it worked was an accident of tree order.
        if let first = rowLists.first {
            return Pane(text: first, scroll: nil, rowLists: rowLists)
        }
        guard let textArea else { return nil }
        return Pane(text: textArea.element, scroll: textArea.scroll)
    }

    private func string(_ text: AXUIElement, in range: NSRange, before deadline: Date) -> String? {
        guard let argument = AccessibilityRead.argument(range) else { return nil }
        return AccessibilityRead.string(
            text,
            parameterized: "AXStringForRange",
            argument: argument,
            before: deadline
        )
    }
}
