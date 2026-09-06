import AppKit
import FlowPeekCore
import SwiftUI

/// The way back to a diagram: one window, opened from the menu bar, listing what was made most
/// recently first. Opening a row ends in the same preview window every other route in the app ends
/// in, so there is nothing new to learn once a diagram is on screen.
@MainActor
final class DiagramHistoryCoordinator: NSObject, NSWindowDelegate {
    static let shared = DiagramHistoryCoordinator()
    private var window: NSWindow?

    private static let size = NSSize(width: 560, height: 620)

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let controller = NSHostingController(
            rootView: DiagramHistoryView(store: DiagramHistoryStore.shared) { [weak self] in
                self?.closeWindow()
            }
        )
        let window = FlowPeekGlassWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = String(localized: "history.window.title")
        window.isOpaque = false
        window.backgroundColor = .clear
        // The content paints its own shadow inside its padding, the way the Settings window does;
        // AppKit's would trace the whole window rect and float outside the visible card.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(Self.size)
        window.contentMinSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }
}

struct DiagramHistoryView: View {
    @ObservedObject var store: DiagramHistoryStore
    let close: () -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        FlowPeekGlassSurface(cornerRadius: 24) {
            VStack(spacing: 0) {
                header
                if store.entries.isEmpty {
                    empty
                } else {
                    list
                    footer
                }
            }
        }
        .shadow(color: .black.opacity(0.24), radius: 30, y: 14)
        .padding(24)
        .alert(
            Text("history.clear.title"),
            isPresented: $isConfirmingClear
        ) {
            Button(String(localized: "history.clear.action"), role: .destructive) { store.removeAll() }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: String(format: String(localized: "history.clear.message"), store.entries.count))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FlowPeekWindowCloseButton(action: close)
            Image(systemName: "clock.arrow.circlepath")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("history.window.title")
                .font(.headline)
            Spacer(minLength: 12)
            Text("history.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.entries) { entry in
                    DiagramHistoryRow(
                        entry: entry,
                        open: { open(entry) },
                        remove: { store.remove(entry.id) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("history.empty.title")
                .font(.headline)
            Text("history.empty.message")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            // The count is what makes the maximum in Settings mean something here: "18 of 20" is the
            // only place a person can see the cap doing its job.
            Text(verbatim: String(format: String(localized: "history.count"), store.entries.count, store.limit))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "history.clear"), role: .destructive) { isConfirmingClear = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private func open(_ entry: DiagramHistoryEntry) {
        guard let document = entry.document(fallbackTitle: String(localized: "diagram.default-title")) else {
            // A row whose text no longer reads as a diagram at all -- the file was edited, or the
            // diagram was emptied out. Said in the panel every other refusal in the app uses, with
            // the one thing worth doing about it attached.
            AppState.shared.previews.showMessage(
                title: String(localized: "history.unreadable.title"),
                message: String(localized: "history.unreadable.message"),
                action: (
                    title: String(localized: "history.remove"),
                    handler: { DiagramHistoryStore.shared.remove(entry.id) }
                )
            )
            return
        }
        // Deliberately not closing this window: two diagrams are opened from here to be compared,
        // and the list is where the second one is picked.
        AppState.shared.previews.openWindow(document: document)
    }
}

private struct DiagramHistoryRow: View {
    let entry: DiagramHistoryEntry
    let open: () -> Void
    let remove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.origin.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(verbatim: title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // The diagram's own opening word, shown as a tag the way the clipboard
                            // badge shows it: it is raw source text, not prose.
                            if let keyword = entry.keyword {
                                Text(verbatim: keyword)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(verbatim: subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("history.open.help")

            // Its own button rather than a swipe or a context menu: this window is the only place a
            // remembered diagram can be got rid of, and a way out that has to be discovered is not
            // one. Drawn faintly until the pointer is on the row, so a list of twenty is a list of
            // diagrams rather than a list of crosses.
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.25)
            .help("history.remove")
            .accessibilityLabel(Text("history.remove"))
        }
        .padding(11)
        .background(Color.primary.opacity(isHovered ? 0.075 : 0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.14)))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var title: String {
        entry.title.isEmpty ? String(localized: "diagram.default-title") : entry.title
    }

    private var subtitle: String {
        let origin = String(localized: entry.origin.titleKey)
        // Formatted by Foundation rather than assembled here: "2 hours ago" is a sentence in every
        // language the app is in, and none of them build it the same way.
        let when = entry.recordedAt.formatted(.relative(presentation: .named))
        return "\(origin) · \(when)"
    }
}
