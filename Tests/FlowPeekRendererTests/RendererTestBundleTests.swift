import FlowPeekCore
import WebKit
import XCTest

/// Wiring assertions for the hosted AppKit + WebKit bundle. The engine itself is covered by
/// `MermaidEngineTests` (engine_spec §9 T1/T2/T6); these only prove that `Bundle.main`
/// resolves to the real `.app`, that it carries the vendored renderers, and that WebKit is
/// linked, which is what those tests depend on.
final class RendererTestBundleTests: XCTestCase {
    func testTheBundleIsHostedByTheAppAndCanSeeTheVendoredEngine() {
        XCTAssertNotNil(Bundle.main.url(forResource: "mermaid", withExtension: "min.js"))
    }

    /// Pele, resolved the same way the pool resolves it. Two things could drop it and neither
    /// shows up anywhere else in this suite: `Scripts/generate_xcodeproj.rb` not naming it, and a
    /// `peleResourceExtension` of `global.js` not matching the file on disk — `forResource:` joins
    /// the two with a dot, so a rename to `pele.js` would still compile and still ship.
    func testTheAppBundleCarriesTheVendoredPele() {
        XCTAssertNotNil(
            Bundle.main.url(
                forResource: MermaidEnginePage.peleResourceName,
                withExtension: MermaidEnginePage.peleResourceExtension
            )
        )
    }

    func testWebKitIsLinked() {
        XCTAssertNotNil(WKWebViewConfiguration())
    }
}
