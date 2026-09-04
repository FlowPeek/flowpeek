import XCTest
@testable import FlowPeekCore

final class ClipboardPreviewPolicyTests: XCTestCase {
    private let diagram = "flowchart TD\n  A[Start] --> B[End]"

    /// The whole defect: a diagram copied before FlowPeek was running — or before the watch was
    /// switched on — is the one the poller can never report, and pressing the shortcut used to be
    /// silent for exactly that copy.
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

    /// The live read is held to the same limits as a witnessed copy: a pasteboard full of a log
    /// file must not become a render request.
    func testAnOversizedPasteboardIsNotADiagram() {
        let huge = "flowchart TD\n" + String(repeating: "  A --> B\n", count: 20_000)
        XCTAssertEqual(
            ClipboardPreviewPolicy.decide(pasteboardText: huge, hasCachedDiagram: false),
            .nothingToPreview
        )
    }
}
