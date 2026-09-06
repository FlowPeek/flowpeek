import AppKit
import FlowPeekCore
import SwiftUI

/// The contents of the shelf: a row of diagrams, newest first, scrolled sideways.
struct DiagramShelfView: View {
    @ObservedObject var store: DiagramHistoryStore
    let open: (DiagramDocument) -> Void
    let close: () -> Void

    @State private var confirmingClear = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Made once and kept for as long as the shelf is open: loading a language model is tens of
    /// milliseconds, and it must not happen on a keystroke.
    private let semantics = SemanticIndex()

    var body: some View {
        FlowPeekGlassSurface(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if store.entries.isEmpty {
                    empty
                } else if results.isEmpty {
                    noMatches
                } else {
                    // Said out loud when these are guesses. The model is good enough to order
                    // candidates and not good enough to be believed, and a row of wrong answers
                    // that looks like a result is worse than none.
                    if !results.related.isEmpty {
                        Text("history.search.related")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 6)
                    }
                    cards
                }
            }
            .padding(.vertical, 14)
        }
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("history.window.title")
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: String(
                format: String(localized: "history.count"),
                store.entries.count,
                store.limit
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if !store.entries.isEmpty {
                search
            }
            if !store.entries.isEmpty {
                Button("history.clear") { confirmingClear = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            FlowPeekWindowCloseButton(action: close)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .confirmationDialog(
            Text("history.clear.title"),
            isPresented: $confirmingClear
        ) {
            Button("history.clear.action", role: .destructive) { store.removeAll() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(verbatim: String(format: String(localized: "history.clear.message"), store.entries.count))
        }
    }

    /// Searching is the point of a list this long, and it has to be one keystroke away: the field
    /// takes focus when the shelf opens, so the shelf can be opened and typed into without the
    /// pointer ever being aimed at anything.
    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("history.search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
                .frame(width: 190)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("history.search.clear"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: Capsule())
        // Not `onAppear`: the view is built before the panel is key, and focus set then is dropped
        // when the window takes it. Measured -- the field stayed unfocused until it was clicked.
        // One runloop turn after the panel is up is enough.
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            searchFocused = true
        }
    }

    /// What the shelf is showing: everything, what the query found, or -- when it found nothing --
    /// the few diagrams the on-device model thinks are closest.
    ///
    /// Recomputed as the query changes rather than kept in state, because the list itself can move
    /// underneath it: a diagram recorded while the shelf is open belongs in the results if it
    /// matches.
    private var results: DiagramHistorySearch.Results {
        DiagramHistorySearch.search(store.entries, query: query, index: semantics)
    }

    private var noMatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("history.search.none.title").font(.system(size: 12, weight: .medium))
            Text("history.search.none.message")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("history.empty.title").font(.system(size: 12, weight: .medium))
            Text("history.empty.message")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(results.matched + results.related) { entry in
                    DiagramShelfCard(
                        entry: entry,
                        store: store,
                        open: { open($0) },
                        forget: { store.remove(entry.id) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 2)
        }
        // A vertical wheel is the only wheel most mice have, and a horizontal shelf it cannot move
        // is a shelf that only works with a trackpad.
        .background(HorizontalWheelBridge())
    }
}

/// One diagram, shown as itself.
private struct DiagramShelfCard: View {
    let entry: DiagramHistoryEntry
    @ObservedObject var store: DiagramHistoryStore
    let open: (DiagramDocument) -> Void
    let forget: () -> Void

    @State private var picture: NSImage?
    @State private var isHovered = false

    /// Sized so four or five fit on a laptop display and the picture inside is still worth looking
    /// at. The 16:9-ish plate is the shape most diagrams settle into once they are fitted.
    private static let width: CGFloat = 188
    private static let pictureHeight: CGFloat = 106

    var body: some View {
        Button(action: openDocument) {
            VStack(alignment: .leading, spacing: 7) {
                plate
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: Self.width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: "\(title), \(subtitle)"))
        // Read off the main actor: this is a file per card, and the shelf has to be on screen
        // before the pictures are, not after.
        .task(id: entry.id) {
            let data = await Task.detached(priority: .userInitiated) { [id = entry.id] in
                DiagramHistoryStore.thumbnailData(for: id)
            }.value
            guard let data, let image = NSImage(data: data) else { return }
            picture = image
        }
    }

    private var plate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                // A diagram remembered before pictures existed, or one whose capture has not landed
                // yet. Its own opening word is the most diagram-like thing there is to show.
                Text(verbatim: entry.keyword ?? String(localized: "diagram.default-title"))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.width, height: Self.pictureHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.28 : 0.10), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(action: forget) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.75))
                        .frame(width: 16, height: 16)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .help(Text("history.remove"))
                .accessibilityLabel(Text("history.remove"))
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func openDocument() {
        guard let document = entry.document(fallbackTitle: String(localized: "diagram.default-title")) else { return }
        open(document)
    }

    private var title: String {
        entry.title.isEmpty ? String(localized: "diagram.default-title") : entry.title
    }

    private var subtitle: String {
        let origin = String(localized: entry.origin.titleKey)
        // Formatted by Foundation rather than assembled here: "2 hours ago" is a sentence in every
        // language the app is in, and none of them build it the same way.
        return "\(origin) · \(entry.recordedAt.formatted(.relative(presentation: .named)))"
    }
}

/// Turns a plain wheel into sideways movement for the scroll view underneath.
///
/// AppKit already does this when Shift is held; nothing does it otherwise, and a shelf that a
/// two-button mouse cannot move is a shelf half the people using it cannot move.
private struct HorizontalWheelBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WheelView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WheelView: NSView {
        override func scrollWheel(with event: NSEvent) {
            // A trackpad sends both axes and needs no help; only a wheel with no sideways component
            // is rewritten, and then by moving the scroller itself rather than by faking an event.
            guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0,
                  let scroller = enclosingScrollView else {
                super.scrollWheel(with: event)
                return
            }
            let step = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
            var origin = scroller.contentView.bounds.origin
            let width = scroller.documentView?.bounds.width ?? 0
            origin.x = min(max(0, origin.x - step * 12), max(0, width - scroller.contentSize.width))
            scroller.contentView.scroll(to: origin)
            scroller.reflectScrolledClipView(scroller.contentView)
        }
    }
}
