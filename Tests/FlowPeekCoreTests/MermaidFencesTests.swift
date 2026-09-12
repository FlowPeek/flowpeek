import XCTest
@testable import FlowPeekCore

/// Pulling a diagram out of what a coding agent wrote, and deciding whether it is the one on screen.
final class MermaidFencesTests: XCTestCase {
    func testAFencedBlockIsTakenWithoutItsFences() {
        let markdown = """
        Here is the diagram.

        ```mermaid
        flowchart TD
            A --> B
        ```

        That is all.
        """
        XCTAssertEqual(MermaidFences.blocks(in: markdown), ["flowchart TD\n    A --> B"])
    }

    func testEveryBlockIsTakenInOrder() {
        let markdown = """
        ```mermaid
        graph TD
            A --> B
        ```
        prose
        ```mermaid
        sequenceDiagram
            A->>B: hello
        ```
        """
        XCTAssertEqual(MermaidFences.blocks(in: markdown).count, 2)
        XCTAssertTrue(MermaidFences.blocks(in: markdown)[1].hasPrefix("sequenceDiagram"))
    }

    /// A block labelled something else is somebody's code sample, and one labelled nothing at all is
    /// far more often a shell transcript than a diagram.
    func testOnlyAMermaidFenceCounts() {
        XCTAssertEqual(MermaidFences.blocks(in: "```swift\nlet a = 1\n```"), [])
        XCTAssertEqual(MermaidFences.blocks(in: "```\ngraph TD\n```"), [])
        XCTAssertEqual(MermaidFences.blocks(in: "no fences here at all"), [])
    }

    func testAnUnclosedFenceHoldsNothing() {
        XCTAssertEqual(MermaidFences.blocks(in: "```mermaid\nflowchart TD\n    A --> B"), [])
    }

    func testAnEmptyBlockIsNotABlock() {
        XCTAssertEqual(MermaidFences.blocks(in: "```mermaid\n\n```"), [])
    }

    // MARK: - Matching what the screen recovered

    /// The case this exists for, and the reason the comparison ignores whitespace rather than
    /// respecting it: what the screen gets wrong IS whitespace. A wrap eats the space it broke at,
    /// so the recovered text reads `...source forconfidence` -- and that has to still identify the
    /// source it came from, or there is nothing to put in its place.
    func testASourceIsFoundEvenThroughTheSpaceTheWrapAte() {
        let exact = "flowchart TD\n    A[\"the detector scores the source for confidence\"] --> B"
        let fromScreen = "flowchart TD\n  A[\"the detector scores the source forconfidence\"] --> B"
        XCTAssertEqual(MermaidFences.matching(fromScreen, in: [exact]), exact)
        // And a rejoin that only differs in margins and spacing finds it just the same.
        let onlySpacing = "flowchart TD\n  A[\"the detector scores the source for confidence\"]   --> B"
        XCTAssertEqual(MermaidFences.matching(onlySpacing, in: [exact]), exact)
    }

    /// What it must not do is match a different diagram. Everything that is not whitespace has to
    /// agree exactly.
    func testADifferentDiagramIsNotMatched() {
        let exact = "flowchart TD\n    A[\"the detector scores the source for confidence\"] --> B"
        let other = "flowchart TD\n    A[\"the detector scores the source for certainty\"] --> B"
        XCTAssertNil(MermaidFences.matching(other, in: [exact]))
    }

    func testTwoCandidatesThatBothMatchAreRefused() {
        let one = "flowchart TD\n    A --> B\n    B --> C\n    C --> D"
        let two = "flowchart TD\n  A --> B\n  B --> C\n  C --> D"
        XCTAssertNil(MermaidFences.matching(one, in: [one, two]), "two answers is not an answer")
    }

    func testSomethingTooShortToBeSureIsRefused() {
        XCTAssertNil(MermaidFences.matching("graph TD", in: ["graph TD"]))
    }

    func testNoCandidateMatchesNothing() {
        let recovered = "flowchart TD\n    A --> B\n    B --> C\n    C --> D"
        XCTAssertNil(MermaidFences.matching(recovered, in: ["sequenceDiagram\n    A->>B: hi there now"]))
        XCTAssertNil(MermaidFences.matching(recovered, in: []))
    }
}
