import AppKit
import ApplicationServices
import FlowPeekCore
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @AppStorage("flowpeek.enabled") var isEnabled = true
    @AppStorage("flowpeek.onboardingComplete") var onboardingComplete = false
    /// The user was offered Accessibility and said no. Remembered so the answer is not asked for
    /// again at every launch; cleared the moment the grant arrives.
    @AppStorage("flowpeek.permission.declined") var permissionDeclined = false
    @AppStorage("flowpeek.clipboard.enabled") var clipboardWatchEnabled = true
    /// Experimental: hold Option to outline Mermaid under the pointer. Off until asked for.
    @AppStorage("flowpeek.ambient.enabled") var ambientPeekEnabled = false
    @AppStorage("flowpeek.ai.enabled") var aiEnabled = false
    @AppStorage("flowpeek.ai.provider") var providerRawValue = AIProviderKind.openAI.rawValue
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var accessibilityNeedsRepair = false
    @Published private(set) var permissionRecoveryError: String?
    @Published private(set) var lastSelection: SelectionSnapshot?
    /// Whether the menu bar should offer the way back to a preview window. A promoted preview is
    /// borderless: it has no Dock icon and no entry in the Window menu, so once another app is in
    /// front of it there was nothing left that could raise it again.
    @Published private(set) var hasPromotedPreview = false
    @Published private(set) var engineHealth: MermaidEngineHealth?
    /// True while the canary is running. The verdict is cleared for the duration, so the menu shows
    /// "checking" rather than a verdict that is being re-taken.
    @Published private(set) var isCheckingEngine = false
    /// What the status item draws, and what the menu says in words. Recomputed rather than derived
    /// in the view: `isEnabled` is `@AppStorage`, which publishes nothing from inside a class, so a
    /// computed property would leave the icon showing the state before the toggle.
    @Published private(set) var menuBarStatus: MenuBarStatus = .armed
    /// Which of the three routes the user has exercised. Drives the onboarding tutorial.
    @Published private(set) var tutorial = TutorialProgress()
    /// The override written into this app's own defaults domain; applied on the next launch.
    @Published var language: AppLanguage = AppLanguage.storedOverride(
        bundleIdentifier: Bundle.main.bundleIdentifier
    )
    /// What this process was actually localized with, read before anything can change it. The
    /// difference between the two is the pending relaunch, which is why the notice survives closing
    /// the Settings window and disappears by itself if the user picks their original language back.
    private let launchLanguage = AppLanguage.storedOverride(bundleIdentifier: Bundle.main.bundleIdentifier)
    /// What macOS reports about the login item, which is not the same thing as what the user asked
    /// for: a registration can succeed straight into `.requiresApproval`.
    @Published private(set) var launchAtLoginStatus = SMAppService.mainApp.status
    private var didRequestLaunchAtLogin = false

    let selectionMonitor = SelectionMonitor()
    let overlay = SelectionOverlayCoordinator()
    let previews = PreviewCoordinator()
    let clipboard = ClipboardMonitor()
    let ambient = AmbientPeekMonitor()
    let highlight = AmbientHighlightCoordinator()
    let indicator = ClipboardIndicatorCoordinator()
    let shortcuts = ShortcutCenter()
    let updater = UpdaterService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Renderer")
    private var lastDetection: (text: String, detection: MermaidDetection)?
    /// Polls `AXIsProcessTrusted()`, because the grant can go away while the app runs and macOS
    /// posts nothing an app may rely on to say so.
    private var permissionPollTimer: Timer?
    /// The most recent copied diagram, kept in memory only, replaced by the next copy.
    private var copied: MermaidSource?
    /// The block the ambient outline is currently drawn around, in memory only.
    private var ambientCandidate: AmbientCandidate?

    private init() {
        // Wired here rather than in `start()`: a preview can be promoted from the demo arguments and
        // from the AI window, neither of which goes through the monitors that `start()` arms.
        previews.onPromotedChange = { [weak self] hasWindow in self?.hasPromotedPreview = hasWindow }
    }

    func start() {
        #if DEBUG
        // Opens the preview on a canned diagram so the panel's chrome, glass and fit can be checked
        // without granting Accessibility to a throwaway build.
        if ProcessInfo.processInfo.arguments.contains("--preview-demo") {
            startEngine()
            showPreviewDemo()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--settings-demo") {
            shortcuts.handlers = [
                .aiPrompt: { [weak self] in self?.presentAIPrompt() },
                .previewClipboard: { [weak self] in self?.previewCopied() },
            ]
            shortcuts.registerAll()
            SettingsWindowCoordinator.shared.show()
            return
        }
        #endif
        InstallLocationAdvisor.promptIfNeeded()
        selectionMonitor.onSelection = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        selectionMonitor.onDismiss = { [weak self] in self?.forgetSelection() }
        selectionMonitor.isPointOnOverlay = { [weak self] point in self?.overlay.contains(point) ?? false }
        overlay.onRender = { [weak self] snapshot in self?.render(snapshot) }
        clipboard.onMermaidCopied = { [weak self] copy in self?.receiveCopied(copy) }
        indicator.onActivate = { [weak self] in self?.previewCopied() }
        ambient.onCandidate = { [weak self] candidate in self?.receiveAmbient(candidate) }
        ambient.onDismiss = { [weak self] in
            self?.highlight.hide()
            self?.ambientCandidate = nil
        }
        ambient.onActivate = { [weak self] in self?.previewAmbient() }
        highlight.onActivate = { [weak self] in self?.previewAmbient() }
        shortcuts.handlers = [
            .aiPrompt: { [weak self] in self?.presentAIPrompt() },
            .previewClipboard: { [weak self] in self?.previewCopied() },
            .ambientPeek: { [weak self] in self?.ambient.activate() },
        ]
        startEngine()
        // Registers the hot keys as well, and only the ones whose feature is on — which is why there
        // is no `registerAll()` here: it would claim ⌥⌘M for a moment even with AI switched off.
        applyEnabledState()
        refreshPermission()
        schedulePermissionPoll()
        #if DEBUG
        let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--force-onboarding")
        #else
        let forceOnboarding = false
        #endif
        // A deliberate decline is not a broken registration, so it must not be met with the
        // "this build no longer matches the allowed entry" copy and a reset button.
        accessibilityNeedsRepair = onboardingComplete && !accessibilityGranted && !permissionDeclined
        if OnboardingPolicy.shouldShow(
            accessibilityGranted: accessibilityGranted,
            onboardingCompleted: onboardingComplete,
            permissionDeclined: permissionDeclined,
            forceOnboarding: forceOnboarding
        ) {
            if !accessibilityGranted && !permissionDeclined { onboardingComplete = false }
            OnboardingCoordinator.shared.show()
        }
    }

    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        selectionMonitor.stop()
        clipboard.stop()
        ambient.stop()
        shortcuts.unregisterAll()
        indicator.hide()
        highlight.hide()
        forgetSelection()
    }

    func applyEnabledState() {
        if isEnabled && accessibilityGranted {
            selectionMonitor.start()
        } else {
            selectionMonitor.stop()
        }
        // The clipboard watch needs no Accessibility grant, so it is the path that still works in
        // apps whose selection is painted rather than exposed — a canvas terminal, say.
        if isEnabled && clipboardWatchEnabled {
            clipboard.start()
        } else {
            clipboard.stop()
        }
        // Ambient peek reads the accessibility tree, so it needs the same grant the overlay does.
        let ambientRunning = isEnabled && ambientPeekEnabled && accessibilityGranted
        if ambientRunning {
            ambient.start()
        } else {
            ambient.stop()
        }
        if !isEnabled {
            overlay.hide()
            indicator.hide()
            highlight.hide()
        }
        // Also the one place that claims and releases the global hot keys: a registered hot key is
        // taken from every other app, so a shortcut whose feature is switched off must not hold one.
        // ⌥Space matters most here — it is a character the user can still want to type, so it stays
        // with the frontmost app until an outline can actually appear.
        shortcuts.setActiveActions(
            ShortcutActivationPolicy.activeActions(
                isEnabled: isEnabled,
                clipboardWatchEnabled: clipboardWatchEnabled,
                aiEnabled: aiEnabled,
                ambientPeekEnabled: ambientPeekEnabled,
                accessibilityGranted: accessibilityGranted
            )
        )
        refreshMenuBarStatus()
    }

    func refreshPermission() {
        updateAccessibilityState(AXIsProcessTrusted())
    }

    private func refreshMenuBarStatus() {
        let resolved = MenuBarStatus.resolve(
            engineUsable: engineHealth?.isUsable ?? true,
            accessibilityGranted: accessibilityGranted,
            permissionDeclined: permissionDeclined,
            isEnabled: isEnabled
        )
        // Assigned only when it moves: this also runs from the permission poll, and `@Published`
        // republishes an identical value, which would redraw the status item on a timer.
        guard resolved != menuBarStatus else { return }
        menuBarStatus = resolved
    }

    /// Three seconds while the grant is missing, ten while it holds. Someone standing in System
    /// Settings waiting for the switch to take effect notices three; a revocation is rare enough
    /// that hearing about it within ten is what matters, and `AXIsProcessTrusted()` still goes out
    /// to the TCC daemon, so the idle case gets the cheaper cadence.
    private static let ungrantedPollInterval: TimeInterval = 3
    private static let grantedPollInterval: TimeInterval = 10

    private func schedulePermissionPoll() {
        let interval = accessibilityGranted ? Self.grantedPollInterval : Self.ungrantedPollInterval
        if let existing = permissionPollTimer, existing.timeInterval == interval { return }
        permissionPollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        updateAccessibilityState(AXIsProcessTrustedWithOptions(options))
        if !accessibilityGranted { openAccessibilitySettings() }
    }

    func openAccessibilitySettings() {
        let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: settingsApp, configuration: configuration) { _, _ in
            Task { @MainActor in
                let candidates = [
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                ]
                for candidate in candidates {
                    if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
                }
                NSSound.beep()
            }
        }
    }

    /// True while the running process is localized in something other than the stored choice.
    var needsRelaunchForLanguage: Bool { language != launchLanguage }

    /// Writes the override and reports whether it changed anything. Compared against what is on disk
    /// rather than against `language`: picking the language the OS already uses is a real override to
    /// write — it has to survive the user changing the system language later — even though the
    /// visible answer does not move.
    @discardableResult
    func apply(language newValue: AppLanguage) -> Bool {
        let previous = AppLanguage.storedOverride(bundleIdentifier: Bundle.main.bundleIdentifier)
        language = newValue
        if let stored = newValue.storedValue {
            UserDefaults.standard.set(stored, forKey: AppLanguage.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        }
        return newValue != previous
    }

    /// Same mechanism the permission flow uses: a fresh instance, then terminate this one.
    func relaunch() {
        relaunchAfterPermissionChange()
    }

    func handle(_ command: AppCommand) {
        AppCommandRouter(
            showSettings: { SettingsWindowCoordinator.shared.show() },
            revealPreview: { [weak self] in self?.previews.revealPromoted() }
        ).handle(command)
    }

    func relaunchAfterPermissionChange() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // This copy is still running when the new one finishes launching, and the single-instance
        // guard would otherwise have the new copy stand aside for a copy that is about to exit.
        configuration.arguments = [SingleInstanceGuard.replacementArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, _ in
            guard application != nil else { NSSound.beep(); return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// The one action here that can destroy a grant the user already gave, so it asks first with
    /// Cancel as the default button.
    func confirmAccessibilityReset() {
        let alert = NSAlert()
        alert.messageText = String(localized: "permission.reset.confirm.title")
        alert.informativeText = String(localized: "permission.reset.confirm.body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "common.cancel"))
        alert.addButton(withTitle: String(localized: "permission.reset.confirm.action"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        resetAccessibilityRegistration()
    }

    func resetAccessibilityRegistration() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { NSSound.beep(); return }
        permissionRecoveryError = nil
        Task {
            let succeeded = await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", "Accessibility", bundleIdentifier]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch {
                    return false
                }
            }.value
            guard succeeded else {
                permissionRecoveryError = String(localized: "permission.reset.failed")
                NSSound.beep()
                return
            }
            accessibilityGranted = false
            accessibilityNeedsRepair = false
            requestAccessibility()
        }
    }

    #if DEBUG
    private func showPreviewDemo() {
        let sample = """
        flowchart TD
          A[Selection] --> B{Looks like Mermaid?}
          B -- yes --> C[Overlay button]
          B -- no --> D[Stay quiet]
          C --> E[Quick preview]
          E --> F[Open in window]
        """
        guard let source = try? MermaidSource(rawValue: sample) else { return }
        previews.showQuick(document: DiagramDocument(title: "FlowPeek Preview", source: source))
    }
    #endif

    /// The overlay is going away and so is the copy of the user's text behind it. `lastSelection` is
    /// their own writing — a whole document, when they pressed ⌘A — and `lastDetection` carries a
    /// normalized second copy of it; both used to sit in memory until the next selection replaced
    /// them, which for someone who selects once and then works elsewhere is the rest of the session.
    private func forgetSelection() {
        overlay.hide()
        lastSelection = nil
        lastDetection = nil
    }

    func receive(_ snapshot: SelectionSnapshot) {
        previews.selectionDidChange()
        // Select-all in a log file or a long document arrives here. Nothing that large can become a
        // diagram, and keeping it would hold megabytes of the user's text for the rest of the
        // session, so it is dropped before it is examined or stored.
        guard snapshot.text.utf16.count <= MermaidDetector.maximumInputCharacters else {
            forgetSelection()
            logger.debug("selection ignored: \(snapshot.text.utf16.count, privacy: .public) code units")
            return
        }
        lastSelection = snapshot
        let detection = MermaidDetector.detect(snapshot.text)
        guard isEnabled, detection.confidence >= .likely else {
            logger.debug(
                """
                selection rejected: enabled=\(self.isEnabled, privacy: .public) \
                confidence=\(detection.confidence.rawValue, privacy: .public) \
                keyword=\(detection.diagramKeyword ?? "none", privacy: .public) \
                app=\(snapshot.applicationName ?? "unknown", privacy: .public) \
                length=\(snapshot.text.count, privacy: .public) \
                head=\(String(snapshot.text.prefix(80)), privacy: .private)
                """
            )
            overlay.hide()
            lastDetection = nil
            return
        }
        // Stored only past the guard: its one reader is the overlay button, which exists only for a
        // selection that got this far, and the detection carries a normalized copy of the whole text.
        lastDetection = (snapshot.text, detection)
        tutorial.noteDetected(.selection)
        overlay.show(for: snapshot)
    }

    /// A copy that parses as Mermaid raises a transient indicator naming the shortcut. It never
    /// steals focus and never opens anything on its own.
    func receiveCopied(_ copy: ClipboardMonitor.Copied) {
        guard isEnabled, clipboardWatchEnabled else { return }
        guard let source = try? MermaidSource(rawValue: copy.detection.extractedSource) else {
            logger.debug("copied Mermaid failed validation; no indicator shown")
            return
        }
        copied = source
        tutorial.noteDetected(.clipboard)
        indicator.show(
            keyword: copy.detection.diagramKeyword,
            shortcut: shortcuts.shortcuts[.previewClipboard].display
        )
    }

    /// The key the onboarding tutorial teaches, so it has to answer whenever it is pressed. The
    /// pasteboard is read live here and the watcher's own switches are not consulted: they govern
    /// the unasked-for badge, not a key the user pressed, and gating this on them is what made the
    /// shortcut silent for every diagram copied before FlowPeek was watching.
    func previewCopied() {
        indicator.hide()
        switch ClipboardPreviewPolicy.decide(
            pasteboardText: clipboard.currentText(),
            hasCachedDiagram: copied != nil
        ) {
        case .preview(let source):
            // Kept so the badge and this path can never name different diagrams.
            copied = source
            showCopied(source)
        case .previewCached:
            if let copied { showCopied(copied) }
        case .nothingToPreview:
            // Saying nothing is what the user reads as a broken app, and a panel that only
            // explains itself is a dead end, so it also offers something to press the key against.
            previews.showMessage(
                title: String(localized: "clipboard.empty.title"),
                message: String(
                    format: String(localized: "clipboard.empty.message"),
                    shortcuts.shortcuts[.previewClipboard].display
                ),
                action: (title: String(localized: "clipboard.empty.copy-sample"), handler: { [weak self] in
                    self?.copySampleDiagram()
                })
            )
        }
    }

    private func showCopied(_ source: MermaidSource) {
        tutorial.noteOpened(.clipboard)
        previews.showQuick(
            document: DiagramDocument(title: String(localized: "diagram.clipboard-title"), source: source)
        )
    }

    /// Turns the empty-clipboard panel into a working demonstration: one more press of the same key
    /// now opens something. Writing it also bumps `changeCount`, so the badge fires too — which is
    /// exactly what a real copy looks like.
    private func copySampleDiagram() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TutorialPractice.sample, forType: .string)
        previewCopied()
    }

    /// An outline is only ever drawn; opening the diagram still takes a deliberate key or click.
    func receiveAmbient(_ candidate: AmbientCandidate) {
        guard isEnabled, ambientPeekEnabled else { return }
        ambientCandidate = candidate
        tutorial.noteDetected(.ambient)
        highlight.show(candidate, shortcut: shortcuts.shortcuts[.ambientPeek].display)
        logger.debug(
            """
            ambient candidate: \(candidate.detection.diagramKeyword ?? "unknown", privacy: .public) \
            in \(candidate.applicationName ?? "unknown", privacy: .public) \
            box \(Int(candidate.bounds.width), privacy: .public)x\(Int(candidate.bounds.height), privacy: .public)
            """
        )
    }

    /// The tutorial's third lesson needs the experiment on; offering it there is friendlier than
    /// sending the user to Settings mid-lesson.
    func enableAmbientPeek() {
        guard !ambientPeekEnabled else { return }
        ambientPeekEnabled = true
        applyEnabledState()
    }

    func resetTutorial() {
        tutorial.reset()
    }

    func previewAmbient() {
        highlight.hide()
        guard let candidate = ambientCandidate else { return }
        ambientCandidate = nil
        let title = String(localized: "preview.error.title")
        do {
            let source = try MermaidSource(rawValue: candidate.detection.extractedSource)
            tutorial.noteOpened(.ambient)
            previews.showQuick(
                document: DiagramDocument(title: String(localized: "diagram.default-title"), source: source)
            )
        } catch let error as MermaidSource.ValidationError {
            previews.showMessage(title: title, message: localizedUserMessage(error))
        } catch {
            previews.showMessage(title: title, message: error.localizedDescription)
        }
    }

    func render(_ snapshot: SelectionSnapshot) {
        overlay.hide()
        // No pre-emptive engine gate: the launch canary can fail once for reasons that have nothing
        // to do with this diagram, and the preview itself reports a real failure specifically — and
        // offers Try Again — where this reported the menu-bar line under "Cannot Preview This
        // Selection" and blamed the selection for the rest of the session.
        let title = String(localized: "preview.error.title")
        let cached = lastDetection.flatMap { $0.text == snapshot.text ? $0.detection : nil }
        let detection = cached ?? MermaidDetector.detect(snapshot.text)
        do {
            let source = try MermaidSource(rawValue: detection.extractedSource)
            tutorial.noteOpened(.selection)
            previews.showQuick(document: DiagramDocument(title: String(localized: "diagram.default-title"), source: source))
        } catch let error as MermaidSource.ValidationError {
            previews.showMessage(title: title, message: localizedUserMessage(error))
        } catch {
            previews.showMessage(title: title, message: error.localizedDescription)
        }
    }

    /// engine_spec §7's anti-regression device: warm the pool, then render a canary and record why
    /// it failed if it did, so a broken engine names itself instead of showing a blank stage.
    private func startEngine() {
        let pool = MermaidWebViewPool.shared
        pool.warmUp()
        // Cleared before the await so a verdict that is being re-taken cannot be displayed as the
        // current one. Nothing gates on it any more, so a `nil` health blocks nothing either.
        engineHealth = nil
        isCheckingEngine = true
        refreshMenuBarStatus()
        Task { [weak self] in
            let health = await pool.runSelfTest(theme: MermaidThemeFactory.current())
            self?.engineHealth = health
            self?.isCheckingEngine = false
            self?.refreshMenuBarStatus()
        }
    }

    /// A canary can fail once for reasons that have nothing to do with the engine — login-time
    /// memory pressure, a WebContent process that lost a race — and the verdict used to stand for
    /// the whole session with no way to take it again short of quitting.
    func recheckEngine() {
        guard !isCheckingEngine else { return }
        startEngine()
    }

    func presentAIPrompt() {
        // Belt and braces: with the activation policy in force this key is not even registered while
        // the experiment is off, so there is nothing to explain here.
        guard aiEnabled else { return }
        guard let selection = lastSelection, !selection.text.isEmpty else {
            // The prompt has nothing to work from, and saying nothing at all is what made the
            // shortcut look broken.
            previews.showMessage(
                title: String(localized: "preview.error.title"),
                message: String(
                    format: String(localized: "ai.no-selection"),
                    shortcuts.shortcuts[.aiPrompt].display
                )
            )
            return
        }
        AIPromptCoordinator.shared.show(context: selection.text)
    }

    var launchAtLoginState: LaunchAtLoginState {
        LaunchAtLoginState.resolve(
            registered: launchAtLoginStatus == .enabled,
            requiresApproval: launchAtLoginStatus == .requiresApproval,
            requestedOn: didRequestLaunchAtLogin
        )
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    /// Nothing is thrown at the UI: an `SMAppService` failure arrives as a bare OSStatus ("The
    /// operation couldn't be completed. (… error 1.)"), and the benign cases — already registered,
    /// not registered — are not failures at all. The status the system reports afterwards is the
    /// honest answer, and `launchAtLoginState` is what the switch renders.
    func setLaunchAtLogin(_ enabled: Bool) {
        didRequestLaunchAtLogin = enabled
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            logger.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func updateAccessibilityState(_ granted: Bool) {
        let changed = granted != accessibilityGranted
        // Every assignment here is guarded, because this now runs from a timer: `@Published`
        // republishes an identical value and `@AppStorage` writes the defaults again, so an
        // unguarded pass would redraw the app and touch the disk every few seconds.
        if changed { accessibilityGranted = granted }
        if granted {
            if accessibilityNeedsRepair { accessibilityNeedsRepair = false }
            // Granting answers the question the decline was an answer to, so a later revoke gets
            // the full offer back rather than being silently treated as still-declined.
            if permissionDeclined { permissionDeclined = false }
        }
        // Cheap, and it also picks up a decline recorded elsewhere: `permissionDeclined` is
        // `@AppStorage`, which publishes nothing, so the poll is what keeps the icon honest.
        refreshMenuBarStatus()
        guard changed else { return }
        // Both AX monitors install global event monitors while trusted and keep them after the
        // grant is gone, delivering nothing; and a monitor installed untrusted stays deaf even once
        // the switch is on. Tearing both down and letting `applyEnabledState()` decide which to
        // start again is what makes a re-grant revive every route rather than only the selection
        // one, and a revoke stop the outline as well as the button.
        selectionMonitor.stop()
        ambient.stop()
        if !granted {
            forgetSelection()
            highlight.hide()
        }
        applyEnabledState()
        // The two directions want different cadences, and this is where the direction changes.
        schedulePermissionPoll()
    }
}
