import Combine
import Foundation

/// The remembered diagrams as the app holds them: the pure list, the file behind it, and the
/// maximum the user set.
///
/// Main-actor isolated so anything that makes or changes a diagram can call `record` where it
/// already is, without an `await` and without wondering whether the list it just wrote is the one
/// the menu is about to draw. The one thing that is not done here is writing the file: encoding a
/// hundred diagrams is not work the main actor should be doing, so every save is handed to a
/// background task, and each one waits for the previous save so two of them cannot land out of
/// order and leave the older list on disk.
@MainActor
public final class DiagramHistoryStore: ObservableObject {
    public static let shared = DiagramHistoryStore()

    /// The maximum lives in the preferences domain because it is a number about diagrams, not a
    /// diagram. Nothing the user wrote is ever written here.
    public static let limitDefaultsKey = "flowpeek.history.limit"

    /// Newest first. Published, so a list drawn from it follows a recording made while it is open.
    @Published public private(set) var entries: [DiagramHistoryEntry] = []

    private var history: DiagramHistory
    private let archive: DiagramHistoryArchive?
    private let defaults: UserDefaults
    private var pendingSave: Task<Void, Never>?

    /// - Parameters:
    ///   - archive: where the list is kept. Nil is a working store with no file behind it, which is
    ///     what the app falls back to if Application Support cannot be reached at all — better a
    ///     history that lasts the session than a feature that is missing.
    public init(
        archive: DiagramHistoryArchive? = DiagramHistoryArchive.defaultURL(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ).map(DiagramHistoryArchive.init(url:)),
        defaults: UserDefaults = .standard
    ) {
        self.archive = archive
        self.defaults = defaults
        let limit = defaults.object(forKey: Self.limitDefaultsKey) as? Int ?? DiagramHistory.defaultLimit
        // Read here rather than in the background, because the first thing that touches this store
        // is a user action — opening the history, or the AI window recording a diagram — and a list
        // that fills in a moment later is a list the user has already been shown as empty. What
        // makes that safe is `DiagramHistoryArchive.maximumFileBytes`: the read is bounded by a
        // number rather than by whatever is on disk.
        let loaded = archive?.load() ?? []
        history = DiagramHistory(entries: loaded, limit: limit)
        entries = history.entries
        // A file written when the maximum was higher, or reordered by hand, is put right by the
        // initialiser above — and then written back, so the list in memory and the list on disk
        // agree from the first moment rather than from the next recording.
        if history.entries != loaded { save() }
    }

    /// How many diagrams are kept. Lowering it forgets the extra ones now, not at the next
    /// recording.
    public var limit: Int {
        get { history.limit }
        set {
            let clamped = DiagramHistory.clamp(newValue)
            guard clamped != history.limit else { return }
            // Sent by hand as well as by `entries`: a maximum raised from 20 to 40 changes nothing
            // about the list, and the control showing the number still has to redraw.
            objectWillChange.send()
            history.setLimit(clamped)
            defaults.set(clamped, forKey: Self.limitDefaultsKey)
            publish()
        }
    }

    /// Remembers a diagram that was just created or changed.
    ///
    /// Safe to call from the main actor, repeatedly, while a diagram is being worked on: a revision
    /// of the diagram at the top of the list replaces it rather than adding a row. See
    /// `DiagramHistory.record` for what counts as a revision.
    public func record(title: String, source: String, origin: DiagramOrigin) {
        guard history.record(title: title, source: source, origin: origin) != nil else { return }
        publish()
    }

    /// The same thing for a caller that already has a validated diagram in its hands.
    public func record(title: String, source: MermaidSource, origin: DiagramOrigin) {
        record(title: title, source: source.text, origin: origin)
    }

    public func remove(_ id: DiagramHistoryEntry.ID) {
        guard history.remove(id) else { return }
        publish()
    }

    public func removeAll() {
        guard !history.entries.isEmpty else { return }
        history.removeAll()
        entries = []
        // The file goes rather than being rewritten empty: a history the user cleared that is still
        // readable on disk is not cleared.
        let archive = archive
        let previous = pendingSave
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            archive?.removeFile()
        }
    }

    private func publish() {
        guard entries != history.entries else { return }
        entries = history.entries
        save()
    }

    private func save() {
        guard let archive else { return }
        let snapshot = history.entries
        // Chained rather than fired independently: two recordings a moment apart would otherwise
        // race, and the loser writing second would put the older list back on disk.
        let previous = pendingSave
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            archive.save(snapshot)
        }
    }
}
