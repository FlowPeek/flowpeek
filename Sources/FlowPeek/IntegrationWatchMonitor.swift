import AppKit
import FlowPeekCore
import OSLog

/// FlowPeek's side of the conversation with every editor that answers through a plugin.
///
/// Deliberately knows nothing about which editor it is talking to. An editor that hides its text
/// from the accessibility API is served by an extension instead, every one of those extensions
/// writes the same JSON (see `IntegrationWatch`), and so one monitor serves all of them: it asks
/// whichever integration belongs to the application in front, reads the answer, and hands back the
/// same candidates the terminal watch produces.
///
/// Providers are found rather than listed. Anything that has written an `integration.json` under
/// FlowPeek's integrations directory is watched, whether FlowPeek shipped it, an editor's own
/// developer wrote it, or somebody added it this morning. The ones FlowPeek installs itself get
/// there the same way: the installer writes the manifest beside the plugin, so there is one path
/// through this code and no privileged case. `docs/INTEGRATIONS.md` is the contract.
///
/// Asking is a file whose modification date is the question. Nothing listens on a port, and while
/// none of these editors is frontmost FlowPeek writes nothing at all, so a plugin goes back to one
/// `stat` a second and the editor is left alone.
@MainActor
final class IntegrationWatchMonitor {
    var onCandidates: (([AmbientCandidate]) -> Void)?
    var onDismiss: (() -> Void)?
    /// Whether the route is allowed to run right now -- the same gate the terminal watch answers to,
    /// so a preview on screen does not get an outline drawn over it.
    var isSuppressed: (() -> Bool)?

    /// Re-asked on this cadence while one of these editors is in front. The plugin treats a question older than
    /// five seconds as a FlowPeek that went away, so this has to be comfortably under that.
    private static let askInterval: TimeInterval = 2
    /// How often the answer is read. The plugin rewrites only when the picture changed, so most of
    /// these are one `stat` that finds the same date as last time.
    private static let readInterval: TimeInterval = 0.2

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Integrations")
    private let fileManager = FileManager.default
    /// Who has registered, and who settings says to leave alone.
    private let registry: IntegrationRegistry
    /// Every provider found on disk, whoever wrote it.
    private var watching: [IntegrationWatch.Manifest] = []
    private var timer: Timer?
    /// Per integration, because more than one of these editors can be installed and the reader
    /// switches between them.
    private var lastAsked: [String: Date] = [:]
    private var lastAnswerDate: [String: Date] = [:]
    /// The last answer each provider gave, so a frame can be put back where a moved window now is
    /// without waiting for the text to change.
    private var lastAnswer: [String: IntegrationWatch.Answer] = [:]
    /// The window frame the outline on screen was measured against.
    private var lastWindow: CGRect?
    private var asking: Set<String> = []
    private var showing = false

    init(registry: IntegrationRegistry = IntegrationRegistry()) {
        self.registry = registry
    }

    private func root(of manifest: IntegrationWatch.Manifest) -> URL {
        registry.directory(of: manifest.id)
    }

    private func askFile(of manifest: IntegrationWatch.Manifest) -> URL {
        root(of: manifest).appendingPathComponent(IntegrationWatch.askName)
    }

    private func answerFile(of manifest: IntegrationWatch.Manifest) -> URL {
        root(of: manifest).appendingPathComponent(IntegrationWatch.answerName)
    }

    /// Everyone registered here who is not switched off in settings.
    ///
    /// Re-read rather than cached across runs of `start`, because a provider can appear at any time
    /// and the whole promise of a published contract is that nobody has to tell FlowPeek first.
    func discover() -> [IntegrationWatch.Manifest] {
        registry.watched()
    }

    var isRunning: Bool { timer != nil }

    /// Starts watching whatever has registered. The caller re-arms this when an integration is
    /// switched on or off, and every start re-reads the directory.
    func start() {
        let next = discover()
        // Anybody who was being asked and is no longer on the list -- switched off in settings, or a
        // provider whose directory has gone -- is told so before the list is replaced. Withdrawing
        // the question is the contract: a provider that finds its `ask` file still there has been
        // promised somebody is listening, and leaving one behind makes a liar of the protocol even
        // when the stale date saves it.
        for provider in watching where !next.contains(where: { $0.id == provider.id }) {
            stopAsking(provider)
        }
        watching = next
        guard !watching.isEmpty else {
            stop()
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.readInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Self.readInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("integration watch started for \(self.watching.count, privacy: .public) provider(s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastAsked = [:]
        lastAnswerDate = [:]
        lastAnswer = [:]
        lastWindow = nil
        watching.forEach(stopAsking)
        watching = []
        dismiss()
        logger.info("integration watch stopped")
    }

    // MARK: - The loop

    private func tick() {
        guard let active = frontmostIntegration(), isSuppressed?() != true else {
            for provider in watching where asking.contains(provider.id) {
                stopAsking(provider)
            }
            dismiss()
            return
        }
        // Only the one in front is asked. A plugin in a background editor has nothing on screen
        // worth framing, and a question it can see is a loop it has to keep running.
        for provider in watching where provider.id != active.id && asking.contains(provider.id) {
            stopAsking(provider)
        }
        ask(active)
        read(active)
    }

    /// The provider speaking for the application the reader is in, if any of them does.
    private func frontmostIntegration() -> IntegrationWatch.Manifest? {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return watching.first { $0.bundleIdentifiers.contains(front) }
    }

    /// The question: a file whose modification date says when it was last asked.
    private func ask(_ provider: IntegrationWatch.Manifest) {
        let now = Date()
        if let last = lastAsked[provider.id], now.timeIntervalSince(last) < Self.askInterval { return }
        lastAsked[provider.id] = now
        let file = askFile(of: provider)
        do {
            try fileManager.createDirectory(at: root(of: provider), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            } else {
                fileManager.createFile(atPath: file.path, contents: Data())
            }
            asking.insert(provider.id)
        } catch {
            logger.error("could not ask \(provider.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops asking, so the plugin's own loop drops back to idle. The answer is left where it is:
    /// it holds no source, only the last thing the editor was showing, and deleting a file the
    /// plugin may be writing is a race with nothing to gain.
    private func stopAsking(_ provider: IntegrationWatch.Manifest) {
        asking.remove(provider.id)
        lastAsked[provider.id] = nil
        let file = askFile(of: provider)
        guard fileManager.fileExists(atPath: file.path) else { return }
        try? fileManager.removeItem(at: file)
    }

    private func read(_ provider: IntegrationWatch.Manifest) {
        let file = answerFile(of: provider)
        guard let modified = try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date else {
            return
        }
        guard modified != lastAnswerDate[provider.id] else {
            // The text has not moved, so the provider has written nothing -- it answers when the
            // picture changes, and dragging a window does not change the picture. The rectangle it
            // described is relative to a window that has moved, though, so the frame has to be
            // measured again or it stays where the window used to be.
            if let answer = lastAnswer[provider.id], frontWindowFrame() != lastWindow {
                present(answer, from: provider)
            }
            return
        }
        lastAnswerDate[provider.id] = modified
        guard let data = try? Data(contentsOf: file),
              let answer = try? JSONDecoder().decode(IntegrationWatch.Answer.self, from: data) else {
            logger.debug("the \(provider.id, privacy: .public) answer did not decode")
            return
        }
        lastAnswer[provider.id] = answer
        guard IntegrationWatch.isUsable(answer, now: Date().timeIntervalSince1970) else {
            dismiss()
            return
        }
        present(answer, from: provider)
    }

    // MARK: - Putting it on the screen

    private func present(_ answer: IntegrationWatch.Answer, from provider: IntegrationWatch.Manifest) {
        guard let window = frontWindowFrame(),
              let flip = ScreenGeometry.flipReference(screenFrames: NSScreen.screens.map(\.frame)) else {
            dismiss()
            return
        }
        lastWindow = window
        // What the provider said, or what the system puts above a standard window's content. Asked
        // of AppKit rather than written down, because the number is macOS's and has moved: a titled
        // window's chrome was 28 points and is 32 on this release.
        let inset = answer.contentInsetTop.map { CGFloat($0) } ?? Self.systemTitleBarHeight
        // The window's content area, which is what a clamped block's edges are measured against.
        let content = ScreenGeometry.axToAppKit(
            CGRect(x: window.minX, y: window.minY + inset,
                   width: window.width, height: max(0, window.height - inset)),
            flipReference: flip
        )
        var candidates: [AmbientCandidate] = []
        for block in IntegrationWatch.drawable(answer) {
            guard let rect = IntegrationWatch.screenRect(
                of: block, window: window, contentInsetTop: inset, flipReference: flip
            ) else {
                continue
            }
            let detection = MermaidDetector.detect(block.text)
            guard detection.confidence >= .likely else { continue }
            candidates.append(
                AmbientCandidate(
                    text: block.text,
                    detection: detection,
                    bounds: rect,
                    applicationName: provider.name,
                    // The frame really is around the block, which is the whole point of the plugin.
                    anchor: .terminal,
                    // A diagram taller than the window is framed with its cut sides open rather
                    // than not framed at all.
                    openEdges: IntegrationWatch.openEdges(
                        of: block, rect: rect, content: content, lineHeight: answer.lineHeight
                    )
                )
            )
        }
        guard !candidates.isEmpty else {
            dismiss()
            return
        }
        showing = true
        // Offsets and counts only; the diagram itself is never logged.
        logger.debug("\(candidates.count, privacy: .public) block(s) framed in \(provider.name, privacy: .public)")
        onCandidates?(candidates)
    }

    private func dismiss() {
        guard showing else { return }
        showing = false
        // Nothing is on screen to keep in step with a window any more.
        lastWindow = nil
        onDismiss?()
    }

    /// How far a standard titled window's content sits below the top of its frame.
    private static let systemTitleBarHeight: CGFloat = {
        let content = CGRect(x: 0, y: 0, width: 100, height: 100)
        let frame = NSWindow.frameRect(
            forContentRect: content,
            styleMask: [.titled, .closable, .miniaturizable, .resizable]
        )
        return frame.height - content.height
    }()

    /// The frontmost application's frontmost window, top-left origin, as the window server reports
    /// it.
    ///
    /// Read from `CGWindowListCopyWindowInfo` rather than from accessibility, because accessibility
    /// is exactly what these editors do not answer -- and because a window's frame needs no
    /// permission to ask about.
    private func frontWindowFrame() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 1, height > 1 else { continue }
            // The list is front to back, so the first one that matches is the one being typed in.
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }
}
