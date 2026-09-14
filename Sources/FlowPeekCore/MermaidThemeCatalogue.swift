import Foundation

/// Which look a diagram is drawn in.
///
/// A raw-valued enum because the choice is persisted: the string is written to the reader's
/// defaults and has to survive across releases, so these cases are named once and never renamed.
/// Removing a case is allowed -- `id(rawValue:)` degrades a stored id it no longer recognises back
/// to the default rather than failing -- but renaming one would silently reset every reader who had
/// chosen it.
public enum MermaidThemeID: String, CaseIterable, Codable, Sendable {
    /// The look FlowPeek has always drawn: the system font, the system palette, the reader's accent.
    case system
    /// An imitation of the editorial language at github.com/cathrynlavery/diagram-design, as far as
    /// mermaid can be made to go. Experimental: what mermaid cannot express is skipped, not faked.
    case editorial
}

/// What the settings card and the preview need to know about a theme without knowing what it looks
/// like. Views iterate these, so adding a theme never means editing a view.
public struct MermaidThemeDescriptor: Equatable, Sendable {
    public let id: MermaidThemeID
    /// Localisation keys rather than strings: the catalogue lives in Core, which has no bundle of
    /// its own, and the names have to exist in both catalogues anyway.
    public let nameKey: String
    public let blurbKey: String
    /// Whether to mark it as an experiment where it is offered. The only boolean here on purpose:
    /// anything else a theme wants to say about itself belongs in its blurb.
    public let isExperimental: Bool

    public init(id: MermaidThemeID, nameKey: String, blurbKey: String, isExperimental: Bool) {
        self.id = id
        self.nameKey = nameKey
        self.blurbKey = blurbKey
        self.isExperimental = isExperimental
    }
}

/// The themes there are.
///
/// A compiled list rather than anything loadable. There is no plug-in mechanism, no user-authored
/// theme and no theme file on disk, because a theme is a set of values that has to be tested against
/// the renderer it feeds, and a value somebody typed into a file has been tested against nothing.
///
/// Adding one costs a case above, a factory beside `MacMermaidTheme.system`, a row here, and two
/// strings in each language. The `switch` in `theme(_:...)` is exhaustive, so the compiler names the
/// one place that still needs work, and `LocalizationCatalogueTests` reads `localizationKeys` and
/// fails if either language is missing either string.
public enum MermaidThemeCatalogue {
    /// What an unreadable or retired stored id becomes. Also what a reader who has chosen nothing
    /// gets, which is why it is the one theme that may never be experimental.
    public static let fallback: MermaidThemeID = .system

    public static let all: [MermaidThemeDescriptor] = [
        .init(id: .system, nameKey: "theme.system.name", blurbKey: "theme.system.blurb", isExperimental: false),
        .init(id: .editorial, nameKey: "theme.editorial.name", blurbKey: "theme.editorial.blurb", isExperimental: true),
    ]

    public static func descriptor(_ id: MermaidThemeID) -> MermaidThemeDescriptor {
        all.first { $0.id == id } ?? all[0]
    }

    /// A stored string turned back into a theme, forgivingly.
    ///
    /// Never `MermaidThemeID(rawValue:)!`. The stored value comes from a defaults domain the reader
    /// can edit and an older build can have written, so an id that no longer exists has to mean
    /// "draw the default", not a crash on the first render.
    public static func id(rawValue: String?) -> MermaidThemeID {
        guard let rawValue, let known = MermaidThemeID(rawValue: rawValue) else { return fallback }
        return known
    }

    public static func theme(
        _ id: MermaidThemeID,
        appearance: MacMermaidTheme.Appearance,
        accentHex: String,
        increaseContrast: Bool
    ) -> MacMermaidTheme {
        switch id {
        case .system:
            return .system(appearance: appearance, accentHex: accentHex, increaseContrast: increaseContrast)
        case .editorial:
            // No `accentHex`: this theme's accent is its own, and why is on `MacMermaidTheme.editorial`.
            return .editorial(appearance: appearance, increaseContrast: increaseContrast)
        }
    }

    /// Every key the catalogue expects to find in both string catalogues, so a theme added without
    /// its Korean name is a failing test rather than a raw key drawn in a menu.
    public static var localizationKeys: [String] {
        all.flatMap { [$0.nameKey, $0.blurbKey] }
    }
}
