import AppKit
import FlowPeekCore
import SwiftUI

@MainActor
final class APIKeyCoordinator {
    static let shared = APIKeyCoordinator()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 310), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "keys.window.title")
        window.contentViewController = NSHostingController(rootView: APIKeyView())
        window.center(); window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}

private struct APIKeyView: View {
    @State private var values: [AIProviderKind: String] = [:]
    @State private var status = ""

    var body: some View {
        Form {
            ForEach(AIProviderKind.allCases, id: \.self) { provider in
                SecureField(provider.displayName, text: binding(for: provider))
            }
            Text("keys.help").font(.footnote).foregroundStyle(.secondary)
            HStack { Spacer(); Button("keys.save") { save() }.buttonStyle(.borderedProminent) }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .padding(24)
        .onAppear {
            for provider in AIProviderKind.allCases { values[provider] = KeychainStore().read(account: provider.rawValue) ?? "" }
        }
    }

    private func binding(for provider: AIProviderKind) -> Binding<String> {
        Binding(get: { values[provider] ?? "" }, set: { values[provider] = $0 })
    }

    private func save() {
        do {
            for (provider, value) in values where !value.isEmpty { try KeychainStore().save(value, account: provider.rawValue) }
            status = String(localized: "keys.saved")
        } catch { status = error.localizedDescription }
    }
}
