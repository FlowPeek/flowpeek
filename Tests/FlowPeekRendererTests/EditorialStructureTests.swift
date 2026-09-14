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
        XCTAssertEqual(occurrences("fp-backend", in: markup), 2, "auth and orders")
    }

    /// One accent on one node, and nothing arbitrary carried off it.
    ///
    /// The hub here is reached from two entry nodes that are alike in every way, so there is no
    /// edge that deserves the accent more than the other and none gets it. Rendered and looked at,
    /// the alternative -- breaking the tie on document order -- put coral on one of two identical
    /// arrows and asked the reader to find a difference that was not there.
    func testTheBusiestNodeIsAccentedAndATiedEdgeIsLeftAlone() async throws {
        let markup = drawing(try await render(Self.hub, .editorial).svg)
        XCTAssertEqual(occurrences("fp-focal", in: markup), 1, "the accent is on exactly one node")
        XCTAssertEqual(
            occurrences("fp-accent\"", in: markup), 0,
            "two equal sources: neither edge has earned the accent"
        )
    }

    /// And where one source plainly is the busiest, the accent does travel: the edge, its label and
    /// an arrowhead of its own -- the last of which is the one thing a stylesheet cannot do, because
    /// every arrow in a flowchart points at the same shared marker.
    func testAnUnambiguousEdgeCarriesTheAccentAndItsOwnArrowhead() async throws {
        // `web` has two edges out, `mob` one, so the flow into the gateway has a clear main source.
        let source = Self.hub + "\n    web --> cdn[CDN]"
        let markup = drawing(try await render(source, .editorial).svg)
        XCTAssertEqual(occurrences("fp-focal", in: markup), 1)
        // Counted in class attributes only. The raw token also appears in the cloned marker's id
        // and in the `marker-end` that points at it, which the next assertion requires to exist, so
        // counting the string would be counting the same success twice and calling it a failure.
        XCTAssertEqual(
            occurrences("fp-accent\"", in: markup), 2,
            "the accent belongs on the edge and its label, and nowhere else"
        )
        XCTAssertTrue(
            markup.contains("-fp-accent-head\""),
            "the accent edge needs an arrowhead of its own: the shared one is every other arrow's too"
        )
    }

    /// The abstention is the part that keeps this an editorial accent rather than a signalling
    /// system. A chain has no busiest node, so it gets no accent -- and most previews are chains.
    func testADiagramWithNoBusiestNodeIsLeftUnaccented() async throws {
        let markup = drawing(try await render("flowchart TD\n  A --> B\n  B --> C\n  C --> D", .editorial).svg)
        XCTAssertEqual(occurrences("fp-focal", in: markup), 0, "a linear chain was given a focal node")
        XCTAssertTrue(markup.contains("fp-entry"), "the ladder itself still ran")
        XCTAssertTrue(markup.contains("fp-terminal"))
    }

    /// An author who has painted a node has already said where to look.
    func testANodeTheAuthorPaintedIsNeverMadeFocal() async throws {
        let source = Self.hub + "\n    style gw fill:#ff0000"
        let markup = drawing(try await render(source, .editorial).svg)
        XCTAssertEqual(occurrences("fp-focal", in: markup), 0)
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
