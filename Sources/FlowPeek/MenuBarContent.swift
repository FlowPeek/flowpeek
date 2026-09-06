import AppKit
import FlowPeekCore
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var app: AppState
    /// Observed, not read once. A diagram filed while this menu is on screen -- the AI window is
    /// perfectly capable of finishing one behind it -- has to appear in the list below, and an
    /// unobserved `shared` would leave the menu showing whatever was true when it was last drawn.
    @ObservedObject private var history = DiagramHistoryStore.shared

    var body: some View {
        // One line, then at most one thing to do about it. The menu used to grow a row for every
        // complaint at once -- a line and a button for the permission, another pair for the engine,
        // another for a shortcut macOS refused -- so its shape changed with the weather and the
        // reader had to work out which of three problems was the one stopping them. Only one of
        // them ever is, and the icon has already picked it.
        Text(statusLine)
        if let remedy {
            Button(String(localized: remedy.titleKey)) { perform(remedy) }
        }
        Divider()

        // The diagrams the user made, at the top, because coming back to one is the commonest
        // reason to open this menu at all. The store reads its file once per launch, on the first
        // touch, and is in memory afterwards. Absent rather than empty when the user switched
        // remembering off: a permanently empty list, with a window behind it, reads as a feature
        // that is broken instead of one that is off.
        if history.isRemembering {
            Menu("menu.recent") {
                ForEach(recent) { entry in
                    Button(entry.title) { open(entry) }
                }
                if recent.isEmpty {
                    Text("menu.recent.empty")
                } else {
                    Divider()
                }
                Button("menu.recent.all") { DiagramHistoryCoordinator.shared.show() }
            }
        }
        // The only mouse-reachable door to the clipboard route once the badge has faded, and the
        // one place the chord is legible without opening Settings.
        Button(clipboardTitle) { app.previewCopied() }
        Toggle(String(localized: app.isEnabled ? "menu.detection.on" : "menu.detection.paused"), isOn: detection)
        // Only while there is one to go back to. A promoted preview is borderless, so it has no
        // Dock icon and no entry in the Window menu: once another app covered it there was nothing
        // that could raise it again.
        if app.hasPromotedPreview {
            Button("menu.preview.reveal") { app.handle(.revealPreview) }
        }
        Divider()

        // One door, not two. "Show Setup Guide" and "How FlowPeek Works" opened the same window,
        // and everything the setup steps carry is reachable without them: the permission from the
        // row above and from the tutorial's own locked lesson, launching at login from Settings.
        Button("menu.help") { OnboardingCoordinator.shared.show(entry: .tutorial) }
        Button("menu.settings") { app.handle(.showSettings) }
        Divider()

        Button("menu.update") {
            // Sparkle is wired in the Xcode distribution target when an appcast URL is supplied.
            NotificationCenter.default.post(name: .flowPeekCheckForUpdates, object: nil)
        }
        Button("menu.about") { NSApp.orderFrontStandardAboutPanel(nil) }
        Divider()
        Button("menu.quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// How many of the user's diagrams the menu itself offers. Enough to recognise the one you
    /// meant, short enough that the menu does not become the history window.
    private static let recentCount = 5

    private var recent: [DiagramHistoryEntry] {
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
    /// `onChange` beside it: in a `.menu`-style `MenuBarExtra` these rows are NSMenu items, and the
    /// modifier that would notice the change only runs while SwiftUI is re-rendering the row — so
    /// starting and stopping the monitors, releasing the hot keys and redrawing the icon all hung on
    /// a callback the menu is under no obligation to deliver. The click itself is the setter.
    private var detection: Binding<Bool> {
        Binding(get: { app.isEnabled }, set: { app.setDetectionEnabled($0) })
    }

    /// One line, in the icon's own precedence, so the menu and the glyph can never disagree.
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
        // the app, and a menu that only speaks up about problems cannot answer it either.
        case .armed: String(localized: "menu.status.ready")
        }
    }

    /// The glyphs are appended from the shortcut store rather than translated into the title: the
    /// combination is user-rebindable, and a dormant action holds no combination at all, so naming
    /// one there would promise a key that is not registered.
    private var clipboardTitle: String {
        let title = String(localized: "menu.preview-clipboard")
        guard let chord = app.clipboardShortcutDisplay else { return title }
        return title + "  " + chord
    }
}

extension Notification.Name {
    static let flowPeekCheckForUpdates = Notification.Name("FlowPeekCheckForUpdates")
}
