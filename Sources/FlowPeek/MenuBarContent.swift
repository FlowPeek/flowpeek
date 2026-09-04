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
        Button("menu.settings") {
            app.handle(.showSettings)
        }
        // The only other opener is the launch-time check, which now stops firing once the permission
        // question has an answer — so without this the wizard would be unreachable after dismissal.
        Button("menu.onboarding") { OnboardingCoordinator.shared.show() }
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
