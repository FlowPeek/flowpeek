import CoreGraphics
import Foundation

/// What the ambient overlay found under the pointer.
public struct AmbientCandidate: Equatable, Sendable {
    public let text: String
    public let detection: MermaidDetection
    /// Screen rectangle in AppKit coordinates, already flipped from the accessibility frame.
    public let bounds: CGRect
    public let applicationName: String?

    public init(text: String, detection: MermaidDetection, bounds: CGRect, applicationName: String?) {
        self.text = text
        self.detection = detection
        self.bounds = bounds
        self.applicationName = applicationName
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
}
