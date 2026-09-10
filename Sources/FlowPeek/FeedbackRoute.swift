import AppKit
import FlowPeekCore

/// The two ways to report something, and the one place that knows what FlowPeek is willing to say
/// about itself.
///
/// Both ways end in `NSWorkspace.open`. FlowPeek makes no request of its own: the browser opens a
/// GitHub form with the diagnostics already in it, or the mail client opens a message with the same
/// block below the signature line, and in either case the person reporting reads the whole thing
/// and presses send. Nothing leaves the machine on FlowPeek's initiative, which is the same promise
/// the rest of the app makes and the reason this is a URL rather than an API call.
@MainActor
enum FeedbackRoute {
    /// Where issues go. The tap and the appcast already point here, so this is not a new place to
    /// trust.
    static let repository = URL(string: "https://github.com/FlowPeek/flowpeek")!

    /// Where email goes. A GitHub account is not everybody's, and a public issue is not everybody's
    /// either.
    static let emailAddress = "rationlunas@gmail.com"

    /// What FlowPeek knows about itself right now. Read from the running app rather than stored, so
    /// a report always describes the build that is actually open.
    static func report(_ app: AppState) -> FeedbackReport {
        let info = Bundle.main.infoDictionary
        var routes: [String] = []
        if app.clipboardWatchEnabled { routes.append("clipboard") }
        if app.terminalPeekEnabled { routes.append("terminal") }
        if app.ambientPeekEnabled { routes.append("pointer") }
        if app.doubleTapEnabled { routes.append("double-tap") }
        if app.aiEnabled { routes.append("ai") }
        if !app.isEnabled { routes = [] }
        return FeedbackReport(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            systemVersion: systemVersion(),
            architecture: machineArchitecture(),
            enabledRoutes: routes,
            accessibilityGranted: app.accessibilityGranted
        )
    }

    /// Opens the GitHub issue form for this kind of report.
    static func openGitHub(_ app: AppState, kind: FeedbackReport.Kind) {
        let report = report(app)
        let url = report.githubIssueURL(repository: repository, kind: kind)
            ?? repository.appendingPathComponent("issues/new")
        NSWorkspace.shared.open(url)
    }

    /// Opens a mail message with the same report in it.
    static func openEmail(_ app: AppState) {
        let report = report(app)
        guard let url = report.mailtoURL(
            address: emailAddress,
            subject: String(localized: "feedback.email.subject"),
            intro: String(localized: "feedback.email.intro")
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The diagnostics on the pasteboard, for a report typed somewhere else entirely.
    static func copyDiagnostics(_ app: AppState) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report(app).diagnostics, forType: .string)
    }

    /// `26.5.1 (25F80)`, built from the numbers rather than from
    /// `operatingSystemVersionString`.
    ///
    /// That property is localized: on a Korean system it answers `버전 26.5.1(빌드 25F80)`, so a
    /// report would arrive in whatever language the reporter runs, and two reports of the same
    /// macOS would not look alike. A test caught it.
    private static func systemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        guard let build = sysctlString("kern.osversion") else { return number }
        return "\(number) (\(build))"
    }

    /// The build identifier macOS reports for itself, which distinguishes two 26.5.1s.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// `arm64` or `x86_64`, as `uname` reports it. `ProcessInfo` will not say, and the difference
    /// is the first thing worth knowing about a Mac in a bug report.
    private static func machineArchitecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
