import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The arrowhead the source specifies, against the one mermaid draws.
///
/// diagram-design gives exact numbers -- `markerWidth 8`, `markerHeight 6`, polygon `0 0, 8 3,
/// 0 6`. Mermaid draws an 8x8 triangle, a third stubbier, on every arrow in the diagram. A marker's
/// geometry is attributes rather than CSS, so the theme's stylesheet cannot reach it and the glue
/// rewrites it.
@MainActor
final class EditorialArrowheadTests: XCTestCase {
    private static let source = """
    flowchart TD
        a[Alpha] --> b[Beta]
        b --> c[(Gamma)]
    """

    private func markers(_ id: MermaidThemeID) async throws -> [String] {
        let pool = MermaidWebViewPool()
        let engine = try pool.checkOut()
        defer { pool.evict(engine) }
        let svg = try await engine.render(
            MermaidRenderRequest(
                source: Self.source,
                theme: MermaidThemeCatalogue.theme(
                    id, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                ),
                seed: "fp-head", renderID: "fp-head-\(id.rawValue)"
            )
        ).svg
        let parts: [String] = svg.components(separatedBy: "<marker")
        return Array(parts.dropFirst())
    }

    /// An attribute of the marker the edges actually point at.
    private func attribute(_ name: String, of marker: String) -> String? {
        guard let start = marker.range(of: "\(name)=\"") else { return nil }
        guard let end = marker[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(marker[start.upperBound..<end])
    }

    private func arrowEnd(_ markers: [String]) -> String? {
        markers.first { attribute("id", of: $0)?.hasSuffix("-pointEnd") == true }
    }

    /// The head is the source's, to the point.
    func testTheArrowheadIsTheSpecifiedEightBySix() async throws {
        let all = try await markers(.editorial)
        let marker = try XCTUnwrap(arrowEnd(all))
        XCTAssertEqual(attribute("markerWidth", of: marker), "8")
        XCTAssertEqual(attribute("markerHeight", of: marker), "6", "mermaid's own head is 8 tall")
        XCTAssertEqual(
            attribute("viewBox", of: marker), "0 0 8 6",
            "the box has to be reshaped with the size: a 10x10 box asked to fill 8x6 scales to fit and comes out 6x6"
        )
        XCTAssertTrue(
            marker.contains("M 0 0 L 8 3 L 0 6 z"),
            "the polygon is the source's own, not a scaled version of mermaid's"
        )
        // The reference point is where the line stops, so the head's body covers its last few
        // points. Mermaid puts it half way along its triangle; the same fraction of the new box.
        XCTAssertEqual(try XCTUnwrap(Double(attribute("refX", of: marker) ?? "")), 4, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(Double(attribute("refY", of: marker) ?? "")), 3, accuracy: 0.01)
    }

    /// Sequence draws its own head, and a bigger one: 12x12 with no viewBox at all. Left alone it
    /// was half again the size of a flowchart's on a diagram whose lines are no heavier.
    func testTheSequenceArrowheadIsBroughtToTheSameSize() async throws {
        let pool = MermaidWebViewPool()
        let engine = try pool.checkOut()
        defer { pool.evict(engine) }
        let svg = try await engine.render(
            MermaidRenderRequest(
                source: "sequenceDiagram\n    A->>B: go\n    B-->>A: done",
                theme: MermaidThemeCatalogue.theme(
                    .editorial, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                ),
                seed: "fp-seqhead", renderID: "fp-seqhead"
            )
        ).svg
        let parts: [String] = svg.components(separatedBy: "<marker")
        let head = try XCTUnwrap(
            parts.first { attribute("id", of: $0)?.hasSuffix("-arrowhead") == true },
            "the sequence arrowhead was not found"
        )
        XCTAssertEqual(attribute("markerWidth", of: head), "8", "mermaid's own is 12")
        XCTAssertEqual(attribute("markerHeight", of: head), "6")
        XCTAssertTrue(head.contains("M 0 0 L 8 3 L 0 6 z"))
        // It carries no viewBox of its own, so one has to be given or the path keeps being read in
        // the marker's old 12-unit space.
        XCTAssertEqual(attribute("viewBox", of: head), "0 0 8 6")
    }

    /// And the system theme keeps mermaid's, because 124 goldens say what it looks like.
    func testTheSystemThemeKeepsMermaidsArrowhead() async throws {
        let all = try await markers(.system)
        let marker = try XCTUnwrap(arrowEnd(all))
        XCTAssertEqual(attribute("markerHeight", of: marker), "8")
        XCTAssertTrue(marker.contains("M 0 0 L 10 5 L 0 10 z"))
    }
}
