import FlowPeekCore
import SwiftUI

@main
struct FlowPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The icon is this app's only permanent surface, so it has to be the first place a paused,
    /// unpermitted or broken FlowPeek admits it.
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var updater = AppState.shared.updater

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
        MenuBarExtra(isInserted: inserted) {
            MenuBarContent()
                .environmentObject(app)
                // The panel hangs off the icon, so while it is open the icon may not be taken away
                // underneath it -- a menu closing itself out from under the pointer is worse than
                // one that stays a moment too long.
                .onAppear { app.setMenuBarPanelOpen(true) }
                .onDisappear { app.setMenuBarPanelOpen(false) }
        } label: {
            MenuBarIcon(status: app.menuBarStatus, hasUpdate: updater.state.wantsAttention)
        }
        // A window, not a menu: `MenuBarContent` draws FlowPeek's own panel -- a status line, the
        // diagrams the user made with the glyph of the route that made each one, and switches --
        // and a system menu can only draw a column of words.
        .menuBarExtraStyle(.window)
    }
}

/// The mark in the menu bar, and the one dot that says there is something waiting.
///
/// A `label:` closure rather than the `systemImage:` initialiser, which cannot draw anything beside
/// the glyph. The template rendering that initialiser gives for free is asked for explicitly here
/// instead, so the mark still inverts with the menu bar the way every other item does.
///
/// The dot never replaces the mark. An icon that turns into something else to announce news is an
/// icon nobody can find afterwards, and the states this app already draws there -- paused,
/// unpermitted, broken -- are about whether it is working, which outranks whether it is current.
struct MenuBarIcon: View {
    let status: MenuBarStatus
    let hasUpdate: Bool

    var body: some View {
        Image(systemName: status.symbolName)
            .renderingMode(.template)
            .overlay(alignment: .topTrailing) {
                if hasUpdate {
                    // Drawn, not templated: the point of it is to be seen against a mark that is
                    // whatever colour the menu bar makes it.
                    Circle()
                        .fill(.tint)
                        .frame(width: 5, height: 5)
                        .offset(x: 3, y: -2)
                }
            }
    }
}
