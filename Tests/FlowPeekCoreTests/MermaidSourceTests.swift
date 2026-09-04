import XCTest
@testable import FlowPeekCore

final class MermaidSourceTests: XCTestCase {
    func testRemovesOnlyASurroundingMermaidFence() throws {
        let source = try MermaidSource(rawValue: """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """)

        XCTAssertEqual(source.text, "flowchart LR\n  A --> B")
    }

    func testDefaultThemeUsesSemanticPaletteAndAppleSystemFont() {
        let theme = MacMermaidTheme(
            appearance: .dark,
            accentHex: "#0A84FF",
            increaseContrast: true
        )

        XCTAssertEqual(theme.variables["fontFamily"], "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif")
        XCTAssertEqual(theme.variables["primaryColor"], "#2C2C2E")
        XCTAssertEqual(theme.variables["primaryTextColor"], "#FFFFFF")
        XCTAssertEqual(theme.variables["lineColor"], "#98989D")
    }

    func testEdgesAreNoLongerCountedInSwift() throws {
        let many = "flowchart LR\n" + (0..<600).map { "A\($0) ----> B\($0)" }.joined(separator: "\n")
        XCTAssertNoThrow(try MermaidSource(rawValue: many))
    }

    func testRejectsTooManyLines() {
        let tall = "flowchart LR\n" + String(repeating: "A --> B\n", count: MermaidSource.maximumLines)
        XCTAssertThrowsError(try MermaidSource(rawValue: tall)) { error in
            XCTAssertEqual(error as? MermaidSource.ValidationError, .tooManyLines(MermaidSource.maximumLines + 1))
        }
    }

    func testRejectsAPathologicallyLongLine() {
        let wide = "flowchart LR\nA --> B[\"" + String(repeating: "x", count: MermaidSource.maximumLineLength) + "\"]"
        XCTAssertThrowsError(try MermaidSource(rawValue: wide)) { error in
            XCTAssertEqual(error as? MermaidSource.ValidationError, .lineTooLong(MermaidSource.maximumLineLength + 11))
        }
    }

    func testFrontmatterRequiresADiagramAfterItsClosingDelimiter() {
        XCTAssertTrue(MermaidSource.looksLikeMermaid("---\ntitle: Checkout\n---\nflowchart LR\nA --> B"))
        XCTAssertFalse(MermaidSource.looksLikeMermaid("---\ntitle: Just YAML\nauthor: FlowPeek\n---"))
    }

    func testRecognizesDiagramAfterMermaidInitDirectiveAndComments() {
        XCTAssertTrue(MermaidSource.looksLikeMermaid("""
            %%{init: {"theme": "dark"}}%%
            %% checkout flow
            flowchart LR
              A --> B
            """))
    }
}
