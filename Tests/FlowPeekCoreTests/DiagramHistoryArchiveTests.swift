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
        archive.save([entry("One"), entry("Two", "C --> D")])
        let whole = try Data(contentsOf: archive.url)
        try whole.prefix(whole.count / 2).write(to: archive.url)
        XCTAssertEqual(archive.load(), [])
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
        let history = DiagramHistory(
            entries: loaded + [DiagramHistoryEntry(title: "Dated", source: "flowchart TD\n  C --> D", origin: .ai)]
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
    func testTheStoreReloadsWhatItRecorded() async throws {
        let suite = "flowpeek.history.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let archive = DiagramHistoryArchive(url: directory.appendingPathComponent("store.json"))
        let store = DiagramHistoryStore(archive: archive, defaults: defaults)
        store.record(title: "Checkout", source: "flowchart TD\n  A --> B", origin: .ai)
        XCTAssertEqual(store.entries.count, 1)

        // The save is handed to a background task on purpose, so the file appears a moment after
        // the recording rather than during it.
        var written: [DiagramHistoryEntry] = []
        for _ in 0..<200 where written.isEmpty {
            written = archive.load()
            if written.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(written.map(\.title), ["Checkout"])

        let reopened = DiagramHistoryStore(archive: archive, defaults: defaults)
        XCTAssertEqual(reopened.entries.map(\.title), ["Checkout"])
        XCTAssertEqual(reopened.limit, DiagramHistory.defaultLimit)
    }

    @MainActor
    func testClearingTheStoreTakesTheFileWithIt() async throws {
        let suite = "flowpeek.history.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let archive = DiagramHistoryArchive(url: directory.appendingPathComponent("cleared.json"))
        let store = DiagramHistoryStore(archive: archive, defaults: defaults)
        store.record(title: "Checkout", source: "flowchart TD\n  A --> B", origin: .ai)
        for _ in 0..<200 where archive.load().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
        for _ in 0..<200 where FileManager.default.fileExists(atPath: archive.url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Cleared means gone, not "rewritten as an empty list next to the one that still reads".
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path))
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
