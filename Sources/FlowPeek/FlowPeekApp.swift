import FlowPeekCore
import SwiftUI

@main
struct FlowPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The icon is this app's only permanent surface, so it has to be the first place a paused,
    /// unpermitted or broken FlowPeek admits it. Observed here rather than inside a `label:` closure
    /// on purpose: the `systemImage:` initializer keeps the native template rendering and sizing.
    @ObservedObject private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra("FlowPeek", systemImage: app.menuBarStatus.symbolName) {
            MenuBarContent()
                .environmentObject(app)
        }
        // A window, not a menu: `MenuBarContent` draws FlowPeek's own panel -- a status line, the
        // diagrams the user made with the glyph of the route that made each one, and switches --
        // and a system menu can only draw a column of words.
        .menuBarExtraStyle(.window)

    }
}
