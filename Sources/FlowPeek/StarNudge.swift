import AppKit
import FlowPeekCore
import SwiftUI

/// The one thing FlowPeek ever asks for, said the way the app says everything small: a pane of
/// glass near the menu bar that takes no focus, covers nothing, and retires itself.
///
/// Deliberately not an alert. An alert would activate the app, put a sheet in front of whatever the
/// user was reading, and make "no" a thing they have to click before they can carry on — for a
/// favour, from an app whose entire manner is to stay out of the way. Everything here is built from
/// the copy badge's parts for the same reason.
@MainActor
final class StarNudgeNoticeCoordinator {
    /// The one thing this notice can set in motion.
    var onStar: (() -> Void)?

    /// The question has been put: the notice has been up long enough to have been read, or it has
    /// been answered. Separate from `show()` because ordering a panel on screen and asking somebody
    /// something are not the same event — FlowPeek can be paused, or the screen locked, a moment
    /// after the notice appears and take it back down again, and there is only one ask to spend.
    var onAsked: (() -> Void)?

    static let size = CGSize(width: 330, height: 118)
    /// Longer than the copy badge's five seconds: that one names a key for something the user just
    /// did, and this one is two sentences and a choice arriving unannounced. Long enough to read
    /// twice and still short enough to be a notice rather than a dialogue.
    static let visibleDuration: TimeInterval = 15
    /// VoiceOver has to reach the end of both buttons before the panel describing them is gone.
    static let voiceOverDuration: TimeInterval = 28
    private static let fadeDuration: TimeInterval = 0.18
    /// A glance, and a little over the fade. Past this the notice has been seen whether or not
    /// anybody presses anything, and the app has spent the one question it had.
    private static let readingTime: Duration = .seconds(2)

    /// The top-right slot belongs to the copy badge: that one answers something the user just did
    /// and can fire at any moment, including while this is up. This one is unsolicited, so it takes
    /// the row underneath and the two stack rather than covering each other.
    private static let slotOffset = ClipboardIndicatorCoordinator.size.height + 10

    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var reportedAsked = false

    func show() {
        let panel = panel ?? makePanel()
        panel.setFrame(CGRect(origin: placement(), size: Self.size), display: false)
        if !panel.isVisible {
            // A fresh presentation. Only reachable again once the ledger has been put back — the
            // notice is shown once for the life of an install — and that door has to work.
            reportedAsked = false
            panel.alphaValue = 0
            // Never `makeKeyAndOrderFront`: taking the keyboard away from whatever the user is
            // typing in, to ask them for a favour, is the one thing this must not do.
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
        scheduleDismissal()
        scheduleAskedReport()
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        // Cancelled, not reported: a notice taken down before it could be read was never a
        // question that was asked.
        reading?.cancel()
        reading = nil
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

    /// Hovering holds it open; leaving restarts the clock. Reading two sentences and reaching for a
    /// button takes longer than a glance, and the pointer arriving is the sign that it is happening.
    private func setHovering(_ hovering: Bool) {
        if hovering {
            dismissal?.cancel()
            dismissal = nil
        } else if panel?.isVisible == true {
            scheduleDismissal()
        }
    }

    /// Pressing either button is the question having been put, however it is answered — and it
    /// arrives before the panel starts fading, so the answer cannot be lost to the teardown.
    private func reportAsked() {
        reading?.cancel()
        reading = nil
        guard !reportedAsked else { return }
        reportedAsked = true
        onAsked?()
    }

    private func scheduleAskedReport() {
        guard !reportedAsked, reading == nil else { return }
        reading = Task { [weak self] in
            try? await Task.sleep(for: Self.readingTime)
            guard !Task.isCancelled else { return }
            self?.reportAsked()
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

    private func placement() -> CGPoint {
        let frames = NSScreen.screens.map(\.visibleFrame)
        let target = ScreenGeometry.visibleFrame(containing: NSEvent.mouseLocation, visibleFrames: frames)
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: Self.size)
        let top = ScreenGeometry.indicatorOrigin(size: Self.size, in: target)
        return ScreenGeometry.clamp(
            origin: CGPoint(x: top.x, y: top.y - Self.slotOffset),
            size: Self.size,
            visibleFrames: [target]
        )
    }

    private func makePanel() -> NSPanel {
        let panel = FlowPeekGlassPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above ordinary windows and full-screen content, below the menu bar itself. The level is
        // set after `isFloatingPanel`, which puts a panel back at `.floating` on its way through.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = NSHostingController(
            rootView: StarNudgeNoticeView(
                star: { [weak self] in
                    self?.reportAsked()
                    self?.hide()
                    self?.onStar?()
                },
                dismiss: { [weak self] in
                    self?.reportAsked()
                    self?.hide()
                },
                hover: { [weak self] hovering in self?.setHovering(hovering) }
            )
        )
        panel.setContentSize(Self.size)
        self.panel = panel
        return panel
    }
}

private struct StarNudgeNoticeView: View {
    let star: () -> Void
    let dismiss: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        FlowPeekGlassSurface(cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("star.title")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("star.message")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: star) {
                        Text("star.action")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(action: dismiss) {
                        Text("star.dismiss")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                // Not a `Spacer` above the row: the panel is a fixed height and the buttons should
                // sit where the text ends, not be pushed to the floor of whatever height it has.
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
        }
        // The glass itself is not pressable — unlike the copy badge, where the whole pane is the
        // one action. Here the two answers are different and both have to be deliberate, so a
        // stray click anywhere on the notice must not count as either of them.
        .onHover { hover($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("star.title"))
    }
}
