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

    /// Providers FlowPeek did not write: somebody else's application or plugin that registered
    /// itself by writing a manifest, exactly as `docs/INTEGRATIONS.md` invites it to.
    ///
    /// Listed because they are watched. A published contract means a provider can appear without the
    /// reader agreeing to anything, so the one place that could show them has to, and the switch
    /// beside each is the reader's answer.
    @Published private(set) var others: [IntegrationWatch.Manifest] = []

    /// Fired whenever an integration is written or taken away, so the routes that depend on one can
    /// be re-armed without waiting for a relaunch.
    var onChange: (() -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Integrations")
    private let fileManager = FileManager.default
    private let library: URL
    private let registry: IntegrationRegistry

    init(library: URL? = nil, registry: IntegrationRegistry = IntegrationRegistry()) {
        self.library = library
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        self.registry = registry
        refresh()
    }

    // MARK: - Reading

    func refresh() {
        statuses = AppIntegration.known.map { (id: $0.id, status: status(of: $0)) }
        // Anything registered that FlowPeek is not itself responsible for. Read from the disk every
        // time: an editor installed since launch, or a provider that appeared five seconds ago,
        // should be in this list the moment somebody looks at it.
        let ours = Set(AppIntegration.known.map(\.id))
        others = registry.manifests().filter { !ours.contains($0.id) }
    }

    /// Whether FlowPeek asks this provider anything. Off means the file stays where its owner put
    /// it and is never spoken to; FlowPeek does not delete other people's plugins.
    func isWatched(_ manifest: IntegrationWatch.Manifest) -> Bool {
        !registry.muted.contains(manifest.id)
    }

    func setWatched(_ watched: Bool, for manifest: IntegrationWatch.Manifest) {
        registry.setWatched(watched, id: manifest.id)
        refreshAndAnnounce()
    }

    /// Where a provider's three files live, so the row can show the reader the directory before
    /// they decide anything about it.
    func directory(of manifest: IntegrationWatch.Manifest) -> URL {
        registry.directory(of: manifest.id)
    }

    /// Re-reads, then tells whoever is listening. Separate from `refresh` so the read that happens
    /// at launch does not re-arm anything that is still being built.
    private func refreshAndAnnounce() {
        refresh()
        onChange?()
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

    /// Where this integration registers itself, which is the same published directory a third
    /// party would use: FlowPeek installing a provider and somebody else shipping one are the same
    /// act, and the watch cannot tell them apart.
    private var providersRoot: URL { registry.root }

    private func manifestFile(of integration: AppIntegration) -> URL {
        providersRoot
            .appendingPathComponent(integration.id, isDirectory: true)
            .appendingPathComponent(IntegrationWatch.manifestName)
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
            // Removed first, then written. Overwriting in place is not enough: measured on
            // Sublime, a payload replaced under a running editor kept answering from the module it
            // had already loaded, and only a file that went away and came back was picked up. An
            // update that does not take is worse than one that fails, because nothing says so.
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.removeItem(at: file)
            }
            try payload.write(to: file, atomically: true, encoding: .utf8)
            // The manifest is the registration. Written after the plugin, so a provider is never
            // announced before the thing that answers for it exists.
            let manifest = IntegrationWatch.Manifest(
                id: integration.id,
                name: integration.displayName,
                bundleIdentifiers: integration.bundleIDs
            )
            let manifestFile = manifestFile(of: integration)
            try fileManager.createDirectory(
                at: manifestFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestFile, options: .atomic)
            logger.info("wrote the \(integration.id, privacy: .public) integration")
        } catch {
            logger.error("could not write \(integration.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            statuses = statuses.map {
                $0.id == integration.id ? (id: $0.id, status: .failed(error.localizedDescription)) : $0
            }
            return false
        }
        refreshAndAnnounce()
        return true
    }

    /// Brings a plugin FlowPeek already wrote up to the payload this build speaks.
    ///
    /// The consent being honoured is the one given when the switch was turned on: an integration
    /// left at an older payload answers a protocol this build has moved past, and the reader who
    /// said yes to the feature did not say yes to it quietly rotting. A file with no version stamp
    /// is somebody else's under our name and is never overwritten -- that one stays a decision.
    func updateInstalled() {
        for entry in statuses {
            guard case .outdated(let installed) = entry.status, installed > 0,
                  let integration = integration(entry.id) else { continue }
            logger.info("updating \(integration.id, privacy: .public) from payload \(installed, privacy: .public)")
            install(integration)
        }
    }

    @discardableResult
    func remove(_ integration: AppIntegration) -> Bool {
        let file = destination(of: integration)
        do {
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.removeItem(at: file)
            }
            // And the registration, so the watch stops looking for an answer nothing will write.
            let directory = manifestFile(of: integration).deletingLastPathComponent()
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            logger.info("removed the \(integration.id, privacy: .public) integration")
        } catch {
            logger.error("could not remove \(integration.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            statuses = statuses.map {
                $0.id == integration.id ? (id: $0.id, status: .failed(error.localizedDescription)) : $0
            }
            return false
        }
        refreshAndAnnounce()
        return true
    }

    func setInstalled(_ installed: Bool, for integration: AppIntegration) {
        _ = installed ? install(integration) : remove(integration)
    }
}
