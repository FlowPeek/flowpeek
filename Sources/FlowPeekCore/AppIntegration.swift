import Foundation

/// An application FlowPeek can teach to answer it, and the rules about when to offer that.
///
/// Some applications draw their own text and expose none of it. Measured on Sublime Text 4 build
/// 4200: the whole application tree is 1,007 elements and four of them carry any characters at all,
/// which are the tab title and the status line. The editor view is not in the tree. Sublime HQ
/// have said so themselves, repeatedly and most recently in January 2025: there is no accessibility
/// support and none planned, because the interface is a custom toolkit with no platform
/// accessibility in it. No setting turns it on, because there is nothing to turn on.
///
/// What those applications do have is an extension point of their own. Sublime ships a Python
/// plugin host whose API answers the two questions the accessibility API will not: which characters
/// are on screen, and where a range of them sits. So FlowPeek's way in is a small file placed where
/// the editor looks for plugins.
///
/// This type exists because that will not be the only one. The shape is the same every time: notice
/// the application is here, explain what would be written and why, write one file, be able to take
/// it away again.
public struct AppIntegration: Identifiable, Equatable, Sendable {
    /// Stable across releases; it is what the installed state is filed under.
    public let id: String
    /// Any of these being installed counts as the application being here. More than one because a
    /// product outlives its bundle identifier.
    public let bundleIDs: [String]
    /// The product's name, which is a name rather than a translation.
    public let displayName: String
    /// What gets written, and where, relative to the user's Library directory. Resolved by the app
    /// layer; kept here so a test can read the plan without touching a disk.
    public let installDirectory: [String]
    public let payloadName: String
    /// Bumped whenever the payload changes, so an older file can be recognised and replaced.
    public let payloadVersion: Int
    /// What FlowPeek gains, in the reader's language. A card that cannot say why is a card asking
    /// for trust it has not earned.
    public let reasonKey: String.LocalizationValue

    /// Where the two sides leave messages for each other, under FlowPeek's own support directory.
    /// Derived from the identifier rather than declared, so a plugin and the app cannot be pointed
    /// at different directories by a typo.
    public var watchDirectoryName: String { id }

    public init(
        id: String,
        bundleIDs: [String],
        displayName: String,
        installDirectory: [String],
        payloadName: String,
        payloadVersion: Int,
        reasonKey: String.LocalizationValue
    ) {
        self.id = id
        self.bundleIDs = bundleIDs
        self.displayName = displayName
        self.installDirectory = installDirectory
        self.payloadName = payloadName
        self.payloadVersion = payloadVersion
        self.reasonKey = reasonKey
    }

    /// The integrations FlowPeek knows how to write. One today; the list is the point.
    public static let known: [AppIntegration] = [.sublimeText]

    public static let sublimeText = AppIntegration(
        id: "sublime-text",
        // 4 and 3 both look here, and a build that renames itself again will be added rather than
        // guessed at.
        bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"],
        displayName: "Sublime Text",
        installDirectory: ["Application Support", "Sublime Text", "Packages", "User"],
        payloadName: "FlowPeek.py",
        // 6: frames a diagram taller than the window instead of skipping it -- it reports which
        // edge ran off, finds a fence outside the visible text, and maps coordinates through the
        // layout so the block's left edge is the block's rather than the first visible character's.
        // It also stops answering when Sublime replaces it, so an updated payload does not run
        // alongside the one it replaced, and closes a fenced block with the marker that opened it
        // rather than with whichever one the search loop left behind.
        payloadVersion: 6,
        reasonKey: "integration.sublime.reason"
    )
}

/// Where one integration stands on this Mac.
public enum AppIntegrationStatus: Equatable, Sendable {
    /// The application is not installed here. Never offered, never listed as a thing to do.
    case absent
    /// Installed, and FlowPeek has written nothing.
    case offered
    /// Installed, and carrying the current payload.
    case active
    /// Installed, and carrying a payload FlowPeek has since moved on from.
    case outdated(installed: Int)
    /// The last attempt to write or remove it did not work, and why.
    case failed(String)

    /// Whether the application is on this Mac at all.
    public var isPresent: Bool { self != .absent }

    /// Whether FlowPeek has a file in place, current or not.
    public var isInstalled: Bool {
        switch self {
        case .active, .outdated: true
        case .absent, .offered, .failed: false
        }
    }

    /// Whether there is something for the reader to do about it.
    public var wantsAttention: Bool {
        switch self {
        case .offered, .outdated, .failed: true
        case .absent, .active: false
        }
    }
}

/// When to put an integration in front of somebody, and when to leave them alone.
public enum AppIntegrationPolicy {
    /// What the wizard offers: the applications that are on this Mac and are not already set up.
    ///
    /// An application that is not installed is not an offer, it is a fact about somebody else's
    /// computer, and a card listing editors the reader does not use is the kind of setup step people
    /// learn to click past without reading.
    public static func onboardingOffers(
        _ statuses: [(id: String, status: AppIntegrationStatus)]
    ) -> [String] {
        statuses.filter { $0.status.wantsAttention }.map(\.id)
    }

    /// Whether the wizard shows the card at all. It does not exist on a Mac with none of these
    /// applications on it, which is most Macs.
    public static func showsOnboardingStep(
        _ statuses: [(id: String, status: AppIntegrationStatus)]
    ) -> Bool {
        !onboardingOffers(statuses).isEmpty
    }

    /// What the settings tab lists: everything found here, set up or not, because that tab is where
    /// somebody goes to undo a decision as well as to make one. Applications that are not installed
    /// stay out of it — the tab says what it can do for this Mac, not what it could do for another.
    public static func settingsRows(
        _ statuses: [(id: String, status: AppIntegrationStatus)]
    ) -> [String] {
        statuses.filter { $0.status.isPresent }.map(\.id)
    }

    /// Whether the tab has anything to show, which decides between a list and a sentence explaining
    /// what the tab is for.
    public static func settingsHasRows(
        _ statuses: [(id: String, status: AppIntegrationStatus)]
    ) -> Bool {
        !settingsRows(statuses).isEmpty
    }
}
