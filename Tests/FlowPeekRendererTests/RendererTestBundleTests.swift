import WebKit
import XCTest

/// Wiring assertions for the hosted AppKit + WebKit bundle. The engine itself is covered by
/// `MermaidEngineTests` (engine_spec §9 T1/T2/T6); these two only prove that `Bundle.main`
/// resolves to the real `.app` and that WebKit is linked, which is what those tests depend on.
final class RendererTestBundleTests: XCTestCase {
    func testTheBundleIsHostedByTheAppAndCanSeeTheVendoredEngine() {
        XCTAssertNotNil(Bundle.main.url(forResource: "mermaid", withExtension: "min.js"))
    }

    func testWebKitIsLinked() {
        XCTAssertNotNil(WKWebViewConfiguration())
    }
}
