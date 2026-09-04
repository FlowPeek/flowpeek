import AppKit
import FlowPeekCore
import WebKit
import XCTest

@testable import FlowPeek

/// The half of the export that needs a real engine: a diagram is rendered, and the bytes that come
/// back have to be a picture of the whole diagram rather than of the panel's viewport.
@MainActor
final class DiagramExportRenderTests: XCTestCase {
    private static let pool = MermaidWebViewPool()

    private func rendered() async throws -> MermaidRenderResult {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }
        return try await engine.render(
            MermaidRenderRequest(
                source: "flowchart TD\n  A[Start] --> B[End]",
                theme: MacMermaidTheme(appearance: .light, accentHex: "#0A84FF", increaseContrast: false),
                seed: "fp-export",
                renderID: "fp-export-1"
            )
        )
    }

    private func request(_ result: MermaidRenderResult) -> DiagramExporter.Request {
        DiagramExporter.Request(svg: result.svg, size: result.size, backgroundHex: "#FFFFFF")
    }

    func testTheSVGIsWrittenAsAStandaloneDocument() async throws {
        let result = try await rendered()
        let data = try await DiagramExporter().data(.svg, for: request(result))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(DiagramSVGDocument.prolog))
        XCTAssertTrue(text.contains("xmlns=\"\(DiagramSVGDocument.namespace)\""))
        XCTAssertTrue(text.contains("</svg>"))
    }

    /// The whole point of the second page: the export is the size of the *drawing*, so a bitmap of
    /// a 107x161 diagram comes back at 2x that and not at the size of whatever view was on screen.
    func testTheBitmapIsTheWholeDiagramAtTwoTimes() async throws {
        let result = try await rendered()
        let data = try await DiagramExporter().data(.png, for: request(result))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not a PNG")
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        let expected = try XCTUnwrap(DiagramExportImage.pixelSize(for: result.size))
        XCTAssertEqual(Double(image.pixelsWide), Double(expected.width), accuracy: 2)
        XCTAssertEqual(
            Double(image.pixelsWide) / Double(image.pixelsHigh),
            result.width / result.height,
            accuracy: 0.05
        )
    }

    /// A blank snapshot is the failure this is really guarding against: a `WKWebView` that never
    /// reached a window paints nothing, and the export would silently be a white rectangle.
    func testTheBitmapIsNotBlank() async throws {
        let result = try await rendered()
        let data = try await DiagramExporter().data(.png, for: request(result))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        var distinct: Set<UInt32> = []
        for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 40)) {
            for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 40)) {
                guard let colour = image.colorAt(x: x, y: y) else { continue }
                distinct.insert(
                    UInt32(colour.redComponent * 255) << 16
                        | UInt32(colour.greenComponent * 255) << 8
                        | UInt32(colour.blueComponent * 255)
                )
            }
        }
        XCTAssertGreaterThan(distinct.count, 1, "the exported bitmap is one flat colour — nothing was drawn")
    }

    func testThePDFIsAVectorDocumentTheSizeOfTheDiagram() async throws {
        let result = try await rendered()
        let data = try await DiagramExporter().data(.pdf, for: request(result))
        XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
        let document = try XCTUnwrap(PDFPageBox(data: data))
        XCTAssertEqual(document.width, result.width, accuracy: 2)
        XCTAssertEqual(document.height, result.height, accuracy: 2)
    }

    func testNothingRenderedIsNotExported() async {
        let empty = DiagramExporter.Request(svg: "", size: CGSize(width: 10, height: 10), backgroundHex: "#FFF")
        do {
            _ = try await DiagramExporter().data(.png, for: empty)
            XCTFail("an empty diagram must not produce an export")
        } catch {
            XCTAssertTrue(error is DiagramExporter.Failure)
        }
    }

    /// `MermaidRenderResult.svg` was populated and then thrown away: nothing in the app read it.
    /// The model is what closes that gap, so it is asserted here rather than only in the exporter.
    func testAModelWithARenderedDiagramCanBeExportedAndAnEmptyOneCannot() async throws {
        let model = DiagramViewModel(title: "Order/Flow: v2", source: "flowchart TD\n  A --> B", pool: Self.pool)
        XCTAssertFalse(model.canExport, "nothing is drawn yet")
        model.attach()
        try await waitUntil { model.canExport }
        let request = try XCTUnwrap(model.exportRequest)
        XCTAssertFalse(request.svg.isEmpty)
        XCTAssertGreaterThan(request.size.width, 0)
        model.release()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition never became true") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// The one number worth reading out of a PDF here: the MediaBox, which says whether the page is
/// the diagram or the panel. Parsed by hand so the test needs no PDFKit import in the app target.
private struct PDFPageBox {
    let width: Double
    let height: Double

    init?(data: Data) {
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "/MediaBox") else { return nil }
        let tail = text[start.upperBound...]
        guard let open = tail.firstIndex(of: "["), let close = tail.firstIndex(of: "]") else { return nil }
        let numbers = tail[tail.index(after: open)..<close]
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
            .compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        width = numbers[2] - numbers[0]
        height = numbers[3] - numbers[1]
    }
}
