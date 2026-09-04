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

    /// Writes the page under Caches rather than a temporary directory the system may sweep while
    /// the browser still has it open. Only FlowPeek's own sample text is written; nothing of the
    /// user's is ever put on disk.
    ///
    /// `lessons` is what the page teaches. Without the Accessibility grant that is the clipboard
    /// step alone: printing "a small button appears beside it" for a drag that can never raise one
    /// turns the practice page into evidence that the app is broken. `ambientEnabled` is the same
    /// argument one switch further in — pointing ships off, and the page cannot offer the switch.
    static func open(
        lessons: [TutorialProgress.Lesson] = TutorialProgress.Lesson.allCases,
        peekShortcut: String,
        ambientEnabled: Bool
    ) {
        do {
            let url = try write(lessons: lessons, peekShortcut: peekShortcut, ambientEnabled: ambientEnabled)
            if !NSWorkspace.shared.open(url) {
                logger.error("no application accepted \(url.lastPathComponent, privacy: .public)")
                NSSound.beep()
            }
        } catch {
            logger.error("could not write the practice page: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static func write(
        lessons: [TutorialProgress.Lesson],
        peekShortcut: String,
        ambientEnabled: Bool
    ) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(Bundle.main.bundleIdentifier ?? "FlowPeek", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("practice.html")
        try html(lessons: lessons, peekShortcut: peekShortcut, ambientEnabled: ambientEnabled)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func html(
        lessons: [TutorialProgress.Lesson],
        peekShortcut: String,
        ambientEnabled: Bool
    ) -> String {
        // Localized through the app catalogue so the practice page speaks the same language as the
        // onboarding window it was opened from.
        let title = String(localized: "tutorial.page.title")
        let blocked = lessons.filter { !$0.canFire(ambientPeekEnabled: ambientEnabled) }
        // "Every gesture below behaves exactly as it will from now on" is a lie the moment one of
        // them is switched off, and it is the sentence the reader trusts when nothing happens.
        let intro = String(localized: blocked.isEmpty ? "tutorial.page.intro" : "tutorial.page.intro.blocked")
        let hint = String(localized: "tutorial.page.hint")
        let steps = lessons
            .map { lesson in
                if blocked.contains(lesson), let switchedOff = lesson.switchedOffDetailKey {
                    return "<li class=\"locked\">\(escape(String(localized: switchedOff)))</li>"
                }
                return "<li>\(escape(lesson.detail(peekShortcut: peekShortcut)))</li>"
            }
            .joined(separator: "\n    ")
        let closing = String(localized: lessons.count > 1 ? "tutorial.page.closing" : "tutorial.page.closing.one")

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
                padding: 22px 24px; border-radius: 12px; margin: 0 0 10px;
                white-space: pre; overflow-x: auto; cursor: pointer }
          pre:hover, pre:focus { outline: 2px solid color-mix(in srgb, currentColor 28%, transparent) }
          p.hint { font-size: 13px; color: color-mix(in srgb, currentColor 62%, transparent);
                   margin: 0 0 28px }
          ol { padding-left: 22px; margin: 0 0 28px }
          li { margin-bottom: 10px }
          li.locked { opacity: .55 }
          kbd { font: 12px ui-monospace, monospace; padding: 2px 6px; border-radius: 5px;
                background: color-mix(in srgb, currentColor 12%, transparent) }
          p.closing { color: color-mix(in srgb, currentColor 62%, transparent); margin: 0 }
        </style></head>
        <body><main>
          <h1>\(escape(title))</h1>
          <p class="intro">\(escape(intro))</p>
          <pre tabindex="0" onclick="getSelection().selectAllChildren(this)">\(escape(TutorialSample.text))</pre>
          <p class="hint">\(escape(hint))</p>
          <ol>
            \(steps)
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
