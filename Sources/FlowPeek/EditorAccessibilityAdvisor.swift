import AppKit
import FlowPeekCore
import OSLog

/// Decides whether a gesture that found nothing was silent because of the editor's own switch, and
/// says so at most twice.
///
/// The whole point is to tell the difference between "there is no diagram here" and "this editor is
/// not handing its text to macOS". Both look identical from the outside -- the app does nothing --
/// and one of them is the app working correctly while the other is a setting away from working at
/// all. Guessing between them would be worse than silence, so this reads the editor's own settings
/// file and only speaks when that file says the switch is not on.
@MainActor
final class EditorAccessibilityAdvisor {
    /// Where the steps are written down. The README's own question, so there is one answer to keep
    /// current rather than two.
    static let helpURL = "https://github.com/FlowPeek/flowpeek#flowpeek-sees-nothing-in-vs-code-why"

    struct Notice: Equatable {
        /// The editor's own name, so the badge says "Cursor" to somebody using Cursor.
        let editorName: String
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Editors")
    private let fileManager = FileManager.default
    private let library: URL
    /// Read once per application bundle. A product file does not change while the app is on disk,
    /// and this runs on a gesture that found nothing, which happens in every application.
    private var products: [URL: EditorAccessibilityNotice.Product?] = [:]
    private var told = 0
    private var lastTold: Date?

    init(library: URL? = nil) {
        self.library = library
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    }

    /// A notice to put in front of the reader, or nil when there is nothing worth saying.
    func notice(for application: NSRunningApplication, now: Date = Date()) -> Notice? {
        guard let bundle = application.bundleURL, let product = product(at: bundle) else { return nil }
        // The settings file is re-read rather than remembered: the reader may have just changed it,
        // and this is the moment they would be looking for the app to notice.
        let settings = EditorAccessibilityNotice
            .userSettingsPath(of: product)
            .reduce(library) { $0.appendingPathComponent($1) }
        let text = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
        let support = EditorAccessibilityNotice.support(inUserSettings: text)
        guard EditorAccessibilityNotice.shouldTell(
            support: support, told: told, lastTold: lastTold, now: now
        ) else { return nil }
        told += 1
        lastTold = now
        logger.info(
            "told the reader that \(product.nameLong, privacy: .public) is not exposing its text"
        )
        return Notice(editorName: product.nameLong)
    }

    /// What the application says it is, out of the file every build of this editor carries.
    private func product(at bundle: URL) -> EditorAccessibilityNotice.Product? {
        if let known = products[bundle] { return known }
        let file = EditorAccessibilityNotice.productPath.reduce(bundle) { $0.appendingPathComponent($1) }
        let product = (try? Data(contentsOf: file)).flatMap(EditorAccessibilityNotice.product(fromProductJSON:))
        products[bundle] = product
        return product
    }
}
