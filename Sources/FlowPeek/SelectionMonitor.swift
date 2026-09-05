@preconcurrency import AppKit
import ApplicationServices
import FlowPeekCore
import OSLog

@MainActor
final class SelectionMonitor {
    var onSelection: ((SelectionSnapshot) -> Void)?
    var onDismiss: (() -> Void)?
    /// True when a screen point lands on the overlay button. A global monitor should not see our own
    /// clicks, but a non-activating panel is exactly the case where that guarantee is worth checking.
    var isPointOnOverlay: ((CGPoint) -> Bool)?

    /// Cumulative 70/200/420/920/1820/3320 ms. A cold Chromium was measured at ~2.04 s to its first
    /// successful read, ~19 ms once warm; every rung exits the instant a read succeeds.
    static let settlingLadder = [70, 130, 220, 500, 900, 1500]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Selection")
    private let reader = AccessibilitySelectionReader()
    private var mouseUpMonitor: Any?
    private var dismissalMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var generation = 0
    /// Set while the left button is down on one of FlowPeek's own surfaces. A resize or a move of
    /// the preview ends its drag well outside that surface, so testing the release point was not
    /// enough -- the gesture has to be judged by where it began.
    private var dragBeganOnOwnWindow = false

    func start() {
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    // A drag that began on one of FlowPeek's own surfaces is not a text selection:
                    // resizing or moving the preview used to end here as a capture, which reported a
                    // selection change and closed the very panel being resized.
                    let ownGesture = self.dragBeganOnOwnWindow || OwnWindowHitTest.contains(location)
                    self.dragBeganOnOwnWindow = false
                    guard !ownGesture else { return }
                    self.captureAfterSettling()
                }
            })
        }
        if dismissalMonitor == nil {
            dismissalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.scrollWheel, .rightMouseDown, .otherMouseDown, .leftMouseDown]
            ) { [weak self] event in
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    let onOwnWindow = OwnWindowHitTest.contains(location)
                    if event.type == .leftMouseDown { self.dragBeganOnOwnWindow = onOwnWindow }
                    if event.type == .leftMouseDown, self.isPointOnOverlay?(location) == true { return }
                    // Scrolling or clicking inside a FlowPeek surface is interaction with FlowPeek,
                    // never a reason to take its own overlay away.
                    if onOwnWindow { return }
                    self.dismissOverlay(reason: Self.reason(for: event.type))
                }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                if event.keyCode == 53 { self?.cancelPendingCapture(reason: "escape") }
                return event
            }
        }
        if globalKeyMonitor == nil {
            // The overlay is a non-activating panel, so a local monitor alone can never see Escape.
            // Only the key code is read here; nothing about the keystroke is retained or logged.
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                let isEscape = event.keyCode == 53
                Task { @MainActor in
                    guard let self else { return }
                    // Typing destroys the selection the button belongs to, so the button goes too.
                    if isEscape { self.cancelPendingCapture(reason: "escape") } else { self.dismissOverlay(reason: "typing") }
                }
            }
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleIdentifier = app?.bundleIdentifier
                let pid = app?.processIdentifier
                Task { @MainActor in self?.applicationDidActivate(bundleIdentifier: bundleIdentifier, pid: pid) }
            }
        }
        if terminationObserver == nil {
            terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor in
                    if let pid { self?.reader.forget(pid) }
                }
            }
        }
        logger.info("Selection monitoring started; mouse-up monitor: \(self.mouseUpMonitor != nil)")
    }

    private static func reason(for type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: "click"
        case .scrollWheel: "scroll"
        default: "input"
        }
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
        mouseUpMonitor = nil
        dismissalMonitor = nil
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        globalKeyMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        reader.releaseAccessibilityTrees()
        generation += 1
    }

    /// Hides the overlay without invalidating an in-flight capture — an app activating, or a scroll,
    /// must not silently cancel the read the user's own click just started.
    private func dismissOverlay(reason: String) {
        logger.debug("dismiss overlay (\(reason, privacy: .public))")
        onDismiss?()
    }

    private func cancelPendingCapture(reason: String) {
        generation += 1
        logger.debug("capture cancelled (\(reason, privacy: .public)); generation now \(self.generation)")
        onDismiss?()
    }

    private func applicationDidActivate(bundleIdentifier: String?, pid: pid_t?) {
        if let bundleIdentifier, bundleIdentifier == Bundle.main.bundleIdentifier {
            logger.debug("ignoring self-activation")
            return
        }
        dismissOverlay(reason: "app activated")
        if let pid { reader.warmUp(pid) }
    }

    private func captureAfterSettling() {
        generation += 1
        let current = generation
        let mouseLocation = NSEvent.mouseLocation
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (rung, delay) in Self.settlingLadder.enumerated() {
                try? await Task.sleep(for: .milliseconds(delay))
                guard current == generation else {
                    logger.debug("capture #\(current) superseded by generation \(self.generation) at rung \(rung)")
                    return
                }
                guard AXIsProcessTrusted() else {
                    logger.debug("capture #\(current) aborted at rung \(rung): process is not accessibility-trusted")
                    return
                }
                logger.debug("capture #\(current) rung \(rung) (+\(delay) ms)")
                if let snapshot = reader.currentSelection(at: mouseLocation) {
                    logger.debug("Captured \(snapshot.text.count) selected characters from \(snapshot.applicationName ?? "unknown", privacy: .public) at rung \(rung)")
                    onSelection?(snapshot)
                    return
                }
            }
            logger.debug("No accessible text selection was found after mouse-up (capture #\(current))")
            // The previous selection is gone — a drag that collapsed it, or a click that cleared it —
            // so the button that belonged to it has to go too.
            onDismiss?()
        }
    }
}

/// Chromium and Electron expose a tree of empty groups until `AXManualAccessibility` is set on the
/// application element, and switch their renderers over asynchronously afterwards -- so this is
/// done when an app activates and memoised per pid rather than repeated on every read. A refusal is
/// memoised too, for `AccessibilityWarmUpMemo.retryInterval` rather than for good: every app that is
/// not Chromium refuses this each time it is asked, and one that was still starting its renderer
/// answers differently a moment later.
///
/// One instance for the whole app, because both routes into a preview need the same processes warm
/// and the switch is one shared boolean per target: a per-route memo would let the selection route
/// turn a tree off while the ambient route still believed it was on. The memo is only a way of not
/// repeating one message, never a claim about who owns the switch -- `release()` is called when the
/// selection monitor stops, which is not the same moment the ambient monitor stops, and each
/// ambient read warms the app it is about to read for exactly that reason.
@MainActor
final class AccessibilityTreeWarmUp {
    static let shared = AccessibilityTreeWarmUp()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Selection")
    private var memo = AccessibilityWarmUpMemo()

    /// `deadline` is the clock of the read this is warming for, when there is one. The set is a
    /// synchronous message like every other, so it may not spend more of that read than the read
    /// has left: an app that answers only once its own timeout expires would otherwise stall here
    /// for that timeout and then be handed a whole fresh budget to stall in again.
    func warmUp(_ pid: pid_t, before deadline: Date = .distantFuture) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = Date()
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0, memo.shouldSend(pid: pid, now: now) else { return }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, min(AccessibilitySelectionReader.messagingTimeout, Float(remaining)))
        let error = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        logger.debug(
            "AXManualAccessibility enabled for pid \(pid) -> \(AccessibilitySelectionReader.name(error), privacy: .public)"
        )
        // A set that landed is remembered for good; one that did not is remembered for the memo's
        // retry window. Remembering a refusal as a success would leave a busy app showing a tree of
        // empty groups for the rest of its life while both routes believed it was awake -- and not
        // remembering it at all sends the same doomed message on every single read, which is the
        // answer every app that is not Chromium gives.
        memo.note(pid: pid, succeeded: error == .success, now: now)
    }

    func forget(_ pid: pid_t) {
        let wasEnabled = memo.isEnabled(pid: pid)
        memo.forget(pid: pid)
        if wasEnabled { logger.debug("pruned accessibility memo for terminated pid \(pid)") }
    }

    func release() {
        for pid in memo.drain() {
            _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
    }
}

@MainActor
final class AccessibilitySelectionReader {
    /// The system default was measured at ~1.52 s per call; a wedged target app blocked one full read for
    /// 4.58 s, which outlives several rungs of the settling ladder.
    static let messagingTimeout: Float = 0.2
    /// Wall-clock budget for one `currentSelection` pass, checked between candidates and ancestor hops.
    static let attemptBudget: TimeInterval = 0.75
    private static let ancestorHopLimit = 24
    private static let webAreaSearchLimit = 400

    fileprivate let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Selection")
    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }()

    // MARK: - Accessibility tree lifecycle

    func warmUp(_ pid: pid_t, before deadline: Date = .distantFuture) {
        AccessibilityTreeWarmUp.shared.warmUp(pid, before: deadline)
    }

    func forget(_ pid: pid_t) { AccessibilityTreeWarmUp.shared.forget(pid) }

    func releaseAccessibilityTrees() { AccessibilityTreeWarmUp.shared.release() }

    // MARK: - Reading

    func currentSelection(at mouseLocation: CGPoint) -> SelectionSnapshot? {
        let running = NSWorkspace.shared.frontmostApplication
        let pid = running?.processIdentifier ?? 0
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            logger.debug("skipping read: FlowPeek is frontmost")
            return nil
        }
        guard pid > 0 else {
            logger.debug("skipping read: no frontmost application")
            return nil
        }

        let deadline = Date().addingTimeInterval(Self.attemptBudget)
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        warmUp(pid, before: deadline)

        let flip = ScreenGeometry.flipReference(screenFrames: NSScreen.screens.map(\.frame))
        let provider = AXProbe(reader: self, application: app, flipReference: flip, deadline: deadline)
        let candidates = SelectionGatherer.candidates(
            using: provider,
            mouseLocation: mouseLocation,
            deadline: deadline,
            hopLimit: Self.ancestorHopLimit
        ) { rect in
            guard let flip, ScreenGeometry.isUsable(rect) else { return nil }
            return ScreenGeometry.axToAppKit(rect, flipReference: flip)
        }

        guard let best = SelectionCandidateScoring.best(from: candidates, mouseLocation: mouseLocation) else {
            logger.debug("no candidate produced selected text in \(running?.localizedName ?? "unknown", privacy: .public)")
            return nil
        }
        logger.debug("selected candidate \(best.kind.description, privacy: .public) with \(best.text.count) characters out of \(candidates.count) candidate(s)")
        return SelectionSnapshot(
            text: best.text,
            screenBounds: best.bounds,
            applicationName: running?.localizedName,
            processIdentifier: pid,
            anchorPoint: mouseLocation
        )
    }

    /// Marker range first: Chromium and Electron answer `AXSelectedTextMarkerRange` while their
    /// `kAXSelectedText` is empty or wrong. Native views simply report the attribute as unsupported.
    fileprivate func probe(_ element: AXUIElement, kind: SelectionCandidateKind, depth: Int) -> ProbedSelection? {
        let role = depth == 0 ? (copyString(element, kAXRoleAttribute) ?? "?") : "-"
        let web = webSelection(from: element)
        let native = web.result == nil ? nativeSelection(from: element) : (result: nil, status: AXError.success)
        let found = web.result ?? native.result
        if depth == 0 || found != nil {
            logger.debug(
                """
                candidate \(kind.description, privacy: .public) depth \(depth) role=\(role, privacy: .public) \
                marker=\(Self.name(web.status), privacy: .public) selectedText=\(Self.name(native.status), privacy: .public) \
                len=\(found?.text.count ?? 0)
                """
            )
        }
        return found
    }

    private func nativeSelection(from element: AXUIElement) -> (result: ProbedSelection?, status: AXError) {
        var selectedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedValue)
        var text: String?
        if status == .success {
            text = selectedValue as? String
            if text == nil, let attributed = selectedValue as? NSAttributedString { text = attributed.string }
        }

        var rangeValue: CFTypeRef?
        var bounds: CGRect?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue {
            if text?.isEmpty != false {
                text = stringForRange(element: element, rangeValue: rangeValue)
                    ?? stringFromValueAndRange(element: element, rangeValue: rangeValue)
            }
            var boundsValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &boundsValue
            ) == .success {
                bounds = Self.rect(from: boundsValue)
            }
        }
        guard let text, !text.isEmpty else { return (nil, status) }
        return (ProbedSelection(text: text, bounds: bounds), status)
    }

    private func webSelection(from element: AXUIElement) -> (result: ProbedSelection?, status: AXError) {
        var marker: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker)
        guard status == .success, let marker else { return (nil, status) }

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            marker,
            &stringValue
        ) == .success, let text = stringValue as? String, !text.isEmpty else { return (nil, status) }

        var boundsValue: CFTypeRef?
        var bounds: CGRect?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            marker,
            &boundsValue
        ) == .success {
            bounds = Self.rect(from: boundsValue)
        }
        return (ProbedSelection(text: text, bounds: bounds), status)
    }

    /// `kAXFocusedWindow` → first descendant whose role is `AXWebArea`, breadth-first.
    fileprivate func focusedWebArea(of app: AXUIElement, deadline: Date) -> AXUIElement? {
        guard let window = copyElement(app, kAXFocusedWindowAttribute) else {
            logger.debug("web-area fallback: no focused window")
            return nil
        }
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < Self.webAreaSearchLimit, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1
            if copyString(element, kAXRoleAttribute) == "AXWebArea" {
                logger.debug("web-area fallback: found AXWebArea after \(visited) node(s)")
                return element
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let array = children as? [AnyObject] {
                for child in array where CFGetTypeID(child) == AXUIElementGetTypeID() {
                    queue.append(unsafeDowncast(child, to: AXUIElement.self))
                }
            }
        }
        logger.debug("web-area fallback: no AXWebArea in \(visited) node(s)")
        return nil
    }

    fileprivate func elementAtPosition(_ point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard status == .success, let hit else {
            logger.debug("hit-test at position failed -> \(Self.name(status), privacy: .public)")
            return nil
        }
        _ = AXUIElementSetMessagingTimeout(hit, Self.messagingTimeout)
        return hit
    }

    /// `AXStringForRange` is the attribute a terminal or a custom text view answers when it keeps no
    /// `AXSelectedText` of its own; slicing `AXValue` is the last resort behind it.
    private func stringForRange(element: AXUIElement, rangeValue: CFTypeRef) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else { return nil }
        let text = (value as? String) ?? (value as? NSAttributedString)?.string
        return (text?.isEmpty == false) ? text : nil
    }

    private func stringFromValueAndRange(element: AXUIElement, rangeValue: CFTypeRef) -> String? {
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(rangeValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0 else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        let fullText = (value as? String) ?? (value as? NSAttributedString)?.string
        guard let fullText else { return nil }
        let nsRange = NSRange(location: range.location, length: range.length)
        guard NSMaxRange(nsRange) <= (fullText as NSString).length else { return nil }
        return (fullText as NSString).substring(with: nsRange)
    }

    // MARK: - Typed CF access

    fileprivate func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func rect(from value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    fileprivate static func name(_ error: AXError) -> String {
        switch error {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        case .invalidUIElement: "invalidUIElement"
        case .invalidUIElementObserver: "invalidUIElementObserver"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .actionUnsupported: "actionUnsupported"
        case .notificationUnsupported: "notificationUnsupported"
        case .notImplemented: "notImplemented"
        case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
        case .notificationNotRegistered: "notificationNotRegistered"
        case .apiDisabled: "apiDisabled"
        case .noValue: "noValue"
        case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: "notEnoughPrecision"
        @unknown default: "error(\(error.rawValue))"
        }
    }
}

/// Binds `SelectionGatherer`'s abstract probe to the real accessibility API. Every AX call lives on
/// this side of the protocol so the gatherer's ordering, budget and fallback branches stay testable.
@MainActor
private final class AXProbe: AccessibilityProbing {
    typealias Element = AXUIElement

    private unowned let reader: AccessibilitySelectionReader
    private let application: AXUIElement
    private let flipReference: CGFloat?
    private let deadline: Date

    init(reader: AccessibilitySelectionReader, application: AXUIElement, flipReference: CGFloat?, deadline: Date) {
        self.reader = reader
        self.application = application
        self.flipReference = flipReference
        self.deadline = deadline
    }

    func hitTest(at point: CGPoint) -> AXUIElement? {
        guard let flipReference else { return nil }
        return reader.elementAtPosition(ScreenGeometry.appKitToAX(point, flipReference: flipReference))
    }

    func focusedElement() -> AXUIElement? { reader.copyElement(application, kAXFocusedUIElementAttribute) }
    func applicationElement() -> AXUIElement { application }
    func parent(of element: AXUIElement) -> AXUIElement? { reader.copyElement(element, kAXParentAttribute) }
    func isSame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }

    func selection(in element: AXUIElement, kind: SelectionCandidateKind, depth: Int) -> ProbedSelection? {
        reader.probe(element, kind: kind, depth: depth)
    }

    func focusedWebArea() -> AXUIElement? { reader.focusedWebArea(of: application, deadline: deadline) }
    func now() -> Date { Date() }
    func log(_ message: String) { reader.logger.debug("\(message, privacy: .public)") }
}
