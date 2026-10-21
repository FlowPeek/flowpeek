import XCTest
@testable import FlowPeekCore

/// The Editorial theme's second promise: that it draws a ladder, and that it spends its accent.
///
/// Every assertion in this class fails against the theme as it first shipped, which is the point.
/// That version was not wrong about the source's restraint -- it was monochrome because its node
/// fill and its node border were both `paper`, and because the coral only ever reached
/// `noteBkgColor`, which most previews never draw. Values, not appearances: what it looks like
/// needs eyes, but these are the claims that can be broken silently.
final class EditorialLadderTests: XCTestCase {
    private func theme(_ appearance: MacMermaidTheme.Appearance, contrast: Bool = false) -> MacMermaidTheme {
        MermaidThemeCatalogue.theme(
            .editorial, appearance: appearance, accentHex: "#FF00FF", increaseContrast: contrast
        )
    }

    private static let rungs = ["backend", "store", "entry", "terminal"]

    // MARK: - The bug that shipped

    /// The one that would have caught it. The accent existed as a token, was handed to the settings
    /// tile, and was never drawn on a diagram: nothing the theme set reached a drawn element.
    ///
    /// This used to also demand a focal rung and an accent edge in the stylesheet, and that half no
    /// longer describes what the renderer should do. Both were spent on a node and an edge the
    /// renderer picked by degree, not on anything the source named; measured, they fired on 8 of the
    /// 172 sweep drawings and 6 of the reader review's 16 sources, and the reviewer read five of the
    /// six as a claim ("this is the critical path") the source never made. So the accent is now
    /// asserted where an element the source itself declares carries it -- gantt's today line -- and
    /// asserted absent from the two flowchart classes the renderer used to invent.
    func testTheAccentIsActuallyDrawnOnTheDiagram() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let built = theme(appearance)
            XCTAssertEqual(
                built.variables["todayLineColor"], built.accent,
                "\(appearance): the accent reaches no drawn element, so nothing is ever drawn in it"
            )
            XCTAssertNil(rung("focal", built.css), "\(appearance): a renderer-chosen focal node is painted again")
            XCTAssertFalse(
                built.css.contains("fp-accent"),
                "\(appearance): a renderer-chosen accent edge is painted again"
            )
        }
    }

    /// And the other half of the same bug: the accent was spent on furniture. A diagram with five
    /// notes drew five coral outlines, which is the source's own "coral on every important node"
    /// anti-pattern with a machine behind it.
    func testFurnitureGivesTheAccentUp() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let built = theme(appearance)
            for key in [
                "noteBkgColor", "noteBorderColor", "activationBkgColor", "activationBorderColor",
                "errorBkgColor", "critBorderColor",
            ] {
                XCTAssertNotEqual(
                    built.variables[key], built.accent,
                    "\(key) is accent-coloured, and a diagram can contain any number of them"
                )
            }
        }
    }

    /// Nodes were paper on paper behind a 12% hairline: one surface where the source has five.
    func testANodeIsNoLongerTheSameColourAsThePage() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let built = theme(appearance)
            let paper = built.variables["background"]!
            XCTAssertNotEqual(built.variables["mainBkg"], paper, "a node is still the colour of the page")
            XCTAssertNotEqual(built.variables["primaryColor"], paper)
            XCTAssertFalse(
                built.variables["nodeBorder"]!.hasPrefix("rgba"),
                "a 12% border also paints ER relationship labels and the state end bullet"
            )
        }
    }

    // MARK: - The ladder

    func testEveryRungIsDefinedForEveryShapeMermaidCanDraw() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let css = theme(appearance).css
            for token in Self.rungs {
                for shape in [
                    "rect.basic", "circle.basic", "polygon.label-container",
                    "path.basic.label-container", "g.label-container circle",
                ] {
                    XCTAssertTrue(
                        css.contains(".node.fp-\(token) \(shape)"),
                        "\(token) does not paint \(shape), so that shape keeps mermaid's own colour"
                    )
                }
                // A stadium's fill and outline are two different <path> elements inside one <g>;
                // one rule setting both would fill the outline path and double-paint the shape.
                XCTAssertTrue(css.contains(".node.fp-\(token) g.outer-path path:nth-child(1)"))
                XCTAssertTrue(css.contains(".node.fp-\(token) g.outer-path path:nth-child(2)"))
            }
        }
    }

    /// The constraint that matters when the picture is printed, photocopied or read by someone who
    /// cannot separate the hues: no rung may be told from another by colour alone.
    func testNoTwoRungsAreToldApartByColourAlone() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            for contrast in [false, true] {
                let css = theme(appearance, contrast: contrast).css
                let parsed = Self.rungs.compactMap { rung($0, css) }
                XCTAssertEqual(parsed.count, Self.rungs.count, "a rung is missing from the stylesheet")
                for i in parsed.indices {
                    for j in parsed.indices where j > i {
                        var channels = 0
                        if parsed[i].fill != parsed[j].fill { channels += 1 }
                        if parsed[i].stroke != parsed[j].stroke { channels += 1 }
                        if parsed[i].width != parsed[j].width { channels += 1 }
                        if parsed[i].dash != parsed[j].dash { channels += 1 }
                        XCTAssertGreaterThanOrEqual(
                            channels, 2,
                            "\(appearance) contrast=\(contrast): \(Self.rungs[i]) and \(Self.rungs[j]) "
                                + "differ in only \(channels) of {fill, stroke, width, dash}"
                        )
                    }
                }
            }
        }
    }

    /// A node border is never dashed. The dash belonged to an `optional` rung given to any node whose
    /// every edge was `-.->`, which turned what the source said about a link into a claim about the
    /// box at its end: the held-out review found it on six nodes in three sources, Prometheus among
    /// them, called optional only because its one edge was dotted. A dashed line on this page is the
    /// author's, and only ever a link.
    func testNoNodeBorderIsDashed() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            for contrast in [false, true] {
                let css = theme(appearance, contrast: contrast).css
                XCTAssertNil(rung("optional", css), "\(appearance) contrast=\(contrast): the optional rung is back")
                for token in Self.rungs {
                    XCTAssertEqual(
                        rung(token, css)?.dash, "", "\(appearance) contrast=\(contrast): the \(token) border is dashed"
                    )
                }
            }
        }
    }

    /// WCAG 1.4.11: a graphical object needed to understand the content owes 3:1 against what is
    /// next to it. An outline is what makes a box a box, so every rung's outline has to clear it
    /// against the page -- the source's own `ink @ 0.30` measures 1.78:1 and gets away with it only
    /// because it always ships a legend, which a preview pane cannot.
    func testEveryRungOutlineIsVisibleAgainstThePaper() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            for contrast in [false, true] {
                let built = theme(appearance, contrast: contrast)
                let paper = built.variables["background"]!
                for token in Self.rungs {
                    let stroke = rung(token, built.css)!.stroke
                    XCTAssertGreaterThanOrEqual(
                        Self.contrast(stroke, paper), 3.0,
                        "\(appearance) contrast=\(contrast): the \(token) outline \(stroke) is invisible on paper"
                    )
                }
            }
        }
    }

    /// Increase Contrast is the one accessibility control a reader has, and the ladder is entirely
    /// made of low-contrast detail. It must reach it.
    func testIncreaseContrastReachesTheLadderAndNotJustTheHairline() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let resting = theme(appearance).css
            let strong = theme(appearance, contrast: true).css
            XCTAssertNotEqual(resting, strong, "\(appearance): Increase Contrast changes nothing about the ladder")
            let paper = theme(appearance).variables["background"]!
            for token in ["store", "entry", "terminal"] {
                let a = rung(token, resting)!, b = rung(token, strong)!
                XCTAssertGreaterThan(
                    Self.contrast(b.fill, paper), Self.contrast(a.fill, paper),
                    "\(appearance): the \(token) rung's fill is no stronger under Increase Contrast"
                )
            }
        }
    }

    // MARK: - Colour that carries words

    /// Coloured text is text. The label-contrast pass cannot rescue an edge label -- its mask rect
    /// is a sibling of the <text>, so `paperUnder` finds nothing behind it and gives up -- so any
    /// hue this theme puts on words has to clear the app's own readable ratio unaided.
    func testEveryColouredWordClearsTheReadableRatio() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let built = theme(appearance)
            let paper = built.variables["background"]!
            for hex in Self.textColours(in: built.css) {
                XCTAssertGreaterThanOrEqual(
                    Self.contrast(hex, paper), 4.5,
                    "\(appearance): \(hex) is used as a text fill at \(Self.contrast(hex, paper)):1 on paper"
                )
            }
        }
    }

    /// The second edge colour is an edge colour. The source is categorical about it and so is the
    /// measurement behind it: link-blue against the default arrow is 1.003:1 in greyscale, so it
    /// carries a dash as well, and it never touches a node body.
    func testTheSecondEdgeColourNeverLandsOnANode() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let css = theme(appearance).css
            let link = appearance == .dark ? "#6A95D8" : "#2E5AA8"
            XCTAssertTrue(css.contains(".flowchart-link.fp-cross"), "there is no zone-crossing edge class")
            XCTAssertTrue(
                css.range(of: "\\.flowchart-link\\.fp-cross[^}]*stroke-dasharray", options: .regularExpression) != nil,
                "the crossing edge is told apart by hue alone, which is invisible in greyscale"
            )
            for token in Self.rungs {
                XCTAssertFalse(
                    rung(token, css).map { $0.fill == link || $0.stroke == link } ?? false,
                    "the \(token) rung is painted in the edge colour"
                )
            }
        }
    }

    // MARK: - The opt-in

    /// The sweep that writes `fp-` class tokens runs only for a theme whose stylesheet can paint
    /// them. That is the whole reason the 124 system goldens do not move.
    func testTheStructuralSweepIsOptedIntoByTheStylesheetAlone() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            XCTAssertTrue(theme(appearance).css.contains(".fp-ladder"), "the glue would never run the sweep")
            let system = MermaidThemeCatalogue.theme(
                .system, appearance: appearance, accentHex: "#0A84FF", increaseContrast: false
            )
            XCTAssertFalse(system.css.contains(".fp-"), "the system theme just asked for the sweep")
        }
    }

    /// mermaid writes `rx="5"` on `(round)` and nothing on `[rect]`: it is the one shape cue a
    /// flowchart rect family gets, and a blanket `rx` in the stylesheet erases it.
    func testTheStylesheetDoesNotFlattenTheOneShapeCueMermaidGives() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let css = theme(appearance).css
            XCTAssertTrue(css.contains(".node rect.basic:not([rx])"), "the rounded rect lost its radius")
            XCTAssertFalse(
                css.range(of: "^\\.node rect \\{[^}]*rx", options: [.regularExpression]) != nil,
                "a blanket rx rule is back"
            )
        }
    }

    /// `==>` is the author asking for weight, and weight is this theme's own non-colour channel.
    func testTheAuthorsOwnEdgeWeightSurvives() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let css = theme(appearance).css
            XCTAssertTrue(css.contains(":not(.edge-thickness-thick)"), "a thick edge is flattened to the default")
            XCTAssertTrue(css.contains(".flowchart-link.edge-thickness-thick"))
        }
    }

    // MARK: - Zone depth

    /// The deepest zone the parser will hand the renderer: flowpeek-flow.js fails a source at
    /// `maxDepth (100)` statements of nesting, and the renderer draws every depth below that
    /// (probed: 100 nested subgraphs draw, the innermost tagged `fp-depth-99`).
    private static let depths = 0..<100

    /// A zone can be told from the zone it sits in, however deep. The wash used to stop at depth 3
    /// -- the depth of the tuned nested drawing -- so depth 3 and 4 shared one fill, and the held-out
    /// review's five-level h14 drew "EKS prod-blue" and its namespace as one grey.
    func testEveryZoneDiffersFromTheZoneItSitsIn() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            for contrast in [false, true] {
                let css = theme(appearance, contrast: contrast).css
                for depth in Self.depths.dropFirst() {
                    let inner = Self.fill(css, classes: "cluster fp-depth-\(depth)", part: "rect")
                    let outer = Self.fill(css, classes: "cluster fp-depth-\(depth - 1)", part: "rect")
                    XCTAssertGreaterThanOrEqual(
                        Self.contrast(inner, outer), 1.03,
                        "\(appearance) contrast=\(contrast): depth \(depth) (\(inner)) is not told from depth \(depth - 1) (\(outer))"
                    )
                }
            }
        }
    }

    /// And a node keeps its wash over whatever zone it is in: the zone rule and the node rule fold
    /// depth the same way, so a node never lands on the paper-based fill its rung has outside a zone,
    /// which is 1.000:1 against some zone (the second review's ghosted NAT Gateway).
    func testANodeIsCompositedOverItsZoneAtEveryDepth() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            for contrast in [false, true] {
                let css = theme(appearance, contrast: contrast).css
                for token in Self.rungs where token != "backend" || appearance == .dark {
                    var byGround: [String: String] = [:]
                    for depth in Self.depths {
                        let ground = Self.fill(css, classes: "cluster fp-depth-\(depth)", part: "rect")
                        let node = Self.fill(css, classes: "node default fp-\(token) fp-on-depth-\(depth)", part: "rect.basic")
                        XCTAssertGreaterThanOrEqual(
                            Self.contrast(node, ground), 1.03,
                            "\(appearance) contrast=\(contrast): \(token) at depth \(depth) sinks into its zone"
                        )
                        XCTAssertEqual(
                            byGround[ground, default: node], node,
                            "\(appearance) contrast=\(contrast): \(token) at depth \(depth) is not the wash over \(ground)"
                        )
                        byGround[ground] = node
                    }
                }
            }
        }
    }

    /// The `fill` the stylesheet gives `part` inside an element with this class attribute, by the
    /// cascade: of the rules whose selector matches, the most specific, then the latest. It reads
    /// the few selector forms the theme writes -- `.class`, `[class*="…"]`, `[class$="…"]` and
    /// `:not(.class)` -- and fails the test on any other, rather than guessing.
    private static func fill(_ css: String, classes: String, part: String) -> String {
        let tokens = Set(classes.split(separator: " ").map(String.init))
        var best: (specificity: Int, fill: String)?
        for block in css.components(separatedBy: "}") {
            guard let brace = block.firstIndex(of: "{") else { continue }
            let body = block[block.index(after: brace)...]
            guard let range = body.range(of: "fill: ") else { continue }
            let tail = body[range.upperBound...]
            let value = String(tail[..<(tail.firstIndex(of: ";") ?? tail.endIndex)])
            guard value.hasPrefix("#") else { continue }
            for raw in block[..<brace].split(separator: ",") {
                let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let pieces = selector.components(separatedBy: " ").filter { !$0.isEmpty }
                guard pieces.count == 2, pieces[1] == part else { continue }
                guard let specificity = match(pieces[0], tokens: tokens, attribute: classes) else { continue }
                if best == nil || specificity >= best!.specificity { best = (specificity, value) }
            }
        }
        return best?.fill ?? "none"
    }

    private static func match(_ compound: String, tokens: Set<String>, attribute: String) -> Int? {
        let pattern = try! NSRegularExpression(
            pattern: #"\.([\w-]+)|\[class([*$])="([^"]*)"\]|:not\(\.([\w-]+)\)"#
        )
        let text = compound as NSString
        var consumed = 0, specificity = 0
        for found in pattern.matches(in: compound, range: NSRange(location: 0, length: text.length)) {
            guard found.range.location == consumed else { XCTFail("unread selector \(compound)"); return nil }
            consumed += found.range.length
            specificity += 1
            func group(_ i: Int) -> String? {
                found.range(at: i).location == NSNotFound ? nil : text.substring(with: found.range(at: i))
            }
            if let name = group(1), !tokens.contains(name) { return nil }
            if let op = group(2), let value = group(3) {
                if op == "*" && !attribute.contains(value) { return nil }
                if op == "$" && !attribute.hasSuffix(value) { return nil }
            }
            if let name = group(4), tokens.contains(name) { return nil }
        }
        guard consumed == text.length else { XCTFail("unread selector \(compound)"); return nil }
        return specificity
    }

    // MARK: - Reading the stylesheet

    private struct ParsedRung {
        var fill = ""
        var stroke = ""
        var width = ""
        var dash = ""
    }

    /// The rung as the stylesheet actually declares it, read back rather than recomputed, so these
    /// tests measure what is shipped.
    private func rung(_ token: String, _ css: String) -> ParsedRung? {
        guard let start = css.range(of: ".node.fp-\(token) rect.basic") else { return nil }
        let rest = css[start.lowerBound...]
        guard let close = rest.range(of: "}") else { return nil }
        let block = String(rest[rest.startIndex..<close.lowerBound])
        func value(_ property: String) -> String {
            guard let found = block.range(of: "\(property): ") else { return "" }
            let tail = block[found.upperBound...]
            let end = tail.firstIndex(where: { $0 == ";" || $0 == "\n" }) ?? tail.endIndex
            return String(tail[tail.startIndex..<end]).trimmingCharacters(in: .whitespaces)
        }
        return ParsedRung(
            fill: value("fill"), stroke: value("stroke"),
            width: value("stroke-width"), dash: value("stroke-dasharray")
        )
    }

    /// Every hex that the stylesheet uses as the colour of type: a `color:` or a `fill:` inside a
    /// rule whose selector names `text`, `tspan` or a label class.
    private static func textColours(in css: String) -> Set<String> {
        var found: Set<String> = []
        for block in css.components(separatedBy: "}") {
            guard let brace = block.firstIndex(of: "{") else { continue }
            let selector = String(block[block.startIndex..<brace])
            // A mask rect behind a label is not the label: `rect.background` lives in the same
            // rule family and is deliberately the colour of the page.
            guard !selector.contains("rect"), !selector.contains("background"),
                  !selector.contains("foreignObject") else { continue }
            guard selector.contains("text") || selector.contains("tspan") || selector.contains("Text")
                || selector.contains("nodeLabel") || selector.contains("edgeLabel") else { continue }
            let body = String(block[block.index(after: brace)...])
            for property in ["fill: ", "color: "] {
                var search = body[...]
                while let range = search.range(of: property) {
                    let tail = search[range.upperBound...]
                    let end = tail.firstIndex(where: { $0 == ";" || $0 == "\n" }) ?? tail.endIndex
                    let value = String(tail[tail.startIndex..<end]).trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("#") { found.insert(value) }
                    search = tail[end...]
                }
            }
        }
        return found
    }

    private static func points(_ length: String) -> Double {
        Double(length.replacingOccurrences(of: "px", with: "")) ?? 0
    }

    private static func channels(_ hex: String) -> [Double] {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        let value = Int(text, radix: 16) ?? 0
        return [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)]
    }

    /// WCAG 2.1 relative luminance, the same arithmetic the renderer's own label pass uses.
    private static func luminance(_ hex: String) -> Double {
        let parts = channels(hex).map { channel -> Double in
            let value = channel / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
    }

    private static func contrast(_ a: String, _ b: String) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
