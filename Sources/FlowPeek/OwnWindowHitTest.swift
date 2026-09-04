import AppKit

/// Whether a screen point lies over one of FlowPeek's own windows.
///
/// A global event monitor is documented not to see events delivered to its own application, but
/// that holds only while the application is active -- and every FlowPeek surface is a
/// non-activating panel shown over somebody else's window, so FlowPeek's own clicks and drags do
/// arrive at its global monitors. Dismissal logic that does not check this closes the surface the
/// user is interacting with: dragging the preview's resize edge closed the preview.
///
/// The frames are tested directly rather than asking the window server: measured,
/// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` reported the window *underneath* for a
/// point squarely inside a visible non-activating panel (48122 for a point in a panel numbered
/// 48328), so it cannot answer this question. Z-order is not consulted, which is right here --
/// FlowPeek's surfaces float above other applications, so a point inside one of them is on it.
@MainActor
enum OwnWindowHitTest {
    /// A couple of points of slack, so the very edge of a resize handle still counts as ours.
    private static let tolerance: CGFloat = 2

    static func contains(_ point: CGPoint) -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }
}
