import AppKit
import FlowPeekCore
import SwiftUI

@MainActor
final class AIPromptCoordinator: NSObject, NSWindowDelegate {
    static let shared = AIPromptCoordinator()
    private var window: NSWindow?

    func show(context: String) {
        window?.close()
        let model = AIPromptModel(context: context)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "ai.window.title")
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: AIPromptView(model: model))
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

@MainActor
final class AIPromptModel: ObservableObject {
    let context: String
    @Published var instruction = ""
    @Published var provider = AIProviderKind(rawValue: UserDefaults.standard.string(forKey: "flowpeek.ai.provider") ?? "") ?? .openAI
    @Published var draft: AIDiagramDraft?
    @Published var editedMermaid = ""
    @Published var isLoading = false
    @Published var error: String?
    @Published var conversation: [AIMessage] = []

    init(context: String) { self.context = context }

    func generate() {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let key = KeychainStore().read(account: provider.rawValue) else {
            error = String(localized: "ai.error.missing-key"); return
        }
        isLoading = true; error = nil
        let request = AIDiagramRequest(context: context, instruction: instruction, conversation: conversation)
        let currentProvider = provider
        let currentInstruction = instruction
        Task {
            do {
                let value = try await AIProviderClient().generate(kind: currentProvider, model: currentProvider.defaultModel, apiKey: key, request: request)
                draft = value; editedMermaid = value.mermaid
                conversation.append(AIMessage(role: .user, text: currentInstruction))
                conversation.append(AIMessage(role: .assistant, text: value.notes))
            } catch { self.error = localizedUserMessage(error) }
            isLoading = false
        }
    }

    func validateOrRepair() {
        do { _ = try MermaidSource(rawValue: editedMermaid); error = nil }
        catch {
            instruction = String(localized: "ai.repair.prompt") + "\n\n" + localizedUserMessage(error) + "\n\n" + editedMermaid
            generate()
        }
    }
}

func localizedUserMessage(_ error: Error) -> String {
    guard let validation = error as? MermaidSource.ValidationError else { return error.localizedDescription }
    switch validation {
    case .empty:
        return String(localized: "mermaid.error.empty")
    case .tooLarge(let count):
        return String(format: String(localized: "mermaid.error.too-large"), count, MermaidSource.maximumCharacters)
    case .tooManyLines(let count):
        return String(format: String(localized: "mermaid.error.too-many-lines"), count, MermaidSource.maximumLines)
    case .lineTooLong(let count):
        return String(format: String(localized: "mermaid.error.line-too-long"), count, MermaidSource.maximumLineLength)
    case .unsupportedSyntax:
        return String(localized: "mermaid.error.unsupported")
    }
}

struct AIPromptView: View {
    @ObservedObject var model: AIPromptModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.draft == nil {
                    ContentUnavailableView("ai.empty.title", systemImage: "sparkles", description: Text("ai.empty.description"))
                } else {
                    MermaidPreviewSurface(source: model.editedMermaid) { model.error = $0 }
                        .padding(20)
                }
            }
            .frame(minWidth: 500)

            VStack(alignment: .leading, spacing: 14) {
                Text("ai.inspector.title").font(.title2.bold())
                Picker("ai.provider", selection: $model.provider) {
                    ForEach(AIProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                GroupBox("ai.context") {
                    ScrollView { Text(model.context).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 90).padding(5)
                }
                TextField("ai.prompt.placeholder", text: $model.instruction, axis: .vertical)
                    .lineLimit(3...7).textFieldStyle(.roundedBorder)
                HStack {
                    Button("ai.generate") { model.generate() }
                        .buttonStyle(.borderedProminent).disabled(model.isLoading || model.instruction.isEmpty)
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    if model.draft != nil { Button("ai.repair.validate") { model.validateOrRepair() } }
                }
                if let draft = model.draft {
                    Text(draft.title).font(.headline)
                    TextEditor(text: $model.editedMermaid)
                        .font(.system(.caption, design: .monospaced))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Text(draft.notes).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(20).frame(minWidth: 320, idealWidth: 380)
        }
    }
}
