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

    // MARK: - Giving up on an app that will not answer

    func testAnAppIsOnlySuppressedOnceItHasUsedUpEveryStrike() {
        var backoff = AmbientPeekPolicy.ReadBackoff()
        let now = Date()
        XCTAssertFalse(backoff.isSuppressed(pid: 501, now: now))
        for strike in 1..<AmbientPeekPolicy.ReadBackoff.strikesBeforeBackoff {
            XCTAssertFalse(backoff.noteAbandoned(pid: 501, now: now), "strike \(strike) is not yet the last")
            XCTAssertFalse(backoff.isSuppressed(pid: 501, now: now))
        }
        XCTAssertTrue(backoff.noteAbandoned(pid: 501, now: now))
        XCTAssertTrue(backoff.isSuppressed(pid: 501, now: now))
    }

    func testTheSuppressionLiftsOnTheClockRatherThanWaitingForAnActivation() {
        var backoff = AmbientPeekPolicy.ReadBackoff()
        let now = Date()
        for _ in 0..<AmbientPeekPolicy.ReadBackoff.strikesBeforeBackoff {
            backoff.noteAbandoned(pid: 501, now: now)
        }
        let window = AmbientPeekPolicy.ReadBackoff.window
        XCTAssertTrue(backoff.isSuppressed(pid: 501, now: now.addingTimeInterval(window - 0.1)))
        XCTAssertFalse(backoff.isSuppressed(pid: 501, now: now.addingTimeInterval(window)))
    }

    /// An app that was busy for a moment is not an app to give up on.
    func testOneCompletedReadClearsTheRecord() {
        var backoff = AmbientPeekPolicy.ReadBackoff()
        let now = Date()
        backoff.noteAbandoned(pid: 501, now: now)
        backoff.noteAbandoned(pid: 501, now: now)
        backoff.noteCompleted(pid: 501)
        XCTAssertFalse(backoff.noteAbandoned(pid: 501, now: now), "the strikes should have been forgotten")
        XCTAssertFalse(backoff.isSuppressed(pid: 501, now: now))
    }

    func testStrikesAreCountedPerApplication() {
        var backoff = AmbientPeekPolicy.ReadBackoff()
        let now = Date()
        for _ in 0..<AmbientPeekPolicy.ReadBackoff.strikesBeforeBackoff {
            backoff.noteAbandoned(pid: 501, now: now)
        }
        XCTAssertTrue(backoff.isSuppressed(pid: 501, now: now))
        XCTAssertFalse(backoff.isSuppressed(pid: 502, now: now))
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

    // MARK: - The caret route

    func testAPointerReadIsAnchoredOnThePointer() {
        let candidate = AmbientPeekPolicy.candidate(
            text: block,
            bounds: CGRect(x: 280, y: 212, width: 760, height: 146),
            screen: screen,
            applicationName: "Google Chrome"
        )
        XCTAssertEqual(candidate?.anchor, .pointer)
    }

    func testASlicedDiagramIsAnchoredOnTheCaretSoTheHintCanSaySo() throws {
        let document = "Intro\n\n```mermaid\n\(block)\n```\n"
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: 20))
        let candidate = AmbientPeekPolicy.candidate(
            slice: slice,
            bounds: CGRect(x: 703, y: 219, width: 1078, height: 24),
            screen: screen,
            applicationName: "Code"
        )
        XCTAssertEqual(candidate?.anchor, .caret)
        XCTAssertEqual(candidate?.detection.expectedType, "flowchart-v2")
        XCTAssertEqual(candidate?.text, slice.text)
    }

    func testASlicedDiagramInAnImplausibleBoxIsStillRefused() throws {
        let document = "```mermaid\n\(block)\n```\n"
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: 0))
        XCTAssertNil(AmbientPeekPolicy.candidate(
            slice: slice,
            bounds: CGRect(x: 0, y: 0, width: 1800, height: 1000),
            screen: screen,
            applicationName: "Code"
        ))
    }

    /// A block that holds two copies of the same diagram is cut at the second starter, and it is
    /// the diagram the peek chord opens -- so refusing it on the size of everything around it turns
    /// down something that renders perfectly well.
    func testTheDiagramIsWeighedRatherThanTheRegionItCameOutOf() throws {
        let half = "flowchart TD\n" + (0..<340).map { "  A\($0) --> B\($0)" }.joined(separator: "\n")
        let document = "```mermaid\n\(half)\n\(half)\n```\n"
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: 20))
        XCTAssertGreaterThan(slice.text.count, AmbientPeekPolicy.maximumCharacters)
        XCTAssertLessThan(slice.detection.extractedSource.count, AmbientPeekPolicy.maximumCharacters)
        XCTAssertNotNil(AmbientPeekPolicy.candidate(
            slice: slice,
            bounds: CGRect(x: 703, y: 219, width: 1078, height: 24),
            screen: screen,
            applicationName: "Code"
        ))
    }

    // MARK: - Where the pointer has to be for the caret to answer

    /// The focused element's rectangle is one line of text, so the pane around it is what says the
    /// pointer is in the editor at all.
    func testAPointerInsideTheEditorPaneLetsTheCaretAnswer() {
        let line = CGRect(x: 703, y: 219, width: 1078, height: 18)
        let pane = CGRect(x: 700, y: 100, width: 1100, height: 800)
        XCTAssertTrue(AmbientPeekPolicy.caretAnchorFits(
            pointer: CGPoint(x: 900, y: 400), focused: line, container: pane
        ))
        // On the caret's own line, with no pane to be had.
        XCTAssertTrue(AmbientPeekPolicy.caretAnchorFits(
            pointer: CGPoint(x: 900, y: 225), focused: line, container: nil
        ))
    }

    /// The sidebar, the tab bar and the integrated terminal are the same process as the editor, and
    /// the caret is in none of them: framing the editor's caret for a pointer parked there marks a
    /// rectangle the pointer has never been over.
    func testAPointerElsewhereInTheSameApplicationIsRefused() {
        let line = CGRect(x: 703, y: 219, width: 1078, height: 18)
        let pane = CGRect(x: 700, y: 100, width: 1100, height: 800)
        for elsewhere in [CGPoint(x: 200, y: 400), CGPoint(x: 900, y: 60), CGPoint(x: 900, y: 950)] {
            XCTAssertFalse(
                AmbientPeekPolicy.caretAnchorFits(pointer: elsewhere, focused: line, container: pane),
                "\(elsewhere)"
            )
        }
    }

    func testAnUnreadableFrameIsNoEvidenceAtAll() {
        let pointer = CGPoint(x: 900, y: 400)
        XCTAssertFalse(AmbientPeekPolicy.caretAnchorFits(pointer: pointer, focused: nil, container: nil))
        XCTAssertFalse(AmbientPeekPolicy.caretAnchorFits(pointer: pointer, focused: .zero, container: .infinite))
    }

    /// The caret's own line measured 1078x18, and `minimumSize` is 24 points tall, so without this
    /// every rectangle the editor offers is refused and no outline is ever drawn.
    func testALineHeightRectangleIsGrownAboutItsCentreUntilItCanBeDrawn() {
        let line = CGRect(x: 703, y: 219, width: 1078, height: 18)
        let grown = AmbientPeekPolicy.grownToMinimum(line)
        XCTAssertEqual(grown.height, AmbientPeekPolicy.minimumSize.height)
        XCTAssertEqual(grown.width, 1078)
        XCTAssertEqual(grown.midX, line.midX)
        XCTAssertEqual(grown.midY, line.midY)
        XCTAssertTrue(AmbientPeekPolicy.isPlausible(bounds: grown, screen: screen))
        XCTAssertFalse(AmbientPeekPolicy.isPlausible(bounds: line, screen: screen))
    }

    func testGrowingLeavesARectangleThatIsAlreadyBigEnoughAloneAndRefusesNonsense() {
        let block = CGRect(x: 280, y: 212, width: 760, height: 146)
        XCTAssertEqual(AmbientPeekPolicy.grownToMinimum(block), block)
        XCTAssertEqual(AmbientPeekPolicy.grownToMinimum(.zero), .zero)
        XCTAssertEqual(AmbientPeekPolicy.grownToMinimum(.infinite), .infinite)
    }
}
