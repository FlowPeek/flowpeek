import Foundation
import FlowPeekCore
import OSLog

/// Everything that has registered itself as an integration provider, and which of them FlowPeek is
/// allowed to speak to.
///
/// One reader for the directory rather than two. The watch needs to know who to ask, the settings
/// tab needs to know who to list, and those have to be the same answer: a provider the tab does not
/// show but the watch still asks is a file being written into somebody's editor with nothing on
/// screen that says so.
///
/// Reading is deliberately cheap and deliberately repeated. A provider can appear at any moment --
/// that is what a published contract means -- so nothing here is cached across calls.
struct IntegrationRegistry {
    /// Where providers register. The published path; see `docs/INTEGRATIONS.md`.
    static func defaultRoot() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("FlowPeek", isDirectory: true)
            .appendingPathComponent(IntegrationWatch.directoryName, isDirectory: true)
    }

    let root: URL
    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Integrations")

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? Self.defaultRoot()
        self.defaults = defaults
    }

    func directory(of id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// Every manifest under the providers directory that can be acted on.
    func manifests() -> [IntegrationWatch.Manifest] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var found: [IntegrationWatch.Manifest] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifest = entry.appendingPathComponent(IntegrationWatch.manifestName)
            guard let data = try? Data(contentsOf: manifest),
                  let decoded = try? JSONDecoder().decode(IntegrationWatch.Manifest.self, from: data) else {
                continue
            }
            guard decoded.isUsable else {
                logger.debug("a provider manifest was ignored: \(entry.lastPathComponent, privacy: .public)")
                continue
            }
            // The directory is what it is found by, so a manifest claiming another name would be
            // asking FlowPeek to look somewhere it is not.
            guard decoded.id == entry.lastPathComponent else {
                logger.debug("a provider manifest names an id its directory does not")
                continue
            }
            found.append(decoded)
        }
        return found
    }

    /// The ones to ask: registered, and not switched off in settings.
    func watched() -> [IntegrationWatch.Manifest] {
        IntegrationWatch.watched(manifests(), muted: muted)
    }

    var muted: Set<String> {
        Set(defaults.stringArray(forKey: IntegrationWatch.mutedDefaultsKey) ?? [])
    }

    func setWatched(_ watched: Bool, id: String) {
        let next = IntegrationWatch.muting(id, in: muted, watched: watched)
        defaults.set(Array(next).sorted(), forKey: IntegrationWatch.mutedDefaultsKey)
    }
}
