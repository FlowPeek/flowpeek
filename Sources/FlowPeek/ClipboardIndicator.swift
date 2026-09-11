import AppKit
import FlowPeekCore
import SwiftUI

/// A transient HUD in the top-right of the active screen: "this copy is a diagram, here is the key
/// that opens it". It never takes focus, never blocks a click it does not own, and retires itself.
@MainActor
final class ClipboardIndicatorCoordinator {
    var onActivate: (() -> Void)?
    /// What clicking the notice does. Separate from `onActivate` because the two badges are two
    /// different offers: one opens the diagram you copied, the other explains a setting.
    var onNotice: (() -> Void)?

    static let size = CGSize(width: 296, height: 56)
    /// The notice carries a sentence rather than a keyword and a key, and an editor's name can be
    /// "Visual Studio Code". At the badge's own width that sentence truncates mid-word, which is a
    /// worse answer than the silence it is there to replace.
    static let noticeSize = CGSize(width: 392, height: 64)
    static let visibleDuration: TimeInterval = 5
    /// A badge that has to be found by ear rather than seen needs longer than a glance: VoiceOver
    /// has to reach the end of the sentence before the panel it describes is gone.
    static let voiceOverDuration: TimeInterval = 12
    private static let fadeDuration: TimeInterval = 0.18
    /// Slack between the glass and the edge of the panel it lives in. The badge grows by 2% under
    /// the pointer, and a window cannot draw outside itself: without this the growth was clipped
    /// along the border, which reads as the badge breaking exactly when it is touched.
    private static let hoverRoom: CGFloat = 6

    private var panel: NSPanel?
    private var model = IndicatorModel()
    private var dismissal: Task<Void, Never>?

    func show(keyword: String?, shortcut: String) {
        model.kind = .clipboard
        model.keyword = keyword
        model.shortcut = shortcut
        present()
    }

    /// The other thing this badge says: the gesture worked, and the editor under it is the reason
    /// nothing happened. Same pane of glass on purpose -- it is the same kind of interruption, and
    /// a second HUD with its own look would be a second thing to recognise.
    func showNotice(editorName: String, action: String) {
        model.kind = .editorNotice(editorName: editorName)
        model.shortcut = action
        present()
    }

    private func present() {
        let panel = panel ?? makePanel()
        // The panel is sized from what it is about to say, not from a constant. Placing a 392-point
        // notice with the 296-point badge's size put 96 points of it off the right of the display.
        let size = Self.panelSize(for: model.kind)
        panel.setContentSize(size)
        panel.setFrame(CGRect(origin: placement(of: size), size: size), display: false)
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
            // AppKit runs this on the main thread; saying so is what lets the panel be touched
            // from a closure the compiler sees as nonisolated.
            MainActor.assumeIsolated { panel?.orderOut(nil) }
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

    /// The panel, which is the glass plus the room it needs to grow under the pointer.
    static func panelSize(for kind: IndicatorModel.Kind) -> CGSize {
        let glass = kind == .clipboard ? size : noticeSize
        return CGSize(width: glass.width + hoverRoom * 2, height: glass.height + hoverRoom * 2)
    }

    private func placement(of size: CGSize) -> CGPoint {
        let frames = NSScreen.screens.map(\.visibleFrame)
        let target = ScreenGeometry.visibleFrame(containing: NSEvent.mouseLocation, visibleFrames: frames)
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: size)
        // The inset is reduced by the room, so the glass sits where it always did rather than being
        // pushed inwards by its own padding.
        return ScreenGeometry.indicatorOrigin(size: size, in: target, inset: 16 - Self.hoverRoom)
    }

    private func makePanel() -> NSPanel {
        let panel = FlowPeekGlassPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize(for: model.kind)),
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
                    guard let self else { return }
                    let isNotice = model.kind != .clipboard
                    hide()
                    isNotice ? onNotice?() : onActivate?()
                },
                hover: { [weak self] hovering in self?.setHovering(hovering) }
            )
            .padding(Self.hoverRoom)
        )
        panel.setContentSize(Self.panelSize(for: model.kind))
        self.panel = panel
        return panel
    }
}

/// A reference model so the hosting controller is built once and the text can change per copy.
@MainActor
final class IndicatorModel: ObservableObject {
    /// What the badge is saying this time.
    enum Kind: Equatable {
        case clipboard
        /// An editor that is not handing its text to macOS, named so the reader knows which one.
        case editorNotice(editorName: String)
    }

    @Published var kind: Kind = .clipboard
    @Published var keyword: String?
    @Published var shortcut: String = ""
}

private struct ClipboardIndicatorView: View {
    @ObservedObject var model: IndicatorModel
    let activate: () -> Void
    let hover: (Bool) -> Void
    @State private var isHovered = false

    private var isNotice: Bool {
        if case .editorNotice = model.kind { return true }
        return false
    }

    private var icon: String {
        isNotice ? "exclamationmark.triangle.fill" : "point.3.connected.trianglepath.dotted"
    }

    /// The editor names itself, so somebody in Cursor is not told about Visual Studio Code.
    private var title: Text {
        switch model.kind {
        case .clipboard: Text("clipboard.indicator.title")
        case .editorNotice(let editorName):
            Text(String(format: String(localized: "notice.editor.title"), editorName))
        }
    }

    private var subtitle: Text {
        switch model.kind {
        case .clipboard: Text("clipboard.indicator.subtitle.generic")
        case .editorNotice: Text("notice.editor.subtitle")
        }
    }

    var body: some View {
        Button {
            // Before the badge is taken out from under the pointer: the exit event never arrives
            // once the panel is gone, and the pointing hand would outlive it.
            endHover()
            activate()
        } label: {
            FlowPeekGlassSurface(cornerRadius: 16) {
                HStack(spacing: 11) {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isNotice ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            title
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            // The keyword is raw source text -- "erDiagram", "swimlane-beta" -- so
                            // it is shown as a tag rather than as prose, and it truncates before
                            // the title does. It used to *replace* the line below, which is the
                            // only place the badge ever says what to do with it.
                            if case .clipboard = model.kind, let keyword = model.keyword, !keyword.isEmpty {
                                Text(verbatim: keyword)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(isNotice ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
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
