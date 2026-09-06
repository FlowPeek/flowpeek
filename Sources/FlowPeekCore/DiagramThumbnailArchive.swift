import Foundation

/// The pictures behind the history: one small PNG per remembered diagram, in a folder beside the
/// list itself.
///
/// A folder of files rather than bitmaps inside the JSON. The list is read on the main actor at the
/// first touch and its size is what makes that safe; a hundred base64 images inside it would not
/// be. Kept as files, a picture is read only when it is about to be shown, and a picture that never
/// arrived is a missing file rather than a corrupt list.
///
/// These are the most legible thing FlowPeek writes down -- a diagram is recognisable from its
/// thumbnail at a glance, in a way its source is not -- so everything that forgets a diagram has to
/// take its picture with it. That is what `remove`, `removeAll` and `prune` are for, and they are
/// called from the same three places the list is: a row deleted, the history cleared, and the
/// remembering switched off.
public struct DiagramThumbnailArchive: Sendable {
    /// The widest a thumbnail is written. Enough for a shelf card on a Retina display, small enough
    /// that a hundred of them are a few megabytes rather than a few hundred.
    public static let maximumWidth: CGFloat = 480
    /// A single file bigger than this is not one of ours. Read with the size checked first, the
    /// same way the list is.
    public static let maximumFileBytes = 4 * 1024 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<bundle id>/thumbnails/`. Nil when Application Support cannot
    /// be reached, which leaves the shelf drawing cards with no picture rather than failing.
    public static func defaultURL(bundleIdentifier: String?) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support
            .appendingPathComponent(bundleIdentifier ?? "FlowPeek", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
    }

    public func url(for id: DiagramHistoryEntry.ID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }

    /// The picture for a diagram, or nil when there is none yet -- which is the ordinary state for
    /// a diagram remembered before this version, and for one whose picture is still being drawn.
    public func load(_ id: DiagramHistoryEntry.ID) -> Data? {
        let url = url(for: id)
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return data
    }

    public func save(_ data: Data, for id: DiagramHistoryEntry.ID) {
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Set again rather than hoped for: a directory that already exists keeps whatever mode it
        // came with. The same reasoning as `DiagramHistoryArchive.save`.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = url(for: id)
        guard (try? data.write(to: url, options: [.atomic])) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove(_ id: DiagramHistoryEntry.ID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// The whole folder, for Clear History and for the remembering being switched off.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Deletes the pictures of diagrams that are no longer in the list.
    ///
    /// The list trims itself -- a maximum lowered from forty to twenty forgets twenty diagrams at
    /// once -- and it does so without knowing this folder exists. Without a sweep, the pictures of
    /// every diagram the user ever made would stay on disk forever while the list they belong to
    /// held twenty rows.
    public func prune(keeping ids: some Sequence<DiagramHistoryEntry.ID>) {
        let kept = Set(ids.map { $0.uuidString + ".png" })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".png") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
