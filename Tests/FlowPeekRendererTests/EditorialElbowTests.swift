import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The connector rule diagram-design calls non-negotiable: orthogonal routing, rounded bends.
///
/// "Rounded right-angle (orthogonal) connectors are mandatory ... every bend must be a quarter-arc
/// with r=8 ... diagonal connectors are an automatic fail." Mermaid gives one half or the other and
/// never both: its `rounded` curve rounds the bends but lets dagre run an edge diagonally between
/// ranks, and its `step` curve routes on the axes but turns square corners. So the theme asks for
/// `step` and `roundEdges` in the glue rewrites the corners.
///
/// What is checked is the drawn path, not the setting that produced it.
@MainActor
final class EditorialElbowTests: XCTestCase {
    /// Nodes far enough off the gateway's centre line that an edge cannot reach one from the other
    /// without turning.
    ///
    /// Three in and three out rather than two and two: port placement lines a connector up whenever
    /// both faces can reach the coordinate halfway between their two boxes, so a two-wide fan on
    /// 80px boxes comes out as five straight segments and there is no corner left to check. At three
    /// wide the outer leaves are past the gateway's face and four of the seven edges turn.
    private static let source = """
    flowchart TD
        web[Web App] --> gw{{API Gateway}}
        mob[Mobile App] --> gw
        cli[CLI Client] --> gw
        gw --> auth[Auth Service]
        gw --> orders[Order Service]
        gw --> search[Search Service]
        orders --> pg[(Postgres)]
    """

    private func edgePaths(_ id: MermaidThemeID) async throws -> [String] {
        let pool = MermaidWebViewPool()
        let engine = try pool.checkOut()
        defer { pool.evict(engine) }
        let svg = try await engine.render(
            MermaidRenderRequest(
                source: Self.source,
                theme: MermaidThemeCatalogue.theme(
                    id, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                ),
                seed: "fp-elbow",
                renderID: "fp-elbow-\(id.rawValue)"
            )
        ).svg
        return svg.components(separatedBy: "class=\"edge-thickness-normal")
            .dropFirst()
            .compactMap { chunk in
                guard let start = chunk.range(of: " d=\"") else { return nil }
                guard let end = chunk[start.upperBound...].firstIndex(of: "\"") else { return nil }
                return String(chunk[start.upperBound..<end])
            }
    }

    /// The `L` runs of a path, as (dx, dy). `Q` corners are skipped: a corner is where the path is
    /// meant to change direction, and it is the runs between them that must lie on an axis.
    private func straightRuns(_ d: String) -> [(CGFloat, CGFloat)] {
        var runs: [(CGFloat, CGFloat)] = []
        var cursor: CGPoint?
        // Split into commands, keeping the letter.
        var command = Character(" ")
        var buffer = ""
        func flush() {
            let numbers = buffer
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { Double($0) }
            defer { buffer = "" }
            switch command {
            case "M":
                guard numbers.count >= 2 else { return }
                cursor = CGPoint(x: numbers[0], y: numbers[1])
            case "L":
                guard numbers.count >= 2, let from = cursor else { return }
                let to = CGPoint(x: numbers[0], y: numbers[1])
                runs.append((to.x - from.x, to.y - from.y))
                cursor = to
            case "Q":
                guard numbers.count >= 4 else { return }
                cursor = CGPoint(x: numbers[2], y: numbers[3])
            default:
                return
            }
        }
        for character in d {
            if character.isLetter {
                flush()
                command = character
            } else {
                buffer.append(character)
            }
        }
        flush()
        return runs
    }

    /// Every straight run of an editorial edge lies on an axis. A run that is neither horizontal
    /// nor vertical is the diagonal the source calls an automatic fail.
    func testEveryEditorialEdgeRunsOnAnAxis() async throws {
        let paths = try await edgePaths(.editorial)
        XCTAssertFalse(paths.isEmpty, "no edges were found to check")
        for d in paths {
            for (dx, dy) in straightRuns(d) where abs(dx) > 0.5 && abs(dy) > 0.5 {
                XCTFail("a run of \(Int(dx))x\(Int(dy)) is diagonal, in \(d.prefix(120))")
            }
        }
    }

    /// And the bends are bends: a corner is a quadratic, not a square join.
    func testEditorialCornersAreRounded() async throws {
        let paths = try await edgePaths(.editorial)
        let withCorners = paths.filter { $0.contains("Q") }
        XCTAssertFalse(
            withCorners.isEmpty,
            "no edge was given a rounded corner, so the rewrite did not run"
        )
    }

    /// The orthogonal routing belongs to flowcharts and stops there.
    ///
    /// mermaid keeps one curve setting and more than one family reads it: a state diagram renders
    /// through the same dagre code and takes whatever `flowchart.curve` says. Given `step` there,
    /// the path it interpolates does not meet the boundary the renderer clipped to, and every
    /// transition's arrowhead came away from its box pointing the wrong way -- seen on screen, on
    /// a five-state diagram, before the theme's one curve was split into two.
    ///
    /// Measured either side of the split, on this diagram's `Draft --> Review`:
    ///
    ///     with the gate   M54.671,102.156 L36.469,128.891 Q… L54.671,170.313
    ///     without it      M54.671,102.156 L43.070,102.156 L43.070,136.234 … L54.671,170.313
    ///
    /// The second has no diagonal left in it, which is what `step` does and what a state diagram
    /// must not be given.
    func testAStateDiagramKeepsTheCurveItAlwaysHad() async throws {
        let pool = MermaidWebViewPool()
        let engine = try pool.checkOut()
        defer { pool.evict(engine) }
        let svg = try await engine.render(
            MermaidRenderRequest(
                source: """
                stateDiagram-v2
                    [*] --> Draft
                    Draft --> Review: submit
                    Review --> Draft: reject
                """,
                theme: MermaidThemeCatalogue.theme(
                    .editorial, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
                ),
                seed: "fp-state", renderID: "fp-state"
            )
        ).svg

        // The same split the flowchart tests use: a transition's class list opens with the
        // thickness and carries the word `transition` after it.
        let parts: [String] = svg.components(separatedBy: "class=\"edge-thickness-normal")
        let paths = parts.dropFirst().compactMap { chunk -> String? in
            guard let s = chunk.range(of: " d=\"") else { return nil }
            guard let e = chunk[s.upperBound...].firstIndex(of: "\"") else { return nil }
            return String(chunk[s.upperBound..<e])
        }
        XCTAssertGreaterThanOrEqual(paths.count, 2, "the two bent transitions were not found")

        // The two that bend. `[*] --> Draft` drops straight down and is axis-aligned whatever the
        // curve is, so it says nothing either way and is not what is counted.
        let bent = paths.filter { straightRuns($0).count > 1 || $0.contains("Q") || $0.contains("C") }
        XCTAssertFalse(bent.isEmpty, "no transition bent at all")
        for d in bent {
            XCTAssertTrue(
                straightRuns(d).contains { abs($0.0) > 0.5 && abs($0.1) > 0.5 },
                "a transition came out with no diagonal run, so the flowchart's curve reached it: \(d)"
            )
        }
    }

    /// The rewrite is the editorial theme's, and the system theme's goldens depend on it staying
    /// that way -- 124 of them. Its edges are mermaid's own splines, which are not axis-aligned.
    func testTheSystemThemeKeepsItsOwnEdges() async throws {
        let paths = try await edgePaths(.system)
        XCTAssertFalse(paths.isEmpty)
        let diagonal = paths.contains { d in
            straightRuns(d).contains { abs($0.0) > 0.5 && abs($0.1) > 0.5 }
                || d.contains("C")
        }
        XCTAssertTrue(diagonal, "the system theme's edges were rewritten, which would move its goldens")
    }
}
