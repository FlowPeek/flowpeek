import CoreGraphics
import XCTest

@testable import FlowPeekCore

/// The candidate-assembly half of the AX read: ordering, the ancestor walk, the wall-clock budget and
/// the `AXWebArea` fallback, driven by a fake provider so none of it needs a live accessibility target.
/// The AX calls themselves (`AccessibilitySelectionReader`) still need Step 3's manual GUI check.
@MainActor
final class SelectionGathererTests: XCTestCase {
    /// Elements are ints; `parents` is the ancestor chain and `selections` what each one reports.
    private final class FakeProbe: AccessibilityProbing {
        typealias Element = Int

        var hit: Int?
        var focused: Int?
        var application = 0
        var webArea: Int?
        var parents: [Int: Int] = [:]
        var selections: [Int: ProbedSelection] = [:]
        var clock = Date(timeIntervalSince1970: 1_000)
        /// Wall clock spent per probe, so a budget can genuinely run out mid-walk.
        var costPerProbe: TimeInterval = 0
        private(set) var probes: [(kind: SelectionCandidateKind, depth: Int, element: Int)] = []
        private(set) var webAreaLookups = 0

        func hitTest(at point: CGPoint) -> Int? { hit }
        func focusedElement() -> Int? { focused }
        func applicationElement() -> Int { application }
        func parent(of element: Int) -> Int? { parents[element] }
        func isSame(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }

        func selection(in element: Int, kind: SelectionCandidateKind, depth: Int) -> ProbedSelection? {
            probes.append((kind, depth, element))
            clock = clock.addingTimeInterval(costPerProbe)
            return selections[element]
        }

        func focusedWebArea() -> Int? {
            webAreaLookups += 1
            return webArea
        }

        func now() -> Date { clock }
    }

    private func gather(_ probe: FakeProbe, budget: TimeInterval = 10, hopLimit: Int = 24) -> [SelectionCandidate] {
        SelectionGatherer.candidates(
            using: probe,
            mouseLocation: CGPoint(x: 100, y: 100),
            deadline: probe.clock.addingTimeInterval(budget),
            hopLimit: hopLimit
        )
    }

    // MARK: - Ordering

    func testRootsAreProbedHitTestThenFocusedThenApplication() {
        let probe = FakeProbe()
        probe.hit = 1
        probe.focused = 2
        probe.application = 3
        probe.selections = [
            1: ProbedSelection(text: "from the hit test", bounds: nil),
            2: ProbedSelection(text: "from the focused element", bounds: nil),
            3: ProbedSelection(text: "from the application", bounds: nil),
        ]

        let candidates = gather(probe)
        XCTAssertEqual(candidates.map(\.kind), [.hitTest, .focused, .application])
        XCTAssertEqual(probe.probes.map(\.element), [1, 2, 3])
        XCTAssertEqual(probe.webAreaLookups, 0, "the fallback must not run when a candidate was found")
    }

    func testAFocusedElementIdenticalToTheHitTestIsNotProbedTwice() {
        let probe = FakeProbe()
        probe.hit = 7
        probe.focused = 7
        probe.application = 3
        probe.selections = [7: ProbedSelection(text: "once", bounds: nil)]

        let candidates = gather(probe)
        XCTAssertEqual(candidates.map(\.kind), [.hitTest])
        XCTAssertEqual(probe.probes.map(\.element), [7, 3])
    }

    func testTheApplicationIsAlwaysARootEvenWithNoHitTestAndNoFocus() {
        let probe = FakeProbe()
        probe.application = 5
        probe.selections = [5: ProbedSelection(text: "app text", bounds: nil)]

        XCTAssertEqual(gather(probe).map(\.kind), [.application])
    }

    // MARK: - Ancestor walk

    func testTheWalkAscendsUntilAnAncestorReportsText() {
        let probe = FakeProbe()
        probe.hit = 1
        probe.application = 99
        probe.parents = [1: 2, 2: 3, 3: 4]
        probe.selections = [3: ProbedSelection(text: "found two hops up", bounds: nil)]

        let candidates = gather(probe)
        XCTAssertEqual(candidates.first?.text, "found two hops up")
        XCTAssertEqual(probe.probes.filter { $0.kind == .hitTest }.map(\.depth), [0, 1, 2])
    }

    func testTheWalkStopsWhenAnElementHasNoParent() {
        let probe = FakeProbe()
        probe.hit = 1
        probe.application = 99
        probe.parents = [1: 2]

        XCTAssertTrue(gather(probe).isEmpty)
        XCTAssertEqual(probe.probes.filter { $0.kind == .hitTest }.map(\.element), [1, 2])
    }

    func testTheWalkNeverExceedsTheHopLimit() {
        let probe = FakeProbe()
        probe.hit = 0
        probe.application = 999
        for element in 0..<200 { probe.parents[element] = element + 1 }

        _ = gather(probe, hopLimit: 24)
        XCTAssertEqual(probe.probes.filter { $0.kind == .hitTest }.count, 24)
    }

    // MARK: - Budget

    func testAnExhaustedBudgetStopsBeforeTheNextRoot() {
        let probe = FakeProbe()
        probe.hit = 1
        probe.focused = 2
        probe.application = 3
        probe.costPerProbe = 0.6

        _ = gather(probe, budget: 0.5)
        // The hit-test root spends 0.6 s and finds nothing; the budget is gone before `focused`.
        XCTAssertEqual(probe.probes.map(\.element), [1])
    }

    func testAnExhaustedBudgetStopsMidWalk() {
        let probe = FakeProbe()
        probe.hit = 1
        probe.application = 99
        probe.parents = [1: 2, 2: 3, 3: 4]
        probe.costPerProbe = 0.3

        _ = gather(probe, budget: 0.7)
        XCTAssertEqual(probe.probes.filter { $0.kind == .hitTest }.map(\.depth), [0, 1, 2])
    }

    func testTheWebAreaFallbackIsSkippedWhenTheBudgetIsGone() {
        let probe = FakeProbe()
        probe.application = 3
        probe.webArea = 42
        probe.costPerProbe = 0.6
        probe.selections = [42: ProbedSelection(text: "web area text", bounds: nil)]

        XCTAssertTrue(gather(probe, budget: 0.5).isEmpty)
        XCTAssertEqual(probe.webAreaLookups, 0)
    }

    // MARK: - Web-area fallback

    func testTheWebAreaFallbackRunsOnlyWhenNothingElseFoundText() {
        let probe = FakeProbe()
        probe.hit = 1
        probe.application = 3
        probe.webArea = 42
        probe.selections = [42: ProbedSelection(text: "chromium marker range", bounds: nil)]

        let candidates = gather(probe)
        XCTAssertEqual(candidates.map(\.kind), [.webArea])
        XCTAssertEqual(candidates.first?.text, "chromium marker range")
        XCTAssertEqual(probe.webAreaLookups, 1)
    }

    func testAWebAreaThatReportsNothingProducesNoCandidate() {
        let probe = FakeProbe()
        probe.application = 3
        probe.webArea = 42

        XCTAssertTrue(gather(probe).isEmpty)
        XCTAssertEqual(probe.webAreaLookups, 1)
    }

    // MARK: - Candidate shaping

    func testCandidateTextIsTrimmedAndBoundsGoThroughTheTransform() {
        let probe = FakeProbe()
        probe.application = 3
        probe.selections = [3: ProbedSelection(text: "  graph TD\nA-->B \n", bounds: CGRect(x: 0, y: 10, width: 40, height: 20))]

        let candidates = SelectionGatherer.candidates(
            using: probe,
            mouseLocation: .zero,
            deadline: probe.clock.addingTimeInterval(10)
        ) { ScreenGeometry.axToAppKit($0, flipReference: 1_000) }

        XCTAssertEqual(candidates.first?.text, "graph TD\nA-->B")
        XCTAssertEqual(candidates.first?.bounds, CGRect(x: 0, y: 970, width: 40, height: 20))
    }

    func testUnusableBoundsAreDroppedRatherThanScored() {
        let probe = FakeProbe()
        probe.application = 3
        probe.selections = [3: ProbedSelection(text: "text", bounds: .zero)]

        let candidates = SelectionGatherer.candidates(
            using: probe,
            mouseLocation: .zero,
            deadline: probe.clock.addingTimeInterval(10)
        ) { ScreenGeometry.isUsable($0) ? $0 : nil }

        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates.first?.bounds)
    }
}
