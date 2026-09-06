import AppKit
import FlowPeekCore
import SwiftUI

/// The panel behind the menu-bar icon.
///
/// A panel rather than a menu. A system menu can only be a column of words, and FlowPeek's menu is
/// mostly not words: it is a state the app is in, a list of diagrams the user made, and two
/// switches. Drawn ourselves, the state can be a line under the app's name instead of a disabled
/// row, a remembered diagram can carry the glyph of the route that made it and the word it opens
/// with, and the one thing worth doing about a problem can sit beside the sentence describing it.
///
/// Everything here is one click from the icon. Nothing opens a submenu: a submenu in a panel this
/// size is a second place to look for five rows.
struct MenuBarContent: View {
    @EnvironmentObject private var app: AppState
    /// Observed, not read once. A diagram filed while this panel is on screen -- the AI window is
    /// perfectly capable of finishing one behind it -- has to appear in the list below, and an
    /// unobserved `shared` would leave the panel showing whatever was true when it was last drawn.
    @ObservedObject private var history = DiagramHistoryStore.shared
    /// Closes the panel. A system menu closes itself when an item is chosen; a panel does not, and
    /// one left hanging over the diagram it just opened is the panel getting in the way of the
    /// thing the user asked for. Every row that opens a window closes this first -- the switches
    /// deliberately do not, because a switch you cannot see the result of is a switch you press
    /// twice.
    @Environment(\.dismiss) private var dismiss
    /// Lives only as long as the panel is on screen; see the modifiers on `body`.
    @State private var escapeMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Absent rather than empty when the user switched remembering off: a permanently empty
            // list, with a window behind it, reads as a feature that is broken instead of one that
            // is off.
            if history.isRemembering {
                separator
                recent
            }
            separator
            actions
            separator
            footer
        }
        .frame(width: Self.width)
        .padding(.vertical, 8)
        // A menu closes on Escape and this has to as well. `onExitCommand` is the modifier for it
        // and does nothing here -- the panel carries no focused view for the command to travel
        // through -- so the key is read directly, and swallowed rather than passed on so it does
        // not also reach whatever is behind.
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                dismiss()
                return nil
            }
        }
        .onDisappear {
            guard let escapeMonitor else { return }
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    /// Wide enough for a diagram's name and the shortcut beside "Open Copied Diagram" on one line,
    /// narrow enough to still read as something hanging off an icon rather than a window.
    private static let width: CGFloat = 320

    // MARK: - Who FlowPeek is and how it is doing

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: app.menuBarStatus.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(width: 28, height: 28)
                .background(statusTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "FlowPeek")
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Under the sentence it is about, not in a row of its own further down: the two
                // were a complaint and a cure with four unrelated items between them.
                if let remedy {
                    Button(String(localized: remedy.titleKey)) { perform(remedy) }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 6)
            // The switch belongs beside the sentence it is about: the status line and this are the
            // same fact said twice, and the one thing a person opens this panel to change is
            // whether FlowPeek is watching at all. Its label is hidden because the line to its left
            // already says what it says -- VoiceOver still reads it.
            Toggle(isOn: detection) {
                Text(app.isEnabled ? "menu.detection.on" : "menu.detection.paused")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// One colour per state, in the icon's own precedence.
    private var statusTint: Color {
        switch app.menuBarStatus {
        case .armed: .accentColor
        case .paused, .nothingWatched: .orange
        case .permissionMissing, .engineBroken: .red
        }
    }

    // MARK: - The diagrams the user made

    private var recent: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionTitle("menu.recent")
            if recentEntries.isEmpty {
                Text("menu.recent.empty")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 21)
                    .padding(.vertical, 6)
            }
            ForEach(recentEntries) { entry in
                PanelRow(action: { dismiss(); open(entry) }) {
                    HStack(spacing: 10) {
                        rowIcon(entry.origin.symbol)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: entry.title.isEmpty
                                 ? String(localized: "diagram.default-title")
                                 : entry.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // The route that made it, in the same words the history window uses.
                            Text(String(localized: entry.origin.titleKey))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        // The diagram's own opening word, shown as a tag the way the clipboard
                        // badge shows it: it is raw source text, not prose.
                        if let keyword = entry.keyword {
                            Text(verbatim: keyword)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            PanelRow(action: { dismiss(); DiagramHistoryCoordinator.shared.show() }) {
                HStack(spacing: 10) {
                    rowIcon("clock.arrow.circlepath")
                    Text("menu.recent.all").font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - The switches, and the door to the clipboard

    private var actions: some View {
        VStack(alignment: .leading, spacing: 1) {
            // The only mouse-reachable door to the clipboard route once the badge has faded, and
            // the one place the chord is legible without opening Settings.
            PanelRow(action: { dismiss(); app.previewCopied() }) {
                HStack(spacing: 10) {
                    rowIcon("doc.on.clipboard")
                    Text("menu.preview-clipboard").font(.system(size: 12))
                    Spacer(minLength: 6)
                    // Rendered from the shortcut store rather than translated into the title: the
                    // combination is user-rebindable, and a dormant action holds none at all.
                    if let chord = app.clipboardShortcutDisplay {
                        Text(verbatim: chord)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // The AI window has no other door: it is opened by a chord, and a chord nobody
            // remembers is a feature nobody has. Only while the experiment is on, because the row
            // would otherwise open a window telling the user to go and switch it on.
            if app.aiEnabled {
                PanelRow(action: { dismiss(); app.presentAIPrompt() }) {
                    HStack(spacing: 10) {
                        rowIcon("wand.and.stars")
                        Text("shortcut.ai-prompt").font(.system(size: 12))
                        Spacer(minLength: 6)
                        if let chord = app.shortcutDisplay(for: .aiPrompt) {
                            Text(verbatim: chord)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // Only while there is one to go back to. A promoted preview is borderless, so it has no
            // Dock icon and no entry in the Window menu: once another app covered it there was
            // nothing that could raise it again.
            if app.hasPromotedPreview {
                PanelRow(action: { dismiss(); app.handle(.revealPreview) }) {
                    HStack(spacing: 10) {
                        rowIcon("square.on.square")
                        Text("menu.preview.reveal").font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                }
            }
            if let chord = app.shortcutDisplay(for: .ambientPeek) {
                // A gesture, not a command: there is no row to press, so the combination is simply
                // stated. It appears only while hold to peek actually holds the key, which is the
                // same condition under which pressing it does anything.
                HStack(spacing: 10) {
                    rowIcon("hand.point.up.left")
                    Text("settings.ambient").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(verbatim: chord)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Everything that opens a window

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            // One door, not two. "Show Setup Guide" and "How FlowPeek Works" opened the same
            // window, and everything the setup steps carry is reachable without them.
            PanelRow(action: { dismiss(); OnboardingCoordinator.shared.show(entry: .tutorial) }) {
                HStack(spacing: 10) {
                    rowIcon("questionmark.circle")
                    Text("menu.help").font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
            PanelRow(action: { dismiss(); app.handle(.showSettings) }) {
                HStack(spacing: 10) {
                    rowIcon("gearshape")
                    Text("menu.settings").font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
            // Quiet, and deliberately not in the accent colour: the one blue thing in this panel
            // should be the remedy in the header, which is the only row that is ever urgent.
            HStack(spacing: 4) {
                FooterButton("menu.update") {
                    dismiss()
                    // Sparkle is wired in the Xcode distribution target when an appcast URL is
                    // supplied.
                    NotificationCenter.default.post(name: .flowPeekCheckForUpdates, object: nil)
                }
                FooterButton("menu.about") { dismiss(); NSApp.orderFrontStandardAboutPanel(nil) }
                Spacer(minLength: 0)
                FooterButton("menu.quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .padding(.top, 6)
    }

    // MARK: - Pieces

    private var separator: some View {
        Divider().opacity(0.4).padding(.horizontal, 12)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    /// Hidden from VoiceOver: every one of these sits beside the words it illustrates, and read
    /// aloud they are the name of a glyph rather than anything about the row.
    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    /// The small print at the bottom. Same hover as a row, without the row's width: these are the
    /// three things nobody opens the panel for.
    private struct FooterButton: View {
        let key: LocalizedStringKey
        let action: () -> Void

        @State private var isHovered = false

        init(_ key: LocalizedStringKey, action: @escaping () -> Void) {
            self.key = key
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                Text(key)
                    .font(.system(size: 11))
                    .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.09 : 0))
            )
            .onHover { isHovered = $0 }
        }
    }

    /// A row that lights up under the pointer, which is the whole of what a menu item does for free
    /// and the whole of what has to be put back by hand.
    private struct PanelRow<Content: View>: View {
        let action: () -> Void
        @ViewBuilder let content: Content

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.09 : 0))
                    .padding(.horizontal, 7)
            )
            .onHover { isHovered = $0 }
        }
    }

    // MARK: - What the panel is showing

    /// How many of the user's diagrams the panel itself offers. Enough to recognise the one you
    /// meant, short enough that the panel does not become the history window.
    private static let recentCount = 5

    private var recentEntries: [DiagramHistoryEntry] {
        Array(history.entries.prefix(Self.recentCount))
    }

    private func open(_ entry: DiagramHistoryEntry) {
        guard let document = entry.document(fallbackTitle: String(localized: "diagram.default-title")) else { return }
        app.previews.openWindow(document: document)
    }

    /// The one thing worth offering about the state above, chosen by the same precedence the icon
    /// uses so the two can never disagree.
    private var remedy: MenuBarRemedy? {
        MenuBarRemedy.resolve(
            status: app.menuBarStatus,
            isCheckingEngine: app.isCheckingEngine,
            engineComplained: app.engineHealth?.menuDescription != nil,
            hasUnavailableShortcut: !app.shortcuts.unavailableActions.isEmpty
        )
    }

    private func perform(_ remedy: MenuBarRemedy) {
        // The re-check is the one that stays: its whole answer is the status line above it, and
        // closing the panel would take away the thing the button was pressed to change.
        if remedy != .recheckEngine { dismiss() }
        switch remedy {
        case .grantPermission: app.openAccessibilitySettings()
        case .recheckEngine: app.recheckEngine()
        // Straight to the pane that holds the field, the way the tutorial's own buttons open the
        // step they are about: `handle(.showSettings)` would land the user on General with nothing
        // on it about shortcuts.
        case .fixShortcut: SettingsWindowCoordinator.shared.show(section: .shortcuts)
        }
    }

    /// The pause switch. A binding whose setter does the work, rather than `$app.isEnabled` with an
    /// `onChange` beside it: starting and stopping the monitors, releasing the hot keys and
    /// redrawing the icon are the click itself, not a consequence of a redraw that may not come.
    private var detection: Binding<Bool> {
        Binding(get: { app.isEnabled }, set: { app.setDetectionEnabled($0) })
    }

    /// One line, in the icon's own precedence, so the panel and the glyph can never disagree.
    private var statusLine: String {
        switch app.menuBarStatus {
        // The engine's own line already names which part failed, and two rows saying "the engine
        // is broken" in different words is worse than one that says what broke.
        case .engineBroken: app.engineHealth?.menuDescription ?? String(localized: "menu.status.engine")
        case .permissionMissing: String(localized: "menu.status.permission")
        case .paused: String(localized: "menu.status.paused")
        // Names both switches, because either one turns detection back on and the icon cannot say
        // which is which.
        case .nothingWatched: String(localized: "menu.status.nothing-watched")
        // Said out loud even when nothing is wrong: "is it working?" was unanswerable anywhere in
        // the app, and a panel that only speaks up about problems cannot answer it either.
        case .armed: String(localized: "menu.status.ready")
        }
    }
}

extension Notification.Name {
    static let flowPeekCheckForUpdates = Notification.Name("FlowPeekCheckForUpdates")
}
