import AppKit
import FlowPeekCore
import SwiftUI

@MainActor
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()
    private var window: NSWindow?
    private var spaceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let view = OnboardingView(
            completion: { [weak self] in
                AppState.shared.onboardingComplete = true
                self?.closeWindow()
            },
            close: { [weak self] in self?.closeWindow() },
            stepAside: { [weak self] in self?.moveAside() }
        )
        let controller = NSHostingController(rootView: view.environmentObject(AppState.shared))
        let window = OnboardingWindow(contentViewController: controller)
        window.title = String(localized: "onboarding.window.title")
        window.styleMask = [.borderless, .closable, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        // The content draws its own shadow inside `.padding`, so AppKit must not draw a second one:
        // its shadow traces the whole window rect, which extends well beyond the visible card and
        // reads as a rounded halo floating outside it.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.level = .floating
        window.hidesOnDeactivate = false
        // 40pt taller than it was: the permission step now explains the choice and offers two
        // buttons, and its card is the one that decides this height. Kept well under the 775pt a
        // 1280x800 display leaves below the menu bar.
        window.setContentSize(NSSize(width: 720, height: 720))
        window.center()
        window.isReleasedWhenClosed = false
        // Escape has to route through closeWindow() rather than the window's own close(): that is
        // the only place the Space observer is torn down, and a bare close() would leave the
        // observer calling orderFrontRegardless() on the dismissed card at the next Space switch.
        window.onCancel = { [weak self] in self?.closeWindow() }
        self.window = window
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.window?.orderFrontRegardless() }
        }
        // Quitting with the card still open used to record nothing at all, so a user who granted
        // permission, ticked a lesson or two and quit for the day was met by the whole flow again at
        // the next launch. There is no other hook for it: the window is borderless, so AppKit's own
        // close path is never taken, and the process is torn down without it.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Synchronous rather than a `Task`: the app is already on its way out and a hop to the
            // next main-actor turn would never run. `queue: .main` is what makes this the main
            // thread, so the assumption holds.
            MainActor.assumeIsolated { Self.recordProgress() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Parks the window against the right edge of its screen, keeping it visible as a checklist
    /// while leaving the practice page usable.
    private func moveAside() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = ScreenGeometry.clamp(
            origin: CGPoint(x: visible.maxX - size.width + 24, y: visible.midY - size.height / 2),
            size: size,
            visibleFrames: [visible],
            inset: 0
        )
        window.setFrameOrigin(origin)
    }

    private func closeWindow() {
        Self.recordProgress()
        window?.close()
        window = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    /// What the wizard leaves behind, whichever way it goes away. Leaving the permission question
    /// unanswered is what earns a second offer at the next launch, so "I'll decide later" still
    /// works and only "I decided" sticks.
    private static func recordProgress() {
        let app = AppState.shared
        guard OnboardingPolicy.recordsCompletion(
            accessibilityGranted: app.accessibilityGranted,
            permissionDeclined: app.permissionDeclined
        ) else { return }
        app.onboardingComplete = true
    }
}

private final class OnboardingWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Borderless means no titlebar and, in a menu-bar-only app, no File menu either — without this
    /// the card has no keyboard dismissal at all.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

struct OnboardingView: View {
    /// Permission is the only step that can complete itself; the login step is a question, so it
    /// always waits for an answer. Which step follows which lives in FlowPeekCore.
    private typealias Step = OnboardingStep

    @EnvironmentObject private var app: AppState
    #if DEBUG
    @State private var step: Step = ProcessInfo.processInfo.arguments.contains("--onboarding-tutorial")
        ? .tutorial
        : .welcome
    #else
    @State private var step: Step = .welcome
    #endif
    @State private var permissionFlow = AccessibilityPermissionFlow(isGranted: false)
    let completion: () -> Void
    let close: () -> Void
    /// Moves the window out of the way, because the practice page is the thing being pointed at.
    let stepAside: () -> Void

    var body: some View {
        ZStack {
            FlowPeekGlassBackground()
            LinearGradient(
                colors: [Color.accentColor.opacity(0.13), .clear, Color.purple.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                header
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.13)).frame(width: 104, height: 104)
                        Circle().stroke(Color.white.opacity(0.28), lineWidth: 1).frame(width: 104, height: 104)
                        Image(systemName: step.symbol)
                            .font(.system(size: 44, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                    }
                    Text(String(localized: step.titleKey(allLessonsAvailable: allLessonsAvailable)))
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text(String(localized: step.messageKey(allLessonsAvailable: allLessonsAvailable)))
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                        .fixedSize(horizontal: false, vertical: true)
                    switch step {
                    case .permission: permissionCard
                    case .launch: launchCard
                    case .tutorial: tutorialCard
                    case .welcome: EmptyView()
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 54)
                footer
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.30), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 35, y: 16)
        .padding(32)
        .animation(.snappy, value: step)
        .onAppear { permissionFlow.update(isGranted: app.accessibilityGranted) }
        .onChange(of: app.accessibilityGranted) { _, granted in
            permissionFlow.update(isGranted: granted)
            if permissionFlow.shouldComplete { advancePastPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermission()
            app.refreshLaunchAtLoginStatus()
        }
        .task(id: step) {
            guard step == .permission else { return }
            while !Task.isCancelled && !app.accessibilityGranted {
                app.refreshPermission()
                if !app.accessibilityGranted { permissionFlow.recordUnconfirmedCheck() }
                // One second, so `shouldOfferRelaunch`'s count reads as seconds. Auto-advance on
                // grant does not depend on this interval anyway: didBecomeActiveNotification above
                // refreshes the moment focus comes back from System Settings.
                try? await Task.sleep(for: .seconds(1))
            }
            if app.accessibilityGranted { advancePastPermission() }
        }
    }

    private var header: some View {
        HStack {
            FlowPeekWindowCloseButton(action: close)
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("FlowPeek").fontWeight(.semibold)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 7) {
                ForEach(Step.visible(permissionSettled: permissionSettled, current: step), id: \.rawValue) { candidate in
                    Capsule()
                        .fill(step == candidate ? Color.accentColor : Color.accentColor.opacity(0.28))
                        .frame(width: step == candidate ? 24 : 8, height: 8)
                }
            }
            .animation(.snappy, value: step)
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("permission.step.toggle", systemImage: "switch.2")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("permission.step.detail")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider().opacity(0.55)
            HStack(spacing: 9) {
                if permissionFlow.phase == .waitingForUser {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(app.accessibilityGranted ? .green : .orange).frame(width: 10, height: 10)
                }
                Text(String(localized: app.accessibilityGranted ? "permission.granted" : waitingMessageKey))
                    .font(.callout.weight(.medium))
            }
        }
        .padding(18)
        .frame(maxWidth: 540, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.22)))
    }

    private var launchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text("onboarding.launch.toggle").font(.headline)
                    Text("onboarding.launch.detail")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 14)
                Toggle("onboarding.launch.toggle", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .accessibilityHint(Text("onboarding.launch.detail"))
            }
            if let notice = app.launchAtLoginState.noticeKey {
                HStack(alignment: .top, spacing: 10) {
                    Label(String(localized: notice), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("settings.launch-at-login.open-login-items") { app.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 540, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.22)))
        .togglesOnTap(launchAtLoginBinding, cornerRadius: 18)
    }

    /// Reads the system's answer rather than what was asked for, so the switch cannot claim a state
    /// macOS refused — and cannot go stale when the user approves the login item in System Settings
    /// while this window is still open.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { app.launchAtLoginState.isOn },
            set: { app.setLaunchAtLogin($0) }
        )
    }

    /// The lessons that can actually be passed, each ticked only when a preview really opened by
    /// that route. The practice text lives in the browser rather than in this window: FlowPeek
    /// refuses to read its own process, so a drag in here could never produce an overlay button.
    private var tutorialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(availableLessons) { lesson in
                HStack(alignment: .top, spacing: 12) {
                    stateBadge(app.tutorial[lesson])
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: lesson.titleKey))
                            .font(.callout.weight(.semibold))
                        Text(lesson.detail(peekShortcut: app.shortcuts.shortcuts[.ambientPeek].display))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if lesson == .ambient, !app.ambientPeekEnabled {
                            Button("tutorial.ambient.enable") { app.enableAmbientPeek() }
                                .controlSize(.small)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if lesson != availableLessons.last || !app.accessibilityGranted {
                    Divider().opacity(0.4)
                }
            }
            // Not a dimmed copy of the two withheld rows: their instructions describe a button and
            // an outline that will not appear, so what is left is the one sentence that explains it
            // and the way back to the switch.
            if !app.accessibilityGranted {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("tutorial.locked")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Only the way back to the question. Clearing the decline here would answer
                        // it on the user's behalf, and a user who then backed out without granting
                        // would be left looking unanswered again — which re-arms the every-launch
                        // offer the decline exists to switch off. The flag moves when they actually
                        // grant the permission, or when they press the decline button again.
                        Button("permission.turn-on") { step = .permission }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 540, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.22)))
        .animation(.snappy, value: app.tutorial)
    }

    /// Waiting, noticed, opened. The middle state matters: it tells the user FlowPeek saw their
    /// text, which is the half of the interaction that is otherwise invisible.
    private func stateBadge(_ state: TutorialProgress.State) -> some View {
        ZStack {
            switch state {
            case .waiting:
                Circle().strokeBorder(.secondary.opacity(0.45), lineWidth: 1.5)
            case .detected:
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            case .done:
                Circle().fill(.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if step == .permission && (permissionFlow.shouldOfferRelaunch || app.accessibilityNeedsRepair) {
                Text(String(localized: app.accessibilityNeedsRepair ? "permission.registration.changed" : "permission.relaunch.help"))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    // Removing FlowPeek's TCC entry throws away a grant the user may have just
                    // given, so it is offered only for the state it actually repairs — a stale
                    // entry left by an earlier build — and never merely because waiting took a
                    // while. Relaunching costs nothing, so that one can be offered on patience.
                    if app.accessibilityNeedsRepair {
                        Button("permission.reset") { app.confirmAccessibilityReset() }
                    }
                    Button("permission.relaunch") { app.relaunchAfterPermissionChange() }
                }
                if let error = app.permissionRecoveryError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            // Sits with the decline button rather than up in the card: a button that means "no" is
            // only a real choice if what it costs is legible from where it is offered.
            if step == .permission && !app.accessibilityGranted {
                Text("permission.clipboard-works")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                if step > .welcome { Button("common.back") { back() } }
                Spacer()
                switch step {
                case .welcome:
                    Button("common.continue") { advanceFromWelcome() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                case .permission:
                    if app.accessibilityGranted {
                        Label("permission.finishing", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 10) {
                            // The step used to have exactly one forward button, and it reopened the
                            // pane the user had just refused. This is the button that means "no".
                            Button("permission.decline") { decline() }
                                .controlSize(.large)
                            Button(String(localized: permissionFlow.phase == .waitingForUser ? "permission.open-again" : "permission.open-settings")) {
                                permissionFlow.beginWaitingForSystemSettings()
                                app.requestAccessibility()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                case .launch:
                    Button("common.continue") { step = .tutorial }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                case .tutorial:
                    HStack(spacing: 10) {
                        Button("tutorial.open-page") {
                            // Get out of the way first: this window floats, and it was sitting
                            // squarely on top of the page the user has to drag across.
                            stepAside()
                            TutorialPractice.open(
                                lessons: availableLessons,
                                peekShortcut: app.shortcuts.shortcuts[.ambientPeek].display
                            )
                        }
                            .controlSize(.large)
                        Button(app.tutorial.isComplete(among: availableLessons) ? "common.start" : "tutorial.skip") { completion() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    /// Nothing to do on the permission step once it is already granted or already refused, so it is
    /// skipped rather than flashed past — or, in the refused case, walked into again.
    private func advanceFromWelcome() {
        step = Step.afterWelcome(permissionSettled: permissionSettled)
    }

    private func advancePastPermission() {
        guard step != .launch else { return }
        step = .launch
    }

    /// Declining is a step forward, not a dismissal: the login question and the tutorial are still
    /// worth asking, and the clipboard lesson still works.
    private func decline() {
        app.permissionDeclined = true
        step = .launch
    }

    private func back() {
        step = step.previous(accessibilityGranted: app.accessibilityGranted)
    }

    /// The permission question has an answer, whichever one it is.
    private var permissionSettled: Bool {
        app.accessibilityGranted || app.permissionDeclined
    }

    private var availableLessons: [TutorialProgress.Lesson] {
        TutorialProgress.Lesson.available(accessibilityGranted: app.accessibilityGranted)
    }

    private var allLessonsAvailable: Bool {
        availableLessons.count == TutorialProgress.Lesson.allCases.count
    }

    private var waitingMessageKey: String.LocalizationValue {
        permissionFlow.phase == .waitingForUser ? "permission.waiting" : "permission.required"
    }
}
