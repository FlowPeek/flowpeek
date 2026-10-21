import AppKit
import FlowPeekCore
import WebKit
import XCTest

@testable import FlowPeek

@MainActor
final class EditorialStructureTests: XCTestCase {
    private static let pool = MermaidWebViewPool()
    private static var counter: UInt64 = 0

    /// A hub with two entry points, a declared store and a stadium terminator: one diagram that
    /// exercises every rung the sweep can assign.
    private static let hub = """
    flowchart TD
        web[Web App] --> gw{{API Gateway}}
        mob[Mobile App] --> gw
        gw --> auth[Auth]
        gw --> orders[Orders]
        orders --> pg[(Postgres)]
        auth --> deny([Denied])
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
                seed: "flowpeek-editorial",
                renderID: MermaidRenderIdentifier.renderID(Self.counter)
            )
        )
    }

    /// The drawing without the stylesheet. The theme's own rules name every `fp-` token, so
    /// counting them in the whole document would count the CSS as well as the picture.
    private func drawing(_ svg: String) -> String {
        guard let end = svg.range(of: "</style>") else { return svg }
        return String(svg[end.upperBound...])
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The rungs are facts about the graph: in-degree 0 is an entry, out-degree 0 a terminal, a
    /// cylinder a store, and everything in between the workhorse.
    func testEveryNodeGetsTheRungItsPositionEarns() async throws {
        let markup = drawing(try await render(Self.hub, .editorial).svg)
        XCTAssertEqual(occurrences("fp-entry", in: markup), 2, "the two in-degree-0 nodes")
        XCTAssertEqual(occurrences("fp-store", in: markup), 1, "the declared cylinder")
        XCTAssertEqual(occurrences("fp-terminal", in: markup), 1, "the one out-degree-0 node")
        XCTAssertEqual(occurrences("fp-backend", in: markup), 3, "auth, orders and the gateway")
    }

    /// No node and no edge is promoted to the accent by its degree.
    ///
    /// These used to assert the opposite: the gateway, busiest at degree four, came out `fp-focal`,
    /// and with `web` given a second exit its edge into the gateway came out `fp-accent` with an
    /// arrowhead of its own. That no longer describes what the renderer should do. The pick was
    /// arithmetic -- nothing in either source asks for it -- and a reader-facing review of 16 sources
    /// read five of the six such picks as a claim the source never made, "this is the critical
    /// path" among them. flowpeek-flow.js `tagLadder` records the measurement.
    func testNeitherTheBusiestNodeNorAnEdgeIntoItIsAccented() async throws {
        let labelled = """
        flowchart TD
            web[Web App] -->|traffic| gw{{API Gateway}}
            mob[Mobile App] --> gw
            gw --> auth[Auth]
            gw --> orders[Orders]
            orders --> pg[(Postgres)]
            auth --> deny([Denied])
            web --> cdn[CDN]
        """
        for source in [Self.hub, labelled] {
            let markup = drawing(try await render(source, .editorial).svg)
            XCTAssertEqual(occurrences("fp-focal", in: markup), 0, "a node was accented by its degree")
            XCTAssertFalse(markup.contains("fp-accent"), "an edge was accented by its source's degree")
            XCTAssertTrue(markup.contains("fp-entry"), "the ladder itself still ran")
        }
    }

    /// The emphasis an author does ask for still arrives, and it is theirs rather than the theme's.
    func testANodeTheAuthorPaintedKeepsTheAuthorsFill() async throws {
        let source = Self.hub + "\n    style gw fill:#ff0000"
        let markup = drawing(try await render(source, .editorial).svg)
        XCTAssertTrue(markup.contains("fill:#ff0000"), "the author's own fill has to survive")
    }

    /// The whole reason the 124 system goldens do not move: the sweep is opted into by the theme's
    /// stylesheet, and the system theme has no `fp-` rules to opt in with.
    func testTheSystemThemeIsNeverTouchedByTheSweep() async throws {
        let markup = drawing(try await render(Self.hub, .system).svg)
        for token in ["fp-focal", "fp-entry", "fp-store", "fp-terminal", "fp-backend", "fp-accent"] {
            XCTAssertFalse(markup.contains(token), "the system theme was given \(token)")
        }
    }

    /// The sweep reads attributes and nothing else, so it has to be as deterministic as the render
    /// it runs inside -- otherwise the first Editorial golden recorded would never match again.
    ///
    /// What is compared is the sweep's own output: the sequence of rungs it assigns. Deliberately
    /// not the whole SVG, which is not byte-stable for this diagram under ANY theme. Measured: the
    /// same source rendered twice into two fresh engines differs in the control points of the
    /// stadium and cylinder shapes, because mermaid draws those through rough.js and gives it no
    /// fixed seed -- and the system theme jitters identically, so it is nothing a theme can cause or
    /// cure. The 124 goldens are unaffected only because none of them contains one of those shapes,
    /// which is worth knowing before an Editorial golden corpus is ever recorded.
    func testTheSweepIsByteStableAcrossRepeatedRenders() async throws {
        func rungs() async throws -> [String] {
            let pool = MermaidWebViewPool()
            let engine = try pool.checkOut()
            defer { pool.evict(engine) }
            let svg = try await engine.render(
                MermaidRenderRequest(
                    source: Self.hub,
                    theme: MermaidThemeCatalogue.theme(
                        .editorial, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                    ),
                    seed: "flowpeek-editorial",
                    renderID: "fp-stable"
                )
            ).svg
            let body = drawing(svg)
            let pattern = try NSRegularExpression(pattern: #"fp-(focal|accent|entry|store|terminal|backend|optional)"#)
            let range = NSRange(body.startIndex..., in: body)
            return pattern.matches(in: body, range: range).compactMap {
                Range($0.range, in: body).map { String(body[$0]) }
            }
        }
        let first = try await rungs()
        let second = try await rungs()
        XCTAssertFalse(first.isEmpty, "the sweep assigned nothing at all")
        XCTAssertEqual(first, second, "the same diagram earned different rungs twice")
    }
}
