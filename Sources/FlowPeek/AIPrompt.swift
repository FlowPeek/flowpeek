import AppKit
import FlowPeekCore
import SwiftUI

extension Notification.Name {
    /// Raised when a key is written to the Keychain. A window standing there offering to take one
    /// has no other way to learn that it arrived: the key sheet belongs to this same application, so
    /// no activation changes and nothing else republishes.
    static let flowPeekAPIKeysChanged = Notification.Name("flowpeek.ai.keys-changed")
}

/// The one place a diagram made in this window enters the app's diagram history.
///
/// `DiagramHistoryStore` is owned elsewhere and is not in this worktree; a closure is the join, so
/// this window can be finished, tested and read without it. Whoever brings the store in replaces
/// the default with `DiagramHistoryStore.shared.record(title:source:origin:)` and deletes nothing
/// else — there is exactly one caller, `AIPromptModel.recordInHistory`.
@MainActor
enum AIDiagramHistoryBridge {
    /// Called with the title as the reader sees it and the Mermaid as it now stands, edits and all.
    static var record: (_ title: String, _ source: MermaidSource, _ origin: String) -> Void = { _, _, _ in }
    /// Which of the app's routes produced the diagram.
    static let origin = "ai"
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

/// Which half of the diagram the stage is showing: the drawing, or the text it was drawn from.
enum AIStageMode: String, CaseIterable, Identifiable {
    case diagram
    case source

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .diagram: "ai.stage.diagram"
        case .source: "ai.stage.source"
        }
    }
}

@MainActor
final class AIPromptModel: ObservableObject {
    /// The same view model, pooled engine and typed failure card the rest of the app previews
    /// with, so a diagram made here behaves exactly as one opened from a selection.
    let preview = DiagramViewModel(title: "")

    @Published private(set) var session: AIDiagramSession
    @Published var instruction = ""
    @Published var stage: AIStageMode = .diagram
    /// The Mermaid as it is being typed. Held here rather than in the view so it survives a rebuild
    /// of the pane and can be put back in step whenever the stage changes underneath it.
    @Published var sourceDraft = ""
    /// Which answer the buffer above belongs to. Named rather than worked out from the stage: the
    /// answer being repaired is very often the one that never reached the stage, and an editor that
    /// guessed would write a refused answer's text over the diagram somebody was looking at.
    @Published private(set) var editingTurn: AITurn.ID?
    /// Why the last apply was refused, in the reader's own language. Cleared by the next keystroke:
    /// a warning about text that is no longer on screen is just noise.
    @Published private(set) var sourceRejection: String?
    /// The last thing worth saying out loud, and a counter so the same sentence twice running is
    /// still two announcements. Nothing else reads it.
    @Published private(set) var announcement: (text: String, count: Int)?
    @Published var provider: AIProviderKind {
        didSet {
            guard provider != oldValue else { return }
            // The window and the Settings pane are two views of one choice; leaving them to
            // disagree is how a key gets pasted for a provider the next request will not use.
            AppState.shared.providerRawValue = provider.rawValue
            refreshKey()
        }
    }

    /// The walk back through what has already been asked. Kept beside the session rather than in it:
    /// where the reader is in their own history is a property of this composer, not of the exchange.
    private var recall = AIInstructionRecall()
    /// What the walk last put in the box, so a keystroke can be told apart from the walk's own
    /// writing and end it.
    private var recalledText: String?
    private var announcementCount = 0

    private var request: Task<Void, Never>?

    init(context: String) {
        let kind = AIProviderKind(rawValue: AppState.shared.providerRawValue) ?? .openAI
        provider = kind
        session = AIDiagramSession(context: context, hasKey: KeychainStore().read(account: kind.rawValue) != nil)
    }

    func release() {
        request?.cancel()
        request = nil
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
            announceLatest()
            return
        }
        let payload = session.beginSending(instruction: asked)
        // Only when the composer is what was sent. A retry replays an earlier turn, and clearing
        // here threw away a repair the reader had asked for and not yet read.
        if asked == instruction.trimmingCharacters(in: .whitespacesAndNewlines) { instruction = "" }
        recall.update(history: session.instructionHistory)
        announceLatest()
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
                drawShownDiagram()
                recordInHistory()
            case .failure(let error):
                receive(error)
            }
            announceLatest()
        }
    }

    /// The reader stopping a request they no longer want the answer to.
    ///
    /// A request runs for up to 90 seconds and there was no way out of it but closing the window
    /// and losing the conversation. Cancelling the task is only half of it: the conversation has to
    /// say the instruction above was never answered, or the window is left showing a question with
    /// nothing under it.
    func stop() {
        guard session.isSending else { return }
        request?.cancel()
        request = nil
        session.cancelSending()
        announceLatest()
    }

    /// The reader asking for the same thing again after a failure. Their own words, sent again as a
    /// visible turn rather than replayed silently -- and the words that earned *this* failure, which
    /// is not the same as the last thing typed once a second exchange has happened since.
    func retry(after failure: AITurn.ID) {
        guard let instruction = session.instruction(before: failure) else { return }
        send(instruction)
    }

    /// An earlier instruction put back in the composer to be adjusted and sent again. Never sent
    /// from here: what goes out in the user's name is always something they pressed the button on.
    func reuse(_ text: String) {
        instruction = text
        recall.reset()
        recalledText = nil
    }

    private func receive(_ error: any Error) {
        if case AIProviderError.unusableDiagram(let draft, let reason) = error {
            // Recorded even though it cannot be drawn: it is the only text a repair can be asked
            // about, and the only thing the reader can copy out of a request that went wrong. It is
            // also now something the reader can simply fix — see `applySourceEdit`.
            session.receive(draft, drawable: false)
            // The refused answer is what the editor opens on: it is the one that needs fixing, and
            // it is the one thing on this screen the reader can put right without another request.
            loadSourceDraft(from: session.turns.last?.id)
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

    // MARK: - Context

    /// The reader dropping the selection the window opened on. The composer keeps working; only the
    /// text that would have travelled with the next request goes away.
    func dropContext() {
        session.dropContext()
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
        recall.reset()
        recalledText = nil
    }

    // MARK: - Editing the diagram text

    /// True while the buffer says something the answer it belongs to does not.
    var sourceIsDirty: Bool {
        guard let editingTurn else { return false }
        return sourceDraft != (session.draft(for: editingTurn)?.mermaid ?? "")
    }

    /// Whether the answer in the editor carries a correction of the reader's own.
    var isEditingAnEditedAnswer: Bool {
        editingTurn.map { session.isEdited($0) } ?? false
    }

    /// The reader choosing an answer to work on: the one on the stage, or the one that never got
    /// there. Drawable answers are put on the stage first, so what is drawn and what is in the
    /// editor are the same diagram.
    func edit(_ id: AITurn.ID) {
        if session.turns.first(where: { $0.id == id })?.drawnDraft != nil {
            session.show(id)
            preview.title = session.shownDraft?.title ?? ""
            preview.update(source: session.shownDraft?.mermaid ?? "")
        }
        loadSourceDraft(from: id)
    }

    func noteSourceTyping() {
        sourceRejection = nil
    }

    /// The reader's own correction, drawn. Nothing here asks a model anything: one wrong arrow is a
    /// text edit, and having to spend a request — and a round of "no, like this" — on a typo is the
    /// single most tiring thing about working in this window.
    func applySourceEdit() {
        guard let id = editingTurn else { return }
        switch session.edit(sourceDraft, of: id) {
        case .unchanged:
            sourceRejection = nil
        case .applied:
            sourceRejection = nil
            // The edit put its answer on the stage, so the drawing comes first and the buffer is
            // reloaded from what the session actually kept: the normalised text, which is what
            // makes the Apply button go quiet again.
            drawShownDiagram()
            recordInHistory()
            announce(String(localized: "ai.source.applied"))
        case .rejected(let error):
            let reason = localizedUserMessage(error)
            sourceRejection = reason
            announce(reason)
        }
    }

    /// Back to what the model said, for a fix that made things worse.
    func revertSourceEdit() {
        guard let id = editingTurn, session.isEdited(id) else { return }
        session.revertEdit(of: id)
        drawShownDiagram()
        loadSourceDraft(from: id)
        announce(String(localized: "ai.source.reverted"))
    }

    /// The buffer, and the answer it belongs to, put back in step. Called wherever the diagram
    /// changes under it — a new answer, an earlier one brought back, an edit applied or reverted —
    /// because a box still holding the previous diagram's text is a box that will write that
    /// diagram over this one on the next apply.
    private func loadSourceDraft(from id: AITurn.ID?) {
        editingTurn = id
        sourceDraft = id.flatMap { session.draft(for: $0)?.mermaid } ?? ""
        sourceRejection = nil
    }

    // MARK: - Taking it away

    func show(_ turn: AITurn) {
        session.show(turn.id)
        drawShownDiagram()
    }

    private func drawShownDiagram() {
        guard let draft = session.shownDraft else { return }
        preview.title = draft.title
        preview.update(source: draft.mermaid)
        loadSourceDraft(from: session.shownTurn)
    }

    /// Every diagram this window produces passes through here on its way to the app's history: an
    /// answer that drew, and the reader's own edit of one. Validated first, because the history is
    /// a list of diagrams that can be opened again and a draft that will not parse is not one.
    private func recordInHistory() {
        guard let draft = session.exportableDraft,
              let source = try? MermaidSource(rawValue: draft.mermaid) else { return }
        let title = draft.title.isEmpty ? String(localized: "diagram.default-title") : draft.title
        AIDiagramHistoryBridge.record(title, source, AIDiagramHistoryBridge.origin)
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

    // MARK: - Saying what changed

    /// Whether the box is currently showing something out of the history rather than something
    /// typed. Down only means anything during a walk.
    var isRecalling: Bool { recall.isWalking }

    /// Walking back and forth through what has already been asked. Returns whether the box was
    /// changed, so an Up that has nowhere to go can be handed back to the text view and move the
    /// caret the way it does everywhere else on this Mac.
    func recallOlder() -> Bool {
        if !recall.isWalking { recall.update(history: session.instructionHistory) }
        guard let text = recall.older(current: instruction) else { return false }
        instruction = text
        recalledText = text
        return true
    }

    func recallNewer() -> Bool {
        guard let text = recall.newer() else { return false }
        instruction = text
        recalledText = recall.isWalking ? text : nil
        return true
    }

    /// Typing ends the walk. Without this the box would keep counting from wherever the reader had
    /// wandered to, and Down would throw away what they had just written on top of it.
    func noteInstruction(_ text: String) {
        guard recall.isWalking, text != recalledText else { return }
        recall.reset()
        recalledText = nil
    }

    /// The panes change under a reader who cannot see them changing: an answer arrives on the right
    /// and a diagram is redrawn on the left, with no focus moving and nothing said. VoiceOver is
    /// told in words instead.
    private func announceLatest() {
        guard let latest = session.latestAnnouncement else { return }
        switch latest {
        case .sent:
            announce(String(format: String(localized: "ai.a11y.sent"), provider.displayName))
        case .answered(let title):
            let named = title.isEmpty ? String(localized: "diagram.default-title") : title
            announce(String(format: String(localized: "ai.a11y.answered"), named))
        case .undrawable:
            announce(String(localized: "ai.a11y.undrawable"))
        case .failed(let headline):
            announce(headline)
        case .cancelled:
            announce(String(localized: "ai.a11y.stopped"))
        }
    }

    private func announce(_ text: String) {
        announcementCount += 1
        announcement = (text: text, count: announcementCount)
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

    /// Named rather than a bare Bool: the window has to be workable from the keyboard alone, and
    /// that means every place focus can be is something a shortcut can send it to.
    private enum Field: Hashable { case composer, source }
    @FocusState private var focus: Field?
    @State private var showsContext = false

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
            showsContext = model.session.hasContext
            focus = .composer
        }
        // Spoken, not drawn. Every one of these is a change the reader can see for themselves; this
        // is the same information for the reader who cannot.
        .onChange(of: model.announcement?.count) { _, _ in
            guard let text = model.announcement?.text else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        // The other pane that changes on its own. The conversation says an answer arrived; this
        // says what was drawn, in the drawing's own words, at the moment there is finally something
        // to describe — a second or so later, once the engine has finished with it.
        .onChange(of: preview.narration) { _, reading in
            guard let reading, model.session.shownDraft != nil else { return }
            AccessibilityNotification.Announcement(drawnDescription(reading)).post()
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
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
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
            // Only once there is something to switch between: an empty stage has no text behind it,
            // and a control offering to show it is a control that does nothing.
            if model.session.latestDraft != nil { stagePicker }
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

    /// The drawing or the text it came from. A segmented control rather than a glyph: it is the one
    /// piece of chrome here that changes what the whole left half of the window is, and it carries
    /// its own name in the reader's language.
    private var stagePicker: some View {
        Picker("ai.stage", selection: $model.stage) {
            ForEach(AIStageMode.allCases) { mode in
                Text(mode.titleKey).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("ai.stage"))
        .help(Text("ai.stage"))
    }

    /// Only ever the diagram that is on the stage: naming an answer that never drew would put its
    /// title over a diagram somebody else asked for.
    private var title: String {
        guard let drawn = model.session.shownDraft?.title, !drawn.isEmpty else {
            return String(localized: "ai.window.title")
        }
        return drawn
    }

    /// The drawing as words, in the shape `DiagramStage` already announces it: what kind of diagram
    /// it is and what it is called, then its own labels. `DiagramNarration` reads those out of the
    /// rendered markup, so this describes what mermaid actually drew rather than what was asked for.
    private func drawnDescription(_ reading: DiagramNarration.Reading) -> String {
        let title = model.session.shownDraft?.title ?? ""
        let name = title.isEmpty ? String(localized: "diagram.default-title") : title
        let heading = reading.kind.map {
            String(format: String(localized: "preview.a11y.diagram.typed"), $0, name)
        } ?? String(format: String(localized: "preview.a11y.diagram"), name)
        return heading + ". " + (reading.spoken ?? String(localized: "preview.a11y.diagram.wordless"))
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
            switch model.stage {
            case .source: sourceEditor
            case .diagram:
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
                .accessibilityAddTraits(.isHeader)
            // Two sentences, because the window now opens both ways and the difference is the whole
            // point: with a selection it says the text is ready, with none it says none is needed.
            Text(model.session.hasContext ? "ai.empty.description" : "ai.empty.description.blank")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Text("ai.suggestions.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(suggestions, id: \.self) { key in
                    Button {
                        model.reuse(String(localized: String.LocalizationValue(key)))
                        focus = .composer
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
    /// Two sets, because "turn this into a flowchart" is not a sentence that means anything in a
    /// window that was opened on nothing.
    private var suggestions: [String] {
        model.session.hasContext
            ? ["ai.suggestion.flowchart", "ai.suggestion.sequence", "ai.suggestion.state"]
            : ["ai.suggestion.blank.sequence", "ai.suggestion.blank.flowchart", "ai.suggestion.blank.state"]
    }

    /// A missing key is an offer, not an error: it says what is needed, where it is kept, and opens
    /// the place it is kept in.
    private var keyOffer: some View {
        VStack(spacing: 16) {
            haloIcon("key.fill")
            Text(verbatim: String(format: String(localized: "ai.key.title"), model.provider.displayName))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
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
        .accessibilityHidden(true)
    }

    // MARK: - The diagram as text

    /// The Mermaid itself, editable.
    ///
    /// The window used to hand back a title and a paragraph of notes, and the diagram's own text
    /// could be copied but never read or corrected here. One wrong label then cost a whole request
    /// and a round of explaining what was wrong, when it costs three keystrokes in a text field.
    /// This is also the only form of the diagram a screen reader can read line by line.
    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("ai.stage.source")
                    .font(.caption.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if model.isEditingAnEditedAnswer {
                    Label("ai.source.edited", systemImage: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("preview.export.copy-text") { preview.copySource() }
                    .controlSize(.small)
                    .disabled(model.session.copyableMermaid == nil)
            }
            if model.editingTurn == nil {
                Text("ai.source.none")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                TextEditor(text: $model.sourceDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .source)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.16)))
                    .onChange(of: model.sourceDraft) { _, _ in model.noteSourceTyping() }
                    .accessibilityLabel(Text("ai.source.a11y"))
                    .accessibilityHint(Text("ai.source.a11y.hint"))
                if let rejection = model.sourceRejection {
                    Label {
                        Text(verbatim: rejection)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
                HStack(spacing: 8) {
                    Button("ai.source.apply") { model.applySourceEdit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        // ⌘⇧↩ rather than ⌘↩: the composer's Generate owns that one, and both are
                        // live at once in a window where either box can hold the focus.
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .disabled(!model.sourceIsDirty)
                    if model.isEditingAnEditedAnswer {
                        Button("ai.source.revert") { model.revertSourceEdit() }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 6)
                    Text("ai.source.explain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
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
    /// With nothing selected it says so — that is an ordinary state of this window now, and a card
    /// that quietly disappeared would leave the reader guessing what was being sent.
    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: model.session.hasContext ? "text.quote" : "text.badge.xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.session.hasContext ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(model.session.hasContext ? "ai.context" : "ai.context.none")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                if model.session.hasContext {
                    Text(verbatim: String(format: String(localized: "ai.context.length"), model.session.context.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showsContext.toggle() }
                    } label: {
                        Image(systemName: showsContext ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(showsContext ? "ai.context.hide" : "ai.context.show"))
                    Button("ai.context.drop") { model.dropContext() }
                        .controlSize(.small)
                }
            }
            if model.session.hasContext {
                if showsContext {
                    ScrollView {
                        Text(verbatim: model.session.context)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .frame(height: 62)
                    .accessibilityLabel(Text("ai.context"))
                }
            } else {
                Text("ai.context.none.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            // Named and grouped, so the whole exchange is one thing a reader can step into and walk
            // rather than a run of unlabelled cards between the context and the box.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("ai.a11y.conversation"))
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
            Spacer(minLength: 6)
            // Beside the spinner as well as in the composer: this is where the reader is looking
            // while they wait, and a 90-second request with no way out but closing the window took
            // the whole conversation with it.
            Button("ai.stop") { model.stop() }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func turnCard(_ turn: AITurn) -> some View {
        switch turn.content {
        case .instruction(let text):
            instructionCard(text)
        case .answer(let draft, let drawable):
            answerCard(turn: turn, draft: draft, drawable: drawable)
        case .failure(let presentation):
            failureCard(presentation, on: turn)
        case .cancelled:
            cancelledCard(on: turn)
        }
    }

    private func instructionCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label("ai.turn.you", systemImage: "person.crop.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                // What was asked, back in the box to be adjusted. The alternative was reading it
                // off the card and retyping it, which for a repair prompt is a page of Mermaid.
                Button("ai.turn.reuse") { reuse(text) }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
            Text(verbatim: text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.accentColor.opacity(0.18)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: String(format: String(localized: "ai.a11y.turn.you"), text)))
    }

    private func answerCard(turn: AITurn, draft: AIDiagramDraft, drawable: Bool) -> some View {
        let isShown = model.session.shownTurn == turn.id
        let name = draft.title.isEmpty ? String(localized: "diagram.default-title") : draft.title
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if model.session.isEdited(turn.id) {
                    Label("ai.source.edited", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("ai.source.edited"))
                }
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
                } else if drawable {
                    Button("ai.turn.show") { model.show(turn) }
                        .controlSize(.small)
                } else {
                    // The one answer with no way onto the stage. Rather than a dead card, it points
                    // at the pane where it can be repaired by hand.
                    Button("ai.turn.fix") { editSource(of: turn) }
                        .controlSize(.small)
                }
                Spacer(minLength: 4)
                if isShown || drawable {
                    Button("ai.turn.edit") { editSource(of: turn) }
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(isShown ? Color.accentColor.opacity(0.35) : .white.opacity(0.14))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: answerLabel(name: name, notes: draft.notes, drawable: drawable)))
        // The stage has exactly one answer on it, and which one is otherwise a green tick a reader
        // cannot see.
        .accessibilityAddTraits(isShown ? [.isSelected] : [])
    }

    private func answerLabel(name: String, notes: String, drawable: Bool) -> String {
        let key = drawable ? "ai.a11y.turn.answer" : "ai.a11y.turn.answer.undrawable"
        return String(format: String(localized: String.LocalizationValue(key)), name, notes)
    }

    /// The reader stopped this one. No remedy button of its own beyond asking again: nothing went
    /// wrong, and the card exists so the instruction above it is not left hanging.
    private func cancelledCard(on turn: AITurn) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "stop.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("ai.turn.cancelled")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("ai.failure.retry") { model.retry(after: turn.id) }
                .controlSize(.small)
                .disabled(model.session.isSending)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("ai.turn.cancelled"))
    }

    /// The two tiers `DiagramFailureView` established: what happened and the one thing to do about
    /// it, with the machine's own words folded away.
    private func failureCard(_ presentation: AIFailurePresentation, on turn: AITurn) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
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
            HStack(spacing: 8) {
                if let title = presentation.remedy.titleKey {
                    Button(LocalizedStringKey(title)) { perform(presentation, on: turn) }
                        .controlSize(.small)
                }
                // A repair does not have to be a request. The answer is already here, its text is
                // already in the editor, and very often the fix is one character.
                if presentation.remedy == .repairDiagram, model.editingTurn != nil {
                    Button("ai.turn.fix") { openSourceEditor() }
                        .controlSize(.small)
                }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: String(
            format: String(localized: "ai.a11y.turn.failure"),
            presentation.headline,
            presentation.hint ?? ""
        )))
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
        focus = .composer
    }

    private func reuse(_ text: String) {
        model.reuse(text)
        focus = .composer
    }

    /// One place decides what "fix this by hand" does: bring the answer to the stage where that is
    /// possible, show the text, and put the caret in it.
    private func editSource(of turn: AITurn) {
        model.edit(turn.id)
        openSourceEditor()
    }

    private func openSourceEditor() {
        model.stage = .source
        focus = .source
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
                .focused($focus, equals: .composer)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.16)))
                .accessibilityLabel(Text("ai.prompt.placeholder"))
                .accessibilityHint(Text("ai.composer.a11y.hint"))
                // A shell's history, in the one box in this window that has one. Only from an empty
                // box, and only while there is something to recall: everywhere else Up is the caret
                // key it is in every other text field on this Mac, so it is handed straight back.
                .onKeyPress(.upArrow) {
                    guard model.instruction.isEmpty || model.isRecalling else { return .ignored }
                    return model.recallOlder() ? .handled : .ignored
                }
                .onKeyPress(.downArrow) {
                    guard model.isRecalling else { return .ignored }
                    return model.recallNewer() ? .handled : .ignored
                }
                .onChange(of: model.instruction) { _, text in model.noteInstruction(text) }
            // What the next request will be understood against, in one line. This is the window's
            // own memory and nothing else says how much of it there is.
            Text(verbatim: memoryLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker("ai.provider", selection: $model.provider) {
                    ForEach(AIProviderKind.allCases, id: \.self) { kind in
                        Text(verbatim: kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(Text("ai.provider"))
                if !model.session.hasKey {
                    Button("ai.failure.add-key") { APIKeyCoordinator.shared.show() }
                        .controlSize(.small)
                }
                Spacer(minLength: 6)
                if model.session.isSending {
                    // In the button's own place, not beside it: while a request is running there is
                    // exactly one thing to do here, and Escape already belongs to the window.
                    Button("ai.stop") { model.stop() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("ai.generate") { model.send() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.session.canSend(model.instruction))
                }
            }
        }
    }

    /// Two facts in one sentence: how many earlier exchanges travel with the next request, and
    /// whether the selection does.
    private var memoryLine: String {
        let exchanges = model.session.rememberedExchanges
        let memory = exchanges == 0
            ? String(localized: "ai.composer.memory.none")
            : String(format: String(localized: "ai.composer.memory"), exchanges)
        let context = model.session.hasContext
            ? String(localized: "ai.composer.context.on")
            : String(localized: "ai.composer.context.off")
        return memory + " " + context
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
                Button("ai.turn.fix") { openSourceEditor() }
                    .controlSize(.small)
                    .disabled(model.editingTurn == nil)
                Spacer(minLength: 4)
            }
            Text(verbatim: Self.repairExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.orange.opacity(0.28)))
    }
}
