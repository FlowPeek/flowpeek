import AppKit
import FlowPeekCore
import OSLog

/// Watches the general pasteboard for copied Mermaid. This is the path for apps whose selection the
/// accessibility APIs cannot see at all — a canvas-rendered terminal such as xterm.js keeps its
/// selection in its own model and paints it, so nothing is exposed to `AXSelectedText` or to a text
/// marker range. A copy is the one signal such an app does emit.
///
/// Nothing is injected and nothing is written back: the pasteboard is polled (AppKit posts no change
/// notification) and only read when `changeCount` moves.
@MainActor
final class ClipboardMonitor {
    struct Copied: Equatable, Sendable {
        let text: String
        let detection: MermaidDetection
    }

    var onMermaidCopied: ((Copied) -> Void)?

    /// Fast enough to feel immediate after ⌘C, slow enough to be invisible in Activity Monitor.
    static let pollInterval: TimeInterval = 0.35
    /// A pasteboard string larger than this cannot become a diagram anyway; skip it before the detector.
    static let maximumLength = MermaidSource.maximumCharacters

    private let pasteboard: NSPasteboard
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Clipboard")
    private var timer: Timer?
    private var lastChangeCount: Int

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        // Whatever is already on the pasteboard predates the watch; only new copies count.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("clipboard watch started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.info("clipboard watch stopped")
    }

    /// Exposed for tests and for the "check now" path; safe to call at any time.
    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text.utf16.count <= Self.maximumLength else {
            logger.debug("copied text ignored: \(text.utf16.count) UTF-16 units exceeds the diagram limit")
            return
        }

        let detection = MermaidDetector.detect(text)
        guard detection.confidence >= .likely else { return }
        // The keyword is safe to log; the diagram itself never is.
        logger.debug(
            "copied Mermaid detected: \(detection.diagramKeyword ?? "unknown", privacy: .public) confidence \(detection.confidence.rawValue, privacy: .public)"
        )
        onMermaidCopied?(Copied(text: text, detection: detection))
    }
}
