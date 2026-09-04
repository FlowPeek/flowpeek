import Foundation

/// What the panel says when a render fails.
///
/// `MermaidRenderError.errorDescription` stays what it always was — the line that goes to the log
/// and into a bug report, engine text and all. This is the same failure said in words someone who
/// did not write the parser can act on: a headline, the user's own offending line, one thing to try,
/// and mermaid's own output demoted to a disclosure. Pure, so both the copy selection and the line
/// quoting are testable without a WebView.
public struct MermaidFailurePresentation: Equatable, Sendable {
    public let localizationKey: String
    public let headline: String
    /// mermaid's 1-based line number, kept only when the source really has such a line.
    public let lineNumber: Int?
    /// The offending line, taken from the source rather than from mermaid's own excerpt — mermaid
    /// clips its excerpt mid-token, so the whole line is strictly more use.
    public let quotedLine: String?
    public let hint: String?
    /// The engine's own words. Never body copy: it is untranslated, it can be jison caret art, and
    /// `.unknownDiagramType` carries the entire selection back.
    public let engineDetails: String?
    public let recovery: MermaidRenderError.Recovery

    /// One line for surfaces with no room for the card — the AI window's inline error.
    public var plainSummary: String {
        guard let quotedLine else { return headline }
        return "\(headline) — \(quotedLine)"
    }

    /// Everything worth pasting into a bug report. The engine text is the only part that names the
    /// actual fault and the only part we never put on screen, so it has to be copyable from here.
    public var diagnosticReport: String {
        var lines = [headline, localizationKey]
        if let quotedLine {
            lines.append(lineNumber.map { "line \($0): \(quotedLine)" } ?? quotedLine)
        }
        if let engineDetails { lines.append(engineDetails) }
        return lines.joined(separator: "\n")
    }

    public init(
        localizationKey: String,
        headline: String,
        lineNumber: Int? = nil,
        quotedLine: String? = nil,
        hint: String? = nil,
        engineDetails: String? = nil,
        recovery: MermaidRenderError.Recovery
    ) {
        self.localizationKey = localizationKey
        self.headline = headline
        self.lineNumber = lineNumber
        self.quotedLine = quotedLine
        self.hint = hint
        self.engineDetails = engineDetails
        self.recovery = recovery
    }

    /// `source` is the normalised text that was handed to mermaid, so mermaid's line numbers index
    /// the same string; pass "" where there is no source to point at (an engine that never started).
    public static func make(_ error: MermaidRenderError, source: String = "") -> MermaidFailurePresentation {
        let key = error.localizationKey
        let headline = String(localized: String.LocalizationValue(Self.headlineKey(for: key)))
        let hint = String(localized: String.LocalizationValue(Self.hintKey(for: key)))
        switch error {
        case .engineMissing, .engineNotReady, .webContentTerminated, .renderProducedNoSVG:
            return .init(localizationKey: key, headline: headline, hint: hint, recovery: error.recovery)
        case .navigationFailed(let detail), .internalFailure(let detail):
            return .init(
                localizationKey: key,
                headline: headline,
                hint: hint,
                engineDetails: detail,
                recovery: error.recovery
            )
        case .inputTooLarge(let measured, let limit):
            return .init(
                localizationKey: key,
                headline: headline,
                hint: String(format: hint, measured, limit),
                recovery: error.recovery
            )
        case .timedOut(let seconds):
            return .init(
                localizationKey: key,
                headline: headline,
                hint: String(format: hint, seconds),
                recovery: error.recovery
            )
        case .edgeLimitExceeded(let detail):
            // mermaid states the limit in its own message; the ceiling we configured is the same
            // number and is the one we can say in Korean.
            return .init(
                localizationKey: key,
                headline: headline,
                hint: String(format: hint, MermaidRenderLimits.engineMaximumEdges),
                engineDetails: detail,
                recovery: error.recovery
            )
        case .unknownDiagramType(let detail):
            // The first line is the one that has to name a type, so it is the line to show — and
            // `detail` is "No diagram type detected … for text: <the whole selection>", which is
            // exactly what must not be echoed back.
            let first = excerpt(of: source, line: 1)
            return .init(
                localizationKey: key,
                headline: headline,
                lineNumber: first == nil ? nil : 1,
                quotedLine: first,
                hint: hint,
                engineDetails: detail,
                recovery: error.recovery
            )
        case .parseFailure(let message, let line):
            let lineCount = source.isEmpty ? 0 : source.components(separatedBy: "\n").count
            // A number past the end of the source points at nothing, so fall back to the headline
            // that claims no line at all rather than naming a line the user cannot find.
            guard let line, line >= 1, line <= lineCount else {
                let plain = "mermaid.render.error.parse"
                return .init(
                    localizationKey: key,
                    headline: String(localized: String.LocalizationValue(Self.headlineKey(for: plain))),
                    hint: String(localized: String.LocalizationValue(Self.hintKey(for: plain))),
                    engineDetails: message,
                    recovery: error.recovery
                )
            }
            return .init(
                localizationKey: key,
                headline: String(format: headline, line),
                lineNumber: line,
                quotedLine: excerpt(of: source, line: line),
                hint: hint,
                engineDetails: message,
                recovery: error.recovery
            )
        }
    }

    // MARK: - Keys

    private static let errorKeyPrefix = "mermaid.render.error."
    private static let ownKeyPrefix = "preview.failure."

    public static func headlineKey(for errorKey: String) -> String { slug(errorKey) + ".headline" }

    public static func hintKey(for errorKey: String) -> String { slug(errorKey) + ".hint" }

    private static func slug(_ errorKey: String) -> String {
        guard errorKey.hasPrefix(errorKeyPrefix) else { return ownKeyPrefix + errorKey }
        return ownKeyPrefix + errorKey.dropFirst(errorKeyPrefix.count)
    }

    /// Derived from the error's own keys, so a new failure code cannot arrive without copy: the
    /// localisation test walks this array against both catalogues.
    public static let localizationKeys: [String] =
        MermaidRenderError.localizationKeys.flatMap { [headlineKey(for: $0), hintKey(for: $0)] }
        + ["preview.failure.details", "preview.failure.copy-details", "preview.failure.copy-source", "preview.failure.retry"]

    // MARK: - Quoting

    /// Longer than this and the line stops being a glance and starts being a paragraph.
    static let maximumQuotedLength = 120

    static func excerpt(of source: String, line: Int) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        let text = lines[line - 1].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard text.count > maximumQuotedLength else { return text }
        return text.prefix(maximumQuotedLength) + "…"
    }
}
