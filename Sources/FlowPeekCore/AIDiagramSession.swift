import Foundation

/// One entry in the conversation the AI window shows.
///
/// The window used to keep the exchange in a `[AIMessage]` it never drew, so a follow-up
/// instruction — the whole point of the feature — was sent against a history the reader could not
/// see. A turn is what the reader sees: their own words, an answer kept whole so it can be put back
/// on the stage, or a failure already said in words they can act on.
public struct AITurn: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case instruction(String)
        case answer(AIDiagramDraft)
        case failure(AIFailurePresentation)
    }

    public let id: UUID
    public let content: Content

    public init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    public var draft: AIDiagramDraft? {
        guard case .answer(let draft) = content else { return nil }
        return draft
    }

    public var instruction: String? {
        guard case .instruction(let text) = content else { return nil }
        return text
    }

}

/// Which of the three things the window's stage has to show.
public enum AIPromptPane: Equatable, Sendable {
    /// No key for the chosen provider, and nothing has been drawn yet: the window has an offer to
    /// make, not an error to report.
    case missingKey
    /// A key is in place and nothing has come back yet.
    case introduction
    /// A drawn answer, on the same stage every other FlowPeek preview uses.
    case diagram
}

/// Everything the AI window knows that does not need AppKit to decide: what has been said, what is
/// on the stage, what may be sent, and what may leave the window.
public struct AIDiagramSession: Equatable, Sendable {
    /// The selection the window was opened on. Never edited — it is the user's own text, and the
    /// window shows it so nobody has to guess what the model is being told.
    public let context: String
    public private(set) var turns: [AITurn] = []
    public private(set) var isSending = false
    /// The answer the stage is drawing. Follows the newest drawable answer, unless the reader picks
    /// an earlier one out of the conversation.
    public private(set) var shownTurn: AITurn.ID?
    /// Whether the chosen provider has a key. Owned by the window, which reads the Keychain.
    public var hasKey: Bool

    public init(context: String, hasKey: Bool) {
        self.context = context
        self.hasKey = hasKey
    }

    // MARK: - What to show

    public var pane: AIPromptPane {
        if shownDraft != nil { return .diagram }
        return hasKey ? .introduction : .missingKey
    }

    public var shownDraft: AIDiagramDraft? {
        guard let shownTurn else { return nil }
        return turns.first { $0.id == shownTurn }?.draft
    }

    /// The newest answer, drawable or not. A draft that failed to draw is still the only text a
    /// repair can be asked about, and still text the reader can take away.
    public var latestDraft: AIDiagramDraft? {
        turns.reversed().compactMap(\.draft).first
    }

    /// The diagram text a copy would put on the clipboard. Deliberately not the same question as
    /// whether an image can be exported: an answer that never drew has no picture and still has
    /// text worth keeping.
    public var copyableMermaid: String? {
        guard let text = latestDraft?.mermaid,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// What an image export or a promoted window would be made from. Only what is on the stage: a
    /// picture can only be taken of something that was drawn.
    public var exportableDraft: AIDiagramDraft? {
        guard let draft = shownDraft,
              !draft.mermaid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return draft
    }

    // MARK: - Sending

    /// Blank instructions, a request already in flight and a provider with no key are all reasons
    /// the button cannot do anything, and all three are decided here rather than in a view.
    public func canSend(_ instruction: String) -> Bool {
        guard hasKey, !isSending else { return false }
        return !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Records the instruction and hands back what the provider is to be asked. The instruction
    /// travels in the request; `providerHistory` carries only instructions that were answered, so
    /// it cannot also arrive as history and ask for the same thing twice.
    public mutating func beginSending(instruction: String) -> AIDiagramRequest {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = AIDiagramRequest(context: context, instruction: text, conversation: providerHistory)
        turns.append(AITurn(content: .instruction(text)))
        isSending = true
        return request
    }

    /// An answer. `drawable` is false for one the diagram engine was never given — a draft that
    /// failed validation is remembered so it can be read, copied and repaired, but it must not take
    /// the stage away from the last diagram that did draw.
    public mutating func receive(_ draft: AIDiagramDraft, drawable: Bool = true) {
        let turn = AITurn(content: .answer(draft))
        turns.append(turn)
        if drawable { shownTurn = turn.id }
        isSending = false
    }

    public mutating func fail(_ presentation: AIFailurePresentation) {
        turns.append(AITurn(content: .failure(presentation)))
        isSending = false
    }

    /// The reader picking an earlier answer out of the conversation. Anything that is not a drawable
    /// answer is ignored: an instruction and a failure have no diagram to put on the stage.
    public mutating func show(_ id: AITurn.ID) {
        guard turns.first(where: { $0.id == id })?.draft != nil else { return }
        shownTurn = id
    }

    // MARK: - What the provider is told

    /// The exchange as the provider sees it: only the instructions that were actually answered.
    ///
    /// An instruction whose request failed is dropped on purpose. A rejected key or a dead network
    /// means the model never saw it, and leaving it in the history would send it again alongside
    /// whatever the user types next.
    public var providerHistory: [AIMessage] {
        var messages: [AIMessage] = []
        var asked: String?
        for turn in turns {
            switch turn.content {
            case .instruction(let text):
                // Held rather than emitted: an instruction is only history once something answered
                // it. One that failed, and the one being sent right now, are both still waiting.
                asked = text
            case .answer(let draft):
                if let asked { messages.append(AIMessage(role: .user, text: asked)) }
                messages.append(AIMessage(role: .assistant, text: draft.notes))
                asked = nil
            case .failure:
                // A failure ends the request, so nothing after it can be that instruction's answer.
                asked = nil
            }
        }
        return messages
    }
}

/// The instruction a repair is asked with.
///
/// It is built here and put in the composer rather than sent: the window used to overwrite whatever
/// the user had typed with a repair prompt and post it on their behalf, so the one thing they never
/// saw was what had been asked in their name. `preamble` is passed in so the sentence is the
/// window's translated one and this stays testable without a bundle.
public enum AIRepairRequest {
    public static func instruction(preamble: String, reason: String, mermaid: String) -> String {
        [preamble, reason, mermaid]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

/// Why a request produced no diagram, in the shape `MermaidFailurePresentation` established: a
/// headline, one thing to do about it, and the machine's own words kept out of the body copy.
public struct AIFailurePresentation: Equatable, Sendable {
    /// The one button worth offering next to the sentence.
    public enum Remedy: String, CaseIterable, Equatable, Sendable {
        case addKey
        case retry
        case repairDiagram
        case none

        public var titleKey: String? {
            switch self {
            case .addKey: "ai.failure.add-key"
            case .retry: "ai.failure.retry"
            case .repairDiagram: "ai.failure.repair"
            case .none: nil
            }
        }
    }

    public let headline: String
    public let hint: String?
    /// Never body copy: it is untranslated and comes from a network stack or a parser.
    public let details: String?
    public let remedy: Remedy

    public init(headline: String, hint: String? = nil, details: String? = nil, remedy: Remedy) {
        self.headline = headline
        self.hint = hint
        self.details = details
        self.remedy = remedy
    }

    public static func make(_ cause: AIFailureCause) -> AIFailurePresentation {
        switch cause {
        case .missingKey:
            .init(headline: localized("ai.failure.missing-key.headline"),
                  hint: localized("ai.failure.missing-key.hint"),
                  remedy: .addKey)
        case .unauthorized:
            .init(headline: localized("ai.failure.unauthorized.headline"),
                  hint: localized("ai.failure.unauthorized.hint"),
                  remedy: .addKey)
        case .server(let status):
            // The provider's own body is not carried: on a rejected key some of them quote the key
            // back in it, which is the one thing that must never reach a window or a screenshot.
            .init(headline: localized("ai.failure.server.headline"),
                  hint: String(format: localized("ai.failure.server.hint"), status),
                  remedy: .retry)
        case .invalidResponse:
            .init(headline: localized("ai.failure.invalid-response.headline"),
                  hint: localized("ai.failure.invalid-response.hint"),
                  remedy: .retry)
        case .transport(let detail):
            .init(headline: localized("ai.failure.transport.headline"),
                  hint: localized("ai.failure.transport.hint"),
                  details: detail,
                  remedy: .retry)
        case .unusableDiagram(let reason):
            // `reason` is already the sentence the rest of the app uses for that validation
            // failure, so it is the hint rather than something folded away.
            .init(headline: localized("ai.failure.unusable.headline"),
                  hint: reason,
                  remedy: .repairDiagram)
        }
    }

    private static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    /// Walked by the localisation test, so a new cause cannot arrive without copy in both
    /// catalogues.
    public static let localizationKeys: [String] = [
        "ai.failure.missing-key.headline", "ai.failure.missing-key.hint",
        "ai.failure.unauthorized.headline", "ai.failure.unauthorized.hint",
        "ai.failure.server.headline", "ai.failure.server.hint",
        "ai.failure.invalid-response.headline", "ai.failure.invalid-response.hint",
        "ai.failure.transport.headline", "ai.failure.transport.hint",
        "ai.failure.unusable.headline",
    ] + Remedy.allCases.compactMap(\.titleKey)
}

/// What went wrong, told apart far enough to decide what to offer next. The window maps its
/// provider and network errors onto these; the copy and the remedy are decided here.
public enum AIFailureCause: Equatable, Sendable {
    case missingKey
    case unauthorized
    case server(status: Int)
    case invalidResponse
    case transport(String)
    /// The answer came back and is not a diagram FlowPeek can draw. `reason` is already localized.
    case unusableDiagram(String)
}
