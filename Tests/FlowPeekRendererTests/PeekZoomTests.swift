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

    /// The window is its final size from the first frame to the last. This is the assertion that
    /// fails on the old implementation.
    func testTheWindowNeverResizesWhileThePeekGrows() async throws {
        let coordinator = PreviewCoordinator(pool: MermaidWebViewPool())
        coordinator.peek(document: try document(), from: card)
        guard let panel = coordinator.quickPanelForTesting else {
            XCTFail("no panel"); return
        }
        let settled = panel.frame
        XCTAssertGreaterThan(settled.width, card.width * 2, "the panel opened at card size")

        var seen: [CGRect] = []
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(30))
            seen.append(panel.frame)
        }
        for frame in seen {
            XCTAssertEqual(frame.width, settled.width, accuracy: 0.5, "the window resized mid-zoom")
            XCTAssertEqual(frame.height, settled.height, accuracy: 0.5, "the window resized mid-zoom")
        }
        coordinator.endPeek()
        try await Task.sleep(for: .milliseconds(500))
    }

    /// And what does move: the content's own layer, scaled down at the start and back to nothing by
    /// the end. Read from the presentation layer, which is what is actually on screen rather than
    /// what the model says it will be.
    func testTheContentIsScaledOutOfTheCardAndEndsAtIdentity() async throws {
        let coordinator = PreviewCoordinator(pool: MermaidWebViewPool())
        coordinator.peek(document: try document(), from: card)
        guard let layer = coordinator.quickPanelForTesting?.contentView?.layer else {
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
