import XCTest
@testable import FlowPeekCore

/// Checks the two string catalogues against each other, on the things that are wrong in a way
/// nothing else notices.
///
/// This exists because a shipped release showed Korean readers `uC5D0uB514uD130uAC00` where the
/// title of a setting should have been. `.strings` recognises `\U` and not `\u`, so the lowercase
/// form is not an escape at all: the parser drops the backslash, keeps the rest as text, and the
/// file stays perfectly valid. `plutil -lint` passed it, the keys matched their English
/// counterparts, the app built, and four settings were unreadable for every Korean user until
/// somebody looked at the screen.
///
/// So the checks here are about the *values*, which is where that class of fault lives.
final class LocalizationCatalogueTests: XCTestCase {
    private static let languages = ["en", "ko"]

    /// The catalogues, found by walking up from this file rather than through a bundle: they are
    /// resources of the app target, which this test target does not link.
    private static func catalogueURL(_ language: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
            .appendingPathComponent("Sources/FlowPeek/Resources/\(language).lproj/Localizable.strings")
    }

    private func catalogue(_ language: String) throws -> [String: String] {
        let url = Self.catalogueURL(language)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: String], "\(language) is not a string table")
    }

    private func rawText(_ language: String) throws -> String {
        try String(contentsOf: Self.catalogueURL(language), encoding: .utf8)
    }

    func testEveryCatalogueParses() throws {
        for language in Self.languages {
            XCTAssertFalse(try catalogue(language).isEmpty, "\(language) parsed to nothing")
        }
    }

    func testTheSameKeysAreInEveryCatalogue() throws {
        let english = Set(try catalogue("en").keys)
        for language in Self.languages.dropFirst() {
            let other = Set(try catalogue(language).keys)
            XCTAssertEqual(english.subtracting(other), [], "missing from \(language)")
            XCTAssertEqual(other.subtracting(english), [], "in \(language) but not en")
        }
    }

    /// The one that shipped. `\uXXXX` is not an escape in this format and leaves its own text on
    /// screen; `\UXXXX` is.
    func testNoValueCarriesAnEscapeThisFormatDoesNotUnderstand() throws {
        for language in Self.languages {
            let text = try rawText(language)
            let matches = text.ranges(of: try Regex(#"\\u[0-9A-Fa-f]{4}"#))
            XCTAssertTrue(
                matches.isEmpty,
                "\(language) uses \\u, which .strings does not decode -- write \\U or the character"
            )
        }
    }

    /// A value that reached a reader still holding an escape sequence never decoded, whatever the
    /// cause. Catches the same fault from the other side, and any future spelling of it.
    ///
    /// The run is matched whole rather than one escape at a time. These arrive back to back --
    /// `uC5D0uB514uD130uAC00` -- so a pattern that demanded a word boundary after each one matched
    /// none of them, and this test passed the very file it was written for until that was fixed.
    ///
    /// `NSRegularExpression` rather than `Regex`, which does not support the lookbehind. That is
    /// worth its own sentence: the first version of this test built the pattern with `try? Regex`
    /// inside `XCTAssertNil`, so the unsupported-syntax error became a nil and the assertion passed
    /// on every input there has ever been. A guard that cannot fail is worse than no guard, because
    /// it is counted.
    func testNoValueLooksLikeAnUndecodedEscape() throws {
        let undecoded = try NSRegularExpression(pattern: #"(?<![0-9A-Za-z])(?:[uU][0-9A-Fa-f]{4})+"#)
        for language in Self.languages {
            for (key, value) in try catalogue(language) {
                let range = NSRange(value.startIndex..., in: value)
                XCTAssertNil(
                    undecoded.firstMatch(in: value, range: range),
                    "\(language):\(key) contains what looks like an undecoded escape: \(value)"
                )
            }
        }
    }

    /// A format specifier that differs between two languages is a crash, not a typo: the argument
    /// the code passes is read as whatever the translated string says it is.
    func testFormatSpecifiersAgreeAcrossLanguages() throws {
        let specifier = try Regex(#"%(?:\d+\$)?[-+ #0]*[\d.*]*(?:ll|l|h|hh|z|q|L)?[@dioux XeEfgGcsSpaAn%]"#)
        let english = try catalogue("en")
        for language in Self.languages.dropFirst() {
            let other = try catalogue(language)
            for (key, value) in english {
                guard let translated = other[key] else { continue }
                let ours = value.matches(of: specifier).map { String($0.0) }.sorted()
                let theirs = translated.matches(of: specifier).map { String($0.0) }.sorted()
                XCTAssertEqual(ours, theirs, "\(key): en has \(ours), \(language) has \(theirs)")
            }
        }
    }

    /// Every theme in the catalogue names two strings, and the catalogue is the thing that grows.
    /// Without this, adding a theme and forgetting its Korean name ships a raw key into a menu.
    func testEveryThemeInTheCatalogueIsNamedInEveryLanguage() throws {
        for language in Self.languages {
            let table = try catalogue(language)
            for key in MermaidThemeCatalogue.localizationKeys {
                XCTAssertNotNil(table[key], "\(language) is missing \(key)")
            }
        }
    }

    /// An empty value renders as nothing at all, which on a button or a title is indistinguishable
    /// from the control being broken.
    func testNoValueIsEmpty() throws {
        for language in Self.languages {
            for (key, value) in try catalogue(language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language):\(key) is empty")
            }
        }
    }
}
