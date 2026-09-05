import XCTest
@testable import FlowPeekCore

/// The catalogues are edited by hand and merged by hand, and a key that only reaches one of them
/// ships as its own raw identifier in that language — "menu.preview.reveal" in a menu — which no
/// build or test would otherwise notice.
final class LocalizationCatalogTests: XCTestCase {
    private static let languages = ["en", "ko"]

    func testEveryLanguageDefinesExactlyTheSameKeys() throws {
        let catalogs = try Self.languages.map { (language: $0, keys: try Self.keys(of: $0)) }
        guard let reference = catalogs.first else { return XCTFail("no catalogues to compare") }
        for catalog in catalogs.dropFirst() {
            XCTAssertEqual(
                Set(catalog.keys).subtracting(reference.keys).sorted(),
                [],
                "\(catalog.language).lproj defines keys \(reference.language).lproj does not"
            )
            XCTAssertEqual(
                Set(reference.keys).subtracting(catalog.keys).sorted(),
                [],
                "\(reference.language).lproj defines keys \(catalog.language).lproj does not"
            )
        }
    }

    /// A repeated key is a silent overwrite: the second row wins and the first translation is gone.
    func testNoLanguageDefinesTheSameKeyTwice() throws {
        for language in Self.languages {
            let keys = try Self.keys(of: language)
            let repeated = Set(keys.filter { key in keys.filter { $0 == key }.count > 1 })
            XCTAssertEqual(repeated.sorted(), [], "\(language).lproj repeats these keys")
        }
    }

    /// The ambient hint picks its keys in `FlowPeekCore`, where no catalogue is in reach and a
    /// missing translation would ship as the raw key over somebody else's window.
    func testTheAmbientHintsKeysAreDefinedInEveryLanguage() throws {
        let needed = [AmbientCandidate.Anchor.pointer, .caret]
            .flatMap { [$0.hintHelpKey, $0.hintNoteKey].compactMap { $0 } }
        for language in Self.languages {
            let keys = Set(try Self.keys(of: language))
            XCTAssertEqual(needed.filter { !keys.contains($0) }, [], "\(language).lproj is missing these")
        }
    }

    private static func keys(of language: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlowPeekCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/FlowPeek/Resources/\(language).lproj/Localizable.strings")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .compactMap { line in
                guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else { return nil }
                return String(line[line.index(after: line.startIndex)..<end])
            }
    }
}
