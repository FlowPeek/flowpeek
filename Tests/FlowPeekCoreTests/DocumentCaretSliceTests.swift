import XCTest
@testable import FlowPeekCore

/// The caret route reads a whole document out of an editor and has to find the one diagram the user
/// is actually in. Every offset here is a UTF-16 offset, because that is what an
/// `AXSelectedTextRange` location counts.
final class DocumentCaretSliceTests: XCTestCase {
    private let flowchart = """
        flowchart TD
          A[Start] --> B[End]
        """
    private let sequence = """
        sequenceDiagram
          Alice->>Bob: Hello
        """
    private let pie = """
        pie title Answers
          "Yes" : 70
          "No" : 30
        """

    /// Every assertion below is only worth anything if the range really does address the slice, so
    /// the range is checked against the document the way the editor would index it.
    private func substring(_ document: String, _ range: NSRange) -> String {
        (document as NSString).substring(with: range)
    }

    private func offset(of needle: String, in document: String) -> Int {
        let range = (document as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) is not in the document")
        return range.location
    }

    // MARK: - Inside a fenced block

    func testACaretInsideAFencedBlockSlicesThatBlock() throws {
        let document = """
            # Notes

            Some prose about the diagram.

            ```mermaid
            \(flowchart)
            ```

            More prose afterwards.
            """
        let caret = offset(of: "A[Start]", in: document)
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: caret))

        XCTAssertEqual(slice.detection.extractedSource, flowchart)
        // The fences are part of the slice: the detector strips them, and the range has to name
        // something the editor could select.
        XCTAssertEqual(substring(document, slice.range), "```mermaid\n\(flowchart)\n```")
    }

    func testTheOpeningAndClosingFenceLinesCountAsInsideTheBlock() throws {
        let document = "Intro\n\n```mermaid\n\(flowchart)\n```\n\nOutro\n"
        let onOpener = offset(of: "```mermaid", in: document)
        let onCloser = offset(of: "```\n\nOutro", in: document)

        XCTAssertEqual(
            DocumentCaretSlicer.slice(document: document, caret: onOpener)?.detection.extractedSource,
            flowchart
        )
        XCTAssertEqual(
            DocumentCaretSlicer.slice(document: document, caret: onCloser)?.detection.extractedSource,
            flowchart
        )
    }

    // MARK: - Outside every block

    func testACaretInProseBetweenTwoBlocksFindsNothing() {
        let document = """
            ```mermaid
            \(flowchart)
            ```

            Prose that sits between the two diagrams.

            ```mermaid
            \(sequence)
            ```
            """
        let caret = offset(of: "sits between", in: document)
        // Deliberately nothing: the nearest block is not the block the caret is in, and framing it
        // would open a diagram the user was never pointing at.
        XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: caret))
    }

    func testACaretInACodeBlockOfAnotherLanguageFindsNothing() {
        let document = """
            ```swift
            let graph = "flowchart TD"
            print(graph)
            ```
            """
        XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: offset(of: "print", in: document)))
    }

    func testADocumentWithNoDiagramAtAllFindsNothing() {
        let document = """
            # Release notes

            Nothing in here is a diagram, though it does talk about a graph of
            dependencies and a sequence of steps.
            """
        for caret in [0, 20, (document as NSString).length] {
            XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: caret), "caret \(caret)")
        }
    }

    func testAnEmptyDocumentFindsNothing() {
        XCTAssertNil(DocumentCaretSlicer.slice(document: "", caret: 0))
    }

    // MARK: - Which block

    func testTheSecondOfThreeBlocksIsTheOneSliced() throws {
        let document = """
            ```mermaid
            \(flowchart)
            ```

            ```mermaid
            \(sequence)
            ```

            ```mermaid
            \(pie)
            ```
            """
        let caret = offset(of: "Alice", in: document)
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: caret))

        XCTAssertEqual(slice.detection.expectedType, "sequence")
        XCTAssertEqual(slice.detection.extractedSource, sequence)
        XCTAssertEqual(substring(document, slice.range), "```mermaid\n\(sequence)\n```")
    }

    // MARK: - The document's edges

    func testACaretAtTheVeryStartSlicesABlockThatOpensTheDocument() throws {
        let document = "```mermaid\n\(flowchart)\n```\n\nProse afterwards.\n"
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: 0))
        XCTAssertEqual(slice.detection.extractedSource, flowchart)
        XCTAssertEqual(slice.range.location, 0)
    }

    func testACaretAtTheVeryEndSlicesABlockThatClosesTheDocument() throws {
        let document = "Prose first.\n\n```mermaid\n\(sequence)\n```"
        let end = (document as NSString).length
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: end))
        XCTAssertEqual(slice.detection.extractedSource, sequence)
        XCTAssertEqual(slice.range.location + slice.range.length, end)
    }

    func testACaretPastTheEndIsClampedToTheEndOfTheBuffer() throws {
        // A stale offset from an editor whose buffer has since shortened reads as "at the end",
        // which is a position, rather than as nothing at all.
        let closes = "Prose first.\n\n```mermaid\n\(sequence)\n```"
        let past = (closes as NSString).length + 5_000
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: closes, caret: past))
        XCTAssertEqual(slice.detection.extractedSource, sequence)

        // And the clamp is only a clamp: with a line after the block, the end of the buffer is not
        // in the block, and the answer is the same nothing prose gets anywhere else.
        let continues = closes + "\n\nOutro.\n"
        XCTAssertNil(DocumentCaretSlicer.slice(document: continues, caret: (continues as NSString).length + 5_000))
    }

    func testANegativeCaretIsClampedToTheStart() throws {
        let document = "```mermaid\n\(flowchart)\n```\n"
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: -12))
        XCTAssertEqual(slice.detection.extractedSource, flowchart)
    }

    // MARK: - A file that is a diagram

    func testAFileWithNoFencesIsItselfTheBlock() throws {
        let document = "\(flowchart)\n"
        for caret in [4, (document as NSString).length] {
            let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: caret), "caret \(caret)")
            XCTAssertEqual(slice.detection.extractedSource, flowchart)
            XCTAssertEqual(slice.range.location, 0)
            // The file's trailing newline is not part of the block, but a caret parked after it is
            // still in it: that is where the cursor sits while a diagram file is being typed.
            XCTAssertEqual(substring(document, slice.range), flowchart)
        }
    }

    func testAFenceFreeFileMayOpenWithFrontMatterACommentOrADirective() throws {
        let documents = [
            "---\ntitle: Shipping\n---\n\(flowchart)\n",
            "%% drawn for the runbook\n\(flowchart)\n",
            "%%{init: {'theme': 'dark'}}%%\n\(flowchart)\n"
        ]
        for document in documents {
            let caret = offset(of: "A[Start]", in: document)
            let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: caret), document)
            XCTAssertTrue(slice.detection.extractedSource.hasSuffix("A[Start] --> B[End]"), document)
        }
    }

    /// Prose is not a diagram because it opens with a word one of them uses. Every line here is
    /// something somebody might have in a scratch buffer, and every one of them detects as a
    /// diagram on its own -- the first line has to read as a declaration, not merely as a match.
    func testAFenceFreeDocumentThatOnlyOpensWithADiagramWordFindsNothing() {
        let openings = [
            "graph of dependencies",
            "timeline of the migration",
            "pie in the sky planning",
            "info about the build",
            "block by block we shipped it",
            "erDiagram is what we need here"
        ]
        for opening in openings {
            let document = "\(opening)\nsecond line of prose\nthird line\n"
            XCTAssertGreaterThanOrEqual(
                MermaidDetector.detect(document).confidence, .likely,
                "\(opening) was expected to fool the detector on its own"
            )
            for caret in [0, 8, (document as NSString).length] {
                XCTAssertNil(
                    DocumentCaretSlicer.slice(document: document, caret: caret),
                    "\(opening) at caret \(caret)"
                )
            }
        }
    }

    /// One ordinary word is the same trap one word wide. The starters are prefixes and none of them
    /// stops at a word boundary, so a single lowercase word that merely begins with one leaves
    /// nothing after it to judge -- and a scratch buffer that opens with one is still a note.
    func testAFenceFreeDocumentOpeningWithOneOrdinaryWordFindsNothing() {
        for word in ["blocking", "information", "graphs", "pies", "timelines", "ganttry",
                     "journeyman", "mindmapping", "infographic"] {
            let document = "\(word)\nsecond line of prose\nthird line\n"
            XCTAssertGreaterThanOrEqual(
                MermaidDetector.detect(document).confidence, .likely,
                "\(word) was expected to fool the detector on its own"
            )
            XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: 3), word)
        }
    }

    /// The declaration line is where the fence-free route gets its evidence, so the forms mermaid
    /// itself accepts there all have to pass -- including the ones whose real keyword is longer than
    /// the head the table matches, which is why the word gate cannot simply demand an exact match.
    func testEveryShapeOfDeclarationLineIsAccepted() {
        for opening in ["flowchart LR", "graph TD;", "gitGraph TB:", "pie showData", "pie title Answers",
                        "sequenceDiagram", "erDiagram", "stateDiagram-v2", "requirementDiagram",
                        "xychart-beta horizontal", "C4Context title Banking", "block-beta",
                        "architecture-beta", "sankey-beta", "packet-beta", "treemap-beta",
                        "flowchart-elk LR", "swimlane-beta", "cynefin-beta", "gitGraph:",
                        "radar-beta:", "graph;", "stateDiagram-v2;"] {
            XCTAssertTrue(MermaidDetector.declaresDiagram(opening), opening)
        }
        for prose in ["graph of dependencies", "pie in the sky", "About the sequenceDiagram", "",
                      "blocking", "graphs", "journeyman", "infographic", "ganttry"] {
            XCTAssertFalse(MermaidDetector.declaresDiagram(prose), prose)
        }
    }

    // MARK: - What one read is allowed to cost

    /// An editor hands over its whole buffer and the split below it is linear in that, so the size
    /// is refused before any of the work is done: a 900 KB buffer measured 74.9 ms of it, on the
    /// main actor, repeated for as long as the modifier is held.
    func testADocumentTooBigToSliceIsRefusedOutright() {
        let padding = String(repeating: "prose about the diagram\n", count: 4_000)
        let document = "```mermaid\n\(flowchart)\n```\n\(padding)"
        XCTAssertGreaterThan((document as NSString).length, AmbientPeekPolicy.maximumDocumentCharacters)
        XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: 20))
        // The same document under the cap still slices, so it is the size that refused it.
        let shorter = "```mermaid\n\(flowchart)\n```\n"
        XCTAssertNotNil(DocumentCaretSlicer.slice(document: shorter, caret: 20))
    }

    /// The slice runs on the same clock as the accessibility calls that fetched the document, so a
    /// budget that is already spent stops it -- and the monitor reports that as an unfinished read
    /// rather than as "no diagram here".
    func testADeadlineThatHasPassedStopsTheSlice() {
        let document = "```mermaid\n\(flowchart)\n```\n"
        XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: 20, before: Date.distantPast))
        XCTAssertNotNil(DocumentCaretSlicer.slice(document: document, caret: 20, before: Date() + 60))
    }

    /// The split reads the clock as it goes, not only at its two ends: a document at the cap is
    /// 64,000 characters of work between those two checks, and the read that fetched it has usually
    /// spent most of its budget getting there. The clock is passed in because arranging for the wall
    /// clock to expire part-way through a split is a race, and this is not.
    func testTheSplitChecksTheClockAsItGoesAndStopsAtTheFirstExpiredReading() {
        let document = "```mermaid\n\(flowchart)\n```\n" + String(repeating: "prose about the diagram\n", count: 1_000)
        let length = (document as NSString).length
        XCTAssertGreaterThan(length, DocumentCaretSlicer.clockInterval * 4)

        var readings = 0
        let slice = DocumentCaretSlicer.slice(
            document: document,
            caret: 20,
            minimumConfidence: AmbientPeekPolicy.minimumConfidence,
            before: .distantFuture,
            clock: { readings += 1; return Date() }
        )
        XCTAssertNotNil(slice)
        XCTAssertGreaterThanOrEqual(readings, length / DocumentCaretSlicer.clockInterval)

        // Expired at the first reading inside the split, and nothing is read after it: the split
        // stops there rather than finishing the document and letting the check on the far side
        // answer for it.
        let start = Date()
        var expiring = 0
        XCTAssertNil(DocumentCaretSlicer.slice(
            document: document,
            caret: 20,
            minimumConfidence: AmbientPeekPolicy.minimumConfidence,
            before: start + 1,
            clock: { expiring += 1; return expiring == 1 ? start : start + 60 }
        ))
        XCTAssertEqual(expiring, 2)
    }

    func testAnUntaggedFenceIsStillWorthReading() throws {
        let document = "Intro\n\n```\n\(flowchart)\n```\n"
        let caret = offset(of: "A[Start]", in: document)
        XCTAssertEqual(
            DocumentCaretSlicer.slice(document: document, caret: caret)?.detection.extractedSource,
            flowchart
        )
    }

    // MARK: - Line endings

    func testCRLFOffsetsCountBothCodeUnitsOfEveryTerminator() throws {
        let lf = "Intro\n\n```mermaid\n\(flowchart)\n```\n\nOutro\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let caret = offset(of: "A[Start]", in: crlf)
        // The same block sits at a higher offset in the CRLF copy, which is the whole point: the
        // caret is counted in code units and every terminator there is two of them.
        XCTAssertGreaterThan(caret, offset(of: "A[Start]", in: lf))

        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: crlf, caret: caret))
        XCTAssertEqual(slice.detection.extractedSource, flowchart)
        XCTAssertEqual(substring(crlf, slice.range), "```mermaid\r\n\(flowchart.replacingOccurrences(of: "\n", with: "\r\n"))\r\n```")
        // The slice itself is handed on with the line endings the detector works in.
        XCTAssertFalse(slice.text.contains("\r"))
    }

    func testAnOffsetInsideACRLFTerminatorStillLandsInTheBlock() throws {
        let document = "```mermaid\r\n\(flowchart.replacingOccurrences(of: "\n", with: "\r\n"))\r\n```\r\n"
        // Between the \r and the \n that close the opening fence: an editor should never report
        // this, and clamping it to a line rather than refusing it costs nothing.
        let caret = offset(of: "\r\nflowchart", in: document) + 1
        XCTAssertEqual(
            DocumentCaretSlicer.slice(document: document, caret: caret)?.detection.expectedType,
            "flowchart-v2"
        )
    }

    // MARK: - A real editor's buffer

    func testAThirtyThousandCharacterDocumentSlicesTheBlockAroundTheCaret() throws {
        // VS Code hands out the whole file: 30031 characters for a 2000-line document, measured, so
        // this is the size the slicer actually runs against.
        var document = ""
        for index in 0..<500 {
            document += "## Section \(index)\n\nProse about section \(index) that runs on a little.\n\n"
            if index == 250 { document += "```mermaid\n\(sequence)\n```\n\n" }
            if index == 400 { document += "```mermaid\n\(pie)\n```\n\n" }
        }
        XCTAssertGreaterThan((document as NSString).length, 30_000)

        let caret = offset(of: "Alice", in: document)
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: caret))
        XCTAssertEqual(slice.detection.extractedSource, sequence)
        XCTAssertEqual(substring(document, slice.range), "```mermaid\n\(sequence)\n```")

        // And the second diagram is not the first one's slice by accident.
        let later = offset(of: "\"Yes\"", in: document)
        XCTAssertEqual(
            DocumentCaretSlicer.slice(document: document, caret: later)?.detection.expectedType,
            "pie"
        )
        // Prose in between belongs to neither.
        XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: offset(of: "Section 300", in: document)))
    }

    // MARK: - Characters wider than one code unit

    func testAnEmojiAheadOfTheBlockShiftsTheOffsetByTwoCodeUnits() throws {
        let document = "🎉 Intro\n\n```mermaid\n\(flowchart)\n```\n"
        let caret = offset(of: "A[Start]", in: document)
        let slice = try XCTUnwrap(DocumentCaretSlicer.slice(document: document, caret: caret))
        XCTAssertEqual(substring(document, slice.range), "```mermaid\n\(flowchart)\n```")
    }

    // MARK: - Confidence

    func testABlockThatOnlyStartsLikeADiagramIsRefused() {
        // A starter with no body detects as `.weak`, and the ambient route requires `.likely`:
        // an outline over an ordinary paragraph is worse than one that never appears.
        let document = "```mermaid\ngraph\n```\n"
        XCTAssertNil(DocumentCaretSlicer.slice(document: document, caret: 12))
        XCTAssertNotNil(DocumentCaretSlicer.slice(document: document, caret: 12, minimumConfidence: .weak))
    }
}
