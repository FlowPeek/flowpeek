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
            AIMessage(role: .assistant, text: "notes for Login"),
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
            AIMessage(role: .assistant, text: "notes for Login"),
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
    /// on it, but it is still the newest thing said and still has text worth keeping.
    func testAnAnswerThatCannotBeDrawnIsRememberedWithoutTakingTheStage() {
        var subject = session()
        _ = subject.beginSending(instruction: "one")
        subject.receive(draft("first"))
        _ = subject.beginSending(instruction: "two")
        subject.receive(draft("prose", mermaid: "I am afraid I cannot draw that"), drawable: false)

        XCTAssertEqual(subject.shownDraft?.title, "first")
        XCTAssertEqual(subject.latestDraft?.title, "prose")
        XCTAssertEqual(subject.copyableMermaid, "I am afraid I cannot draw that")
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
}
