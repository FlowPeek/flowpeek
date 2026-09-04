import Foundation

public struct MermaidSource: Equatable, Sendable {
    /// Compared in UTF-16 code units, the unit mermaid's own `maxTextSize` uses.
    public static let maximumCharacters = 100_000
    public static let maximumLines = 5_000
    public static let maximumLineLength = 20_000

    public enum ValidationError: LocalizedError, Equatable {
        case empty
        case tooLarge(Int)
        case tooManyLines(Int)
        case lineTooLong(Int)
        case unsupportedSyntax

        public var errorDescription: String? {
            switch self {
            case .empty: "The selected content is empty."
            case .tooLarge(let count): "The diagram is too large (\(count)/\(MermaidSource.maximumCharacters) characters)."
            case .tooManyLines(let count): "The diagram has too many lines (\(count)/\(MermaidSource.maximumLines))."
            case .lineTooLong(let count): "A line is too long (\(count)/\(MermaidSource.maximumLineLength) characters)."
            case .unsupportedSyntax: "The selection does not look like Mermaid syntax."
            }
        }
    }

    public let text: String

    public init(rawValue: String, requireRecognizedDiagram: Bool = true) throws {
        // The detector declines to examine anything this large and hands back nothing, which would
        // otherwise be reported as an empty selection rather than an oversized one.
        let raw = rawValue.utf16.count
        guard raw <= MermaidDetector.maximumInputCharacters else { throw ValidationError.tooLarge(raw) }
        let detection = MermaidDetector.detect(rawValue)
        let normalized = detection.extractedSource
        guard !normalized.isEmpty else { throw ValidationError.empty }
        let units = normalized.utf16.count
        guard units <= Self.maximumCharacters else { throw ValidationError.tooLarge(units) }
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count <= Self.maximumLines else { throw ValidationError.tooManyLines(lines.count) }
        if let longest = lines.map(\.utf16.count).max(), longest > Self.maximumLineLength {
            throw ValidationError.lineTooLong(longest)
        }
        if requireRecognizedDiagram, detection.confidence < .likely {
            throw ValidationError.unsupportedSyntax
        }
        text = normalized
    }

    public static func looksLikeMermaid(_ text: String) -> Bool {
        MermaidDetector.looksLikeMermaid(text)
    }
}
