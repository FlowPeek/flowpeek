import AppKit
import FlowPeekCore
import SwiftUI

@MainActor
final class APIKeyCoordinator: NSObject, NSWindowDelegate {
    static let shared = APIKeyCoordinator()
    private var window: NSWindow?

    private static let size = CGSize(width: 480, height: 430)

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: APIKeyView(close: { [weak self] in self?.closeWindow() }))
        // A panel rather than a window: it is opened from the AI window and from Settings, and it
        // must not take main status away from either of them.
        let window = FlowPeekGlassPanel(contentViewController: controller)
        window.title = String(localized: "keys.window.title")
        window.styleMask = [.borderless, .closable, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        // The content draws its own shadow inside `.padding`, so AppKit must not draw a second one
        // tracing the whole window rect.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .floating
        window.setContentSize(NSSize(width: Self.size.width, height: Self.size.height))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }

    /// Escape reaches `cancelOperation`, which closes the panel without going through
    /// `closeWindow()`; without this the coordinator would keep fronting a closed panel.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct APIKeyView: View {
    let close: () -> Void

    @State private var values: [AIProviderKind: String] = [:]
    /// Which providers had a key when this panel opened, so a field of dots can say whether it is
    /// holding a key that is already in the Keychain or one being typed for the first time.
    @State private var stored: Set<AIProviderKind> = []
    @State private var failure: String?
    @State private var savedProviders: Set<AIProviderKind> = []

    var body: some View {
        FlowPeekGlassSurface(cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(AIProviderKind.allCases, id: \.self) { provider in
                        keyCard(provider)
                    }
                    Label("keys.help", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("keys.save") { save() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .shadow(color: .black.opacity(0.24), radius: 30, y: 14)
        .padding(24)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 12) {
            FlowPeekWindowCloseButton(action: close)
            Image(systemName: "key.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("keys.window.title").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
    }

    private func keyCard(_ provider: AIProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: provider.displayName).font(.headline)
                Spacer()
                if savedProviders.contains(provider) {
                    Label("keys.saved.badge", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else if stored.contains(provider) {
                    Text("keys.stored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SecureField(String(localized: "keys.field.placeholder"), text: binding(for: provider))
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .padding(9)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.16)))
                .accessibilityLabel(Text(verbatim: provider.displayName))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16)))
    }

    private func load() {
        let store = KeychainStore()
        for provider in AIProviderKind.allCases {
            let existing = store.read(account: provider.rawValue)
            values[provider] = existing ?? ""
            if existing != nil { stored.insert(provider) }
        }
    }

    private func binding(for provider: AIProviderKind) -> Binding<String> {
        Binding(
            get: { values[provider] ?? "" },
            set: { newValue in
                values[provider] = newValue
                // Typing again after a save means this field is no longer what is in the Keychain.
                savedProviders.remove(provider)
            }
        )
    }

    private func save() {
        let store = KeychainStore()
        var written: Set<AIProviderKind> = []
        do {
            for (provider, value) in values where !value.isEmpty {
                try store.save(value, account: provider.rawValue)
                written.insert(provider)
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        failure = nil
        savedProviders = written
        stored.formUnion(written)
        // The AI window can be standing behind this one offering to take a key; it belongs to this
        // same application, so no activation changes and nothing else would tell it the key landed.
        NotificationCenter.default.post(name: .flowPeekAPIKeysChanged, object: nil)
    }
}
