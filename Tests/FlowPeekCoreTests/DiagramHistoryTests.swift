import XCTest
@testable import FlowPeekCore

/// The ordering, the cap and the rule that decides whether a recording is a new diagram or another
/// go at the last one. All of it decidable without a window, a disk or a clock.
final class DiagramHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func flowchart(_ nodes: [String]) -> String {
        (["flowchart TD"] + nodes.map { "  \($0)" }).joined(separator: "\n")
    }

    // MARK: - Ordering and the cap

    func testTheNewestRecordingIsFirst() {
        var history = DiagramHistory()
        history.record(title: "One", source: flowchart(["A --> B"]), origin: .ai, at: start)
        history.record(title: "Two", source: flowchart(["C --> D"]), origin: .ai, at: start.addingTimeInterval(-9_000))
        XCTAssertEqual(history.entries.map(\.title), ["Two", "One"])
    }

    func testTheCapDropsTheOldest() {
        var history = DiagramHistory(limit: 5)
        for index in 0..<8 {
            history.record(
                title: "D\(index)",
                source: flowchart(["N\(index) --> M\(index)"]),
                origin: .ai,
                at: start.addingTimeInterval(Double(index) * 86_400)
            )
        }
        XCTAssertEqual(history.entries.count, 5)
        XCTAssertEqual(history.entries.map(\.title), ["D7", "D6", "D5", "D4", "D3"])
    }

    func testLoweringTheMaximumForgetsTheExtrasImmediately() {
        var history = DiagramHistory(limit: 20)
        for index in 0..<10 {
            history.record(
                title: "D\(index)",
                source: flowchart(["N\(index) --> M\(index)"]),
                origin: .ai,
                at: start.addingTimeInterval(Double(index) * 86_400)
            )
        }
        history.setLimit(6)
        XCTAssertEqual(history.entries.map(\.title), ["D9", "D8", "D7", "D6", "D5", "D4"])
    }

    func testTheMaximumIsHeldInsideItsRange() {
        var history = DiagramHistory(limit: 9_000)
        XCTAssertEqual(history.limit, DiagramHistory.limitRange.upperBound)
        history.setLimit(0)
        XCTAssertEqual(history.limit, DiagramHistory.limitRange.lowerBound)
    }

    // MARK: - What makes two entries the same thing

    func testTheSameDiagramAgainMovesUpInsteadOfAddingARow() {
        var history = DiagramHistory()
        let repeated = flowchart(["A --> B"])
        history.record(title: "Login", source: repeated, origin: .ai, at: start)
        history.record(title: "Payments", source: flowchart(["X --> Y"]), origin: .ai, at: start.addingTimeInterval(86_400))
        let first = history.entries.last?.id
        history.record(title: "Login", source: repeated, origin: .ai, at: start.addingTimeInterval(172_800))

        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.first?.title, "Login")
        // Same row, not a new one: anything holding the identifier still points at this diagram.
        XCTAssertEqual(history.entries.first?.id, first)
    }

    func testNormalizingRemovesOnlyTheWhitespaceAtTheEnds() {
        XCTAssertEqual(
            DiagramHistory.normalize("\n\nflowchart TD   \n  A --> B\t\n\r\n   \n"),
            "flowchart TD\n  A --> B"
        )
        // Blank lines inside the diagram are the author's own spacing and stay exactly as written.
        XCTAssertEqual(DiagramHistory.normalize("flowchart TD\n\n  A --> B"), "flowchart TD\n\n  A --> B")
    }

    func testTrailingWhitespaceDoesNotMakeItADifferentDiagram() {
        var history = DiagramHistory()
        history.record(title: "One", source: "flowchart TD\n  A --> B", origin: .ai, at: start)
        history.record(title: "One", source: "flowchart TD  \n  A --> B\t\n\n", origin: .ai, at: start.addingTimeInterval(1))
        XCTAssertEqual(history.entries.count, 1)
    }

    func testAnEditKeepsOneRowWhileTheTitleHolds() {
        var history = DiagramHistory()
        history.record(title: "Checkout", source: flowchart(["A --> B"]), origin: .ai, at: start)
        for step in 1...4 {
            history.record(
                title: "Checkout",
                source: flowchart(["A --> B"] + (1...step).map { "S\($0) --> T\($0)" }),
                origin: .ai,
                at: start.addingTimeInterval(Double(step) * 60)
            )
        }
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertTrue(history.entries[0].source.contains("S4 --> T4"))
    }

    func testARenamedEditStillCountsAsTheSameDiagram() {
        var history = DiagramHistory()
        let original = flowchart((1...10).map { "N\($0) --> N\($0 + 1)" })
        history.record(title: "Draft", source: original, origin: .ai, at: start)
        history.record(
            title: "Order pipeline",
            source: original + "\n  N11 --> N12",
            origin: .ai,
            at: start.addingTimeInterval(120)
        )
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].title, "Order pipeline")
    }

    func testADifferentDiagramWithADifferentTitleIsItsOwnRow() {
        var history = DiagramHistory()
        history.record(title: "Checkout", source: flowchart((1...8).map { "A\($0) --> B\($0)" }), origin: .ai, at: start)
        history.record(title: "Deploy", source: flowchart((1...8).map { "P\($0) --> Q\($0)" }), origin: .ai, at: start.addingTimeInterval(60))
        XCTAssertEqual(history.entries.count, 2)
    }

    func testComingBackTomorrowStartsANewRow() {
        var history = DiagramHistory()
        history.record(title: "Checkout", source: flowchart(["A --> B"]), origin: .ai, at: start)
        history.record(
            title: "Checkout",
            source: flowchart(["A --> B", "B --> C"]),
            origin: .ai,
            at: start.addingTimeInterval(DiagramHistory.revisionWindow + 60)
        )
        XCTAssertEqual(history.entries.count, 2)
    }

    func testARevisionOnlyFoldsIntoTheDiagramBeingWorkedOn() {
        var history = DiagramHistory()
        history.record(title: "Checkout", source: flowchart(["A --> B"]), origin: .ai, at: start)
        history.record(title: "Deploy", source: flowchart((1...8).map { "P\($0) --> Q\($0)" }), origin: .ai, at: start.addingTimeInterval(60))
        // Same title as the row underneath, but that row is not the one being worked on any more.
        history.record(title: "Checkout", source: flowchart(["A --> B", "B --> C"]), origin: .ai, at: start.addingTimeInterval(120))
        XCTAssertEqual(history.entries.count, 3)
    }

    func testTheSameTitleFromADifferentRouteIsItsOwnRow() {
        var history = DiagramHistory()
        history.record(title: "Checkout", source: flowchart(["A --> B"]), origin: .ai, at: start)
        history.record(title: "Checkout", source: flowchart(["C --> D"]), origin: .clipboard, at: start.addingTimeInterval(60))
        XCTAssertEqual(history.entries.count, 2)
    }

    func testAClockThatWentBackwardsStillFolds() {
        var history = DiagramHistory()
        history.record(title: "Checkout", source: flowchart(["A --> B"]), origin: .ai, at: start)
        history.record(title: "Checkout", source: flowchart(["A --> B", "B --> C"]), origin: .ai, at: start.addingTimeInterval(-60))
        XCTAssertEqual(history.entries.count, 1)
    }

    // MARK: - Nothing worth keeping

    func testBlankSourceIsNotRemembered() {
        var history = DiagramHistory()
        XCTAssertNil(history.record(title: "Nothing", source: "   \n\n\t", origin: .ai, at: start))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testADiagramTooLargeToRenderIsNotRemembered() {
        var history = DiagramHistory()
        let huge = String(repeating: "a", count: MermaidSource.maximumCharacters + 1)
        XCTAssertNil(history.record(title: "Huge", source: huge, origin: .ai, at: start))
        XCTAssertTrue(history.entries.isEmpty)
    }

    // MARK: - Removal

    func testRemovingOneLeavesTheRest() throws {
        var history = DiagramHistory()
        history.record(title: "One", source: flowchart(["A --> B"]), origin: .ai, at: start)
        history.record(title: "Two", source: flowchart(["C --> D"]), origin: .ai, at: start.addingTimeInterval(86_400))
        let victim = try XCTUnwrap(history.entries.first?.id)
        XCTAssertTrue(history.remove(victim))
        XCTAssertEqual(history.entries.map(\.title), ["One"])
        XCTAssertFalse(history.remove(UUID()))
    }

    func testClearingRemovesEverything() {
        var history = DiagramHistory()
        history.record(title: "One", source: flowchart(["A --> B"]), origin: .ai, at: start)
        history.removeAll()
        XCTAssertTrue(history.entries.isEmpty)
    }

    // MARK: - What a hand-edited list turns into

    func testLoadingSortsFoldsAndTrims() {
        let shared = flowchart(["A --> B"])
        let history = DiagramHistory(
            entries: [
                DiagramHistoryEntry(title: "Old", source: shared, recordedAt: start, origin: .ai),
                DiagramHistoryEntry(title: "New", source: shared, recordedAt: start.addingTimeInterval(86_400), origin: .ai),
                DiagramHistoryEntry(title: "Other", source: flowchart(["C --> D"]), recordedAt: start.addingTimeInterval(43_200), origin: .ai),
                DiagramHistoryEntry(title: "Empty", source: "", recordedAt: .distantFuture, origin: .ai),
            ],
            limit: 5
        )
        XCTAssertEqual(history.entries.map(\.title), ["New", "Other"])
    }

    // MARK: - Reopening one

    func testAnEntryRebuildsIntoADocument() throws {
        let entry = DiagramHistoryEntry(title: "", source: flowchart(["A --> B"]), origin: .ai)
        let document = try XCTUnwrap(entry.document(fallbackTitle: "Untitled"))
        XCTAssertEqual(document.title, "Untitled")
        XCTAssertTrue(document.source.text.contains("A --> B"))
    }

    func testAnEntryWithNothingLeftInItRebuildsIntoNothing() {
        let entry = DiagramHistoryEntry(title: "Gone", source: "   ", origin: .ai)
        XCTAssertNil(entry.document(fallbackTitle: "Untitled"))
    }

    func testTheKeywordIsReadOffTheFirstSignificantLine() {
        XCTAssertEqual(DiagramHistoryEntry(title: "", source: "\n\n  erDiagram\n  A ||--o{ B : has", origin: .ai).keyword, "erDiagram")
        XCTAssertNil(DiagramHistoryEntry(title: "", source: "  --> nothing", origin: .ai).keyword)
    }
}
