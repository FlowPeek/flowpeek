import XCTest
@testable import FlowPeekCore

/// The bundle these tests run in has no string catalogue, so `String(localized:)` hands back the key
/// itself. That is what makes the choice of key assertable: a headline of
/// "preview.failure.parse.headline" is proof that the no-line copy was picked.
final class MermaidFailurePresentationTests: XCTestCase {

    private let source = """
    flowchart TD
      A[Start] --> B{Choice}
      B -->|yes| C[Ship]
      B --->>>> D[[Broken]]
      C --> E[Done]
    """

    // MARK: - Quoting the user's own line

    func testAParseFailureQuotesTheOffendingSourceLineNotMermaidsExcerpt() {
        let presentation = MermaidFailurePresentation.make(
            .parseFailure(message: "Parse error on line 4:\n...--->>>> D[[\n-----^\nExpecting 'SEMI', got 'ALPHA'", line: 4),
            source: source
        )
        XCTAssertEqual(presentation.lineNumber, 4)
        XCTAssertEqual(presentation.quotedLine, "B --->>>> D[[Broken]]")
        XCTAssertEqual(presentation.headline, MermaidFailurePresentation.headlineKey(for: "mermaid.render.error.parse-line"))
        XCTAssertEqual(presentation.recovery, .fixSource)
        XCTAssertTrue(presentation.engineDetails?.contains("Expecting") == true, "the engine text has to survive somewhere")
    }

    func testALineNumberPastTheEndOfTheSourceFallsBackToTheHeadlineThatClaimsNoLine() {
        for line in [0, -1, 999] {
            let presentation = MermaidFailurePresentation.make(
                .parseFailure(message: "Parse error on line \(line)", line: line),
                source: source
            )
            XCTAssertNil(presentation.quotedLine, "line \(line)")
            XCTAssertNil(presentation.lineNumber, "line \(line)")
            XCTAssertEqual(
                presentation.headline,
                MermaidFailurePresentation.headlineKey(for: "mermaid.render.error.parse"),
                "line \(line) points at nothing, so it must not be named"
            )
        }
    }

    func testABlankOffendingLineKeepsItsNumberAndQuotesNothing() {
        let presentation = MermaidFailurePresentation.make(
            .parseFailure(message: "Parse error on line 2", line: 2),
            source: "flowchart TD\n   \n  A --> B"
        )
        XCTAssertEqual(presentation.lineNumber, 2)
        XCTAssertNil(presentation.quotedLine)
    }

    func testAMissingLineNumberIsAFirstClassPathBecauseTheLangiumParsersHaveNoHash() {
        let presentation = MermaidFailurePresentation.make(
            .parseFailure(message: "Expecting: one of these possible Token sequences", line: nil),
            source: "packet-beta\n  0-15: nonsense"
        )
        XCTAssertNil(presentation.lineNumber)
        XCTAssertNil(presentation.quotedLine)
        XCTAssertEqual(presentation.headline, MermaidFailurePresentation.headlineKey(for: "mermaid.render.error.parse"))
        XCTAssertEqual(presentation.engineDetails, "Expecting: one of these possible Token sequences")
    }

    func testAVeryLongLineIsClippedRatherThanPastedIntoThePanel() {
        let long = "flowchart TD\n  A[" + String(repeating: "x", count: 400) + "] --> B"
        let presentation = MermaidFailurePresentation.make(.parseFailure(message: "Parse error", line: 2), source: long)
        let quoted = try? XCTUnwrap(presentation.quotedLine)
        XCTAssertEqual(quoted?.count, MermaidFailurePresentation.maximumQuotedLength + 1, "120 characters plus the ellipsis")
        XCTAssertEqual(quoted?.last, "…")
    }

    // MARK: - The diagram type mermaid cannot draw

    func testAnUnrecognisedTypeShowsTheFirstLineAndNeverEchoesTheWholeSelection() {
        let selection = "zenuml\n  Alice->Bob: hi\n  Bob->Alice: hello"
        let detail = "No diagram type detected matching given configuration for text: " + selection
        let presentation = MermaidFailurePresentation.make(.unknownDiagramType(detail), source: selection)

        XCTAssertEqual(presentation.quotedLine, "zenuml", "the first line is the one that has to name a type")
        XCTAssertEqual(presentation.lineNumber, 1)
        XCTAssertEqual(presentation.recovery, .fixSource)
        XCTAssertEqual(presentation.engineDetails, detail)
        for shown in [presentation.headline, presentation.hint ?? "", presentation.quotedLine ?? "", presentation.plainSummary] {
            XCTAssertFalse(shown.contains("Alice"), "the selection must not be read back to its author: \(shown)")
            XCTAssertFalse(shown.contains("No diagram type detected"), shown)
        }
    }

    // MARK: - Nothing the engine said reaches the eye

    func testNoPresentationEverPutsEngineTextInItsCopy() {
        let sentinel = "SENTINEL-DETAIL Expecting 'SEMI', 'NEWLINE', got 'ALPHA' ^"
        let carriers: [MermaidRenderError] = [
            .navigationFailed(sentinel),
            .unknownDiagramType(sentinel),
            .parseFailure(message: sentinel, line: 2),
            .parseFailure(message: sentinel, line: nil),
            .edgeLimitExceeded(message: sentinel),
            .internalFailure(sentinel),
        ]
        for error in carriers {
            let presentation = MermaidFailurePresentation.make(error, source: source)
            XCTAssertFalse(presentation.headline.contains("SENTINEL"), "\(error)")
            XCTAssertFalse(presentation.hint?.contains("SENTINEL") == true, "\(error)")
            XCTAssertFalse(presentation.quotedLine?.contains("SENTINEL") == true, "\(error)")
            XCTAssertFalse(presentation.plainSummary.contains("SENTINEL"), "\(error)")
            XCTAssertEqual(presentation.engineDetails, sentinel, "\(error) dropped the detail the log needs")
            XCTAssertTrue(presentation.diagnosticReport.contains(sentinel), "\(error) is not reportable")
        }
    }

    func testEveryFailureCodeCarriesAHeadlineAHintAndOneThingToDo() {
        for error in Self.allErrors {
            let presentation = MermaidFailurePresentation.make(error, source: source)
            XCTAssertFalse(presentation.headline.isEmpty, "\(error)")
            XCTAssertNotNil(presentation.hint, "\(error) leaves the reader with nothing to try")
            XCTAssertEqual(presentation.localizationKey, error.localizationKey, "\(error)")
            XCTAssertFalse(presentation.plainSummary.contains("\n"), "\(error) must stay one line for the AI inspector")
        }
    }

    func testRetryIsOfferedOnlyWhereRetryingCouldWork() {
        XCTAssertEqual(MermaidRenderError.engineNotReady.recovery, .retry)
        XCTAssertEqual(MermaidRenderError.webContentTerminated.recovery, .retry)
        XCTAssertEqual(MermaidRenderError.navigationFailed("x").recovery, .retry)
        XCTAssertEqual(MermaidRenderError.renderProducedNoSVG.recovery, .retry)
        XCTAssertEqual(MermaidRenderError.timedOut(seconds: 8).recovery, .retry)
        XCTAssertEqual(MermaidRenderError.internalFailure("x").recovery, .retry)

        XCTAssertEqual(MermaidRenderError.parseFailure(message: "x", line: 1).recovery, .fixSource)
        XCTAssertEqual(MermaidRenderError.unknownDiagramType("x").recovery, .fixSource)
        XCTAssertEqual(MermaidRenderError.edgeLimitExceeded(message: "x").recovery, .fixSource)
        XCTAssertEqual(MermaidRenderError.inputTooLarge(utf16: 1, limit: 2).recovery, .fixSource)

        XCTAssertEqual(MermaidRenderError.engineMissing.recovery, .none, "no build can talk itself into having the engine")
    }

    func testAnEngineThatNeverStartedHasNoSourceToPointAt() {
        let presentation = MermaidFailurePresentation.make(.engineMissing)
        XCTAssertNil(presentation.quotedLine)
        XCTAssertNil(presentation.engineDetails)
        XCTAssertEqual(presentation.plainSummary, presentation.headline)
    }

    // MARK: - Catalogues

    func testEveryPresentationKeyIsTranslatedInBothCatalogsWithMatchingSpecifiers() throws {
        let keys = MermaidFailurePresentation.localizationKeys + DiagramNotice.localizationKeys
            + ["settings.ai.shortcut", "settings.ai.keychain", "ai.error.server", "ai.error.unauthorized"]
        var specifiers: [String: [String: [String]]] = [:]
        for language in ["en", "ko"] {
            let entries = try Self.catalog(language)
            for key in keys {
                guard let value = entries[key] else {
                    XCTFail("\(language).lproj is missing \(key)")
                    continue
                }
                XCTAssertFalse(value.isEmpty, "\(language).lproj has an empty \(key)")
                specifiers[key, default: [:]][language] = Self.formatSpecifiers(value)
            }
        }
        for (key, byLanguage) in specifiers {
            XCTAssertEqual(
                byLanguage["en"]?.sorted(), byLanguage["ko"]?.sorted(),
                "\(key) takes different arguments in each language, which crashes String(format:)"
            )
        }
    }

    func testTheHeadlineKeysCoverEveryFailureCodeAndNothingElse() {
        XCTAssertEqual(
            MermaidFailurePresentation.localizationKeys.count,
            MermaidRenderError.localizationKeys.count * 2 + 4
        )
        for error in Self.allErrors {
            let headline = MermaidFailurePresentation.headlineKey(for: error.localizationKey)
            XCTAssertTrue(MermaidFailurePresentation.localizationKeys.contains(headline), headline)
            XCTAssertTrue(headline.hasPrefix("preview.failure."), headline)
        }
    }

    // MARK: - The quiet notice

    func testOnlyRemovalsSomebodyCanSeeRaiseANotice() {
        XCTAssertNil(DiagramNotice.make(scrubbed: [], cspViolations: [], measurementFallbacks: []))
        XCTAssertNil(
            DiagramNotice.make(scrubbed: ["script", "meta", "animate", "@onclick"], cspViolations: [], measurementFallbacks: []),
            "none of these were ever going to draw anything"
        )
        XCTAssertNil(
            DiagramNotice.make(scrubbed: [], cspViolations: [], measurementFallbacks: ["viewbox"]),
            "a diagram with no viewBox is still measured by WebKit, so its size is honest"
        )
        XCTAssertEqual(
            DiagramNotice.make(scrubbed: ["image", "@src"], cspViolations: [], measurementFallbacks: [])?.reasons,
            [.remoteContentBlocked]
        )
        XCTAssertEqual(
            DiagramNotice.make(scrubbed: [], cspViolations: ["img-src<-https://example.com/a.png"], measurementFallbacks: [])?.reasons,
            [.remoteContentBlocked]
        )
        XCTAssertEqual(
            DiagramNotice.make(scrubbed: ["foreignObject"], cspViolations: [], measurementFallbacks: [])?.reasons,
            [.labelsDropped],
            "mermaid parks maths in a foreignObject, and the sweep takes the label with it"
        )
        XCTAssertEqual(
            DiagramNotice.make(scrubbed: [], cspViolations: [], measurementFallbacks: ["viewbox", "bbox"])?.reasons,
            [.sizeEstimated]
        )
        XCTAssertEqual(
            DiagramNotice.make(
                scrubbed: ["image", "foreignobject"],
                cspViolations: [],
                measurementFallbacks: ["viewbox", "bbox"]
            )?.reasons,
            [.remoteContentBlocked, .labelsDropped, .sizeEstimated],
            "always in declaration order"
        )
    }

    func testTheNoticeKeepsTheEngineWordsForTheSmallPrint() {
        let notice = try? XCTUnwrap(
            DiagramNotice.make(scrubbed: ["image"], cspViolations: ["img-src<-x"], measurementFallbacks: ["viewbox"])
        )
        XCTAssertEqual(notice?.details, ["image", "img-src<-x", "viewbox"])
    }

    func testARenderResultDerivesItsOwnNotice() {
        let plain = MermaidRenderResult(
            svg: "<svg/>", diagramType: "flowchart-v2", width: 10, height: 10,
            scrubbed: ["@onclick"], durationMS: 1
        )
        XCTAssertNil(plain.notice)

        let estimated = MermaidRenderResult(
            svg: "<svg/>", diagramType: "info", width: 10, height: 10,
            scrubbed: [], durationMS: 1, cspViolations: [],
            measurementFallbacks: ["viewbox", DiagramNotice.estimatedSizeMarker]
        )
        XCTAssertEqual(estimated.notice?.reasons, [.sizeEstimated])
    }

    func testTheGlueReportsTheMeasurementItHadToFallBackOn() throws {
        let json = """
        {"ok":true,"diagramType":"info","width":220,"height":80,"scrubbed":[],"svg":"<svg/>",
         "durationMS":4,"measurementFallbacks":["viewbox","bbox"]}
        """
        let result = try MermaidGlueDecoder.result(from: json, sourceUTF16Count: 4)
        XCTAssertEqual(result.measurementFallbacks, ["viewbox", "bbox"])
        XCTAssertEqual(result.notice?.reasons, [.sizeEstimated])
    }

    // MARK: - Helpers

    private static let allErrors: [MermaidRenderError] = [
        .engineMissing,
        .engineNotReady,
        .webContentTerminated,
        .navigationFailed("NSURLErrorDomain -1"),
        .inputTooLarge(utf16: 120_001, limit: 100_000),
        .unknownDiagramType("No diagram type detected matching given configuration for text: zenuml"),
        .parseFailure(message: "Parse error on line 1", line: nil),
        .parseFailure(message: "Parse error on line 1", line: 1),
        .edgeLimitExceeded(message: "Edge limit exceeded. 2001 edges found, but the limit is 2000."),
        .renderProducedNoSVG,
        .timedOut(seconds: 8),
        .internalFailure("payload is not valid JSON"),
    ]

    private static func catalog(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FlowPeek/Resources/\(language).lproj/Localizable.strings")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let data = Data(contents.utf8)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    /// `%@`, `%ld`, `%1$ld` … — the arguments `String(format:)` will go looking for.
    private static func formatSpecifiers(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(\\d+\\$)?[@a-zA-Z]+")
        let range = NSRange(value.startIndex..., in: value)
        return pattern.matches(in: value, range: range).map { (value as NSString).substring(with: $0.range) }
    }
}
