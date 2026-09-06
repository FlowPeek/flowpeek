import XCTest
@testable import FlowPeekCore

final class AIDiagramSessionTests: XCTestCase {
    private func draft(_ name: String, mermaid: String = "flowchart TD\n  A --> B") -> AIDiagramDraft {
        AIDiagramDraft(title: name, mermaid: mermaid, notes: "notes for \(name)")
    }

    private func session(hasKey: Bool = true) -> AIDiagramSession {
        AIDiagramSession(context: "the selected text", hasKey: hasKey)
    }

    // MARK: - The conversation

    /// The reader has to be able to see what they asked and what came back, in the order it
    /// happened: a follow-up instruction means nothing next to a list that only keeps the answers.
    func testTheConversationKeepsBothSidesInTheOrderTheyHappened() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.receive(draft("Login"))
        _ = subject.beginSending(instruction: "add the failure branch")
        subject.receive(draft("Login v2"))

        XCTAssertEqual(subject.turns.count, 4)
        XCTAssertEqual(subject.turns[0].content, .instruction("draw the login flow"))
        XCTAssertEqual(subject.turns[1].draft?.title, "Login")
        XCTAssertEqual(subject.turns[2].content, .instruction("add the failure branch"))
        XCTAssertEqual(subject.turns[3].draft?.title, "Login v2")
    }

    /// The instruction being sent is in the request, so it must not also be in the history that
    /// travels with it.
    func testTheHistorySentWithAnInstructionStopsAtThePreviousAnswer() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.receive(draft("Login"))

        let request = subject.beginSending(instruction: "add the failure branch")
        XCTAssertEqual(request.instruction, "add the failure branch")
        XCTAssertEqual(request.context, "the selected text")
        XCTAssertEqual(request.conversation, [
            AIMessage(role: .user, text: "draw the login flow"),
            AIMessage(role: .assistant, text: "notes for Login\n\n```mermaid\nflowchart TD\n  A --> B\n```"),
        ])
    }

    /// A request that failed never reached the model, so repeating the instruction in the history
    /// would ask for the same thing twice.
    func testAnInstructionThatFailedIsLeftOutOfTheHistory() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.fail(AIFailurePresentation.make(.transport("offline")))
        _ = subject.beginSending(instruction: "draw the login flow again")
        subject.receive(draft("Login"))

        XCTAssertEqual(subject.providerHistory, [
            AIMessage(role: .user, text: "draw the login flow again"),
            AIMessage(role: .assistant, text: "notes for Login\n\n```mermaid\nflowchart TD\n  A --> B\n```"),
        ])
    }

    func testAnInstructionIsTrimmedBeforeItIsRecordedOrSent() {
        var subject = session()
        let request = subject.beginSending(instruction: "  draw the login flow \n")
        XCTAssertEqual(request.instruction, "draw the login flow")
        XCTAssertEqual(subject.turns.first?.content, .instruction("draw the login flow"))
    }

    // MARK: - What the stage shows

    func testTheStageFollowsTheNewestAnswer() {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("second"))

        XCTAssertEqual(subject.shownDraft?.title, "second")
        XCTAssertEqual(subject.pane, .diagram)
        XCTAssertFalse(subject.isSending)
    }

    /// An answer the engine was never given must not take the stage away from the diagram that is
    /// on it, but it is still the newest thing said and is still kept so it can be read and
    /// repaired. What the chrome copies is the diagram on the stage, which is the one the reader is
    /// looking at -- offering the refused text there put two different diagrams in one menu.
    func testAnAnswerThatCannotBeDrawnIsRememberedWithoutTakingTheStage() {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("prose", mermaid: "I am afraid I cannot draw that"), drawable: false)

        XCTAssertEqual(subject.shownDraft?.title, "first")
        XCTAssertEqual(subject.latestDraft?.title, "prose", "the refused answer is still kept")
        XCTAssertEqual(subject.copyableMermaid, subject.shownDraft?.mermaid)
        XCTAssertEqual(subject.exportableDraft?.title, "first")
    }

    func testAnEarlierAnswerCanBePutBackOnTheStage() {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        let firstAnswer = subject.turns[1].id
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("second"))

        subject.show(firstAnswer)
        XCTAssertEqual(subject.shownDraft?.title, "first")
    }

    /// An instruction and a failure have no diagram behind them, so picking one must leave the
    /// stage exactly where it was.
    func testOnlyAnAnswerCanBePutOnTheStage() {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        subject.fail(AIFailurePresentation.make(.invalidResponse))

        subject.show(subject.turns[0].id)
        XCTAssertEqual(subject.shownDraft?.title, "first")
        subject.show(subject.turns[2].id)
        XCTAssertEqual(subject.shownDraft?.title, "first")
    }

    // MARK: - Panes

    /// A missing key is an offer to make, not an error to report, and it is the only thing the
    /// window can usefully say before anything has been drawn.
    func testTheWindowOffersAKeyWhenThereIsNoneAndNothingIsDrawn() {
        XCTAssertEqual(session(hasKey: false).pane, .missingKey)
        XCTAssertEqual(session(hasKey: true).pane, .introduction)
    }

    /// Deleting the key does not delete the diagram: the reader can still read, copy and export
    /// what is on the stage.
    func testADrawnDiagramOutlivesTheKeyThatProducedIt() {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        subject.hasKey = false

        XCTAssertEqual(subject.pane, .diagram)
        XCTAssertNotNil(subject.exportableDraft)
    }

    // MARK: - Sending rules

    func testNothingIsSentWithoutAKeyWithoutWordsOrWhileARequestIsInFlight() {
        XCTAssertFalse(session(hasKey: false).canSend("draw this"))
        XCTAssertFalse(session().canSend("   \n "))
        XCTAssertTrue(session().canSend("draw this"))

        var sending = session()
        _ = sending.beginSending(instruction: "draw this")
        XCTAssertTrue(sending.isSending)
        XCTAssertFalse(sending.canSend("and this"))
    }

    func testAnAnswerOrAFailureEndsTheRequest() {
        var answered = session()
        _ = answered.beginSending(instruction: "one")
        answered.receive(draft("first"))
        XCTAssertFalse(answered.isSending)

        var failed = session()
        _ = failed.beginSending(instruction: "one")
        failed.fail(AIFailurePresentation.make(.invalidResponse))
        XCTAssertFalse(failed.isSending)
    }

    // MARK: - Repair

    /// What is asked on the user's behalf has to be readable before it is sent, and it is only
    /// worth reading if it carries the reason and the source that failed.
    func testARepairAsksAboutTheReasonAndTheSourceThatFailed() {
        let instruction = AIRepairRequest.instruction(
            preamble: "Repair this diagram.",
            reason: "Mermaid could not parse line 3",
            mermaid: "flowchart TD\n  A -->"
        )
        XCTAssertEqual(instruction, """
        Repair this diagram.

        Mermaid could not parse line 3

        flowchart TD
          A -->
        """)
    }

    func testARepairWithNoReasonToGiveDoesNotLeaveAGapWhereItWouldHaveBeen() {
        let instruction = AIRepairRequest.instruction(preamble: "Repair this.", reason: "  ", mermaid: "flowchart TD")
        XCTAssertEqual(instruction, "Repair this.\n\nflowchart TD")
    }

    // MARK: - Failures

    /// Every failure has to leave the reader with something to press, and which button that is
    /// depends only on what went wrong.
    func testEachFailureOffersTheOneThingWorthDoingAboutIt() {
        XCTAssertEqual(AIFailurePresentation.make(.missingKey).remedy, .addKey)
        XCTAssertEqual(AIFailurePresentation.make(.unauthorized).remedy, .addKey)
        XCTAssertEqual(AIFailurePresentation.make(.server(status: 503)).remedy, .retry)
        XCTAssertEqual(AIFailurePresentation.make(.invalidResponse).remedy, .retry)
        XCTAssertEqual(AIFailurePresentation.make(.transport("offline")).remedy, .retry)
        XCTAssertEqual(AIFailurePresentation.make(.unusableDiagram("not a diagram")).remedy, .repairDiagram)
    }

    /// The provider's own body can quote the key back on a rejection, so a rejected request says
    /// what happened and carries nothing of what came with it.
    func testARejectedRequestCarriesNoneOfTheProvidersOwnWords() {
        XCTAssertNil(AIFailurePresentation.make(.server(status: 401)).details)
        XCTAssertNil(AIFailurePresentation.make(.unauthorized).details)
        XCTAssertEqual(AIFailurePresentation.make(.transport("The Internet connection appears to be offline.")).details,
                       "The Internet connection appears to be offline.")
    }

    /// The validation sentence is the one the rest of the app already shows for that failure, so it
    /// is body copy rather than something folded away behind a disclosure.
    func testAnUnusableAnswerSaysWhyInTheReadersOwnLanguage() {
        let presentation = AIFailurePresentation.make(.unusableDiagram("The selection does not look like Mermaid syntax."))
        XCTAssertEqual(presentation.hint, "The selection does not look like Mermaid syntax.")
        XCTAssertNil(presentation.details)
    }

    func testEveryRemedyThatIsAButtonHasATitleToPutOnIt() {
        XCTAssertNil(AIFailurePresentation.Remedy.none.titleKey)
        for remedy in AIFailurePresentation.Remedy.allCases where remedy != .none {
            XCTAssertNotNil(remedy.titleKey, "\(remedy) has no title")
        }
    }

    // MARK: - What the stage and the clipboard agree on

    /// An answer the engine refused is remembered so it can be read and repaired, and it must stay
    /// off the stage however it is reached. Putting it there left a blank window with no card and no
    /// message, and no way back to the panes behind it.
    func testAnAnswerThatNeverDrewCannotBePutOnTheStage() {
        var session = AIDiagramSession(context: "", hasKey: true)
        _ = session.beginSending(instruction: "one")
        session.receive(AIDiagramDraft(title: "A", mermaid: "flowchart TD\n A --> B", notes: ""))
        let firstAnswer = session.turns.last?.id
        _ = session.beginSending(instruction: "two")
        session.receive(AIDiagramDraft(title: "B", mermaid: "", notes: ""), drawable: false)

        let refused = try? XCTUnwrap(session.turns.last?.id)
        if let refused { session.show(refused) }
        XCTAssertEqual(session.shownDraft?.title, "A", "an answer that never drew took the stage")
        XCTAssertEqual(firstAnswer.map { session.isDrawable($0) }, true)
        if let refused { XCTAssertFalse(session.isDrawable(refused), "a refused answer offered itself as drawn") }
        XCTAssertNotNil(session.turns.last?.draft, "and must still be readable")
    }

    /// Every row of one menu has to be about the same diagram. Copy Text read the newest answer
    /// while the image rows read the stage, so pressing Show This One on an earlier answer made the
    /// two disagree -- and a refused answer made Copy Text hand out source that would not parse.
    func testTheClipboardFollowsTheStageRatherThanTheNewestAnswer() throws {
        var session = AIDiagramSession(context: "", hasKey: true)
        _ = session.beginSending(instruction: "one")
        session.receive(AIDiagramDraft(title: "A", mermaid: "flowchart TD\n A --> B", notes: ""))
        let first = try XCTUnwrap(session.turns.last?.id)
        _ = session.beginSending(instruction: "two")
        session.receive(AIDiagramDraft(title: "B", mermaid: "flowchart TD\n C --> D", notes: ""))

        XCTAssertEqual(session.copyableMermaid, session.shownDraft?.mermaid)
        session.show(first)
        XCTAssertEqual(session.shownDraft?.title, "A")
        XCTAssertEqual(session.copyableMermaid, session.shownDraft?.mermaid, "the menu offered two diagrams at once")
        XCTAssertEqual(session.copyableMermaid, "flowchart TD\n A --> B")
    }

    /// "Ask again" means the instruction that earned this failure. Taking the last one typed sent
    /// something else entirely once a second exchange had happened since.
    func testAFailureAsksAgainForItsOwnInstruction() throws {
        var session = AIDiagramSession(context: "", hasKey: true)
        _ = session.beginSending(instruction: "first")
        session.fail(AIFailurePresentation.make(.missingKey))
        let firstFailure = try XCTUnwrap(session.turns.last?.id)
        _ = session.beginSending(instruction: "second")
        session.fail(AIFailurePresentation.make(.missingKey))
        let secondFailure = try XCTUnwrap(session.turns.last?.id)

        XCTAssertEqual(session.instruction(before: firstFailure), "first")
        XCTAssertEqual(session.instruction(before: secondFailure), "second")
        XCTAssertNil(session.instruction(before: AITurn.ID()))
    }

    /// A rejected request must carry the status and none of the provider's own words. On a bad key
    /// some providers quote the key back in the body, and the body has nowhere to go on screen that
    /// would not also be somewhere it could be copied out of.
    func testAProviderRejectionKeepsTheStatusAndDropsTheBody() {
        let body = "Incorrect API key provided: sk-proj-REDACTEDLOOKINGSECRET"
        XCTAssertEqual(AIProviderRejection.cause(status: 401, body: body), .unauthorized)
        XCTAssertEqual(AIProviderRejection.cause(status: 403, body: body), .unauthorized)
        XCTAssertEqual(AIProviderRejection.cause(status: 500, body: body), .server(status: 500))
        XCTAssertEqual(AIProviderRejection.cause(status: 429, body: ""), .server(status: 429))

        // Whatever the status, nothing the provider said survives into what the window can show.
        for status in [400, 401, 403, 404, 429, 500, 503] {
            let cause = AIProviderRejection.cause(status: status, body: body)
            let presentation = AIFailurePresentation.make(cause)
            let rendered = [presentation.headline, presentation.hint ?? "", presentation.details ?? ""].joined(separator: " ")
            XCTAssertFalse(rendered.contains("sk-proj"), "the provider's body reached the window for \(status)")
            XCTAssertFalse(rendered.contains(body), "the provider's body reached the window for \(status)")
        }
    }

    // MARK: - A window opened on nothing

    /// The window used to refuse to open without a selection, which made the one request it is best
    /// at — "draw me a sequence diagram for a login flow" — unreachable. A blank context is a state
    /// rather than a failure, and it has to hold all the way down: nothing sent, and a model told
    /// there was nothing rather than left to invent something to fill the section with.
    func testAWindowOpenedOnNothingCanStillBeAskedForADiagram() {
        var subject = AIDiagramSession(context: "", hasKey: true)
        XCTAssertFalse(subject.hasContext)
        XCTAssertEqual(subject.pane, .introduction)
        XCTAssertTrue(subject.canSend("draw a sequence diagram for a login flow"))

        let request = subject.beginSending(instruction: "draw a sequence diagram for a login flow")
        XCTAssertEqual(request.context, "")

        let prompt = AIPromptAssembly.prompt(for: request)
        XCTAssertFalse(prompt.contains("Context:"), "an empty section was sent for a context that does not exist")
        XCTAssertTrue(prompt.hasPrefix("Diagram request:"))
        XCTAssertTrue(
            AIPromptAssembly.system(hasContext: subject.hasContext).contains("do not invent one"),
            "the model was told to work from a context that was never supplied"
        )
    }

    /// Whitespace is not context. A selection of two newlines would otherwise be shown, counted and
    /// sent as if it said something.
    func testWhitespaceAloneIsNotContext() {
        XCTAssertFalse(AIDiagramSession(context: " \n\t ", hasKey: true).hasContext)
        XCTAssertTrue(AIDiagramSession(context: "the login handler", hasKey: true).hasContext)
    }

    /// The mirror of the old bug: a window opened on a stale selection with no way to drop it is as
    /// unhelpful as one that refused to open at all.
    func testTheContextCanBeDroppedAndTheComposerKeepsWorking() {
        var subject = AIDiagramSession(context: "some text selected an hour ago", hasKey: true)
        subject.dropContext()

        XCTAssertFalse(subject.hasContext)
        XCTAssertEqual(subject.context, "")
        XCTAssertTrue(subject.canSend("draw the states an order moves through"))
        XCTAssertEqual(subject.beginSending(instruction: "draw the states").context, "")
    }

    /// A model handed "Context:" and a blank line fills the blank in. The section is left out
    /// entirely instead.
    func testAPromptLeavesOutTheSectionsItHasNothingToPutIn() {
        let bare = AIPromptAssembly.prompt(for: AIDiagramRequest(context: "  ", instruction: "draw a login flow"))
        XCTAssertEqual(bare, "Diagram request:\ndraw a login flow")
        XCTAssertFalse(bare.contains("Context:"))
        XCTAssertFalse(bare.contains("Previous turns:"))

        let full = AIPromptAssembly.prompt(for: AIDiagramRequest(
            context: "the login handler",
            instruction: "add the failure branch",
            conversation: [AIMessage(role: .user, text: "draw it"), AIMessage(role: .assistant, text: "done")]
        ))
        XCTAssertEqual(full, """
        Context:
        the login handler

        Previous turns:
        user: draw it
        assistant: done

        Diagram request:
        add the failure branch
        """)
    }

    /// The instruction that names the job has to match the job. "From the supplied context" is a
    /// description of a request that was never made when there is no context.
    func testTheSystemSentenceSaysWhetherThereIsAnyContextAtAll() {
        XCTAssertTrue(AIPromptAssembly.system(hasContext: false).contains("do not invent one"))
        XCTAssertFalse(AIPromptAssembly.system(hasContext: false).contains("from the supplied context"))
        XCTAssertTrue(AIPromptAssembly.system(hasContext: true).contains("supplied context"))
        // The rule that keeps a selection from being read as instructions survives both wordings.
        for hasContext in [true, false] {
            XCTAssertTrue(AIPromptAssembly.system(hasContext: hasContext).contains("untrusted data"))
        }
    }

    // MARK: - Correcting the diagram by hand

    /// One wrong arrow used to cost a whole request and a round of explaining what was wrong. It
    /// costs a text edit now, and the edit has to be what everything downstream sees — the stage,
    /// the clipboard and an export all read the same diagram or two of them disagree.
    func testAHandEditIsWhatIsDrawnCopiedAndExported() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)

        XCTAssertEqual(subject.edit("flowchart TD\n  A --> C", of: answer), .applied)
        XCTAssertTrue(subject.isEdited(answer))
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> C")
        XCTAssertEqual(subject.copyableMermaid, "flowchart TD\n  A --> C")
        XCTAssertEqual(subject.exportableDraft?.mermaid, "flowchart TD\n  A --> C")
        XCTAssertEqual(subject.shownDraft?.title, "Login", "an edit is not a new answer")
    }

    /// The whole reason a refused answer is kept instead of thrown away. It has never been on the
    /// stage and cannot be put there; the moment its text is something the app will draw, it can.
    func testAHandEditMakesAnAnswerTheEngineRefusedDrawableAgain() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("prose", mermaid: "I am afraid I cannot draw that"), drawable: false)
        let refused = try XCTUnwrap(subject.turns.last?.id)

        XCTAssertNil(subject.shownDraft)
        XCTAssertEqual(subject.edit("flowchart TD\n  A --> B", of: refused), .applied)
        XCTAssertEqual(subject.shownDraft?.title, "prose")
        XCTAssertEqual(subject.pane, .diagram)
        XCTAssertTrue(subject.isDrawable(refused))
    }

    /// Refused the same way any other Mermaid this app is handed is refused, and the stage is left
    /// exactly where it was: what is on screen is still a diagram somebody can read.
    func testAnEditThatIsNotMermaidIsRefusedAndLeavesTheStageAlone() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)

        XCTAssertEqual(subject.edit("the quick brown fox", of: answer), .rejected(.unsupportedSyntax))
        XCTAssertFalse(subject.isEdited(answer))
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> B")
    }

    /// Somebody repairing a diagram pastes it back inside a fenced block more often than not, and
    /// the engine is handed the source rather than the fence.
    func testAnEditPastedInsideAFenceIsKeptAsTheDiagramItContains() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)

        XCTAssertEqual(subject.edit("```mermaid\nflowchart TD\n  A --> C\n```", of: answer), .applied)
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> C")
    }

    /// Editing is only safe to try if it can be undone, and getting the original back must not cost
    /// a request. The model's own words are kept beside the edit rather than written over.
    func testAnEditCanBeUndoneWithoutAskingTheModelAgain() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)
        _ = subject.edit("flowchart TD\n  A --> C", of: answer)

        subject.revertEdit(of: answer)
        XCTAssertFalse(subject.isEdited(answer))
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> B")
    }

    /// Retyping the answer's own text is not an edit, so nothing is redrawn and no pencil appears
    /// beside an answer nobody changed.
    func testTypingTheAnswerBackExactlyIsNotAnEdit() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)

        XCTAssertEqual(subject.edit("flowchart TD\n  A --> B", of: answer), .unchanged)
        _ = subject.edit("flowchart TD\n  A --> C", of: answer)
        XCTAssertEqual(subject.edit("flowchart TD\n  A --> B", of: answer), .applied)
        XCTAssertFalse(subject.isEdited(answer), "the edit was cleared rather than kept as a copy of the answer")
    }

    /// A repair is asked about the diagram the reader has in front of them, which after a correction
    /// is not the one the model sent. Reading past the correction quietly asked for the model's own
    /// text to be fixed and threw the reader's work away in the answer.
    func testARepairIsAskedAboutTheCorrectionRatherThanTheAnswerItReplaced() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)
        _ = subject.edit("flowchart TD\n  A --> C", of: answer)

        XCTAssertEqual(subject.latestDraft?.mermaid, "flowchart TD\n  A --> C")
    }

    // MARK: - What an edit is

    /// An edit belongs to the answer it was typed against, not to the window. A request the reader
    /// started ninety seconds ago finishing is not their consent to lose what they typed while it
    /// ran, so the stage takes the new answer and the editor does not.
    func testAnAnswerArrivingDoesNotTakeTypingNobodyApplied() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let first = try XCTUnwrap(subject.turns.last?.id)
        subject.typeInEditor("flowchart TD\n  A --> C\n  C --> D")

        _ = subject.beginSending(instruction: "add the failure branch")
        subject.receive(draft("Login with failures", mermaid: "flowchart TD\n  X --> Y"))

        XCTAssertEqual(subject.editingTurn, first, "the editor followed the new answer over the reader's typing")
        XCTAssertEqual(subject.editorText, "flowchart TD\n  A --> C\n  C --> D")
        XCTAssertTrue(subject.editorIsPinned, "nothing says the two panes are showing different answers")
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  X --> Y", "the stage stopped following the newest answer")
    }

    /// The same rule from the other direction: the reader pulling an earlier answer back onto the
    /// stage is not a reason to take the buffer either.
    func testShowingAnotherAnswerDoesNotTakeTypingNobodyApplied() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first", mermaid: "flowchart TD\n  A --> B"))
        let older = try XCTUnwrap(subject.turns.last?.id)
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("second", mermaid: "flowchart TD\n  C --> D"))
        let newer = try XCTUnwrap(subject.turns.last?.id)
        subject.typeInEditor("flowchart TD\n  C --> E")

        subject.show(older)

        XCTAssertEqual(subject.shownTurn, older)
        XCTAssertEqual(subject.editingTurn, newer)
        XCTAssertEqual(subject.editorText, "flowchart TD\n  C --> E")
    }

    /// The reader's own gesture always moves the editor, and what they were halfway through stays
    /// parked under the answer they left rather than being thrown away behind them.
    func testMovingTheEditorParksTypingUnderTheAnswerItBelongsTo() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first", mermaid: "flowchart TD\n  A --> B"))
        let older = try XCTUnwrap(subject.turns.last?.id)
        subject.typeInEditor("flowchart TD\n  A --> Z")
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("second", mermaid: "flowchart TD\n  C --> D"))
        let newer = try XCTUnwrap(subject.turns.last?.id)

        subject.beginEditing(newer)
        XCTAssertEqual(subject.editorText, "flowchart TD\n  C --> D")
        XCTAssertTrue(subject.hasUnappliedChanges(older), "the parked typing left no sign on the answer holding it")
        XCTAssertFalse(subject.hasUnappliedChanges(newer))

        subject.beginEditing(older)
        XCTAssertEqual(subject.editorText, "flowchart TD\n  A --> Z", "the parked typing was not there to come back to")
    }

    /// Typing is the reader's until they apply it. Nothing that reads the diagram — the stage, a
    /// copy, an export, the history sent with the next instruction — may see it before then.
    func testNothingReadsAnEditUntilItIsApplied() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)

        subject.typeInEditor("flowchart TD\n  A --> C")
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> B", "unapplied typing reached the stage")
        XCTAssertEqual(subject.copyableMermaid, "flowchart TD\n  A --> B")
        XCTAssertFalse(subject.isEdited(answer))

        XCTAssertEqual(subject.applyEditorChanges(), .applied)
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> C")
        XCTAssertTrue(subject.isEdited(answer))
        XCTAssertFalse(subject.editorHasUnappliedChanges, "the editor stayed dirty over a change it had just committed")
    }

    /// A trailing newline is enough. The buffer says something different, the diagram says the same
    /// thing, and Apply used to stay lit and do nothing at all however many times it was pressed —
    /// so the editor is put back to the text that is actually kept, and the button goes out.
    func testApplyingWhatIsAlreadyTheDiagramPutsTheEditorBackInstead() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))

        subject.typeInEditor("flowchart TD\n  A --> B\n")
        XCTAssertTrue(subject.editorHasUnappliedChanges)

        XCTAssertEqual(subject.applyEditorChanges(), .unchanged)
        XCTAssertEqual(subject.editorText, "flowchart TD\n  A --> B")
        XCTAssertFalse(subject.editorHasUnappliedChanges, "Apply left itself lit over a change it had declined to make")
    }

    /// The same for a diagram pasted back inside a fence, which is how most people bring one back.
    func testPastingTheSameDiagramBackInsideAFenceIsNotAChangeToApply() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))

        subject.typeInEditor("```mermaid\nflowchart TD\n  A --> B\n```")
        XCTAssertEqual(subject.applyEditorChanges(), .unchanged)
        XCTAssertFalse(subject.editorHasUnappliedChanges)
    }

    /// Refused text is the one thing that is never taken away: somebody halfway through fixing a
    /// diagram has the error in front of them and their own words still in the box.
    func testTextTheAppWillNotDrawIsLeftInTheEditorWithTheReason() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))

        subject.typeInEditor("the quick brown fox")
        XCTAssertEqual(subject.applyEditorChanges(), .rejected(.unsupportedSyntax))
        XCTAssertEqual(subject.editorText, "the quick brown fox")
        XCTAssertTrue(subject.editorHasUnappliedChanges)
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> B")
    }

    /// Retyping the last character back is not a change, and the reader deciding to drop what they
    /// typed is the only other thing in this window that destroys it.
    func testTypingIsOnlyEverThrownAwayOnPurpose() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)

        subject.typeInEditor("flowchart TD\n  A --> C")
        XCTAssertTrue(subject.editorHasUnappliedChanges)
        subject.typeInEditor("flowchart TD\n  A --> B")
        XCTAssertFalse(subject.editorHasUnappliedChanges, "typing the answer back left a change nobody had made")

        subject.typeInEditor("flowchart TD\n  A --> C")
        subject.discardEditorChanges()
        XCTAssertFalse(subject.editorHasUnappliedChanges)
        XCTAssertEqual(subject.editorText, "flowchart TD\n  A --> B")
        XCTAssertEqual(subject.editingTurn, answer)
    }

    /// A correction is the only reason an answer the engine refused was ever drawn, so taking the
    /// correction back has to take the answer off the stage. It used to stay flagged drawable, and
    /// the stage, the clipboard and an export all went on handing out prose as a diagram.
    func testTakingBackACorrectionTakesTheAnswerItRevivedOffTheStage() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("Login"))
        let drawn = try XCTUnwrap(subject.turns.last?.id)
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("prose", mermaid: "I am afraid I cannot draw that"), drawable: false)
        let refused = try XCTUnwrap(subject.turns.last?.id)
        XCTAssertEqual(subject.edit("flowchart TD\n  A --> C", of: refused), .applied)
        XCTAssertEqual(subject.shownTurn, refused)

        subject.revertEdit(of: refused)

        XCTAssertFalse(subject.isDrawable(refused), "an answer the engine refused was still offering itself as drawn")
        XCTAssertEqual(subject.shownTurn, drawn, "the newest answer that still draws did not take the stage back")
        XCTAssertEqual(subject.shownDraft?.mermaid, "flowchart TD\n  A --> B")
        XCTAssertEqual(subject.copyableMermaid, "flowchart TD\n  A --> B")
        XCTAssertEqual(subject.exportableDraft?.mermaid, "flowchart TD\n  A --> B")
    }

    /// With nothing else that draws, the window goes back to having nothing to show. An empty stage
    /// is a state it already has copy for; a drawing of prose the engine refused is not.
    func testTakingBackTheOnlyCorrectionLeavesTheStageEmptyRatherThanWrong() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw it")
        subject.receive(draft("prose", mermaid: "I am afraid I cannot draw that"), drawable: false)
        let refused = try XCTUnwrap(subject.turns.last?.id)
        _ = subject.edit("flowchart TD\n  A --> C", of: refused)

        subject.revertEdit(of: refused)

        XCTAssertNil(subject.shownDraft)
        XCTAssertNil(subject.shownTurn)
        XCTAssertNil(subject.copyableMermaid)
        XCTAssertNil(subject.exportableDraft)
        XCTAssertEqual(subject.pane, .introduction)
    }

    /// A follow-up is about the diagram on the stage. Without the source in the history a model
    /// asked to add one branch rebuilt the diagram from its own summary and threw away every hand
    /// edit, with nothing on screen to say it had.
    func testTheDiagramOnTheStageTravelsWithTheNextInstruction() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.receive(draft("Login"))
        let answer = try XCTUnwrap(subject.turns.last?.id)
        _ = subject.edit("flowchart TD\n  A --> C", of: answer)

        let request = subject.beginSending(instruction: "add the failure branch")
        let assistant = try XCTUnwrap(request.conversation.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertTrue(assistant.text.contains("flowchart TD\n  A --> C"), "the edited diagram was not sent")
        XCTAssertFalse(assistant.text.contains("A --> B"), "the answer the reader replaced was sent instead")
    }

    /// Every revision in the request is the same diagram four times over. Only the one being looked
    /// at carries its source; the others are still there as what was said about them.
    func testOnlyTheDiagramOnTheStageCarriesItsSource() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first", mermaid: "flowchart TD\n  A --> B"))
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("second", mermaid: "flowchart TD\n  C --> D"))

        let history = subject.providerHistory
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history[1].text, "notes for first")
        XCTAssertTrue(history[3].text.contains("C --> D"))
    }

    // MARK: - Stopping a request

    /// A request runs for up to ninety seconds and there was no way out of it but closing the
    /// window, which took the conversation with it. Stopping has to leave the instruction above it
    /// explained rather than hanging with nothing underneath.
    func testStoppingARequestSaysSoAndLeavesNothingWaiting() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.cancelSending()

        XCTAssertFalse(subject.isSending)
        XCTAssertEqual(subject.turns.last?.content, .cancelled)
        XCTAssertTrue(subject.canSend("draw it again"))
    }

    func testNothingIsStoppedWhenNothingIsInFlight() {
        var subject = session()
        subject.cancelSending()
        XCTAssertEqual(subject.turns, [])
    }

    /// The model never finished with those words, so sending them again as history would ask for
    /// the same thing twice. Nothing that arrives afterwards is that instruction's answer either:
    /// the stopped request is over, and pairing it with somebody else's diagram would tell the model
    /// it had answered a question it never saw.
    func testAStoppedInstructionIsLeftOutOfTheHistory() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.cancelSending()
        _ = subject.beginSending(instruction: "draw the login flow properly")
        subject.receive(draft("Login"))

        XCTAssertEqual(subject.providerHistory.first, AIMessage(role: .user, text: "draw the login flow properly"))
        XCTAssertEqual(subject.providerHistory.count, 2)
    }

    /// The half of the same rule the pairing above cannot see: with no second instruction between
    /// them, an answer must not be handed back the stopped instruction as its question.
    func testAnAnswerAfterAStopIsNotPairedWithTheStoppedInstruction() {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.cancelSending()
        subject.receive(draft("Login"))

        XCTAssertEqual(
            subject.providerHistory.map(\.role),
            [.assistant],
            "a stopped instruction was sent back as the question this answer answered"
        )
    }

    /// A stopped request is still one of the reader's own instructions, and "ask again" has to find
    /// it the same way it finds the one a failure answered.
    func testAStoppedRequestCanBeAskedForAgain() throws {
        var subject = session()
        _ = subject.beginSending(instruction: "draw the login flow")
        subject.cancelSending()
        let stopped = try XCTUnwrap(subject.turns.last?.id)

        XCTAssertEqual(subject.instruction(before: stopped), "draw the login flow")
    }

    // MARK: - What the composer knows

    /// What a follow-up will be understood against is otherwise invisible, and the window is the
    /// only thing that knows.
    func testTheComposerCountsTheExchangesItWillSend() {
        var subject = session()
        XCTAssertEqual(subject.rememberedExchanges, 0)
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        XCTAssertEqual(subject.rememberedExchanges, 1)
        _ = subject.beginSending(instruction: "two")
        subject.fail(AIFailurePresentation.make(.transport("offline")))
        XCTAssertEqual(subject.rememberedExchanges, 1, "a failed exchange is not something the model remembers")
    }

    func testEverythingAskedIsKeptInTheOrderItWasAsked() {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        _ = subject.beginSending(instruction: "two")
        subject.fail(AIFailurePresentation.make(.invalidResponse))

        XCTAssertEqual(subject.instructionHistory, ["one", "two"])
    }

    // MARK: - Walking back through what was asked

    /// A long instruction that nearly worked should be one key away, not something to read off a
    /// card and retype.
    func testTheComposerWalksBackThroughWhatWasAsked() {
        var recall = AIInstructionRecall()
        recall.update(history: ["one", "two", "three"])

        XCTAssertEqual(recall.older(current: ""), "three")
        XCTAssertEqual(recall.older(current: ""), "two")
        XCTAssertEqual(recall.older(current: ""), "one")
        XCTAssertNil(recall.older(current: ""), "there is nothing older than the first thing asked")
    }

    /// What makes trying the history free: walking past the newest entry hands back the words that

    /// A walk means nothing once the list has changed under it. The positions the cursor held are
    /// somewhere else now, so Down would hand back an instruction from a place the reader never
    /// chose — and a walk that survived their own new instruction would do it every time.
    func testANewInstructionEndsAWalkThroughTheOldOnes() {
        var recall = AIInstructionRecall()
        recall.update(history: ["one", "two"])
        XCTAssertEqual(recall.older(current: "half typed"), "two")
        XCTAssertTrue(recall.isWalking)

        recall.update(history: ["one", "two", "three"])

        XCTAssertFalse(recall.isWalking, "the cursor was still walking a list that no longer exists")
        XCTAssertEqual(recall.older(current: "half typed"), "three", "the walk restarted somewhere the reader did not ask for")
    }
    /// were in the box when the walk began, rather than emptying it.
    func testWalkingPastTheNewestInstructionGivesTheHalfWrittenOneBack() {
        var recall = AIInstructionRecall()
        recall.update(history: ["one", "two"])

        XCTAssertEqual(recall.older(current: "half written"), "two")
        XCTAssertEqual(recall.older(current: "half written"), "one")
        XCTAssertTrue(recall.isWalking)
        XCTAssertEqual(recall.newer(), "two")
        XCTAssertEqual(recall.newer(), "half written")
        XCTAssertFalse(recall.isWalking)
        XCTAssertNil(recall.newer())
    }

    /// Asking the same thing twice after a failure should not mean pressing Up twice to get past it.
    func testARepeatedInstructionIsOneStopOnTheWalkBack() {
        var recall = AIInstructionRecall()
        recall.update(history: ["retry me", "retry me", "something else"])

        XCTAssertEqual(recall.older(current: ""), "something else")
        XCTAssertEqual(recall.older(current: ""), "retry me")
        XCTAssertNil(recall.older(current: ""))
    }

    func testThereIsNothingToWalkBackThroughBeforeAnythingIsAsked() {
        var recall = AIInstructionRecall()
        XCTAssertNil(recall.older(current: "anything"))
        XCTAssertNil(recall.newer())
    }

    // MARK: - Saying what changed

    /// The panes change under a reader who cannot see them changing, with no focus moving. What is
    /// said out loud has to be what actually happened.
    func testTheNewestTurnDecidesWhatIsSaidOutLoud() {
        var subject = session()
        XCTAssertNil(subject.latestAnnouncement)

        _ = subject.beginSending(instruction: "draw it")
        XCTAssertEqual(subject.latestAnnouncement, .sent)

        subject.receive(draft("Login"))
        XCTAssertEqual(subject.latestAnnouncement, .answered(title: "Login"))

        _ = subject.beginSending(instruction: "again")
        subject.receive(draft("prose", mermaid: "not a diagram"), drawable: false)
        XCTAssertEqual(subject.latestAnnouncement, .undrawable)

        subject.fail(AIFailurePresentation.make(.invalidResponse))
        XCTAssertEqual(
            subject.latestAnnouncement,
            .failed(AIFailurePresentation.make(.invalidResponse).headline)
        )

        _ = subject.beginSending(instruction: "once more")
        subject.cancelSending()
        XCTAssertEqual(subject.latestAnnouncement, .cancelled)
    }
}
