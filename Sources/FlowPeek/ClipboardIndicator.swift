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
    /// A badge that has to be found by ear rather than seen needs longer than a glance: VoiceOver
    /// has to reach the end of the sentence before the panel it describes is gone.
    static let voiceOverDuration: TimeInterval = 12
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
        let duration = NSWorkspace.shared.isVoiceOverEnabled ? Self.voiceOverDuration : Self.visibleDuration
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
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
        Button {
            // Before the badge is taken out from under the pointer: the exit event never arrives
            // once the panel is gone, and the pointing hand would outlive it.
            endHover()
            activate()
        } label: {
            FlowPeekGlassSurface(cornerRadius: 16) {
                HStack(spacing: 11) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("clipboard.indicator.title")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            // The keyword is raw source text -- "erDiagram", "swimlane-beta" -- so
                            // it is shown as a tag rather than as prose, and it truncates before
                            // the title does. It used to *replace* the line below, which is the
                            // only place the badge ever says what to do with it.
                            if let keyword = model.keyword, !keyword.isEmpty {
                                Text(verbatim: keyword)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Text("clipboard.indicator.subtitle.generic")
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
        // The whole pane of glass is the button, not just the text inside it.
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            // Guarded, so repeated enter events cannot stack pushes the exits will never balance.
            guard hovering != isHovered else { return }
            if hovering {
                isHovered = true
                NSCursor.pointingHand.push()
                hover(true)
            } else {
                endHover()
                hover(false)
            }
        }
        .onDisappear { endHover() }
        .help("clipboard.indicator.help")
        // Without a label VoiceOver reads the three Texts and the key cap glyphs as one run-on
        // string and never says that any of it is pressable. The label collapses those children,
        // so it has to carry the key cap itself — naming the shortcut is the badge's whole job,
        // and it is rendered from the store rather than translated because it is rebindable.
        .accessibilityLabel(Text(verbatim: String(
            format: String(localized: "clipboard.indicator.a11y"),
            model.shortcut
        )))
        .accessibilityHint(Text("clipboard.indicator.help"))
    }

    private func endHover() {
        guard isHovered else { return }
        isHovered = false
        NSCursor.pop()
    }
}
