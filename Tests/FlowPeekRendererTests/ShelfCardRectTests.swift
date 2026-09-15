import AppKit
import QuartzCore
import FlowPeekCore
import SwiftUI
import XCTest

@testable import FlowPeek

/// The link in the peek chain that had never been checked: the rect the shelf hands out, against
/// where the card it names actually is on screen.
///
/// `PeekOriginTests` proves the zoom is faithful to the rect it is given. This proves the rect is
/// the card. Ground truth is the real `NSScrollView` behind the row -- its clip view's screen rect
/// and its live `bounds.origin`, which is the scrolling the row has actually done -- so the card's
/// position includes the movement that the reported rect was suspected of missing. Nothing is
/// sampled part-way through an animation: every reading is taken after the motion it depends on has
/// stopped, and the failures this catches are hundreds of points wide, not fractions of a frame.
@MainActor
final class ShelfCardRectTests: XCTestCase {
    /// From `DiagramShelfView`: 188pt cards 12pt apart, the row inset 18pt from the shelf's edge.
    private static let pitch: CGFloat = 200
    private static let rowInset: CGFloat = 18
    private static let cardWidth: CGFloat = 188
    /// The gap between the clip view's top and the card's: the row is 142pt tall with 2pt of
    /// padding under it inside a 150pt viewport, so SwiftUI centres it with 3pt above.
    private static let cardTopInset: CGFloat = 3

    private static let down: (code: UInt16, characters: String) = (125, "\u{F701}")
    private static let right: (code: UInt16, characters: String) = (124, "\u{F703}")
    private static let space: (code: UInt16, characters: String) = (49, " ")

    private var recorded: [DiagramHistoryEntry.ID] = []

    override func tearDown() async throws {
        // Shut down rather than dismissed: `endPeek` starts a 0.28s shrink and only lets the panel
        // go at the end of it, and a preview still being taken down when the next test raises one
        // is a test that fails on what the one before it left behind.
        AppState.shared.previews.endPeek()
        AppState.shared.previews.closeQuick()
        DiagramHistoryCoordinator.shared.close()
        for id in recorded { DiagramHistoryStore.shared.remove(id) }
        recorded = []
        try await Task.sleep(for: .milliseconds(400))
    }

    /// A shelf long enough that arrowing along it has to scroll.
    private func seedShelf() async throws {
        for index in 1...14 {
            guard let id = DiagramHistoryStore.shared.record(
                title: String(format: "ZZProbe %02d", index),
                source: "flowchart TD\n  A\(index) --> B\(index)",
                origin: .clipboard
            ) else { continue }
            recorded.append(id)
        }
        XCTAssertGreaterThanOrEqual(recorded.count, 10, "could not seed a shelf long enough to scroll")

        DiagramHistoryCoordinator.shared.show()
        try await Task.sleep(for: .milliseconds(900))
    }

    private func shelfPanel() -> NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && $0.contentView is NSHostingView<DiagramShelfView>
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView { return scroller }
        for child in view.subviews where firstScrollView(in: child) != nil {
            return firstScrollView(in: child)
        }
        return nil
    }

    /// Where card `index` really is on screen, right now: the clip view, shifted by the scroll.
    ///
    /// `contentView.bounds.origin.x` is the scrolling the row has actually performed, read from the
    /// scroll view itself, so the horizontal half of this owes nothing to the code under test. The
    /// vertical half is a model of the layout and is only asserted where it is not the point.
    fileprivate func realCard(_ index: Int, panel: NSPanel, scroller: NSScrollView) -> CGRect {
        let clip = panel.convertToScreen(
            scroller.contentView.convert(scroller.contentView.bounds, to: nil)
        )
        let height = clip.height - Self.cardTopInset - 5
        return CGRect(
            x: clip.minX - scroller.contentView.bounds.origin.x
                + Self.rowInset + CGFloat(index) * Self.pitch,
            y: clip.maxY - Self.cardTopInset - height,
            width: Self.cardWidth,
            height: height
        )
    }

    private func send(_ key: (code: UInt16, characters: String), to panel: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.characters,
                isARepeat: false,
                keyCode: key.code
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// The peek grows out of the card the keyboard is on -- the first one, and every one arrowed to
    /// afterwards, including the ones that only came into view because the row scrolled to them.
    func testThePeekStartsOnTheCardTheKeyboardIsOn() async throws {
        try await seedShelf()

        guard let panel = shelfPanel(), let content = panel.contentView else {
            return XCTFail("the shelf did not come up")
        }
        guard let scroller = firstScrollView(in: content) else {
            return XCTFail("no scroll view behind the row")
        }

        func check(_ step: String, index: Int) {
            guard let handed = AppState.shared.previews.peekOrigin else {
                return XCTFail("\(step): no peek was raised at all")
            }
            let real = realCard(index, panel: panel, scroller: scroller)
            XCTAssertEqual(handed.minX, real.minX, accuracy: 1, "\(step): peek starts sideways of the card")
            XCTAssertEqual(handed.minY, real.minY, accuracy: 1, "\(step): peek starts above or below the card")
            XCTAssertEqual(handed.width, real.width, accuracy: 1, "\(step): peek starts the wrong width")
            XCTAssertEqual(handed.height, real.height, accuracy: 1, "\(step): peek starts the wrong height")
        }

        // Into the row, then Space to grow the preview out of the card the keyboard landed on.
        send(Self.down, to: panel)
        try await Task.sleep(for: .milliseconds(500))
        send(Self.space, to: panel)
        try await Task.sleep(for: .milliseconds(500))
        check("Space on the first card", index: 0)

        // And along the row. Past the third card the shelf scrolls to keep the focused one centred,
        // which is exactly where a rect read before the scroll goes 200 points wrong.
        for step in 1...6 {
            send(Self.right, to: panel)
            try await Task.sleep(for: .milliseconds(600))
            check("arrowed to card \(step)", index: step)
        }
    }

    /// Where the zoom's first frame puts the drawn content, in screen coordinates.
    ///
    /// Read from the animation's own `fromValue`, the same way `PeekOriginTests` reads it: exact,
    /// and not a sample taken part-way through an ease-out. It has to be this rather than
    /// `peekOrigin`, because `peekOrigin` is corrected after the fact when the row reports -- so a
    /// zoom that began on the wrong rectangle would leave a right-looking `peekOrigin` behind it,
    /// and a test that read that would pass over the very bug it is here to catch. Checked: with
    /// the scroll animated again, `peekOrigin` alone passes and this fails.
    private func zoomStart() -> CGRect? {
        PeekZoomGeometry.start(of: AppState.shared.previews.quickPanelForTesting)
    }

    /// The path the test above never takes: Space pressed on a card with NO peek already up.
    ///
    /// That is the only call in the app that actually starts a zoom. `DiagramPreview.peek` returns
    /// early through `acceptsDiagramInPlace` whenever a peek is already showing, so the arrowing
    /// measured above moves a diagram inside a stationary panel and grows nothing out of anything.
    /// Here the preview really is grown, and the arrows immediately before the Space are what used
    /// to leave the row moving underneath it.
    ///
    /// Only the horizontal axis is asserted. The clip view's own `bounds.origin.x` is a reading of
    /// the scrolling the row has really done, so the x ground truth owes nothing to the code under
    /// test; the vertical constants in `realCard` are a model of the layout rather than a reading
    /// of it, and an assertion that restates its own expectation cannot fail.
    func testSpacePressedAfterArrowingGrowsTheZoomOutOfTheCard() async throws {
        try await seedShelf()

        guard let panel = shelfPanel(), let content = panel.contentView else {
            return XCTFail("the shelf did not come up")
        }
        guard let scroller = firstScrollView(in: content) else {
            return XCTFail("no scroll view behind the row")
        }

        send(Self.down, to: panel)
        try await Task.sleep(for: .milliseconds(500))

        // Five arrows in quick succession and then Space with no pause at all -- a hand that knows
        // which diagram it wants. This is the gesture that used to grow the preview out of a card
        // two places along from the one the keyboard was on.
        for _ in 1...5 {
            send(Self.right, to: panel)
            try await Task.sleep(for: .milliseconds(60))
        }
        send(Self.space, to: panel)

        // Inside the 0.28s zoom, because the animation is what is being read and it is taken away
        // when it finishes. The value itself is the animation's `fromValue`, so nothing here
        // depends on how far along it is.
        try await Task.sleep(for: .milliseconds(100))
        guard let began = zoomStart() else {
            return XCTFail("Space started no zoom at all")
        }

        // The card's own resting place, read once everything has stopped.
        try await Task.sleep(for: .milliseconds(900))
        let real = realCard(5, panel: panel, scroller: scroller)
        XCTAssertEqual(
            began.minX, real.minX, accuracy: 1,
            "the zoom began \(Int(began.minX - real.minX)) points sideways of the card"
        )
        XCTAssertEqual(began.width, real.width, accuracy: 1, "the zoom began the wrong width")
    }
}
