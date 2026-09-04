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
