import Foundation

/// Which actions may hold a global hot key right now. A registered hot key is consumed system-wide:
/// holding one for a switched-off feature takes the combination away from whatever app the user is
/// in and then does nothing with it, which is indistinguishable from a broken keyboard.
public enum ShortcutActivationPolicy {
    public static func activeActions(
        isEnabled: Bool,
        clipboardWatchEnabled: Bool,
        aiEnabled: Bool,
        ambientPeekEnabled: Bool = false,
        accessibilityGranted: Bool = false
    ) -> Set<FlowPeekShortcutAction> {
        guard isEnabled else { return [] }
        var actions: Set<FlowPeekShortcutAction> = []
        if clipboardWatchEnabled { actions.insert(.previewClipboard) }
        if aiEnabled { actions.insert(.aiPrompt) }
        // Ambient peek reads the accessibility tree, so without the grant the feature cannot raise
        // an outline at all and its chord — ⌥Space, a character people type — must stay where it is.
        if ambientPeekEnabled && accessibilityGranted { actions.insert(.ambientPeek) }
        return actions
    }
}
