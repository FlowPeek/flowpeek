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
    /// turns the practice page into evidence that the app is broken. `switches` is the same argument
    /// one layer further in — a paused or half-switched-off FlowPeek is listening for fewer of the
    /// three than the page would otherwise promise, and the page carries no switches of its own.
    static func open(
        lessons: [TutorialProgress.Lesson] = TutorialProgress.Lesson.allCases,
        peekShortcut: String,
        switches: TutorialProgress.Switches
    ) {
        do {
            let url = try write(lessons: lessons, peekShortcut: peekShortcut, switches: switches)
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
        switches: TutorialProgress.Switches
    ) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(Bundle.main.bundleIdentifier ?? "FlowPeek", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("practice.html")
        try html(lessons: lessons, peekShortcut: peekShortcut, switches: switches)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func html(
        lessons: [TutorialProgress.Lesson],
        peekShortcut: String,
        switches: TutorialProgress.Switches
    ) -> String {
        // Localized through the app catalogue so the practice page speaks the same language as the
        // onboarding window it was opened from.
        let title = String(localized: "tutorial.page.title")
        // Each blocked lesson prints the switch that is in the way rather than an instruction it
        // cannot follow, and the switch is named because none of them is on this page.
        let blockers = lessons.reduce(into: [TutorialProgress.Lesson: TutorialProgress.Blocker]()) { result, lesson in
            if let blocker = lesson.blocker(switches) { result[lesson] = blocker }
        }
        // "Every gesture below behaves exactly as it will from now on" is a lie the moment one of
        // them is switched off, and it is the sentence the reader trusts when nothing happens.
        let intro = String(localized: blockers.isEmpty ? "tutorial.page.intro" : "tutorial.page.intro.blocked")
        let hint = String(localized: "tutorial.page.hint")
        let steps = lessons
            .map { lesson in
                if let blocker = blockers[lesson] {
                    return "<li class=\"locked\">\(escape(blocker.detail))</li>"
                }
                return "<li>\(escape(lesson.detail(peekShortcut: peekShortcut)))</li>"
            }
            .joined(separator: "\n    ")
        let closing = String(localized: lessons.count > 1 ? "tutorial.page.closing" : "tutorial.page.closing.one")
        // One click selects the whole block, which is what removes most partial drags. The same
        // thing has to be reachable from the keyboard: the block is focusable, so Return and Space
        // have to do what the click does, or the only way left to select it is the drag this page
        // exists to talk somebody out of. The hint paragraph is the block's description rather than
        // a label, because the text inside it is the thing being read.
        let sample = """
        <pre tabindex="0" aria-describedby="practice-hint"
             onclick="getSelection().selectAllChildren(this)"
             onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); getSelection().selectAllChildren(this) }"
        >\(escape(TutorialSample.text))</pre>
        """

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
          \(sample)
          <p class="hint" id="practice-hint">\(escape(hint))</p>
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
