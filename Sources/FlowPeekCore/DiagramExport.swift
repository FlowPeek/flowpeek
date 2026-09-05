import CoreGraphics
import Foundation

/// What a diagram can be turned into on its way out of the preview.
///
/// Three, not one, because the destinations disagree: a chat window takes a bitmap and nothing
/// else, a page layout would rather have the vector, and anyone who wants to keep editing the
/// drawing wants the SVG the engine already handed back.
public enum DiagramExportFormat: String, CaseIterable, Sendable {
    case png
    case pdf
    case svg

    public var fileExtension: String { rawValue }

    /// The uniform type identifier, spelled out rather than read from `UTType`, so the mapping stays
    /// in FlowPeekCore and can be asserted without AppKit.
    public var contentType: String {
        switch self {
        case .png: "public.png"
        case .pdf: "com.adobe.pdf"
        case .svg: "public.svg-image"
        }
    }

    /// Whether producing this means drawing the diagram again. Only the SVG is already in hand.
    public var needsRedraw: Bool { self != .svg }

    /// The order the clipboard advertises. First is what an application that understands several of
    /// them will take, so PNG leads: pasting into a message or a document is the case that has to
    /// just work, and the two vector types stay available to whoever asks for them by name.
    public static let clipboardOrder: [DiagramExportFormat] = [.png, .pdf, .svg]
}

/// The name a saved diagram arrives with. Preview titles come from the app that was being read —
/// a page title, a window title, a clipboard label — so they carry characters a file name cannot.
public enum DiagramExportName {
    /// Used when the title contributes nothing usable, which is also the untitled case.
    public static let fallback = "diagram"
    /// Well under the 255-byte limit, and short enough that the save panel shows all of it.
    public static let maximumLength = 60

    public static func baseName(for title: String) -> String {
        var cleaned = ""
        var pendingSpace = false
        for character in title.unicodeScalars {
            // `/` is the path separator and `:` is still the separator HFS-era APIs report, so both
            // come back from the panel mangled rather than saved. Newlines and tabs arrive from
            // multi-line window titles.
            let forbidden = character == "/" || character == ":" || character == "\\"
            if forbidden || CharacterSet.whitespacesAndNewlines.contains(character)
                || CharacterSet.controlCharacters.contains(character) {
                pendingSpace = !cleaned.isEmpty
                continue
            }
            if pendingSpace {
                cleaned.append(" ")
                pendingSpace = false
            }
            cleaned.unicodeScalars.append(character)
        }
        // A leading dot hides the file in Finder, which is never what a title meant to say.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : cleaned
    }

    public static func fileName(for title: String, format: DiagramExportFormat) -> String {
        baseName(for: title) + "." + format.fileExtension
    }
}

/// How large a bitmap export is.
public enum DiagramExportImage {
    /// The preview draws vectors, but a pasted bitmap is judged on a Retina screen, and a 1x PNG of
    /// a flowchart's 15px labels is visibly soft there.
    public static let scale: Double = 2
    /// A ceiling on either edge. A 4000x3000pt diagram at 2x would be 96 MB of ARGB before it is
    /// ever encoded, so past this the scale gives way rather than the export.
    public static let maximumEdge: Double = 8192

    /// The pixel size a bitmap export of `size` points should have, scaled down proportionally if
    /// 2x would cross `maximumEdge`. Zero or non-finite input yields nothing to draw.
    public static func pixelSize(for size: CGSize) -> CGSize? {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        var factor = scale
        let longest = max(width, height) * factor
        if longest > maximumEdge { factor *= maximumEdge / longest }
        return CGSize(
            width: max(1, (width * factor).rounded()),
            height: max(1, (height * factor).rounded())
        )
    }
}

/// The SVG the engine returns is a fragment of a page: it is attached to a live document, so it can
/// rely on the document for its namespace and needs no prolog. A file on disk cannot, and an
/// `.svg` that opens as XML markup in a text editor instead of a drawing is the usual result.
public enum DiagramSVGDocument {
    public static let prolog = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>"
    public static let namespace = "http://www.w3.org/2000/svg"

    public static func standalone(_ svg: String) -> String {
        var markup = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        if !markup.contains("xmlns=") {
            // mermaid 11 emits `xmlns` itself; this covers a renderer that does not, and the
            // `<svg` prefix is guaranteed by the glue's own post-condition check.
            markup = markup.replacingOccurrences(of: "<svg", with: "<svg xmlns=\"\(namespace)\"", options: [], range: markup.range(of: "<svg"))
        }
        return prolog + "\n" + markup + "\n"
    }
}

/// The diagram as words.
///
/// A screen reader gets nothing out of the drawing itself: the engine hands Swift a scrubbed SVG,
/// and inside it the diagram's own words are the character data of its `<text>` elements — plus,
/// for the types that emit HTML labels even with `htmlLabels` off, of its `<foreignObject>`s. The
/// root carries `role="graphics-document document"` and an `aria-roledescription` naming the
/// diagram type, which is the only place the *kind* of drawing is written down in the markup.
///
/// Read once per render, never per layout pass: this walks the whole markup, and a large flowchart
/// is a hundred kilobytes of it.
public enum DiagramNarration {
    /// Enough labels to tell one diagram from another; a 400-node chart read out node by node is
    /// not a description, it is a wall.
    public static let maximumLabels = 40
    /// Roughly a long sentence, so the value is over before the panel is.
    public static let maximumLength = 400
    /// The markup budget. A drawing can be mostly path data — the labels stop arriving long before
    /// the bytes do — so the walk gives up rather than scanning megabytes for nothing.
    public static let maximumScan = 200_000

    /// The elements whose character data is the diagram's text. Everything else — `<style>` above
    /// all, which mermaid ships as one element inside the SVG — is markup, not words.
    private static let containers: Set<String> = ["text", "foreignobject"]

    public struct Reading: Equatable, Sendable {
        /// The diagram type as `aria-roledescription` spells it, tidied for reading out loud.
        public let kind: String?
        public let labels: [String]
        /// Whether a cap cut the reading short, so the value can say so rather than stopping
        /// mid-diagram as if that were all of it.
        public let isTruncated: Bool

        public init(kind: String?, labels: [String], isTruncated: Bool) {
            self.kind = kind
            self.labels = labels
            self.isTruncated = isTruncated
        }

        /// The labels as one string, capped again by length: 40 short labels and 40 sentences are
        /// very different amounts of speech.
        public var spoken: String? {
            guard !labels.isEmpty else { return nil }
            var sentence = ""
            var cut = isTruncated
            for label in labels {
                let next = sentence.isEmpty ? label : sentence + ", " + label
                if next.count > DiagramNarration.maximumLength {
                    cut = true
                    break
                }
                sentence = next
            }
            if sentence.isEmpty {
                sentence = String(labels[0].prefix(DiagramNarration.maximumLength))
                cut = true
            }
            return cut ? sentence + "…" : sentence
        }
    }

    public static func read(_ svg: String) -> Reading {
        let found = labels(in: svg)
        return Reading(kind: kind(in: svg), labels: found.words, isTruncated: found.truncated)
    }

    /// `aria-roledescription="flowchart-v2"` is the engine's own name for what it drew. The version
    /// suffix and the hyphens are spelling, not meaning, and both are read out as written.
    public static func kind(in svg: String) -> String? {
        guard let value = attribute("aria-roledescription", in: svg) else { return nil }
        var words = value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(String.init)
        if let last = words.last, last.count > 1, last.hasPrefix("v"), last.dropFirst().allSatisfy(\.isNumber) {
            words.removeLast()
        }
        let kind = words.joined(separator: " ")
        return kind.isEmpty ? nil : kind
    }

    private static func attribute(_ name: String, in svg: String) -> String? {
        guard let start = svg.range(of: name + "=\"", options: [.caseInsensitive]),
              let end = svg.range(of: "\"", range: start.upperBound..<svg.endIndex) else { return nil }
        let raw = String(svg[start.upperBound..<end.lowerBound])
        return decodeEntities(in: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One pass, no XML parser: the markup is a fragment, and `XMLParser` rejects the whole document
    /// over a single unescaped `&` in a label — which is exactly the diagram whose words matter.
    private static func labels(in svg: String) -> (words: [String], truncated: Bool) {
        var words: [String] = []
        var current = ""
        var depth = 0
        var scanned = 0
        var index = svg.startIndex
        while index < svg.endIndex {
            if scanned >= maximumScan || words.count >= maximumLabels { return (words, true) }
            let character = svg[index]
            guard character == "<" else {
                if depth > 0 { current.append(character) }
                scanned += 1
                index = svg.index(after: index)
                continue
            }
            guard let terminator = svg[index...].firstIndex(of: ">") else { break }
            let tag = svg[svg.index(after: index)..<terminator]
            let name = elementName(of: tag)
            if containers.contains(name) {
                if tag.hasPrefix("/") {
                    depth = max(0, depth - 1)
                    if depth == 0 {
                        if let word = tidy(current) { words.append(word) }
                        current = ""
                    }
                } else if !tag.hasSuffix("/") {
                    if depth == 0 { current = "" }
                    depth += 1
                }
            } else if depth > 0 {
                // Every other tag inside a label — a `<tspan>` per line, a `<br/>` in an HTML one —
                // is a word boundary. Without this a two-line node label reads as one run-on word.
                current.append(" ")
            }
            scanned += svg.distance(from: index, to: terminator)
            index = svg.index(after: terminator)
        }
        return (words, false)
    }

    private static func elementName(of tag: Substring) -> String {
        var name = tag
        if name.hasPrefix("/") { name = name.dropFirst() }
        let stop = name.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? name.endIndex
        return name[name.startIndex..<stop].lowercased()
    }

    private static func tidy(_ raw: String) -> String? {
        let collapsed = decodeEntities(in: raw)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Only what the scrubbed markup can actually contain. The engine serialises through the DOM,
    /// so a label's `&` arrives as `&amp;` and its quotes as numeric references.
    private static func decodeEntities(in raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var result = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "&", let end = raw[index...].firstIndex(of: ";") else {
                result.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            let entity = raw[raw.index(after: index)..<end]
            if let replacement = named[entity.lowercased()] {
                result.append(replacement)
            } else if entity.hasPrefix("#"), let scalar = scalar(of: entity.dropFirst()) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append(contentsOf: raw[index...end])
            }
            index = raw.index(after: end)
        }
        return result
    }

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    private static func scalar(of digits: Substring) -> Unicode.Scalar? {
        let hexadecimal = digits.hasPrefix("x") || digits.hasPrefix("X")
        let body = hexadecimal ? digits.dropFirst() : digits
        guard let value = UInt32(body, radix: hexadecimal ? 16 : 10) else { return nil }
        return Unicode.Scalar(value)
    }
}
