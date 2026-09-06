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
    /// The diagram whose source is on the pasteboard, for the moment after Command-C. A copy with
    /// no answer looks exactly like a key that did nothing.
    @State private var copied: DiagramHistoryEntry.ID?
    @FocusState private var focus: Field?

    /// Everything the keyboard can be on. A card is named by its diagram rather than by its
    /// position, so a list that moves under the focus -- a diagram recorded while the shelf is
    /// open, a row deleted -- keeps the focus on the same diagram instead of on the same slot.
    private enum Field: Hashable {
        case search
        case card(DiagramHistoryEntry.ID)
    }
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
                    keyHints
                    // Command-C is a menu command as far as AppKit is concerned, so `onKeyPress`
                    // never sees it. A shortcut on a button does -- and disabling that button while
                    // the keyboard is in the search field is what leaves Command-C there meaning
                    // "copy what I typed".
                    Button("history.keys.copy") { copyFocused() }
                        .keyboardShortcut("c", modifiers: .command)
                        .disabled(focusedEntry == nil)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 14)
            // Escape backs out one step at a time -- out of the cards, then out of the query, then
            // out of the shelf -- which is what it does everywhere else in macOS.
            .onExitCommand(perform: retreat)
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            // Handled here rather than on the card: `focusable()` wraps a plain-styled Button in
            // something that takes the focus but does not pass it these, so a card that plainly had
            // the focus ring did nothing when Return was pressed on it.
            .onKeyPress(.return) { actOnFocused(openEntry) }
            .onKeyPress(.space) { actOnFocused(openEntry) }
            // Matched on the character rather than on `KeyEquivalent.delete`: measured, neither
            // `.delete` nor `.deleteForward` fired for the key labelled Delete on this keyboard,
            // and a card with a focus ring on it that ignores Delete is a dead key.
            .onKeyPress(phases: .down) { press in
                guard focusedEntry != nil,
                      press.characters.unicodeScalars.contains(where: { $0 == "\u{7F}" || $0 == "\u{8}" })
                else { return .ignored }
                return actOnFocused(forget)
            }
            .onKeyPress(.upArrow) {
                guard case .card = focus else { return .ignored }
                focus = .search
                return .handled
            }
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
                .focused($focus, equals: .search)
                .frame(width: 190)
                // Down or Tab walks into the shelf; Return opens the first thing found, which is
                // the whole gesture for "the one I want is obviously first".
                .onKeyPress(.downArrow, phases: .down) { _ in moveIntoCards() }
                .onKeyPress(.tab, phases: .down) { _ in moveIntoCards() }
                .onKeyPress(.return) {
                    guard let first = visible.first else { return .ignored }
                    openEntry(first)
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    focus = .search
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
            focus = .search
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
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { position, entry in
                        DiagramShelfCard(
                            entry: entry,
                            isFocused: focus == .card(entry.id),
                            // Only the first nine. Ten would be ⌘0, which reads as "the tenth" to
                            // nobody, and a shelf is scrolled past nine anyway.
                            ordinal: position < 9 ? position + 1 : nil,
                            isCopied: copied == entry.id,
                            open: { openEntry(entry) },
                            forget: { forget(entry) }
                        )
                        // Focusable as well as focused: a plain-styled Button takes no focus on
                        // macOS on its own, so binding `focus` to it was binding to something that
                        // could never hold it.
                        .focusable()
                        .focused($focus, equals: .card(entry.id))
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 2)
            }
            // The focused card is dragged into view, so arrowing along the shelf scrolls it rather
            // than walking the focus off the end of what can be seen.
            .onChange(of: focus) { _, new in
                guard case .card(let id) = new else { return }
                withAnimation(.easeOut(duration: 0.16)) { scroller.scrollTo(id, anchor: .center) }
            }
        }
        // A vertical wheel is the only wheel most mice have, and a horizontal shelf it cannot move
        // is a shelf that only works with a trackpad.
        .background(HorizontalWheelBridge())
    }

    /// The keys, written down. A shelf you can drive from the keyboard that does not say so is a
    /// shelf everybody drives with the mouse.
    private var keyHints: some View {
        HStack(spacing: 14) {
            ForEach(Self.hints, id: \.0) { keys, label in
                HStack(spacing: 4) {
                    Text(verbatim: keys)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    Text(label).font(.system(size: 9))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        // One line for the sighted reader; VoiceOver gets the same keys from each card's hint.
        .accessibilityHidden(true)
    }

    private static let hints: [(String, LocalizedStringKey)] = [
        ("↑↓←→", "history.keys.move"),
        ("⏎", "history.keys.open"),
        ("⌘C", "history.keys.copy"),
        ("⌫", "history.keys.forget"),
        ("esc", "history.keys.close"),
    ]

    // MARK: - What the keyboard does

    /// The rows on the shelf right now, answers and guesses in the order they are drawn.
    private var visible: [DiagramHistoryEntry] { results.matched + results.related }

    /// One step out: off the cards, then out of the query, then off the screen.
    private func retreat() {
        if case .card = focus {
            focus = .search
        } else if !query.isEmpty {
            query = ""
            focus = .search
        } else {
            close()
        }
    }

    /// The diagram the keyboard is on, if it is on one at all.
    private var focusedEntry: DiagramHistoryEntry? {
        guard case .card(let id) = focus else { return nil }
        return visible.first { $0.id == id }
    }

    /// Runs something on the diagram the keyboard is on, and says so to the key handler.
    private func actOnFocused(_ act: (DiagramHistoryEntry) -> Void) -> KeyPress.Result {
        guard let focusedEntry else { return .ignored }
        act(focusedEntry)
        return .handled
    }

    private func copyFocused() {
        guard let focusedEntry else { return }
        copySource(of: focusedEntry)
    }

    private func moveIntoCards() -> KeyPress.Result {
        guard let first = visible.first else { return .ignored }
        focus = .card(first.id)
        return .handled
    }

    /// Steps along the shelf. Clamped rather than wrapped: arrowing off the end and landing back at
    /// the beginning loses your place in a list you are scanning.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard case .card(let id) = focus,
              let index = visible.firstIndex(where: { $0.id == id }) else { return .ignored }
        let next = index + delta
        guard visible.indices.contains(next) else { return .handled }
        focus = .card(visible[next].id)
        return .handled
    }

    private func openEntry(_ entry: DiagramHistoryEntry) {
        guard let document = entry.document(fallbackTitle: String(localized: "diagram.default-title")) else { return }
        open(document)
    }

    /// The diagram itself, as text. Not the picture: what somebody does with a remembered diagram
    /// is paste it back into the document or the editor it came from.
    private func copySource(of entry: DiagramHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.source, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { copied = entry.id }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard copied == entry.id else { return }
            withAnimation(.easeIn(duration: 0.2)) { copied = nil }
        }
    }

    /// Keeps the focus on the shelf rather than dropping it: deleting the row under the keyboard
    /// and leaving nothing focused means the next keystroke does nothing.
    private func forget(_ entry: DiagramHistoryEntry) {
        let rows = visible
        let index = rows.firstIndex(where: { $0.id == entry.id })
        store.remove(entry.id)
        guard let index else { return }
        let remaining = rows.filter { $0.id != entry.id }
        if remaining.isEmpty {
            focus = .search
        } else {
            focus = .card(remaining[min(index, remaining.count - 1)].id)
        }
    }
}

/// One diagram, shown as itself.
private struct DiagramShelfCard: View {
    let entry: DiagramHistoryEntry
    let isFocused: Bool
    /// Its place on the shelf, for the Command-number that opens it. Nil past the ninth.
    let ordinal: Int?
    let isCopied: Bool
    let open: () -> Void
    let forget: () -> Void

    @State private var picture: NSImage?
    @State private var isHovered = false

    /// Sized so four or five fit on a laptop display and the picture inside is still worth looking
    /// at. The 16:9-ish plate is the shape most diagrams settle into once they are fitted.
    private static let width: CGFloat = 188
    private static let pictureHeight: CGFloat = 106

    var body: some View {
        Button(action: open) {
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
        // Command-1 through Command-9 open a card outright, for somebody who can see the one they
        // want and does not want to arrow to it.
        .modifier(OrdinalShortcut(ordinal: ordinal))
        .accessibilityLabel(Text(verbatim: "\(title), \(subtitle)"))
        .accessibilityHint(Text("history.card.hint"))
        .accessibilityAddTraits(.isButton)
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
        // The keyboard's position, drawn as plainly as the pointer's: a focus ring that is only a
        // slightly brighter rim is one nobody finds while arrowing along a shelf.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isFocused ? 2.5 : 0)
        )
        .overlay(alignment: .topLeading) {
            if let ordinal, isHovered || isFocused {
                Text(verbatim: "⌘\(ordinal)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .center) {
            if isCopied {
                Text("history.copied")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }
        }
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

/// `keyboardShortcut` takes no optional, and a shelf longer than nine cards still has to draw the
/// rest of them.
private struct OrdinalShortcut: ViewModifier {
    let ordinal: Int?

    func body(content: Content) -> some View {
        if let ordinal, let key = "\(ordinal)".first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}
