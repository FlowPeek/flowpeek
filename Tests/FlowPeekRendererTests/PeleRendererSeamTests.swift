import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The third renderer at the one seam.
///
/// Pele differs from FlowPeek's own renderer in the thing these tests are about: it answers for
/// every diagram type, so the question "can this renderer draw this?" is settled by the theme
/// alone and never by the type. That makes the routing table's shape visible here — the same
/// source under three themes comes back drawn by three renderers — and it makes the decline path
/// rarer and worth pinning: a source Pele throws on still arrives as a drawing.
///
/// What a reader can tell from the picture is, as with the flow renderer, nothing. The choice is
/// reported back as `renderer` and asserted here instead.
@MainActor
final class PeleRendererSeamTests: XCTestCase {
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
                seed: "flowpeek-pele",
                renderID: MermaidRenderIdentifier.renderID(Self.counter)
            )
        )
    }

    /// The claim that separates this renderer from the other one in front of mermaid. FlowPeek's
    /// own renderer declines everything that is not `flowchart-v2`; Pele is asked about the theme
    /// and never about the type, so a type it has never been tried on routes to it too.
    ///
    /// Six families drawn by six different parts of Pele — a graph layout, a lifeline, a chart, a
    /// state machine, a timeline grid and a tree — rather than six flowcharts, which would assert
    /// the same code six times.
    func testEveryDiagramTypeUnderThePeleThemeIsDrawnByPele() async throws {
        let sources: [(String, String)] = [
            ("flowchart-v2", Self.hub),
            ("sequence", "sequenceDiagram\n    web->>gw: GET /orders\n    gw-->>web: 200"),
            ("pie", "pie title Traffic\n    \"Web\" : 60\n    \"Mobile\" : 40"),
            ("stateDiagram", "stateDiagram-v2\n    [*] --> Idle\n    Idle --> Busy\n    Busy --> [*]"),
            ("gantt", "gantt\n    dateFormat YYYY-MM-DD\n    section Build\n    Draft :a1, 2026-01-01, 30d"),
            ("mindmap", "mindmap\n    root((FlowPeek))\n        Renderers\n        Themes"),
        ]
        for (type, source) in sources {
            let result = try await render(source, .pele)
            XCTAssertEqual(result.renderer, "pele", "\(type) should have routed to Pele")
            XCTAssertNil(result.rendererFallback, "\(type) drew, so nothing declined")
            XCTAssertEqual(result.diagramType, type, "the type is mermaid's own parse, not Pele's")
            XCTAssertGreaterThan(result.width, 0, "\(type) came back with no width")
            XCTAssertGreaterThan(result.height, 0, "\(type) came back with no height")
        }
    }

    /// The whole table in one assertion: one source, three themes, three renderers. Each row is
    /// also covered on its own — the two mermaid-vocabulary ones in `FlowRendererSeamTests` — and
    /// this is here for what those cannot show, that the three choices are exclusive and that
    /// adding a renderer did not quietly move one of the others.
    func testTheSameFlowchartIsDrawnByThreeDifferentRenderers() async throws {
        let drawn = [
            MermaidThemeID.system: "mermaid",
            MermaidThemeID.editorial: "flowpeek-flow",
            MermaidThemeID.pele: "pele",
        ]
        for (theme, renderer) in drawn {
            let result = try await render(Self.hub, theme)
            XCTAssertEqual(result.renderer, renderer, "the \(theme.rawValue) theme drew with the wrong renderer")
            XCTAssertEqual(result.diagramType, "flowchart-v2")
        }
    }

    /// The theme reaches the drawing, and it reaches it through the attribute that was already
    /// there. Pele's `<svg>` defines every `--_*` shorthand it paints through as
    /// `var(--pele-x, <default>)` in its own `style`; a second `style` attribute would drop that
    /// one silently and the diagram would paint black. So both halves have to be in the same
    /// attribute, and the SVG has to carry exactly one.
    func testThePeleThemeIsMergedIntoTheSvgsOwnStyleAttribute() async throws {
        let result = try await render(Self.hub, .pele)
        XCTAssertEqual(result.renderer, "pele")

        // WebKit re-serialises a style attribute it has been written to, so the declarations come
        // back as `--pele-bg: #F5F5F5` rather than the `--pele-bg:#F5F5F5` the glue wrote. The
        // separator is normalised away here; which spelling WebKit picks is not the subject.
        let openTag = String(result.svg.prefix(while: { $0 != ">" }))
            .replacingOccurrences(of: ": ", with: ":")
        XCTAssertEqual(
            openTag.components(separatedBy: " style=").count - 1, 1,
            "the <svg> must carry one style attribute, not two"
        )
        XCTAssertTrue(
            openTag.contains("--_bg:var(--pele-bg"),
            "Pele's own definitions were lost, which is the failure that paints the diagram black"
        )
        let theme = MermaidThemeCatalogue.theme(
            .pele, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
        )
        guard case .pele(let variables) = theme.engine else {
            return XCTFail("the Pele theme stopped being written in Pele's vocabulary")
        }
        for name in ["--pele-bg", "--pele-fg", "--pele-line", "--pele-accent", "--pele-series-1"] {
            let declaration = "\(name):\(try XCTUnwrap(variables[name]))"
            XCTAssertTrue(openTag.contains(declaration), "the <svg> is missing \(declaration)")
        }
        // The colours are in the markup rather than on a parent, which is what makes an export
        // look like the theme: this string is what the host copies and writes to a file.
        XCTAssertTrue(result.svg.hasPrefix("<svg"))
    }

    /// A decline is a route, not a fault — and reaching one takes doing, which is itself the
    /// finding. Every one of the 35 rows of `MermaidEngineTests.conformanceTable` draws through
    /// Pele, measured: every type we claim, the four beta types mermaid added after Pele's
    /// vocabulary was written included, and nothing scrubbed from any of them. Nor is there a
    /// source in reach that mermaid parses and Pele does not: of the three candidates tried —
    /// an ER entity alias in a relationship, `A:::one:::two`, a `classDef` inside a mindmap —
    /// mermaid 11.17.2 rejects all three in its own `parse`, which runs first and fails the
    /// render before this seam is consulted at all.
    ///
    /// So the decline is produced rather than found, in the way a shipped build could really
    /// produce one: `window.pele` not there. Four scripts are one shipped set, and a build that
    /// carries three of them is exactly this.
    func testADiagramStillDrawsWhenPeleIsNotInTheWorld() async throws {
        // The bundle declares `var pele` at the top level, so the binding cannot be deleted; it
        // can be emptied, which is what `peleEngine()` in the glue reads.
        try await withPatchedWorld(
            "window.__peleHeld = window.pele; window.pele = null; return 1;",
            undo: "window.pele = window.__peleHeld; delete window.__peleHeld; return 1;"
        ) { engine in
            let result = try await self.draw(Self.hub, through: engine)
            XCTAssertEqual(result.renderer, "mermaid")
            XCTAssertEqual(result.rendererFallback, "no-renderer")
            XCTAssertEqual(result.diagramType, "flowchart-v2")
            XCTAssertGreaterThan(result.width, 0)
            XCTAssertTrue(result.svg.contains("<svg"), "the decline has to end in a drawing")
            XCTAssertNil(result.notice, "a fallback is not a degraded render and must raise no badge")
        }
    }

    /// What a throw out of Pele does, and what it is allowed to say. Pele is synchronous and
    /// called inside the render, so an uncaught throw would take the whole diagram down with it;
    /// and a `PeleError` carries the reader's own source in both `message` and `snippet`, where
    /// `rendererFallback` is reported to Swift and logged. So the reason is the error's `code` and
    /// nothing else.
    ///
    /// Stubbed, and only because nothing real reaches it: see the test above for what was tried.
    /// The stub throws what Pele throws — a `PeleError` is an `Error` subclass with `code`,
    /// `line`, `column`, `snippet` and a message that quotes the line back.
    func testAThrowOutOfPeleIsADeclineAndReportsNoSource() async throws {
        try await withPatchedWorld(
            // The whole namespace is swapped rather than its `render`: Pele exposes that one as a
            // non-configurable getter, so assigning to it fails silently and the real renderer
            // goes on drawing -- which is how this test first passed while proving nothing.
            """
            window.__peleHeld = window.pele;
            window.pele = { render: function () {
              var e = new Error("Parse error on line 2:\\n  orders --> pg[(Postgres)]\\n-----^");
              e.name = "PeleError";
              e.code = "syntax";
              e.snippet = "orders --> pg[(Postgres)]";
              throw e;
            } };
            return 1;
            """,
            undo: "window.pele = window.__peleHeld; delete window.__peleHeld; return 1;"
        ) { engine in
            let result = try await self.draw(Self.hub, through: engine)
            XCTAssertEqual(result.renderer, "mermaid", "a throw is a decline, not a failed render")
            XCTAssertEqual(result.rendererFallback, "threw:syntax")
            XCTAssertFalse(
                try XCTUnwrap(result.rendererFallback).contains("Postgres"),
                "the reason quoted the reader's diagram back"
            )
            XCTAssertGreaterThan(result.width, 0)
        }
    }

    // MARK: - Harness

    /// One render through an engine the caller already holds, so a patched content world and the
    /// render that reads it are the same JS context.
    private func draw(_ source: String, through engine: MermaidEngineView) async throws -> MermaidRenderResult {
        Self.counter += 1
        return try await engine.render(
            MermaidRenderRequest(
                source: source,
                theme: MermaidThemeCatalogue.theme(
                    .pele, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                ),
                seed: "flowpeek-pele",
                renderID: MermaidRenderIdentifier.renderID(Self.counter)
            )
        )
    }

    /// Runs `body` against a content world with `patch` applied, and takes it back out whichever
    /// way `body` ends: the engine returns to a pool the rest of this suite draws from, and an
    /// engine left without its renderer would fail the next test instead of this one.
    private func withPatchedWorld(
        _ patch: String,
        undo: String,
        _ body: (MermaidEngineView) async throws -> Void
    ) async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }
        _ = try await engine.evaluate(patch)
        do {
            try await body(engine)
        } catch {
            _ = try? await engine.evaluate(undo)
            throw error
        }
        _ = try await engine.evaluate(undo)
    }

    /// The scrub still runs over Pele's output, and finds nothing: measured across 20 diagram
    /// types, it emits no banned element, no `<a>`, no `<foreignObject>`, no `on*` attribute and
    /// no `url()` anywhere. A removal here would be a change in what Pele emits, and the one
    /// removal that would matter — the `style` attribute, dropped whole by the `url()` rule —
    /// takes every colour in the drawing with it.
    func testPeleOutputGivesTheScrubNothingToDo() async throws {
        for source in [Self.hub, "sequenceDiagram\n    A->>B: hi", "pie\n    \"a\" : 1"] {
            let result = try await render(source, .pele)
            XCTAssertEqual(result.renderer, "pele")
            XCTAssertEqual(result.scrubbed, [], "the scrub had to remove something from Pele's output")
        }
    }

    /// The editorial passes are mermaid's repairs and must not run here. `tagStructure` is the one
    /// that would be visible if it did — it writes an `fp-` class onto every node it recognises —
    /// and the Pele theme reaches it through neither gate: it carries no stylesheet to find
    /// `.fp-ladder` in, and the seam hands Pele's output to `dressPele` instead.
    func testTheEditorialPassesDoNotTouchPeleOutput() async throws {
        let result = try await render(Self.hub, .pele)
        XCTAssertEqual(result.renderer, "pele")
        XCTAssertFalse(result.svg.contains("fp-"), "an editorial pass tagged Pele's markup")
        XCTAssertFalse(result.svg.contains("<marker"), "Pele draws its arrowheads as filled paths")
    }

    /// Byte stability across two renders into the same pooled JS context, as the flow renderer is
    /// held to. Pele caches text widths across renders — `forgetTextWidths()` exists to clear that
    /// cache — so a second render of the same source is where a cache that changed the layout
    /// would show up.
    func testTheSameSourceRendersToTheSameBytesTwice() async throws {
        let first = try await render(Self.hub, .pele)
        let second = try await render(Self.hub, .pele)
        XCTAssertEqual(first.renderer, "pele")
        XCTAssertEqual(first.svg, second.svg)
    }
}
