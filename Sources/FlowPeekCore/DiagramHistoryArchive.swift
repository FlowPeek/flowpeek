import Foundation

/// Where the remembered diagrams live between launches, and everything that can go wrong with the
/// file they live in.
///
/// Not `UserDefaults`. What is kept here is the user's own work, and the preferences domain is read
/// by anything that can read preferences — `defaults read`, a backup agent, a support script
/// someone pastes into a terminal — and cached in memory by the framework for as long as the
/// process lives. A file of our own can be given its own permissions, replaced atomically, and
/// deleted by the user when they want their diagrams gone.
///
/// Every read is total: a truncated file, a file from a version that knows fields this one does
/// not, and a file somebody edited by hand all produce entries or nothing, never a throw and never
/// a crash. Nothing that is read or written is ever logged.
public struct DiagramHistoryArchive: Sendable {
    /// What `save` stamps into the file. Read back only to be tolerated: a newer file is decoded
    /// field by field like any other rather than rejected, because the fields we know are the ones
    /// we need and refusing the file would lose diagrams over a number.
    public static let currentVersion = 1

    /// The largest file we are willing to parse. `DiagramHistory.limitRange.upperBound` entries at
    /// `MermaidSource.maximumCharacters` each is the honest worst case; this is that, rounded, and
    /// it is what keeps the load at first use bounded rather than open-ended.
    public static let maximumFileBytes = 24 * 1024 * 1024

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/<bundle id>/diagram-history.json`, made if it is not there.
    /// Nil when the directory cannot be reached at all, which leaves the store working in memory
    /// for the session rather than failing.
    public static func defaultURL(bundleIdentifier: String?) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support
            .appendingPathComponent(bundleIdentifier ?? "FlowPeek", isDirectory: true)
            .appendingPathComponent("diagram-history.json")
    }

    // MARK: - Reading

    public func load() -> [DiagramHistoryEntry] {
        // Read with the size checked first: `Data(contentsOf:)` would map whatever is there, and
        // the cap exists precisely so a file somebody replaced with a disk image is not parsed.
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: url)
        else { return [] }
        return Self.decode(data)
    }

    /// Reads whatever survives. Never throws: there is no caller that could do anything useful with
    /// the reason, and the answer to every reason is the same — start with what could be read.
    public static func decode(_ data: Data) -> [DiagramHistoryEntry] {
        guard !data.isEmpty, data.count <= maximumFileBytes else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(Archived.self, from: data) {
            return file.entries.filter(\.isUsable)
        }
        // A bare array is what a hand-edit tends to leave behind, and what a version before the
        // envelope would have written.
        if let entries = try? decoder.decode([Tolerated<DiagramHistoryEntry>].self, from: data) {
            return entries.compactMap(\.value).filter(\.isUsable)
        }
        return []
    }

    // MARK: - Writing

    public static func encode(_ entries: [DiagramHistoryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys and pretty printing cost nothing at this size and make the file something a
        // person can open, read and delete a row out of — which they are entitled to do with their
        // own diagrams.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Archived(version: currentVersion, entries: entries))
    }

    /// Replaces the file, or leaves the previous one alone. Called off the main actor.
    ///
    /// Failures are swallowed on purpose: the only thing that could be said about one is *what*
    /// failed to save, and that is the user's diagram. Losing a save is recoverable — the next
    /// recording writes the whole list again — and saying so is not worth a line in a log that
    /// names their work.
    public func save(_ entries: [DiagramHistoryEntry]) {
        guard let data = try? Self.encode(entries) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard (try? data.write(to: url, options: [.atomic])) != nil else { return }
        // An atomic write is a fresh file with the process umask on it, so the mode has to be put
        // back after every save rather than once when the file is made.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Forgetting everything means the file goes too. A history the user cleared that is still on
    /// disk is not cleared.
    public func removeFile() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - The file's shape

    private struct Archived: Codable {
        let version: Int?
        let entries: [DiagramHistoryEntry]

        init(version: Int, entries: [DiagramHistoryEntry]) {
            self.version = version
            self.entries = entries
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? container.decodeIfPresent(Int.self, forKey: .version)).flatMap { $0 }
            let rows = (try? container.decodeIfPresent([Tolerated<DiagramHistoryEntry>].self, forKey: .entries))
                .flatMap { $0 } ?? []
            entries = rows.compactMap(\.value)
        }
    }

    /// One bad row is one bad row. Decoding an array element through this keeps a truncated or
    /// hand-mangled entry from taking every diagram after it down with it — the element decoder is
    /// scoped to that element, so a failure inside it leaves the array's own cursor where it was.
    private struct Tolerated<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
