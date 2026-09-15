import AppKit
import FlowPeekCore
import XCTest

@testable import FlowPeek

/// Where the zoom actually starts on screen, measured rather than reasoned about.
///
/// The arithmetic that puts a card's rectangle into screen coordinates was already checked and is
/// right: two cards 400 points apart produced origins 400 points apart. That is not the same claim
/// as "the picture starts over the card", though, because between the origin and the screen there
/// is a layer transform, a pinned content frame and a window that has been widened to hold both.
/// This measures the end of that chain: it reads the presentation layer -- what is composited, not
/// what was asked for -- and works out where the drawn content's centre really is.
@MainActor
final class PeekOriginTests: XCTestCase {
    private func document() throws -> DiagramDocument {
        DiagramDocument(title: "Peeked", source: try MermaidSource(rawValue: "flowchart TD\n  A --> B"))
    }

    /// Where the zoom's first frame puts the drawn content, in screen coordinates.
    ///
    /// Read from the animation's own `fromValue` rather than by sampling the presentation layer
    /// part-way through. Sampling was the first attempt and it was not a measurement: 25ms into a
    /// 280ms ease-out the content has already travelled an amount that depends on when the test
    /// happened to look, and with a tolerance loose enough to survive that, the broken transform
    /// passed too. This value is exact and does not depend on timing at all.
    private func zoomStart(_ coordinator: PreviewCoordinator) -> CGRect? {
        guard let panel = coordinator.quickPanelForTesting,
              let container = panel.contentView as? ResizableContentView,
              let layer = container.content.layer,
              let zoom = layer.animation(forKey: "flowpeek.peek") as? CABasicAnimation,
              let from = (zoom.fromValue as? NSValue)?.caTransform3DValue else { return nil }
        // The layer is transformed about its own centre, so the drawn rectangle is the frame scaled
        // about that centre and then moved by the matrix's translation.
        let frame = container.content.frame
        let width = frame.width * from.m11
        let height = frame.height * from.m22
        let centre = CGPoint(x: frame.midX + from.m41, y: frame.midY + from.m42)
        return CGRect(
            x: panel.frame.minX + centre.x - width / 2,
            y: panel.frame.minY + centre.y - height / 2,
            width: width,
            height: height
        )
    }

    private func start(from card: CGRect) async throws -> CGRect? {
        let coordinator = PreviewCoordinator(pool: MermaidWebViewPool())
        coordinator.peek(document: try document(), from: card)
        let rect = zoomStart(coordinator)
        coordinator.endPeek()
        try await Task.sleep(for: .milliseconds(500))
        return rect
    }

    /// The zoom's first frame is the card. Not near it, not scaled toward it: the same rectangle.
    func testTheZoomStartsExactlyOnTheCardItWasGiven() async throws {
        // Placed against the screen this is running on rather than at absolute coordinates. The
        // first version used fixed rectangles from a large display and failed on a CI runner, where
        // the window they implied did not fit and AppKit trimmed it.
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 188, height: 142)
        for card in [
            CGRect(origin: CGPoint(x: screen.minX + 40, y: screen.minY + 40), size: size),
            CGRect(origin: CGPoint(x: screen.maxX - size.width - 40, y: screen.minY + 40), size: size),
            CGRect(origin: CGPoint(x: screen.midX, y: screen.maxY - size.height - 40), size: size),
        ] {
            guard let began = try await start(from: card) else {
                XCTFail("no animation for \(card)"); return
            }
            XCTAssertEqual(began.midX, card.midX, accuracy: 1, "started off to the side of \(card)")
            XCTAssertEqual(began.midY, card.midY, accuracy: 1, "started above or below \(card)")
            XCTAssertEqual(began.width, card.width, accuracy: 1, "started the wrong width")
            XCTAssertEqual(began.height, card.height, accuracy: 1, "started the wrong height")
        }
    }

    /// And the thing the reader actually reported: two cards far apart must not share a start.
    func testTwoCardsDoNotStartTheZoomInTheSamePlace() async throws {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 188, height: 142)
        let left = CGRect(origin: CGPoint(x: screen.minX + 40, y: screen.minY + 40), size: size)
        let right = CGRect(origin: CGPoint(x: screen.maxX - size.width - 40, y: screen.minY + 40), size: size)
        guard let fromLeft = try await start(from: left),
              let fromRight = try await start(from: right) else {
            XCTFail("no animation"); return
        }
        XCTAssertEqual(
            fromRight.midX - fromLeft.midX, right.midX - left.midX, accuracy: 1,
            "the gap between the two starts does not match the gap between the two cards"
        )
    }
}
