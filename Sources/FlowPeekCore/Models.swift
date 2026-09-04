import CoreGraphics
import Foundation

public struct SelectionSnapshot: Equatable, Sendable {
    public let text: String
    public let screenBounds: CGRect?
    public let applicationName: String?
    public let processIdentifier: pid_t
    public let capturedAt: Date
    /// Mouse-up location in AppKit screen coordinates, captured at gesture time rather than re-read later.
    public let anchorPoint: CGPoint

    public init(
        text: String,
        screenBounds: CGRect?,
        applicationName: String?,
        processIdentifier: pid_t,
        capturedAt: Date = .now,
        anchorPoint: CGPoint = .zero
    ) {
        self.text = text
        self.screenBounds = screenBounds
        self.applicationName = applicationName
        self.processIdentifier = processIdentifier
        self.capturedAt = capturedAt
        self.anchorPoint = anchorPoint
    }
}

/// Where a selection candidate came from, in descending order of trust.
public enum SelectionCandidateKind: Int, CaseIterable, Comparable, Sendable, CustomStringConvertible {
    case hitTest = 0
    case webArea = 1
    case focused = 2
    case application = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .hitTest: "hit-test"
        case .webArea: "web-area"
        case .focused: "focused"
        case .application: "application"
        }
    }
}

public struct SelectionCandidate: Equatable, Sendable {
    public let kind: SelectionCandidateKind
    public let text: String
    public let bounds: CGRect?

    public init(kind: SelectionCandidateKind, text: String, bounds: CGRect?) {
        self.kind = kind
        self.text = text
        self.bounds = bounds
    }
}

/// Picks between the selections reported by the hit-tested, focused, web-area and application elements.
/// Length is the primary signal; containing the mouse point is worth `containmentBonus` characters;
/// the candidate kind only breaks exact ties.
public enum SelectionCandidateScoring {
    public static let containmentBonus = 512
    public static let maximumLengthWeight = 4096
    public static let containmentTolerance: CGFloat = 4

    public static func score(
        _ candidate: SelectionCandidate,
        mouseLocation: CGPoint,
        tolerance: CGFloat = containmentTolerance
    ) -> Int {
        let length = min(candidate.text.count, maximumLengthWeight)
        let containment = contains(candidate.bounds, mouseLocation, tolerance: tolerance) ? containmentBonus : 0
        let priority = SelectionCandidateKind.application.rawValue - candidate.kind.rawValue
        return length + containment + priority
    }

    public static func best(
        from candidates: [SelectionCandidate],
        mouseLocation: CGPoint,
        tolerance: CGFloat = containmentTolerance
    ) -> SelectionCandidate? {
        var winner: (candidate: SelectionCandidate, score: Int)?
        for candidate in candidates where !candidate.text.isEmpty {
            let value = score(candidate, mouseLocation: mouseLocation, tolerance: tolerance)
            if winner == nil || value > winner!.score { winner = (candidate, value) }
        }
        return winner?.candidate
    }

    public static func contains(_ rect: CGRect?, _ point: CGPoint, tolerance: CGFloat = containmentTolerance) -> Bool {
        guard let rect, ScreenGeometry.isUsable(rect) else { return false }
        return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
}

/// Screen-space math shared by the AX reader and the overlay. Pure so it can be tested without a display.
public enum ScreenGeometry {
    /// AppKit's global origin is the bottom-left of the screen at (0, 0) — which is *not* guaranteed to be
    /// `NSScreen.screens.first`. Flipping to/from AX (top-left, y-down) uses that screen's `maxY`.
    public static func flipReference(screenFrames: [CGRect]) -> CGFloat? {
        if let primary = screenFrames.first(where: { $0.origin == .zero }) { return primary.maxY }
        return screenFrames.map(\.maxY).max()
    }

    public static func appKitToAX(_ point: CGPoint, flipReference: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: flipReference - point.y)
    }

    public static func axToAppKit(_ rect: CGRect, flipReference: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: flipReference - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func isUsable(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return false }
        return !rect.isEmpty && !rect.isNull && !rect.isInfinite
    }

    /// Clamps a window origin so the whole window stays inside one screen's visible frame.
    /// Every screen is considered: the one already containing the window wins, otherwise the one it
    /// overlaps most, otherwise the one whose centre is nearest.
    public static func clamp(
        origin: CGPoint,
        size: CGSize,
        visibleFrames: [CGRect],
        inset: CGFloat = 8
    ) -> CGPoint {
        guard !visibleFrames.isEmpty else { return origin }
        let rect = CGRect(origin: origin, size: size)
        if visibleFrames.contains(where: { $0.contains(rect) }) { return origin }

        let overlapping = visibleFrames
            .map { ($0, $0.intersection(rect)) }
            .filter { !$0.1.isNull && !$0.1.isEmpty }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
        let target = overlapping ?? visibleFrames.min {
            distanceSquared(centre(of: $0), centre(of: rect)) < distanceSquared(centre(of: $1), centre(of: rect))
        }
        guard let target else { return origin }

        // A window wider or taller than the screen cannot honour the inset on both sides; insisting on
        // it there pushes the far edge off the screen instead, so the inset is dropped per axis.
        let insetX = size.width + 2 * inset <= target.width ? inset : 0
        let insetY = size.height + 2 * inset <= target.height ? inset : 0
        let minX = target.minX + insetX
        let minY = target.minY + insetY
        let maxX = max(minX, target.maxX - size.width - insetX)
        let maxY = max(minY, target.maxY - size.height - insetY)
        return CGPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, minY), maxY))
    }

    /// Trims a rectangle to the screen it overlaps most, keeping the coordinates that are on screen
    /// and dropping only what runs past the edge. `nil` when it overlaps no screen at all.
    ///
    /// This is the opposite of `clamp` and exists for decoration drawn around someone else's text: a
    /// code block taller than the display used to be *translated* onto the screen, which put the
    /// outline around whatever text happened to be 245 pt higher up. Deliberately `frame` rather
    /// than `visibleFrame` — a block legitimately extends under the Dock and behind the menu bar.
    public static func clip(_ rect: CGRect, screenFrames: [CGRect]) -> CGRect? {
        guard isUsable(rect) else { return nil }
        let overlaps = screenFrames
            .map { $0.intersection(rect) }
            .filter { isUsable($0) }
        guard let clipped = overlaps.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return clipped
    }

    /// Parks a transient HUD in the top-right of a screen, just under the menu bar: clear of the
    /// content the user is reading, and where FlowPeek's own menu-bar icon already draws the eye.
    public static func indicatorOrigin(size: CGSize, in visibleFrame: CGRect, inset: CGFloat = 16) -> CGPoint {
        clamp(
            origin: CGPoint(
                x: visibleFrame.maxX - size.width - inset,
                y: visibleFrame.maxY - size.height - inset
            ),
            size: size,
            visibleFrames: [visibleFrame],
            inset: min(inset, 8)
        )
    }

    /// The visible frame of the screen a point sits on, falling back to the largest one so a HUD is
    /// never placed on a screen that is not there.
    public static func visibleFrame(containing point: CGPoint, visibleFrames: [CGRect]) -> CGRect? {
        if let hit = visibleFrames.first(where: { $0.contains(point) }) { return hit }
        return visibleFrames.max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func centre(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

public struct DiagramViewport: Equatable, Sendable {
    public var scale: Double
    public var offset: CGPoint

    public init(scale: Double = 1, offset: CGPoint = .zero) {
        self.scale = min(max(scale, 0.2), 5)
        self.offset = offset
    }
}

public struct DiagramDocument: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var source: MermaidSource
    public var viewport: DiagramViewport

    public init(id: UUID = UUID(), title: String = "Mermaid Diagram", source: MermaidSource, viewport: DiagramViewport = .init()) {
        self.id = id
        self.title = title
        self.source = source
        self.viewport = viewport
    }
}

public struct AIDiagramRequest: Equatable, Sendable {
    public let context: String
    public let instruction: String
    public let conversation: [AIMessage]

    public init(context: String, instruction: String, conversation: [AIMessage] = []) {
        self.context = context
        self.instruction = instruction
        self.conversation = conversation
    }
}

public struct AIMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct AIDiagramDraft: Codable, Equatable, Sendable {
    public let title: String
    public let mermaid: String
    public let notes: String

    public init(title: String, mermaid: String, notes: String) {
        self.title = title
        self.mermaid = mermaid
        self.notes = notes
    }
}

public enum AIProviderKind: String, CaseIterable, Codable, Sendable {
    case openAI
    case anthropic
    case gemini

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.6-terra"
        case .anthropic: "claude-sonnet-5"
        case .gemini: "gemini-3.7-flash"
        }
    }
}
