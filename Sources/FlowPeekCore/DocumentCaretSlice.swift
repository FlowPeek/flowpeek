import Foundation

/// A diagram lifted out of a whole document around the caret, and where in that document it sat.
public struct CaretDiagramSlice: Equatable, Sendable {
    /// The block's own text, its fences included: the detector strips the fence and the chrome
    /// around it, so that work stays in one place. Line endings are normalised to `\n`, which is
    /// what the detector does with them anyway.
    public let text: String
    public let detection: MermaidDetection
    /// Where `text` came from, counted in UTF-16 code units -- the unit an `AXSelectedTextRange`
    /// location arrives in, because the value it indexes is an `NSString`. Ends at the last
    /// character of the block, not past the newline that follows it.
    public let range: NSRange

    public init(text: String, detection: MermaidDetection, range: NSRange) {
        self.text = text
        self.detection = detection
        self.range = range
    }
}

/// Finds the diagram a caret is sitting in, given the whole document.
///
/// This exists for editors that hand out their document and nothing else. VS Code's editor -- and
/// every Electron app built the same way -- exposes the focused `AXTextArea`'s `AXValue` as the
/// entire file with real newlines, while the elements under the pointer are `AXGroup`s with no
/// value at all. There is no way left to ask which line the pointer is over: `AXTextMarkerForPosition`
/// is advertised and answers nil, `AXBoundsForRange` answers 0x0, and every line's
/// `AXTextMarkerRangeForLine` bounds is the whole editor rectangle. The caret is the one position
/// the editor does report, and in an editor it is where the user is working.
///
/// Pure, so the slicing can be tested without an accessibility target: a document, a caret offset
/// and the detector are the whole input.
public enum DocumentCaretSlicer {
    /// How many characters the line split gets through between two readings of the clock.
    private static let clockInterval = 4_096

    /// The diagram around `caret`, or nil when the caret is not in one.
    ///
    /// `caret` is a UTF-16 offset and is clamped into the document, so a stale offset from an
    /// editor that has since shortened its buffer reads as "at the end" rather than as nothing.
    ///
    /// `deadline` is the same wall clock the accessibility calls that fetched the document run
    /// against. Slicing is the one part of a read that is not a message to another process, so
    /// nothing else would ever interrupt it, and a read that runs out of clock here is reported as
    /// unfinished exactly like one that ran out of clock mid-descent.
    public static func slice(
        document: String,
        caret: Int,
        minimumConfidence: MermaidDetection.Confidence = AmbientPeekPolicy.minimumConfidence,
        before deadline: Date = .distantFuture
    ) -> CaretDiagramSlice? {
        guard !document.isEmpty else { return nil }
        // Refused on length before a single character is examined: an editor hands over its whole
        // buffer, the work below is linear in it, and a clock alone cannot keep a read cheap when
        // it is re-run every debounce for as long as the modifier is held.
        guard document.utf16.count <= AmbientPeekPolicy.maximumDocumentCharacters else { return nil }
        guard Date() < deadline else { return nil }
        guard let lines = self.lines(of: document, before: deadline) else { return nil }
        let clamped = min(max(caret, 0), lines[lines.count - 1].end)
        guard let region = region(containing: clamped, in: lines) else { return nil }
        guard Date() < deadline else { return nil }
        let detection = MermaidDetector.detect(region.text)
        guard detection.confidence >= minimumConfidence else { return nil }
        return CaretDiagramSlice(text: region.text, detection: detection, range: region.range)
    }

    // MARK: - Lines

    private struct Line {
        let text: String
        /// UTF-16 offset of the line's first character.
        let start: Int
        /// UTF-16 offset just past the line's last character, before its terminator.
        let contentEnd: Int
        /// UTF-16 offset just past the terminator, which is where the next line starts.
        let end: Int
    }

    /// Splits into lines while counting UTF-16 offsets, because the caret is one of those offsets
    /// and nothing else in the document can be trusted to place it.
    ///
    /// Iterating over `Character`s is what makes CRLF free: Swift treats "\r\n" as a single
    /// character two code units wide, so a CRLF document yields exactly the same lines as an LF one
    /// and only the offsets differ -- which is the difference the caret is counted in.
    private static func lines(of document: String, before deadline: Date) -> [Line]? {
        var lines: [Line] = []
        var text = ""
        var start = 0
        var offset = 0
        var sinceCheck = 0
        for character in document {
            // Every few thousand characters rather than every one: reading the clock is itself work,
            // and the point is to notice a deadline that has passed, not to time each character.
            sinceCheck += 1
            if sinceCheck >= Self.clockInterval {
                guard Date() < deadline else { return nil }
                sinceCheck = 0
            }
            let width = character.unicodeScalars.reduce(0) { $0 + UTF16.width($1) }
            if character == "\n" || character == "\r\n" || character == "\r" {
                lines.append(Line(text: text, start: start, contentEnd: offset, end: offset + width))
                offset += width
                start = offset
                text = ""
                continue
            }
            text.append(character)
            offset += width
        }
        // Always closed off, terminator or not: a document ending in a newline has an empty last
        // line, and a caret parked after that newline has to land somewhere.
        lines.append(Line(text: text, start: start, contentEnd: offset, end: offset))
        return lines
    }

    // MARK: - Regions

    private struct Region {
        let range: NSRange
        let text: String
    }

    private static func region(containing caret: Int, in lines: [Line]) -> Region? {
        var index = 0
        var sawFence = false
        while index < lines.count {
            guard let open = fenceOpen(lines[index].text) else {
                index += 1
                continue
            }
            sawFence = true
            let last = closingFenceIndex(lines, after: index, marker: open.marker) ?? lines.count - 1
            if open.mayHoldMermaid, caret >= lines[index].start, caret <= lines[last].contentEnd {
                return region(lines, from: index, to: last)
            }
            // Past the whole block, closing fence included: a fence inside a fence is content, and
            // treating it as an opener would slice from the middle of someone's code sample.
            index = last + 1
        }
        // A file that *is* a diagram rather than a document mentioning one -- .mmd, or a scratch
        // buffer -- has no fence to find, so the document is the block.
        //
        // With fences present, a caret outside every one of them is in prose. Nothing is returned
        // for it on purpose: the nearest block is not the block the user is in, and framing it
        // would open a diagram the caret was never near.
        guard !sawFence else { return nil }
        // Nothing marks a fence-free document as code, so it has to say what it is on its own first
        // line. Without that test every focused text area in every app is a diagram the moment its
        // first line opens with a word mermaid also uses -- "graph of dependencies" is a note, and
        // an outline around somebody's notes is worse than no outline at all.
        guard let opening = firstContentLine(lines), MermaidDetector.declaresDiagram(opening) else { return nil }
        return region(lines, from: 0, to: lines.count - 1)
    }

    /// The first line that carries the document's own content: blank lines, `%%` comments,
    /// `%%{init}%%` directives and front matter all belong to a diagram file and are scanned past,
    /// the same way the detector's starter scan passes over them.
    private static func firstContentLine(_ lines: [Line]) -> String? {
        var index = 0
        var insideDirective = false
        var insideFrontMatter = false
        while index < lines.count {
            let line = lines[index].text.trimmingCharacters(in: .whitespaces)
            index += 1
            if insideDirective {
                if line.contains("}%%") { insideDirective = false }
                continue
            }
            if insideFrontMatter {
                if line == "---" { insideFrontMatter = false }
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("%%{") {
                insideDirective = !line.contains("}%%")
                continue
            }
            if line.hasPrefix("%%") { continue }
            // Only an opening delimiter: a closing one has already been consumed above, and a
            // document whose first content line is a lone `---` and never closes is not front
            // matter, so it falls through and is judged as the line it is.
            if line == "---", lines.dropFirst(index).contains(where: { $0.text.trimmingCharacters(in: .whitespaces) == "---" }) {
                insideFrontMatter = true
                continue
            }
            return line
        }
        return nil
    }

    /// Trailing blank lines are dropped from what is handed on, but not from what counts as being
    /// inside the region: a document that ends in a newline has an empty last line, the caret sits
    /// on it whenever the user is typing at the end of a diagram file, and the block is still the
    /// block. Without the trim the range would name a newline the block does not include.
    private static func region(_ lines: [Line], from first: Int, to last: Int) -> Region {
        var end = last
        while end > first, lines[end].text.trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return Region(
            range: NSRange(
                location: lines[first].start,
                length: lines[end].contentEnd - lines[first].start
            ),
            text: lines[first...end].map(\.text).joined(separator: "\n")
        )
    }

    private struct FenceOpen {
        let marker: Character
        let mayHoldMermaid: Bool
    }

    /// Mirrors the detector's own fence parsing, on a single line at a time. Indentation is
    /// tolerated: a fenced block inside a list item is indented and is still a fenced block.
    private static func fenceOpen(_ line: String) -> FenceOpen? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmed.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count)
            .trimmingCharacters(in: .whitespaces)
            .prefix { !$0.isWhitespace }
            .lowercased()
        // An untagged fence is worth reading -- a diagram pasted into a plain block is ordinary --
        // and the detector's confidence gate is what turns down a block of shell script.
        return FenceOpen(marker: marker, mayHoldMermaid: info.isEmpty || info == "mermaid" || info == "mmd")
    }

    private static func closingFenceIndex(_ lines: [Line], after index: Int, marker: Character) -> Int? {
        lines.indices.dropFirst(index + 1).first { position in
            let line = lines[position].text.trimmingCharacters(in: .whitespaces)
            return line.count >= 3 && line.allSatisfy { $0 == marker }
        }
    }
}
