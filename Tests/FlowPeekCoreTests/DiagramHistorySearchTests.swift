import XCTest
@testable import FlowPeekCore

/// A stand-in for the on-device embeddings: the ranking is what is being checked, not Apple's
/// vectors, and a test that depended on those would be a test of macOS.
private struct StubIndex: DiagramSemanticIndex {
    /// query -> (candidate fragment, distance)
    let distances: [String: [(String, Double)]]

    func distance(_ query: String, _ candidate: String) -> Double? {
        guard let rows = distances[query] else { return nil }
        for (fragment, distance) in rows where candidate.contains(fragment) { return distance }
        return nil
    }
}

final class DiagramHistorySearchTests: XCTestCase {
    private func entry(_ title: String, _ source: String, minutesAgo: Int = 0) -> DiagramHistoryEntry {
        DiagramHistoryEntry(
            id: UUID(),
            title: title,
            source: source,
            recordedAt: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60),
            origin: .clipboard
        )
    }

    func testAnEmptyQueryIsNotASearch() {
        let rows = [entry("A", "flowchart LR\n  A --> B"), entry("B", "flowchart LR\n  C --> D")]
        let found = DiagramHistorySearch.search(rows, query: "   ")
        XCTAssertEqual(found.matched, rows)
        XCTAssertTrue(found.related.isEmpty)
    }

    func testAWordInTheTitleMatches() {
        let wanted = entry("Checkout flow", "flowchart LR\n  Cart --> Pay")
        let other = entry("Deploy", "flowchart LR\n  Build --> Ship")
        let found = DiagramHistorySearch.search([wanted, other], query: "checkout")
        XCTAssertEqual(found.matched.map(\.id), [wanted.id])
    }

    func testAWordOnlyInTheSourceMatches() {
        // The point of searching the source: an identifier means nothing to an embedding and
        // everything to the person who wrote it.
        let wanted = entry("A → B", "flowchart LR\n  getUserToken --> validate")
        let other = entry("C → D", "flowchart LR\n  render --> paint")
        let found = DiagramHistorySearch.search([wanted, other], query: "getUserToken")
        XCTAssertEqual(found.matched.map(\.id), [wanted.id])
    }

    func testMatchingIgnoresCaseAndAccents() {
        let wanted = entry("Café Menu", "flowchart LR\n  Order --> Serve")
        XCTAssertEqual(DiagramHistorySearch.search([wanted], query: "cafe").matched.count, 1)
    }

    func testMeaningFindsWhatTheWordsDoNot() {
        let wanted = entry("Checkout flow", "flowchart LR\n  Cart --> Pay")
        let other = entry("Deploy", "flowchart LR\n  Build --> Ship")
        let index = StubIndex(distances: ["payment": [("Checkout", 0.4), ("Deploy", 1.4)]])
        let found = DiagramHistorySearch.search([wanted, other], query: "payment", index: index)
        XCTAssertTrue(found.matched.isEmpty)
        XCTAssertEqual(found.related.map(\.id), [wanted.id])
    }

    func testNeighboursComeBackNearestFirst() {
        let near = entry("Checkout flow", "flowchart LR\n  Cart --> Pay")
        let far = entry("Refunds", "flowchart LR\n  Ask --> Refund")
        let index = StubIndex(distances: ["payment": [("Refunds", 0.7), ("Checkout", 0.3)]])
        let found = DiagramHistorySearch.search([far, near], query: "payment", index: index)
        XCTAssertEqual(found.related.map(\.id), [near.id, far.id])
    }

    /// A guess is never offered beside an answer. The model rates the checkout diagram far closer,
    /// and it is still not what was asked for.
    func testAGuessIsNotOfferedWhenSomethingActuallyMatched() {
        let literal = entry("Payment retries", "flowchart LR\n  Fail --> Retry")
        let neighbour = entry("Checkout flow", "flowchart LR\n  Cart --> Pay")
        let index = StubIndex(distances: ["payment": [("Checkout", 0.1)]])
        let found = DiagramHistorySearch.search([neighbour, literal], query: "payment", index: index)
        XCTAssertEqual(found.matched.map(\.id), [literal.id])
        XCTAssertTrue(found.related.isEmpty)
    }

    func testOnlyAFewGuessesAreEverMade() {
        let rows = (0..<10).map { entry("Row \($0)", "flowchart LR\n  N\($0) --> Done") }
        let index = StubIndex(distances: ["payment": rows.enumerated().map { ("Row \($0.offset)", 0.5) }])
        let found = DiagramHistorySearch.search(rows, query: "payment", index: index)
        XCTAssertEqual(found.related.count, DiagramHistorySearch.relatedLimit)
    }

    func testARowIsNeverListedTwice() {
        let both = entry("Payment", "flowchart LR\n  Cart --> Pay")
        let index = StubIndex(distances: ["payment": [("Payment", 0.1)]])
        let found = DiagramHistorySearch.search([both], query: "payment", index: index)
        XCTAssertEqual(found.matched.count + found.related.count, 1)
    }

    func testDistantThingsAreNotNeighbours() {
        let other = entry("Deploy", "flowchart LR\n  Build --> Ship")
        let index = StubIndex(distances: ["payment": [("Deploy", 1.4)]])
        XCTAssertTrue(DiagramHistorySearch.search([other], query: "payment", index: index).isEmpty)
    }

    func testWithNoModelForTheLanguageOnlyTheWordsMatch() {
        let wanted = entry("결제 흐름", "flowchart LR\n  Cart --> Pay")
        let other = entry("배포", "flowchart LR\n  Build --> Ship")
        // The stub answers nil for everything, which is what NLEmbedding does for a language it
        // has no model for.
        let index = StubIndex(distances: [:])
        let found = DiagramHistorySearch.search([wanted, other], query: "결제", index: index)
        XCTAssertEqual(found.matched.map(\.id), [wanted.id])
    }

    func testTheHaystackIsTheWordsWithoutTheSyntax() {
        let row = entry("Checkout flow", "flowchart LR\n  Cart[Shopping cart] --> Pay[Card payment]")
        let haystack = DiagramHistorySearch.haystack(row)
        XCTAssertTrue(haystack.hasPrefix("Checkout flow"))
        XCTAssertTrue(haystack.contains("Shopping"))
        XCTAssertTrue(haystack.contains("payment"))
        // Mermaid's own vocabulary means the same thing in every diagram, so it says nothing about
        // this one.
        XCTAssertFalse(haystack.contains("flowchart"))
        XCTAssertFalse(haystack.contains("LR"))
        XCTAssertFalse(haystack.contains("-->"))
    }

    func testARepeatedWordIsWeighedOnce() {
        let row = entry("Loop", "flowchart LR\n  Retry --> Retry --> Retry")
        XCTAssertEqual(DiagramHistorySearch.haystack(row), "Loop Retry")
    }

    func testAVeryLongDiagramIsCutBeforeItIsWeighed() {
        let long = entry("Big", "flowchart LR\n" + (0..<500).map { "  N\($0) --> M\($0)" }.joined(separator: "\n"))
        // Sixty words is a paragraph; a thousand lines averaged into one vector says nothing about
        // any of them.
        XCTAssertLessThanOrEqual(DiagramHistorySearch.haystack(long).split(separator: " ").count, 61)
    }
}
