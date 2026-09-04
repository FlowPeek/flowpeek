import SwiftUI

@main
struct FlowPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("FlowPeek", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarContent()
                .environmentObject(AppState.shared)
        }
        .menuBarExtraStyle(.menu)

    }
}
