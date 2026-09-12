import Foundation

/// Taking whole lines out of a file that is still being written to.
///
/// A coding agent appends to its session file while the reader is looking at the screen, so every
/// read has two edges that are not lines: the last one may be half-written, and the first one is
/// only a whole line if the read began where the last one stopped. Getting either wrong is quiet --
/// half a JSON object simply fails to decode, and a line dropped for no reason is a diagram that
/// never appears -- so the arithmetic is here, where it can be tested, rather than inline.
public enum AppendedLines {
    /// The most bytes a single line may be before it is given up on.
    ///
    /// Without this a file with no newline in it at all is never consumed and is read again from
    /// the same offset for ever, growing each time.
    public static let maximumLineBytes = 8 * 1_024 * 1_024

    /// What a read of appended bytes yields.
    public struct Take: Equatable {
        /// The whole lines, newline excluded.
        public let lines: [Data]
        /// How many of the chunk's bytes those lines account for. What is left is a partial line and
        /// is read again next time, from this many bytes further on.
        public let consumed: Int
    }

    /// - Parameters:
    ///   - chunk: the bytes read.
    ///   - startsMidLine: whether the read began at an arbitrary offset. True only for the first
    ///     look at a file already larger than the window worth reading; every later read starts
    ///     exactly where the last one stopped, which is a line boundary, and dropping a line there
    ///     would throw away a whole record every time.
    public static func take(_ chunk: Data, startsMidLine: Bool) -> Take {
        guard !chunk.isEmpty else { return Take(lines: [], consumed: 0) }
        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
            // No line ended here. Either it will next time, or the line is past believing and the
            // bytes are given up rather than read again for ever.
            return Take(lines: [], consumed: chunk.count > maximumLineBytes ? chunk.count : 0)
        }
        let consumed = chunk.distance(from: chunk.startIndex, to: lastNewline) + 1
        let whole = chunk[chunk.startIndex..<chunk.index(after: lastNewline)]
        var lines = whole.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { Data($0) }
            .filter { !$0.isEmpty }
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        return Take(lines: lines, consumed: consumed)
    }
}
