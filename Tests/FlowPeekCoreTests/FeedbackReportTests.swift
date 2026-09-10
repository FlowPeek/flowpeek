import XCTest
@testable import FlowPeekCore

/// A report is the easiest place to break the one promise FlowPeek makes about diagrams, so what a
/// report may contain is fixed in the type and pinned here.
final class FeedbackReportTests: XCTestCase {
    private static let repository = URL(string: "https://github.com/FlowPeek/flowpeek")!

    private func report(routes: [String] = ["clipboard", "terminal"], granted: Bool = true) -> FeedbackReport {
        FeedbackReport(
            appVersion: "0.17.2",
            appBuild: "212",
            systemVersion: "26.5.1 (25F74)",
            architecture: "arm64",
            enabledRoutes: routes,
            accessibilityGranted: granted
        )
    }

    // MARK: - What it says

    func testTheDiagnosticsSayTheFourThingsWorthKnowing() {
        let text = report().diagnostics
        XCTAssertTrue(text.contains("FlowPeek 0.17.2 (212)"), text)
        XCTAssertTrue(text.contains("macOS 26.5.1 (25F74)"), text)
        XCTAssertTrue(text.contains("arm64"), text)
        XCTAssertTrue(text.contains("clipboard, terminal"), text)
        XCTAssertTrue(text.contains("Accessibility: granted"), text)
    }

    func testEverySwitchOffIsSaidPlainlyRatherThanLeftBlank() {
        let text = report(routes: [], granted: false).diagnostics
        XCTAssertTrue(text.contains("Routes on: none"), text)
        XCTAssertTrue(text.contains("Accessibility: not granted"), text)
    }

    /// The promise. A report is assembled from fixed fields, so there is no opening for a diagram,
    /// a window title or a file path to arrive in one -- and the URL is built from the same block.
    func testAReportCarriesNothingButItsOwnFields() throws {
        let text = report().diagnostics
        XCTAssertEqual(text.split(separator: "\n").count, 4, "four lines, and no room for a fifth")
        let url = try XCTUnwrap(report().githubIssueURL(repository: Self.repository, kind: .bug))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.map(\.name).sorted(), ["diagnostics", "template"])
        XCTAssertEqual(query.first { $0.name == "diagnostics" }?.value, text)
    }

    // MARK: - Where it goes

    func testTheGitHubURLOpensTheFormForWhatIsBeingReported() throws {
        for (kind, file) in [(FeedbackReport.Kind.bug, "bug.yml"), (.idea, "idea.yml")] {
            let url = try XCTUnwrap(report().githubIssueURL(repository: Self.repository, kind: kind))
            XCTAssertEqual(url.path, "/FlowPeek/flowpeek/issues/new")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "template" }?.value, file)
        }
    }

    /// The newlines and spaces in the block have to survive being a query value, or the form opens
    /// with one long line in it.
    func testTheDiagnosticsAreEncodedRatherThanFlattened() throws {
        let url = try XCTUnwrap(report().githubIssueURL(repository: Self.repository, kind: .bug))
        XCTAssertFalse(url.absoluteString.contains("\n"))
        XCTAssertTrue(url.absoluteString.contains("%0A"), "the line breaks are carried, not dropped")
        let back = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "diagnostics" }?.value
        XCTAssertEqual(back, report().diagnostics, "what the form receives is what was written")
    }

    func testTheEmailCarriesTheSameBlockUnderASeparator() throws {
        let url = try XCTUnwrap(report().mailtoURL(
            address: "someone@example.com", subject: "FlowPeek feedback", intro: "What happened:"
        ))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertEqual(url.path, "someone@example.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "subject" }?.value, "FlowPeek feedback")
        let body = try XCTUnwrap(query.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.hasPrefix("What happened:"), body)
        XCTAssertTrue(body.contains("---\nFlowPeek 0.17.2 (212)"), body)
    }

    func testNoAddressMeansNoEmailRatherThanAnEmptyOne() {
        XCTAssertNil(report().mailtoURL(address: "", subject: "s", intro: "i"))
    }

    // MARK: - When it will not fit

    /// A URL nobody can open is worse than a form filled in by hand, so an oversized report drops
    /// its diagnostics and still opens the right form.
    func testAnOversizedReportOpensTheFormWithoutTheBlock() throws {
        var huge = report()
        huge.enabledRoutes = (0..<2_000).map { "route\($0)" }
        XCTAssertGreaterThan(huge.diagnostics.count, FeedbackReport.maximumURLLength)

        let url = try XCTUnwrap(huge.githubIssueURL(repository: Self.repository, kind: .bug))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.map(\.name), ["template"])
        XCTAssertLessThanOrEqual(url.absoluteString.count, FeedbackReport.maximumURLLength)

        let mail = try XCTUnwrap(huge.mailtoURL(address: "a@b.c", subject: "s", intro: "i"))
        let mailQuery = URLComponents(url: mail, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(mailQuery.map(\.name), ["subject"], "the subject still says what it is about")
    }
}
