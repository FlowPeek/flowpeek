import Foundation
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

    /// What the icon is entitled to say about the engine while a fresh canary is in flight.
    ///
    /// `latest` is absent for the length of a re-check: the verdict being re-taken must not be
    /// displayed as the current one. That gap is not evidence of a cure, and reading it as one is
    /// what turned the broken-engine octagon into "Ready — watching for diagrams" for the whole
    /// duration of a check the user asked for *because* the engine had just failed. Before the very
    /// first canary there is no measurement at all and `lastMeasured` is true there: an icon that
    /// warns before it has evidence is one people learn to stop reading.
    public static func engineUsable(latest: Bool?, lastMeasured: Bool) -> Bool {
        latest ?? lastMeasured
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

/// The one thing worth offering to do about the state the icon is drawing.
///
/// The menu used to carry a row for every complaint at once: a line about the permission, a button
/// for it, a line about the engine, a button for it, a line about a shortcut and a button for that
/// — up to six rows, in a menu whose other half is eight. They are not independent, though. Only
/// one of them is the reason FlowPeek is not doing its job, and it is the same one the icon has
/// already picked, so the menu offers that one and stays the same shape whatever is wrong.
public enum MenuBarRemedy: Equatable, Sendable {
    case grantPermission
    case recheckEngine
    case fixShortcut

    public var titleKey: String.LocalizationValue {
        switch self {
        case .grantPermission: "permission.open-settings"
        case .recheckEngine: "menu.engine.recheck"
        case .fixShortcut: "menu.shortcuts.fix"
        }
    }

    /// - Parameters:
    ///   - isCheckingEngine: nothing is offered while the canary is still running; the answer that
    ///     would decide what to offer has not arrived.
    ///   - hasUnavailableShortcut: a combination macOS refused to hand over. Last in precedence:
    ///     the feature behind it is reachable from the menu anyway, where a missing permission or a
    ///     broken engine leaves nothing working at all.
    public static func resolve(
        status: MenuBarStatus,
        isCheckingEngine: Bool,
        engineComplained: Bool,
        hasUnavailableShortcut: Bool
    ) -> MenuBarRemedy? {
        guard !isCheckingEngine else { return nil }
        switch status {
        case .engineBroken: return .recheckEngine
        case .permissionMissing, .nothingWatched: return .grantPermission
        case .armed, .paused:
            // A degraded engine that still draws: worth offering the re-check, because the verdict
            // is one canary at one launch and taking it again is the only way to move it.
            if engineComplained { return .recheckEngine }
            return hasUnavailableShortcut ? .fixShortcut : nil
        }
    }
}
