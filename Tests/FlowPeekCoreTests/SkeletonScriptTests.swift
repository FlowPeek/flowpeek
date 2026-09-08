import Foundation
import XCTest
@testable import FlowPeekCore

/// The timings behind the little drawings that explain each mechanic. Worth testing because a
/// stage that cannot be reached, or a loop that does not come back round, is the kind of fault a
/// looping animation hides: it just looks slightly wrong forever.
final class SkeletonScriptTests: XCTestCase {
    private enum Stage: Equatable, Sendable {
        case quiet
        case approaching
        case revealed
    }

    private let script = SkeletonScript<Stage>([
        .init(.quiet, 1.0),
        .init(.approaching, 0.5),
        .init(.revealed, 1.5),
    ])

    func testTheTotalIsEveryStep() {
        XCTAssertEqual(script.total, 3.0, accuracy: 0.0001)
    }

    func testEachStageOwnsItsOwnSliceOfTheLoop() {
        XCTAssertEqual(script.stage(at: 0), .quiet)
        XCTAssertEqual(script.stage(at: 0.99), .quiet)
        XCTAssertEqual(script.stage(at: 1.0), .approaching)
        XCTAssertEqual(script.stage(at: 1.49), .approaching)
        XCTAssertEqual(script.stage(at: 1.5), .revealed)
        XCTAssertEqual(script.stage(at: 2.99), .revealed)
    }

    func testTheLoopComesBackRound() {
        XCTAssertEqual(script.stage(at: 3.0), .quiet)
        XCTAssertEqual(script.stage(at: 4.0), .approaching)
        XCTAssertEqual(script.stage(at: 300.25), .quiet)
    }

    /// A scene can be driven from a clock that has not reached its own origin, and wrapping
    /// backwards has to land in the last step rather than before the first.
    func testNegativeTimeWrapsIntoTheLoop() {
        XCTAssertEqual(script.stage(at: -0.5), .revealed)
        XCTAssertEqual(script.stage(at: -1.6), .approaching)
        XCTAssertEqual(script.stage(at: -3.0), .quiet)
    }

    func testProgressRunsFromTheStartOfEachStep() {
        XCTAssertEqual(script.progress(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(script.progress(at: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(script.progress(at: 1.25), 0.5, accuracy: 0.0001)
        XCTAssertEqual(script.progress(at: 2.25), 0.5, accuracy: 0.0001)
    }

    /// A step of no length is unreachable by any clock, so keeping it would mean a stage that is in
    /// the script and never on screen.
    func testStepsOfNoLengthAreDropped() {
        let script = SkeletonScript<Stage>([
            .init(.quiet, 1),
            .init(.approaching, 0),
            .init(.revealed, -1),
        ])
        XCTAssertEqual(script.steps.map(\.stage), [.quiet])
        XCTAssertEqual(script.total, 1)
    }

    func testAnEmptyScriptPlaysNothing() {
        let script = SkeletonScript<Stage>([])
        XCTAssertTrue(script.isEmpty)
        XCTAssertEqual(script.total, 0)
        XCTAssertNil(script.stage(at: 1))
        XCTAssertNil(script.resting)
        XCTAssertEqual(script.progress(at: 1), 0)
    }

    /// Reduced motion gets one frame instead of a loop, and it should be the frame that shows the
    /// mechanic having worked -- which is where the script ends.
    func testTheRestingStageIsTheLastOneUnlessNamed() {
        XCTAssertEqual(script.resting, .revealed)
        XCTAssertEqual(
            SkeletonScript<Stage>([.init(.quiet, 1), .init(.revealed, 1)], resting: .quiet).resting,
            .quiet
        )
    }

    /// A clock that has stopped being a number must not take the drawing with it.
    func testAnUnusableTimeFallsBackToTheFirstStage() {
        XCTAssertEqual(script.stage(at: .infinity), .quiet)
        XCTAssertEqual(script.stage(at: .nan), .quiet)
    }
}
