import Combine
import Foundation

/// The remembered diagrams as the app holds them: the pure list, the file behind it, and the
/// maximum the user set.
///
/// Main-actor isolated so anything that makes or changes a diagram can call `record` where it
/// already is, without an `await` and without wondering whether the list it just wrote is the one
/// the menu is about to draw. The one thing that is not done here is writing the file: encoding a
/// hundred diagrams is not work the main actor should be doing, so every save goes to a serial
/// queue of its own -- serial so two saves a moment apart cannot land out of order and leave the
/// older list on disk, and so `flush` can wait for the queue to drain when the app is going away.
@MainActor
public final class DiagramHistoryStore: ObservableObject {
    public static let shared: DiagramHistoryStore = {
        let store = DiagramHistoryStore()
        hasOpenedShared = true
        return store
    }()

    /// Whether anything has asked for `shared` yet. Quitting is not a reason to open the file for
    /// the first time, so `flushSharedIfOpened` asks this before touching it.
    private static var hasOpenedShared = false

    /// The maximum lives in the preferences domain because it is a number about diagrams, not a
    /// diagram. Nothing the user wrote is ever written here.
    public static let limitDefaultsKey = "flowpeek.history.limit"
    /// The age lives beside the maximum, and for the same reason: it is a number about diagrams,
    /// not a diagram.
    public static let ageDefaultsKey = "flowpeek.history.age"

    /// Newest first. Published, so a list drawn from it follows a recording made while it is open.
    @Published public private(set) var entries: [DiagramHistoryEntry] = []

    private var history: DiagramHistory
    private let archive: DiagramHistoryArchive?
    /// The pictures. Separate from the list because they are read one at a time, when a card is
    /// about to be drawn, and because everything that forgets a diagram has to forget its picture:
    /// a thumbnail is the most legible thing FlowPeek writes down.
    private let thumbnails: DiagramThumbnailArchive?
    private let defaults: UserDefaults
    /// One queue, so writes happen in the order they were asked for and `flush` can wait on all of
    /// them by putting one more behind them.
    private let writes = DispatchQueue(label: "com.selenehyun.FlowPeek.diagram-history", qos: .utility)

    /// - Parameters:
    ///   - archive: where the list is kept. Nil is a working store with no file behind it, which is
    ///     what the app falls back to if Application Support cannot be reached at all — better a
    ///     history that lasts the session than a feature that is missing.
    public init(
        archive: DiagramHistoryArchive? = DiagramHistoryArchive.defaultURL(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ).map(DiagramHistoryArchive.init(url:)),
        thumbnails: DiagramThumbnailArchive? = DiagramThumbnailArchive.defaultURL(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ).map(DiagramThumbnailArchive.init(directory:)),
        defaults: UserDefaults = .standard
    ) {
        self.archive = archive
        self.thumbnails = thumbnails
        self.defaults = defaults
        let limit = defaults.object(forKey: Self.limitDefaultsKey) as? Int ?? DiagramHistory.defaultLimit
        let age = (defaults.string(forKey: Self.ageDefaultsKey)).flatMap(DiagramHistory.Age.init(rawValue:))
            ?? .forever
        // Read here rather than in the background, because the first thing that touches this store
        // is a user action — opening the history, or the AI window recording a diagram — and a list
        // that fills in a moment later is a list the user has already been shown as empty. What
        // makes that safe is `DiagramHistoryArchive.maximumFileBytes`: the read is bounded by a
        // number rather than by whatever is on disk.
        let loaded = archive?.load() ?? []
        history = DiagramHistory(entries: loaded, limit: limit, age: age)
        entries = history.entries
        // A file written when the maximum was higher, or reordered by hand, is put right by the
        // initialiser above — and then written back, so the list in memory and the list on disk
        // agree from the first moment rather than from the next recording.
        if !history.isRemembering {
            // Off, with a file from before it was switched off: emptying it is the promise, and a
            // launch is the first chance to keep it if the app was quit before the write landed.
            if !loaded.isEmpty, let archive { writes.async { archive.removeFile() } }
            if let thumbnails { writes.async { thumbnails.removeAll() } }
        } else {
            if history.entries != loaded { save() }
            // The list trims itself without knowing the picture folder exists -- a maximum lowered
            // from forty to twenty forgets twenty diagrams in one go -- so the folder is swept once
            // a launch against whatever survived.
            if let thumbnails {
                let kept = history.entries.map(\.id)
                writes.async { thumbnails.prune(keeping: kept) }
            }
        }
    }

    /// How long a diagram is kept. Shortening it forgets what is already too old now, not at the
    /// next recording.
    public var age: DiagramHistory.Age {
        get { history.age }
        set {
            guard newValue != history.age else { return }
            // Sent by hand as well as by `entries`: an age lengthened from a week to a month
            // changes nothing about the list, and the control showing it still has to redraw.
            objectWillChange.send()
            history.setAge(newValue)
            defaults.set(newValue.rawValue, forKey: Self.ageDefaultsKey)
            publish()
        }
    }

    /// Drops whatever has aged out while the app was doing nothing. Called when a surface that
    /// shows the history is about to open: time passes without recordings, and a list capped at a
    /// day is a day stale the moment nobody makes a diagram.
    public func pruneExpired() {
        guard history.pruneExpired() else { return }
        publish()
    }

    /// Whether anything is being remembered at all, for a menu that should not offer a list when
    /// the user has said not to keep one.
    public var isRemembering: Bool { history.isRemembering }

    /// How many diagrams are kept, or `DiagramHistory.off` for none. Lowering it forgets the extra
    /// ones now, not at the next recording, and switching it off deletes the file.
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
            guard clamped == DiagramHistory.off else { return publish() }
            // Switching it off is a statement about the disk, not just about the list, so the file
            // goes the same way it does for Clear History rather than being rewritten empty.
            entries = []
            if let thumbnails { writes.async { thumbnails.removeAll() } }
            guard let archive else { return }
            writes.async { archive.removeFile() }
        }
    }

    /// Remembers a diagram that was just created or changed, and answers with the row it landed in.
    ///
    /// Safe to call from the main actor as often as a diagram changes -- but a caller that keeps
    /// working on one diagram has to say so, by holding the identifier it got back and passing it as
    /// `revising` on the next recording. That is what folds an editing session into one row. A
    /// caller that does not is telling us it has a diagram, not a revision, and gets a row for each
    /// one; that way round a mistake costs a row rather than somebody's work. See
    /// `DiagramHistory.record`.
    @discardableResult
    public func record(
        title: String,
        source: String,
        origin: DiagramOrigin,
        revising identity: DiagramHistoryEntry.ID? = nil
    ) -> DiagramHistoryEntry.ID? {
        guard let entry = history.record(
            title: title,
            source: source,
            origin: origin,
            revising: identity
        ) else { return nil }
        publish()
        return entry.id
    }

    /// The same thing for a caller that already has a validated diagram in its hands.
    @discardableResult
    public func record(
        title: String,
        source: MermaidSource,
        origin: DiagramOrigin,
        revising identity: DiagramHistoryEntry.ID? = nil
    ) -> DiagramHistoryEntry.ID? {
        record(title: title, source: source.text, origin: origin, revising: identity)
    }

    public func remove(_ id: DiagramHistoryEntry.ID) {
        guard history.remove(id) else { return }
        publish()
        guard let thumbnails else { return }
        writes.async { thumbnails.remove(id) }
    }

    /// The same picture, readable from off the main actor. The shelf loads one file per card and
    /// must be on screen before its pictures are, not after; the folder is the shared thing, not
    /// this actor's state.
    public nonisolated static func thumbnailData(for id: DiagramHistoryEntry.ID) -> Data? {
        DiagramThumbnailArchive.defaultURL(bundleIdentifier: Bundle.main.bundleIdentifier)
            .map(DiagramThumbnailArchive.init(directory:))?
            .load(id)
    }

    /// The picture for a diagram, or nil when there is none: a diagram remembered before pictures
    /// existed, one whose capture failed, and one still being drawn all answer the same way, and
    /// the card that asked draws itself without a picture.
    public func thumbnail(for id: DiagramHistoryEntry.ID) -> Data? {
        thumbnails?.load(id)
    }

    /// Files the picture for a diagram that was just remembered. Written off the main actor like
    /// everything else here; a picture that lands after the shelf was drawn shows up the next time
    /// it opens, which is the right trade against blocking on a bitmap.
    public func storeThumbnail(_ data: Data, for id: DiagramHistoryEntry.ID) {
        // Not for a diagram that is no longer in the list, and not at all when the user has said
        // not to remember: a picture with no row is a picture nothing will ever delete.
        guard history.isRemembering, history.entries.contains(where: { $0.id == id }), let thumbnails else { return }
        writes.async { thumbnails.save(data, for: id) }
        // Redraw: a card that was showing a placeholder has a picture now.
        objectWillChange.send()
    }

    public func removeAll() {
        guard !history.entries.isEmpty else { return }
        history.removeAll()
        entries = []
        // The files go rather than being rewritten empty: a history the user cleared that is still
        // readable on disk is not cleared, and its pictures are the readable part.
        if let thumbnails { writes.async { thumbnails.removeAll() } }
        guard let archive else { return }
        writes.async { archive.removeFile() }
    }

    /// Waits for the file to catch up with the list. Called when the app is going away: confirming
    /// Clear History and then quitting from the menu bar two rows below it is one gesture as far as
    /// the user is concerned, and a deletion still sitting in a queue when the process exits is a
    /// history that comes back on the next launch. The same wait is what keeps the diagram recorded
    /// a moment before a quit.
    ///
    /// Bounded, and it has to be: this blocks while the app is being torn down, so a write that is
    /// somehow not finishing must not be able to hold the quit open.
    public func flush(timeout: TimeInterval = 2) {
        guard archive != nil else { return }
        let drained = DispatchSemaphore(value: 0)
        writes.async { drained.signal() }
        _ = drained.wait(timeout: .now() + timeout)
    }

    /// The same wait, for the one caller that has no reason to have opened the store yet.
    public static func flushSharedIfOpened() {
        guard hasOpenedShared else { return }
        shared.flush()
    }

    private func publish() {
        guard entries != history.entries else { return }
        let dropped = Set(entries.map(\.id)).subtracting(history.entries.map(\.id))
        entries = history.entries
        save()
        // Whatever fell off the end -- trimmed by the maximum, or folded into another row -- takes
        // its picture with it.
        guard let thumbnails, !dropped.isEmpty else { return }
        writes.async { for id in dropped { thumbnails.remove(id) } }
    }

    private func save() {
        guard let archive else { return }
        let snapshot = history.entries
        writes.async { archive.save(snapshot) }
    }
}
