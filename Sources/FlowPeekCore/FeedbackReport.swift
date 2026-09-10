import Foundation

/// What FlowPeek says about itself when someone reports a problem, and where that report goes.
///
/// Nothing is sent by the app. The report is assembled here, put into a URL, and handed to the
/// browser or the mail client, where the person reporting reads it and presses send. That is the
/// whole mechanism: no endpoint of ours, no account with us, nothing to trust us about, and the
/// text is in front of the sender before it goes anywhere.
///
/// What it is allowed to contain is the point of this type. A diagram is the one thing FlowPeek
/// promises never to write down, and a report is exactly where that promise is easiest to break by
/// accident, so the fields are fixed here rather than assembled at the call site: a version, an
/// operating system, an architecture, which of the routes are switched on, and whether the
/// permission was granted. No source, no titles, no application names, no file paths.
public struct FeedbackReport: Equatable, Sendable {
    /// What is being reported, which picks the issue form and the labels on the other side.
    public enum Kind: String, Sendable, CaseIterable {
        case bug
        case idea

        /// The issue form to open. Named files rather than a guess: GitHub matches the file name
        /// in `.github/ISSUE_TEMPLATE`, and a name that does not exist opens the chooser instead,
        /// which is a worse but not broken outcome.
        public var template: String {
            switch self {
            case .bug: "bug.yml"
            case .idea: "idea.yml"
            }
        }
    }

    public var appVersion: String
    public var appBuild: String
    public var systemVersion: String
    public var architecture: String
    /// The routes that are switched on, already named in a way a stranger can read.
    public var enabledRoutes: [String]
    public var accessibilityGranted: Bool

    public init(
        appVersion: String,
        appBuild: String,
        systemVersion: String,
        architecture: String,
        enabledRoutes: [String],
        accessibilityGranted: Bool
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.systemVersion = systemVersion
        self.architecture = architecture
        self.enabledRoutes = enabledRoutes
        self.accessibilityGranted = accessibilityGranted
    }

    /// The block that goes into the report, in the order a reader wants it.
    public var diagnostics: String {
        """
        FlowPeek \(appVersion) (\(appBuild))
        macOS \(systemVersion) on \(architecture)
        Routes on: \(enabledRoutes.isEmpty ? "none" : enabledRoutes.joined(separator: ", "))
        Accessibility: \(accessibilityGranted ? "granted" : "not granted")
        """
    }

    /// How long a report may be before the diagnostics are dropped from the URL.
    ///
    /// A `mailto:` or a GitHub form URL goes through the browser and through the mail client, and
    /// both have limits nobody documents. This is comfortably under the shortest of them, and the
    /// block above is a fifth of it; the cap exists so a future field cannot quietly produce a URL
    /// that opens an empty form.
    public static let maximumURLLength = 6_000

    /// The GitHub issue form, with the diagnostics already filled in.
    ///
    /// Query parameters name the fields of the form by id, so `diagnostics` here is the `id:` of
    /// the textarea in `.github/ISSUE_TEMPLATE`. A field that no longer exists is ignored by
    /// GitHub rather than refused, so a renamed field costs the pre-filling and nothing else.
    public func githubIssueURL(repository: URL, kind: Kind) -> URL? {
        guard var components = URLComponents(
            url: repository.appendingPathComponent("issues/new"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "template", value: kind.template),
            URLQueryItem(name: "diagnostics", value: diagnostics),
        ]
        guard let url = components.url else { return nil }
        guard url.absoluteString.count <= Self.maximumURLLength else {
            // Better a form the person fills in by hand than a URL the browser truncates.
            components.queryItems = [URLQueryItem(name: "template", value: kind.template)]
            return components.url
        }
        return url
    }

    /// The same report as an email, for anyone without a GitHub account or without the wish to
    /// post in public.
    public func mailtoURL(address: String, subject: String, intro: String) -> URL? {
        guard !address.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        let body = "\(intro)\n\n\n---\n\(diagnostics)\n"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url, url.absoluteString.count <= Self.maximumURLLength else {
            // Subject only. The diagnostics are still one press away from the same menu.
            var short = URLComponents()
            short.scheme = "mailto"
            short.path = address
            short.queryItems = [URLQueryItem(name: "subject", value: subject)]
            return short.url
        }
        return url
    }
}
