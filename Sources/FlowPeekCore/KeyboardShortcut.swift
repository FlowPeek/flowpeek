import Foundation

/// A user-assignable global shortcut. Pure value type: no Carbon, no AppKit, so the validation and
/// the rendering are testable without a display. `keyCode` is a virtual key code (`kVK_*`), which is
/// layout-independent — the same physical key on a QWERTY and a Dvorak layout.
public struct FlowPeekShortcut: Equatable, Hashable, Codable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// Shift alone cannot carry a global shortcut: ⇧A is a capital A everywhere else.
        public static let anchoring: Modifiers = [.command, .option, .control]

        /// Symbols in the order macOS renders them.
        public var display: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text
        }
    }

    public enum ValidationError: LocalizedError, Equatable, Sendable {
        case noAnchoringModifier
        case reservedByTheSystem(String)
        case alreadyUsed(action: String)

        public var errorDescription: String? {
            switch self {
            case .noAnchoringModifier:
                "A global shortcut needs at least one of Command, Option, or Control."
            case .reservedByTheSystem(let name):
                "\(name) is reserved by macOS."
            case .alreadyUsed(let action):
                "That shortcut is already assigned to \(action)."
            }
        }

        /// The app layer owns the localized catalogue; core only names the case and its argument.
        public var localizationKey: String {
            switch self {
            case .noAnchoringModifier: "shortcut.error.no-modifier"
            case .reservedByTheSystem: "shortcut.error.reserved"
            case .alreadyUsed: "shortcut.error.already-used"
            }
        }

        public var localizationArgument: String? {
            switch self {
            case .noAnchoringModifier: nil
            case .reservedByTheSystem(let name): name
            case .alreadyUsed(let action): action
            }
        }
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var display: String { modifiers.display + Self.keyName(for: keyCode) }

    /// `nil` when the combination is assignable. `taken` maps an existing shortcut to the name of the
    /// action already using it, so the caller can report the clash instead of silently shadowing it.
    public static func validate(
        keyCode: UInt16,
        modifiers: Modifiers,
        taken: [FlowPeekShortcut: String] = [:]
    ) -> ValidationError? {
        guard !modifiers.isDisjoint(with: .anchoring) else { return .noAnchoringModifier }
        if let name = reserved[Reserved(keyCode: keyCode, modifiers: modifiers)] {
            return .reservedByTheSystem(name)
        }
        if let action = taken[FlowPeekShortcut(keyCode: keyCode, modifiers: modifiers)] {
            return .alreadyUsed(action: action)
        }
        return nil
    }

    // MARK: - Reserved combinations

    private struct Reserved: Hashable {
        let keyCode: UInt16
        let modifiers: Modifiers
    }

    /// Combinations macOS will never hand over. Registering them appears to succeed and then never
    /// fires, which reads as a broken shortcut, so they are refused up front.
    private static let reserved: [Reserved: String] = [
        Reserved(keyCode: 0x31, modifiers: [.command]): "⌘Space",
        Reserved(keyCode: 0x31, modifiers: [.command, .option]): "⌥⌘Space",
        Reserved(keyCode: 0x30, modifiers: [.command]): "⌘Tab",
        Reserved(keyCode: 0x30, modifiers: [.command, .shift]): "⇧⌘Tab",
        Reserved(keyCode: 0x0C, modifiers: [.command]): "⌘Q",
        Reserved(keyCode: 0x35, modifiers: [.command, .option]): "⌥⌘Esc",
    ]

    // MARK: - Key names

    /// Virtual key code to the glyph macOS shows in a menu. Unknown codes render as their number so a
    /// recorded shortcut is never blank.
    public static func keyName(for keyCode: UInt16) -> String {
        if let name = namedKeys[keyCode] { return name }
        if let character = characterKeys[keyCode] { return character }
        return "#\(keyCode)"
    }

    private static let characterKeys: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        0x18: "=", 0x1B: "-", 0x21: "[", 0x1E: "]", 0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".",
        0x2C: "/", 0x2A: "\\", 0x32: "`",
    ]

    private static let namedKeys: [UInt16: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]
}

/// The actions a shortcut can be bound to. Adding a case is all it takes to expose a new one in
/// Settings; the store and the recorder are driven by this list.
public enum FlowPeekShortcutAction: String, CaseIterable, Codable, Sendable {
    case previewClipboard
    case aiPrompt
    case ambientPeek

    public var defaultShortcut: FlowPeekShortcut {
        switch self {
        case .previewClipboard: FlowPeekShortcut(keyCode: 0x2E, modifiers: [.command, .option, .shift])
        case .aiPrompt: FlowPeekShortcut(keyCode: 0x2E, modifiers: [.command, .option])
        // The same virtual key the ambient monitor watched for: ⌥Space, now registered so macOS
        // hands it to FlowPeek instead of also typing a non-breaking space into the app underneath.
        case .ambientPeek: FlowPeekShortcut(keyCode: 0x31, modifiers: [.option])
        }
    }

    /// Stable identifier for the Carbon registration; never reuse a number.
    public var hotKeyID: UInt32 {
        switch self {
        case .aiPrompt: 1
        case .previewClipboard: 2
        case .ambientPeek: 3
        }
    }

    /// True for a chord that must only be claimed while its feature is running. A registered hot key
    /// is consumed system-wide, and ⌥Space is a character the user can still want to type, so it
    /// stays with the frontmost app until the ambient experiment is actually on.
    public var registersOnlyWhenActive: Bool {
        switch self {
        case .previewClipboard, .aiPrompt: false
        case .ambientPeek: true
        }
    }

    public var titleKey: String.LocalizationValue {
        switch self {
        case .previewClipboard: "shortcut.preview-clipboard"
        case .aiPrompt: "shortcut.ai-prompt"
        case .ambientPeek: "shortcut.ambient-peek"
        }
    }

    public var detailKey: String.LocalizationValue {
        switch self {
        case .previewClipboard: "shortcut.preview-clipboard.detail"
        case .aiPrompt: "shortcut.ai-prompt.detail"
        case .ambientPeek: "shortcut.ambient-peek.detail"
        }
    }
}

/// The whole assignment table. Pure so the conflict rules can be tested directly.
public struct FlowPeekShortcutSet: Equatable, Codable, Sendable {
    private var assignments: [FlowPeekShortcutAction: FlowPeekShortcut]

    public init(assignments: [FlowPeekShortcutAction: FlowPeekShortcut] = [:]) {
        self.assignments = assignments
    }

    public static var defaults: FlowPeekShortcutSet {
        FlowPeekShortcutSet(
            assignments: Dictionary(uniqueKeysWithValues: FlowPeekShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        )
    }

    public subscript(action: FlowPeekShortcutAction) -> FlowPeekShortcut {
        assignments[action] ?? action.defaultShortcut
    }

    public var isDefault: Bool { self == .defaults }

    /// Every shortcut except the one being edited, so a shortcut can be re-recorded onto itself.
    public func taken(excluding action: FlowPeekShortcutAction) -> [FlowPeekShortcut: String] {
        var result: [FlowPeekShortcut: String] = [:]
        for other in FlowPeekShortcutAction.allCases where other != action {
            result[self[other]] = String(localized: other.titleKey)
        }
        return result
    }

    public func validate(
        keyCode: UInt16,
        modifiers: FlowPeekShortcut.Modifiers,
        for action: FlowPeekShortcutAction
    ) -> FlowPeekShortcut.ValidationError? {
        FlowPeekShortcut.validate(keyCode: keyCode, modifiers: modifiers, taken: taken(excluding: action))
    }

    /// Applies the assignment, or returns why it was refused and leaves the set untouched.
    public mutating func assign(
        keyCode: UInt16,
        modifiers: FlowPeekShortcut.Modifiers,
        to action: FlowPeekShortcutAction
    ) -> FlowPeekShortcut.ValidationError? {
        if let error = validate(keyCode: keyCode, modifiers: modifiers, for: action) { return error }
        assignments[action] = FlowPeekShortcut(keyCode: keyCode, modifiers: modifiers)
        return nil
    }

    public mutating func reset(_ action: FlowPeekShortcutAction) {
        assignments[action] = action.defaultShortcut
    }

    public mutating func resetAll() {
        self = .defaults
    }
}
