import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The seam between FlowPeek's own flowchart renderer and the vendored mermaid.
///
/// Which renderer drew a diagram is the one thing about this that a reader must never be able to
/// tell, so it is asserted here instead: the glue reports it back as `renderer`, and everything
/// downstream of the choice — the scrub, the post-conditions, the contrast pass, the geometry —
/// is the same code either way.
///
/// The gate is three clauses and the third is the load-bearing one. A theme whose stylesheet
/// carries no `.fp-` rules cannot paint what this renderer tags, so it keeps the whole system
/// theme on mermaid — which is also what keeps the 124 goldens byte-identical, and why
/// `testTheSystemThemeStaysOnMermaid` is worth as much as the two either side of it.
@MainActor
final class FlowRendererSeamTests: XCTestCase {
    private static let pool = MermaidWebViewPool()
    private static var counter: UInt64 = 0

    private static let hub = """
    flowchart TD
        web[Web App] --> gw{{API Gateway}}
        mob[Mobile App] --> gw
        gw --> auth[Auth]
        gw --> orders[Orders]
        orders --> pg[(Postgres)]
    """

    private func render(_ source: String, _ id: MermaidThemeID) async throws -> MermaidRenderResult {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }
        Self.counter += 1
        return try await engine.render(
            MermaidRenderRequest(
                source: source,
                theme: MermaidThemeCatalogue.theme(
                    id, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                ),
                seed: "flowpeek-seam",
                renderID: MermaidRenderIdentifier.renderID(Self.counter)
            )
        )
    }

    func testAnEditorialFlowchartIsDrawnByFlowPeeksOwnRenderer() async throws {
        let result = try await render(Self.hub, .editorial)
        XCTAssertEqual(result.renderer, "flowpeek-flow")
        XCTAssertNil(result.rendererFallback, "nothing declined, so there is nothing to report")
        XCTAssertEqual(result.diagramType, "flowchart-v2", "the health canary keys off this string")
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
    }

    /// The gate's third clause, stated as the thing it protects.
    func testTheSystemThemeStaysOnMermaid() async throws {
        let result = try await render(Self.hub, .system)
        XCTAssertEqual(result.renderer, "mermaid")
        XCTAssertEqual(
            result.rendererFallback, "no-ladder",
            "the system theme must be turned away by the marker, not by anything it happens to contain"
        )
    }

    /// A decline is a route, not a fault. `click` binds behaviour to an element, which this
    /// renderer does not implement and mermaid does, so the diagram comes back drawn — by the other
    /// engine, at full size, with nothing said to the reader about it.
    func testASourceTheRendererDeclinesIsStillDrawn() async throws {
        let result = try await render(Self.hub + "\n    click gw \"https://example.com\"", .editorial)
        XCTAssertEqual(result.renderer, "mermaid")
        XCTAssertEqual(result.rendererFallback, "unsupported:click")
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        XCTAssertTrue(result.svg.contains("<svg"), "the decline has to end in a drawing")
        XCTAssertNil(result.notice, "a fallback is not a degraded render and must raise no badge")
    }

    /// Only flowchart-v2 is claimed. `flowchart-elk` is a different layout engine and `swimlane` a
    /// different diagram; both are in the DOM sweep's own type list, which says nothing about
    /// whether this renderer can lay them out.
    func testAnEditorialDiagramOfAnotherKindStaysOnMermaid() async throws {
        let result = try await render("sequenceDiagram\n    A->>B: hello", .editorial)
        XCTAssertEqual(result.renderer, "mermaid")
        XCTAssertEqual(result.rendererFallback, "wrong-type")
        XCTAssertEqual(result.diagramType, "sequence")
    }

    /// The scrub still runs over flow output, and on correct output it finds nothing. This is not a
    /// sanitisation success: the renderer emits no banned element and no `on*` attribute at all, so
    /// anything here would be a bug in the renderer rather than a save by the boundary.
    func testFlowOutputGivesTheScrubNothingToDo() async throws {
        let result = try await render(Self.hub, .editorial)
        XCTAssertEqual(result.renderer, "flowpeek-flow")
        XCTAssertEqual(result.scrubbed, [], "the renderer emitted something the scrub had to remove")
    }

    /// Byte stability, which mermaid cannot offer for this source: it draws the stadium and the
    /// cylinder through rough.js with no per-render seed, so their control points move with how
    /// many diagrams the context has drawn. FlowPeek's renderer has no entropy in it, and the
    /// pooled web view keeps one JS context across renders — so a second render into the same
    /// context is where module-level state would show up.
    func testTheSameSourceRendersToTheSameBytesTwice() async throws {
        func draw() async throws -> String {
            let engine = try Self.pool.checkOut()
            defer { Self.pool.checkIn(engine) }
            let result = try await engine.render(
                MermaidRenderRequest(
                    source: Self.hub + "\n    auth --> deny([Denied])",
                    theme: MermaidThemeCatalogue.theme(
                        .editorial, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                    ),
                    seed: "flowpeek-seam",
                    renderID: "fp-seam-stability"
                )
            )
            XCTAssertEqual(result.renderer, "flowpeek-flow")
            return result.svg
        }
        let first = try await draw()
        let second = try await draw()
        XCTAssertEqual(first, second)
    }
}
