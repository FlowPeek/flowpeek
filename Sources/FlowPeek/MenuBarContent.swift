import AppKit
import FlowPeekCore
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        // The menu opens with the same verdict the icon is drawing, in words: this is the only
        // surface a user with no window open can consult when FlowPeek has gone quiet, and it used
        // to say nothing at all about permission — the state that switches two of the three routes
        // off — while offering "Refresh Accessibility Permission" as a command whose click closed
        // the menu and reported nothing.
        Text(statusLine)
        if !app.accessibilityGranted {
            // Said here even when the icon stays calm because the user declined the switch: the
            // menu is where someone can find out what that costs and change their mind, and it is
            // the place to say it without turning the icon into a permanent nag.
            if !statusLineCoversPermission {
                Text("menu.status.permission")
            }
            Button("permission.open-settings") { app.openAccessibilitySettings() }
        }
        if app.isCheckingEngine {
            Text("menu.engine.checking")
        } else {
            if let complaint = engineComplaint {
                Text(complaint)
            }
            // Offered for a degraded engine too: the complaint is about one canary at one launch,
            // and taking it again is the only way to find out whether it still stands.
            if app.engineHealth?.menuDescription != nil {
                Button("menu.engine.recheck") { app.recheckEngine() }
            }
        }
        // A stored combination the OS refused to hand over leaves the feature reachable only from
        // here, and until now the red line saying so lived in the Shortcuts pane alone.
        if !app.shortcuts.unavailableActions.isEmpty {
            Text("menu.shortcuts.unavailable")
            // Straight to the pane that holds the field, the way the tutorial's own buttons open the
            // step they are about: this row exists to fix a combination, and `handle(.showSettings)`
            // would land the user on General with nothing on it about shortcuts.
            Button("menu.shortcuts.fix") { SettingsWindowCoordinator.shared.show(section: .shortcuts) }
        }
        Divider()
        // The only mouse-reachable door to the clipboard route once the badge has faded, and the
        // one place the chord is legible without opening Settings.
        Button(clipboardTitle) { app.previewCopied() }
        Toggle(String(localized: app.isEnabled ? "menu.detection.on" : "menu.detection.paused"), isOn: $app.isEnabled)
            .onChange(of: app.isEnabled) { _, _ in app.applyEnabledState() }
        Divider()
        // Only while there is one to go back to. A promoted preview is borderless, so it has no
        // Dock icon and no entry in the Window menu: once another app covered it there was nothing
        // that could raise it again.
        if app.hasPromotedPreview {
            Button("menu.preview.reveal") { app.handle(.revealPreview) }
            Divider()
        }
        Button("menu.settings") {
            app.handle(.showSettings)
        }
        // The only other opener is the launch-time check, which now stops firing once the permission
        // question has an answer — so without this the wizard would be unreachable after dismissal.
        Button("menu.onboarding") { OnboardingCoordinator.shared.show() }
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

    /// Whether the line above has already said that Accessibility is off, so the extra row for the
    /// decliner does not repeat it back to them.
    private var statusLineCoversPermission: Bool {
        app.menuBarStatus == .permissionMissing || app.menuBarStatus == .nothingWatched
    }

    /// The engine's complaint, unless the status row above is already carrying it — which it is
    /// whenever the engine is the top-priority problem.
    private var engineComplaint: String? {
        guard app.menuBarStatus != .engineBroken else { return nil }
        return app.engineHealth?.menuDescription
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
