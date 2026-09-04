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
