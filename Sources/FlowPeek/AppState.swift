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
    @AppStorage("flowpeek.clipboard.enabled") var clipboardWatchEnabled = true
    /// Experimental: hold Option to outline Mermaid under the pointer. Off until asked for.
    @AppStorage("flowpeek.ambient.enabled") var ambientPeekEnabled = false
    @AppStorage("flowpeek.ai.enabled") var aiEnabled = false
    @AppStorage("flowpeek.ai.provider") var providerRawValue = AIProviderKind.openAI.rawValue
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var accessibilityNeedsRepair = false
    @Published private(set) var permissionRecoveryError: String?
    @Published private(set) var lastSelection: SelectionSnapshot?
    @Published private(set) var engineHealth: MermaidEngineHealth?
    /// Mirrors `AppleLanguages` in this app's defaults domain; applied on the next launch.
    @Published var language: AppLanguage = AppLanguage.stored(
        in: UserDefaults.standard.stringArray(forKey: AppLanguage.defaultsKey)
    )

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
    /// The most recent copied diagram, kept in memory only, replaced by the next copy.
    private var copied: MermaidSource?
    /// The block the ambient outline is currently drawn around, in memory only.
    private var ambientCandidate: AmbientCandidate?

    private init() {}

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
        selectionMonitor.onDismiss = { [weak self] in self?.overlay.hide() }
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
        ]
        shortcuts.registerAll()
        startEngine()
        applyEnabledState()
        refreshPermission()
        #if DEBUG
        let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--force-onboarding")
        #else
        let forceOnboarding = false
        #endif
        accessibilityNeedsRepair = onboardingComplete && !accessibilityGranted
        if OnboardingPolicy.shouldShow(
            accessibilityGranted: accessibilityGranted,
            onboardingCompleted: onboardingComplete,
            forceOnboarding: forceOnboarding
        ) {
            if !accessibilityGranted { onboardingComplete = false }
            OnboardingCoordinator.shared.show()
        } else {
            onboardingComplete = true
        }
    }

    func stop() {
        selectionMonitor.stop()
        clipboard.stop()
        ambient.stop()
        shortcuts.unregisterAll()
        indicator.hide()
        highlight.hide()
        overlay.hide()
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
        if isEnabled && ambientPeekEnabled && accessibilityGranted {
            ambient.start()
        } else {
            ambient.stop()
        }
        if !isEnabled {
            overlay.hide()
            indicator.hide()
            highlight.hide()
        }
    }

    func refreshPermission() {
        updateAccessibilityState(AXIsProcessTrusted())
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

    /// Writes the override and reports whether a relaunch is needed to see it.
    @discardableResult
    func apply(language newValue: AppLanguage) -> Bool {
        guard newValue != language else { return false }
        language = newValue
        if let stored = newValue.storedValue {
            UserDefaults.standard.set(stored, forKey: AppLanguage.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        }
        return true
    }

    /// Same mechanism the permission flow uses: a fresh instance, then terminate this one.
    func relaunch() {
        relaunchAfterPermissionChange()
    }

    func handle(_ command: AppCommand) {
        AppCommandRouter(showSettings: {
            SettingsWindowCoordinator.shared.show()
        }).handle(command)
    }

    func relaunchAfterPermissionChange() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, _ in
            guard application != nil else { NSSound.beep(); return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
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

    func receive(_ snapshot: SelectionSnapshot) {
        previews.selectionDidChange()
        lastSelection = snapshot
        let detection = MermaidDetector.detect(snapshot.text)
        lastDetection = (snapshot.text, detection)
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
            return
        }
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
        indicator.show(
            keyword: copy.detection.diagramKeyword,
            shortcut: shortcuts.shortcuts[.previewClipboard].display
        )
    }

    func previewCopied() {
        indicator.hide()
        guard let copied else { return }
        let title = String(localized: "preview.error.title")
        if let engineHealth, !engineHealth.isUsable {
            previews.showMessage(title: title, message: engineHealth.menuDescription ?? "")
            return
        }
        previews.showQuick(
            document: DiagramDocument(title: String(localized: "diagram.clipboard-title"), source: copied)
        )
    }

    /// An outline is only ever drawn; opening the diagram still takes a deliberate key or click.
    func receiveAmbient(_ candidate: AmbientCandidate) {
        guard isEnabled, ambientPeekEnabled else { return }
        ambientCandidate = candidate
        highlight.show(candidate, shortcut: "⌥Space")
        logger.debug(
            """
            ambient candidate: \(candidate.detection.diagramKeyword ?? "unknown", privacy: .public) \
            in \(candidate.applicationName ?? "unknown", privacy: .public) \
            box \(Int(candidate.bounds.width), privacy: .public)x\(Int(candidate.bounds.height), privacy: .public)
            """
        )
    }

    func previewAmbient() {
        highlight.hide()
        guard let candidate = ambientCandidate else { return }
        ambientCandidate = nil
        let title = String(localized: "preview.error.title")
        if let engineHealth, !engineHealth.isUsable {
            previews.showMessage(title: title, message: engineHealth.menuDescription ?? "")
            return
        }
        do {
            let source = try MermaidSource(rawValue: candidate.detection.extractedSource)
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
        let title = String(localized: "preview.error.title")
        if let engineHealth, !engineHealth.isUsable {
            previews.showMessage(title: title, message: engineHealth.menuDescription ?? "")
            return
        }
        let cached = lastDetection.flatMap { $0.text == snapshot.text ? $0.detection : nil }
        let detection = cached ?? MermaidDetector.detect(snapshot.text)
        do {
            let source = try MermaidSource(rawValue: detection.extractedSource)
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
        Task { [weak self] in
            let health = await pool.runSelfTest(theme: MermaidThemeFactory.current())
            self?.engineHealth = health
        }
    }

    func presentAIPrompt() {
        guard aiEnabled, let selection = lastSelection, !selection.text.isEmpty else { return }
        AIPromptCoordinator.shared.show(context: selection.text)
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    private func updateAccessibilityState(_ granted: Bool) {
        let becameGranted = granted && !accessibilityGranted
        let becameRevoked = !granted && accessibilityGranted
        accessibilityGranted = granted
        if granted { accessibilityNeedsRepair = false }
        if becameGranted && isEnabled { selectionMonitor.restart() }
        if becameRevoked { selectionMonitor.stop(); overlay.hide() }
    }
}
