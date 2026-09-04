import Foundation

/// The in-app language override. macOS reads `AppleLanguages` out of the app's own defaults domain
/// at launch, so a change here is a stored preference plus a relaunch — not a live re-render.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case korean

    public static let defaultsKey = "AppleLanguages"

    public var id: String { rawValue }

    /// `nil` means "follow the system", which is expressed by removing the override entirely.
    public var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .korean: "ko"
        }
    }

    public var titleKey: String.LocalizationValue {
        switch self {
        case .system: "settings.language.system"
        case .english: "settings.language.english"
        case .korean: "settings.language.korean"
        }
    }

    /// The value to store under `AppleLanguages`, or `nil` to remove the key.
    public var storedValue: [String]? {
        localeIdentifier.map { [$0] }
    }

    /// Reads back whatever is stored, tolerating the fact that macOS also writes this key itself:
    /// a stored list may carry a region ("ko-KR") or several languages, and anything that is not one
    /// of ours is reported as `.system` rather than being silently overwritten.
    public static func stored(in languages: [String]?) -> AppLanguage {
        guard let first = languages?.first else { return .system }
        let base = first.split(separator: "-").first.map(String.init) ?? first
        return allCases.first { $0.localeIdentifier == base } ?? .system
    }
}
