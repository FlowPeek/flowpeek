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
        history.record(title: "Two", source: flowchart(["C --> D"]), origin: .ai, at: start.addingTimeInterval(9_000))
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
        // A positive number below the range, not 0: zero is the off switch, which
        // `testZeroIsOffRatherThanTheSmallestHistory` covers.
        history.setLimit(2)
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

    /// The title a diagram carries is a label, never an identity. Every answer an assistant writes
    /// comes with a title the model chose, and "Mermaid Diagram" is what the app itself falls back
    /// to, so two unrelated diagrams sharing one is the ordinary case rather than a strange one.
    func testTwoDiagramsUnderTheSameTitleAreTwoDiagrams() {
        var history = DiagramHistory()
        let first = flowchart(["A --> B", "B --> C"])
        let second = "sequenceDiagram\n  Alice ->> Bob: hello\n  Bob -->> Alice: hi"
        history.record(title: "Mermaid Diagram", source: first, origin: .ai, at: start)
        history.record(title: "Mermaid Diagram", source: second, origin: .ai, at: start.addingTimeInterval(300))

        XCTAssertEqual(history.entries.count, 2)
        // Both still readable: neither recording overwrote the other's source.
        XCTAssertEqual(Set(history.entries.map(\.source)), [first, second])
    }

    /// Two small diagrams of the same kind share their declaration line and, sooner or later, a
    /// line of their own. Looking alike is not being the same.
    func testTwoSmallDiagramsThatShareMostOfTheirLinesAreStillTwoRows() {
        var history = DiagramHistory()
        history.record(title: "First", source: flowchart(["A --> B", "C --> D"]), origin: .ai, at: start)
        history.record(title: "Second", source: flowchart(["A --> B", "E --> F"]), origin: .ai, at: start.addingTimeInterval(60))

        XCTAssertEqual(history.entries.map(\.title), ["Second", "First"])
        XCTAssertTrue(history.entries.contains { $0.source.contains("C --> D") })
    }

    func testAnEditRecordedWithoutSayingWhatItRevisesIsItsOwnRow() {
        var history = DiagramHistory()
        let original = flowchart((1...10).map { "N\($0) --> N\($0 + 1)" })
        history.record(title: "Draft", source: original, origin: .ai, at: start)
        history.record(title: "Draft", source: original + "\n  N11 --> N12", origin: .ai, at: start.addingTimeInterval(60))
        XCTAssertEqual(history.entries.count, 2)
    }

    // MARK: - Being told which diagram this is

    func testFiveGoesAtOneDiagramLeaveOneRow() throws {
        var history = DiagramHistory()
        var identity = try XCTUnwrap(
            history.record(title: "Checkout", source: flowchart(["A --> B"]), origin: .ai, at: start)
        ).id
        for step in 1...4 {
            identity = try XCTUnwrap(
                history.record(
                    title: "Checkout",
                    source: flowchart(["A --> B"] + (1...step).map { "S\($0) --> T\($0)" }),
                    origin: .ai,
                    at: start.addingTimeInterval(Double(step) * 60),
                    revising: identity
                )
            ).id
        }
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertTrue(history.entries[0].source.contains("S4 --> T4"))
    }

    /// An identifier that names nothing yet becomes the new row's own, so a window can choose one
    /// before it has anything to record and keep passing the same one afterwards.
    func testAnIdentifierChosenBeforeTheFirstRecordingNamesTheRowItMakes() {
        var history = DiagramHistory()
        let identity = UUID()
        history.record(title: "Draft", source: flowchart(["A --> B"]), origin: .ai, at: start, revising: identity)
        history.record(
            title: "Draft",
            source: flowchart(["A --> B", "B --> C"]),
            origin: .ai,
            at: start.addingTimeInterval(60),
            revising: identity
        )
        XCTAssertEqual(history.entries.map(\.id), [identity])
        XCTAssertTrue(history.entries[0].source.contains("B --> C"))
    }

    /// Replacing a row is the one thing here that can destroy a diagram, so it has to reach exactly
    /// the row it was pointed at and nothing beside it.
    func testARevisionReplacesTheRowItNamesAndNoOther() throws {
        var history = DiagramHistory()
        let target = try XCTUnwrap(
            history.record(title: "Checkout", source: flowchart(["A --> B"]), origin: .ai, at: start)
        ).id
        let bystander = flowchart(["P --> Q"])
        history.record(title: "Deploy", source: bystander, origin: .ai, at: start.addingTimeInterval(60))

        history.record(
            title: "Checkout",
            source: flowchart(["A --> B", "B --> C"]),
            origin: .ai,
            at: start.addingTimeInterval(120),
            revising: target
        )

        XCTAssertEqual(history.entries.map(\.title), ["Checkout", "Deploy"])
        XCTAssertEqual(history.entries[0].id, target)
        XCTAssertTrue(history.entries[0].source.contains("B --> C"))
        // The row that was not named still reads exactly as it was recorded.
        XCTAssertEqual(history.entries[1].source, bystander)
    }

    func testARevisionCanRenameTheRowItReplaces() throws {
        var history = DiagramHistory()
        let identity = try XCTUnwrap(
            history.record(title: "Draft", source: flowchart(["A --> B"]), origin: .ai, at: start)
        ).id
        history.record(
            title: "Order pipeline",
            source: flowchart(["A --> B", "B --> C"]),
            origin: .ai,
            at: start.addingTimeInterval(120),
            revising: identity
        )
        XCTAssertEqual(history.entries.map(\.title), ["Order pipeline"])
    }

    /// A stale identifier -- a row the user deleted while the window that made it was still open --
    /// starts a row rather than landing on whatever happens to be at the top.
    func testAnIdentifierNoRowCarriesAddsARowRatherThanReplacingOne() {
        var history = DiagramHistory()
        let kept = flowchart(["A --> B"])
        history.record(title: "Checkout", source: kept, origin: .ai, at: start)
        history.record(
            title: "Elsewhere",
            source: flowchart(["X --> Y"]),
            origin: .ai,
            at: start.addingTimeInterval(60),
            revising: UUID()
        )
        XCTAssertEqual(history.entries.map(\.title), ["Elsewhere", "Checkout"])
        XCTAssertEqual(history.entries[1].source, kept)
    }

    // MARK: - Order

    /// `record` takes the date it is handed, and a clock that stepped backwards hands it an older
    /// one. The list still has to read newest first, now rather than after the next launch.
    func testARecordingCarryingAnOlderDateLandsWhereItsDatePutsIt() throws {
        var history = DiagramHistory()
        let identity = try XCTUnwrap(
            history.record(title: "One", source: flowchart(["A --> B"]), origin: .ai, at: start)
        ).id
        history.record(title: "Two", source: flowchart(["C --> D"]), origin: .ai, at: start.addingTimeInterval(86_400))
        history.record(
            title: "One",
            source: flowchart(["A --> B", "B --> C"]),
            origin: .ai,
            at: start.addingTimeInterval(-86_400),
            revising: identity
        )

        XCTAssertEqual(history.entries.map(\.title), ["Two", "One"])
        XCTAssertEqual(
            history.entries.map(\.recordedAt),
            history.entries.map(\.recordedAt).sorted(by: >)
        )
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
        // Six distinct diagrams against the smallest maximum there is, so the trim has something to
        // do as well as the sort and the fold: a file written when the maximum was higher, or typed
        // by hand, is exactly how a list arrives too long.
        var entries: [DiagramHistoryEntry] = [
            DiagramHistoryEntry(title: "Old", source: shared, recordedAt: start, origin: .ai),
            DiagramHistoryEntry(title: "New", source: shared, recordedAt: start.addingTimeInterval(86_400), origin: .ai),
            DiagramHistoryEntry(title: "Empty", source: "", recordedAt: .distantFuture, origin: .ai),
        ]
        for index in 0..<5 {
            entries.append(
                DiagramHistoryEntry(
                    title: "D\(index)",
                    source: flowchart(["N\(index) --> M\(index)"]),
                    recordedAt: start.addingTimeInterval(Double(index) * 3_600),
                    origin: .ai
                )
            )
        }
        let history = DiagramHistory(entries: entries, limit: DiagramHistory.limitRange.lowerBound)
        // "New" is the folded pair, dated latest; "D0" is a diagram too many and is the one dropped.
        XCTAssertEqual(history.entries.map(\.title), ["New", "D4", "D3", "D2", "D1"])
    }

    /// A list is drawn keyed on the identifier and a row is removed by it, so a file carrying the
    /// same one twice would leave the app deleting a row nobody clicked.
    func testTwoRowsSharingAnIdentifierDoNotBothLoad() {
        let identity = UUID()
        let history = DiagramHistory(
            entries: [
                DiagramHistoryEntry(id: identity, title: "A", source: flowchart(["A --> B"]), recordedAt: start, origin: .ai),
                DiagramHistoryEntry(
                    id: identity,
                    title: "B",
                    source: flowchart(["C --> D"]),
                    recordedAt: start.addingTimeInterval(60),
                    origin: .ai
                ),
            ]
        )
        XCTAssertEqual(history.entries.map(\.title), ["B"])
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

// MARK: - Switched off

extension DiagramHistoryTests {
    func testZeroIsOffRatherThanTheSmallestHistory() {
        XCTAssertEqual(DiagramHistory.clamp(0), DiagramHistory.off)
        XCTAssertEqual(DiagramHistory.clamp(-4), DiagramHistory.off)
        // No gap for a stored value to fall into between off and the smallest real history.
        XCTAssertEqual(DiagramHistory.clamp(1), DiagramHistory.limitRange.lowerBound)
    }

    func testSwitchedOffRemembersNothing() {
        var history = DiagramHistory(limit: DiagramHistory.off)
        XCTAssertFalse(history.isRemembering)
        XCTAssertNil(history.record(title: "A", source: "flowchart LR\n  A --> B", origin: .clipboard))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSwitchingOffForgetsWhatWasAlreadyThere() {
        var history = DiagramHistory(limit: 20)
        history.record(title: "A", source: "flowchart LR\n  A --> B", origin: .clipboard)
        history.record(title: "B", source: "flowchart LR\n  C --> D", origin: .clipboard)
        XCTAssertEqual(history.entries.count, 2)
        history.setLimit(DiagramHistory.off)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSwitchingBackOnStartsEmpty() {
        var history = DiagramHistory(limit: 20)
        history.record(title: "A", source: "flowchart LR\n  A --> B", origin: .clipboard)
        history.setLimit(DiagramHistory.off)
        history.setLimit(DiagramHistory.defaultLimit)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertNotNil(history.record(title: "C", source: "flowchart LR\n  E --> F", origin: .clipboard))
    }

    func testAFileFromBeforeItWasSwitchedOffIsNotLoaded() {
        let kept = DiagramHistoryEntry(
            id: UUID(),
            title: "A",
            source: "flowchart LR\n  A --> B",
            recordedAt: Date(),
            origin: .clipboard
        )
        let history = DiagramHistory(entries: [kept], limit: DiagramHistory.off)
        XCTAssertTrue(history.entries.isEmpty)
    }
}

// MARK: - Kept by age as well as by count

extension DiagramHistoryTests {
    private func aged(_ title: String, hoursAgo: Double, now: Date) -> DiagramHistoryEntry {
        DiagramHistoryEntry(
            id: UUID(),
            title: title,
            source: "flowchart LR\n  \(title) --> Done",
            recordedAt: now.addingTimeInterval(-hoursAgo * 3600),
            origin: .clipboard
        )
    }

    func testForeverIsTheDefaultAndKeepsEverything() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = DiagramHistory(
            entries: [aged("Old", hoursAgo: 24 * 400, now: now)],
            limit: 20,
            now: now
        )
        XCTAssertEqual(history.age, .forever)
        XCTAssertEqual(history.entries.count, 1)
    }

    func testWhatIsOlderThanTheAgeIsNotLoaded() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = DiagramHistory(
            entries: [aged("Fresh", hoursAgo: 2, now: now), aged("Stale", hoursAgo: 30, now: now)],
            limit: 20,
            age: .day,
            now: now
        )
        XCTAssertEqual(history.entries.map(\.title), ["Fresh"])
    }

    func testShorteningTheAgeForgetsNowRatherThanAtTheNextDiagram() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var history = DiagramHistory(
            entries: [aged("Fresh", hoursAgo: 2, now: now), aged("Older", hoursAgo: 48, now: now)],
            limit: 20,
            age: .week,
            now: now
        )
        XCTAssertEqual(history.entries.count, 2)
        history.setAge(.day, now: now)
        XCTAssertEqual(history.entries.map(\.title), ["Fresh"])
    }

    func testTimePassingWithNothingHappeningStillForgets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var history = DiagramHistory(entries: [aged("Fresh", hoursAgo: 2, now: now)], limit: 20, age: .day, now: now)
        XCTAssertEqual(history.entries.count, 1)
        // Nothing recorded, nothing changed -- two days simply went by.
        XCTAssertTrue(history.pruneExpired(now: now.addingTimeInterval(48 * 3600)))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPruningReportsWhetherItChangedAnything() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var history = DiagramHistory(entries: [aged("Fresh", hoursAgo: 1, now: now)], limit: 20, age: .day, now: now)
        XCTAssertFalse(history.pruneExpired(now: now))
    }

    func testWhicheverLimitForgetsFirstWins() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<10).map { aged("D\($0)", hoursAgo: Double($0) * 3, now: now) }
        // Five rows by count; the age would have kept eight.
        let byCount = DiagramHistory(entries: rows, limit: 5, age: .day, now: now)
        XCTAssertEqual(byCount.entries.count, 5)
        // Nine rows by age -- everything up to and including the one recorded exactly a day ago --
        // where the maximum would have kept all ten.
        let byAge = DiagramHistory(entries: rows, limit: 20, age: .day, now: now)
        XCTAssertEqual(byAge.entries.count, 9)
    }

    func testRecordingAlsoDropsWhatHasAgedOut() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var history = DiagramHistory(entries: [aged("Stale", hoursAgo: 2, now: now)], limit: 20, age: .day, now: now)
        let later = now.addingTimeInterval(48 * 3600)
        history.record(title: "New", source: "flowchart LR\n  X --> Y", origin: .clipboard, at: later)
        XCTAssertEqual(history.entries.map(\.title), ["New"])
    }
}
