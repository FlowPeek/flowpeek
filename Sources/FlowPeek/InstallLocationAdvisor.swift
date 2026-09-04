import AppKit

@MainActor
enum InstallLocationAdvisor {
    static func promptIfNeeded() {
        let source = Bundle.main.bundleURL
        guard source.path.hasPrefix("/Volumes/") else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "install.title")
        alert.informativeText = String(localized: "install.message")
        alert.addButton(withTitle: String(localized: "install.move"))
        alert.addButton(withTitle: String(localized: "common.later"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                NSWorkspace.shared.activateFileViewerSelecting([destination]); return
            }
            try FileManager.default.copyItem(at: source, to: destination)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }
}
