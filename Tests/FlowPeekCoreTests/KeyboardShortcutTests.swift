import XCTest
@testable import FlowPeekCore

final class KeyboardShortcutTests: XCTestCase {
    private let m: UInt16 = 0x2E
    private let a: UInt16 = 0x00

    // MARK: - Rendering

    func testModifiersRenderInTheOrderMacOSUses() {
        let all: FlowPeekShortcut.Modifiers = [.command, .option, .control, .shift]
        XCTAssertEqual(all.display, "⌃⌥⇧⌘")
        XCTAssertEqual(FlowPeekShortcut(keyCode: m, modifiers: [.command, .option, .shift]).display, "⌥⇧⌘M")
        XCTAssertEqual(FlowPeekShortcut(keyCode: m, modifiers: [.command, .option]).display, "⌥⌘M")
    }

    func testNamedKeysRenderAsGlyphsAndUnknownCodesStayVisible() {
        XCTAssertEqual(FlowPeekShortcut.keyName(for: 0x31), "Space")
        XCTAssertEqual(FlowPeekShortcut.keyName(for: 0x24), "↩")
        XCTAssertEqual(FlowPeekShortcut.keyName(for: 0x35), "⎋")
        XCTAssertEqual(FlowPeekShortcut.keyName(for: 0x7A), "F1")
        XCTAssertEqual(FlowPeekShortcut.keyName(for: 0x2A), "\\")
        XCTAssertEqual(FlowPeekShortcut.keyName(for: 0xFE), "#254")
    }

    // MARK: - Validation

    func testShiftAloneIsNotEnoughToAnchorAGlobalShortcut() {
        XCTAssertEqual(FlowPeekShortcut.validate(keyCode: a, modifiers: [.shift]), .noAnchoringModifier)
        XCTAssertEqual(FlowPeekShortcut.validate(keyCode: a, modifiers: []), .noAnchoringModifier)
        XCTAssertNil(FlowPeekShortcut.validate(keyCode: a, modifiers: [.control]))
        XCTAssertNil(FlowPeekShortcut.validate(keyCode: a, modifiers: [.option]))
        XCTAssertNil(FlowPeekShortcut.validate(keyCode: a, modifiers: [.command]))
        XCTAssertNil(FlowPeekShortcut.validate(keyCode: a, modifiers: [.command, .shift]))
    }

    func testSystemReservedCombinationsAreRefusedUpFront() {
        XCTAssertEqual(
            FlowPeekShortcut.validate(keyCode: 0x31, modifiers: [.command]),
            .reservedByTheSystem("⌘Space")
        )
        XCTAssertEqual(
            FlowPeekShortcut.validate(keyCode: 0x30, modifiers: [.command]),
            .reservedByTheSystem("⌘Tab")
        )
        // The same key with a different modifier set is not reserved.
        XCTAssertNil(FlowPeekShortcut.validate(keyCode: 0x31, modifiers: [.command, .control]))
    }

    /// These return `noErr` from `RegisterEventHotKey` and are then swallowed before they reach the
    /// app, so the registration status cannot see them and this list is the only defence.
    func testTheSilentlySwallowedSystemCombinationsAreRefusedToo() {
        let cases: [(UInt16, FlowPeekShortcut.Modifiers, String)] = [
            (0x14, [.command, .shift], "⇧⌘3"),
            (0x15, [.command, .shift], "⇧⌘4"),
            (0x17, [.command, .shift], "⇧⌘5"),
            (0x16, [.command, .shift], "⇧⌘6"),
            (0x31, [.control], "⌃Space"),
            (0x31, [.control, .option], "⌃⌥Space"),
            (0x7E, [.control], "⌃↑"),
            (0x7D, [.control], "⌃↓"),
            (0x7B, [.control], "⌃←"),
            (0x7C, [.control], "⌃→"),
            (0x2C, [.command, .shift], "⇧⌘/"),
        ]
        for (keyCode, modifiers, name) in cases {
            XCTAssertEqual(
                FlowPeekShortcut.validate(keyCode: keyCode, modifiers: modifiers),
                .reservedByTheSystem(name),
                name
            )
            // Each name is the combination the user pressed, not a guess.
            XCTAssertEqual(FlowPeekShortcut(keyCode: keyCode, modifiers: modifiers).display, name)
        }
        // Adding Command to the screenshot keys leaves them assignable.
        XCTAssertNil(FlowPeekShortcut.validate(keyCode: 0x14, modifiers: [.command, .option]))
    }

    /// The OS is the only witness to this one, so core just carries the name through to the catalogue.
    func testAShortcutAnotherAppOwnsNamesTheCombinationForTheCatalogue() {
        let error = FlowPeekShortcut.ValidationError.claimedByAnotherApp("⌥⌘M")
        XCTAssertEqual(error.localizationKey, "shortcut.error.claimed")
        XCTAssertEqual(error.localizationArgument, "⌥⌘M")
        XCTAssertNotNil(error.errorDescription)
    }

    func testAClashNamesTheActionAlreadyHoldingTheShortcut() {
        let taken = [FlowPeekShortcut(keyCode: m, modifiers: [.command, .option]): "Generate with AI"]
        XCTAssertEqual(
            FlowPeekShortcut.validate(keyCode: m, modifiers: [.command, .option], taken: taken),
            .alreadyUsed(action: "Generate with AI")
        )
        XCTAssertNil(FlowPeekShortcut.validate(keyCode: m, modifiers: [.command, .control], taken: taken))
    }

    // MARK: - The set

    func testDefaultsMatchTheShippedAssignments() {
        let set = FlowPeekShortcutSet.defaults
        XCTAssertTrue(set.isDefault)
        XCTAssertEqual(set[.aiPrompt].display, "⌥⌘M")
        XCTAssertEqual(set[.previewClipboard].display, "⌥⇧⌘M")
        // Every action must have a distinct default, or one would shadow the other on first launch.
        let displays = Set(FlowPeekShortcutAction.allCases.map { set[$0].display })
        XCTAssertEqual(displays.count, FlowPeekShortcutAction.allCases.count)
    }

    func testHotKeyIdentifiersAreUniqueAndStable() {
        let ids = FlowPeekShortcutAction.allCases.map(\.hotKeyID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(FlowPeekShortcutAction.aiPrompt.hotKeyID, 1)
        XCTAssertEqual(FlowPeekShortcutAction.previewClipboard.hotKeyID, 2)
    }

    func testAssigningAnUnusedCombinationSucceedsAndSticks() {
        var set = FlowPeekShortcutSet.defaults
        XCTAssertNil(set.assign(keyCode: 0x02, modifiers: [.command, .control], to: .previewClipboard))
        XCTAssertEqual(set[.previewClipboard].display, "⌃⌘D")
        XCTAssertFalse(set.isDefault)
        // The other action is untouched.
        XCTAssertEqual(set[.aiPrompt].display, "⌥⌘M")
    }

    func testAssigningTheOtherActionsShortcutIsRefusedAndChangesNothing() {
        var set = FlowPeekShortcutSet.defaults
        let before = set
        let error = set.assign(keyCode: m, modifiers: [.command, .option], to: .previewClipboard)
        XCTAssertEqual(error, .alreadyUsed(action: String(localized: FlowPeekShortcutAction.aiPrompt.titleKey)))
        XCTAssertEqual(set, before)
    }

    func testAnActionCanBeReRecordedOntoItsOwnShortcut() {
        var set = FlowPeekShortcutSet.defaults
        XCTAssertNil(set.assign(keyCode: m, modifiers: [.command, .option], to: .aiPrompt))
        XCTAssertEqual(set[.aiPrompt].display, "⌥⌘M")
    }

    func testResetRestoresOneActionAndResetAllRestoresEverything() {
        var set = FlowPeekShortcutSet.defaults
        XCTAssertNil(set.assign(keyCode: 0x02, modifiers: [.command, .control], to: .previewClipboard))
        XCTAssertNil(set.assign(keyCode: 0x0E, modifiers: [.command, .control], to: .aiPrompt))

        set.reset(.previewClipboard)
        XCTAssertEqual(set[.previewClipboard], FlowPeekShortcutAction.previewClipboard.defaultShortcut)
        XCTAssertFalse(set.isDefault)

        set.resetAll()
        XCTAssertTrue(set.isDefault)
    }

    // MARK: - Persistence

    func testTheSetSurvivesAJSONRoundTrip() throws {
        var set = FlowPeekShortcutSet.defaults
        XCTAssertNil(set.assign(keyCode: 0x31, modifiers: [.command, .control, .shift], to: .previewClipboard))

        let data = try JSONEncoder().encode(set)
        let restored = try JSONDecoder().decode(FlowPeekShortcutSet.self, from: data)

        XCTAssertEqual(restored, set)
        XCTAssertEqual(restored[.previewClipboard].display, "⌃⇧⌘Space")
    }

    /// A set stored before a new action existed must still decode, falling back to that action's default.
    func testAPartialSetFallsBackToTheDefaultForMissingActions() throws {
        let partial = FlowPeekShortcutSet(
            assignments: [.aiPrompt: FlowPeekShortcut(keyCode: 0x0E, modifiers: [.command, .control])]
        )
        let restored = try JSONDecoder().decode(
            FlowPeekShortcutSet.self,
            from: try JSONEncoder().encode(partial)
        )

        XCTAssertEqual(restored[.aiPrompt].display, "⌃⌘E")
        XCTAssertEqual(restored[.previewClipboard], FlowPeekShortcutAction.previewClipboard.defaultShortcut)
    }
}
