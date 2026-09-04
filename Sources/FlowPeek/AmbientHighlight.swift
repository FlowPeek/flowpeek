import AppKit
import FlowPeekCore
import SwiftUI

/// The outline that sits over a detected block, plus a small hint naming the key that opens it.
/// Click-through everywhere except the hint, so holding the modifier never blocks the app underneath.
@MainActor
final class AmbientHighlightCoordinator {
    var onActivate: (() -> Void)?

    /// How far the stroke sits outside the block, so it frames the text instead of touching it.
    private static let inset: CGFloat = 5
    private static let hintBarHeight: CGFloat = 20
    private static let gap: CGFloat = 4
    private static let fade: TimeInterval = 0.14

    private var panel: NSPanel?
    private var model = AmbientHighlightModel()

    func show(_ candidate: AmbientCandidate, shortcut: String) {
        // A block scrolled half past the bottom of the display, or simply taller than it, is clipped
        // to what is on screen. Moving the panel instead — which is what keeping a whole window
        // visible would do — drew the frame around unrelated text further up the page.
        guard let outline = ScreenGeometry.clip(
            candidate.bounds.insetBy(dx: -Self.inset, dy: -Self.inset),
            screenFrames: NSScreen.screens.map(\.frame)
        ), outline.width >= AmbientPeekPolicy.minimumSize.width,
              outline.height >= AmbientPeekPolicy.minimumSize.height else {
            hide()
            return
        }

        model.keyword = candidate.detection.diagramKeyword
        model.shortcut = shortcut
        model.anchor = candidate.anchor

        let chrome = Self.hintBarHeight + Self.gap
        let panel = panel ?? makePanel()

        // AppKit's y grows upward while a VStack lays its first child out at the top, so the panel
        // has to extend *above* the block and the outline row has to be exactly the block's height.
        // Extending below instead pushed the outline down by the height of the hint.
        let placement = self.placement(for: outline, chrome: chrome)
        model.placement = placement
        model.outlineHeight = outline.height

        // Whatever the hint does, the outline row keeps the block's own rectangle: the panel grows
        // away from it, never over it.
        let origin: CGPoint
        let size: CGSize
        switch placement {
        case .above:
            origin = outline.origin
            size = CGSize(width: outline.width, height: outline.height + chrome)
        case .below:
            origin = CGPoint(x: outline.minX, y: outline.minY - chrome)
            size = CGSize(width: outline.width, height: outline.height + chrome)
        case .inside:
            origin = outline.origin
            size = outline.size
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: false)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// Where the hint can go without displacing the outline. A block that fills the display's height
    /// leaves room for neither bar, so the last case puts the hint inside the frame rather than
    /// letting it push the outline off the text.
    private func placement(for outline: CGRect, chrome: CGFloat) -> AmbientHighlightModel.Placement {
        guard let screen = ScreenGeometry.visibleFrame(
            containing: CGPoint(x: outline.midX, y: outline.midY),
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        ) else { return .above }
        if outline.maxY + chrome <= screen.maxY { return .above }
        if outline.minY - chrome >= screen.minY { return .below }
        return .inside
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = NSHostingController(
            rootView: AmbientHighlightView(
                model: model,
                hintBarHeight: Self.hintBarHeight,
                gap: Self.gap,
                activate: { [weak self] in
                    self?.hide()
                    self?.onActivate?()
                }
            )
        )
        self.panel = panel
        return panel
    }
}

@MainActor
final class AmbientHighlightModel: ObservableObject {
    /// Where the hint sits relative to the outline. `inside` is for a block that reaches both edges
    /// of the display: there is nowhere to put a bar without moving the frame off the text.
    enum Placement {
        case above
        case below
        case inside
    }

    @Published var keyword: String?
    @Published var shortcut = ""
    @Published var outlineHeight: CGFloat = 0
    @Published var placement: Placement = .above
    /// What the frame is actually around. A caret-anchored read frames the line or the pane the
    /// caret is in, never the block, so the hint says where the diagram came from instead of
    /// letting the outline claim to be drawn around it.
    @Published var anchor: AmbientCandidate.Anchor = .pointer
}

private struct AmbientHighlightView: View {
    @ObservedObject var model: AmbientHighlightModel
    let hintBarHeight: CGFloat
    let gap: CGFloat
    let activate: () -> Void

    var body: some View {
        switch model.placement {
        case .above:
            stack { hint; outline }
        case .below:
            stack { outline; hint }
        case .inside:
            outline.overlay(alignment: .topLeading) { hint }
        }
    }

    private func stack(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: gap, content: content)
            // Pinned, not centred: a centred stack would spread the slack evenly and shift the
            // outline off the text by half the hint's height.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var outline: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.07))
            )
            .frame(height: model.outlineHeight)
            // Decoration over someone else's window: it must never eat a click.
            .allowsHitTesting(false)
    }

    private var hint: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.keyword ?? String(localized: "ambient.hint.generic"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if model.anchor == .caret {
                    Text(String(localized: "ambient.hint.caret"))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .opacity(0.85)
                }
                Text(model.shortcut)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 8)
            .frame(height: hintBarHeight)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: model.anchor == .caret ? "ambient.hint.help.caret" : "ambient.hint.help"))
    }
}
