import XCTest
@testable import FlowPeekCore

/// Reading a file somebody else is still writing to.
final class AppendedLinesTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func text(_ take: AppendedLines.Take) -> [String] {
        take.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func testWholeLinesAreTakenAndCounted() {
        let take = AppendedLines.take(data("one\ntwo\nthree\n"), startsMidLine: false)
        XCTAssertEqual(text(take), ["one", "two", "three"])
        XCTAssertEqual(take.consumed, 14)
    }

    /// The last line may still be being written, so it is left where it is and read again from the
    /// offset this reports.
    func testAHalfWrittenLastLineIsLeftForNextTime() {
        let take = AppendedLines.take(data("one\ntwo\nthr"), startsMidLine: false)
        XCTAssertEqual(text(take), ["one", "two"])
        XCTAssertEqual(take.consumed, 8, "only up to the last newline")
    }

    /// The bug this file exists to stop. A read that starts where the last one stopped starts on a
    /// line boundary, and dropping its first line throws away a whole record on every poll.
    func testAReadThatStartsAtABoundaryKeepsItsFirstLine() {
        let take = AppendedLines.take(data("first\nsecond\n"), startsMidLine: false)
        XCTAssertEqual(text(take), ["first", "second"])
    }

    /// Only the very first look at an already-large file starts part-way into a line, and there the
    /// fragment really is not a line.
    func testAReadThatStartsMidLineDropsTheFragment() {
        let take = AppendedLines.take(data("agment\"}\nsecond\n"), startsMidLine: true)
        XCTAssertEqual(text(take), ["second"])
        XCTAssertEqual(take.consumed, 16, "the fragment's bytes are still consumed")
    }

    func testNothingCompleteConsumesNothing() {
        let take = AppendedLines.take(data("no newline yet"), startsMidLine: false)
        XCTAssertEqual(take.lines, [])
        XCTAssertEqual(take.consumed, 0, "read it again when the rest arrives")
    }

    /// Unless it is past believing, in which case it is given up rather than re-read for ever.
    func testAnImpossiblyLongLineIsGivenUp() {
        let huge = data(String(repeating: "x", count: AppendedLines.maximumLineBytes + 1))
        let take = AppendedLines.take(huge, startsMidLine: false)
        XCTAssertEqual(take.lines, [])
        XCTAssertEqual(take.consumed, huge.count)
    }

    func testBlankLinesAreNotLines() {
        XCTAssertEqual(text(AppendedLines.take(data("one\n\n\ntwo\n"), startsMidLine: false)), ["one", "two"])
    }

    func testAnEmptyChunkAnswersNothing() {
        XCTAssertEqual(AppendedLines.take(Data(), startsMidLine: false), .init(lines: [], consumed: 0))
    }
}
