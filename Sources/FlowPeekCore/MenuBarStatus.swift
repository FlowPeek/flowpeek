/// What the menu-bar icon is saying about FlowPeek right now.
///
/// Only states the user can act on. There is deliberately no "warming up" case and none for a
/// degraded-but-working engine: an icon that changes while nothing is being asked of anyone teaches
/// people to stop reading it, and then the one change that mattered is invisible too.
public enum MenuBarStatus: Sendable, Equatable, CaseIterable {
    /// At least one detection route is live.
    case armed
    /// The user paused detection themselves. Nothing is broken; nothing is watching either.
    case paused
    /// Accessibility is missing and the user never said they wanted it that way, so the button
    /// beside a selection and the Option-hover outline cannot appear at all.
    case permissionMissing
    /// Detection is on and nothing is broken, yet every route that could notice a diagram is
    /// switched off: no grant, so selection and the outline are impossible, and the clipboard
    /// watch turned off too.
    case nothingWatched
    /// The canary render failed: no route can produce a diagram.
    case engineBroken

    /// `permissionDeclined` is what keeps this from becoming a permanent scold: someone who
    /// answered "continue without it" and lives on the clipboard route has a working app, and a
    /// warning badge that never goes away is one they would be right to ignore. It buys silence
    /// about the grant, not a claim to be watching — that is what `clipboardWatchEnabled` decides.
    public static func resolve(
        engineUsable: Bool,
        accessibilityGranted: Bool,
        permissionDeclined: Bool,
        isEnabled: Bool,
        clipboardWatchEnabled: Bool
    ) -> MenuBarStatus {
        // A broken engine outranks everything: neither granting permission nor un-pausing produces
        // a diagram while the renderer cannot draw its own canary. A missing grant outranks the
        // pause because the pause is the user's own doing and the switch that undoes it is in the
        // same menu, whereas a grant that went away is news.
        if !engineUsable { return .engineBroken }
        if !accessibilityGranted && !permissionDeclined { return .permissionMissing }
        if !isEnabled { return .paused }
        // Selection and the ambient outline both read the accessibility tree, so the grant is the
        // whole question for them; ambient adds nothing here because it cannot run without the
        // grant either. With none of them possible and the clipboard watch off, "Ready — watching
        // for diagrams" would be a sentence about an app that is watching nothing.
        if !accessibilityGranted && !clipboardWatchEnabled { return .nothingWatched }
        return .armed
    }

    /// The SF Symbol the status item draws. One glyph per state, so the icon can be read at a
    /// glance; `pause.circle`, `eye.slash`, `exclamationmark.triangle.fill` and
    /// `exclamationmark.octagon.fill` have all shipped since macOS 11, and there is no `.slash`
    /// variant of the armed glyph to fall back on.
    public var symbolName: String {
        switch self {
        case .armed: "point.3.connected.trianglepath.dotted"
        case .paused: "pause.circle"
        case .permissionMissing: "exclamationmark.triangle.fill"
        case .nothingWatched: "eye.slash"
        case .engineBroken: "exclamationmark.octagon.fill"
        }
    }
}
