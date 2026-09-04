import AppKit
import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The keyboard's half of panning. `#stage` is the scroller and nothing in the page is focusable,
/// so an in-page `keydown` listener could never be delivered anything: an arrow key has to arrive
/// from Swift and move the scroller directly.
@MainActor
final class PreviewPanTests: XCTestCase {
    private static let pool = MermaidWebViewPool()

    private func scrolledEngine() async throws -> MermaidEngineView {
        let engine = try Self.pool.checkOut()
        _ = try await engine.render(
            MermaidRenderRequest(
                source: "flowchart TD\n  A[Start] --> B[End]",
                theme: MacMermaidTheme(appearance: .light, accentHex: "#0A84FF", increaseContrast: false),
                seed: "fp-pan",
                renderID: "fp-pan-1"
            )
        )
        // Zoomed past the stage in both directions, or there is nothing to scroll.
        _ = try await engine.evaluate("return window.__flowpeek.setScale(8);")
        _ = try await engine.evaluate("return window.__flowpeek.panBy(-1e6, -1e6);")
        return engine
    }

    private func offset(_ engine: MermaidEngineView) async throws -> CGPoint {
        let x = try await engine.evaluate("return document.getElementById('stage').scrollLeft;")
        let y = try await engine.evaluate("return document.getElementById('stage').scrollTop;")
        return CGPoint(
            x: (x as? NSNumber)?.doubleValue ?? .nan,
            y: (y as? NSNumber)?.doubleValue ?? .nan
        )
    }

    func testAPanMovesTheStageByThePixelDeltaItIsGiven() async throws {
        let engine = try await scrolledEngine()
        defer { Self.pool.checkIn(engine) }
        var at = try await offset(engine)
        XCTAssertEqual(at, .zero)

        engine.pan(dx: 40, dy: 25)
        try await settle()
        at = try await offset(engine)
        XCTAssertEqual(at, CGPoint(x: 40, y: 25))

        engine.pan(dx: -40, dy: 100)
        try await settle()
        at = try await offset(engine)
        XCTAssertEqual(at, CGPoint(x: 0, y: 125))
    }

    /// The glue must not be able to put the scroller into a nonsense state from a bad argument:
    /// `scrollTop = NaN` leaves the diagram unreachable until the panel is reopened.
    func testANonsenseDeltaLeavesTheStageWhereItWas() async throws {
        let engine = try await scrolledEngine()
        defer { Self.pool.checkIn(engine) }
        engine.pan(dx: 30, dy: 30)
        try await settle()
        let before = try await offset(engine)

        _ = try await engine.evaluate("return window.__flowpeek.panBy('nope', undefined);")
        let after = try await offset(engine)
        XCTAssertEqual(after, before)
    }

    /// `pan` is fire-and-forget from Swift, so the assertion has to let the call reach the page.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }
}
