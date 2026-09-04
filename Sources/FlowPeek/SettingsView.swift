import AppKit
import FlowPeekCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum SettingsSection: String, CaseIterable {
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
    @State private var selection = SettingsSection.general
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var needsRelaunchForLanguage = false
    let close: () -> Void

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
        .onAppear { app.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermission()
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
                    Button("settings.permission.request") { app.openAccessibilitySettings() }
                        .buttonStyle(.bordered)
                    if !app.accessibilityGranted {
                        Button("permission.reset") { app.resetAccessibilityRegistration() }
                            .buttonStyle(.borderedProminent)
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
                    Picker("", selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(String(localized: option.titleKey)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if needsRelaunchForLanguage {
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
                    Toggle("", isOn: $app.clipboardWatchEnabled)
                        .labelsHidden()
                        .onChange(of: app.clipboardWatchEnabled) { _, _ in app.applyEnabledState() }
                }
            }
            .togglesOnTap($app.clipboardWatchEnabled)

            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    settingIcon("viewfinder", color: .pink)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("settings.ambient").font(.headline)
                            Text("settings.experimental")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.pink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.pink.opacity(0.12), in: Capsule())
                        }
                        Text("settings.ambient.description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    Toggle("", isOn: $app.ambientPeekEnabled)
                        .labelsHidden()
                        .onChange(of: app.ambientPeekEnabled) { _, _ in app.applyEnabledState() }
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
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, value in
                            do {
                                try app.setLaunchAtLogin(value)
                                launchError = nil
                            } catch {
                                launchError = error.localizedDescription
                            }
                        }
                }
                if let launchError {
                    Text(launchError).font(.footnote).foregroundStyle(.red)
                }
            }
            .togglesOnTap($launchAtLogin)

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
                Button("shortcut.reset-all") { app.shortcuts.resetAll() }
                    .disabled(app.shortcuts.shortcuts.isDefault)
            }

            ForEach(FlowPeekShortcutAction.allCases, id: \.rawValue) { action in
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
                        ShortcutRecorder(action: action, center: app.shortcuts)
                    }
                }
            }

            Label("settings.shortcuts.note", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
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
                    Toggle("", isOn: $app.aiEnabled).labelsHidden()
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
            set: { needsRelaunchForLanguage = app.apply(language: $0) || needsRelaunchForLanguage }
        )
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
