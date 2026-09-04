import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        if let health = app.engineHealth?.menuDescription {
            Text(health)
            Divider()
        }
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
        // The three gestures are the whole app, and a week later nobody remembers whether it was
        // hold-Option or Option-drag. This is the way back to just the checklist and the practice
        // page, without walking through setup again.
        Button("menu.tutorial") { OnboardingCoordinator.shared.show(entry: .tutorial) }
        Button("menu.permission.refresh") { app.refreshPermission() }
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
}

extension Notification.Name {
    static let flowPeekCheckForUpdates = Notification.Name("FlowPeekCheckForUpdates")
}
