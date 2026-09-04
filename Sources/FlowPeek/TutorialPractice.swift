import AppKit
import FlowPeekCore
import OSLog

/// Opens a practice page in the user's own browser.
///
/// The page cannot live inside FlowPeek's own window: `AccessibilitySelectionReader` deliberately
/// refuses to read its own process, so a drag inside the onboarding window would never produce an
/// overlay button, and the ambient reader skips it for the same reason. Practising has to happen in
/// another application, and a browser is both the measured-good case for every route and the place
/// people actually meet Mermaid.
@MainActor
enum TutorialPractice {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek",
        category: "Tutorial"
    )

    static let sample = """
    flowchart TD
      A[Copy or select this] --> B{FlowPeek notices}
      B -- overlay button --> C[Preview]
      B -- badge --> C
      B -- hold Option --> C
    """

    /// Writes the page under Caches rather than a temporary directory the system may sweep while
    /// the browser still has it open. Only FlowPeek's own sample text is written; nothing of the
    /// user's is ever put on disk.
    static func open() {
        do {
            let url = try write()
            if !NSWorkspace.shared.open(url) {
                logger.error("no application accepted \(url.lastPathComponent, privacy: .public)")
                NSSound.beep()
            }
        } catch {
            logger.error("could not write the practice page: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static func write() throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(Bundle.main.bundleIdentifier ?? "FlowPeek", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("practice.html")
        try html().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func html() -> String {
        // Localized through the app catalogue so the practice page speaks the same language as the
        // onboarding window it was opened from.
        let title = String(localized: "tutorial.page.title")
        let intro = String(localized: "tutorial.page.intro")
        let selection = String(localized: "tutorial.selection.detail")
        let clipboard = String(localized: "tutorial.clipboard.detail")
        let ambient = String(localized: "tutorial.ambient.detail")
        let closing = String(localized: "tutorial.page.closing")

        return """
        <!doctype html>
        <html lang="\(Locale.current.language.languageCode?.identifier ?? "en")">
        <head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
          :root { color-scheme: light dark }
          body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
                 margin: 0; padding: 56px 32px; display: flex; justify-content: center }
          main { max-width: 620px }
          h1 { font-size: 26px; margin: 0 0 8px }
          p.intro { color: color-mix(in srgb, currentColor 62%, transparent); margin: 0 0 28px }
          pre { font: 14px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
                background: color-mix(in srgb, currentColor 7%, transparent);
                padding: 22px 24px; border-radius: 12px; margin: 0 0 28px;
                white-space: pre; overflow-x: auto }
          ol { padding-left: 22px; margin: 0 0 28px }
          li { margin-bottom: 10px }
          kbd { font: 12px ui-monospace, monospace; padding: 2px 6px; border-radius: 5px;
                background: color-mix(in srgb, currentColor 12%, transparent) }
          p.closing { color: color-mix(in srgb, currentColor 62%, transparent); margin: 0 }
        </style></head>
        <body><main>
          <h1>\(escape(title))</h1>
          <p class="intro">\(escape(intro))</p>
          <pre>\(escape(sample))</pre>
          <ol>
            <li>\(escape(selection))</li>
            <li>\(escape(clipboard))</li>
            <li>\(escape(ambient))</li>
          </ol>
          <p class="closing">\(escape(closing))</p>
        </main></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
