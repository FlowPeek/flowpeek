import Foundation

/// Turning a file on disk into a diagram FlowPeek can draw.
///
/// The reading itself is trivial; what is worth keeping in one place, and testing, is everything
/// around it -- how big a file is worth opening, what a preview should be called, and the fact that
/// a file which is not a diagram has to be refused with the same words the rest of the app uses.
public enum DiagramFile {
    /// Larger than this is not a diagram somebody is going to look at; it is a file that happens to
    /// end in `.mmd`. The renderer has its own limit and would refuse anyway -- this one exists so
    /// that a gigabyte is never read into memory to find that out.
    public static let maximumBytes = 2 * 1024 * 1024

    public enum Failure: Error, Equatable {
        case tooLarge(bytes: Int)
        case notText
    }

    /// The name a preview opened from a file wears: the file's own, without the extension, which is
    /// what the person who named it would call it. Empty names fall back to the caller's default,
    /// because a window titled with nothing is a window nobody can find in a list.
    public static func title(for url: URL, fallback: String) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A path that names no file answers with a separator or a dot rather than with nothing, so
        // those are spelled out. Anything else is kept as it is -- a file whose whole name is
        // `.mmd` is a hidden file called `.mmd`, and Foundation is right not to read a leading dot
        // as an extension.
        return ["", "/", ".", ".."].contains(stem) ? fallback : stem
    }

    /// Checks the size before reading, so a file that is far too big costs an attribute lookup
    /// rather than the memory to hold it.
    public static func read(
        contentsOf url: URL,
        attributes: (URL) -> Int? = { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        },
        contents: (URL) -> String? = { url in try? String(contentsOf: url, encoding: .utf8) }
    ) throws(Failure) -> String {
        if let size = attributes(url), size > maximumBytes { throw .tooLarge(bytes: size) }
        guard let text = contents(url) else { throw .notText }
        return text
    }
}
