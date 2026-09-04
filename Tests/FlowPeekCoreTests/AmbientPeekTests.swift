import XCTest
@testable import FlowPeekCore

final class AmbientPeekTests: XCTestCase {
    private let screen = CGSize(width: 1920, height: 1080)
    private let block = """
        flowchart TD
          A[Selection] --> B{Looks like Mermaid?}
          B -- yes --> C[Outline]
        """

    // MARK: - When to read

    func testTheFirstReadIsAlwaysAllowed() {
        XCTAssertTrue(AmbientPeekPolicy.shouldRead(
            pointer: CGPoint(x: 100, y: 100), lastPointer: nil, now: Date(), lastRead: nil
        ))
    }

    func testAReadInsideTheDebounceIsRefusedHoweverFarThePointerMoved() {
        let now = Date()
        XCTAssertFalse(AmbientPeekPolicy.shouldRead(
            pointer: CGPoint(x: 900, y: 900),
            lastPointer: CGPoint(x: 100, y: 100),
            now: now,
            lastRead: now.addingTimeInterval(-AmbientPeekPolicy.debounce / 2)
        ))
    }

    func testAfterTheDebounceOnlyRealMovementTriggersAFreshRead() {
        let now = Date()
        let stale = now.addingTimeInterval(-AmbientPeekPolicy.debounce * 2)
        let origin = CGPoint(x: 100, y: 100)

        // Still inside the element that was just read.
        XCTAssertFalse(AmbientPeekPolicy.shouldRead(
            pointer: CGPoint(x: 103, y: 102), lastPointer: origin, now: now, lastRead: stale
        ))
        XCTAssertTrue(AmbientPeekPolicy.shouldRead(
            pointer: CGPoint(x: 100 + AmbientPeekPolicy.movementThreshold, y: 100),
            lastPointer: origin, now: now, lastRead: stale
        ))
    }

    // MARK: - Which rectangles are plausible

    func testASliverIsNotACodeBlock() {
        XCTAssertFalse(AmbientPeekPolicy.isPlausible(
            bounds: CGRect(x: 0, y: 0, width: 400, height: 8), screen: screen
        ))
        XCTAssertFalse(AmbientPeekPolicy.isPlausible(
            bounds: CGRect(x: 0, y: 0, width: 40, height: 200), screen: screen
        ))
    }

    func testAWindowSizedContainerIsRefused() {
        // A whole editor pane came back at 1225x493 in measurement; that is 29% of this screen and
        // allowed, while something covering most of the display is not.
        XCTAssertTrue(AmbientPeekPolicy.isPlausible(
            bounds: CGRect(x: 0, y: 0, width: 1225, height: 493), screen: screen
        ))
        XCTAssertFalse(AmbientPeekPolicy.isPlausible(
            bounds: CGRect(x: 0, y: 0, width: 1800, height: 1000), screen: screen
        ))
    }

    func testADegenerateOrOffscreenRectIsRefused() {
        XCTAssertFalse(AmbientPeekPolicy.isPlausible(bounds: .zero, screen: screen))
        XCTAssertFalse(AmbientPeekPolicy.isPlausible(bounds: .infinite, screen: screen))
        XCTAssertFalse(AmbientPeekPolicy.isPlausible(
            bounds: CGRect(x: 0, y: 0, width: 300, height: 200), screen: .zero
        ))
    }

    // MARK: - The decision

    /// The measured Chrome case: a `<pre>` at 760x146 carrying the block's full text.
    func testAMeasuredCodeBlockBecomesACandidate() {
        let candidate = AmbientPeekPolicy.candidate(
            text: block,
            bounds: CGRect(x: 280, y: 212, width: 760, height: 146),
            screen: screen,
            applicationName: "Google Chrome"
        )
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.detection.expectedType, "flowchart-v2")
        XCTAssertEqual(candidate?.applicationName, "Google Chrome")
        XCTAssertEqual(candidate?.bounds.width, 760)
    }

    func testProseIsRefusedEvenInAPlausibleBox() {
        XCTAssertNil(AmbientPeekPolicy.candidate(
            text: "The graph shows a 12% increase over the quarter.",
            bounds: CGRect(x: 0, y: 0, width: 600, height: 120),
            screen: screen,
            applicationName: "Safari"
        ))
    }

    /// A `.weak` match is exactly what would fire over ordinary text, and an outline appearing there
    /// is worse than one that never appears.
    func testAWeakMatchDoesNotRaiseAnOutline() {
        let weak = MermaidDetector.detect("info")
        XCTAssertEqual(weak.confidence, .weak)
        XCTAssertNil(AmbientPeekPolicy.candidate(
            text: "info",
            bounds: CGRect(x: 0, y: 0, width: 300, height: 60),
            screen: screen,
            applicationName: "Safari"
        ))
    }

    func testAWholeDocumentIsRefusedEvenIfItParses() {
        let huge = "flowchart TD\n" + (0..<900).map { "  A\($0) --> B\($0)" }.joined(separator: "\n")
        XCTAssertGreaterThan(huge.count, AmbientPeekPolicy.maximumCharacters)
        XCTAssertNil(AmbientPeekPolicy.candidate(
            text: huge,
            bounds: CGRect(x: 0, y: 0, width: 700, height: 400),
            screen: screen,
            applicationName: "Safari"
        ))
    }

    func testTheCandidateCarriesTheNormalisedSourceNotTheRawText() {
        // The kind of noise a browser injects: a non-breaking space and a fence.
        let noisy = "```mermaid\nflowchart\u{00A0}TD\n  A --> B\n```"
        let candidate = AmbientPeekPolicy.candidate(
            text: noisy,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 120),
            screen: screen,
            applicationName: "Safari"
        )
        XCTAssertNotNil(candidate)
        XCTAssertFalse(candidate!.detection.extractedSource.contains("\u{00A0}"))
        XCTAssertFalse(candidate!.detection.extractedSource.contains("```"))
        XCTAssertTrue(candidate!.detection.extractedSource.hasPrefix("flowchart TD"))
    }
}
