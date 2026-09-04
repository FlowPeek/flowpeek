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
        case nothingToPreview
    }

    public static func decide(pasteboardText: String?, hasCachedDiagram: Bool) -> Decision {
        // `MermaidSource` is the same validation the badge path applies, limits included, so a live
        // read cannot open something a witnessed copy would have been refused for.
        if let pasteboardText, let source = try? MermaidSource(rawValue: pasteboardText) {
            return .preview(source)
        }
        if hasCachedDiagram { return .previewCached }
        return .nothingToPreview
    }
}
