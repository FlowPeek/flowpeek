import AppKit
import QuartzCore

@testable import FlowPeek

/// Where a peek's zoom actually puts the drawn content on screen, read from the layer itself.
///
/// Written once and shared, because it was written twice and both copies were wrong in the same
/// way. Each assumed the layer was transformed about its centre; AppKit positions a layer-backed
/// view's layer by its BOTTOM-LEFT corner, so `anchorPoint` is (0, 0) and the centred arithmetic
/// described a rectangle the app was never drawing. The production code made the same assumption,
/// so the tests and the bug agreed with each other and the suite stayed green while the preview
/// visibly grew out of the wrong corner of the screen.
///
/// So nothing here is assumed. The anchor, the position and the bounds are asked of the layer, and
/// the result is what Core Animation will render.
@MainActor
enum PeekZoomGeometry {
    /// The rect the zoom starts from, in screen coordinates, or nil if no zoom is running.
    ///
    /// Taken from the animation's own `fromValue`, so it is exact and owes nothing to how far along
    /// the 280ms ease-out the reading happens to be taken.
    static func start(of panel: NSPanel?) -> CGRect? {
        guard let panel,
              let container = panel.contentView as? ResizableContentView,
              let layer = container.content.layer,
              let zoom = layer.animation(forKey: "flowpeek.peek") as? CABasicAnimation,
              let from = (zoom.fromValue as? NSValue)?.caTransform3DValue else { return nil }
        return rect(of: from, on: layer, in: panel)
    }

    /// `transform` applied to `layer`, as a rectangle on the screen.
    ///
    /// The anchor is the one point the scale leaves alone, so the layer's origin corner closes in
    /// on it by the anchor's share of the scaled size; the matrix's translation then carries the
    /// whole thing. The panel's own frame turns the result from the stage's coordinates into the
    /// screen's -- and during a zoom that frame is the stage, which is why this is read rather than
    /// remembered from before.
    static func rect(of transform: CATransform3D, on layer: CALayer, in panel: NSPanel) -> CGRect {
        let width = layer.bounds.width * transform.m11
        let height = layer.bounds.height * transform.m22
        return CGRect(
            x: panel.frame.minX + layer.position.x - layer.anchorPoint.x * width + transform.m41,
            y: panel.frame.minY + layer.position.y - layer.anchorPoint.y * height + transform.m42,
            width: width,
            height: height
        )
    }
}
