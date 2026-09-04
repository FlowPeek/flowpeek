import XCTest
@testable import FlowPeekCore

final class ClipboardPreviewPolicyTests: XCTestCase {
    private let diagram = "flowchart TD\n  A[Start] --> B[End]"

    /// A diagram copied before FlowPeek was running — or before the watch was switched on — is the
    /// one the poller can never report, because it starts by writing off everything already on the
    /// pasteboard. The asked-for route has to answer for it anyway.
    func testAPasteboardDiagramNobodyWitnessedIsStillOpened() {
        guard case .preview(let source) = ClipboardPreviewPolicy.decide(
            pasteboardText: diagram,
            hasCachedDiagram: false
        ) else { return XCTFail("the live pasteboard read was ignored") }
        XCTAssertTrue(source.text.contains("flowchart"))
    }

    /// The live read wins, so the panel and the pasteboard can never disagree about which diagram
    /// "the copied one" means.
    func testTheLiveReadOutranksTheRememberedCopy() throws {
        XCTAssertEqual(
            ClipboardPreviewPolicy.decide(pasteboardText: diagram, hasCachedDiagram: true),
            .preview(try MermaidSource(rawValue: diagram))
        )
    }

    /// A copy blessed while the watch was on survives the watch being switched off, so that key
    /// keeps working for the diagram the badge already named.
    func testTheRememberedCopyIsTheFallback() {
        XCTAssertEqual(
            ClipboardPreviewPolicy.decide(pasteboardText: "just some prose", hasCachedDiagram: true),
            .previewCached
        )
        XCTAssertEqual(ClipboardPreviewPolicy.decide(pasteboardText: nil, hasCachedDiagram: true), .previewCached)
    }

    /// Nothing to show is an answer too — the silence is what made the key look broken.
    func testAnEmptyPasteboardAndNoCacheSaysSo() {
        XCTAssertEqual(
            ClipboardPreviewPolicy.decide(pasteboardText: nil, hasCachedDiagram: false),
            .nothingToPreview
        )
        XCTAssertEqual(
            ClipboardPreviewPolicy.decide(pasteboardText: "", hasCachedDiagram: false),
            .nothingToPreview
        )
        XCTAssertEqual(
            ClipboardPreviewPolicy.decide(pasteboardText: "shopping list", hasCachedDiagram: false),
            .nothingToPreview
        )
    }

    /// A diagram too big to draw is a diagram, and the user is entitled to hear which limit it hit.
    /// Reported as "there is no diagram on the clipboard" it sends them looking for a mistake in
    /// syntax that is perfectly good.
    func testAnOversizedPasteboardIsRefusedWithItsReason() {
        let huge = "flowchart TD\n" + String(repeating: "  A --> B\n", count: 20_000)
        guard case .refused(let error) = ClipboardPreviewPolicy.decide(
            pasteboardText: huge,
            hasCachedDiagram: false
        ) else { return XCTFail("the size limit was reported as an empty clipboard") }
        guard case .tooLarge(let units) = error else { return XCTFail("the wrong limit was named: \(error)") }
        XCTAssertGreaterThan(units, MermaidSource.maximumCharacters)
    }

    /// The refusal outranks the remembered copy. Falling back here is how the user came to press a
    /// key for a 150k-character flowchart and be shown a different, older diagram under the title
    /// "Copied Diagram", with nothing said about either one.
    func testARefusalIsNotAnsweredWithADifferentDiagram() {
        let huge = "flowchart TD\n" + String(repeating: "  A --> B\n", count: 20_000)
        guard case .refused = ClipboardPreviewPolicy.decide(pasteboardText: huge, hasCachedDiagram: true) else {
            return XCTFail("a remembered copy was opened instead of reporting the pasteboard")
        }
    }

    /// Past the detector's own ceiling nothing is examined at all, so the answer can only be the
    /// size — and it still has to be the size rather than silence.
    func testTextTooLargeToEvenExamineStillReportsTheSize() {
        let vast = String(repeating: "a", count: MermaidDetector.maximumInputCharacters + 1)
        guard case .refused(.tooLarge) = ClipboardPreviewPolicy.decide(
            pasteboardText: vast,
            hasCachedDiagram: true
        ) else { return XCTFail("an unexaminable pasteboard fell through to the cache") }
    }

    /// A line no renderer will take is a shape complaint, not an absence: the same reporting the
    /// selection route gives for the same text.
    func testAnUnrenderableShapeIsRefusedRatherThanCalledEmpty() {
        let oneVastLine = "flowchart TD\n  A[" + String(repeating: "x", count: 25_000) + "] --> B"
        guard case .refused(.lineTooLong) = ClipboardPreviewPolicy.decide(
            pasteboardText: oneVastLine,
            hasCachedDiagram: false
        ) else { return XCTFail("a line over the limit was reported as nothing to preview") }
    }
}
