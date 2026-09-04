import AppKit
import FlowPeekCore
import ServiceManagement
import SwiftUI

@MainActor
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()
    private var window: NSWindow?
    private var spaceObserver: NSObjectProtocol?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let view = OnboardingView(
            completion: { [weak self] in
                AppState.shared.onboardingComplete = true
                self?.closeWindow()
            },
            close: { [weak self] in self?.closeWindow() }
        )
        let controller = NSHostingController(rootView: view.environmentObject(AppState.shared))
        let window = OnboardingWindow(contentViewController: controller)
        window.title = String(localized: "onboarding.window.title")
        window.styleMask = [.borderless, .closable, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.level = .floating
        window.hidesOnDeactivate = false
        window.setContentSize(NSSize(width: 720, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
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

    private func closeWindow() {
        window?.close()
        window = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }
}

private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct OnboardingView: View {
    /// Permission is the only step that can complete itself; the login step is a question, so it
    /// always waits for an answer.
    private enum Step: Int, CaseIterable, Comparable {
        case welcome, permission, launch

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var symbol: String {
            switch self {
            case .welcome: "point.3.connected.trianglepath.dotted"
            case .permission: "hand.point.up.left.and.text"
            case .launch: "power"
            }
        }

        var title: String.LocalizationValue {
            switch self {
            case .welcome: "onboarding.welcome.title"
            case .permission: "onboarding.permission.title"
            case .launch: "onboarding.launch.title"
            }
        }

        var message: String.LocalizationValue {
            switch self {
            case .welcome: "onboarding.welcome.message"
            case .permission: "onboarding.permission.message"
            case .launch: "onboarding.launch.message"
            }
        }
    }

    @EnvironmentObject private var app: AppState
    @State private var step: Step = .welcome
    @State private var permissionFlow = AccessibilityPermissionFlow(isGranted: false)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    let completion: () -> Void
    let close: () -> Void

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
        }
        .task(id: step) {
            guard step == .permission else { return }
            while !Task.isCancelled && !app.accessibilityGranted {
                app.refreshPermission()
                if !app.accessibilityGranted { permissionFlow.recordUnconfirmedCheck() }
                try? await Task.sleep(for: .milliseconds(500))
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
                ForEach(Step.allCases, id: \.rawValue) { candidate in
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
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, value in applyLaunchAtLogin(value) }
            }
            if let launchError {
                Text(launchError).font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: 540, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.22)))
        .togglesOnTap($launchAtLogin, cornerRadius: 18)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if step == .permission && (permissionFlow.shouldOfferRelaunch || app.accessibilityNeedsRepair) {
                Text(String(localized: app.accessibilityNeedsRepair ? "permission.registration.changed" : "permission.relaunch.help"))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("permission.reset") { app.resetAccessibilityRegistration() }
                    Button("permission.relaunch") { app.relaunchAfterPermissionChange() }
                }
                if let error = app.permissionRecoveryError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
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
                        Button(String(localized: permissionFlow.phase == .waitingForUser ? "permission.open-again" : "permission.open-settings")) {
                            permissionFlow.beginWaitingForSystemSettings()
                            app.requestAccessibility()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                case .launch:
                    Button("common.start") { completion() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    /// Nothing to do on the permission step once it is already granted, so it is skipped rather than
    /// flashed past.
    private func advanceFromWelcome() {
        step = app.accessibilityGranted ? .launch : .permission
    }

    private func advancePastPermission() {
        guard step != .launch else { return }
        step = .launch
    }

    private func back() {
        switch step {
        case .launch: step = app.accessibilityGranted ? .welcome : .permission
        case .permission, .welcome: step = .welcome
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try app.setLaunchAtLogin(enabled)
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            // The switch must not claim a state the system refused.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var waitingMessageKey: String.LocalizationValue {
        permissionFlow.phase == .waitingForUser ? "permission.waiting" : "permission.required"
    }
}
