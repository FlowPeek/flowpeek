import AppKit
import FlowPeekCore
import SwiftUI

struct SettingsView: View {
    /// Not private: the menu bar's "Change Shortcuts…" row opens this window on a named pane, and
    /// the pane it wants is the whole point of that row.
    enum SettingsSection: String, CaseIterable {
        case general
        case shortcuts
        case ai

        var title: LocalizedStringKey {
            switch self {
            case .general: "settings.general"
            case .shortcuts: "settings.shortcuts"
            case .ai: "settings.ai"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .ai: "sparkles"
            }
        }
    }

    @EnvironmentObject private var app: AppState
    /// The centre is its own observable object, so reading it through `app` would never redraw: the
    /// dimmed rows and the AI card's shortcut would keep naming the previous state.
    @ObservedObject private var shortcuts = AppState.shared.shortcuts
    @State private var selection: SettingsSection
    @State private var relaunchPrompt: RelaunchPrompt?
    let close: () -> Void

    init(section: SettingsSection = .general, close: @escaping () -> Void) {
        _selection = State(initialValue: section)
        self.close = close
    }

    /// The card's own copy names the chord that opens an outlined diagram, and that chord is
    /// rebindable on the next tab along, so it is read from the store rather than spelled out in
    /// the catalogue. `shortcuts` is observed, so a rebind rewrites this sentence immediately.
    private var ambientDescription: String {
        String(
            format: String(localized: "settings.ambient.description"),
            shortcuts.shortcuts[.ambientPeek].display
        )
    }

    var body: some View {
        ZStack {
            FlowPeekGlassBackground()
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), .clear, Color.purple.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 18) {
                    sidebar
                    content
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.30), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 35, y: 16)
        .padding(30)
        .onAppear {
            app.refreshPermission()
            app.refreshLaunchAtLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermission()
            // Approving the login item happens in System Settings, so coming back is the only moment
            // this window can learn about it.
            app.refreshLaunchAtLoginStatus()
        }
        .alert(
            relaunchPrompt?.title ?? "",
            isPresented: Binding(
                get: { relaunchPrompt != nil },
                set: { if !$0 { relaunchPrompt = nil } }
            ),
            presenting: relaunchPrompt
        ) { prompt in
            Button(prompt.restartNow) { app.relaunch() }
            Button(prompt.later, role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FlowPeekWindowCloseButton(action: close)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("settings.window.title")
                .font(.headline)
            Spacer()
            Text("FlowPeek")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SettingsSection.allCases, id: \.rawValue) { section in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = section }
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.body.weight(selection == section ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background {
                            if selection == section {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(Color.accentColor.opacity(0.20))
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Label("settings.sidebar.hint", systemImage: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .padding(10)
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18)))
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selection {
                case .general: generalSettings
                case .shortcuts: shortcutSettings
                case .ai: aiSettings
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18)))
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("settings.general", description: "settings.general.description")

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    settingIcon("figure.arms.open", color: app.accessibilityGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("settings.accessibility").font(.headline)
                        Text("settings.accessibility.description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    statusBadge
                }
                HStack {
                    // The pane is worth offering either way — it is where a grant is reviewed or
                    // taken back — but it is only the thing to do next while the grant is missing,
                    // not for something the badge two lines up reports as already given. One
                    // button, wearing two styles: a copy per style would let the label and the
                    // action drift apart in a branch nobody is looking at.
                    if app.accessibilityGranted {
                        accessibilityPaneButton.buttonStyle(.bordered)
                    } else {
                        accessibilityPaneButton.buttonStyle(.borderedProminent)
                        // Removing the TCC entry destroys a grant, so it must never be the button
                        // that looks like the default.
                        Button("permission.reset") { app.confirmAccessibilityReset() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    settingIcon("globe", color: .indigo)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("settings.language").font(.headline)
                        Text("settings.language.description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    Picker("settings.language", selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(String(localized: option.titleKey)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if app.needsRelaunchForLanguage {
                    HStack(spacing: 10) {
                        Text("settings.language.relaunch")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("settings.language.relaunch.action") { app.relaunch() }
                            .controlSize(.small)
                    }
                }
            }

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    settingIcon("doc.on.clipboard", color: .teal)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("settings.clipboard").font(.headline)
                        Text("settings.clipboard.description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    Toggle("settings.clipboard", isOn: $app.clipboardWatchEnabled)
                        .labelsHidden()
                        .accessibilityHint(Text("settings.clipboard.description"))
                        .onChange(of: app.clipboardWatchEnabled) { _, _ in app.applyEnabledState() }
                }
            }
            .togglesOnTap($app.clipboardWatchEnabled)

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    settingIcon("viewfinder", color: .pink)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("settings.ambient")
                                .font(.headline)
                                // Reads the accessibility tree, so without the grant it is a title
                                // for something that cannot happen yet.
                                .foregroundStyle(app.accessibilityGranted ? .primary : .secondary)
                            Text("settings.experimental")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.pink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.pink.opacity(0.12), in: Capsule())
                        }
                        Text(verbatim: ambientDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    Toggle("settings.ambient", isOn: $app.ambientPeekEnabled)
                        .labelsHidden()
                        .accessibilityHint(Text(verbatim: ambientDescription))
                        .onChange(of: app.ambientPeekEnabled) { _, _ in app.applyEnabledState() }
                }
                // The preference stays writable while the grant is missing: `applyEnabledState()`
                // starts the monitor the moment permission lands, and refusing the switch would
                // leave the user nothing to turn on afterwards.
                if !app.accessibilityGranted {
                    HStack(alignment: .top, spacing: 10) {
                        Label("settings.ambient.needs-permission", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("settings.permission.request") { app.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }
            .togglesOnTap($app.ambientPeekEnabled)

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    settingIcon("power", color: .blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("settings.launch-at-login").font(.headline)
                        Text("settings.launch-at-login.description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    Toggle("settings.launch-at-login", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .accessibilityHint(Text("settings.launch-at-login.description"))
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
            .togglesOnTap(launchAtLoginBinding)

            Label("settings.privacy", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("settings.shortcuts", description: "settings.shortcuts.description")
                Spacer()
                Button("shortcut.reset-all") { shortcuts.resetAll() }
                    .disabled(shortcuts.shortcuts.isDefault)
            }

            ForEach(FlowPeekShortcutAction.allCases, id: \.rawValue) { action in
                let isActive = shortcuts.activeActions.contains(action)
                settingsCard {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: action.titleKey)).font(.headline)
                            Text(String(localized: action.detailKey))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        ShortcutRecorder(action: action, center: shortcuts)
                    }
                    // The recorder stays live so the combination can be set up in advance; what the
                    // row has to say is that pressing it right now does nothing. Which complaint
                    // that is belongs to the action, not to this row. `app.isEnabled` is
                    // `@Published`, so the wording follows a pause raised from the menu bar without
                    // this view holding a second reader of the same defaults key.
                    if !isActive {
                        Label(
                            String(localized: action.inactiveHintKey(detectionPaused: !app.isEnabled)),
                            systemImage: "moon.zzz"
                        )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(isActive ? 1 : 0.55)
            }

            Label("settings.shortcuts.note", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        // The clash line under a recorder is only as fresh as the last registration, and the app
        // that owns the combination can be installed or started long after this one launched. This
        // pane is where that line is read, so opening it is the moment to ask again.
        .onAppear { shortcuts.refreshAvailability() }
    }

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("settings.ai", description: "settings.ai.description")
                Spacer()
                Text("settings.experimental")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.12), in: Capsule())
            }

            settingsCard {
                HStack(spacing: 14) {
                    settingIcon("wand.and.stars", color: .purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.ai.enabled").font(.headline)
                        AIShortcutLabel(center: app.shortcuts)
                    }
                    Spacer()
                    Toggle("settings.ai.enabled", isOn: $app.aiEnabled)
                        .labelsHidden()
                        // The experiment owns its hot key: off means FlowPeek gives the combination
                        // back to whatever app the user is in.
                        .onChange(of: app.aiEnabled) { _, _ in app.applyEnabledState() }
                }
            }
            .togglesOnTap($app.aiEnabled)

            settingsCard {
                HStack(spacing: 14) {
                    settingIcon("cpu", color: .indigo)
                    Picker("settings.ai.provider", selection: $app.providerRawValue) {
                        ForEach(AIProviderKind.allCases, id: \.rawValue) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Divider().opacity(0.5)

                Button {
                    APIKeyCoordinator.shared.show()
                } label: {
                    Label("settings.ai.keys", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Its own view so it observes the centre directly: `app.shortcuts` is a nested
    /// ObservableObject, and a rebind on the Shortcuts tab publishes there, not through AppState.
    private struct AIShortcutLabel: View {
        @ObservedObject var center: ShortcutCenter

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: String(
                    format: String(localized: "settings.ai.shortcut"),
                    center.shortcuts[.aiPrompt].display
                ))
                Text("settings.ai.keychain")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 25, weight: .bold, design: .rounded))
            Text(description).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { app.language },
            set: { chosen in
                // Storing a new override is not by itself a reason to restart: picking the language
                // this process already launched in has nothing to show for a relaunch.
                guard app.apply(language: chosen), app.needsRelaunchForLanguage else { return }
                // The window will not re-render in the new language, so the choice looks like it did
                // nothing. The notice row below survives closing this window now, but it is the row
                // the user already missed, so the moment of choice asks the question outright.
                relaunchPrompt = RelaunchPrompt(language: chosen)
            }
        )
    }

    /// Reads the system's answer rather than what was asked for: `register()` can succeed straight
    /// into requires-approval, where the item exists and still never launches.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { app.launchAtLoginState.isOn },
            set: { app.setLaunchAtLogin($0) }
        )
    }

    /// The alert has to be built by hand: this process is still localized in the language being left
    /// behind, and asking "Restart now?" in that language is exactly the confusion it exists to end.
    private struct RelaunchPrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let restartNow: String
        let later: String

        init(language: AppLanguage) {
            let bundle = Self.bundle(for: language)
            title = bundle.localizedString(forKey: "settings.language.relaunch.title", value: nil, table: nil)
            message = bundle.localizedString(forKey: "settings.language.relaunch", value: nil, table: nil)
            restartNow = bundle.localizedString(forKey: "settings.language.relaunch.action", value: nil, table: nil)
            later = bundle.localizedString(forKey: "common.later", value: nil, table: nil)
        }

        /// Falls back to the main bundle for `.system`, and for a language this build has no
        /// `.lproj` for, which is also what the app itself would resolve to.
        private static func bundle(for language: AppLanguage) -> Bundle {
            guard let code = language.localeIdentifier,
                  let url = Bundle.main.url(forResource: code, withExtension: "lproj"),
                  let bundle = Bundle(url: url)
            else { return .main }
            return bundle
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            content()
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16)))
    }

    private func settingIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var accessibilityPaneButton: Button<Text> {
        Button("settings.permission.request") { app.openAccessibilitySettings() }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(app.accessibilityGranted ? .green : .orange).frame(width: 7, height: 7)
            Text(String(localized: app.accessibilityGranted ? "permission.granted.short" : "permission.required.short"))
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}
