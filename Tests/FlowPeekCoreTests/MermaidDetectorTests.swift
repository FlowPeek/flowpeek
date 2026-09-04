import XCTest
@testable import FlowPeekCore

/// One test per row of the detection specification's acceptance table.
final class MermaidDetectorTests: XCTestCase {
    private func expect(
        _ input: String,
        _ confidence: MermaidDetection.Confidence,
        _ type: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let detection = MermaidDetector.detect(input)
        XCTAssertEqual(detection.confidence, confidence, "confidence", file: file, line: line)
        XCTAssertEqual(detection.expectedType, type, "detector id", file: file, line: line)
    }

    // MARK: - B, baselines

    func testB01GraphTD() { expect("graph TD\nA-->B", .certain, "flowchart-v2") }
    func testB02FlowchartLR() { expect("flowchart LR\nA-->B", .certain, "flowchart-v2") }
    func testB03SequenceDiagram() { expect("sequenceDiagram\nAlice->>Bob: Hi", .certain, "sequence") }
    func testB04LeadingIndent() { expect("   graph TD\n A-->B", .certain, "flowchart-v2") }
    func testB05ClassDiagramV2() { expect("classDiagram-v2\nA <|-- B", .certain, "classDiagram") }
    func testB06StateDiagramV2BeforeBase() { expect("stateDiagram-v2\n[*] --> S", .certain, "stateDiagram") }
    func testB07BalancedFrontMatter() { expect("---\ntitle: T\n---\ngraph TD\nA-->B", .certain, "flowchart-v2") }
    func testB08SingleLineDirective() { expect("%%{init:{'theme':'dark'}}%%\ngraph TD\nA-->B", .certain, "flowchart-v2") }
    func testB09MultiLineDirective() { expect("%%{init:{\n  'theme':'dark'\n}}%%\ngraph TD\nA-->B", .certain, "flowchart-v2") }
    func testB10LeadingComment() { expect("%% a comment\ngraph TD\nA-->B", .certain, "flowchart-v2") }

    // MARK: - F, fences

    func testF01BalancedMermaidFence() { expect("```mermaid\ngraph TD\nA-->B\n```", .certain, "flowchart-v2") }
    func testF02BareFence() { expect("```\ngraph TD\nA-->B\n```", .certain, "flowchart-v2") }
    func testF03ProseBeforeFence() { expect("Here is the diagram:\n\n```mermaid\ngraph TD\nA-->B\n```", .likely, "flowchart-v2") }
    func testF04HeadingBeforeFence() { expect("## Architecture\n```mermaid\ngraph TD\nA-->B\n```", .likely, "flowchart-v2") }
    func testF05UnclosedFence() { expect("```mermaid\ngraph TD\nA-->B", .likely, "flowchart-v2") }
    func testF06TildeFence() { expect("~~~mermaid\ngraph TD\nA-->B\n~~~", .certain, "flowchart-v2") }
    func testF07MmdInfoString() { expect("```mmd\ngraph TD\nA-->B\n```", .certain, "flowchart-v2") }

    func testF08TakesTheFirstOfTwoBlocksAndLeavesNoFenceBehind() {
        let input = "```mermaid\ngraph TD\nA-->B\n```\n\n```mermaid\ngraph LR\nC-->D\n```"
        let detection = MermaidDetector.detect(input)
        XCTAssertEqual(detection.confidence, .likely)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertEqual(detection.extractedSource, "graph TD\nA-->B")
        XCTAssertFalse(detection.extractedSource.contains("```"))
    }

    func testF09SkipsNonMermaidBlock() { expect("```js\nconst x=1\n```\n```mermaid\ngraph TD\nA-->B\n```", .likely, "flowchart-v2") }
    func testF10FenceAttributes() { expect("```mermaid {highlight=1}\ngraph TD\nA-->B\n```", .likely, "flowchart-v2") }
    func testF11TrailingProse() { expect("```mermaid\ngraph TD\nA-->B\n```\n\nThat's the flow.", .likely, "flowchart-v2") }

    // MARK: - U, Unicode

    func testU01NonBreakingSpaceIsNormalisedForTheRendererToo() {
        let detection = MermaidDetector.detect("graph\u{00A0}TD\nA-->B")
        XCTAssertEqual(detection.confidence, .certain)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertEqual(detection.extractedSource, "graph TD\nA-->B")
        XCTAssertFalse(detection.extractedSource.unicodeScalars.contains("\u{00A0}"))
    }

    func testU02ByteOrderMark() { expect("\u{FEFF}graph TD\nA-->B", .certain, "flowchart-v2") }
    func testU03ByteOrderMarkBeforeFence() { expect("\u{FEFF}```mermaid\ngraph TD\nA-->B\n```", .certain, "flowchart-v2") }

    func testU04CarriageReturns() {
        let detection = MermaidDetector.detect("graph TD\r\nA-->B\r\n")
        XCTAssertEqual(detection.confidence, .certain)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertEqual(detection.extractedSource, "graph TD\nA-->B")
    }

    func testU05LineSeparator() { expect("graph TD\u{2028}A-->B", .certain, "flowchart-v2") }
    func testU06ZeroWidthSpace() { expect("\u{200B}graph TD\nA-->B", .certain, "flowchart-v2") }
    func testU07IdeographicSpace() { expect("graph\u{3000}TD\nA-->B", .certain, "flowchart-v2") }

    // MARK: - C, chrome

    func testC01CopyLabel() { expect("Copy\ngraph TD\nA-->B", .likely, "flowchart-v2") }
    func testC02KoreanCopyLabel() { expect("복사\ngraph TD\nA-->B", .likely, "flowchart-v2") }
    func testC03TrailingChromeIsHarmless() { expect("graph TD\nA-->B\nCopy", .certain, "flowchart-v2") }

    /// The measured mermaid.ai case: an editable code block exposes its content as the field's own
    /// value and again as highlighted text, so a region read hands over the diagram twice. mermaid
    /// reads to the last line and fails on the second starter, so the repeat has to be cut.
    func testC10RepeatedStarterIsTruncated() {
        let once = "eventmodeling\n\ntf 01 ui CartUI\ntf 02 cmd AddItem\ntf 03 evt ItemAdded"
        let detection = MermaidDetector.detect(once + "\n" + once)
        XCTAssertEqual(detection.expectedType, "eventmodeling")
        XCTAssertEqual(detection.extractedSource, once)
    }

    /// Two different diagrams in a row also has to yield one: the first, which is the one the read
    /// was anchored on.
    func testC11SecondDiagramOfTheSameTypeIsDropped() {
        let detection = MermaidDetector.detect("graph TD\nA-->B\ngraph LR\nC-->D")
        XCTAssertEqual(detection.extractedSource, "graph TD\nA-->B")
    }

    /// The cut is keyed on a repeat of *this* diagram's own type, so a body that legitimately uses
    /// a keyword belonging to another diagram type survives intact.
    func testC12ForeignKeywordInBodySurvives() {
        let source = "classDiagram\nclass Order\nclass Item\nOrder ||-- Item"
        let detection = MermaidDetector.detect(source)
        XCTAssertEqual(detection.expectedType, "classDiagram")
        XCTAssertEqual(detection.extractedSource, source)
    }

    func testC04SpaceGutter() {
        let detection = MermaidDetector.detect("1  graph TD\n2  A-->B\n3  B-->C")
        XCTAssertEqual(detection.confidence, .likely)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertEqual(detection.extractedSource, "graph TD\nA-->B\nB-->C")
    }

    func testC05PipeGutter() {
        let detection = MermaidDetector.detect("1 | graph TD\n2 | A-->B\n3 | B-->C")
        XCTAssertEqual(detection.confidence, .likely)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertEqual(detection.extractedSource, "graph TD\nA-->B\nB-->C")
    }

    func testC06SingleNumericLineIsNeverAGutter() {
        let detection = MermaidDetector.detect("graph TD\n1 --> 2")
        XCTAssertEqual(detection.confidence, .certain)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertEqual(detection.extractedSource, "graph TD\n1 --> 2")
    }

    func testC07ShellPrompt() { expect("$ cat diagram.mmd\ngraph TD\nA-->B", .likely, "flowchart-v2") }

    // MARK: - K, keyword coverage

    func testK01C4Context() { expect("C4Context\ntitle X", .likely, "c4") }
    func testK02C4Container() { expect("C4Container\ntitle X", .likely, "c4") }

    func testK03RemainingC4Flavours() {
        expect("C4Component\ntitle X", .likely, "c4")
        expect("C4Dynamic\ntitle X", .likely, "c4")
        expect("C4Deployment\ntitle X", .likely, "c4")
    }

    func testK04LoneInfoIsWeak() { expect("info", .weak, "info") }
    func testK05EventModeling() { expect("eventmodeling\n  triggerCommand C", .likely, "eventmodeling") }
    func testK06GitGraphColonForm() { expect("gitGraph:\n  commit", .likely, "gitGraph") }
    func testK07RequirementWithoutDiagramSuffix() { expect("requirement\n  test_req", .likely, "requirement") }
    func testK08BareSankey() { expect("sankey\nA,B,10", .likely, "sankey") }
    func testK09BareXYChart() { expect("xychart\n  title Sales", .likely, "xychart") }
    func testK10BareBlock() { expect("block\n  columns 2", .likely, "block") }
    func testK11BarePacket() { expect("packet\n  0-7: \"a\"", .likely, "packet") }
    func testK12Architecture() { expect("architecture\n  group g(cloud)[G]", .likely, "architecture") }
    func testK13Treemap() { expect("treemap\n\"Root\"\n  \"A\": 10", .likely, "treemap") }

    func testK14IshikawaIsCaseInsensitive() {
        expect("ishikawa-beta\n  Effect", .likely, "ishikawa")
        expect("ISHIKAWA-BETA\n  Effect", .likely, "ishikawa")
    }

    func testK15Venn() { expect("venn-beta\n  title V", .likely, "venn") }

    func testK16WardleyIsCaseInsensitive() {
        expect("wardley-beta\n  title W", .likely, "wardley")
        expect("Wardley-Beta\n  title W", .likely, "wardley")
    }

    func testK17Cynefin() { expect("cynefin-beta\n  title C", .likely, "cynefin") }
    func testK18Swimlane() { expect("swimlane-beta\n  lane A", .likely, "swimlane") }
    func testK19TreeView() { expect("treeView-beta\n  Root", .likely, "treeView") }

    func testK20RailroadFamilyIsCaseInsensitive() {
        expect("railroad-beta\n  rule Start", .likely, "railroad")
        expect("RAILROAD-BETA\n  rule Start", .likely, "railroad")
        expect("railroad-ebnf-beta\n  rule Start", .likely, "railroadEbnf")
        expect("RAILROAD-EBNF-BETA\n  rule Start", .likely, "railroadEbnf")
        expect("railroad-abnf-beta\n  rule Start", .likely, "railroadAbnf")
        expect("railroad-peg-beta\n  rule Start", .likely, "railroadPeg")
    }

    func testK21Radar() { expect("radar-beta\n  axis a, b", .likely, "radar") }
    func testK22Kanban() { expect("kanban\n  Todo", .likely, "kanban") }
    func testK23FlowchartElkOutranksFlowchart() { expect("flowchart-elk TD\nA-->B", .certain, "flowchart-elk") }

    // MARK: - N, negatives

    func testN01ZenumlIsNotRegisteredInMermaid11() { expect("zenuml\nA->B: hi", MermaidDetection.Confidence.none, nil) }
    func testN02StartersAreCaseSensitive() { expect("SEQUENCEDIAGRAM\nA->>B: x", MermaidDetection.Confidence.none, nil) }
    func testN03ProseContainingGraph() { expect("The graph shows a 12% increase.", MermaidDetection.Confidence.none, nil) }
    func testN04GitGraphProse() { expect("git graph of the repo", MermaidDetection.Confidence.none, nil) }
    func testN05LonePieProseIsAtMostWeak() { expect("pie chart of revenue is shown below", .weak, "pie") }

    func testN06Empty() {
        expect("", MermaidDetection.Confidence.none, nil)
        expect("   ", MermaidDetection.Confidence.none, nil)
    }

    func testN07JSON() { expect("{ \"graph\": \"TD\" }", MermaidDetection.Confidence.none, nil) }
    func testN08SQL() { expect("SELECT * FROM graph", MermaidDetection.Confidence.none, nil) }

    // MARK: - E, edges of the algorithm

    func testE01UnclosedFrontMatterFallsThroughToTheStarterScan() {
        expect("---\ntitle: T\ngraph TD\nA-->B", .likely, "flowchart-v2")
    }

    func testE02CommentsOnlyThenStarter() { expect("%%\n%%\n%%\ngraph TD\nA-->B", .certain, "flowchart-v2") }

    func testE03BareMermaidLabelLine() {
        let detection = MermaidDetector.detect("mermaid\ngraph TD\nA-->B")
        XCTAssertEqual(detection.confidence, .certain)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertEqual(detection.extractedSource, "graph TD\nA-->B")
        XCTAssertEqual(detection.droppedPrefixLines, 1)
    }

    func testE04StarterOutsideTheTwelveLineWindow() {
        let prose = (1...13).map { "Prose sentence \($0) that says nothing useful." }.joined(separator: "\n")
        expect(prose + "\ngraph TD\nA-->B", MermaidDetection.Confidence.none, nil)
    }

    func testE05SizeGateIsMeasuredInUTF16CodeUnits() {
        let huge = "graph TD\n" + String(repeating: "A-->B\n", count: 40_000)
        XCTAssertGreaterThan(huge.utf16.count, 200_000)
        XCTAssertGreaterThanOrEqual(MermaidDetector.detect(huge).confidence, .likely)
        XCTAssertThrowsError(try MermaidSource(rawValue: huge)) { error in
            XCTAssertEqual(error as? MermaidSource.ValidationError, .tooLarge(huge.utf16.count - 1))
        }

        // Emoji: 60,001 grapheme clusters but 120,002 UTF-16 units, so only the UTF-16 gate rejects it.
        let emoji = "graph TD\nA-->B[\"" + String(repeating: "😀", count: 60_000) + "\"]"
        XCTAssertLessThan(emoji.count, MermaidSource.maximumCharacters)
        XCTAssertGreaterThan(emoji.utf16.count, MermaidSource.maximumCharacters)
        XCTAssertThrowsError(try MermaidSource(rawValue: emoji)) { error in
            XCTAssertEqual(error as? MermaidSource.ValidationError, .tooLarge(emoji.utf16.count))
        }
    }

    func testE07RawInputOverTheCeilingIsNotExaminedAtAll() {
        let ceiling = MermaidDetector.maximumInputCharacters
        let overSized = "graph TD\nA-->B\n" + String(repeating: "x", count: ceiling)
        XCTAssertGreaterThan(overSized.utf16.count, ceiling)
        let detection = MermaidDetector.detect(overSized)
        XCTAssertEqual(detection.confidence, MermaidDetection.Confidence.none)
        XCTAssertEqual(detection.extractedSource, "")
        XCTAssertNil(detection.diagramKeyword)
        XCTAssertEqual(detection.droppedPrefixLines, 0)

        // One code unit under the ceiling is still examined, so the cap cannot be off by one.
        let allowed = "graph TD\nA-->B\n" + String(repeating: "x", count: ceiling - 15)
        XCTAssertEqual(allowed.utf16.count, ceiling)
        XCTAssertGreaterThanOrEqual(MermaidDetector.detect(allowed).confidence, .likely)
    }

    /// Detection is linear in the input and runs on the main actor, so select-all in a log file used
    /// to freeze the app for the length of a scan whose answer could only ever be "too large".
    /// Uncapped, this input measured 1.1 s; the ceiling turns it into a length comparison.
    func testE08SelectAllInALogFileReturnsImmediately() {
        let log = String(repeating: "2026-09-04 19:44:14 INFO  request completed in 12 ms\n", count: 380_000)
        XCTAssertGreaterThan(log.utf16.count, 20_000_000)
        let start = Date()
        XCTAssertEqual(MermaidDetector.detect(log).confidence, MermaidDetection.Confidence.none)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }

    func testE06LongArrowsAreNoLongerBilledTwice() throws {
        let source = "flowchart TD\n" + String(repeating: "  A ----> B\n", count: 300)
        let detection = MermaidDetector.detect(source)
        XCTAssertGreaterThanOrEqual(detection.confidence, .likely)
        XCTAssertEqual(detection.expectedType, "flowchart-v2")
        XCTAssertNoThrow(try MermaidSource(rawValue: source))
    }

    // MARK: - What the renderer is handed

    /// mermaid reads from the very first line, so prose the window scanned past has to be dropped
    /// or it reports an unknown diagram type. This is what ⌥Space hit on mermaid.ai's own docs.
    func testProseBeforeTheStarterIsNotHandedToTheRenderer() {
        let detection = MermaidDetector.detect("""
            Compact version:
            Code:
            eventmodeling

            tf 01 ui CartUI
            tf 02 cmd AddItem
            """)
        XCTAssertGreaterThanOrEqual(detection.confidence, .likely)
        XCTAssertEqual(detection.expectedType, "eventmodeling")
        XCTAssertTrue(detection.extractedSource.hasPrefix("eventmodeling"))
        XCTAssertFalse(detection.extractedSource.contains("Compact version"))
    }

    /// Comments and init directives ahead of the keyword *are* the source and must survive.
    func testCommentsAndDirectivesAheadOfTheStarterAreKept() {
        let detection = MermaidDetector.detect("""
            %%{init:{'theme':'dark'}}%%
            %% a note about the flow
            graph TD
              A --> B
            """)
        XCTAssertEqual(detection.confidence, .certain)
        XCTAssertTrue(detection.extractedSource.hasPrefix("%%{init:"))
        XCTAssertTrue(detection.extractedSource.contains("%% a note about the flow"))
    }

    func testFrontMatterAheadOfTheStarterIsKept() {
        let detection = MermaidDetector.detect("""
            ---
            title: Checkout
            ---
            graph LR
              A --> B
            """)
        XCTAssertGreaterThanOrEqual(detection.confidence, .likely)
        XCTAssertTrue(detection.extractedSource.hasPrefix("---"))
        XCTAssertTrue(detection.extractedSource.contains("title: Checkout"))
    }

    /// Prose resets the preamble: a comment that sits above prose belongs to the prose, not to the
    /// diagram, and carrying it through would put a stray line before the keyword.
    func testACommentAboveProseIsNotTreatedAsPreamble() {
        let detection = MermaidDetector.detect("""
            %% this comment is about the paragraph
            Some explanation of the checkout flow.
            graph TD
              A --> B
            """)
        XCTAssertGreaterThanOrEqual(detection.confidence, .likely)
        XCTAssertTrue(detection.extractedSource.hasPrefix("graph TD"))
    }

    /// Trailing affordances under a runnable snippet, which reading a block by its enclosing
    /// element picks up.
    func testTrailingSnippetChromeIsDropped() {
        let detection = MermaidDetector.detect("""
            eventmodeling

            tf 01 ui CartUI
            tf 02 cmd AddItem

            ⌘ + Enter
            |
            """)
        XCTAssertGreaterThanOrEqual(detection.confidence, .likely)
        XCTAssertFalse(detection.extractedSource.contains("⌘ + Enter"))
        XCTAssertTrue(detection.extractedSource.hasSuffix("tf 02 cmd AddItem"))
    }
}
