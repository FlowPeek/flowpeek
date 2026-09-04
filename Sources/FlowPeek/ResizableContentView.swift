import AppKit

/// Gives a borderless window the edge and corner drags a titled one gets for free.
///
/// A borderless window has no frame view to track a resize in: `.resizable` on one only permits a
/// programmatic or accessibility resize, and `NSWindow` never turns an edge drag into a resize.
/// Measured on a 720x520 panel, dragging the bottom-right corner left it at 720x520 — first with the
/// SwiftUI hosting view answering the hit, and again with the hit declined so AppKit could take it.
/// So the drag is tracked here.
///
/// The ring is narrow on purpose: the chrome buttons sit 14 points in from the edge, so nothing
/// interactive falls inside it, and `isMovableByWindowBackground` still moves the window from
/// anywhere further in.
final class ResizableContentView: NSView {
    /// The width AppKit itself uses for a titled window's resize border.
    private static let edge: CGFloat = 6
    /// How far in from both edges still counts as a corner.
    ///
    /// The surfaces are drawn with a 20-point corner radius, so the frame's own corner is outside
    /// the painted glass and a click there passes through to whatever is behind -- measured: the
    /// window never saw it. Reaching this far in puts the corner grab on painted pixels, where the
    /// diagonal drag people expect actually lands.
    private static let corner: CGFloat = 20

    private struct Grab {
        let mask: Edges
        let origin: CGPoint
        let frame: CGRect
    }

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    private var grab: Grab?

    init(content: NSView) {
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Tracking

    /// Claims the ring for this view; everything further in goes to the content as usual.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return edges(at: local).isEmpty ? super.hitTest(point) : self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let mask = edges(at: local)
        guard !mask.isEmpty, let window else {
            super.mouseDown(with: event)
            return
        }
        grab = Grab(mask: mask, origin: NSEvent.mouseLocation, frame: window.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let window else {
            super.mouseDragged(with: event)
            return
        }
        let now = NSEvent.mouseLocation
        let dx = now.x - grab.origin.x
        let dy = now.y - grab.origin.y
        var frame = grab.frame

        // AppKit's y grows upward, so the "bottom" edge moves the origin and the "top" edge only
        // changes the height.
        if grab.mask.contains(.right) { frame.size.width += dx }
        if grab.mask.contains(.left) { frame.size.width -= dx; frame.origin.x += dx }
        if grab.mask.contains(.top) { frame.size.height += dy }
        if grab.mask.contains(.bottom) { frame.size.height -= dy; frame.origin.y += dy }

        // The window's limits are expressed for its content, which is the whole frame here.
        let minimum = window.contentMinSize
        if frame.width < minimum.width {
            if grab.mask.contains(.left) { frame.origin.x -= minimum.width - frame.width }
            frame.size.width = minimum.width
        }
        if frame.height < minimum.height {
            if grab.mask.contains(.bottom) { frame.origin.y -= minimum.height - frame.height }
            frame.size.height = minimum.height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard grab != nil else {
            super.mouseUp(with: event)
            return
        }
        grab = nil
        // The size memory listens for `windowDidResize`, which `setFrame` already posted; nothing
        // else has to be announced here.
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width
        let h = bounds.height
        let e = Self.edge
        // No public diagonal resize cursor exists, so a corner takes the cursor of its longer edge.
        addCursorRect(CGRect(x: 0, y: 0, width: e, height: h), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: w - e, y: 0, width: e, height: h), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: 0, y: 0, width: w, height: e), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: 0, y: h - e, width: w, height: e), cursor: .resizeUpDown)
    }

    // MARK: - Geometry

    private func edges(at point: NSPoint) -> Edges {
        guard bounds.contains(point) else { return [] }
        let left = point.x - bounds.minX
        let right = bounds.maxX - point.x
        let bottom = point.y - bounds.minY
        let top = bounds.maxY - point.y

        // A corner first: near both a vertical and a horizontal edge, with the wider reach.
        let nearX: Edges? = left <= Self.corner ? .left : (right <= Self.corner ? .right : nil)
        let nearY: Edges? = bottom <= Self.corner ? .bottom : (top <= Self.corner ? .top : nil)
        if let nearX, let nearY { return [nearX, nearY] }

        var mask: Edges = []
        if left <= Self.edge { mask.insert(.left) }
        if right <= Self.edge { mask.insert(.right) }
        if bottom <= Self.edge { mask.insert(.bottom) }
        if top <= Self.edge { mask.insert(.top) }
        return mask
    }
}
