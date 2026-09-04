import CoreGraphics

/// Remembers how big the user made a preview, so the next one opens at that size.
///
/// Kept pure and separate from `UserDefaults` so the awkward parts -- a size saved on a large
/// display and restored on a small one, a corrupt or half-written value, a size below the surface's
/// own minimum -- are decided by something that can be tested rather than by whatever the window
/// server happens to allow.
public enum PreviewSizeMemory {
    /// Which surface a remembered size belongs to. The quick panel and the promoted window are
    /// different shapes with different defaults, so they remember separately.
    public enum Surface: String, CaseIterable, Sendable {
        case quick
        case window

        public var widthKey: String { "flowpeek.preview.\(rawValue).width" }
        public var heightKey: String { "flowpeek.preview.\(rawValue).height" }
    }

    /// How much of a display a restored preview may take up. A preview that fills the screen edge
    /// to edge stops reading as a preview, and on a smaller display it would be unusable.
    public static let maximumScreenFraction: CGFloat = 0.92

    /// The size to open at.
    ///
    /// - Parameters:
    ///   - stored: what was remembered, or nil on a first run.
    ///   - fallback: the surface's designed size, used when nothing sensible was remembered.
    ///   - minimum: the surface's own minimum; a restored size is never smaller.
    ///   - visibleFrame: the display the preview will open on, or nil when that is not yet known.
    public static func size(
        stored: CGSize?,
        fallback: CGSize,
        minimum: CGSize,
        visibleFrame: CGRect?
    ) -> CGSize {
        var size = fallback
        if let stored, stored.width.isFinite, stored.height.isFinite, stored.width > 0, stored.height > 0 {
            size = stored
        }
        size.width = max(size.width, minimum.width)
        size.height = max(size.height, minimum.height)
        guard let visibleFrame, isUsable(visibleFrame) else { return size }
        // The cap yields to the minimum: a surface that cannot fit its own minimum on this display
        // is better slightly too large than unusable.
        let capped = CGSize(
            width: max(minimum.width, min(size.width, visibleFrame.width * maximumScreenFraction)),
            height: max(minimum.height, min(size.height, visibleFrame.height * maximumScreenFraction))
        )
        return capped
    }

    /// Whether a size is worth remembering. Nothing degenerate is stored, so a bad value can never
    /// be read back.
    public static func shouldRemember(_ size: CGSize, minimum: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite else { return false }
        return size.width >= minimum.width && size.height >= minimum.height
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite && rect.width > 1 && rect.height > 1
    }
}
