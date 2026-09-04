/// What a deliberately asked-for clipboard preview should open.
///
/// Separate from the watcher's rules on purpose. The badge is unsolicited, so it only ever speaks
/// for a copy FlowPeek witnessed; this runs because the user pressed the shortcut or picked the menu
/// item, and it has to answer for whatever is on the pasteboard now — including a diagram copied
/// before FlowPeek was launched, which the poller never sees because it starts by writing off
/// everything already on the pasteboard.
public enum ClipboardPreviewPolicy {
    public enum Decision: Equatable, Sendable {
        /// What is on the pasteboard right now is a diagram; show that.
        case preview(MermaidSource)
        /// Nothing usable on the pasteboard, but a copy the watcher already blessed is still in
        /// memory — the diagram copied before the watch was switched off.
        case previewCached
        /// The pasteboard holds a diagram that cannot be drawn, and the reason has to be said out
        /// loud. Not folded into `nothingToPreview`, and not allowed to fall back to the remembered
        /// copy: answering a key press by opening a *different* diagram, or by claiming the
        /// clipboard is empty when a 150k-character flowchart is sitting on it, is the kind of
        /// wrong answer that sends people looking for a bug in their diagram.
        case refused(MermaidSource.ValidationError)
        case nothingToPreview
    }

    public static func decide(pasteboardText: String?, hasCachedDiagram: Bool) -> Decision {
        guard let pasteboardText, !pasteboardText.isEmpty else { return fallback(hasCachedDiagram) }
        do {
            // `MermaidSource` is the same validation the badge path applies, limits included, so a
            // live read cannot open something a witnessed copy would have been refused for.
            return .preview(try MermaidSource(rawValue: pasteboardText))
        } catch MermaidSource.ValidationError.unsupportedSyntax, MermaidSource.ValidationError.empty {
            // Prose, a URL, a shopping list: there is no diagram here to report anything about, so
            // the remembered copy is still the best answer to the key that was pressed.
            return fallback(hasCachedDiagram)
        } catch let error as MermaidSource.ValidationError {
            // A size complaint is only true if a diagram is what was copied. The length limits are
            // checked before the syntax is looked at, so a novel on the pasteboard comes back as
            // "too large" -- and telling somebody their *diagram* is too big sends them looking for
            // a fault in a diagram they never copied. The detector reads from the first lines, so a
            // prefix settles the question without walking the whole paste.
            guard looksLikeADiagram(pasteboardText) else { return fallback(hasCachedDiagram) }
            return .refused(error)
        } catch {
            return fallback(hasCachedDiagram)
        }
    }

    /// Enough to reach a starter line and its first statements; the detector looks no further.
    private static let probeCharacters = 4000

    private static func looksLikeADiagram(_ text: String) -> Bool {
        MermaidSource.looksLikeMermaid(String(text.prefix(probeCharacters)))
    }

    private static func fallback(_ hasCachedDiagram: Bool) -> Decision {
        hasCachedDiagram ? .previewCached : .nothingToPreview
    }
}
