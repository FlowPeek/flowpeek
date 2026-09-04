import AppKit
import Carbon.HIToolbox
import FlowPeekCore
import OSLog

/// Owns every global shortcut: what it is, where it is stored, and its Carbon registration. Also the
/// one place that can suspend the registrations — which the recorder needs, because a registered
/// hot key is consumed system-wide and would never reach the field trying to record it.
@MainActor
final class ShortcutCenter: ObservableObject {
    @Published private(set) var shortcuts: FlowPeekShortcutSet
    /// Exactly one field can be recording: a second one would leave the first stuck showing "Press
    /// keys" while quietly losing its claim on the suspension.
    @Published private(set) var recordingAction: FlowPeekShortcutAction?

    /// What each action does. Assigned once at start-up; re-registration does not disturb it.
    var handlers: [FlowPeekShortcutAction: () -> Void] = [:]

    private static let storageKey = "flowpeek.shortcuts"

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "HotKey")
    private var hotKeys: [FlowPeekShortcutAction: GlobalHotKey] = [:]
    private var isSuspended = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(FlowPeekShortcutSet.self, from: data) {
            shortcuts = stored
        } else {
            shortcuts = .defaults
        }
    }

    // MARK: - Registration

    func registerAll() {
        guard !isSuspended else { return }
        for action in FlowPeekShortcutAction.allCases { register(action) }
    }

    func unregisterAll() {
        hotKeys.values.forEach { $0.unregister() }
        hotKeys.removeAll()
    }

    /// Frees the keyboard for one field. Any field already recording is dropped first, so the
    /// suspension always has exactly one owner and can never be left dangling.
    func beginRecording(_ action: FlowPeekShortcutAction) {
        recordingAction = action
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
        logger.debug("hot keys suspended for recording")
    }

    func endRecording() {
        recordingAction = nil
        guard isSuspended else { return }
        isSuspended = false
        registerAll()
        logger.debug("hot keys resumed")
    }

    private func register(_ action: FlowPeekShortcutAction) {
        let hotKey = hotKeys[action] ?? GlobalHotKey()
        hotKey.onPress = { [weak self] in self?.handlers[action]?() }
        hotKey.register(shortcuts[action], for: action)
        hotKeys[action] = hotKey
    }

    // MARK: - Editing

    /// `nil` on success. On failure nothing is stored and nothing is re-registered.
    @discardableResult
    func assign(
        keyCode: UInt16,
        modifiers: FlowPeekShortcut.Modifiers,
        to action: FlowPeekShortcutAction
    ) -> FlowPeekShortcut.ValidationError? {
        var updated = shortcuts
        if let error = updated.assign(keyCode: keyCode, modifiers: modifiers, to: action) { return error }
        shortcuts = updated
        persist()
        register(action)
        return nil
    }

    func reset(_ action: FlowPeekShortcutAction) {
        var updated = shortcuts
        updated.reset(action)
        shortcuts = updated
        persist()
        register(action)
    }

    func resetAll() {
        shortcuts = .defaults
        persist()
        registerAll()
    }

    func validate(
        keyCode: UInt16,
        modifiers: FlowPeekShortcut.Modifiers,
        for action: FlowPeekShortcutAction
    ) -> FlowPeekShortcut.ValidationError? {
        shortcuts.validate(keyCode: keyCode, modifiers: modifiers, for: action)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(shortcuts) else {
            logger.error("could not encode the shortcut set; keeping the previous stored value")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension FlowPeekShortcut.Modifiers {
    /// The Carbon flags `RegisterEventHotKey` expects.
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: FlowPeekShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
