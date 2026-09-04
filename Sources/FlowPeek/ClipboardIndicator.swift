import AppKit
import FlowPeekCore
import SwiftUI

/// A transient HUD in the top-right of the active screen: "this copy is a diagram, here is the key
/// that opens it". It never takes focus, never blocks a click it does not own, and retires itself.
@MainActor
final class ClipboardIndicatorCoordinator {
    var onActivate: (() -> Void)?

    static let size = CGSize(width: 296, height: 56)
    static let visibleDuration: TimeInterval = 5
    private static let fadeDuration: TimeInterval = 0.18

    private var panel: NSPanel?
    private var model = IndicatorModel()
    private var dismissal: Task<Void, Never>?

    func show(keyword: String?, shortcut: String) {
        model.keyword = keyword
        model.shortcut = shortcut
        let panel = panel ?? makePanel()
        panel.setFrame(CGRect(origin: placement(for: panel), size: Self.size), display: false)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
        scheduleDismissal()
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// Hovering holds it open; leaving restarts the clock, the way a notification behaves.
    private func setHovering(_ hovering: Bool) {
        if hovering {
            dismissal?.cancel()
            dismissal = nil
        } else if panel?.isVisible == true {
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleDuration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func placement(for panel: NSPanel) -> CGPoint {
        let frames = NSScreen.screens.map(\.visibleFrame)
        let target = ScreenGeometry.visibleFrame(containing: NSEvent.mouseLocation, visibleFrames: frames)
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: Self.size)
        return ScreenGeometry.indicatorOrigin(size: Self.size, in: target)
    }

    private func makePanel() -> NSPanel {
        let panel = FlowPeekGlassPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above ordinary windows and full-screen content, below the menu bar itself.
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = NSHostingController(
            rootView: ClipboardIndicatorView(
                model: model,
                activate: { [weak self] in
                    self?.hide()
                    self?.onActivate?()
                },
                hover: { [weak self] hovering in self?.setHovering(hovering) }
            )
        )
        panel.setContentSize(Self.size)
        self.panel = panel
        return panel
    }
}

/// A reference model so the hosting controller is built once and the text can change per copy.
@MainActor
final class IndicatorModel: ObservableObject {
    @Published var keyword: String?
    @Published var shortcut: String = ""
}

private struct ClipboardIndicatorView: View {
    @ObservedObject var model: IndicatorModel
    let activate: () -> Void
    let hover: (Bool) -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: activate) {
            FlowPeekGlassSurface(cornerRadius: 16) {
                HStack(spacing: 11) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("clipboard.indicator.title")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(model.shortcut)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(.white.opacity(0.14))
                        )
                }
                .padding(.horizontal, 14)
            }
            .scaleEffect(isHovered ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            hover(hovering)
        }
    }

    private var subtitle: String {
        guard let keyword = model.keyword, !keyword.isEmpty else {
            return String(localized: "clipboard.indicator.subtitle.generic")
        }
        return keyword
    }
}
