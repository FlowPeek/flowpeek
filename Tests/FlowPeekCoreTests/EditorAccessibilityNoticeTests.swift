import XCTest

@testable import FlowPeekCore

/// When a silent gesture in VS Code is worth explaining, and when explaining it would be wrong.
final class EditorAccessibilityNoticeTests: XCTestCase {
    // MARK: - Reading the setting

    /// The one file this reads is JSON with comments and trailing commas allowed, which is why it
    /// is scanned rather than parsed: `JSONSerialization` refuses an ordinary VS Code settings file.
    func testTheSettingIsFoundInASettingsFileAStrictParserWouldRefuse() {
        let settings = """
        {
          // The editor, mostly
          "editor.fontSize": 13,
          "editor.accessibilitySupport": "on",   // turned on for a screen reader
          "workbench.colorTheme": "Default Dark+",
        }
        """
        XCTAssertEqual(EditorAccessibilityNotice.support(inUserSettings: settings), .on)
    }

    func testEveryValueTheSettingCanTake() {
        XCTAssertEqual(
            EditorAccessibilityNotice.support(inUserSettings: #"{"editor.accessibilitySupport": "off"}"#), .off
        )
        XCTAssertEqual(
            EditorAccessibilityNotice.support(inUserSettings: #"{"editor.accessibilitySupport":"auto"}"#), .auto
        )
        XCTAssertEqual(
            EditorAccessibilityNotice.support(inUserSettings: #"{ "editor.accessibilitySupport" :  "ON" }"#), .on,
            "the value is matched without regard to case"
        )
    }

    /// No file, or no such key, means the default, and the default is `auto`. Both read as "not on"
    /// rather than as "cannot tell", because the consequence for the reader is identical.
    func testAMissingSettingIsNotOn() {
        XCTAssertEqual(EditorAccessibilityNotice.support(inUserSettings: "{}"), .unknown)
        XCTAssertEqual(EditorAccessibilityNotice.support(inUserSettings: ""), .unknown)
        XCTAssertFalse(EditorAccessibilityNotice.Support.unknown.exposesText)
        XCTAssertFalse(EditorAccessibilityNotice.Support.auto.exposesText)
        XCTAssertTrue(EditorAccessibilityNotice.Support.on.exposesText)
    }

    /// A key that merely looks similar is not this key.
    func testANeighbouringSettingIsNotMistakenForIt() {
        XCTAssertEqual(
            EditorAccessibilityNotice.support(
                inUserSettings: #"{"editor.accessibilityPageSize": 10, "editor.fontLigatures": "on"}"#
            ),
            .unknown
        )
    }

    // MARK: - Which editor this is

    /// Identified by the file the editor carries rather than by a list of bundle identifiers, so a
    /// fork nobody has heard of yet is handled the day it ships. These are the real values from the
    /// installed editor.
    func testTheProductFileIdentifiesTheEditorAndWhereItKeepsSettings() throws {
        let json = """
        {"nameShort": "Code", "nameLong": "Visual Studio Code", "applicationName": "code",
         "dataFolderName": ".vscode", "darwinBundleIdentifier": "com.microsoft.VSCode"}
        """
        let product = try XCTUnwrap(EditorAccessibilityNotice.product(fromProductJSON: Data(json.utf8)))
        XCTAssertEqual(product.nameShort, "Code")
        XCTAssertEqual(product.nameLong, "Visual Studio Code")
        XCTAssertEqual(product.bundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(
            EditorAccessibilityNotice.userSettingsPath(of: product),
            ["Application Support", "Code", "User", "settings.json"]
        )
    }

    /// Every fork files its data under its own `nameShort`, which is why the directory is read from
    /// the editor instead of guessed. Checked against the directories Homebrew removes for each.
    func testAForkIsReadTheSameWayAndPointsAtItsOwnDirectory() throws {
        for (nameShort, long) in [("Cursor", "Cursor"), ("Antigravity", "Google Antigravity"),
                                  ("Trae", "Trae"), ("Kiro", "Kiro"), ("Positron", "Positron"),
                                  ("Void", "Void"), ("VSCodium", "VSCodium"),
                                  ("Code - Insiders", "Visual Studio Code - Insiders")] {
            let json = #"{"nameShort": "\#(nameShort)", "nameLong": "\#(long)", "applicationName": "code"}"#
            let product = try XCTUnwrap(
                EditorAccessibilityNotice.product(fromProductJSON: Data(json.utf8)), nameShort
            )
            XCTAssertEqual(
                EditorAccessibilityNotice.userSettingsPath(of: product)[1], nameShort,
                "\(long) keeps its settings under its own name"
            )
        }
    }

    func testAnApplicationThatIsNotOneOfTheseEditorsIsNotMistakenForOne() {
        XCTAssertNil(EditorAccessibilityNotice.product(fromProductJSON: Data("not json".utf8)))
        XCTAssertNil(EditorAccessibilityNotice.product(fromProductJSON: Data("{}".utf8)))
        XCTAssertNil(
            EditorAccessibilityNotice.product(fromProductJSON: Data(#"{"nameShort": "Code"}"#.utf8)),
            "a product file without applicationName is some other application's"
        )
    }

    /// The name becomes part of a path, so a name that is a path is refused rather than followed.
    func testANameThatWouldEscapeItsDirectoryIsRefused() {
        for name in ["../../etc", "/", "..", "."] {
            XCTAssertNil(
                EditorAccessibilityNotice.product(
                    fromProductJSON: Data(#"{"nameShort": "\#(name)", "applicationName": "code"}"#.utf8)
                ),
                name
            )
        }
    }

    // MARK: - When to say it

    /// The setting being on is the whole of the guard against nagging somebody who has already
    /// done what the notice asks. A quiet gesture in that editor is then a document with no diagram
    /// in it, which is not worth a word.
    func testNothingIsSaidWhenTheSettingIsAlreadyOn() {
        XCTAssertFalse(
            EditorAccessibilityNotice.shouldTell(support: .on, told: 0, lastTold: nil, now: .now)
        )
    }

    func testTheFirstSilentGestureIsExplained() {
        for support in [EditorAccessibilityNotice.Support.auto, .off, .unknown] {
            XCTAssertTrue(
                EditorAccessibilityNotice.shouldTell(support: support, told: 0, lastTold: nil, now: .now),
                "\(support) leaves the editor unreadable and is worth explaining"
            )
        }
    }

    /// Holding the key three times in five seconds is one question asked three times, and the badge
    /// already on screen is its answer.
    func testABurstOfGesturesIsOneTelling() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(
            EditorAccessibilityNotice.shouldTell(
                support: .auto, told: 1, lastTold: now.addingTimeInterval(-5), now: now
            )
        )
        XCTAssertTrue(
            EditorAccessibilityNotice.shouldTell(
                support: .auto,
                told: 1,
                lastTold: now.addingTimeInterval(-EditorAccessibilityNotice.repeatInterval),
                now: now
            )
        )
    }

    /// Twice is telling, three times is nagging. Somebody who has read it and carried on has
    /// decided, and the answer stays in the README and the menu either way.
    func testItStopsAfterTwoTellings() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let longAgo = now.addingTimeInterval(-86_400)
        XCTAssertTrue(EditorAccessibilityNotice.shouldTell(support: .auto, told: 1, lastTold: longAgo, now: now))
        XCTAssertFalse(EditorAccessibilityNotice.shouldTell(support: .auto, told: 2, lastTold: longAgo, now: now))
    }
}
