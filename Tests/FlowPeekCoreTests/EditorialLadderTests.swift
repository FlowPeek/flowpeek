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

    private static let rungs = ["backend", "store", "entry", "terminal", "optional", "focal"]

    // MARK: - The bug that shipped

    /// The one that would have caught it. The accent existed as a token, was handed to the settings
    /// tile, and was never drawn on a diagram: the stylesheet did not mention it once.
    func testTheAccentIsActuallyDrawnOnTheDiagram() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let built = theme(appearance)
            let css = built.css
            XCTAssertTrue(
                css.contains(built.accent),
                "\(appearance): the accent never appears in the stylesheet, so nothing is ever drawn in it"
            )
            XCTAssertNotNil(
                rung("focal", css)?.stroke,
                "\(appearance): there is no focal rung for the accent to land on"
            )
            XCTAssertEqual(rung("focal", css)?.stroke, built.accent)
            XCTAssertTrue(
                css.contains(".flowchart-link.fp-accent"),
                "\(appearance): the focal node's own edge never takes the accent"
            )
            XCTAssertTrue(
                css.contains("marker.fp-marker-accent"),
                "\(appearance): the accent edge would keep the shared grey arrowhead"
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

    /// WCAG 1.4.11: a graphical object needed to understand the content owes 3:1 against what is
    /// next to it. An outline is what makes a box a box, so every rung's outline has to clear it
    /// against the page -- the source's own `ink @ 0.30` measures 1.78:1 and gets away with it only
    /// because it always ships a legend, which a preview pane cannot.
    func testEveryRungOutlineIsVisibleAgainstThePaper() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            for contrast in [false, true] {
                let built = theme(appearance, contrast: contrast)
                let paper = built.variables["background"]!
                for token in Self.rungs where token != "focal" {
                    let stroke = rung(token, built.css)!.stroke
                    XCTAssertGreaterThanOrEqual(
                        Self.contrast(stroke, paper), 3.0,
                        "\(appearance) contrast=\(contrast): the \(token) outline \(stroke) is invisible on paper"
                    )
                }
            }
        }
    }

    /// The accent is the one stroke that cannot clear 3:1 -- 2.86:1 on light paper, measured -- so
    /// it is not allowed to carry the focal signal on its own. type-line.md: "focus is carried by
    /// stroke weight, not tone", at twice the ladder's weight.
    func testTheFocalNodeCarriesItsEmphasisInWeightAsWellAsHue() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            for contrast in [false, true] {
                let css = theme(appearance, contrast: contrast).css
                let focal = rung("focal", css)!, backend = rung("backend", css)!
                XCTAssertGreaterThanOrEqual(
                    Self.points(focal.width), Self.points(backend.width) * 1.9,
                    "\(appearance) contrast=\(contrast): the focal outline is not twice the ladder's weight"
                )
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
            for token in ["store", "entry", "terminal", "optional"] {
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
