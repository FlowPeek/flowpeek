import AppKit
import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The half a pure test cannot reach: what the running app actually puts in a report. Nothing here
/// opens a browser or a mail client; the URLs those receive are `FeedbackReport`'s and are tested
/// against fixed values there.
@MainActor
final class FeedbackRouteTests: XCTestCase {
    func testTheReportDescribesTheBuildThatIsRunning() {
        let report = FeedbackRoute.report(AppState.shared)
        XCTAssertEqual(report.appVersion, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertFalse(report.appVersion.isEmpty)
        // Numbers, not `operatingSystemVersionString`: that one is localized, and a report has to
        // read the same whatever language the reporter runs in.
        XCTAssertNotNil(report.systemVersion.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression),
                        report.systemVersion)
        XCTAssertFalse(report.systemVersion.contains("버전"), report.systemVersion)
        XCTAssertTrue(["arm64", "x86_64"].contains(report.architecture), report.architecture)
    }

    /// The routes are named for a stranger reading an issue, so the vocabulary is fixed rather than
    /// whatever a property happens to be called.
    func testOnlyKnownRouteNamesCanAppear() {
        let known: Set<String> = ["clipboard", "terminal", "pointer", "double-tap", "ai"]
        let report = FeedbackRoute.report(AppState.shared)
        XCTAssertEqual(Set(report.enabledRoutes).subtracting(known), [])
    }

    /// Switching FlowPeek off is a fact worth reporting, and it is reported as no routes rather
    /// than as whatever the individual switches happen to say underneath.
    func testAPausedAppReportsNoRoutes() {
        let app = AppState.shared
        let wasEnabled = app.isEnabled
        defer { app.isEnabled = wasEnabled }
        app.isEnabled = false
        XCTAssertEqual(FeedbackRoute.report(app).enabledRoutes, [])
    }

    /// The whole point of the type: a report is four lines about the app and nothing about the
    /// user's work. This is the one that has to keep passing as fields are added.
    func testAReportSaysNothingAboutAnyDiagram() {
        let text = FeedbackRoute.report(AppState.shared).diagnostics
        XCTAssertEqual(text.split(separator: "\n").count, 4)
        for word in ["graph", "flowchart", "sequenceDiagram", "-->"] {
            XCTAssertFalse(text.contains(word), "a report should never carry diagram syntax")
        }
    }
}
