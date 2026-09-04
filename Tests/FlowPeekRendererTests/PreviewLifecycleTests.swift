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

    /// `isReleasedWhenClosed` is false for these windows, so a closed one stays in `NSApp.windows`
    /// for the rest of the test process; only the visible ones are on screen.
    private func previewWindows() -> [FlowPeekGlassWindow] {
        NSApp.windows.compactMap { $0 as? FlowPeekGlassWindow }.filter(\.isVisible)
    }

    private func previewWindow(titled title: String) throws -> FlowPeekGlassWindow {
        try XCTUnwrap(previewWindows().first { $0.title == title })
    }

    func testAQuickPreviewTakenWhileAWindowIsOpenStillReturnsItsEngine() throws {
        let pool = MermaidWebViewPool()
        pool.warmUp()
        let coordinator = PreviewCoordinator(pool: pool)

        coordinator.showQuick(document: try document("first"))
        coordinator.promote()
        XCTAssertEqual(previewWindows().count, 1)

        // The panel that is opened, looked at and closed while the window stays up. Its engine used
        // to be dropped on the floor, one pre-warmed view per preview.
        coordinator.showQuick(document: try document("second"))
        coordinator.closeQuick()

        previewWindows().forEach { $0.close() }
        XCTAssertEqual(pool.idleCount, 2, "both surfaces must have checked their engines back in")
        XCTAssertTrue(previewWindows().isEmpty)
    }

    /// The reported bug: the close dot on the first window closed the second one, and the first
    /// window's engine was never returned because the coordinator no longer knew about it.
    func testASecondWindowLeavesTheFirstOneAloneAndBothReleaseIndependently() throws {
        let pool = MermaidWebViewPool()
        pool.warmUp()
        let coordinator = PreviewCoordinator(pool: pool)

        coordinator.showQuick(document: try document("left"))
        coordinator.promote()
        coordinator.showQuick(document: try document("right"))
        coordinator.promote()

        XCTAssertEqual(previewWindows().count, 2)
        let left = try previewWindow(titled: "left")
        let right = try previewWindow(titled: "right")
        XCTAssertNotEqual(left.frame.origin, right.frame.origin, "a second window must not hide behind the first")

        left.close()
        XCTAssertEqual(previewWindows().map(\.title), ["right"], "closing one window must not take the other with it")
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
}
