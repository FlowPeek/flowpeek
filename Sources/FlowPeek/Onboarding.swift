import AppKit
import FlowPeekCore
import SwiftUI

/// Which door the window is being opened by.
///
/// A returning user who asked for the tutorial is not being set up again: the wizard's steps are
/// behind them, and the difference decides whether the window offers a way backwards into them.
enum OnboardingEntry {
    case setup
    case tutorial
}

@MainActor
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()
    private var window: NSWindow?
    /// Which door the window on screen was opened by. The menu offers two — setup and the tutorial
    /// — and they are different destinations: fronting the wizard when the user asked for the
    /// checklist reads as a menu item that does nothing.
    private var openEntry: OnboardingEntry?
    private var spaceObserver: NSObjectProtocol?

    func show(entry: OnboardingEntry = .setup) {
        if let window, openEntry == entry { window.makeKeyAndOrderFront(nil); return }
        // The step is @State inside the view, so there is no way to push a new destination into a
        // window that is already up; it is rebuilt instead.
        if window != nil { closeWindow() }
        let view = OnboardingView(
            entry: entry,
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
        openEntry = entry
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.window?.orderFrontRegardless() }
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
        // Answering the permission question, either way, is finishing setup: the tutorial is
        // practice, not a gate. Leaving it unanswered is what earns a second offer at the next
        // launch, so "I'll decide later" still works and only "I decided" sticks.
        let app = AppState.shared
        if app.accessibilityGranted || app.permissionDeclined { app.onboardingComplete = true }
        // The checklist is what made a refused selection worth a second look; with it gone, the
        // rejected branch of `receive` — which every ordinary selection in every app takes — has
        // nothing left to ask.
        app.notePracticePageClosed()
        window?.close()
        window = nil
        openEntry = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
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
    /// always waits for an answer.
    private enum Step: Int, CaseIterable, Comparable {
        case welcome, permission, launch, tutorial

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var symbol: String {
            switch self {
            case .welcome: "point.3.connected.trianglepath.dotted"
            case .permission: "hand.point.up.left.and.text"
            case .launch: "power"
            case .tutorial: "graduationcap"
            }
        }

        var title: String.LocalizationValue {
            switch self {
            case .welcome: "onboarding.welcome.title"
            case .permission: "onboarding.permission.title"
            case .launch: "onboarding.launch.title"
            case .tutorial: "tutorial.title"
            }
        }

        var message: String.LocalizationValue {
            switch self {
            case .welcome: "onboarding.welcome.message"
            case .permission: "onboarding.permission.message"
            case .launch: "onboarding.launch.message"
            case .tutorial: "tutorial.message"
            }
        }
    }

    @EnvironmentObject private var app: AppState
    @State private var step: Step
    @State private var permissionFlow = AccessibilityPermissionFlow(isGranted: false)
    @State private var nudge = false
    private let entry: OnboardingEntry
    let completion: () -> Void
    let close: () -> Void
    /// Moves the window out of the way, because the practice page is the thing being pointed at.
    let stepAside: () -> Void

    init(
        entry: OnboardingEntry = .setup,
        completion: @escaping () -> Void,
        close: @escaping () -> Void,
        stepAside: @escaping () -> Void
    ) {
        self.entry = entry
        self.completion = completion
        self.close = close
        self.stepAside = stepAside
        #if DEBUG
        let debugTutorial = ProcessInfo.processInfo.arguments.contains("--onboarding-tutorial")
        #else
        let debugTutorial = false
        #endif
        _step = State(initialValue: entry == .tutorial || debugTutorial ? .tutorial : .welcome)
    }

    /// Opened for the tutorial alone, rather than as the last step of setup.
    private var isRevisit: Bool { entry == .tutorial }

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
                    Text(String(localized: step.title))
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text(String(localized: step.message))
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
            // Suppressed on a revisit: four dots for a four-step wizard the user is not in implies
            // three steps still to come, and none of them is there.
            if !isRevisit {
                HStack(spacing: 7) {
                    ForEach(Step.allCases, id: \.rawValue) { candidate in
                        Capsule()
                            .fill(step == candidate ? Color.accentColor : Color.accentColor.opacity(0.28))
                            .frame(width: step == candidate ? 24 : 8, height: 8)
                    }
                }
                .animation(.snappy, value: step)
            }
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
                let state = app.tutorial[lesson]
                let blocker = lesson.blocker(app.tutorialSwitches)
                // Progress outlives the switch: somebody who passed this lesson and later turned
                // the experiment back off has still passed it, and hiding the tick behind an "off"
                // badge would tell them otherwise.
                let blocked = blocker != nil && state != .done
                HStack(alignment: .top, spacing: 12) {
                    // The badge carries the row's state for VoiceOver, which cannot see a stroke
                    // colour: the lesson is its label and waiting/noticed/missed/done its value.
                    stateBadge(state, blocked: blocked)
                        .accessibilityElement()
                        .accessibilityLabel(Text(String(localized: lesson.titleKey)))
                        .accessibilityValue(Text(String(localized: blocked ? "tutorial.state.off" : state.titleKey)))
                        .accessibilityAddTraits(state == .done ? [.isSelected] : [])
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: lesson.titleKey))
                            .font(.callout.weight(.semibold))
                            // Already the badge's label; without this the lesson name is read twice.
                            .accessibilityHidden(true)
                        Text(lesson.detail(peekShortcut: app.shortcuts.shortcuts[.ambientPeek].display))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // On the tick's own terms: a finished lesson keeps its checkmark, so it
                        // must not also carry a line saying nothing is watching for it.
                        if blocked, let reason = blocker?.reasonKey {
                            Text(String(localized: reason))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // The gesture happened and the text was refused. Says which part to change,
                        // because the drag itself looked fine to the person who made it.
                        if state == .missed, let missed = lesson.missedKey {
                            Label(String(localized: missed), systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if nudge, blocker == nil, state == .waiting {
                            Label(String(localized: lesson.nudgeKey), systemImage: "questionmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if blocked, blocker == .ambientPeekOff {
                            // Prominent because it is not an aside: nothing in this row can happen
                            // until it is pressed. Offered only where the reason line above it
                            // appears — the experiment is the switch actually in the way, and the
                            // row still has something left to do. With detection paused, turning
                            // the experiment on changes nothing the user can see.
                            Button(String(localized: TutorialProgress.Blocker.enableButtonTitleKey)) {
                                app.enableAmbientPeek()
                                // The page already in the browser still carries the sentence saying
                                // this route is off, and that sentence is now wrong.
                                if app.tutorialPracticeOpen { openPracticePage() }
                            }
                                .buttonStyle(.borderedProminent)
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
                        Button("permission.turn-on") {
                            app.permissionDeclined = false
                            step = .permission
                        }
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
        .task(id: app.tutorialPracticeOpen) {
            guard app.tutorialPracticeOpen else { return }
            // Long enough that somebody working through the page in order finishes before it
            // appears, short enough to catch somebody sitting in front of a page where nothing
            // happened and no longer sure whether to try again.
            try? await Task.sleep(for: .seconds(45))
            // A cancelled sleep throws, and leaving this step cancels it — including by the route
            // this very card offers, the button into the permission wizard. Without this, coming
            // back finds every waiting row already nudged two seconds in.
            guard !Task.isCancelled else { return }
            nudge = true
        }
        .onChange(of: app.tutorial) { previous, current in announce(previous, current) }
    }

    /// Waiting, noticed, missed, opened — plus the row that cannot report anything because its
    /// gesture is switched off. The noticed state matters most: it tells the user FlowPeek saw their
    /// text, which is the half of the interaction that is otherwise invisible.
    private func stateBadge(_ state: TutorialProgress.State, blocked: Bool) -> some View {
        ZStack {
            if blocked {
                Image(systemName: "slash.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                switch state {
                case .waiting:
                    Circle().strokeBorder(.secondary.opacity(0.45), lineWidth: 1.5)
                case .detected:
                    Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                case .missed:
                    Circle().strokeBorder(.orange, lineWidth: 1.5)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                case .done:
                    Circle().fill(.green)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 18, height: 18)
    }

    /// "The ticks fill in as you go" is the card's whole promise, and a tick filling in is silent:
    /// VoiceOver re-reads a row only if the user navigates back to it, and by then they have already
    /// had to guess whether the gesture worked.
    ///
    /// Only while FlowPeek is frontmost and has a key window to post from. The tick usually fills in
    /// while the browser is in front — the drag and the copy both happen over there — and VoiceOver
    /// does not surface an announcement from a background application, so posting one there would
    /// be a claim this card cannot keep. The badge's own label and value carry the change instead,
    /// read out when the user comes back to the row.
    private func announce(_ previous: TutorialProgress, _ current: TutorialProgress) {
        guard NSApp.isActive, let window = NSApp.keyWindow else { return }
        guard let changed = availableLessons.first(where: { previous[$0] != current[$0] }) else { return }
        let sentence = "\(String(localized: changed.titleKey)): \(String(localized: current[changed].titleKey))"
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
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
                if showsBackButton { Button("common.back") { back() } }
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
                        // Only on a revisit, and only once there is something to clear. Progress
                        // outlives the window now, so a returning user meets their own ticks and
                        // needs a way to mean "I want to practise this again" rather than reading a
                        // finished list; during setup the same list is being filled in for the
                        // first time and the footer already has three buttons.
                        if isRevisit, app.tutorial != TutorialProgress() {
                            Button("tutorial.restart") {
                                app.resetTutorial()
                                nudge = false
                            }
                            .controlSize(.large)
                        }
                        Button("tutorial.open-page") { openPracticePage() }
                            .controlSize(.large)
                        // "Finish Anyway" is nonsense addressed to somebody who finished setup days
                        // ago; a recap just closes. Closing still settles `onboardingComplete` the
                        // way every other dismissal does, which for a returning user is a write of
                        // the value it already had.
                        if isRevisit {
                            Button("common.close") { close() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        } else {
                            Button(app.tutorial.isComplete(among: availableLessons) ? "common.start" : "tutorial.skip") { completion() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
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
        step = permissionSettled ? .launch : .permission
    }

    /// Back to the checklist on a revisit: the permission step is a detour the tutorial itself
    /// offered, not a stage of a setup flow the returning user is walking through.
    private var permissionDestination: Step { isRevisit ? .tutorial : .launch }

    private func advancePastPermission() {
        guard step != permissionDestination else { return }
        step = permissionDestination
    }

    /// Declining is a step forward, not a dismissal: the login question and the tutorial are still
    /// worth asking, and the clipboard lesson still works.
    private func decline() {
        app.permissionDeclined = true
        step = permissionDestination
    }

    /// On a revisit the tutorial is the root of the window, so there is nothing behind it to go
    /// back to — walking a returning user into the permission wizard is not what they asked for.
    private var showsBackButton: Bool {
        isRevisit ? step != .tutorial : step > .welcome
    }

    private func back() {
        if isRevisit { step = .tutorial; return }
        switch step {
        case .tutorial: step = .launch
        case .launch: step = permissionSettled ? .welcome : .permission
        case .permission, .welcome: step = .welcome
        }
    }

    /// One opener, because what the page prints depends on which lessons are on offer and whether
    /// the pointing experiment is on. A second copy of that argument list is how the page and this
    /// checklist end up describing two different sets of gestures.
    private func openPracticePage() {
        // Get out of the way first: this window floats, and it was sitting squarely on top of the
        // page the user has to drag across.
        stepAside()
        app.notePracticePageOpened()
        TutorialPractice.open(
            lessons: availableLessons,
            peekShortcut: app.shortcuts.shortcuts[.ambientPeek].display,
            switches: app.tutorialSwitches
        )
    }

    /// The permission question has an answer, whichever one it is.
    private var permissionSettled: Bool {
        app.accessibilityGranted || app.permissionDeclined
    }

    private var availableLessons: [TutorialProgress.Lesson] {
        TutorialProgress.Lesson.available(accessibilityGranted: app.accessibilityGranted)
    }

    private var waitingMessageKey: String.LocalizationValue {
        permissionFlow.phase == .waitingForUser ? "permission.waiting" : "permission.required"
    }
}
