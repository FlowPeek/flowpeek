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
        let needed = AmbientCandidate.Anchor.allCases
            .flatMap { [$0.hintHelpKey, $0.hintNoteKey].compactMap { $0 } }
        for language in Self.languages {
            let keys = Set(try Self.keys(of: language))
            XCTAssertEqual(needed.filter { !keys.contains($0) }, [], "\(language).lproj is missing these")
        }
    }

    /// The AI window's failure copy is picked in `FlowPeekCore` too, and a missing translation there
    /// would ship as the raw key in place of the sentence that says what to do next.
    func testTheAIFailureKeysAreDefinedInEveryLanguage() throws {
        for language in Self.languages {
            let keys = Set(try Self.keys(of: language))
            XCTAssertEqual(
                AIFailurePresentation.localizationKeys.filter { !keys.contains($0) },
                [],
                "\(language).lproj is missing these"
            )
        }
    }

    /// The label under a remembered diagram is chosen in `FlowPeekCore` from the origin stored with
    /// it, so a missing translation there would ship as the raw key under every row in the list.
    func testTheDiagramOriginKeysAreDefinedInEveryLanguage() throws {
        for language in Self.languages {
            let keys = Set(try Self.keys(of: language))
            XCTAssertEqual(
                DiagramOrigin.localizationKeys.filter { !keys.contains($0) },
                [],
                "\(language).lproj is missing these"
            )
        }
    }

    /// The feedback rows and their two destinations. Named in Swift rather than only in a view,
    /// so a missing translation would ship as `menu.report` in somebody's menu bar.
    func testTheFeedbackKeysAreDefinedInEveryLanguage() throws {
        let needed = [
            "menu.report", "menu.feedback.email",
            "feedback.email.subject", "feedback.email.intro",
            "settings.feedback.title", "settings.feedback.note",
            "settings.feedback.github", "settings.feedback.idea",
            "settings.feedback.email", "settings.feedback.copy",
        ]
        for language in Self.languages {
            let keys = Set(try Self.keys(of: language))
            XCTAssertEqual(needed.filter { !keys.contains($0) }, [], "\(language).lproj is missing these")
        }
    }

    /// The app pre-fills the issue form by field id, and GitHub ignores a parameter that names no
    /// field: rename the textarea and the pre-filling stops working with nothing to notice it. The
    /// forms are checked in, so the invariant can be checked here.
    func testEveryIssueFormCarriesTheFieldTheAppPreFills() throws {
        let templates = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/ISSUE_TEMPLATE")
        for kind in FeedbackReport.Kind.allCases {
            let form = templates.appendingPathComponent(kind.template)
            let text = try String(contentsOf: form, encoding: .utf8)
            XCTAssertTrue(text.contains("id: diagnostics"),
                          "\(kind.template) has no field for the block the app fills in")
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
