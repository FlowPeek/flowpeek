import CoreGraphics
import XCTest

@testable import FlowPeekCore

/// The parts of "get the diagram out of the panel" that do not need WebKit: what the file is
/// called, how big the bitmap is, and what an `.svg` on disk has to contain to open as a drawing.
final class DiagramExportTests: XCTestCase {

    // MARK: - Names

    func testATitleBecomesTheFileName() {
        XCTAssertEqual(
            DiagramExportName.fileName(for: "Order Flow", format: .png),
            "Order Flow.png"
        )
    }

    /// Preview titles are lifted from whatever was being read — a page title, a window title — so
    /// they arrive with the two characters a file name cannot survive.
    func testPathSeparatorsAreNotCarriedIntoAFileName() {
        let name = DiagramExportName.fileName(for: "docs/api: v2", format: .pdf)
        XCTAssertFalse(name.dropLast(4).contains("/"))
        XCTAssertFalse(name.dropLast(4).contains(":"))
        XCTAssertEqual(name, "docs api v2.pdf")
    }

    func testANewlineInATitleCollapsesToOneSpace() {
        XCTAssertEqual(DiagramExportName.baseName(for: "Sequence\n\n  Diagram"), "Sequence Diagram")
    }

    /// A leading dot would hide the saved file in Finder, which no title ever means to ask for.
    func testALeadingDotIsDropped() {
        XCTAssertEqual(DiagramExportName.baseName(for: "...hidden"), "hidden")
    }

    func testATitleThatContributesNothingFallsBackRatherThanSavingAnExtensionOnlyFile() {
        XCTAssertEqual(DiagramExportName.baseName(for: "   "), DiagramExportName.fallback)
        XCTAssertEqual(DiagramExportName.baseName(for: "///"), DiagramExportName.fallback)
        XCTAssertEqual(DiagramExportName.fileName(for: "", format: .svg), "diagram.svg")
    }

    func testAVeryLongTitleIsCappedAndNotLeftWithATrailingSpace() {
        let name = DiagramExportName.baseName(for: String(repeating: "ab ", count: 200))
        XCTAssertLessThanOrEqual(name.count, DiagramExportName.maximumLength)
        XCTAssertEqual(name, name.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Bitmap size

    func testABitmapExportIsDrawnAtTwoTimes() {
        XCTAssertEqual(
            DiagramExportImage.pixelSize(for: CGSize(width: 400, height: 300)),
            CGSize(width: 800, height: 600)
        )
    }

    /// 2x of a wall-sized diagram is hundreds of megabytes before it is ever encoded, so past the
    /// ceiling the scale gives way — and the aspect ratio does not.
    func testAHugeDiagramGivesUpScaleRatherThanFailing() throws {
        let source = CGSize(width: 9000, height: 3000)
        let pixels = try XCTUnwrap(DiagramExportImage.pixelSize(for: source))
        XCTAssertEqual(pixels.width, DiagramExportImage.maximumEdge, accuracy: 1)
        XCTAssertEqual(pixels.width / pixels.height, source.width / source.height, accuracy: 0.01)
    }

    func testNothingIsDrawnForAnEmptyOrNonsenseSize() {
        XCTAssertNil(DiagramExportImage.pixelSize(for: .zero))
        XCTAssertNil(DiagramExportImage.pixelSize(for: CGSize(width: 100, height: 0)))
        XCTAssertNil(DiagramExportImage.pixelSize(for: CGSize(width: CGFloat.nan, height: 10)))
    }

    // MARK: - SVG on disk

    /// The engine returns a fragment of a live page, which can take its namespace from the document
    /// it is attached to. A file cannot: without the prolog and the namespace an `.svg` opens as
    /// markup rather than as a drawing.
    func testASavedSVGIsAStandaloneDocument() {
        let document = DiagramSVGDocument.standalone("<svg xmlns=\"http://www.w3.org/2000/svg\"><g/></svg>")
        XCTAssertTrue(document.hasPrefix(DiagramSVGDocument.prolog))
        XCTAssertTrue(document.contains("<g/>"))
        XCTAssertTrue(document.hasSuffix("\n"))
    }

    func testAMissingNamespaceIsAddedExactlyOnce() {
        let document = DiagramSVGDocument.standalone("<svg viewBox=\"0 0 10 10\"><g/></svg>")
        XCTAssertEqual(document.components(separatedBy: "xmlns=").count - 1, 1)
        XCTAssertTrue(document.contains("<svg xmlns=\"\(DiagramSVGDocument.namespace)\" viewBox="))
    }

    func testAnSVGThatAlreadyDeclaresTheNamespaceIsLeftAlone() {
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\"><g/></svg>"
        XCTAssertEqual(DiagramSVGDocument.standalone(markup).components(separatedBy: "xmlns=").count - 1, 1)
    }

    // MARK: - Formats

    func testTheClipboardOffersEveryFormatAndLeadsWithTheOneEveryAppUnderstands() {
        XCTAssertEqual(DiagramExportFormat.clipboardOrder.first, .png)
        XCTAssertEqual(Set(DiagramExportFormat.clipboardOrder), Set(DiagramExportFormat.allCases))
    }

    func testOnlyTheSVGIsAlreadyInHand() {
        XCTAssertFalse(DiagramExportFormat.svg.needsRedraw)
        XCTAssertTrue(DiagramExportFormat.png.needsRedraw)
        XCTAssertTrue(DiagramExportFormat.pdf.needsRedraw)
    }

    func testEveryFormatCarriesItsOwnTypeAndExtension() {
        XCTAssertEqual(Set(DiagramExportFormat.allCases.map(\.contentType)).count, DiagramExportFormat.allCases.count)
        XCTAssertEqual(DiagramExportFormat.png.fileExtension, "png")
        XCTAssertEqual(DiagramExportFormat.pdf.contentType, "com.adobe.pdf")
    }

    // MARK: - The page an export is drawn from

    /// The live preview cannot answer what an export asks — its scroller is its viewport — so the
    /// export gets a page of exactly the diagram's size, under the same policy as the render page.
    func testTheExportPageIsSizedToTheDiagramAndRunsNothing() {
        let page = MermaidEnginePage.exportDocument(
            svg: "<svg id=\"fp-1\"><g/></svg>",
            width: 107.09375,
            height: 161.375,
            background: "#FFFFFF"
        )
        XCTAssertTrue(page.contains(MermaidEnginePage.contentSecurityPolicy))
        XCTAssertTrue(page.contains("<svg id=\"fp-1\"><g/></svg>"))
        XCTAssertTrue(page.contains("width:107.094px"))
        XCTAssertTrue(page.contains("height:161.375px"))
        XCTAssertTrue(page.contains("background:#FFFFFF"))
        XCTAssertFalse(page.contains("<script"))
    }

    func testTheExportPageCanBeTransparentForTheVectorFormats() {
        let page = MermaidEnginePage.exportDocument(svg: "<svg/>", width: 10, height: 10, background: "transparent")
        XCTAssertTrue(page.contains("background:transparent"))
    }

    /// A zero-sized page has no layout box at all, and WebKit snapshots it as nothing.
    func testTheExportPageNeverCollapsesToNothing() {
        let page = MermaidEnginePage.exportDocument(svg: "<svg/>", width: 0, height: -4, background: "#000")
        XCTAssertTrue(page.contains("width:1.000px"))
        XCTAssertTrue(page.contains("height:1.000px"))
    }
}

/// What a screen reader is given instead of the drawing. The words are the diagram's own — the
/// character data of the `<text>` elements the engine hands back — so this is the one description
/// that cannot drift from what is on screen.
final class DiagramNarrationTests: XCTestCase {
    private let flowchart = """
    <svg id="fp-1" role="graphics-document document" aria-roledescription="flowchart-v2" viewBox="0 0 100 200">\
    <style>#fp-1 .node text{fill:#333;font-family:"Helvetica Neue"}</style>\
    <g class="node"><path d="M0,0 L10,10 L20,0 Z"/><text><tspan>Start</tspan></text></g>\
    <g class="edgeLabel"><text><tspan>yes</tspan></text></g>\
    <g class="node"><text><tspan>Order</tspan><tspan>Placed</tspan></text></g>\
    </svg>
    """

    func testTheDiagramsOwnWordsAreWhatIsReadOut() {
        XCTAssertEqual(DiagramNarration.read(flowchart).labels, ["Start", "yes", "Order Placed"])
    }

    /// mermaid wraps every line of a label in its own `<tspan>`. Dropping the tags without putting
    /// a boundary in their place turns a two-line node into "OrderPlaced".
    func testAWrappedLabelDoesNotRunItsLinesTogether() {
        XCTAssertTrue(DiagramNarration.read(flowchart).labels.contains("Order Placed"))
    }

    /// The theme is shipped as one `<style>` element inside the SVG, and the drawing itself is
    /// mostly path data. Neither is anything to say out loud.
    func testMarkupIsNotMistakenForWords() {
        let spoken = try? XCTUnwrap(DiagramNarration.read(flowchart).spoken)
        XCTAssertEqual(spoken, "Start, yes, Order Placed")
        XCTAssertFalse(spoken?.contains("fill") ?? true)
        XCTAssertFalse(spoken?.contains("M0,0") ?? true)
    }

    /// `htmlLabels` is off, but eventmodeling emits every label as a `<foreignObject>` anyway — the
    /// glue keeps those rather than deleting them, so their text is the diagram's text too.
    func testAnHTMLLabelIsReadLikeAnyOther() {
        let svg = "<svg><g><foreignObject><div><span>Ship it</span></div></foreignObject></g></svg>"
        XCTAssertEqual(DiagramNarration.read(svg).labels, ["Ship it"])
    }

    /// The engine serialises through the DOM, so a label that was written `A & B` arrives escaped.
    func testAnEscapedLabelIsSpokenAsItWasWritten() {
        let svg = "<svg><text><tspan>A &amp; B &#39;n&#39; &lt;C&gt;</tspan></text></svg>"
        XCTAssertEqual(DiagramNarration.read(svg).labels, ["A & B 'n' <C>"])
    }

    func testTheKindOfDrawingComesFromTheEnginesOwnRoleDescription() {
        XCTAssertEqual(DiagramNarration.read(flowchart).kind, "flowchart")
        XCTAssertEqual(DiagramNarration.kind(in: "<svg aria-roledescription=\"er\"/>"), "er")
        XCTAssertEqual(DiagramNarration.kind(in: "<svg aria-roledescription=\"class-diagram\"/>"), "class diagram")
        XCTAssertNil(DiagramNarration.kind(in: "<svg role=\"graphics-document document\"/>"))
    }

    /// A four-hundred-node chart read out node by node is not a description. It stops, and says it
    /// stopped, rather than trailing off as if that were the whole diagram.
    func testAVeryTalkativeDiagramIsCutShortAndSaysSo() throws {
        let labels = (0..<400).map { "<text><tspan>Step number \($0)</tspan></text>" }.joined()
        let reading = DiagramNarration.read("<svg>" + labels + "</svg>")
        XCTAssertEqual(reading.labels.count, DiagramNarration.maximumLabels)
        XCTAssertTrue(reading.isTruncated)
        let spoken = try XCTUnwrap(reading.spoken)
        XCTAssertTrue(spoken.hasSuffix("…"))
        XCTAssertLessThanOrEqual(spoken.count, DiagramNarration.maximumLength + 1)
    }

    /// Nothing to read is not the same as a blank value: the caller says so in the reader's own
    /// language instead of announcing an empty string.
    func testADrawingWithNoWordsHasNothingToSay() {
        let reading = DiagramNarration.read("<svg><g><path d=\"M0,0 L1,1\"/><text> </text></g></svg>")
        XCTAssertTrue(reading.labels.isEmpty)
        XCTAssertNil(reading.spoken)
    }
}
