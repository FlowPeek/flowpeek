import CoreGraphics
import Foundation

public struct ProbedSelection: Equatable, Sendable {
    public let text: String
    public let bounds: CGRect?

    public init(text: String, bounds: CGRect?) {
        self.text = text
        self.bounds = bounds
    }
}

/// The accessibility surface `SelectionGatherer` needs. `AccessibilitySelectionReader` supplies the
/// real `AXUIElement` implementation; a fake supplies deterministic elements so the candidate
/// ordering, the wall-clock budget and the `AXWebArea` fallback are testable without a live AX target.
@MainActor
public protocol AccessibilityProbing: AnyObject {
    associatedtype Element

    /// The element under the mouse, in AX (top-left, y-down) coordinates.
    func hitTest(at point: CGPoint) -> Element?
    func focusedElement() -> Element?
    func applicationElement() -> Element
    func parent(of element: Element) -> Element?
    func isSame(_ lhs: Element, _ rhs: Element) -> Bool
    /// Marker range first, then `kAXSelectedText`; nil when this element reports no selection.
    func selection(in element: Element, kind: SelectionCandidateKind, depth: Int) -> ProbedSelection?
    /// `kAXFocusedWindow` → first descendant whose role is `AXWebArea`, breadth-first.
    func focusedWebArea() -> Element?
    func now() -> Date
    func log(_ message: String)
}

public extension AccessibilityProbing {
    func log(_ message: String) {}
}

/// Assembles the ordered candidate list for one `currentSelection` pass. Pure control flow —
/// ordering, ancestor walk, budget checks and the web-area fallback — with every AX call behind
/// `AccessibilityProbing`.
public enum SelectionGatherer {
    public static let ancestorHopLimit = 24

    /// Roots in descending order of trust: the hit-tested element, the focused element (unless it is
    /// the same object), then the application. If none of them yields text, the `AXWebArea` under the
    /// focused window is tried last — Chromium answers there when nothing above it does.
    @MainActor
    public static func candidates<Provider: AccessibilityProbing>(
        using provider: Provider,
        mouseLocation: CGPoint,
        deadline: Date,
        hopLimit: Int = ancestorHopLimit,
        boundsTransform: (CGRect) -> CGRect? = { $0 }
    ) -> [SelectionCandidate] {
        var roots: [(kind: SelectionCandidateKind, element: Provider.Element)] = []
        if let hit = provider.hitTest(at: mouseLocation) {
            roots.append((.hitTest, hit))
        }
        if let focused = provider.focusedElement(),
           !roots.contains(where: { provider.isSame($0.element, focused) }) {
            roots.append((.focused, focused))
        }
        roots.append((.application, provider.applicationElement()))

        var candidates: [SelectionCandidate] = []
        for root in roots {
            guard provider.now() < deadline else {
                provider.log("candidate \(root.kind.description) skipped: attempt budget exhausted")
                break
            }
            if let found = walk(from: root.element, kind: root.kind, provider: provider, deadline: deadline, hopLimit: hopLimit) {
                candidates.append(candidate(kind: root.kind, found: found, boundsTransform: boundsTransform))
            }
        }
        if candidates.isEmpty, provider.now() < deadline, let webArea = provider.focusedWebArea() {
            if let found = provider.selection(in: webArea, kind: .webArea, depth: 0) {
                candidates.append(candidate(kind: .webArea, found: found, boundsTransform: boundsTransform))
            }
        }
        return candidates
    }

    /// The element itself, then up to `hopLimit` ancestors. The walk only ascends, so it can never
    /// reach the `AXWebArea` that owns the marker range — the fallback above covers that case.
    @MainActor
    private static func walk<Provider: AccessibilityProbing>(
        from element: Provider.Element,
        kind: SelectionCandidateKind,
        provider: Provider,
        deadline: Date,
        hopLimit: Int
    ) -> ProbedSelection? {
        var cursor = element
        for depth in 0..<hopLimit {
            guard provider.now() < deadline else {
                provider.log("candidate \(kind.description) walk stopped at depth \(depth): attempt budget exhausted")
                return nil
            }
            if let found = provider.selection(in: cursor, kind: kind, depth: depth) { return found }
            guard let parent = provider.parent(of: cursor) else {
                provider.log("candidate \(kind.description) walk ended at depth \(depth): no parent")
                return nil
            }
            cursor = parent
        }
        provider.log("candidate \(kind.description) walk exhausted \(hopLimit) hops")
        return nil
    }

    private static func candidate(
        kind: SelectionCandidateKind,
        found: ProbedSelection,
        boundsTransform: (CGRect) -> CGRect?
    ) -> SelectionCandidate {
        SelectionCandidate(
            kind: kind,
            text: found.text.trimmingCharacters(in: .whitespacesAndNewlines),
            bounds: found.bounds.flatMap(boundsTransform)
        )
    }
}
