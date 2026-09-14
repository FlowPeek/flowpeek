import FlowPeekCore
import SwiftUI

@main
struct FlowPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The icon is this app's only permanent surface, so it has to be the first place a paused,
    /// unpermitted or broken FlowPeek admits it. Observed here rather than inside a `label:` closure
    /// on purpose: the `systemImage:` initializer keeps the native template rendering and sizing.
    @ObservedObject private var app = AppState.shared

    /// Whether the icon is in the menu bar, and what it means when something else takes it out.
    ///
    /// The setter is not dead. macOS lets a reader drag a menu bar item away with Command held, and
    /// SwiftUI reports that by writing `false` here; without somewhere for it to land the item
    /// would come back at the next state change and the drag would read as broken. So a removal
    /// nobody asked for is taken as the request it plainly is, and the same gesture brings it back.
    private var inserted: Binding<Bool> {
        Binding(
            get: { app.menuBarPresent },
            set: { present in
                guard !present, !app.menuBarHidden else { return }
                app.menuBarHidden = true
            }
        )
    }

    var body: some Scene {
        MenuBarExtra(
            "FlowPeek",
            systemImage: app.menuBarStatus.symbolName,
            isInserted: inserted
        ) {
            MenuBarContent()
                .environmentObject(app)
                // The panel hangs off the icon, so while it is open the icon may not be taken away
                // underneath it -- a menu closing itself out from under the pointer is worse than
                // one that stays a moment too long.
                .onAppear { app.setMenuBarPanelOpen(true) }
                .onDisappear { app.setMenuBarPanelOpen(false) }
        }
        // A window, not a menu: `MenuBarContent` draws FlowPeek's own panel -- a status line, the
        // diagrams the user made with the glyph of the route that made each one, and switches --
        // and a system menu can only draw a column of words.
        .menuBarExtraStyle(.window)
    }
}
