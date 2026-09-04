import AppKit
import FlowPeekCore
import SwiftUI

/// Click to record, then press a combination. While a field is recording every global hot key is
/// suspended, otherwise Carbon would swallow the very keys being recorded.
struct ShortcutRecorder: View {
    let action: FlowPeekShortcutAction
    @ObservedObject var center: ShortcutCenter

    @State private var pressedModifiers: FlowPeekShortcut.Modifiers = []
    @State private var error: String?
    @State private var isHovered = false

    private var isRecording: Bool { center.recordingAction == action }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(fieldText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isRecording ? Color.accentColor : .primary)
                        .frame(minWidth: 82)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(isRecording ? 0.12 : isHovered ? 0.09 : 0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isRecording ? Color.accentColor.opacity(0.75) : .white.opacity(0.14))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("shortcut.record.help")

                Button {
                    center.reset(action)
                    error = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(center.shortcuts[action] == action.defaultShortcut)
                .help("shortcut.reset.help")
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .overlay {
            if isRecording {
                KeyCaptureView(
                    onCapture: capture,
                    onModifiers: { pressedModifiers = $0 },
                    onCancel: stopRecording
                )
                .frame(width: 0, height: 0)
            }
        }
        .onDisappear { if isRecording { stopRecording() } }
        .onChange(of: center.recordingAction) { _, current in
            // Another field took the keyboard; drop this one's transient state.
            if current != action { pressedModifiers = [] }
        }
    }

    private var fieldText: String {
        guard isRecording else { return center.shortcuts[action].display }
        return pressedModifiers.isEmpty ? String(localized: "shortcut.recording") : pressedModifiers.display
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        error = nil
        pressedModifiers = []
        center.beginRecording(action)
    }

    private func stopRecording() {
        pressedModifiers = []
        center.endRecording()
    }

    /// Core names the failure; the app owns the catalogue, matching how `mermaid.error.*` is handled.
    private static func message(for error: FlowPeekShortcut.ValidationError) -> String {
        let format = Bundle.main.localizedString(forKey: error.localizationKey, value: nil, table: nil)
        guard let argument = error.localizationArgument else { return format }
        return String(format: format, argument)
    }

    private func capture(keyCode: UInt16, modifiers: FlowPeekShortcut.Modifiers) {
        if let failure = center.assign(keyCode: keyCode, modifiers: modifiers, to: action) {
            error = Self.message(for: failure)
            pressedModifiers = []
            return
        }
        error = nil
        stopRecording()
    }
}

/// An invisible first responder. `⌘`-combinations never reach `keyDown` — AppKit routes them through
/// `performKeyEquivalent(with:)` first — so both paths have to be handled.
private struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (UInt16, FlowPeekShortcut.Modifiers) -> Void
    let onModifiers: (FlowPeekShortcut.Modifiers) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        view.onModifiers = onModifiers
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onModifiers = onModifiers
        nsView.onCancel = onCancel
    }

    final class CaptureView: NSView {
        var onCapture: ((UInt16, FlowPeekShortcut.Modifiers) -> Void)?
        var onModifiers: ((FlowPeekShortcut.Modifiers) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            handle(event)
        }

        override func flagsChanged(with event: NSEvent) {
            onModifiers?(FlowPeekShortcut.Modifiers(event.modifierFlags))
        }

        /// Escape on its own abandons the recording; Escape with a modifier is a legitimate shortcut.
        private func handle(_ event: NSEvent) {
            let modifiers = FlowPeekShortcut.Modifiers(event.modifierFlags)
            if event.keyCode == 53, modifiers.isEmpty {
                onCancel?()
                return
            }
            onCapture?(event.keyCode, modifiers)
        }
    }
}
