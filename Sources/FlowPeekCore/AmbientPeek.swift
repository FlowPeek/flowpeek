import CoreGraphics
import Foundation

/// What the ambient overlay found under the pointer.
public struct AmbientCandidate: Equatable, Sendable {
    /// What `bounds` is a rectangle around. Normally the block the pointer is on. An editor that
    /// exposes only its focused document -- VS Code, and Electron apps generally -- cannot say
    /// which line the pointer is over, so the diagram is taken from the caret instead and the
    /// rectangle is the caret's line or the pane around it. The hint has to say so rather than let
    /// the frame imply it is drawn around the diagram.
    public enum Anchor: Equatable, Sendable {
        case pointer
        case caret
    }

    public let text: String
    public let detection: MermaidDetection
    /// Screen rectangle in AppKit coordinates, already flipped from the accessibility frame.
    public let bounds: CGRect
    public let applicationName: String?
    public let anchor: Anchor

    public init(
        text: String,
        detection: MermaidDetection,
        bounds: CGRect,
        applicationName: String?,
        anchor: Anchor = .pointer
    ) {
        self.text = text
        self.detection = detection
        self.bounds = bounds
        self.applicationName = applicationName
        self.anchor = anchor
    }
}

/// The rules for when the ambient overlay may appear, and when a fresh read is worth its cost.
/// Pure so the debouncing and the plausibility limits can be tested without a display or an
/// accessibility target.
public enum AmbientPeekPolicy {
    /// A hit-test plus a bounded descent measured 19-31 ms in Chrome, VS Code and an Electron app.
    /// Re-reading faster than this buys nothing and keeps the main actor busy while the pointer moves.
    public static let debounce: TimeInterval = 0.15

    /// How far the pointer must travel before the previous answer is considered stale. Under this,
    /// the pointer is still inside the element that was just read.
    public static let movementThreshold: CGFloat = 8

    /// Wall clock for one whole read, checked before every accessibility call. The read itself
    /// measures 19-31 ms, so this is not a budget an ordinary app can spend; it exists because an
    /// app that is busy or beachballing answers each call only when its messaging timeout expires,
    /// and 400 nodes of that is minutes of frozen pointer rather than a slow outline.
    public static let readBudget: TimeInterval = 0.2

    /// Only `.likely` or better raises an outline. A `.weak` match is the kind of thing that fires on
    /// prose containing the word "graph", and an outline that appears over ordinary text is worse
    /// than one that never appears.
    public static let minimumConfidence: MermaidDetection.Confidence = .likely

    /// Rectangles outside this range are not code blocks: a sliver cannot hold a diagram, and
    /// something the size of a window is a container that happens to carry text.
    public static let minimumSize = CGSize(width: 80, height: 24)
    public static let maximumAreaFraction: CGFloat = 0.55

    /// A block bigger than this is almost certainly a whole document rather than one diagram, and
    /// outlining it would frame the entire page.
    public static let maximumCharacters = 8_000

    public static func shouldRead(
        pointer: CGPoint,
        lastPointer: CGPoint?,
        now: Date,
        lastRead: Date?
    ) -> Bool {
        if let lastRead, now.timeIntervalSince(lastRead) < debounce { return false }
        guard let lastPointer else { return true }
        return hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y) >= movementThreshold
    }

    /// Whether a rectangle is a plausible outline target on a screen of the given size.
    public static func isPlausible(bounds: CGRect, screen: CGSize) -> Bool {
        guard ScreenGeometry.isUsable(bounds) else { return false }
        guard bounds.width >= minimumSize.width, bounds.height >= minimumSize.height else { return false }
        guard screen.width > 0, screen.height > 0 else { return false }
        let area = bounds.width * bounds.height
        return area <= screen.width * screen.height * maximumAreaFraction
    }

    /// Which app to stop reading from, and for how long. One wedged application should cost the
    /// pointer a few stalls, not a stall every time the pointer moves over it while Option is down.
    ///
    /// The window is a clock rather than "until it activates again": a beachballing app is normally
    /// the frontmost one already, so waiting for an activation would either never lift or lift on
    /// the first click somewhere else and change nothing.
    public struct ReadBackoff: Equatable, Sendable {
        public static let strikesBeforeBackoff = 3
        public static let window: TimeInterval = 10

        private var strikes: [pid_t: Int] = [:]
        private var suppressed: [pid_t: Date] = [:]

        public init() {}

        public func isSuppressed(pid: pid_t, now: Date) -> Bool {
            guard let until = suppressed[pid] else { return false }
            return now < until
        }

        /// A read that ran out of budget. Returns whether that tipped this app into the backoff.
        @discardableResult
        public mutating func noteAbandoned(pid: pid_t, now: Date) -> Bool {
            suppressed = suppressed.filter { $0.value > now }
            let count = (strikes[pid] ?? 0) + 1
            guard count >= Self.strikesBeforeBackoff else {
                strikes[pid] = count
                return false
            }
            strikes[pid] = nil
            suppressed[pid] = now.addingTimeInterval(Self.window)
            return true
        }

        /// Any read that finished inside its budget clears the app's record: an app that was busy
        /// for a moment is not an app to give up on.
        public mutating func noteCompleted(pid: pid_t) {
            strikes[pid] = nil
            suppressed[pid] = nil
        }
    }

    /// The single decision the coordinator needs: is this read worth showing?
    public static func candidate(
        text: String,
        bounds: CGRect,
        screen: CGSize,
        applicationName: String?
    ) -> AmbientCandidate? {
        guard text.count <= maximumCharacters else { return nil }
        guard isPlausible(bounds: bounds, screen: screen) else { return nil }
        let detection = MermaidDetector.detect(text)
        guard detection.confidence >= minimumConfidence else { return nil }
        return AmbientCandidate(
            text: text,
            detection: detection,
            bounds: bounds,
            applicationName: applicationName
        )
    }

    /// The same decision for a diagram already sliced out of a document. The slicer has run the
    /// detector to find the block at all, and running it a second time on the way out is work for
    /// nothing -- the caret route tries several rectangles before one is drawable.
    public static func candidate(
        slice: CaretDiagramSlice,
        bounds: CGRect,
        screen: CGSize,
        applicationName: String?
    ) -> AmbientCandidate? {
        guard slice.text.count <= maximumCharacters else { return nil }
        guard isPlausible(bounds: bounds, screen: screen) else { return nil }
        guard slice.detection.confidence >= minimumConfidence else { return nil }
        return AmbientCandidate(
            text: slice.text,
            detection: slice.detection,
            bounds: bounds,
            applicationName: applicationName,
            anchor: .caret
        )
    }

    /// Grows a rectangle about its centre until it is at least big enough to draw.
    ///
    /// The caret route has nothing block-shaped to offer: the caret's own line measured 1078x18,
    /// and `minimumSize` is 24 points tall, so every rectangle the editor answers with would be
    /// refused and the outline would never appear. Growing it keeps the line it frames and leaves
    /// the plausibility limits -- which is what stops a whole window being outlined -- untouched.
    public static func grownToMinimum(_ bounds: CGRect) -> CGRect {
        guard ScreenGeometry.isUsable(bounds) else { return bounds }
        let width = max(bounds.width, minimumSize.width)
        let height = max(bounds.height, minimumSize.height)
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}
