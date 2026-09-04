import AppKit
import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The accounting behind "previews stay instant": every surface that closes has to hand its engine
/// back, or the pool refills cold and the next preview costs 159-750 ms instead of 5-11 ms.
/// Driven through the real coordinator and a private pool, so the shared one is left alone.
@MainActor
final class PreviewLifecycleTests: XCTestCase {
    private func document(_ title: String) throws -> DiagramDocument {
        DiagramDocument(title: title, source: try MermaidSource(rawValue: "flowchart TD\n  A[\(title)] --> B"))
    }

    /// One test case's own windows. `isReleasedWhenClosed` is false for these, so every window this
    /// process has ever opened stays in `NSApp.windows` — and other cases in the same process leave
    /// their own visible ones behind. Counting the whole application made each assertion depend on
    /// which tests had run first; a case counts from a baseline it takes itself instead.
    @MainActor
    private struct WindowScope {
        private let existing: Set<ObjectIdentifier>

        init() { existing = Set(NSApp.windows.map(ObjectIdentifier.init)) }

        var previews: [FlowPeekGlassWindow] {
            NSApp.windows
                .compactMap { $0 as? FlowPeekGlassWindow }
                .filter { $0.isVisible && !existing.contains(ObjectIdentifier($0)) }
        }

        func preview(titled title: String) throws -> FlowPeekGlassWindow {
            try XCTUnwrap(previews.first { $0.title == title })
        }
    }

    func testAQuickPreviewTakenWhileAWindowIsOpenStillReturnsItsEngine() throws {
        let scope = WindowScope()
        let pool = MermaidWebViewPool()
        pool.warmUp()
        let coordinator = PreviewCoordinator(pool: pool)

        coordinator.showQuick(document: try document("first"))
        coordinator.promote()
        XCTAssertEqual(scope.previews.count, 1)

        // The panel that is opened, looked at and closed while the window stays up. Its engine used
        // to be dropped on the floor, one pre-warmed view per preview.
        coordinator.showQuick(document: try document("second"))
        coordinator.closeQuick()

        scope.previews.forEach { $0.close() }
        XCTAssertEqual(pool.idleCount, 2, "both surfaces must have checked their engines back in")
        XCTAssertTrue(scope.previews.isEmpty)
    }

    /// One shared window slot meant the close dot on the first window closed the second one, and the
    /// first window's engine was never returned because the coordinator no longer knew about it.
    func testASecondWindowLeavesTheFirstOneAloneAndBothReleaseIndependently() throws {
        let scope = WindowScope()
        let pool = MermaidWebViewPool()
        pool.warmUp()
        let coordinator = PreviewCoordinator(pool: pool)

        coordinator.showQuick(document: try document("left"))
        coordinator.promote()
        coordinator.showQuick(document: try document("right"))
        coordinator.promote()

        XCTAssertEqual(scope.previews.count, 2)
        let left = try scope.preview(titled: "left")
        let right = try scope.preview(titled: "right")
        XCTAssertNotEqual(left.frame.origin, right.frame.origin, "a second window must not hide behind the first")

        left.close()
        XCTAssertEqual(scope.previews.map(\.title), ["right"], "closing one window must not take the other with it")
        XCTAssertEqual(pool.idleCount, 1)

        right.close()
        XCTAssertEqual(pool.idleCount, 2)
    }

    /// The net under the explicit calls: a model that is dropped without `release()` — a surface torn
    /// down by SwiftUI, a coordinator replaced — still returns its engine.
    func testAModelDroppedWithoutReleaseStillReturnsItsEngine() {
        let pool = MermaidWebViewPool()
        pool.warmUp()
        XCTAssertEqual(pool.idleCount, 1)

        autoreleasepool {
            let model = DiagramViewModel(title: "orphan", source: "flowchart TD\n  A --> B", pool: pool)
            model.attach()
            XCTAssertEqual(pool.idleCount, 0)
        }

        XCTAssertEqual(pool.idleCount, 1)
    }

    /// The way back to a window another application has covered. A promoted preview is borderless:
    /// no Dock icon, no entry in the Window menu, so the menu-bar entry is the only route — and it
    /// must only be offered while there is in fact a window to raise.
    func testTheMenuBarIsToldWhenThereIsAPromotedWindowToGoBackTo() throws {
        let scope = WindowScope()
        let pool = MermaidWebViewPool()
        pool.warmUp()
        let coordinator = PreviewCoordinator(pool: pool)
        var offered: [Bool] = []
        coordinator.onPromotedChange = { offered.append($0) }

        coordinator.showQuick(document: try document("recoverable"))
        XCTAssertFalse(coordinator.hasPromotedPreviews, "a quick panel is not a window to go back to")
        XCTAssertTrue(offered.isEmpty)

        coordinator.promote()
        XCTAssertTrue(coordinator.hasPromotedPreviews)
        XCTAssertEqual(offered, [true])

        // Raising it must not disturb the window itself, only its order.
        let window = try scope.preview(titled: "recoverable")
        let frame = window.frame
        coordinator.revealPromoted()
        XCTAssertEqual(window.frame, frame)
        XCTAssertTrue(window.isVisible)

        window.close()
        XCTAssertFalse(coordinator.hasPromotedPreviews)
        XCTAssertEqual(offered, [true, false], "the entry has to disappear with the last window")
    }
}
