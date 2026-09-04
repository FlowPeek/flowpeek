import AppKit
import SwiftUI

struct FlowPeekGlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 28) {
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            configure(glass)
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        configure(effect)
        return effect
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
    }

    private func configure(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
    }
}

struct FlowPeekWindowCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isHovered ? Color.red : Color.secondary.opacity(0.42))
                // Drawn at rest too, not only on hover: on the borderless surfaces this is the one
                // visible way out, and a bare grey dot does not read as a close button until the
                // pointer is already on it.
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(isHovered ? Color.black.opacity(0.7) : Color.primary.opacity(0.45))
            }
            .frame(width: 13, height: 13)
            // A 13pt dot is a hard thing to hit, and on these borderless surfaces it is the only
            // visible way out. The padding widens the hittable circle to 23pt; the negative padding
            // hands the layout its 13pt back, so nothing beside it in the header moves. The hover
            // and the tooltip sit inside that padding rather than on the button, whose frame the
            // negative padding has shrunk again: a click that lands in the ring has to light the dot
            // up first, or the pointer is over something that gives no sign it can be pressed.
            .padding(5)
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .help(Text("common.close"))
            .padding(-5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("common.close"))
    }
}

/// The app's one glass shape: material, the same faint accent wash the onboarding surface uses, a
/// continuous-corner clip and a hairline rim. Every borderless FlowPeek surface is built from this.
struct FlowPeekGlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    init(cornerRadius: CGFloat = 22, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        ZStack {
            FlowPeekGlassBackground(cornerRadius: cornerRadius)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.11), .clear, Color.purple.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A borderless panel still has to accept keys, or Escape and every button inside it are inert.
final class FlowPeekGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

final class FlowPeekGlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct TogglesOnTap: ViewModifier {
    @Binding var isOn: Bool
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // An overlay, not a background: the card already paints one, and a tint behind it would
            // barely show. `allowsHitTesting(false)` keeps the wash out of the switch's way.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .onTapGesture { isOn.toggle() }
    }
}

extension View {
    /// Makes a whole settings or onboarding card flip its switch, not only the switch itself. The
    /// `Toggle` inside keeps handling its own clicks, so a tap on the control is not counted twice.
    func togglesOnTap(_ isOn: Binding<Bool>, cornerRadius: CGFloat = 16) -> some View {
        modifier(TogglesOnTap(isOn: isOn, cornerRadius: cornerRadius))
    }
}
