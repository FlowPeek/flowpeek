import XCTest
@testable import FlowPeekCore

/// The Swift half of engine_spec §9 T4(c). `Scripts/conformance.mjs` drives the *same*
/// `Tests/Fixtures/detector_corpus.json` through the vendored bundle's own `detectType()`;
/// this drives it through `MermaidDetector`'s hand-maintained table. One file, so a re-vendored
/// mermaid whose per-detector regexes drifted fails on one side or the other, never silently.
final class MermaidDetectorCorpusTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let expected: String?
            let source: String
        }

        let cases: [Case]
    }

    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FlowPeekCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/detector_corpus.json")

    private func corpus() throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: try Data(contentsOf: Self.url))
    }

    func testTheSharedCorpusCoversEveryRowOfTheDetectorTable() throws {
        let covered = Set(try corpus().cases.compactMap(\.expected))
        let missing = MermaidDetector.tableIdentifiers.filter { !covered.contains($0) }
        XCTAssertEqual(missing, [], "detector table rows with no corpus row: \(missing)")
    }

    func testEveryCorpusRowResolvesToTheDetectorIdMermaidItselfReports() throws {
        var failures: [String] = []
        for row in try corpus().cases {
            let detected = MermaidDetector.detect(row.source).expectedType
            if detected != row.expected {
                failures.append("\(row.id): table \(detected ?? "none") vs corpus \(row.expected ?? "none")")
            }
        }
        XCTAssertEqual(failures, [], "corpus drift:\n" + failures.joined(separator: "\n"))
    }
}
