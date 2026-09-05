import AppKit
import FlowPeekCore
import SwiftUI

extension Notification.Name {
    /// Raised when a key is written to the Keychain. A window standing there offering to take one
    /// has no other way to learn that it arrived: the key sheet belongs to this same application, so
    /// no activation changes and nothing else republishes.
    static let flowPeekAPIKeysChanged = Notification.Name("flowpeek.ai.keys-changed")
}

@MainActor
final class AIPromptCoordinator: NSObject, NSWindowDelegate {
    static let shared = AIPromptCoordinator()
    private var window: NSWindow?
    private var model: AIPromptModel?

    private static let size = CGSize(width: 1040, height: 700)
    private static let minSize = CGSize(width: 820, height: 540)

    func show(context: String) {
        closeWindow()
        let model = AIPromptModel(context: context)
        self.model = model
        // Borderless, like every other FlowPeek surface: the glass is the window and SwiftUI draws
        // the close control. `.resizable` only gives AppKit permission — the edge drags come from
        // `ResizableContentView`.
        let window = FlowPeekGlassWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "ai.window.title")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // A hosting *view*, not a controller: a controller re-imposes SwiftUI's fitting size on
        // every layout and the window cannot be resized at all. See `PreviewCoordinator.makePanel`.
        let hosting = NSHostingView(
            rootView: AIPromptView(model: model, close: { [weak self] in self?.closeWindow() })
        )
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        window.contentView = ResizableContentView(content: hosting)
        window.setFrame(CGRect(origin: window.frame.origin, size: Self.size), display: false)
        window.contentMinSize = Self.minSize
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.close()
        model?.release()
        model = nil
    }

    /// Escape reaches `cancelOperation`, which closes the window without going through
    /// `closeWindow()`; this is the only path that gives the pooled engine back on that route.
    func windowWillClose(_ notification: Notification) {
        window = nil
        model?.release()
        model = nil
    }
}

@MainActor
final class AIPromptModel: ObservableObject {
    /// The same view model, pooled engine and typed failure card the rest of the app previews
    /// with, so a diagram made here behaves exactly as one opened from a selection.
    let preview = DiagramViewModel(title: "")

    @Published private(set) var session: AIDiagramSession
    @Published var instruction = ""
    @Published var provider: AIProviderKind {
        didSet {
            guard provider != oldValue else { return }
            // The window and the Settings pane are two views of one choice; leaving them to
            // disagree is how a key gets pasted for a provider the next request will not use.
            AppState.shared.providerRawValue = provider.rawValue
            refreshKey()
        }
    }

    /// The one-word report for a text copy. The chrome's other copies go through the preview, which
    /// keeps its own; a draft that never drew has no preview to report through and still has text.

    private var request: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(context: String) {
        let kind = AIProviderKind(rawValue: AppState.shared.providerRawValue) ?? .openAI
        provider = kind
        session = AIDiagramSession(context: context, hasKey: KeychainStore().read(account: kind.rawValue) != nil)
    }

    func release() {
        request?.cancel()
        request = nil
        noticeTask?.cancel()
        noticeTask = nil
        preview.release()
    }

    /// One `SecItemCopyMatching` against a single account — measured in microseconds, and the only
    /// way to answer a question the window is asked on every appearance and every key change.
    func refreshKey() {
        session.hasKey = KeychainStore().read(account: provider.rawValue) != nil
    }

    // MARK: - Asking

    func send() {
        send(instruction)
    }

    private func send(_ text: String) {
        let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.canSend(asked) else { return }
        guard let key = KeychainStore().read(account: provider.rawValue) else {
            // The key was there when the window last looked and is not there now, which is a real
            // answer rather than a reason to leave the button dead.
            session.hasKey = false
            session.fail(AIFailurePresentation.make(.missingKey))
            return
        }
        let payload = session.beginSending(instruction: asked)
        // Only when the composer is what was sent. A retry replays an earlier turn, and clearing
        // here threw away a repair the reader had asked for and not yet read.
        if asked == instruction.trimmingCharacters(in: .whitespacesAndNewlines) { instruction = "" }
        let kind = provider
        request?.cancel()
        request = Task { [weak self] in
            let outcome: Result<AIDiagramDraft, any Error>
            do {
                outcome = .success(try await AIProviderClient().generate(
                    kind: kind,
                    model: kind.defaultModel,
                    apiKey: key,
                    request: payload
                ))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let draft):
                session.receive(draft)
                preview.title = draft.title
                preview.update(source: draft.mermaid)
            case .failure(let error):
                receive(error)
            }
        }
    }

    /// The reader asking for the same thing again after a failure. Their own words, sent again as a
    /// visible turn rather than replayed silently -- and the words that earned *this* failure, which
    /// is not the same as the last thing typed once a second exchange has happened since.
    func retry(after failure: AITurn.ID) {
        guard let instruction = session.instruction(before: failure) else { return }
        send(instruction)
    }

    private func receive(_ error: any Error) {
        if case AIProviderError.unusableDiagram(let draft, let reason) = error {
            // Recorded even though it cannot be drawn: it is the only text a repair can be asked
            // about, and the only thing the reader can copy out of a request that went wrong.
            session.receive(draft, drawable: false)
            session.fail(AIFailurePresentation.make(.unusableDiagram(reason)))
            return
        }
        session.fail(AIFailurePresentation.make(Self.cause(of: error)))
    }

    private static func cause(of error: any Error) -> AIFailureCause {
        switch error {
        case let provider as AIProviderError:
            switch provider {
            case .missingKey: .missingKey
            case .invalidResponse: .invalidResponse
            case .unusableDiagram: .invalidResponse
            case .server(let status, let body): AIProviderRejection.cause(status: status, body: body)
            }
        // URLError's own description is translated by Foundation and names no key, so it is the one
        // machine sentence worth carrying through.
        case let transport as URLError: .transport(transport.localizedDescription)
        default: .transport(error.localizedDescription)
        }
    }

    // MARK: - Repair

    /// Writes the repair into the composer instead of sending it. The window used to overwrite the
    /// instruction with a repair prompt and post it, so what had been asked in the user's name was
    /// the one thing they never got to read.
    /// `mermaid` is named by the caller rather than looked up here: the diagram that would not draw
    /// is the one on the stage, and the diagram that would not validate is the newest answer, which
    /// never reached the stage at all.
    func composeRepair(reason: String, mermaid: String?) {
        guard let mermaid, !mermaid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        instruction = AIRepairRequest.instruction(
            preamble: String(localized: "ai.repair.prompt"),
            reason: reason,
            mermaid: mermaid
        )
    }

    // MARK: - Taking it away

    func show(_ turn: AITurn) {
        session.show(turn.id)
        guard let draft = session.shownDraft else { return }
        preview.title = draft.title
        preview.update(source: draft.mermaid)
    }

    /// Hands the diagram to the preview every other route in the app ends in, so it can be zoomed,
    /// compared with another one and kept open after this window goes away.
    func openInPreview() {
        guard let draft = session.exportableDraft,
              let source = try? MermaidSource(rawValue: draft.mermaid) else { return }
        AppState.shared.previews.openWindow(
            document: DiagramDocument(title: draft.title, source: source)
        )
    }
}

func localizedUserMessage(_ error: any Error) -> String {
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

// MARK: - The window

struct AIPromptView: View {
    @ObservedObject var model: AIPromptModel
    /// Observed separately: the preview is a nested ObservableObject, so a render finishing or
    /// failing publishes there and never through the model.
    @ObservedObject private var preview: DiagramViewModel
    let close: () -> Void

    @FocusState private var composerFocused: Bool

    init(model: AIPromptModel, close: @escaping () -> Void) {
        self.model = model
        _preview = ObservedObject(wrappedValue: model.preview)
        self.close = close
    }

    var body: some View {
        FlowPeekGlassSurface(cornerRadius: 24) {
            VStack(spacing: 0) {
                chrome
                HStack(alignment: .top, spacing: 16) {
                    stage
                    inspector.frame(width: 372)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .onAppear {
            model.refreshKey()
            composerFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .flowPeekAPIKeysChanged)) { _ in
            model.refreshKey()
        }
        // A key can also be pasted in with the Keychain itself, or removed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshKey()
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: 10) {
            FlowPeekWindowCloseButton(action: close)
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("settings.experimental")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.12), in: Capsule())
            Spacer(minLength: 12)
            if let word = exportWord {
                HStack(spacing: 5) {
                    if preview.exportFeedback == .working { ProgressView().controlSize(.small) }
                    Text(word)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
            DiagramChromeControls(model: preview, keyEquivalentsWork: true)
            // Gated on the diagram having actually drawn rather than on there being a draft: an
            // answer the reader put on the stage to look at may be one that does not parse, and a
            // button that opens nothing is worse than one that is visibly unavailable.
            chromeButton("macwindow", help: "preview.open-window") { model.openInPreview() }
                .disabled(!preview.canExport)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// Only ever the diagram that is on the stage: naming an answer that never drew would put its
    /// title over a diagram somebody else asked for.
    private var title: String {
        guard let drawn = model.session.shownDraft?.title, !drawn.isEmpty else {
            return String(localized: "ai.window.title")
        }
        return drawn
    }

    private var exportWord: LocalizedStringKey? {
        guard let feedback = preview.exportFeedback else { return nil }
        return LocalizedStringKey(feedback.rawValue)
    }

    private func chromeButton(
        _ symbol: String,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            switch model.session.pane {
            case .missingKey: keyOffer
            case .introduction: introduction
            case .diagram:
                // Attached here rather than when the window opens: a pooled engine is a scarce
                // thing, and a window that is still being typed into has nothing to draw with it.
                DiagramStage(model: preview, inset: 14)
                    .onAppear { preview.attach() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18)))
    }

    private var introduction: some View {
        VStack(spacing: 18) {
            haloIcon("sparkles")
            Text("ai.empty.title")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("ai.empty.description")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Text("ai.suggestions.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Self.suggestions, id: \.self) { key in
                    Button {
                        model.instruction = String(localized: String.LocalizationValue(key))
                        composerFocused = true
                    } label: {
                        Text(LocalizedStringKey(key))
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 340)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(28)
    }

    /// Three ways in for somebody who has never written Mermaid and does not know what to ask for.
    private static let suggestions = ["ai.suggestion.flowchart", "ai.suggestion.sequence", "ai.suggestion.state"]

    /// A missing key is an offer, not an error: it says what is needed, where it is kept, and opens
    /// the place it is kept in.
    private var keyOffer: some View {
        VStack(spacing: 16) {
            haloIcon("key.fill")
            Text(verbatim: String(format: String(localized: "ai.key.title"), model.provider.displayName))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("ai.key.description")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            Button("ai.failure.add-key") { APIKeyCoordinator.shared.show() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Label("settings.ai.keychain", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private func haloIcon(_ symbol: String) -> some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.13)).frame(width: 84, height: 84)
            Circle().stroke(Color.white.opacity(0.28), lineWidth: 1).frame(width: 84, height: 84)
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            contextCard
            conversation
            composer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18)))
    }

    /// What the model is being told, shown rather than described: this is the user's own text
    /// leaving their Mac, and the window should never be the only place that is not said out loud.
    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "text.quote")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("ai.context").font(.caption.weight(.semibold))
                Spacer()
                Text(verbatim: String(format: String(localized: "ai.context.length"), model.session.context.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(verbatim: model.session.context)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(height: 62)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.16)))
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.session.turns.isEmpty {
                        Text("ai.conversation.empty")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                    ForEach(model.session.turns) { turn in
                        turnCard(turn).id(turn.id)
                    }
                    if model.session.isSending { sendingRow.id(Self.sendingAnchor) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            .onChange(of: model.session.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(model.session.turns.last?.id, anchor: .bottom) }
            }
            .onChange(of: model.session.isSending) { _, sending in
                guard sending else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.sendingAnchor, anchor: .bottom) }
            }
        }
    }

    private static let sendingAnchor = "sending"

    private var sendingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: String(format: String(localized: "ai.sending"), model.provider.displayName))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func turnCard(_ turn: AITurn) -> some View {
        switch turn.content {
        case .instruction(let text):
            instructionCard(text)
        case .answer(let draft, _):
            answerCard(turn: turn, draft: draft)
        case .failure(let presentation):
            failureCard(presentation, on: turn)
        }
    }

    private func instructionCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("ai.turn.you", systemImage: "person.crop.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.accentColor.opacity(0.18)))
    }

    private func answerCard(turn: AITurn, draft: AIDiagramDraft) -> some View {
        let isShown = model.session.shownTurn == turn.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(verbatim: draft.title.isEmpty ? String(localized: "diagram.default-title") : draft.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
            }
            if !draft.notes.isEmpty {
                Text(verbatim: draft.notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if isShown {
                    Label("ai.turn.shown", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Button("ai.turn.show") { model.show(turn) }
                        .controlSize(.small)
                }
                Spacer(minLength: 4)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(isShown ? Color.accentColor.opacity(0.35) : .white.opacity(0.14))
        )
    }

    /// The two tiers `DiagramFailureView` established: what happened and the one thing to do about
    /// it, with the machine's own words folded away.
    private func failureCard(_ presentation: AIFailurePresentation, on turn: AITurn) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(verbatim: presentation.headline)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = presentation.hint {
                Text(verbatim: hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presentation.remedy == .repairDiagram {
                Text(verbatim: Self.repairExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let title = presentation.remedy.titleKey {
                Button(LocalizedStringKey(title)) { perform(presentation, on: turn) }
                    .controlSize(.small)
            }
            if let details = presentation.details {
                DisclosureGroup {
                    Text(verbatim: details)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("preview.failure.details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.orange.opacity(0.28)))
    }

    private func perform(_ presentation: AIFailurePresentation, on turn: AITurn) {
        switch presentation.remedy {
        case .addKey: APIKeyCoordinator.shared.show()
        // The instruction this failure answered, not whichever was typed last: a card that says
        // "ask again" has one thing it can mean, and asking again for something else -- while
        // silently emptying a composer the reader was still reading -- is not it.
        case .retry: model.retry(after: turn.id)
        // The newest answer: this failure is the one raised by an answer that never drew.
        case .repairDiagram: composeRepair(reason: presentation.hint ?? "", mermaid: model.session.latestDraft?.mermaid)
        case .none: break
        }
    }

    /// Names the button that actually sends, rather than spelling it out a second time in the
    /// catalogue where the two could drift apart in one language and not the other.
    private static var repairExplanation: String {
        String(format: String(localized: "ai.repair.explain"), String(localized: "ai.generate"))
    }

    private func composeRepair(reason: String, mermaid: String?) {
        model.composeRepair(reason: reason, mermaid: mermaid)
        composerFocused = true
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Only where rewriting the diagram is what would help. A dead WebContent process, a
            // timeout or a missing engine are all failures of the drawing rather than of the
            // drawing's text, and offering to spend a request rewriting a correct diagram is worse
            // than saying nothing.
            if case .failed(let presentation) = preview.status, presentation.recovery == .fixSource {
                renderRepairRow(presentation)
            }
            TextField("ai.prompt.placeholder", text: $model.instruction, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(2...6)
                .focused($composerFocused)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.16)))
            HStack(spacing: 10) {
                Picker("ai.provider", selection: $model.provider) {
                    ForEach(AIProviderKind.allCases, id: \.self) { kind in
                        Text(verbatim: kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if !model.session.hasKey {
                    Button("ai.failure.add-key") { APIKeyCoordinator.shared.show() }
                        .controlSize(.small)
                }
                Spacer(minLength: 6)
                Button("ai.generate") { model.send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.session.canSend(model.instruction))
            }
        }
    }

    /// A diagram that came back and then would not draw. The offer is a button that writes the
    /// request into the composer, never a request already on its way.
    private func renderRepairRow(_ presentation: MermaidFailurePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: presentation.plainSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                // The diagram on the stage: this is the failure of the one that is being looked at.
                Button("ai.failure.repair") {
                    composeRepair(reason: presentation.plainSummary, mermaid: model.session.shownDraft?.mermaid)
                }
                .controlSize(.small)
                .disabled(model.session.shownDraft == nil)
                Text(verbatim: Self.repairExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.orange.opacity(0.28)))
    }
}
