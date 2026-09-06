import XCTest
@testable import FlowPeekCore

final class DiagramLabelTests: XCTestCase {
    func testFrontMatterTitleWinsOverEverythingInTheBody() {
        let source = """
        ---
        title: Christmas Delivery
        config:
          theme: base
        ---
        flowchart TD
          A[Santa] --> B[Rudolph]
        """
        XCTAssertEqual(DiagramLabel.describe(source), "Christmas Delivery")
    }

    func testATitleStatementInTheBodyIsUsed() {
        XCTAssertEqual(DiagramLabel.describe("pie title Sales by Region\n  \"Dogs\" : 386"), "Sales by Region")
    }

    func testTitleMustBeAWordOfItsOwn() {
        // `titleCase` is a node, not a title statement.
        XCTAssertEqual(DiagramLabel.describe("flowchart LR\n  titleCase --> other"), "titleCase → other")
    }

    func testBareOperandsAreStrungTogether() {
        XCTAssertEqual(DiagramLabel.describe("flowchart LR\n  Order --> Pay --> Ship"), "Order → Pay → Ship")
    }

    func testNodeTextBeatsTheIdentifier() {
        XCTAssertEqual(DiagramLabel.describe("flowchart TD\n  A[Collect] --> B[Review]"), "Collect → Review")
    }

    func testDoubledBracketsGiveTheInnerWords() {
        XCTAssertEqual(DiagramLabel.describe("mindmap\n  root((Big Idea))"), "Big Idea")
    }

    func testSequenceParticipantsRatherThanTheirMessages() {
        let source = """
        sequenceDiagram
          participant Alice as A. Smith
          Alice->>Bob: Good morning
        """
        XCTAssertEqual(DiagramLabel.describe(source), "Alice → Bob")
    }

    func testEntityCardinalityIsNotPartOfTheName() {
        XCTAssertEqual(
            DiagramLabel.describe("erDiagram\n  CUSTOMER ||--o{ ORDER : places"),
            "CUSTOMER → ORDER"
        )
    }

    func testTheStarterLineAloneSaysNothing() {
        XCTAssertNil(DiagramLabel.describe("sequenceDiagram"))
        XCTAssertNil(DiagramLabel.describe("flowchart LR"))
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(
            DiagramLabel.describe("%% flowchart of the thing\nflowchart LR\n  A --> B"),
            "A → B"
        )
    }

    func testAtMostThreeLabels() {
        XCTAssertEqual(DiagramLabel.describe("flowchart LR\n  A --> B --> C --> D --> E"), "A → B → C")
    }

    func testRepeatsAreNotListedTwice() {
        XCTAssertEqual(DiagramLabel.describe("flowchart LR\n  A --> B\n  A --> C"), "A → B → C")
    }

    func testALongLabelIsCutRatherThanWrapped() {
        let name = String(repeating: "x", count: 60)
        let described = DiagramLabel.describe("flowchart LR\n  A[\(name)] --> B")
        XCTAssertEqual(described, String(repeating: "x", count: 23) + "… → B")
    }

    func testTheWholeNameIsBounded() {
        let source = "flowchart LR\n  A[Alphabet Soup Company] --> B[Beetroot Wholesalers] --> C[Cornerstone]"
        let described = DiagramLabel.describe(source)
        XCTAssertLessThanOrEqual(described?.count ?? 0, 48)
    }

    func testALineBreakInsideALabelBecomesASpace() {
        XCTAssertEqual(DiagramLabel.describe("flowchart LR\n  A[Sign<br/>Off] --> B"), "Sign Off → B")
    }

    func testNothingToReadIsNil() {
        XCTAssertNil(DiagramLabel.describe(""))
        XCTAssertNil(DiagramLabel.describe("gantt\n  dateFormat YYYY-MM-DD"))
    }

    /// Malformed, and only a drawn diagram is ever filed -- but the reader must still return
    /// rather than run to the end of the source looking for a bracket that is not there.
    func testAnUnbalancedBracketStillAnswers() {
        XCTAssertNotNil(DiagramLabel.describe("flowchart LR\n  A[Unclosed --> B"))
    }
}
