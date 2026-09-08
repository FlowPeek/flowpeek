import FlowPeekCore
import XCTest

/// Hosted by the app, so `String(localized:)` resolves against the real catalogue. The Core tests
/// can only check that the two keys are joined; this is where the sentence somebody actually reads
/// is checked.
final class TutorialGestureTests: XCTestCase {
    private func detail(gestureOn: Bool, detection: Bool = true) -> String {
        TutorialProgress.Lesson.clipboard.detail(
            peekShortcut: "⌥Space",
            switches: TutorialProgress.Switches(
                detectionEnabled: detection,
                doubleTapEnabled: gestureOn
            )
        )
    }

    func testTheCopyLessonTeachesTheGesture() {
        let text = detail(gestureOn: true)
        XCTAssertTrue(text.contains("Option"), text)
        XCTAssertFalse(text.contains("tutorial."), "a key leaked into the lesson: \(text)")
    }

    func testTheLessonWithoutTheGestureIsStillAWholeSentence() {
        let text = detail(gestureOn: false)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("tutorial."), "a key leaked into the lesson: \(text)")
        XCTAssertFalse(text.contains("Option"), "the gesture is off and must not be taught: \(text)")
    }

    func testAPausedAppTeachesNothingAboutTheGesture() {
        XCTAssertEqual(detail(gestureOn: true, detection: false), detail(gestureOn: false))
    }
}
