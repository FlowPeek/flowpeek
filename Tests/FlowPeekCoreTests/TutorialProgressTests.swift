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

    private static func catalog(_ language: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlowPeekCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/FlowPeek/Resources/\(language).lproj/Localizable.strings")
    }
}
