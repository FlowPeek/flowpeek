import XCTest
@testable import FlowPeekCore

final class TutorialProgressTests: XCTestCase {
    func testEveryLessonStartsWaiting() {
        let progress = TutorialProgress()
        for lesson in TutorialProgress.Lesson.allCases {
            XCTAssertEqual(progress[lesson], .waiting)
        }
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(progress.completedCount, 0)
    }

    func testDetectionIsItsOwnStateSoNoticingIsNotMistakenForOpening() {
        var progress = TutorialProgress()
        progress.noteDetected(.selection)
        XCTAssertEqual(progress[.selection], .detected)
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(progress.completedCount, 0)
    }

    func testOpeningCompletesOneLessonWithoutTouchingTheOthers() {
        var progress = TutorialProgress()
        progress.noteOpened(.clipboard)
        XCTAssertEqual(progress[.clipboard], .done)
        XCTAssertEqual(progress[.selection], .waiting)
        XCTAssertEqual(progress[.ambient], .waiting)
        XCTAssertEqual(progress.completedCount, 1)
    }

    /// Having opened a diagram once, seeing another one merely detected must not undo the tick.
    func testDetectionNeverDemotesAFinishedLesson() {
        var progress = TutorialProgress()
        progress.noteOpened(.ambient)
        progress.noteDetected(.ambient)
        XCTAssertEqual(progress[.ambient], .done)
    }

    func testCompleteOnlyWhenAllThreeRoutesOpenedAPreview() {
        var progress = TutorialProgress()
        for lesson in TutorialProgress.Lesson.allCases {
            XCTAssertFalse(progress.isComplete)
            progress.noteOpened(lesson)
        }
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.completedCount, 3)
    }

    func testResetClearsEverything() {
        var progress = TutorialProgress()
        TutorialProgress.Lesson.allCases.forEach { progress.noteOpened($0) }
        progress.reset()
        XCTAssertEqual(progress, TutorialProgress())
    }

    /// Without the grant the drag never produces a button and Option-hover never outlines
    /// anything, so those two lessons must not be on offer.
    func testOnlyTheClipboardLessonIsAvailableWithoutAccessibility() {
        XCTAssertEqual(TutorialProgress.Lesson.available(accessibilityGranted: false), [.clipboard])
        XCTAssertEqual(
            TutorialProgress.Lesson.available(accessibilityGranted: true),
            TutorialProgress.Lesson.allCases
        )
    }

    func testWithheldLessonsAreExactlyTheOnesNeedingTheGrant() {
        let withheld = Set(TutorialProgress.Lesson.requiringAccessibility)
        let offered = Set(TutorialProgress.Lesson.available(accessibilityGranted: false))
        XCTAssertEqual(withheld.union(offered), Set(TutorialProgress.Lesson.allCases))
        XCTAssertTrue(withheld.isDisjoint(with: offered))
    }

    /// A declining user finishes by doing the one lesson they can, and the finish button has to say
    /// so rather than offering to "finish anyway" forever.
    func testTheClipboardLessonAloneCompletesTheTutorialWithoutAccessibility() {
        var progress = TutorialProgress()
        let available = TutorialProgress.Lesson.available(accessibilityGranted: false)
        XCTAssertFalse(progress.isComplete(among: available))

        progress.noteOpened(.clipboard)

        XCTAssertTrue(progress.isComplete(among: available))
        XCTAssertEqual(progress.completedCount(among: available), 1)
        XCTAssertFalse(progress.isComplete)
    }

    /// Whether a key resolves to real text cannot be checked here: `String(localized:)` reads the
    /// main bundle, which in a test process is the xctest runner and carries no catalogue. What core
    /// can guarantee is that no two lessons share a key or a symbol, which is what would actually
    /// make two rows look identical.
    func testEveryLessonHasADistinctKeyAndSymbol() {
        let titles = Set(TutorialProgress.Lesson.allCases.map { "\($0.titleKey)" })
        let details = Set(TutorialProgress.Lesson.allCases.map { "\($0.detailKey)" })
        let symbols = Set(TutorialProgress.Lesson.allCases.map(\.symbol))
        let identifiers = Set(TutorialProgress.Lesson.allCases.map(\.id))
        XCTAssertEqual(titles.count, 3)
        XCTAssertEqual(details.count, 3)
        XCTAssertEqual(symbols.count, 3)
        XCTAssertEqual(identifiers.count, 3)
    }

    // MARK: - The chord the copy names

    /// Pointing is the one gesture whose instructions have to name a key, and that key is
    /// rebindable in Settings.
    func testOnlyThePointingLessonNamesTheChord() {
        XCTAssertTrue(TutorialProgress.Lesson.ambient.namesPeekShortcut)
        XCTAssertFalse(TutorialProgress.Lesson.selection.namesPeekShortcut)
        XCTAssertFalse(TutorialProgress.Lesson.clipboard.namesPeekShortcut)
    }

    /// Every sentence that names the peek chord takes it as an argument. Spelled out in the
    /// catalogue — "press Option-Space", "⌥Space opens it" — the copy starts lying the moment the
    /// chord is rebound, and nothing in the app would notice.
    func testTheCopyNamingTheChordTakesItAsAnArgumentInBothCatalogs() throws {
        let keys = ["tutorial.ambient.detail", "settings.ambient.description"]
        for language in ["en", "ko"] {
            let contents = try String(contentsOf: Self.catalog(language), encoding: .utf8)
            for line in contents.components(separatedBy: "\n") {
                guard let key = keys.first(where: { line.hasPrefix("\"\($0)\" = ") }) else { continue }
                XCTAssertTrue(line.contains("%@"), "\(language).lproj: \(key) has to be given the chord")
                XCTAssertFalse(line.contains("⌥Space"), "\(language).lproj: \(key) spells the chord out")
                XCTAssertFalse(line.contains("Option-Space"), "\(language).lproj: \(key) spells the chord out")
            }
            for key in keys {
                XCTAssertTrue(contents.contains("\"\(key)\" = "), "\(language).lproj is missing \(key)")
            }
        }
    }

    // MARK: - Progress that outlives the window

    /// The tutorial is quit halfway through, and a relaunch used to hand the returning user empty
    /// circles for gestures they had already done.
    func testProgressSurvivesARoundTripThroughItsStoredForm() {
        var progress = TutorialProgress()
        progress.noteOpened(.clipboard)
        progress.noteDetected(.ambient)
        progress.noteMissed(.selection)

        XCTAssertEqual(TutorialProgress(persisted: progress.persisted), progress)
    }

    /// Every state has to survive the trip, not just the ticked one: "FlowPeek saw it" and "that
    /// drag was refused" are the two the user most needs to still be there after a relaunch.
    func testEveryStateSurvivesTheRoundTrip() {
        for state in [TutorialProgress.State.waiting, .detected, .missed, .done] {
            let progress = TutorialProgress(states: [.selection: state])
            XCTAssertEqual(TutorialProgress(persisted: progress.persisted)[.selection], state)
        }
    }

    /// The stored names are the file format. Renaming a case would silently discard everyone's
    /// progress, which is the one failure a round trip against itself cannot see.
    func testTheStoredShapeIsLessonNameToStateName() {
        var progress = TutorialProgress()
        progress.noteOpened(.ambient)

        XCTAssertEqual(progress.persisted, ["ambient": "done"])
    }

    /// A file written by a newer build, or by one that named things differently, must not be able to
    /// stop the tutorial from opening: the worst honest outcome is a row that reads as untried.
    func testUnknownLessonsAndStatesAreIgnoredRatherThanRejected() {
        let progress = TutorialProgress(persisted: [
            "clipboard": "done",
            "clipboard-but-sideways": "done",
            "selection": "transcended",
        ])

        XCTAssertEqual(progress[.clipboard], .done)
        XCTAssertEqual(progress[.selection], .waiting)
        XCTAssertEqual(progress.completedCount, 1)
    }

    func testCodableUsesTheSameFlatShapeAsTheStoredForm() throws {
        var progress = TutorialProgress()
        progress.noteDetected(.clipboard)

        let data = try JSONEncoder().encode(progress)

        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: data),
            ["clipboard": "detected"]
        )
        XCTAssertEqual(try JSONDecoder().decode(TutorialProgress.self, from: data), progress)
    }

    // MARK: - A lesson that fires nothing

    func testAMissedAttemptIsItsOwnStateAndFinishesNothing() {
        var progress = TutorialProgress()
        progress.noteMissed(.selection)
        XCTAssertEqual(progress[.selection], .missed)
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertFalse(progress.isComplete)
    }

    /// A second sloppy drag after a good one must not take the tick away, and it must not talk over
    /// "FlowPeek saw it" either.
    func testAMissNeverDemotesALessonThatGotFurther() {
        var finished = TutorialProgress()
        finished.noteOpened(.selection)
        finished.noteMissed(.selection)
        XCTAssertEqual(finished[.selection], .done)

        var noticed = TutorialProgress()
        noticed.noteDetected(.selection)
        noticed.noteMissed(.selection)
        XCTAssertEqual(noticed[.selection], .detected)
    }

    func testAMissedLessonStillPromotesOnceItWorks() {
        var progress = TutorialProgress()
        progress.noteMissed(.selection)
        progress.noteDetected(.selection)
        XCTAssertEqual(progress[.selection], .detected)
        progress.noteOpened(.selection)
        XCTAssertEqual(progress[.selection], .done)
    }

    /// Only the drag route sees its own near misses: an unparseable copy is dropped before anything
    /// records it, and pointing at prose produces no candidate at all. A row with nothing truthful
    /// to say about a miss must not be able to show one.
    func testOnlyTheLessonThatCanExplainAMissCanRecordOne() {
        for lesson in TutorialProgress.Lesson.allCases {
            var progress = TutorialProgress()
            progress.noteMissed(lesson)
            XCTAssertEqual(
                progress[lesson] == .missed,
                lesson.missedKey != nil,
                "\(lesson.rawValue) records a miss it has no words for"
            )
        }
    }

    func testWithEverySwitchOnNothingIsBlocked() {
        for lesson in TutorialProgress.Lesson.allCases {
            XCTAssertNil(lesson.blocker(TutorialProgress.Switches()), lesson.rawValue)
            XCTAssertTrue(lesson.canFire(TutorialProgress.Switches()))
        }
    }

    /// The pause in the menu bar gates all three routes, so a paused user must not be told to go and
    /// make a gesture nothing is listening for — whatever the other two switches say.
    func testThePauseStopsEveryLessonNoMatterWhatElseIsOn() {
        let paused = TutorialProgress.Switches(detectionEnabled: false)
        for lesson in TutorialProgress.Lesson.allCases {
            XCTAssertEqual(lesson.blocker(paused), .detectionPaused, lesson.rawValue)
            XCTAssertFalse(lesson.canFire(paused))
        }
    }

    /// Answered before the per-route switches, because somebody told only about the pointing
    /// experiment turns that on, sees nothing, and has been sent to the wrong switch.
    func testThePauseIsReportedAheadOfARouteItAlsoBlocks() {
        let both = TutorialProgress.Switches(detectionEnabled: false, ambientPeekEnabled: false)
        XCTAssertEqual(TutorialProgress.Lesson.ambient.blocker(both), .detectionPaused)
    }

    /// Each of the other two switches gates one route only, and the drag has no switch of its own
    /// beyond the pause.
    func testTheClipboardWatchAndThePointingExperimentBlockTheirOwnLessonAlone() {
        let noClipboard = TutorialProgress.Switches(clipboardWatchEnabled: false)
        let noAmbient = TutorialProgress.Switches(ambientPeekEnabled: false)
        for lesson in TutorialProgress.Lesson.allCases {
            XCTAssertEqual(
                lesson.blocker(noClipboard),
                lesson == .clipboard ? .clipboardWatchOff : nil,
                "\(lesson.rawValue) disagrees with the clipboard watch"
            )
            XCTAssertEqual(
                lesson.blocker(noAmbient),
                lesson == .ambient ? .ambientPeekOff : nil,
                "\(lesson.rawValue) disagrees with the experiment switch"
            )
        }
        XCTAssertNil(TutorialProgress.Lesson.selection.blocker(
            TutorialProgress.Switches(clipboardWatchEnabled: false, ambientPeekEnabled: false)
        ))
    }

    /// Every switch that can be in the way has to be able to say so on both surfaces — the checklist
    /// row and the practice page — and say something different on each, or one of them is a row that
    /// reads as switched off with no word about which switch.
    func testEverySwitchThatCanBlockALessonHasItsOwnWordingForBothSurfaces() {
        let reachable = Set(
            TutorialProgress.Lesson.allCases.flatMap { lesson in
                Self.everySwitchCombination.compactMap { lesson.blocker($0) }
            }
        )
        XCTAssertEqual(reachable, Set(TutorialProgress.Blocker.allCases))

        let reasons = Set(TutorialProgress.Blocker.allCases.map { Self.key($0.reasonKey) })
        let details = Set(TutorialProgress.Blocker.allCases.map { Self.key($0.detailKey) })
        XCTAssertEqual(reasons.count, TutorialProgress.Blocker.allCases.count)
        XCTAssertEqual(details.count, TutorialProgress.Blocker.allCases.count)
        XCTAssertTrue(reasons.isDisjoint(with: details))
    }

    /// The checklist can throw exactly one of the three switches itself; the other two live
    /// somewhere else and the sentence has to say where rather than offer a button that is not there.
    func testOnlyTheExperimentSwitchIsTheOneTheChecklistCanThrow() {
        for blocker in TutorialProgress.Blocker.allCases {
            XCTAssertEqual(blocker.namesEnableButton, blocker == .ambientPeekOff, blocker.rawValue)
        }
    }

    /// The one sentence that names that button takes it as an argument. Written out in the
    /// catalogue, the page starts naming a control that no longer exists the moment the button is
    /// reworded — and nothing in the app would notice.
    func testTheSentenceNamingTheEnableButtonIsGivenItsLabelInBothCatalogs() throws {
        let key = Self.key(TutorialProgress.Blocker.ambientPeekOff.detailKey)
        let label = Self.key(TutorialProgress.Blocker.enableButtonTitleKey)
        for language in ["en", "ko"] {
            let contents = try String(contentsOf: Self.catalog(language), encoding: .utf8)
            let line = try XCTUnwrap(
                contents.components(separatedBy: "\n").first { $0.hasPrefix("\"\(key)\" = ") },
                "\(language).lproj is missing \(key)"
            )
            XCTAssertTrue(line.contains("%@"), "\(language).lproj: \(key) has to be given the button's label")
            let button = try XCTUnwrap(
                contents.components(separatedBy: "\n").first { $0.hasPrefix("\"\(label)\" = ") }
            )
            let words = button.components(separatedBy: "\"")
            let title = try XCTUnwrap(words.dropLast().last)
            XCTAssertFalse(line.contains(title), "\(language).lproj: \(key) spells the button's label out")
        }
    }

    private static let everySwitchCombination: [TutorialProgress.Switches] = [false, true].flatMap { paused in
        [false, true].flatMap { clipboard in
            [false, true].map { ambient in
                TutorialProgress.Switches(
                    detectionEnabled: paused,
                    clipboardWatchEnabled: clipboard,
                    ambientPeekEnabled: ambient
                )
            }
        }
    }

    func testEveryStateAndEveryNudgeHasItsOwnKey() {
        let states = [TutorialProgress.State.waiting, .detected, .missed, .done]
        XCTAssertEqual(Set(states.map { "\($0.titleKey)" }).count, states.count)
        XCTAssertEqual(Set(TutorialProgress.Lesson.allCases.map { "\($0.nudgeKey)" }).count, 3)
    }

    /// The checklist is read aloud through these, so a key that reaches only one catalogue ships as
    /// its own identifier — VoiceOver saying "tutorial.state.done".
    func testEveryKeyTheChecklistReadsAloudIsInBothCatalogs() throws {
        var keys = ["tutorial.state.off", "tutorial.restart", "menu.tutorial", "tutorial.page.hint"]
        keys += [TutorialProgress.State.waiting, .detected, .missed, .done].map { Self.key($0.titleKey) }
        keys += TutorialProgress.Lesson.allCases.map { Self.key($0.nudgeKey) }
        keys += TutorialProgress.Lesson.allCases.compactMap { $0.missedKey }.map(Self.key)
        keys += TutorialProgress.Blocker.allCases.map { Self.key($0.reasonKey) }
        keys += TutorialProgress.Blocker.allCases.map { Self.key($0.detailKey) }
        keys += [Self.key(TutorialProgress.Blocker.enableButtonTitleKey)]
        keys += ["tutorial.page.intro", "tutorial.page.intro.blocked"]
        for language in ["en", "ko"] {
            let contents = try String(contentsOf: Self.catalog(language), encoding: .utf8)
            for key in keys {
                XCTAssertTrue(contents.contains("\"\(key)\" = "), "\(language).lproj is missing \(key)")
            }
        }
    }

    // MARK: - Recognising the practice page's own diagram

    /// The partial drag the whole missed state exists to explain: a selection that starts below the
    /// line detection reads first.
    func testAPartialSelectionOfTheSampleIsStillRecognisedAsTheSample() {
        XCTAssertTrue(TutorialSample.appearsIn("B -- overlay button --> C[Preview]\n  B -- badge --> C"))
    }

    func testTheWholeSampleIsRecognisedThroughBrowserWhitespace() {
        XCTAssertTrue(TutorialSample.appearsIn("\u{00A0}" + TutorialSample.text + "  \r\n"))
    }

    /// The gate that keeps the tutorial from commenting on the user's own work: a diagram they
    /// dragged badly in their own document is not a failed lesson.
    func testUnrelatedTextIsNotMistakenForThePracticePage() {
        XCTAssertFalse(TutorialSample.appearsIn("flowchart TD\n  X[Their own thing] --> Y[Also theirs]"))
        XCTAssertFalse(TutorialSample.appearsIn("just some prose that mentions FlowPeek"))
        XCTAssertFalse(TutorialSample.appearsIn(""))
    }

    /// The starter line opens every flowchart on the web, so on its own it says nothing about where
    /// the text came from.
    func testTheStarterLineAloneIsNotEvidenceOfThePracticePage() {
        XCTAssertFalse(TutorialSample.appearsIn("flowchart TD"))
    }

    /// A whole document is not a fragment of a five-line block, and normalizing one to establish
    /// that costs more than the detection that has just rejected it.
    func testAnythingFarLargerThanTheBlockIsAnsweredWithoutBeingWalked() {
        let padding = String(repeating: "x", count: TutorialSample.maximumMatchableCharacters)
        XCTAssertFalse(TutorialSample.appearsIn(TutorialSample.text + padding))
        XCTAssertTrue(TutorialSample.appearsIn(TutorialSample.text))
    }

    // MARK: - What a rejected selection is worth asking about

    /// Asked on the main actor for every selection FlowPeek rejects, in every application. The two
    /// free questions come first, so an ordinary select-all never pays for the scan.
    func testARejectedSelectionIsOnlyExaminedWhileThePracticePageIsOpen() {
        let progress = TutorialProgress()
        XCTAssertFalse(
            progress.shouldNoteMissedSelection(text: TutorialSample.text, practicePageOpen: false)
        )
        XCTAssertTrue(
            progress.shouldNoteMissedSelection(text: TutorialSample.text, practicePageOpen: true)
        )
    }

    /// A lesson that has already got further has nothing to complain about, and this is the branch
    /// every ordinary selection takes — so it must stop asking the moment the row is settled.
    func testALessonPastWaitingAsksNothingOfTheText() {
        for state in [TutorialProgress.State.detected, .missed, .done] {
            let progress = TutorialProgress(states: [.selection: state])
            XCTAssertFalse(
                progress.shouldNoteMissedSelection(text: TutorialSample.text, practicePageOpen: true),
                "a \(state.rawValue) row still walks the selection"
            )
        }
    }

    /// The user's own half-dragged diagram is not a failed lesson, even with the page open.
    func testUnrelatedTextIsStillNotAMissWithThePageOpen() {
        let progress = TutorialProgress()
        XCTAssertFalse(
            progress.shouldNoteMissedSelection(
                text: "flowchart TD\n  X[Their own thing] --> Y[Also theirs]",
                practicePageOpen: true
            )
        )
    }

    /// The partial drag, end to end: refused by detection, recognised as the practice page's own
    /// diagram, recorded as a miss so the row can say which part to change.
    func testThePartialDragOffThePracticePageBecomesAMiss() {
        var progress = TutorialProgress()
        let dragged = "B -- overlay button --> C[Preview]\n  B -- badge --> C"
        XCTAssertTrue(progress.shouldNoteMissedSelection(text: dragged, practicePageOpen: true))
        progress.noteMissed(.selection)
        XCTAssertEqual(progress[.selection], .missed)
        XCTAssertFalse(progress.shouldNoteMissedSelection(text: dragged, practicePageOpen: true))
    }

    /// `String.LocalizationValue` keeps its key private and interpolating one yields the whole
    /// reflected struct, so the key is lifted back out of that. Only a test needs this: the app
    /// hands the value straight to `String(localized:)`. If the reflection ever stops looking like
    /// this the dump comes back instead, and the assertion using it fails rather than passing.
    private static func key(_ value: String.LocalizationValue) -> String {
        let dump = "\(value)"
        guard let start = dump.range(of: "key: \"")?.upperBound,
              let end = dump.range(of: "\"", range: start..<dump.endIndex)?.lowerBound
        else { return dump }
        return String(dump[start..<end])
    }

    private static func catalog(_ language: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlowPeekCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/FlowPeek/Resources/\(language).lproj/Localizable.strings")
    }
}
