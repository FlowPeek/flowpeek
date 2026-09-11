import Foundation

/// Why a gesture in VS Code found nothing, when the reason is a switch only the reader can throw.
///
/// VS Code hands its text to macOS only when `editor.accessibilitySupport` is `on`. The setting
/// ships as `auto`, which means "on when a screen reader is running", and FlowPeek is not a screen
/// reader and cannot answer to that. Measured on a default install: the focused element is an
/// `AXGroup` carrying zero characters, and it stays that way whatever FlowPeek asks it. With the
/// setting on, the same element is an `AXTextArea` holding the whole document.
///
/// So the app does nothing there, and doing nothing is indistinguishable from being broken. This
/// decides when to say which of the two it is. It is a notice rather than a fix because the switch
/// belongs to the editor: no amount of accessibility permission lets one application change
/// another's settings, and writing into somebody else's settings file behind their back is not on
/// the table.
public enum EditorAccessibilityNotice {
    // MARK: - Which editor this is

    /// What an editor says about itself, out of the file every VS Code build carries.
    ///
    /// Identified by that file rather than by a list of bundle identifiers. VS Code is forked
    /// constantly -- Cursor, Antigravity, Trae, Kiro, Positron, Void, and whatever ships next
    /// month -- and every one of them inherits this setting, this default, and this problem. A list
    /// would be out of date the week it was written, and an editor missing from it would leave its
    /// reader with the silence this whole type exists to explain.
    public struct Product: Equatable, Sendable {
        /// The name the editor files its data under. `Code` for VS Code itself, and it is exactly
        /// the directory in Application Support: verified against the installed editor, and against
        /// the directories Homebrew removes for six different forks.
        public let nameShort: String
        /// The product's own name, for saying which editor is being talked about.
        public let nameLong: String
        public let bundleIdentifier: String?

        public init(nameShort: String, nameLong: String, bundleIdentifier: String?) {
            self.nameShort = nameShort
            self.nameLong = nameLong
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// Where the product file sits inside an application bundle.
    public static let productPath = ["Contents", "Resources", "app", "product.json"]

    /// Reads a product file, or answers nil for an application that is not one of these editors.
    ///
    /// The keys are required rather than defaulted: a file that does not name the editor is not a
    /// file this can act on, and guessing a data directory is guessing where somebody's settings
    /// live.
    public static func product(fromProductJSON data: Data) -> Product? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nameShort = object["nameShort"] as? String, !nameShort.isEmpty,
              // Present in every build of this editor and in nothing else that ships a product.json.
              object["applicationName"] is String else {
            return nil
        }
        // A name that is a path is not a name. Everything here is used to build a path, so a
        // separator in it would leave that path somewhere else entirely.
        guard !nameShort.contains("/"), nameShort != ".", nameShort != ".." else { return nil }
        return Product(
            nameShort: nameShort,
            nameLong: object["nameLong"] as? String ?? nameShort,
            bundleIdentifier: object["darwinBundleIdentifier"] as? String
        )
    }

    /// Where that editor keeps the reader's own settings, relative to the Library directory.
    public static func userSettingsPath(of product: Product) -> [String] {
        ["Application Support", product.nameShort, "User", "settings.json"]
    }

    // MARK: - What the setting says

    /// What the reader's settings say about the switch.
    public enum Support: Equatable, Sendable {
        /// Explicitly on. The editor is exposing its text and a silent gesture means something else.
        case on
        /// `auto`, which is on only for a real screen reader, so off as far as FlowPeek is concerned.
        case auto
        case off
        /// No settings file, or no such key in it. The default is `auto`, so this reads the same way.
        case unknown

        /// Whether the editor can be read as things stand.
        public var exposesText: Bool { self == .on }
    }

    /// Reads the setting out of an editor's user settings file.
    ///
    /// Scanned rather than parsed. That file is JSON with comments and trailing commas allowed, so
    /// a strict parser refuses perfectly ordinary settings files, and the one key this needs is
    /// unambiguous enough to find without understanding the rest of the document.
    public static func support(inUserSettings text: String) -> Support {
        guard let range = text.range(of: "\"editor.accessibilitySupport\"") else { return .unknown }
        let tail = text[range.upperBound...].prefix(64)
        guard let colon = tail.firstIndex(of: ":") else { return .unknown }
        let value = tail[tail.index(after: colon)...]
            .drop(while: { $0 == " " || $0 == "\t" || $0 == "\"" })
            .prefix(while: { $0.isLetter })
        switch value.lowercased() {
        case "on": return .on
        case "off": return .off
        case "auto": return .auto
        default: return .unknown
        }
    }

    // MARK: - When to say it

    /// A burst of holds is one question, not several. Under this, the badge that is already up is
    /// the answer.
    public static let repeatInterval: TimeInterval = 60

    /// How many times one run of the app will explain this. The reader who has read it twice and
    /// carried on without changing the setting has decided; a third telling is nagging, and the
    /// answer stays in the README either way.
    public static let maximumTellings = 2

    /// Whether to put the notice up for a gesture that found nothing.
    ///
    /// - Parameters:
    ///   - support: what the settings file says. `on` means the editor is already exposing its
    ///     text, so a silent gesture is a document with no diagram in it and there is nothing to
    ///     explain. This is the whole of the guard against telling somebody to do what they have
    ///     already done.
    ///   - told: how many times this run has already explained it.
    ///   - lastTold: when it last did.
    public static func shouldTell(
        support: Support,
        told: Int,
        lastTold: Date?,
        now: Date
    ) -> Bool {
        guard !support.exposesText else { return false }
        guard told < maximumTellings else { return false }
        guard let lastTold else { return true }
        return now.timeIntervalSince(lastTold) >= repeatInterval
    }
}
