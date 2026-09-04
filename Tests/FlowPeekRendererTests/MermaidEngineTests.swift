import AppKit
import FlowPeekCore
import WebKit
import XCTest

@testable import FlowPeek

/// engine_spec §9 T1/T2/T6, driven through the production pool, page, glue and content world.
/// Everything here is headless: no user interaction, no network, no file base URL.
@MainActor
final class MermaidEngineTests: XCTestCase {
    // MARK: - T2, the conformance table

    /// One row per diagram type, checked in so a re-vendored `mermaid.min.js` that drops or renames
    /// a type fails loudly. `expected` is mermaid's own detected id, not FlowPeek's guess.
    static let conformanceTable: [(type: String, source: String)] = [
        ("flowchart-v2", "flowchart TD\n  A[Start] --> B[End]"),
        ("flowchart-v2", "graph LR\n  A --> B"),
        ("sequence", "sequenceDiagram\n  Alice->>John: Hello John"),
        ("classDiagram", "classDiagram\n  Animal <|-- Duck"),
        ("stateDiagram", "stateDiagram-v2\n  [*] --> Still\n  Still --> [*]"),
        ("er", "erDiagram\n  CUSTOMER ||--o{ ORDER : places"),
        ("gantt", "gantt\n  title A Gantt\n  dateFormat YYYY-MM-DD\n  section Section\n  A task :a1, 2024-01-01, 30d"),
        ("pie", "pie title Pets\n  \"Dogs\" : 386\n  \"Cats\" : 85"),
        ("journey", "journey\n  title My working day\n  section Go to work\n    Make tea: 5: Me"),
        (
            "quadrantChart",
            "quadrantChart\n  title Reach and engagement\n  x-axis Low Reach --> High Reach\n"
                + "  y-axis Low Influence --> High Influence\n  Campaign A: [0.3, 0.6]"
        ),
        (
            "requirement",
            "requirementDiagram\n  requirement test_req {\n  id: 1\n  text: the test text.\n"
                + "  risk: high\n  verifymethod: test\n  }"
        ),
        ("gitGraph", "gitGraph\n  commit\n  commit"),
        ("mindmap", "mindmap\n  root((mermaid))\n    Origins"),
        ("timeline", "timeline\n  title History of Social Media\n  2002 : LinkedIn"),
        ("kanban", "kanban\n  Todo\n    [Create Roadmap]"),
        ("sankey", "sankey-beta\n\nAgricultural waste,Bio-conversion,124.729"),
        (
            "xychart",
            "xychart-beta\n  title \"Sales\"\n  x-axis [jan, feb]\n  y-axis \"Revenue\" 0 --> 10\n  bar [5, 7]"
        ),
        ("block", "block-beta\n  columns 1\n  A"),
        ("packet", "packet-beta\n  title Packet\n  0-15: \"Source Port\"\n  16-31: \"Destination Port\""),
        ("architecture", "architecture-beta\n  group api(cloud)[API]\n  service db(database)[Database] in api"),
        ("treemap", "treemap-beta\n\"Root\"\n  \"A\": 10\n  \"B\": 20"),
        ("c4", "C4Context\n  title System Context\n  Person(customerA, \"Banking Customer A\")"),
        ("flowchart-elk", "flowchart-elk TD\n  A[Start] --> B[End]"),
        ("swimlane", "swimlane-beta TD\n  A[Start] --> B[End]"),
        ("eventmodeling", "eventmodeling\n  tf 1 cmd PlaceOrder"),
        ("treeView", "treeView-beta\n  Root\n    Child"),
        ("radar", "radar-beta\n  axis a, b, c\n  curve c1{1, 2, 3}"),
        ("ishikawa", "ishikawa-beta\n  Effect\n    Cause"),
        ("railroad", "railroad-beta\n  A = terminal(\"b\");"),
        ("railroadEbnf", "railroad-ebnf-beta\n  A = \"b\";"),
        ("railroadAbnf", "railroad-abnf-beta\n  A = \"b\";"),
        ("railroadPeg", "railroad-peg-beta\n  A <- \"b\";"),
        ("venn", "venn-beta\n  set A\n  set B"),
        ("wardley", "wardley-beta\n  component X [0.5, 0.5]"),
        ("cynefin", "cynefin-beta\n  clear\n    \"Best practice\""),
        // `info` is deliberately absent: it renders a version banner whose SVG carries no viewBox
        // attribute at all, so the glue's own width/height post-condition rejects it as "nothing
        // drawn". It is unreachable from the shipping trigger — MermaidDetector rates a lone `info`
        // `.weak` and AppState gates at `.likely` — so it can never produce a blank panel.
    ]

    // MARK: - T1

    func testFlowchartRendersInlineSVGWithRealGeometry() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let result = try await engine.render(Self.request("flowchart TD\n  A[Start] --> B[End]"))
        XCTAssertEqual(result.diagramType, "flowchart-v2")
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        XCTAssertTrue(result.scrubbed.isEmpty, "a benign diagram must need no scrubbing: \(result.scrubbed)")
        XCTAssertEqual(result.cspViolations, [])

        // *** The assertion that would have failed loudly on securityLevel 'sandbox' (IFRAME). ***
        let tag = try await engine.evaluate(
            "return String(document.getElementById('diagram').firstElementChild.tagName).toLowerCase();"
        ) as? String
        XCTAssertEqual(tag, "svg")

        let styles = try await engine.evaluate(
            "return document.getElementById('diagram').querySelectorAll('style').length;"
        ) as? Int
        XCTAssertEqual(styles, 1, "mermaid ships its whole theme as exactly one <style> inside the SVG")
    }

    /// The pixel assertion: a DOM check cannot tell a painted diagram from an invisible one.
    /// The sandbox bug scored 0 here.
    func testRenderedFlowchartActuallyPaintsPixels() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.evict(engine) }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow is released when closed, which ARC then releases again —
        // measured as an EXC_BAD_ACCESS in `-[_NSWindowTransformAnimation dealloc]` on the next test
        // that spins the run loop, taking the whole test host down.
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(engine.webView)
        engine.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        engine.webView.underPageBackgroundColor = .white
        window.orderFrontRegardless()
        defer {
            engine.webView.removeFromSuperview()
            window.orderOut(nil)
        }

        _ = try await engine.render(Self.request("flowchart TD\n  A[Start] --> B[End]"))
        try await Task.sleep(for: .milliseconds(400))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = engine.webView.bounds
        let image = try await engine.webView.takeSnapshot(configuration: configuration)

        let painted = Self.nonBackgroundPixels(image)
        XCTAssertGreaterThan(painted, 500, "the stage rendered \(painted) non-background pixels")
    }

    func testEngineAndGlueAreInvisibleToThePageWorld() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let inWorld = try await engine.evaluate("return typeof window.mermaid + '/' + typeof window.__flowpeek;") as? String
        XCTAssertEqual(inWorld, "object/object")

        let inPage = try await engine.webView.callAsyncJavaScript(
            "return typeof window.mermaid + '/' + typeof window.__flowpeek;",
            in: nil,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(inPage, "undefined/undefined")
    }

    // MARK: - T2

    func testEveryDiagramTypeInTheConformanceTableRenders() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        var failures: [String] = []
        for row in Self.conformanceTable {
            do {
                let result = try await engine.render(Self.request(row.source))
                if result.diagramType != row.type {
                    failures.append("\(row.type): detected as \(result.diagramType)")
                }
                if result.width <= 0 || result.height <= 0 {
                    failures.append("\(row.type): empty geometry \(result.width)x\(result.height)")
                }
                if !result.cspViolations.isEmpty {
                    failures.append("\(row.type): CSP violations \(result.cspViolations)")
                }
            } catch {
                failures.append("\(row.type): \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(failures, [], "conformance table drift:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - T5, the adversarial corpus

    /// engine_spec §9 T5. Every row must *render* — containment that works by failing to draw is not
    /// containment — and then leave nothing loadable, executable or navigable in the live DOM.
    static let adversarialCorpus: [(label: String, source: String)] = [
        ("img-onerror-label", "flowchart TD\n  A[\"<img src=x onerror=alert(1)>\"] --> B[ok]"),
        ("script-tag-label", "flowchart TD\n  A[\"<script>alert(1)</script>\"] --> B[ok]"),
        ("click-javascript-url", "flowchart TD\n  A --> B\n  click A \"javascript:alert(1)\""),
        ("click-href-external", "flowchart TD\n  A --> B\n  click A href \"https://evil.example/\" _blank"),
        ("init-html-labels", "%%{init:{'htmlLabels':true}}%%\nflowchart TD\n  A[\"<b>bold</b>\"] --> B[ok]"),
        (
            "init-security-loose",
            "%%{init:{'securityLevel':'loose'}}%%\nflowchart TD\n  A --> B\n  click A \"javascript:alert(1)\""
        ),
        ("style-element-breakout", "flowchart TD\n  A[\"</style><style>*{display:none}</style>\"] --> B[ok]"),
        ("img-data-url-label", "flowchart TD\n  A[\"<img src='data:image/svg+xml;base64,AAAA'>\"] --> B[ok]"),
        ("svg-image-external-href", "flowchart TD\n  A[\"<image href='https://evil.example/x.png'/>\"] --> B[ok]"),
        (
            "frontmatter-security-sandbox",
            "---\nconfig:\n  securityLevel: sandbox\n  htmlLabels: true\n---\nflowchart TD\n  A[\"<b>x</b>\"] --> B[ok]"
        ),
    ]

    private struct DOMAudit: Decodable {
        let tags: [String: Int]
        let offendingAttributes: [String]
        let securityLevel: String?
        let htmlLabels: Bool?
        let rootTag: String?
    }

    /// Walks the LIVE `#diagram` subtree — not the returned string — because what the user sees is
    /// what is attached. `<style>` is counted, not banned: mermaid ships the whole theme as one.
    private static let auditScript = """
    var root = document.getElementById('diagram');
    var live = root.firstElementChild;
    var tags = {};
    var offending = [];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    while (walker.nextNode()) {
      var el = walker.currentNode;
      var name = String(el.localName || el.tagName).toLowerCase();
      tags[name] = (tags[name] || 0) + 1;
      var attrs = Array.prototype.slice.call(el.attributes || []);
      for (var i = 0; i < attrs.length; i++) {
        var n = attrs[i].name.toLowerCase();
        var v = (attrs[i].value || '').trim();
        if (n.indexOf('on') === 0) { offending.push(name + '@' + n); continue; }
        if ((n === 'href' || n === 'xlink:href' || n === 'src' || n === 'from' || n === 'to') && v.charAt(0) !== '#') {
          offending.push(name + '@' + n + '=' + v);
          continue;
        }
        if (n === 'style' && /url\\s*\\(\\s*(?!#)/i.test(v)) { offending.push(name + '@style-url'); }
      }
    }
    var cfg = mermaid.mermaidAPI.getConfig();
    return JSON.stringify({
      tags: tags,
      offendingAttributes: offending,
      securityLevel: cfg.securityLevel,
      htmlLabels: cfg.htmlLabels,
      rootTag: live ? String(live.localName || live.tagName).toLowerCase() : null
    });
    """

    func testTheAdversarialCorpusLeavesNothingExecutableInTheLiveDOM() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        var failures: [String] = []
        for row in Self.adversarialCorpus {
            do {
                let result = try await engine.render(Self.request(row.source))
                if !result.cspViolations.isEmpty {
                    failures.append("\(row.label): CSP violations \(result.cspViolations)")
                }
                guard let json = try await engine.evaluate(Self.auditScript) as? String,
                      let audit = try? JSONDecoder().decode(DOMAudit.self, from: Data(json.utf8)) else {
                    failures.append("\(row.label): the DOM audit did not return JSON")
                    continue
                }
                for banned in ["a", "image", "img", "foreignobject", "script", "iframe", "object", "embed", "link", "meta"]
                where audit.tags[banned] != nil {
                    failures.append("\(row.label): \(audit.tags[banned]!) surviving <\(banned)>")
                }
                if audit.tags["style"] != 1 {
                    failures.append("\(row.label): \(audit.tags["style"] ?? 0) <style> elements, expected exactly 1")
                }
                if !audit.offendingAttributes.isEmpty {
                    failures.append("\(row.label): offending attributes \(audit.offendingAttributes)")
                }
                if audit.rootTag != "svg" {
                    failures.append("\(row.label): #diagram holds \(audit.rootTag ?? "nothing"), not an <svg>")
                }
                if audit.securityLevel != "strict" {
                    failures.append("\(row.label): securityLevel became \(audit.securityLevel ?? "nil")")
                }
                if audit.htmlLabels != false {
                    failures.append("\(row.label): htmlLabels became \(String(describing: audit.htmlLabels))")
                }
            } catch {
                // A hostile source that cannot render proves nothing about the scrub, so it is a failure.
                failures.append("\(row.label): did not render — \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(failures, [], "adversarial corpus breach:\n" + failures.joined(separator: "\n"))
    }

    /// The `secure` list at flowpeek-glue.js:9 is the only thing standing between an untrusted
    /// `%%{init:…}%%` and re-enabled foreignObject labels, so assert the key set itself, not a substring.
    func testUntrustedDirectivesCannotReopenTheSecuredConfigurationKeys() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        _ = try await engine.render(Self.request(
            "%%{init:{'htmlLabels':true,'securityLevel':'loose','theme':'forest','themeCSS':'*{display:none}',"
                + "'fontFamily':'cursive','look':'handDrawn','layout':'elk','secure':[]}}%%\nflowchart TD\n  A --> B"
        ))

        let json = try await engine.evaluate(
            """
            var cfg = mermaid.mermaidAPI.getConfig();
            return JSON.stringify({
              secure: cfg.secure,
              securityLevel: cfg.securityLevel,
              htmlLabels: cfg.htmlLabels,
              theme: cfg.theme,
              fontFamily: cfg.fontFamily,
              look: cfg.look,
              layout: cfg.layout
            });
            """
        ) as? String
        let audit = try XCTUnwrap(json.map { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])

        let secure = try XCTUnwrap(audit["secure"] as? [String])
        for key in ["htmlLabels", "theme", "themeVariables", "themeCSS", "fontFamily", "altFontFamily", "layout", "look"] {
            XCTAssertTrue(secure.contains(key), "`\(key)` fell out of the secure list: \(secure)")
        }
        XCTAssertEqual(audit["securityLevel"] as? String, "strict")
        XCTAssertEqual(audit["htmlLabels"] as? Bool, false)
        XCTAssertEqual(audit["theme"] as? String, "base")
        XCTAssertEqual(audit["fontFamily"] as? String, MacMermaidTheme.systemFontStack)
        XCTAssertNotEqual(audit["look"] as? String, "handDrawn")
        XCTAssertNotEqual(audit["layout"] as? String, "elk")
    }

    // MARK: - T3, golden snapshots

    /// engine_spec §9 T3. `deterministicIds: true` plus a fixed seed is what makes render output
    /// byte-stable, so the goldens are the only thing that actually proves it: a theme regression, a
    /// DOMPurify behaviour change or an accidental `<style>` removal all land as a diff.
    /// The accent is pinned here — `MermaidThemeFactory.current` reads the user's own accent colour
    /// and would make every golden machine-specific.
    static func goldenTheme(_ variant: GoldenVariant) -> MacMermaidTheme {
        MacMermaidTheme(
            appearance: variant.appearance,
            accentHex: "#0A84FF",
            increaseContrast: variant.increaseContrast
        )
    }

    enum GoldenVariant: String, CaseIterable {
        case light, lightContrast = "light-contrast", dark, darkContrast = "dark-contrast"

        var appearance: MacMermaidTheme.Appearance { self == .dark || self == .darkContrast ? .dark : .light }
        var increaseContrast: Bool { self == .lightContrast || self == .darkContrast }
    }

    static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FlowPeekRendererTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/golden")

    /// Generated ids and one wall-clock artefact are normalised; nothing about theming, geometry or
    /// structure is. Namely: FlowPeek's own outer render id; the random suffix Iconify mints per call
    /// for architecture-beta icon paths (`IconifyId1a06a9a77cb3e0b550`); and gantt's `today` marker,
    /// whose `x1`/`x2` are derived from `Date.now()` and drift about one unit per eight minutes
    /// (measured `x1="20701"` then `x1="20702"`). Everything else in the gantt stays under diff.
    static func normalised(_ svg: String) -> String {
        svg
            .replacingOccurrences(of: "fp-[0-9]+", with: "fp-N", options: .regularExpression)
            .replacingOccurrences(of: "IconifyId[0-9a-z]+", with: "IconifyId-N", options: .regularExpression)
            .replacingOccurrences(
                of: "<g class=\"today\">.*?</g>",
                with: "<g class=\"today\">TODAY</g>",
                options: .regularExpression
            )
    }

    /// Types mermaid 11.17.2 cannot render byte-stably even with `deterministicIds` and a fixed seed,
    /// measured over repeated recordings in one process:
    /// - `classDiagram`, `requirement` and `cynefin` draw their outlines with a jittered
    ///   hand-drawn stroke whose PRNG is not reseeded per render, so the `d=` control points move with
    ///   how many diagrams the JS context drew before them (measured: `cynefinBoundary` starting at
    ///   x=401.580 in one context and x=400.294 in another, ±8 chars per file).
    /// - `gitGraph` reports a different `viewBox` height on each render (measured 86.038 vs 87.198).
    /// They stay in the conformance table (T2 proves they render); only the golden diff skips them.
    static let goldenExclusions: Set<String> = ["classDiagram", "requirement", "gitGraph", "cynefin"]

    /// Table rows are keyed by type, disambiguated by occurrence so the two flowchart-v2 rows get
    /// their own goldens without depending on the row index.
    static var goldenKeys: [String] {
        var seen: [String: Int] = [:]
        return conformanceTable.map { row in
            seen[row.type, default: 0] += 1
            let count = seen[row.type]!
            return count == 1 ? row.type : "\(row.type)-\(count)"
        }
    }

    func testRenderOutputIsByteStableAcrossRepeatedRenders() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let source = "flowchart TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[End]\n  B -->|no| A"
        let first = try await engine.render(Self.goldenRequest(source, .light))
        let second = try await engine.render(Self.goldenRequest(source, .light))
        XCTAssertEqual(
            Self.normalised(first.svg),
            Self.normalised(second.svg),
            "the same source and seed rendered two different SVGs — deterministicIds is not doing its job"
        )
        XCTAssertGreaterThan(first.svg.count, 500)
    }

    /// The golden exclusions are a measured fact about mermaid, not a place to park a failing type:
    /// every excluded type must still be in the conformance table, and every one must still be unstable.
    func testTheGoldenExclusionsAreStillJustified() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let types = Set(Self.conformanceTable.map(\.type))
        XCTAssertTrue(Self.goldenExclusions.isSubset(of: types), "an excluded type left the conformance table")

        for row in Self.conformanceTable where Self.goldenExclusions.contains(row.type) {
            let first = Self.normalised(try await engine.render(Self.goldenRequest(row.source, .light)).svg)
            let second = Self.normalised(try await engine.render(Self.goldenRequest(row.source, .light)).svg)
            XCTAssertNotEqual(
                first,
                second,
                "\(row.type) renders byte-stably now — drop it from goldenExclusions and record its goldens"
            )
        }
    }

    /// Re-record every golden with `TEST_RUNNER_FLOWPEEK_RECORD_GOLDEN=1 xcodebuild … test` (xcodebuild
    /// forwards only `TEST_RUNNER_`-prefixed variables into the test process). That is the correct
    /// response to a deliberate mermaid re-vendor or theme change — and the wrong response to an
    /// unexplained diff. Recording always fails the test so a re-record can never pass unnoticed.
    func testGoldenSVGsMatchTheCheckedInSnapshots() async throws {
        // A dedicated pool, so the goldens depend only on this test's own render sequence. mermaid's
        // deterministic id generator advances per render within a view, so a view that other tests had
        // already rendered into produces different — still deterministic — inner ids.
        let pool = MermaidWebViewPool()
        let engine = try pool.checkOut()
        defer { pool.evict(engine) }

        let recording = ProcessInfo.processInfo.environment["FLOWPEEK_RECORD_GOLDEN"] == "1"
        if recording {
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
        }

        var failures: [String] = []
        let keys = Self.goldenKeys
        for variant in GoldenVariant.allCases {
            for (index, row) in Self.conformanceTable.enumerated() where !Self.goldenExclusions.contains(row.type) {
                let name = "\(keys[index]).\(variant.rawValue).svg"
                let url = Self.goldenDirectory.appendingPathComponent(name)
                let rendered: String
                do {
                    rendered = Self.normalised(try await engine.render(Self.goldenRequest(row.source, variant)).svg) + "\n"
                } catch {
                    failures.append("\(name): did not render — \(error.localizedDescription)")
                    continue
                }
                if recording {
                    try rendered.write(to: url, atomically: true, encoding: .utf8)
                    continue
                }
                guard let golden = try? String(contentsOf: url, encoding: .utf8) else {
                    failures.append("\(name): no golden checked in; re-run with FLOWPEEK_RECORD_GOLDEN=1")
                    continue
                }
                if golden != rendered {
                    failures.append("\(name): differs from the golden (\(golden.count) vs \(rendered.count) chars)")
                }
            }
        }
        if recording {
            XCTFail("goldens re-recorded; unset FLOWPEEK_RECORD_GOLDEN and re-run to verify")
        }
        XCTAssertEqual(failures, [], "golden drift:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - T6

    func testSyntaxErrorReportsItsLine() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let error = await Self.failure(of: engine, "graph TD;A--->>>>B[[")
        guard case .parseFailure(let message, let line) = error else {
            return XCTFail("expected a parse failure, got \(String(describing: error))")
        }
        XCTAssertEqual(line, 1)
        XCTAssertTrue(message.contains("Parse error on line 1"), message)
        Self.assertSpecific(error)

        let empty = try await engine.evaluate("return document.getElementById('diagram').children.length;") as? Int
        XCTAssertEqual(empty, 0, "a failed render must leave #diagram empty, never half-written")
    }

    func testUnknownDiagramTypeIsNamed() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let error = await Self.failure(of: engine, "zenuml\n  Alice->Bob: hi")
        guard case .unknownDiagramType(let message) = error else {
            return XCTFail("expected an unknown-type failure, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("No diagram type detected"), message)
        Self.assertSpecific(error)
    }

    func testEdgeLimitSurfacesMermaidsOwnMessage() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let edges = (0...MermaidRenderLimits.engineMaximumEdges).map { "  A\($0) --> B\($0)" }.joined(separator: "\n")
        let error = await Self.failure(of: engine, "flowchart TD\n" + edges)
        guard case .edgeLimitExceeded(let message) = error else {
            return XCTFail("expected an edge-limit failure, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("Edge limit exceeded"), message)
        Self.assertSpecific(error)
    }

    func testOversizeSourceIsRejectedBeforeItReachesJavaScript() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        let source = "flowchart TD\n" + String(repeating: "x", count: MermaidRenderLimits.maximumSourceUTF16)
        let error = await Self.failure(of: engine, source)
        guard case .inputTooLarge = error else {
            return XCTFail("expected an input-too-large failure, got \(String(describing: error))")
        }
        Self.assertSpecific(error)
    }

    /// The watchdog: a render that never resolves must become `.timedOut`, and its view must be
    /// poisoned so it is never handed out again.
    func testAStalledRenderTimesOutAndPoisonsItsView() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.evict(engine) }

        // The resolver is parked in a global so WebKit cannot collect the promise and resolve the
        // call early with "Completion handler for function call is no longer reachable".
        _ = try await engine.evaluate(
            "window.__stalled = []; window.__flowpeek.render = function () {"
                + " return new Promise(function (resolve) { window.__stalled.push(resolve); }); };"
        )
        let started = Date()
        let error = await Self.failure(of: engine, "flowchart TD\n  A --> B")
        guard case .timedOut(let seconds) = error else {
            return XCTFail("expected a timeout, got \(String(describing: error))")
        }
        XCTAssertEqual(seconds, MermaidRenderLimits.timeoutSeconds)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), Double(MermaidRenderLimits.timeoutSeconds) - 1)
        let poisoned = engine.isPoisoned
        XCTAssertTrue(poisoned)
        Self.assertSpecific(error)
    }

    /// A genuine WebKit-level JS fault must carry the thrown message, never WebKit's fixed
    /// "A JavaScript exception occurred" — the string that made the original bug undiagnosable.
    func testJavaScriptFaultsCarryTheirOwnMessage() async throws {
        let engine = try Self.pool.checkOut()
        defer { Self.pool.checkIn(engine) }

        do {
            _ = try await engine.evaluate("throw new Error('boom from the glue');")
            XCTFail("the evaluation should have thrown")
        } catch {
            let mapped = MermaidRenderError.javaScriptException(error)
            XCTAssertTrue(
                mapped.localizedDescription.contains("boom from the glue"),
                mapped.localizedDescription
            )
            Self.assertSpecific(mapped)
        }
    }

    // MARK: - Self-test

    func testSelfTestReportsAHealthyEngine() async throws {
        let result = await Self.pool.runSelfTest(theme: MermaidThemeFactory.current(.light))
        XCTAssertEqual(result.status, .healthy, "self-test said: \(result.menuDescription ?? "healthy")")
        XCTAssertTrue(result.isUsable)
        XCTAssertGreaterThan(result.warmupMS, 0)
    }

    // MARK: - Helpers

    private static let pool = MermaidWebViewPool()
    private static var counter: UInt64 = 0

    private static func request(_ source: String) -> MermaidRenderRequest {
        counter += 1
        return MermaidRenderRequest(
            source: source,
            theme: MermaidThemeFactory.current(.light),
            seed: "flowpeek-tests",
            renderID: MermaidRenderIdentifier.renderID(counter)
        )
    }

    /// A golden render: pinned theme, pinned seed. Only `renderID` moves, and `normalised` erases it.
    static func goldenRequest(_ source: String, _ variant: GoldenVariant) -> MermaidRenderRequest {
        counter += 1
        return MermaidRenderRequest(
            source: source,
            theme: goldenTheme(variant),
            seed: "flowpeek-golden",
            renderID: MermaidRenderIdentifier.renderID(counter)
        )
    }

    private static func failure(of engine: MermaidEngineView, _ source: String) async -> MermaidRenderError? {
        do {
            let result = try await engine.render(request(source))
            XCTFail("expected a failure, rendered \(result.diagramType) instead")
            return nil
        } catch {
            return error
        }
    }

    /// engine_spec §9 T6: no path may ever surface WebKit's generic placeholder.
    private static func assertSpecific(_ error: MermaidRenderError?) {
        guard let error else { return XCTFail("no error to inspect") }
        let description = error.localizedDescription
        XCTAssertFalse(description.isEmpty)
        XCTAssertFalse(
            description.contains(MermaidRenderError.genericJavaScriptExceptionMessage),
            "\(error) surfaced WebKit's generic exception string"
        )
    }

    private static func nonBackgroundPixels(_ image: NSImage) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var painted = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where
            pixels[index] < 240 || pixels[index + 1] < 240 || pixels[index + 2] < 240 {
            painted += 1
        }
        return painted
    }
}
