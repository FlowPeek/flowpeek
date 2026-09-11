import XCTest

@testable import FlowPeekCore

/// The rules about when FlowPeek may put an editor in front of somebody, and when it must not.
final class AppIntegrationTests: XCTestCase {
    private func statuses(_ pairs: (String, AppIntegrationStatus)...) -> [(id: String, status: AppIntegrationStatus)] {
        pairs.map { (id: $0.0, status: $0.1) }
    }

    // MARK: - What the wizard shows

    /// The card does not exist on a Mac with none of these editors on it, which is most Macs. A
    /// setup step about software the reader does not have is the kind people learn to click past.
    func testTheWizardSkipsTheCardWhenNothingIsInstalled() {
        XCTAssertFalse(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .absent))))
        XCTAssertEqual(AppIntegrationPolicy.onboardingOffers(statuses(("sublime-text", .absent))), [])
    }

    func testTheWizardOffersAnEditorThatIsHereAndNotSetUp() {
        XCTAssertTrue(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .offered))))
        XCTAssertEqual(
            AppIntegrationPolicy.onboardingOffers(statuses(("sublime-text", .offered))),
            ["sublime-text"]
        )
    }

    /// Somebody who already said yes is not asked again. An integration carrying the current payload
    /// has nothing for them to do.
    func testAnEditorAlreadySetUpIsNotAnOffer() {
        XCTAssertFalse(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .active))))
    }

    /// A payload that has moved on is an offer again: the file in place is ours and is behind.
    func testAnOutdatedPayloadIsOfferedAgain() {
        XCTAssertTrue(
            AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .outdated(installed: 1))))
        )
    }

    /// A failure is the one state that most needs saying out loud, so it counts as wanting
    /// attention rather than being quietly treated as done.
    func testAFailureAsksToBeSeen() {
        XCTAssertTrue(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .failed("disk full")))))
    }

    /// With several editors, one already set up and one not, only the one with something to do is
    /// offered — but the card still appears.
    func testOnlyTheEditorsWithSomethingToDoAreOffered() {
        let mixed = statuses(
            ("one", .active), ("two", .offered), ("three", .absent), ("four", .outdated(installed: 2))
        )
        XCTAssertTrue(AppIntegrationPolicy.showsOnboardingStep(mixed))
        XCTAssertEqual(AppIntegrationPolicy.onboardingOffers(mixed), ["two", "four"])
    }

    // MARK: - What the settings tab lists

    /// The tab is where a decision is undone as well as made, so it lists what is set up too.
    func testTheTabListsEveryEditorFoundHereWhateverItsState() {
        let mixed = statuses(("one", .active), ("two", .offered), ("three", .absent))
        XCTAssertEqual(AppIntegrationPolicy.settingsRows(mixed), ["one", "two"])
        XCTAssertTrue(AppIntegrationPolicy.settingsHasRows(mixed))
    }

    /// An editor that is not on this Mac stays out of the tab as well: the tab says what FlowPeek
    /// can do here, not what it could do somewhere else.
    func testTheTabSaysSoWhenThereIsNothingToList() {
        XCTAssertEqual(AppIntegrationPolicy.settingsRows(statuses(("one", .absent))), [])
        XCTAssertFalse(AppIntegrationPolicy.settingsHasRows(statuses(("one", .absent))))
    }

    // MARK: - The states themselves

    func testTheStatesAgreeOnWhatIsInstalledAndWhatIsPresent() {
        XCTAssertFalse(AppIntegrationStatus.absent.isPresent)
        for status in [AppIntegrationStatus.offered, .active, .outdated(installed: 1), .failed("x")] {
            XCTAssertTrue(status.isPresent, "\(status) means the application is here")
        }
        XCTAssertTrue(AppIntegrationStatus.active.isInstalled)
        XCTAssertTrue(AppIntegrationStatus.outdated(installed: 1).isInstalled)
        XCTAssertFalse(AppIntegrationStatus.offered.isInstalled)
        // A failed write left nothing behind, so the switch must not read as on.
        XCTAssertFalse(AppIntegrationStatus.failed("x").isInstalled)
    }

    // MARK: - The catalogue

    /// The one integration that exists has to be described well enough to be written and found
    /// again, and its identifier is what its state is filed under, so it may never be reworded.
    func testTheSublimeIntegrationNamesEverythingNeededToWriteAndFindIt() {
        let sublime = AppIntegration.sublimeText
        XCTAssertEqual(sublime.id, "sublime-text")
        XCTAssertEqual(sublime.displayName, "Sublime Text")
        XCTAssertTrue(sublime.bundleIDs.contains("com.sublimetext.4"))
        XCTAssertEqual(
            sublime.installDirectory,
            ["Application Support", "Sublime Text", "Packages", "User"],
            "this is where Sublime looks for plugins; it is not a guess"
        )
        XCTAssertEqual(sublime.payloadName, "FlowPeek.py")
        XCTAssertGreaterThan(sublime.payloadVersion, 0)
        XCTAssertTrue(AppIntegration.known.contains(sublime))
    }

    /// Identifiers are the filing system. Two integrations sharing one would overwrite each other's
    /// state, and a renamed one would lose track of a file it had already written.
    func testEveryKnownIntegrationHasItsOwnIdentifier() {
        let ids = AppIntegration.known.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertFalse(ids.contains(where: \.isEmpty))
    }
}


/// The published contract. These are the rules a third party reads in `docs/INTEGRATIONS.md`, so
/// they are tested against the document rather than against the one provider that ships with the
/// app: a change here is a change to somebody else's software.
final class IntegrationWatchTests: XCTestCase {
    private func block(top: Double = 10, bottom: Double = 40, x: Double = 5, clipped: Bool = false) -> IntegrationWatch.Answer.Block {
        .init(range: [0, 10], clipped: clipped, x: x, top: top, bottom: bottom, text: "flowchart TD\n A --> B")
    }

    // MARK: - The manifest

    func testAManifestIsUsableOnlyWhenItSaysWhoItSpeaksFor() {
        let good = IntegrationWatch.Manifest(id: "com.example.editor", name: "Example", bundleIdentifiers: ["com.example.editor"])
        XCTAssertTrue(good.isUsable)

        var noBundle = good
        noBundle.bundleIdentifiers = []
        XCTAssertFalse(noBundle.isUsable, "there would be no window to measure against")

        var emptyBundle = good
        emptyBundle.bundleIdentifiers = [""]
        XCTAssertFalse(emptyBundle.isUsable)

        var nameless = good
        nameless.name = ""
        XCTAssertFalse(nameless.isUsable, "the reader has to be told which application this is")

        var anonymous = good
        anonymous.id = ""
        XCTAssertFalse(anonymous.isUsable, "the id is the directory it is found by")

        var future = good
        future.version = IntegrationWatch.supportedVersion + 1
        XCTAssertFalse(future.isUsable, "a newer protocol is left alone rather than guessed at")
    }

    func testTheManifestRoundTripsThroughTheJSONAThirdPartyWouldWrite() throws {
        let json = """
        {"version": 1, "id": "com.example.editor", "name": "Example Editor",
         "bundleIdentifiers": ["com.example.editor", "com.example.editor.beta"]}
        """
        let manifest = try JSONDecoder().decode(IntegrationWatch.Manifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.isUsable)
        XCTAssertEqual(manifest.bundleIdentifiers.count, 2)
        XCTAssertEqual(manifest.name, "Example Editor")
    }

    // MARK: - Saying no to a provider

    /// A provider registers by writing a file, so one can appear without anybody agreeing to it.
    /// The switch in settings is the reader's answer, and this is what it means.
    func testAMutedProviderIsNotWatched() {
        let a = IntegrationWatch.Manifest(id: "a", name: "A", bundleIdentifiers: ["com.a"])
        let b = IntegrationWatch.Manifest(id: "b", name: "B", bundleIdentifiers: ["com.b"])
        XCTAssertEqual(IntegrationWatch.watched([a, b], muted: []).map(\.id), ["a", "b"])
        XCTAssertEqual(IntegrationWatch.watched([a, b], muted: ["a"]).map(\.id), ["b"])
        XCTAssertEqual(IntegrationWatch.watched([a, b], muted: ["a", "b"]), [])
    }

    /// Muting is remembered against the identifier, not against a provider FlowPeek happens to have
    /// seen: switching one off has to survive the editor being reinstalled, and switching it back on
    /// must leave everybody else's decision alone.
    func testTheSwitchOnlyMovesItsOwnProvider() {
        var muted = IntegrationWatch.muting("a", in: [], watched: false)
        XCTAssertEqual(muted, ["a"])
        muted = IntegrationWatch.muting("b", in: muted, watched: false)
        XCTAssertEqual(muted, ["a", "b"])
        muted = IntegrationWatch.muting("a", in: muted, watched: true)
        XCTAssertEqual(muted, ["b"])
        XCTAssertEqual(IntegrationWatch.muting("a", in: muted, watched: true), ["b"], "turning on what is already on changes nothing")
    }

    // MARK: - The answer

    /// The field names are somebody else's to write, so they are pinned by a literal rather than by
    /// round-tripping our own encoder.
    func testAnAnswerDecodesFromTheJSONTheDocumentShows() throws {
        let json = """
        {"version": 1, "ok": true, "at": 1789123456.78, "line_height": 15.0, "em_width": 7.0,
         "content_inset_top": 0.0,
         "blocks": [{"range": [0, 78], "clipped": false, "x": 56.0, "top": 34.0, "bottom": 124.0,
                     "text": "flowchart TD"}]}
        """
        let answer = try JSONDecoder().decode(IntegrationWatch.Answer.self, from: Data(json.utf8))
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(answer.lineHeight, 15)
        XCTAssertEqual(answer.emWidth, 7)
        XCTAssertEqual(answer.blocks?.count, 1)
        XCTAssertEqual(answer.blocks?.first?.top, 34)
        XCTAssertEqual(answer.contentInsetTop, 0, "a provider may say its window has no chrome")
    }

    func testAnAnswerGoesStaleSoAFrameIsNeverLeftWhereADiagramUsedToBe() {
        let fresh = IntegrationWatch.Answer(version: 1, ok: true, at: 1_000, blocks: [block()])
        XCTAssertTrue(IntegrationWatch.isUsable(fresh, now: 1_000 + IntegrationWatch.freshness - 1))
        XCTAssertFalse(IntegrationWatch.isUsable(fresh, now: 1_000 + IntegrationWatch.freshness + 1))
    }

    func testAnAnswerFromANewerProtocolIsIgnored() {
        let future = IntegrationWatch.Answer(version: IntegrationWatch.supportedVersion + 1, ok: true, at: 1_000)
        XCTAssertFalse(IntegrationWatch.isUsable(future, now: 1_000))
    }

    /// `ok: false` is how a provider says "no window, nothing to report", and it must not be drawn.
    func testAProviderCanSayItHasNothingToReport() {
        XCTAssertFalse(IntegrationWatch.isUsable(.init(version: 1, ok: false, at: 1_000), now: 1_000))
    }

    /// An answer with no timestamp is taken at its word: the field is optional in the document.
    func testAnAnswerWithoutATimestampIsStillRead() {
        XCTAssertTrue(IntegrationWatch.isUsable(.init(version: 1, ok: true, blocks: []), now: 9_999))
    }

    // MARK: - Geometry

    /// The one piece of arithmetic in the contract: window coordinates with a top-left origin, plus
    /// the window's place on screen, become an AppKit rectangle.
    func testAWindowRelativeBlockBecomesARectangleOnScreen() throws {
        // A 1000pt-tall screen; a window 100 from the left and 200 down from the top.
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let rect = try XCTUnwrap(
            IntegrationWatch.screenRect(
                of: block(top: 34, bottom: 124, x: 56), window: window,
                contentInsetTop: 32, flipReference: 1_000
            )
        )
        XCTAssertEqual(rect.minX, 156, "the window's left edge plus the block's own offset")
        XCTAssertEqual(rect.height, 90, "bottom minus top")
        // Top-left 200 + 32 of title bar + 34 = 266 down; its bottom edge is 356 down, so in AppKit
        // it sits at 1000 - 356 = 644.
        XCTAssertEqual(rect.minY, 644)
        XCTAssertEqual(rect.maxX, window.maxX - IntegrationWatch.rightInset)
    }

    func testABlockWithNoHeightIsNotARectangle() {
        XCTAssertNil(
            IntegrationWatch.screenRect(
                of: block(top: 50, bottom: 50), window: CGRect(x: 0, y: 0, width: 100, height: 100),
                contentInsetTop: 32, flipReference: 1_000
            )
        )
    }

    /// A diagram taller than the window is the one most worth previewing, so it is framed rather
    /// than skipped. This used to assert the opposite, which is the bug: measured in Sublime, a
    /// 33-line diagram in an 832-point viewport reported 123 to 873, was marked clipped, and got no
    /// frame at all.
    func testAClippedBlockIsStillDrawn() {
        let answer = IntegrationWatch.Answer(
            version: 1, ok: true, at: 1, blocks: [block(clipped: true), block()]
        )
        XCTAssertEqual(IntegrationWatch.drawable(answer).count, 2)
    }

    /// A provider whose range ran past the closing fence is describing a rectangle around the rest
    /// of the document, and drawing it covers the reader's window. Measured in Sublime: the fence
    /// search looked for the wrong marker, found no closer, and ran the block to the end of the
    /// file, so a diagram scrolled out of sight framed everything that was on screen.
    func testABlockThatRanPastItsClosingFenceIsNotDrawn() {
        let good = block()
        var swallowed = block()
        swallowed.text = "```mermaid\nflowchart TD\n A --> B\n```\n\nLine 1: ordinary prose.\nLine 2: more."
        let answer = IntegrationWatch.Answer(version: 1, ok: true, at: 1, blocks: [swallowed, good])
        XCTAssertEqual(IntegrationWatch.drawable(answer).count, 1)
    }

    func testAWellFormedOrUnfinishedBlockIsKept() {
        // Ends at its fence, trailing blank line and all.
        XCTAssertTrue(IntegrationWatch.stopsAtItsOwnFence("```mermaid\nflowchart TD\n```\n"))
        // Never closed: a diagram still being written or still being printed.
        XCTAssertTrue(IntegrationWatch.stopsAtItsOwnFence("```mermaid\nflowchart TD\n A --> B"))
        // Not fenced at all, which is what a provider sends when it reports the source alone.
        XCTAssertTrue(IntegrationWatch.stopsAtItsOwnFence("flowchart TD\n A --> B"))
        // A tilde fence closed by a tilde fence.
        XCTAssertTrue(IntegrationWatch.stopsAtItsOwnFence("~~~mermaid\nflowchart TD\n~~~"))
        // And the fault itself.
        XCTAssertFalse(IntegrationWatch.stopsAtItsOwnFence("```mermaid\nflowchart TD\n```\nprose"))
    }

    /// A provider that says which edge it cut is believed.
    func testTheProvidersOwnAnswerNamesTheOpenEdges() {
        var reported = block(clipped: true)
        reported.clippedTop = true
        reported.clippedBottom = false
        let edges = IntegrationWatch.openEdges(
            of: reported,
            // Deliberately nowhere near the content, to prove the geometry was not consulted.
            rect: CGRect(x: 0, y: 500, width: 100, height: 50),
            content: CGRect(x: 0, y: 0, width: 100, height: 100),
            lineHeight: 15
        )
        XCTAssertEqual(edges, .top)
    }

    /// A provider from before those fields existed still gets an open edge, read from where its
    /// clamped rectangle sits. AppKit coordinates, so the top of the block is `maxY`.
    func testAnOlderProvidersOpenEdgeIsReadFromTheRectangle() {
        let content = CGRect(x: 0, y: 0, width: 500, height: 800)
        // Clamped against the bottom of the content area: the block runs on below the viewport.
        let atBottom = CGRect(x: 0, y: 0, width: 500, height: 400)
        XCTAssertEqual(
            IntegrationWatch.openEdges(of: block(clipped: true), rect: atBottom, content: content, lineHeight: 15),
            .bottom
        )
        // Taller than the window: clamped at both ends, and framed with two open sides.
        XCTAssertEqual(
            IntegrationWatch.openEdges(of: block(clipped: true), rect: content, content: content, lineHeight: 15),
            [.top, .bottom]
        )
        // Sitting in the middle of the viewport and not clipped: nothing is open, whatever the
        // rectangle is flush against.
        XCTAssertEqual(
            IntegrationWatch.openEdges(
                of: block(clipped: false), rect: content, content: content, lineHeight: 15
            ),
            []
        )
    }

    /// The terminal route trims twice -- to the terminal's content, then to the display -- and both
    /// cuts mean the same thing to the frame.
    func testTrimmingAwayAnEdgeOpensIt() {
        let full = CGRect(x: 0, y: 100, width: 400, height: 600)
        XCTAssertEqual(
            AmbientPeekPolicy.openEdges(trimmed: full, from: full), [], "nothing was trimmed"
        )
        XCTAssertEqual(
            AmbientPeekPolicy.openEdges(trimmed: CGRect(x: 0, y: 100, width: 400, height: 300), from: full),
            .top
        )
        XCTAssertEqual(
            AmbientPeekPolicy.openEdges(trimmed: CGRect(x: 0, y: 300, width: 400, height: 400), from: full),
            .bottom
        )
        XCTAssertEqual(
            AmbientPeekPolicy.openEdges(trimmed: CGRect(x: 0, y: 300, width: 400, height: 100), from: full),
            [.top, .bottom]
        )
    }

    func testTheDirectoryNamesAreTheOnesTheDocumentPublishes() {
        XCTAssertEqual(IntegrationWatch.directoryName, "integrations")
        XCTAssertEqual(IntegrationWatch.manifestName, "integration.json")
        XCTAssertEqual(IntegrationWatch.askName, "ask")
        XCTAssertEqual(IntegrationWatch.answerName, "answer.json")
        XCTAssertEqual(IntegrationWatch.supportedVersion, 1)
    }
}
