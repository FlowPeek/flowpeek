import AppKit
import FlowPeekCore
import WebKit
import XCTest

@testable import FlowPeek

/// WebKit kills the WebContent process on its own account — under memory pressure, and after the
/// lid has been closed — and it does not wait for a render to be in flight before doing it. The
/// panel used to have no way to hear about that: `markFailed` flipped the view's own state and
/// logged, the view model kept a `.rendered` status over a page that no longer existed, and the
/// preview stayed a pane of glass with chrome and no diagram until it was closed and reopened.
@MainActor
final class PreviewEngineDeathTests: XCTestCase {

    /// The termination WebKit would report. The policy object *is* the navigation delegate, so this
    /// is the same call WebKit makes, arriving at the same place.
    private func killWebContent(of view: MermaidEngineView) throws {
        let policy = try XCTUnwrap(view.webView.navigationDelegate as? MermaidWebPolicy)
        policy.webViewWebContentProcessDidTerminate(view.webView)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, _ what: String, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("never happened: \(what)") }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func isRendered(_ model: DiagramViewModel) -> Bool {
        if case .rendered = model.status { return true }
        return false
    }

    func testAnEngineThatDiesUnderAnIdlePreviewIsReplacedAndTheDiagramComesBack() async throws {
        let pool = MermaidWebViewPool()
        let model = DiagramViewModel(title: "still open", source: "flowchart TD\n  A[Start] --> B[End]", pool: pool)
        model.attach()
        await waitUntil({ self.isRendered(model) }, "the first render finished")

        let dead = try XCTUnwrap(model.engine)
        try killWebContent(of: dead)

        await waitUntil({ model.engine !== dead }, "the dead engine was replaced")
        await waitUntil({ self.isRendered(model) }, "the diagram was drawn again")
        XCTAssertFalse(try XCTUnwrap(model.engine).isPoisoned)
        model.release()
    }

    /// The failure has to be reported *after* the waiters, so a render already in flight still wins
    /// through its own path — which is the only one that can quote the user's source back at them.
    func testARenderInFlightStillReportsTheFailureItself() async throws {
        let pool = MermaidWebViewPool()
        let model = DiagramViewModel(title: "mid-render", source: "flowchart TD\n  A --> B", pool: pool)
        model.attach()
        let engine = try XCTUnwrap(model.engine)
        XCTAssertEqual(model.status, .rendering, "attach() starts a render synchronously")

        try killWebContent(of: engine)
        // Whatever the outcome, it must be a decided one: the status the defect describes is a
        // `.rendered` that never changes.
        await waitUntil({ model.status != .rendering }, "the in-flight render settled")
        model.release()
    }

    /// A view handed back to the pool must carry nothing of its last owner: a stale callback would
    /// report a later death to a view model whose surface closed minutes ago.
    func testAPooledViewCarriesNoCallbackFromItsLastOwner() async throws {
        let pool = MermaidWebViewPool()
        let model = DiagramViewModel(title: "closed", source: "flowchart TD\n  A --> B", pool: pool)
        model.attach()
        await waitUntil({ self.isRendered(model) }, "the render finished")
        let view = try XCTUnwrap(model.engine)
        model.release()

        XCTAssertNil(view.onFatal)
        XCTAssertNil(view.onViewportChange)
        // And reporting one anyway changes nothing about the closed surface.
        try killWebContent(of: view)
        XCTAssertNil(model.engine)
    }
}
