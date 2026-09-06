import XCTest
@testable import FlowPeekCore

/// The file the remembered diagrams live in, and what it does when what is on disk is not what was
/// written: truncated halfway, carrying fields from a later version, or edited by hand into
/// something that is only nearly JSON. Every one of those has to produce diagrams or nothing.
final class DiagramHistoryArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowpeek-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeArchive() -> DiagramHistoryArchive {
        DiagramHistoryArchive(url: directory.appendingPathComponent("diagram-history.json"))
    }

    private func entry(_ title: String, _ nodes: String = "A --> B") -> DiagramHistoryEntry {
        DiagramHistoryEntry(
            title: title,
            source: "flowchart TD\n  \(nodes)",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .ai
        )
    }

    // MARK: - There and back

    func testWhatIsWrittenComesBack() {
        let archive = makeArchive()
        let written = [entry("One"), entry("Two", "C --> D")]
        archive.save(written)
        XCTAssertEqual(archive.load(), written)
    }

    func testAMissingFileIsAnEmptyHistoryRatherThanAFailure() {
        XCTAssertEqual(makeArchive().load(), [])
    }

    func testTheFileIsReadableOnlyByItsOwner() throws {
        let archive = makeArchive()
        archive.save([entry("One")])
        // Saved twice on purpose: an atomic write replaces the file, so a mode set once when it was
        // created would be gone by the second save.
        archive.save([entry("One"), entry("Two", "C --> D")])
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: archive.url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.int16Value & 0o077, 0)
    }

    /// The diagrams are the user's own work and the directory is ours alone. A directory that was
    /// already there -- an earlier version's, or one a restore put back -- keeps the mode it came
    /// with unless every save puts it right.
    func testTheDirectoryIsReachableOnlyByItsOwner() throws {
        let nested = directory.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let archive = DiagramHistoryArchive(url: nested.appendingPathComponent("diagram-history.json"))
        archive.save([entry("One")])
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.int16Value & 0o077, 0)
    }

    func testClearingTakesTheFileWithIt() {
        let archive = makeArchive()
        archive.save([entry("One")])
        archive.removeFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path))
        XCTAssertEqual(archive.load(), [])
    }

    // MARK: - Nonsense on disk

    func testATruncatedFileLosesTheHistoryAndNothingElse() throws {
        let archive = makeArchive()
        let written = [entry("One"), entry("Two", "C --> D")]
        archive.save(written)
        let whole = try Data(contentsOf: archive.url)
        try whole.prefix(whole.count / 2).write(to: archive.url)
        XCTAssertEqual(archive.load(), [])
        // The other half of "and nothing else": the archive is not poisoned by what it just read.
        // Whole bytes still come back as diagrams, so an empty answer means an unreadable file
        // rather than an archive that has given up.
        try whole.write(to: archive.url)
        XCTAssertEqual(archive.load(), written)
    }

    func testAnEmptyFileIsAnEmptyHistory() throws {
        let archive = makeArchive()
        try Data().write(to: archive.url)
        XCTAssertEqual(archive.load(), [])
    }

    func testSomethingThatIsNotJSONAtAllIsAnEmptyHistory() {
        XCTAssertEqual(DiagramHistoryArchive.decode(Data("not json, just words".utf8)), [])
    }

    func testAFileFromALaterVersionKeepsTheFieldsThisOneKnows() throws {
        let json = """
        {
          "version": 97,
          "generatedBy": "a version that has not been written yet",
          "entries": [
            {
              "id": "\(UUID().uuidString)",
              "title": "From the future",
              "source": "flowchart TD\\n  A --> B",
              "recordedAt": "2026-01-02T03:04:05Z",
              "origin": "ai",
              "colourScheme": "solarized"
            }
          ]
        }
        """
        let entries = DiagramHistoryArchive.decode(Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "From the future")
    }

    func testAnOriginThisVersionHasNoNameForStillLoads() {
        let json = """
        {"version": 1, "entries": [{"title": "T", "source": "flowchart TD\\n  A --> B", "origin": "telepathy"}]}
        """
        XCTAssertEqual(DiagramHistoryArchive.decode(Data(json.utf8)).first?.origin, .unknown)
    }

    func testOneMangledRowDoesNotTakeTheRestWithIt() {
        let json = """
        {
          "version": 1,
          "entries": [
            {"title": "Good", "source": "flowchart TD\\n  A --> B", "origin": "ai"},
            {"title": "No source at all", "origin": "ai"},
            {"title": "Blank", "source": "   ", "origin": "ai"},
            {"title": "Wrong shape", "source": 42, "origin": "ai"},
            {"title": "Also good", "source": "flowchart TD\\n  C --> D", "origin": "clipboard"}
          ]
        }
        """
        XCTAssertEqual(DiagramHistoryArchive.decode(Data(json.utf8)).map(\.title), ["Good", "Also good"])
    }

    func testARowWithNoDateSortsToTheBottomRatherThanTheTop() {
        let json = """
        {"version": 1, "entries": [{"title": "Undated", "source": "flowchart TD\\n  A --> B", "origin": "ai"}]}
        """
        let loaded = DiagramHistoryArchive.decode(Data(json.utf8))
        // The dated row is stamped years ago on purpose. A missing date that fell back to the moment
        // of reading would beat any real date in the file, and the undated row would be at the top
        // of the list on every launch -- which is the thing this is about, so it must not be able to
        // pass just because the dated row happens to be built second.
        let history = DiagramHistory(
            entries: loaded + [
                DiagramHistoryEntry(
                    title: "Dated",
                    source: "flowchart TD\n  C --> D",
                    recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    origin: .ai
                )
            ]
        )
        XCTAssertEqual(history.entries.map(\.title), ["Dated", "Undated"])
    }

    func testABareArrayIsStillReadable() {
        let json = """
        [{"title": "Loose", "source": "flowchart TD\\n  A --> B", "origin": "ai"}]
        """
        XCTAssertEqual(DiagramHistoryArchive.decode(Data(json.utf8)).map(\.title), ["Loose"])
    }

    /// Perfectly good JSON, just far too much of it. The size has to decide before anything is
    /// parsed, or the bound on the read at first use is whatever somebody put in the file.
    func testAFileTooLargeToBeAHistoryIsNotParsedEvenWhenItIsValid() throws {
        let archive = makeArchive()
        let padding = String(repeating: "a", count: DiagramHistoryArchive.maximumFileBytes)
        let json = """
        {"version": 1, "note": "\(padding)", \
        "entries": [{"title": "Buried", "source": "flowchart TD\\n  A --> B", "origin": "ai"}]}
        """
        let data = Data(json.utf8)
        XCTAssertGreaterThan(data.count, DiagramHistoryArchive.maximumFileBytes)
        try data.write(to: archive.url)
        XCTAssertEqual(archive.load(), [])
        XCTAssertEqual(DiagramHistoryArchive.decode(data), [])
    }

    // MARK: - The store on top of it

    @MainActor
    func testTheStoreReloadsWhatItRecorded() throws {
        let suite = "flowpeek.history.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let archive = DiagramHistoryArchive(url: directory.appendingPathComponent("store.json"))
        let store = DiagramHistoryStore(archive: archive, defaults: defaults)
        store.record(title: "Checkout", source: "flowchart TD\n  A --> B", origin: .ai)
        XCTAssertEqual(store.entries.count, 1)

        // The save is not done on the main actor, so this is the same wait the app makes on its way
        // out. Waiting for it rather than polling is what makes "recorded, then quit" a promise.
        store.flush()
        XCTAssertEqual(archive.load().map(\.title), ["Checkout"])

        let reopened = DiagramHistoryStore(archive: archive, defaults: defaults)
        XCTAssertEqual(reopened.entries.map(\.title), ["Checkout"])
        XCTAssertEqual(reopened.limit, DiagramHistory.defaultLimit)
    }

    /// Quitting straight after clearing is the ordinary way this is done: the history window is
    /// open, Clear History is confirmed, and Quit is two rows down the same menu. The file has to be
    /// gone by the time the process is.
    @MainActor
    func testClearingTheStoreTakesTheFileWithItBeforeAQuitCanLand() throws {
        let suite = "flowpeek.history.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let archive = DiagramHistoryArchive(url: directory.appendingPathComponent("cleared.json"))
        let store = DiagramHistoryStore(archive: archive, defaults: defaults)
        store.record(title: "Checkout", source: "flowchart TD\n  A --> B", origin: .ai)
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.url.path))

        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
        store.flush()
        // Cleared means gone, not "rewritten as an empty list next to the one that still reads".
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path))
        XCTAssertEqual(DiagramHistoryStore(archive: archive, defaults: defaults).entries, [])
    }

    /// Two recordings a moment apart go to the same queue in the order they were made, so the file
    /// left behind is the later list rather than whichever write happened to finish last.
    @MainActor
    func testTheFileEndsUpHoldingTheLaterOfTwoQuickRecordings() throws {
        let suite = "flowpeek.history.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let archive = DiagramHistoryArchive(url: directory.appendingPathComponent("ordered.json"))
        let store = DiagramHistoryStore(archive: archive, defaults: defaults)
        store.record(title: "First", source: "flowchart TD\n  A --> B", origin: .ai)
        store.record(title: "Second", source: "flowchart TD\n  C --> D", origin: .ai)
        store.flush()
        XCTAssertEqual(archive.load().map(\.title), ["Second", "First"])
    }

    @MainActor
    func testTheStoreRemembersTheMaximumAndAppliesItAtOnce() throws {
        let suite = "flowpeek.history.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DiagramHistoryStore(archive: nil, defaults: defaults)
        for index in 0..<10 {
            store.record(title: "D\(index)", source: "flowchart TD\n  N\(index) --> M\(index)", origin: .clipboard)
        }
        XCTAssertEqual(store.entries.count, 10)
        store.limit = 5
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(defaults.integer(forKey: DiagramHistoryStore.limitDefaultsKey), 5)

        let reopened = DiagramHistoryStore(archive: nil, defaults: defaults)
        XCTAssertEqual(reopened.limit, 5)
    }
}
