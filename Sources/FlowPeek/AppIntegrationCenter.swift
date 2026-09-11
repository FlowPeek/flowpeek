import AppKit
import FlowPeekCore
import OSLog

/// Notices which of the applications FlowPeek can extend are on this Mac, and writes or removes the
/// one file each of them needs.
///
/// Everything it writes goes into the application's own support directory, never into an
/// application bundle: `~/Library/Application Support/...` is the user's, so there is no App
/// Management prompt and no Gatekeeper question, and there is nothing here that a person could not
/// have done with a text editor. Measured on Sublime Text 4: a file dropped into its `Packages/User`
/// directory was loaded in the same second, with the editor already running and nothing done in it,
/// and deleting the file put the directory back the way it was.
///
/// The one thing this deliberately does not do is act on its own. The write is a decision, so it is
/// offered rather than taken, and undoing it is a button rather than an instruction.
@MainActor
final class AppIntegrationCenter: ObservableObject {
    static let shared = AppIntegrationCenter()

    /// Where each known integration stands, in the order they are declared.
    @Published private(set) var statuses: [(id: String, status: AppIntegrationStatus)] = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Integrations")
    private let fileManager = FileManager.default
    private let library: URL

    init(library: URL? = nil) {
        self.library = library
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        refresh()
    }

    // MARK: - Reading

    func refresh() {
        statuses = AppIntegration.known.map { (id: $0.id, status: status(of: $0)) }
    }

    func integration(_ id: String) -> AppIntegration? {
        AppIntegration.known.first { $0.id == id }
    }

    func status(_ id: String) -> AppIntegrationStatus {
        statuses.first { $0.id == id }?.status ?? .absent
    }

    /// Whether anything here is worth putting in front of somebody during setup.
    var hasOffers: Bool { AppIntegrationPolicy.showsOnboardingStep(statuses) }
    /// What the settings tab lists.
    var listed: [AppIntegration] {
        AppIntegrationPolicy.settingsRows(statuses).compactMap(integration)
    }

    /// The file this integration would write, so a card can show it before anything is written.
    func destination(of integration: AppIntegration) -> URL {
        integration.installDirectory
            .reduce(library) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent(integration.payloadName)
    }

    private func status(of integration: AppIntegration) -> AppIntegrationStatus {
        guard isInstalled(integration) else { return .absent }
        let file = destination(of: integration)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .offered }
        guard let version = Self.version(in: text) else {
            // Somebody's own file under our name, or one from before the stamp existed. Treated as
            // out of date rather than overwritten without saying so.
            return .outdated(installed: 0)
        }
        return version == integration.payloadVersion ? .active : .outdated(installed: version)
    }

    /// Whether the application is on this Mac. Asked of LaunchServices rather than of a path, so a
    /// copy anywhere -- another volume, a developer's build, a renamed bundle -- still counts.
    private func isInstalled(_ integration: AppIntegration) -> Bool {
        integration.bundleIDs.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    /// The payload as it will be written, so the card can show the reader the file itself.
    func payload(of integration: AppIntegration) -> String? {
        guard let url = Bundle.main.url(forResource: Self.resourceName(of: integration), withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("the payload for \(integration.id, privacy: .public) is not in the bundle")
            return nil
        }
        return text
    }

    private static func resourceName(of integration: AppIntegration) -> String {
        switch integration.id {
        case AppIntegration.sublimeText.id: "flowpeek-sublime"
        default: "flowpeek-\(integration.id)"
        }
    }

    /// The line the version is read back from, so an installed file can say which payload it is.
    static func version(in text: String) -> Int? {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) {
            guard let range = line.range(of: "flowpeek-version:") else { continue }
            return Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: - Writing

    @discardableResult
    func install(_ integration: AppIntegration) -> Bool {
        guard let payload = payload(of: integration) else {
            statuses = statuses.map {
                $0.id == integration.id ? (id: $0.id, status: .failed("payload missing")) : $0
            }
            return false
        }
        let file = destination(of: integration)
        do {
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try payload.write(to: file, atomically: true, encoding: .utf8)
            logger.info("wrote the \(integration.id, privacy: .public) integration")
        } catch {
            logger.error("could not write \(integration.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            statuses = statuses.map {
                $0.id == integration.id ? (id: $0.id, status: .failed(error.localizedDescription)) : $0
            }
            return false
        }
        refresh()
        return true
    }

    @discardableResult
    func remove(_ integration: AppIntegration) -> Bool {
        let file = destination(of: integration)
        do {
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.removeItem(at: file)
            }
            logger.info("removed the \(integration.id, privacy: .public) integration")
        } catch {
            logger.error("could not remove \(integration.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            statuses = statuses.map {
                $0.id == integration.id ? (id: $0.id, status: .failed(error.localizedDescription)) : $0
            }
            return false
        }
        refresh()
        return true
    }

    func setInstalled(_ installed: Bool, for integration: AppIntegration) {
        _ = installed ? install(integration) : remove(integration)
    }
}
