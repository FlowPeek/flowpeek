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
}
