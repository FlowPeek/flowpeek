import AppKit
import FlowPeekCore
import SwiftUI

@MainActor
final class SelectionOverlayCoordinator {
    var onRender: ((SelectionSnapshot) -> Void)?
    private var panel: NSPanel?
    private var snapshot: SelectionSnapshot?

    private static let buttonSize = CGSize(width: 38, height: 38)

    func show(for snapshot: SelectionSnapshot) {
        self.snapshot = snapshot
        let panel = panel ?? makePanel()
        // A degenerate AX rect is worse than none: `CGRect.intersects` is false for any empty rect, so a
        // (0,0,0,0) bounds silently defeated the screen lookup and pinned the button to the origin.
        let mouse = snapshot.anchorPoint == .zero ? NSEvent.mouseLocation : snapshot.anchorPoint
        let anchor = snapshot.screenBounds.flatMap { ScreenGeometry.isUsable($0) ? $0 : nil }
            ?? CGRect(origin: mouse, size: .zero)
        let size = panel.frame.size == .zero ? Self.buttonSize : panel.frame.size
        let origin = ScreenGeometry.clamp(
            origin: CGPoint(x: anchor.maxX + 8, y: anchor.midY - size.height / 2),
            size: size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil); snapshot = nil }

    /// Whether a screen point lands on the button, so the dismissal monitor can tell a click that
    /// clears the selection from a click that is trying to open the preview.
    func contains(_ point: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -2, dy: -2).contains(point)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 38, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = NSHostingController(rootView: OverlayButton { [weak self] in
            guard let self, let snapshot = self.snapshot else { return }
            self.onRender?(snapshot)
        })
        // The hosting controller resizes the panel to the SwiftUI view's fitting size, which is zero before
        // the first layout pass — without this the first show is ordered front collapsed.
        panel.setContentSize(Self.buttonSize)
        self.panel = panel
        return panel
    }
}

private struct OverlayButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(GlassBackground().clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.separator.opacity(0.65)))
        }
        .buttonStyle(.plain)
        .help("preview.mermaid")
        // `.help()` is NSAccessibilityHelp, a hint. This glyph is the whole control, so without a
        // label the one button the selection route offers announces as an unnamed button.
        .accessibilityLabel(Text("preview.mermaid"))
        .padding(2)
    }
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 11
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
