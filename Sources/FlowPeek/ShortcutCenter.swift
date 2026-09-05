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
    /// Actions whose stored combination the OS refused to hand over, which in practice means another
    /// process already owns it. Rebuilt whenever the registrations are — a launch, a recording, an
    /// assignment, a restore, or a change to which actions may hold a key — so a clash that appears
    /// months after the shortcut was recorded shows up the next time one of those happens.
    @Published private(set) var unavailableActions: Set<FlowPeekShortcutAction> = []
    /// Which actions may hold a hot key at all, per `ShortcutActivationPolicy`.
    @Published private(set) var activeActions = Set(FlowPeekShortcutAction.allCases)

    /// What each action does. Assigned once at start-up; re-registration does not disturb it.
    var handlers: [FlowPeekShortcutAction: () -> Void] = [:]

    private static let storageKey = "flowpeek.shortcuts"
    /// A field left recording holds every shortcut down, so the suspension gets an outer bound. Long
    /// enough that clicking the field and then thinking is not cut short and silently reverted.
    private static let recordingLifetime = Duration.seconds(60)

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "HotKey")
    private var hotKeys: [FlowPeekShortcutAction: GlobalHotKey] = [:]
    private var isSuspended = false
    /// Bumped by every begin and end, so a watchdog can tell its own session from a later one.
    private var recordingGeneration = 0
    /// The watchdog for the recording session that is open now, cancelled by the next begin or end
    /// so a minute of clicking record fields does not leave sixty of them sleeping.
    private var recordingWatchdog: Task<Void, Never>?
    /// Whether the live registrations have been built at least once; see `setActiveActions`.
    private var hasRegistered = false

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

    /// The policy's answer, applied. What left the set gives its hot key back to the rest of the
    /// system; what entered it takes one.
    func setActiveActions(_ actions: Set<FlowPeekShortcutAction>) {
        // `applyEnabledState()` runs on every switch in Settings and from the menu bar, and most of
        // those do not move this set. Re-registering anyway would drop and re-take every live
        // Carbon claim — a window in which another app can grab the combination — and redraw the
        // Shortcuts pane for nothing. The first call still has to register: `activeActions` starts
        // optimistic, so for a user with every feature on it already equals the policy's answer.
        guard actions != activeActions || !hasRegistered else { return }
        hasRegistered = true
        activeActions = actions
        registerAll()
    }

    /// Re-asks the OS for every combination that is supposed to be live, which is the only way a
    /// clash that appeared *while* the app was running becomes visible: `unavailableActions` is a
    /// record of the last registration, and `setActiveActions` deliberately does not register again
    /// when the active set has not moved. Paying `register(_:)`'s drop-and-retake on every switch is
    /// what that guard exists to avoid; paying it when the pane that draws the red line is open and
    /// the user is looking at it is not the same bargain. It is a price rather than a free second
    /// opinion, though: `register(_:)` gives the claim up before taking it again (GlobalHotKey.swift),
    /// so every live combination is briefly nobody's and a retake that loses turns a working hot key
    /// into the very line it was asked about. Which is why nothing but that pane calls this.
    func refreshAvailability() {
        registerAll()
    }

    /// Frees the keyboard for one field. Any field already recording is dropped first, so the
    /// suspension always has exactly one owner and can never be left dangling.
    func beginRecording(_ action: FlowPeekShortcutAction) {
        recordingAction = action
        recordingGeneration += 1
        let session = recordingGeneration
        // Everything that can take the keyboard away without a keystroke releases the suspension
        // itself, but a leak here disables every shortcut for the rest of the session with nothing
        // on screen to say so, so it also gets a floor it cannot fall through.
        recordingWatchdog?.cancel()
        recordingWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.recordingLifetime)
            guard let self, !Task.isCancelled, self.recordingGeneration == session else { return }
            self.endRecording()
        }
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
        logger.debug("hot keys suspended for recording")
    }

    func endRecording() {
        recordingAction = nil
        recordingGeneration += 1
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
        guard isSuspended else { return }
        isSuspended = false
        registerAll()
        logger.debug("hot keys resumed")
    }

    /// `noErr` when the OS actually handed the combination over. A dormant action reports `noErr`
    /// too: it holds nothing on purpose, which is not a failure.
    @discardableResult
    private func register(_ action: FlowPeekShortcutAction) -> OSStatus {
        guard activeActions.contains(action) else {
            hotKeys[action]?.unregister()
            hotKeys[action] = nil
            unavailableActions.remove(action)
            return noErr
        }
        let hotKey = hotKeys[action] ?? GlobalHotKey()
        hotKey.onPress = { [weak self] in self?.handlers[action]?() }
        let status = hotKey.register(shortcuts[action], for: action)
        hotKeys[action] = hotKey
        note(status, for: action)
        return status
    }

    private func note(_ status: OSStatus, for action: FlowPeekShortcutAction) {
        if status == noErr {
            unavailableActions.remove(action)
        } else {
            unavailableActions.insert(action)
        }
    }

    // MARK: - Editing

    /// `nil` on success. On failure nothing is stored and the previous claim is put back.
    @discardableResult
    func assign(
        keyCode: UInt16,
        modifiers: FlowPeekShortcut.Modifiers,
        to action: FlowPeekShortcutAction
    ) -> FlowPeekShortcut.ValidationError? {
        var updated = shortcuts
        if let error = updated.assign(keyCode: keyCode, modifiers: modifiers, to: action) { return error }
        let candidate = updated[action]
        // Ask the OS before storing anything: `RegisterEventHotKey` is the only thing that knows
        // whether another process already owns the combination. This runs while recording still has
        // every FlowPeek hot key suspended, so a refusal can only be coming from outside the app.
        let hotKey = hotKeys[action] ?? GlobalHotKey()
        hotKey.onPress = { [weak self] in self?.handlers[action]?() }
        let status = hotKey.register(candidate, for: action)
        guard status == noErr else {
            hotKey.unregister()
            hotKeys[action] = nil
            // Not while recording: `endRecording()` puts every claim back, and re-claiming the old
            // combination now would fire the action instead of letting the user record it.
            if !isSuspended { register(action) }
            logger.info("\(candidate.display, privacy: .public) refused: OSStatus \(status, privacy: .public)")
            return .claimedByAnotherApp(candidate.display)
        }
        hotKeys[action] = hotKey
        shortcuts = updated
        persist()
        note(status, for: action)
        if isSuspended || !activeActions.contains(action) {
            // The probe only borrowed the combination: while recording every claim is down, and a
            // dormant feature must not hold one at all. `register(_:)` takes it for real later.
            hotKey.unregister()
            hotKeys[action] = nil
        }
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
        // Restoring defaults mid-recording used to write shortcuts that `registerAll()` then skipped,
        // because a suspension was still in force; ending it first also drops the field out of
        // "Press keys", which is what the user asked for by pressing this. The defaults go in before
        // that, though: `endRecording()` registers on the way out, and doing it the other way round
        // claimed the custom combinations system-wide for the instant before they were discarded.
        shortcuts = .defaults
        persist()
        let wasSuspended = isSuspended
        endRecording()
        if !wasSuspended { registerAll() }
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
