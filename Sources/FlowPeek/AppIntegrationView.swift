import AppKit
import FlowPeekCore
import SwiftUI

/// One integration, drawn the same way wherever it appears.
///
/// The wizard and the settings tab show the same rows, because they are the same decision asked at
/// two different moments, and a setup step that looks nothing like the place you go to undo it is
/// two things to learn instead of one. The only difference is the frame around them.
struct AppIntegrationRow: View {
    @ObservedObject var center: AppIntegrationCenter
    let integration: AppIntegration
    /// Whether the file itself can be opened out and read. On during setup, where the whole point is
    /// that nothing is written before it has been shown.
    var showsPayload: Bool = true

    @State private var expanded = false

    private var status: AppIntegrationStatus { center.status(integration.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: integration.displayName).font(.headline)
                        statusBadge
                    }
                    Text(String(localized: integration.reasonKey)).localizedCallout()
                    if showsPayload { disclosure }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { status.isInstalled },
                    set: { center.setInstalled($0, for: integration) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(verbatim: integration.displayName))
            }
            if expanded { payload }
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var icon: some View {
        Image(nsImage: appIcon)
            .resizable()
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
    }

    /// The application's own icon, which is the fastest way for somebody to know which of their
    /// editors is being talked about. A symbol stands in when the icon cannot be had.
    private var appIcon: NSImage {
        for bundleID in integration.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            ?? NSImage()
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .active:
            badge("integration.state.on", color: .green)
        case .outdated:
            badge("integration.state.outdated", color: .orange)
        case .failed:
            badge("integration.state.failed", color: .red)
        case .offered, .absent:
            EmptyView()
        }
    }

    private func badge(_ key: LocalizedStringKey, color: Color) -> some View {
        Text(key)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    /// The file, on request. Nothing FlowPeek writes into somebody else's application should have to
    /// be taken on trust, and the fastest way to earn that is to put it on screen before it is
    /// written rather than to describe it.
    private var disclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                Text(expanded ? "integration.payload.hide" : "integration.payload.show")
                    .font(.callout)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.top, 2)
    }

    private var payload: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: center.destination(of: integration).path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            ScrollView {
                Text(verbatim: center.payload(of: integration) ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 190)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Every integration found on this Mac, or a sentence explaining what the list would hold.
///
/// Built for more than one from the start: the rows are a `ForEach` over whatever was found, the
/// empty case says so rather than showing an empty box, and nothing here knows that Sublime is the
/// only one today.
struct AppIntegrationList: View {
    @ObservedObject var center: AppIntegrationCenter
    var showsPayload: Bool = true

    var body: some View {
        if center.listed.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("integration.none")
                    .localizedCallout()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(spacing: 10) {
                ForEach(center.listed) { integration in
                    AppIntegrationRow(center: center, integration: integration, showsPayload: showsPayload)
                }
            }
        }
    }
}

private extension Text {
    func localizedCallout() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
