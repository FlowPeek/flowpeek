import AppKit
import FlowPeekCore
import XCTest

@testable import FlowPeek

/// How a peek arrives: the drawn content scales out of the card, and the window does not resize.
///
/// Both halves matter, and the second is what was wrong. Animating the window's frame makes SwiftUI
/// lay out again at every step and the diagram re-fits itself to each new stage -- so the picture
/// stayed one size on screen while the window grew around it, which reads as a window being dragged
/// open rather than as a preview coming out of a card.
@MainActor
final class PeekZoomTests: XCTestCase {
    private func document() throws -> DiagramDocument {
        DiagramDocument(title: "Peeked", source: try MermaidSource(rawValue: "flowchart TD\n  A --> B"))
    }

    private let card = CGRect(x: 140, y: 220, width: 150, height: 96)

    /// The drawn content keeps one size for the whole zoom.
    ///
    /// This is the assertion the old implementation fails. It animated the window's frame, so
    /// SwiftUI laid out again at every step and the diagram re-fitted itself to each new stage --
    /// the picture stayed one size on screen while the window opened around it.
    ///
    /// The window itself does move, and on purpose: it is widened to hold both the panel and the
    /// card for the duration, because a window cannot draw outside itself and the shrink was being
    /// clipped at its edge. What must not move is what is drawn inside it.
    func testTheDrawnContentIsNeverRelaidOutWhileThePeekGrows() async throws {
        let coordinator = PreviewCoordinator(pool: MermaidWebViewPool())
        coordinator.peek(document: try document(), from: card)
        guard let panel = coordinator.quickPanelForTesting,
              let container = panel.contentView as? ResizableContentView else {
            XCTFail("no panel"); return
        }
        let settled = container.content.frame.size
        XCTAssertGreaterThan(settled.width, card.width * 2, "the content opened at card size")

        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(container.content.frame.width, settled.width, accuracy: 0.5,
                           "the content was re-laid-out mid-zoom")
            XCTAssertEqual(container.content.frame.height, settled.height, accuracy: 0.5,
                           "the content was re-laid-out mid-zoom")
        }
        coordinator.endPeek()
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Nothing is drawn outside the window, or it is cut off at the edge -- which is exactly how the
    /// shrink came out clipped. The window has to contain the card it is zooming into.
    func testTheWindowContainsTheCardItZoomsOutOf() async throws {
        let coordinator = PreviewCoordinator(pool: MermaidWebViewPool())
        coordinator.peek(document: try document(), from: card)
        guard let panel = coordinator.quickPanelForTesting else { XCTFail("no panel"); return }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(
            panel.frame.contains(card),
            "the card is outside the window, so the zoom is clipped: \(panel.frame) vs \(card)"
        )
        coordinator.endPeek()
        try await Task.sleep(for: .milliseconds(500))
        // And it is given back afterwards, rather than left as a window the size of two things.
        XCTAssertFalse(coordinator.isPeeking)
    }

    /// And what does move: the content's own layer, scaled down at the start and back to nothing by
    /// the end. Read from the presentation layer, which is what is actually on screen rather than
    /// what the model says it will be.
    func testTheContentIsScaledOutOfTheCardAndEndsAtIdentity() async throws {
        let coordinator = PreviewCoordinator(pool: MermaidWebViewPool())
        coordinator.peek(document: try document(), from: card)
        // The drawn content's own layer, which is what is scaled -- not the container's, which is
        // the window-sized wrapper the resize edges live on.
        guard let container = coordinator.quickPanelForTesting?.contentView as? ResizableContentView,
              let layer = container.content.layer else {
            XCTFail("no layer"); return
        }
        // Early enough to still be small: the zoom is 200ms.
        try await Task.sleep(for: .milliseconds(40))
        let during = (layer.presentation() ?? layer).transform.m11
        XCTAssertLessThan(during, 0.95, "the content was never scaled down, so nothing zoomed")
        XCTAssertGreaterThan(during, 0, "the content was scaled to nothing")

        try await Task.sleep(for: .milliseconds(400))
        let after = (layer.presentation() ?? layer).transform.m11
        XCTAssertEqual(after, 1, accuracy: 0.01, "the content did not finish at its real size")
        coordinator.endPeek()
        try await Task.sleep(for: .milliseconds(500))
    }
}
