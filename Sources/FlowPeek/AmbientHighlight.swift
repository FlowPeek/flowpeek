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
        model.keyword = candidate.detection.diagramKeyword
        model.shortcut = shortcut

        let outline = candidate.bounds.insetBy(dx: -Self.inset, dy: -Self.inset)
        let chrome = Self.hintBarHeight + Self.gap
        let panel = panel ?? makePanel()

        // AppKit's y grows upward while a VStack lays its first child out at the top, so the panel
        // has to extend *above* the block and the outline row has to be exactly the block's height.
        // Extending below instead pushed the outline down by the height of the hint.
        let hintFitsAbove = fits(
            top: outline.maxY + chrome,
            on: ScreenGeometry.visibleFrame(containing: outline.origin, visibleFrames: visibleFrames())
        )
        model.hintOnTop = hintFitsAbove
        model.outlineHeight = outline.height

        let origin = CGPoint(x: outline.minX, y: hintFitsAbove ? outline.minY : outline.minY - chrome)
        let size = CGSize(width: outline.width, height: outline.height + chrome)
        panel.setFrame(
            CGRect(
                origin: ScreenGeometry.clamp(
                    origin: origin,
                    size: size,
                    visibleFrames: visibleFrames(),
                    inset: 2
                ),
                size: size
            ),
            display: false
        )

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

    private func visibleFrames() -> [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    private func fits(top: CGFloat, on screen: CGRect?) -> Bool {
        guard let screen else { return true }
        return top <= screen.maxY
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
    @Published var keyword: String?
    @Published var shortcut = ""
    @Published var outlineHeight: CGFloat = 0
    /// False when the block is near the top of the display and the hint has to go underneath.
    @Published var hintOnTop = true
}

private struct AmbientHighlightView: View {
    @ObservedObject var model: AmbientHighlightModel
    let hintBarHeight: CGFloat
    let gap: CGFloat
    let activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            if model.hintOnTop {
                hint
                outline
            } else {
                outline
                hint
            }
        }
        // Pinned, not centred: a centred stack would spread the slack evenly and shift the outline
        // off the text by half the hint's height.
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
        .help("ambient.hint.help")
    }
}
