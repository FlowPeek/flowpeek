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

    /// Option alone. macOS itself uses a held Option to reveal alternatives, and pairing it with
    /// Space means the peek chord can never be mistaken for typing a space.
    static let modifier: NSEvent.ModifierFlags = .option
    static let peekKeyCode: UInt16 = 49
    /// Compared against these alone: caps lock, the function flag and the numeric-pad flag ride
    /// along on real events and would break an equality test against the whole mask.
    private static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private static let descentNodeLimit = 400
    private static let descentDepthLimit = 12
    /// Five levels reached the whole page in measurement; four keeps the climb inside a block.
    private static let ancestorLimit = 4
    /// Two pieces on the same visual line differed by well under a point; a new line differs by a
    /// full line height.
    private static let lineTolerance: CGFloat = 3
    private static let messagingTimeout: Float = 0.25

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Ambient")
    private var flagsMonitor: Any?
    private var moveMonitor: Any?
    private var keyMonitor: Any?
    private var isEngaged = false
    private var lastPointer: CGPoint?
    private var lastRead: Date?
    private var showing = false
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
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let isPeek = event.keyCode == Self.peekKeyCode
                && event.modifierFlags.intersection(Self.significantModifiers) == Self.modifier
            Task { @MainActor in if isPeek { self?.activate() } }
        }
        logger.info("ambient peek armed")
    }

    func stop() {
        [flagsMonitor, moveMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        flagsMonitor = nil
        moveMonitor = nil
        keyMonitor = nil
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

    private func activate() {
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
        lastRead = now

        guard AXIsProcessTrusted() else { return }
        guard let candidate = read(at: pointer) else {
            retire()
            return
        }
        showing = true
        onCandidate?(candidate)
    }

    // MARK: - Reading

    private func read(at pointer: CGPoint) -> AmbientCandidate? {
        let frames = NSScreen.screens.map(\.frame)
        guard let flip = ScreenGeometry.flipReference(screenFrames: frames) else { return nil }
        let application = NSWorkspace.shared.frontmostApplication
        guard application?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        var hit: AXUIElement?
        let axPoint = ScreenGeometry.appKitToAX(pointer, flipReference: flip)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit else { return nil }
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
            defer { cursor = parent(of: element) }
            guard let axFrame = rect(element, "AXFrame") else { continue }
            let bounds = ScreenGeometry.axToAppKit(axFrame, flipReference: flip)
            // Cheap rejection before the descent, which is the expensive half. Once an ancestor is
            // too big to be a code block, every further ancestor is too, so stop.
            guard AmbientPeekPolicy.isPlausible(bounds: bounds, screen: screen) else { break }

            guard let text = text(under: element) else { continue }
            if let candidate = AmbientPeekPolicy.candidate(
                text: text,
                bounds: bounds,
                screen: screen,
                applicationName: application?.localizedName
            ) { return candidate }
        }
        return nil
    }

    /// Rebuilds lines from the pieces' own frames. Joining every piece with a newline splits a
    /// line that arrives as several pieces -- two, in the measured case -- and mermaid then fails
    /// mid-statement. Pieces sharing a baseline are one line; a new baseline starts a new one.
    private func text(under element: AXUIElement) -> String? {
        var pieces: [(text: String, frame: CGRect?)] = []
        var visited = 0
        collectText(element, depth: 0, visited: &visited, into: &pieces)
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
    /// the hit-test returns, so the walk has to go down. Bounded on both node count and depth: a
    /// deep subtree must never stall the pointer. Each piece's frame comes back with it, because
    /// the frames are what make line reconstruction possible.
    ///
    /// A node that carries text of its own is a leaf for this walk. An editable code block exposes
    /// its whole content as the `AXTextArea`'s `AXValue` *and* re-exposes the same content as
    /// syntax-highlighted `AXStaticText` descendants; collecting both concatenates the diagram to
    /// itself, and mermaid then fails on the second starter. Measured on mermaid.ai's own docs: one
    /// `AXTextArea` yielded 884 characters, which is the 442-character diagram exactly twice.
    private func collectText(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        into pieces: inout [(text: String, frame: CGRect?)]
    ) {
        guard visited < Self.descentNodeLimit, depth < Self.descentDepthLimit else { return }
        visited += 1
        if let role = string(element, kAXRoleAttribute as String),
           role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField",
           let text = string(element, kAXValueAttribute as String),
           !text.isEmpty {
            pieces.append((text, rect(element, "AXFrame")))
            return
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let array = children as? [AnyObject] else { return }
        for child in array where CFGetTypeID(child) == AXUIElementGetTypeID() {
            collectText(unsafeDowncast(child, to: AXUIElement.self), depth: depth + 1, visited: &visited, into: &pieces)
        }
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private func rect(_ element: AXUIElement, _ attribute: String) -> CGRect? {
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
