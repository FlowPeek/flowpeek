import XCTest
@testable import FlowPeekCore

final class MermaidRendererTests: XCTestCase {

    // MARK: - Page and CSP invariants

    func testContentSecurityPolicyGrantsNoScriptSourceAndNoFrameSource() {
        let csp = MermaidEnginePage.contentSecurityPolicy
        XCTAssertEqual(
            csp,
            "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        )
        XCTAssertFalse(csp.contains("script-src"), "script-src must stay absent; the engine arrives as a user script")
        XCTAssertFalse(csp.contains("frame-src"), "frame-src is only needed by securityLevel 'sandbox', which we never use")
        XCTAssertFalse(csp.contains("unsafe-eval"))
        XCTAssertFalse(csp.contains("img-src"))
        for directive in ["default-src 'none'", "style-src 'unsafe-inline'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"] {
            XCTAssertTrue(csp.contains(directive), "missing \(directive)")
        }
    }

    func testEnginePageCarriesNoScriptTagOfAnyKind() {
        let html = MermaidEnginePage.html
        XCTAssertFalse(html.lowercased().contains("<script"), "the page must never load or inline a script")
        XCTAssertFalse(html.lowercased().contains("src="), "the page must have no subresource of any kind")
        XCTAssertTrue(html.contains(MermaidEnginePage.contentSecurityPolicy))
        XCTAssertTrue(html.contains("id=\"stage\""))
        XCTAssertTrue(html.contains("id=\"diagram\""))
        XCTAssertTrue(html.contains("id=\"error\""))
        XCTAssertLessThan(html.utf8.count, 1200, "the inline page should stay tiny")
    }

    // MARK: - Errors

    private var allErrors: [MermaidRenderError] {
        [
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
    }

    func testEveryErrorCaseHasItsOwnSpecificDescription() {
        var seen: Set<String> = []
        for error in allErrors {
            guard let description = error.errorDescription else {
                return XCTFail("\(error) has no errorDescription")
            }
            XCTAssertFalse(description.isEmpty, "\(error) has an empty errorDescription")
            XCTAssertNotEqual(description, MermaidRenderError.genericJavaScriptExceptionMessage)
            XCTAssertTrue(seen.insert(description).inserted, "\(error) reuses another case's description: \(description)")
        }
        XCTAssertEqual(seen.count, allErrors.count)
    }

    func testEveryErrorCaseUsesADeclaredLocalizationKey() {
        let declared = Set(MermaidRenderError.localizationKeys)
        for error in allErrors {
            XCTAssertTrue(declared.contains(error.localizationKey), "undeclared key \(error.localizationKey)")
        }
        XCTAssertEqual(declared.count, MermaidRenderError.localizationKeys.count, "duplicate key in localizationKeys")
    }

    func testEveryLocalizationKeyIsTranslatedInBothCatalogs() throws {
        for language in ["en", "ko"] {
            let url = Self.repositoryRoot
                .appendingPathComponent("Sources/FlowPeek/Resources/\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: url, encoding: .utf8)
            for key in MermaidRenderError.localizationKeys + ["mermaid.engine.degraded", "mermaid.engine.broken"] {
                XCTAssertTrue(contents.contains("\"\(key)\" = "), "\(language).lproj is missing \(key)")
            }
        }
    }

    func testJavaScriptExceptionNeverSurfacesWebKitsGenericMessage() {
        let generic = NSError(
            domain: "WKErrorDomain",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: MermaidRenderError.genericJavaScriptExceptionMessage]
        )
        XCTAssertEqual(MermaidRenderError.javaScriptException(generic), .internalFailure("WKErrorDomain 4"))

        let detailed = NSError(
            domain: "WKErrorDomain",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey: MermaidRenderError.genericJavaScriptExceptionMessage,
                "WKJavaScriptExceptionMessage": "TypeError: undefined is not an object",
            ]
        )
        XCTAssertEqual(MermaidRenderError.javaScriptException(detailed), .internalFailure("TypeError: undefined is not an object"))
    }

    // MARK: - Payload encoding

    func testPayloadCarriesEverythingTheGlueReads() throws {
        let theme = MacMermaidTheme(appearance: .dark, accentHex: "#0A84FF", increaseContrast: false)
        let request = MermaidRenderRequest(
            source: "flowchart TD\n  A --> B",
            theme: theme,
            seed: "fp-seed",
            renderID: "fp-7"
        )
        let json = try request.payloadJSON()
        let decoded = try JSONDecoder().decode(MermaidRenderPayload.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.source, "flowchart TD\n  A --> B")
        XCTAssertEqual(decoded.renderID, "fp-7")
        XCTAssertEqual(decoded.seed, "fp-seed")
        XCTAssertEqual(decoded.fontFamily, MacMermaidTheme.systemFontStack)
        XCTAssertEqual(decoded.themeVariables["primaryColor"], "#2C2C2E")
        XCTAssertEqual(decoded.themeCSS, theme.css)
        XCTAssertEqual(try request.payloadJSON(), json, "payload encoding must be deterministic")
    }

    func testPayloadEncodingEnforcesTheSwiftSideGates() {
        let theme = MacMermaidTheme(appearance: .light, accentHex: "#007AFF", increaseContrast: false)
        func request(_ source: String) -> MermaidRenderRequest {
            MermaidRenderRequest(source: source, theme: theme, seed: "s", renderID: "fp-1")
        }

        // UTF-16 units, not grapheme clusters: 60,000 emoji are 120,000 units.
        let emoji = String(repeating: "😀", count: 60_000)
        XCTAssertThrowsError(try request(emoji).payloadJSON()) {
            XCTAssertEqual($0 as? MermaidRenderError, .inputTooLarge(utf16: 120_000, limit: 100_000))
        }
        XCTAssertThrowsError(try request(String(repeating: "\n", count: 5_000)).payloadJSON()) {
            XCTAssertEqual($0 as? MermaidRenderError, .inputTooLarge(utf16: 5_001, limit: 5_000))
        }
        XCTAssertThrowsError(try request(String(repeating: "a", count: 20_001)).payloadJSON()) {
            XCTAssertEqual($0 as? MermaidRenderError, .inputTooLarge(utf16: 20_001, limit: 20_000))
        }
        XCTAssertNoThrow(try request("flowchart TD\n A-->B").payloadJSON())
    }

    func testRenderIdentifiersAreValidCSSIdentifiers() {
        let id = MermaidRenderIdentifier.renderID(42)
        XCTAssertEqual(id, "fp-42")
        XCTAssertFalse(id.first!.isNumber, "mermaid uses the id raw as \"#\" + id")
        let seed = MermaidRenderIdentifier.seed(for: UUID(uuidString: "8B6E1D26-6F0B-4C34-9F6E-0C4A1C0E4A11")!)
        XCTAssertEqual(seed, "fp-8b6e1d26-6f0b-4c34-9f6e-0c4a1c0e4a11")
    }

    // MARK: - Glue response decoding

    func testSuccessfulGlueResponseBecomesAResult() throws {
        let json = """
        {"ok":true,"diagramType":"flowchart-v2","width":118.109375,"height":326.109375,
         "scrubbed":[],"svg":"<svg id=\\"fp-1\\"></svg>","durationMS":7,"cspViolations":[]}
        """
        let result = try MermaidGlueDecoder.result(from: json, sourceUTF16Count: 24)
        XCTAssertEqual(result.diagramType, "flowchart-v2")
        XCTAssertEqual(result.width, 118.109375)
        XCTAssertEqual(result.height, 326.109375)
        XCTAssertEqual(result.durationMS, 7)
        XCTAssertTrue(result.scrubbed.isEmpty)
        XCTAssertTrue(result.cspViolations.isEmpty)
    }

    func testAZeroSizedSuccessIsTreatedAsAFailedRender() {
        // The exact shape the 'sandbox' bug produced: SUCCESS with nothing painted.
        let json = #"{"ok":true,"diagramType":"flowchart-v2","width":0,"height":0,"scrubbed":[],"svg":"","durationMS":3}"#
        assertThrows(json, sourceUTF16Count: 10, .renderProducedNoSVG)
    }

    func testEveryDocumentedGlueCodeMapsToItsTypedError() {
        assertThrows(#"{"ok":false,"code":"engine-missing","message":"not present"}"#, sourceUTF16Count: 4, .engineMissing)
        assertThrows(#"{"ok":false,"code":"engine-not-ready","message":"no #diagram"}"#, sourceUTF16Count: 4, .engineNotReady)
        assertThrows(#"{"ok":false,"code":"render-no-svg","message":"nothing was attached to #diagram"}"#, sourceUTF16Count: 4, .renderProducedNoSVG)
        assertThrows(
            #"{"ok":false,"code":"too-large","message":"mermaid substituted its size-limit placeholder"}"#,
            sourceUTF16Count: 120_500,
            .inputTooLarge(utf16: 120_500, limit: MermaidRenderLimits.maximumSourceUTF16)
        )
        assertThrows(
            #"{"ok":false,"code":"edge-limit","message":"Edge limit exceeded. 2000 edges found, but the limit is 2000."}"#,
            sourceUTF16Count: 40,
            .edgeLimitExceeded(message: "Edge limit exceeded. 2000 edges found, but the limit is 2000.")
        )
        assertThrows(
            #"{"ok":false,"code":"unknown-type","message":"No diagram type detected matching given configuration for text: zenuml"}"#,
            sourceUTF16Count: 6,
            .unknownDiagramType("No diagram type detected matching given configuration for text: zenuml")
        )
        assertThrows(
            #"{"ok":false,"code":"parse","message":"Parse error on line 1:","line":1}"#,
            sourceUTF16Count: 20,
            .parseFailure(message: "Parse error on line 1:", line: 1)
        )
        assertThrows(
            #"{"ok":false,"code":"parse","message":"Parse error"}"#,
            sourceUTF16Count: 20,
            .parseFailure(message: "Parse error", line: nil)
        )
        assertThrows(
            #"{"ok":false,"code":"internal","message":"payload is missing a source string"}"#,
            sourceUTF16Count: 0,
            .internalFailure("payload is missing a source string")
        )
    }

    func testAnUnrecognisedCodeStillProducesASpecificMessage() {
        do {
            _ = try MermaidGlueDecoder.result(
                from: #"{"ok":false,"code":"martian","message":"boom"}"#,
                sourceUTF16Count: 3
            )
            XCTFail("expected a failure")
        } catch {
            guard case .internalFailure(let message) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertTrue(message.contains("martian"), message)
            XCTAssertTrue(message.contains("boom"), message)
            XCTAssertNotEqual(message, MermaidRenderError.genericJavaScriptExceptionMessage)
        }
    }

    func testUndecodableJSONNamesItself() {
        do {
            _ = try MermaidGlueDecoder.result(from: "not json at all", sourceUTF16Count: 0)
            XCTFail("expected a failure")
        } catch {
            guard case .internalFailure(let message) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertTrue(message.contains("not json at all"), message)
        }
    }

    // MARK: - Health

    func testHealthyCanaryIsHealthyAndAnythingElseIsNot() {
        let healthy = MermaidGlueDecoder.health(
            from: #"{"ok":true,"diagramType":"flowchart-v2","width":85.4,"height":174,"scrubbed":[],"cspViolations":[],"engineVersion":null,"canaryMS":6}"#,
            warmupMS: 210
        )
        XCTAssertEqual(healthy.status, .healthy)
        XCTAssertEqual(healthy.warmupMS, 210)
        XCTAssertEqual(healthy.canaryMS, 6)
        XCTAssertTrue(healthy.isUsable)
        XCTAssertNil(healthy.menuDescription)

        let scrubbedCanary = MermaidGlueDecoder.health(
            from: #"{"ok":true,"diagramType":"flowchart-v2","width":85.4,"height":174,"scrubbed":["@href"],"cspViolations":["style-src-elem<-inline"],"canaryMS":6}"#,
            warmupMS: 0
        )
        guard case .degraded(let detail) = scrubbedCanary.status else { return XCTFail("expected degraded") }
        XCTAssertTrue(detail.contains("@href"), detail)
        XCTAssertTrue(detail.contains("style-src-elem<-inline"), detail)
        XCTAssertTrue(scrubbedCanary.isUsable)

        let broken = MermaidGlueDecoder.health(
            from: #"{"ok":false,"code":"engine-missing","message":"not present","canaryMS":1}"#,
            warmupMS: 0
        )
        XCTAssertEqual(broken.status, .broken(.engineMissing))
        XCTAssertFalse(broken.isUsable)
        XCTAssertNotNil(broken.menuDescription)

        let blank = MermaidGlueDecoder.health(from: #"{"ok":true,"diagramType":"flowchart-v2","width":0,"height":0}"#, warmupMS: 0)
        XCTAssertEqual(blank.status, .broken(.renderProducedNoSVG), "a canary with no pixels is broken, not healthy")
    }

    // MARK: - Fit

    func testFitScaleIsDrivenByTheViewBox() {
        let result = MermaidRenderResult(svg: "", diagramType: "flowchart-v2", width: 1000, height: 500, scrubbed: [], durationMS: 1)
        XCTAssertEqual(result.fitScale(in: CGSize(width: 572, height: 800)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.fitScale(in: CGSize(width: 4000, height: 4000)), 1, "never enlarge past 1")
        XCTAssertEqual(result.fitScale(in: CGSize(width: 40, height: 40)), 0.2, "clamped to DiagramViewport's floor")
    }

    // MARK: - The glue asset

    func testGlueSourceIsPresentAndHoldsItsContract() throws {
        let source = try String(contentsOf: Self.glueURL, encoding: .utf8)
        for needle in [
            "window.__flowpeek",
            "securitypolicyviolation",
            "securityLevel: \"strict\"",
            "htmlLabels: false",
            "suppressErrorRendering: true",
            "maxTextSize: 120000",
            "maxEdges: 2000",
            "deterministicIds: true",
            "\"text/html\"",
            "importNode",
            "replaceChildren",
            "SVGSVGElement",
            "Maximum text size in diagram exceeded",
            "e.hash && e.hash.loc && e.hash.loc.first_line",
            "function selfTest",
            "function setScale",
        ] {
            XCTAssertTrue(source.contains(needle), "flowpeek-glue.js is missing \(needle)")
        }
        XCTAssertFalse(source.contains("image/svg+xml"), "the XML parser rejects mermaid's undeclared xlink prefix")
        XCTAssertFalse(source.contains("sandbox"), "securityLevel 'sandbox' returns an iframe the CSP blocks")
        XCTAssertFalse(source.contains("suppressErrors:"), "parse() must throw so the message reaches Swift")
        XCTAssertTrue(source.contains("await mm.parse(p.source);"), "parse() must be called with no options object")

        // <style> must survive the scrub — removing it collapses the whole theme.
        let scrubList = try XCTUnwrap(source.range(of: "root.querySelectorAll(\"script,"))
        let line = source[scrubList.lowerBound...].prefix(while: { $0 != "\n" })
        XCTAssertFalse(line.contains("style,"), "the scrub must never remove <style>")
        XCTAssertTrue(line.contains("foreignObject"))

        for code in MermaidGlueCode.allCases {
            XCTAssertTrue(source.contains("\"\(code.rawValue)\""), "the glue never emits code \(code.rawValue)")
        }
    }

    func testGlueSourceParsesUnderNode() throws {
        guard let node = Self.nodeExecutable else {
            throw XCTSkip("node is not installed on this machine")
        }
        let process = Process()
        process.executableURL = node
        process.arguments = ["--check", Self.glueURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "node --check failed:\n\(output)")
    }

    // MARK: - Helpers

    private func assertThrows(
        _ json: String,
        sourceUTF16Count: Int,
        _ expected: MermaidRenderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try MermaidGlueDecoder.result(from: json, sourceUTF16Count: sourceUTF16Count)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FlowPeekCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root

    private static let glueURL = repositoryRoot
        .appendingPathComponent("Sources/FlowPeek/Resources/flowpeek-glue.js")

    private static let nodeExecutable: URL? = {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/node"
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }()
}
