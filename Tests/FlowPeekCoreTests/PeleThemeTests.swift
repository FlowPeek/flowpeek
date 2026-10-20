import XCTest
@testable import FlowPeekCore

/// The Pele entry in the catalogue: what it says it is, and what it says it looks like.
///
/// Nothing renders through Pele yet, so none of this can be checked by looking at a drawing. What
/// can be checked is every claim the theme makes about itself -- that it is handed to Pele and not
/// to mermaid, that it speaks only Pele's vocabulary, that its colours are the editorial palette
/// rather than a second one beside it, and that the numbers in its documentation are the numbers it
/// actually ships. Those are the claims that break silently.
final class PeleThemeTests: XCTestCase {
    private let appearances: [MacMermaidTheme.Appearance] = [.light, .dark]
    private let contrasts = [false, true]

    private func theme(_ appearance: MacMermaidTheme.Appearance, contrast: Bool = false) -> MacMermaidTheme {
        // A loud accent the theme must ignore. `.pele` takes the editorial coral, like `.editorial`
        // does, so a reader's accent reaching the palette would show up here as magenta.
        MermaidThemeCatalogue.theme(
            .pele, appearance: appearance, accentHex: "#FF00FF", increaseContrast: contrast
        )
    }

    private func variables(
        _ appearance: MacMermaidTheme.Appearance,
        contrast: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String: String] {
        guard case .pele(let variables) = theme(appearance, contrast: contrast).engine else {
            XCTFail("the pele entry is not drawn by pele", file: file, line: line)
            return [:]
        }
        return variables
    }

    /// Every property Pele resolves a colour or a face through, and nothing else. Read off
    /// `Sources/FlowPeek/Resources/pele.global.js`, where each appears as the first argument of a
    /// `var(--pele-…, default)` in the `style` attribute the emitted `<svg>` carries.
    private static let coreProperties = [
        "--pele-bg", "--pele-fg", "--pele-muted", "--pele-line",
        "--pele-surface", "--pele-surface-alt", "--pele-border", "--pele-accent",
        "--pele-critical",
        "--pele-radius", "--pele-font", "--pele-font-mono",
    ]
    private static let seriesProperties = (1...8).map { "--pele-series-\($0)" }

    /// Every property whose value Pele can end up writing a `fill="var(--_bg)"` label on top of,
    /// found by grepping `Sources/FlowPeek/Resources/pele.global.js` for `var(--_bg)` used as a
    /// text fill and working back to what is painted underneath each one. `--pele-line` is on the
    /// list too -- the sequence message-number badge -- but it is the ink and is checked at 7:1 by
    /// `testTextAndLinesClearTheirRatios`, so it is not repeated here.
    ///
    ///   `--pele-accent`    gantt, a task bar whose label fits inside it
    ///   `--pele-critical`  gantt, the same bar when the task is `crit`
    ///   `--pele-series-N`  pie slices, treemap leaves, gitgraph branches, timeline sections
    ///   `--pele-muted`     timeline, a period belonging to no section in a timeline that has them
    ///
    /// `--pele-muted` is the one that makes this list worth having rather than worth reading once.
    /// It is chrome everywhere else, and a chrome colour under data paint is exactly the defect
    /// that put `muted` in the series ramp and had a category invert its weight between
    /// appearances. It passes today at 6.11:1 light and 7.07:1 dark, so it is here to be checked,
    /// not to be fixed: `q=(K,ee)=>K.section>=0?lt(K.section):f?"var(--_m)":lt(c?ee:0)` picks the
    /// fill and `B0=' fill="var(--_bg)"'` paints the label over it, so a future move of `muted`
    /// toward the paper would silently take a timeline label with it.
    private static let fillsUnderBackgroundColouredLabels =
        ["--pele-accent", "--pele-critical", "--pele-muted"] + (1...8).map { "--pele-series-\($0)" }

    // MARK: - Which engine

    func testTheThemeIsHandedToPeleInEveryAppearance() {
        for appearance in appearances {
            for contrast in contrasts {
                guard case .pele = theme(appearance, contrast: contrast).engine else {
                    XCTFail("\(appearance) contrast=\(contrast) is not drawn by pele")
                    continue
                }
            }
        }
    }

    /// The other half of carrying the engine as a case rather than a flag. mermaid's vocabulary is
    /// not this theme's, so a plausible-looking set of `themeVariables` here would be a second
    /// palette nobody renders; an arrangement would be dagre config handed to a layout engine that
    /// is not dagre.
    func testItCarriesNoneOfMermaidsVocabulary() {
        for appearance in appearances {
            for contrast in contrasts {
                let built = theme(appearance, contrast: contrast)
                let label = "\(appearance) contrast=\(contrast)"
                XCTAssertTrue(built.variables.isEmpty, "\(label): carries mermaid themeVariables")
                XCTAssertTrue(built.css.isEmpty, "\(label): carries a mermaid stylesheet")
                XCTAssertTrue(built.arrangement.isEmpty, "\(label): asks dagre for spacing")
            }
        }
    }

    /// The glue turns its structural sweep and its arrowhead rewrite on by finding `.fp-ladder` in
    /// the theme's CSS (flowpeek-glue.js:459). Neither has anything to say about a drawing Pele
    /// made, so the marker must not be there -- and today it cannot be, because the string is empty.
    /// Asserted against the marker rather than against emptiness so that a Pele theme which later
    /// grows a stylesheet still cannot switch the ladder on by accident.
    func testItNeverCarriesTheLadderMarker() {
        for appearance in appearances {
            for contrast in contrasts {
                XCTAssertFalse(
                    theme(appearance, contrast: contrast).css.contains(".fp-ladder"),
                    "\(appearance) contrast=\(contrast)"
                )
            }
        }
    }

    // MARK: - The variable map

    func testItSetsExactlyThePropertiesPeleReads() {
        let expected = Set(Self.coreProperties + Self.seriesProperties)
        for appearance in appearances {
            for contrast in contrasts {
                let keys = Set(variables(appearance, contrast: contrast).keys)
                let label = "\(appearance) contrast=\(contrast)"
                XCTAssertEqual(expected.subtracting(keys), [], "\(label): unset")
                XCTAssertEqual(keys.subtracting(expected), [], "\(label): set but unread by Pele")
            }
        }
    }

    /// Full property names, so the seam writes a declaration rather than assembling one. A key
    /// stored as `bg` would need a prefix added at every call site that ever reads this map.
    func testEveryKeyIsAWholePropertyName() {
        for (key, value) in variables(.light) {
            XCTAssertTrue(key.hasPrefix("--pele-"), "\(key) is not a custom property Pele reads")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) is empty")
        }
    }

    /// `--pele-critical` is set and `--pele-error` is not, and the two are not the same decision.
    /// Critical is a FILL -- a `crit` gantt bar -- and Pele writes a page-coloured label on it, so
    /// its own #E45756 at 3.32:1 light and 3.56:1 dark is under the floor for words and has to
    /// move. Error is only ever the colour of the HTML overlay Pele's `mount` API builds; FlowPeek
    /// calls `pele.render` directly and reports its own failures, so nothing in this app paints it
    /// and restating a default would be a value that stops tracking what it copied.
    func testItSetsTheCriticalFillAndLeavesTheUnreachableErrorColourAlone() {
        for appearance in appearances {
            for contrast in contrasts {
                let map = variables(appearance, contrast: contrast)
                let label = "\(appearance) contrast=\(contrast)"
                XCTAssertNotNil(map["--pele-critical"], "\(label): a crit bar's label is unreadable")
                XCTAssertNotEqual(
                    map["--pele-critical"]?.uppercased(), "#E45756",
                    "\(label): critical is back on Pele's own 3.32:1 default"
                )
                XCTAssertNil(map["--pele-error"], "\(label)")
            }
        }
    }

    // MARK: - One app, one palette

    /// The reason this theme exists at all is that the three entries in the picker should look like
    /// one application. Tied to `.editorial` rather than to literals so the two cannot drift: change
    /// the editorial paper and this fails until the Pele paper follows it.
    func testThePaperInkAndAccentAreEditorialsOwn() {
        for appearance in appearances {
            for contrast in contrasts {
                let editorial = MermaidThemeCatalogue.theme(
                    .editorial, appearance: appearance, accentHex: "#FF00FF", increaseContrast: contrast
                )
                let map = variables(appearance, contrast: contrast)
                let label = "\(appearance) contrast=\(contrast)"
                XCTAssertEqual(map["--pele-bg"], editorial.variables["background"], "\(label): paper")
                XCTAssertEqual(map["--pele-fg"], editorial.variables["primaryTextColor"], "\(label): ink")
                XCTAssertEqual(map["--pele-muted"], editorial.variables["lineColor"], "\(label): muted")
                // The accent is the one token that cannot be shared outright, because Pele writes a
                // page-coloured label on it and editorial never does. Tied to editorial by HUE
                // instead, which is the part that has to stay recognisable: a deeper coral is still
                // the editorial coral, and a hue that wandered would be a sixth colour in a
                // five-colour palette. 10 degrees is the slack the rounding of a hex leaves.
                let accent = map["--pele-accent"] ?? ""
                XCTAssertEqual(theme(appearance, contrast: contrast).accent, accent, "\(label): tile")
                XCTAssertLessThanOrEqual(
                    Self.hueGap(accent, editorial.accent), 10,
                    "\(label): \(accent) is not the editorial coral any more"
                )
            }
        }
    }

    /// The reader's accent is the system theme's idea and stays there. Editorial spends its coral on
    /// the one thing to look at first, and a sixth colour in a five-colour palette would land
    /// exactly where the palette works hardest.
    func testTheReadersAccentNeverReachesThePalette() {
        for appearance in appearances {
            for contrast in contrasts {
                for (key, value) in variables(appearance, contrast: contrast) {
                    XCTAssertNotEqual(
                        value.uppercased(), "#FF00FF",
                        "\(key) took the reader's accent at \(appearance) contrast=\(contrast)"
                    )
                }
            }
        }
    }

    /// The other way a page-coloured label can land on a mid-tone fill, and this one is entirely
    /// ours. The label-contrast pass does run on Pele's output, and the only labels it corrects
    /// there sit on a fill Pele drew with `fill-opacity` -- a gantt `active` bar is the accent at
    /// 0.25. The glue's `parseRGB` drops the alpha, so the pass measures the solid colour while the
    /// paint is a wash of it over the paper, and it then picks whichever end of this pair suits the
    /// solid. For the light `active` bar, really #E4C8BC, that was the paper at 1.45:1 instead of
    /// the ink at 8.15:1. Both ends are the ink so the pass cannot reach for the paper; nothing is
    /// lost, because every fill it measures correctly under this theme already clears its
    /// threshold.
    func testACorrectedLabelCanOnlyEverBecomeTheInk() {
        for appearance in appearances {
            for contrast in contrasts {
                let built = theme(appearance, contrast: contrast)
                let ink = variables(appearance, contrast: contrast)["--pele-fg"]
                let label = "\(appearance) contrast=\(contrast)"
                XCTAssertEqual(built.darkInk, ink, "\(label)")
                XCTAssertEqual(built.lightInk, ink, "\(label): a correction can still land on paper")
            }
        }
    }

    /// Pele collapses a node outline and an edge into one `--pele-line`, and its own default sets it
    /// equal to `--pele-fg`. Keeping that is what keeps the weight balance Pele was drawn against.
    func testTheDrawingLineIsTheInkPeleExpectsItToBe() {
        for appearance in appearances {
            let map = variables(appearance)
            XCTAssertEqual(map["--pele-line"], map["--pele-fg"], "\(appearance)")
        }
    }

    /// Both faces are the editorial stacks, which name Apple SD Gothic Neo: the app is bilingual and
    /// a Korean label falling back to a system default is the fault this is here to catch.
    func testBothFacesCarryTheKoreanStack() {
        let map = variables(.light)
        for key in ["--pele-font", "--pele-font-mono"] {
            XCTAssertTrue(map[key]?.contains("Apple SD Gothic Neo") == true, key)
        }
        XCTAssertNotEqual(map["--pele-font"], map["--pele-font-mono"], "one stack doing both jobs")
        XCTAssertTrue(map["--pele-font-mono"]?.contains("monospace") == true)
    }

    // MARK: - Dark is not an afterthought

    /// A theme that only works in light is half a theme. Every colour here has a light and a dark
    /// form -- the series ramp included, now that each member is pinned to a target ratio against
    /// its own paper rather than borrowed as a single hex -- and the two faces and the radius have
    /// one form on purpose.
    func testEveryPaletteColourHasBothForms() {
        let light = variables(.light)
        let dark = variables(.dark)
        let unchanging = Set(["--pele-font", "--pele-font-mono", "--pele-radius"])
        for key in light.keys where !unchanging.contains(key) {
            XCTAssertNotEqual(light[key], dark[key], "\(key) is the same colour in both appearances")
        }
        for key in unchanging {
            XCTAssertEqual(light[key], dark[key], "\(key) should not depend on appearance")
        }
    }

    /// Light paper is light and dark paper is dark, which is the one thing an appearance has to get
    /// right and the one a mirrored palette can get backwards.
    func testThePapersAreTheRightWayRound() {
        XCTAssertGreaterThan(
            Self.luminance(variables(.light)["--pele-bg"] ?? "#000000"),
            Self.luminance(variables(.dark)["--pele-bg"] ?? "#FFFFFF")
        )
    }

    // MARK: - Measured

    /// The numbers the theme's own documentation states. Ink 11.82:1, muted 6.11:1 light and 7.07:1
    /// dark, border 3.48:1 and 4.44:1 -- the last clearing the 3:1 WCAG 1.4.11 asks of a graphical
    /// object, which is the floor that matters for a line nobody reads words off.
    func testTextAndLinesClearTheirRatios() {
        for appearance in appearances {
            let map = variables(appearance)
            let paper = map["--pele-bg"] ?? "#FFFFFF"
            XCTAssertGreaterThanOrEqual(Self.contrast(map["--pele-fg"] ?? "", paper), 7.0, "\(appearance) ink")
            XCTAssertGreaterThanOrEqual(Self.contrast(map["--pele-line"] ?? "", paper), 7.0, "\(appearance) line")
            XCTAssertGreaterThanOrEqual(Self.contrast(map["--pele-muted"] ?? "", paper), 4.5, "\(appearance) muted")
            XCTAssertGreaterThanOrEqual(Self.contrast(map["--pele-border"] ?? "", paper), 3.0, "\(appearance) border")
        }
    }

    /// THE DEFECT THIS SUITE EXISTS FOR. Pele writes a label that sits on a filled shape as
    /// `fill="var(--_bg)"` -- the page colour, picked without looking at the fill -- so a fill that
    /// can carry one has to hold 13px regular text against the paper, which is 4.5:1. Not 3:1: the
    /// large-text exception floors at 14px bold or 18px regular and a pie percentage is neither.
    ///
    /// Asserted as the ratio rather than as a list of hexes on purpose. A pinned hex only records
    /// what someone typed; this is the property that makes the drawing readable, and it fails for a
    /// new member of the ramp, a retuned one, or a paper that moved under all of them.
    func testEveryFillUnderABackgroundColouredLabelHoldsBodyText() {
        for appearance in appearances {
            for contrast in contrasts {
                let map = variables(appearance, contrast: contrast)
                let paper = map["--pele-bg"] ?? "#FFFFFF"
                for key in Self.fillsUnderBackgroundColouredLabels {
                    let colour = map[key] ?? ""
                    XCTAssertGreaterThanOrEqual(
                        Self.contrast(colour, paper), 4.5,
                        "\(appearance) contrast=\(contrast) \(key) (\(colour)): a label on it is unreadable"
                    )
                }
            }
        }
    }

    /// Series 1 is the theme's accent and series 2 its link: the two series most charts have are
    /// the two colours the rest of the app already means something by.
    func testTheRampOpensWithTheThemesOwnTwoVoices() {
        for appearance in appearances {
            let map = variables(appearance)
            XCTAssertEqual(map["--pele-series-1"], map["--pele-accent"], "\(appearance)")
            let ramp = Self.seriesProperties.compactMap { map[$0]?.uppercased() }
            XCTAssertEqual(Set(ramp).count, 8, "\(appearance): two series share a colour")
            // Pele's default series puts #E45756 third, and the same hex is the default of
            // `--pele-critical` and `--pele-error`. A series painted in it would be the colour of
            // something being wrong -- and would now collide with the critical fill this theme sets.
            XCTAssertFalse(ramp.contains("#E45756"), "\(appearance): a series took the error colour")
        }
    }

    /// No member of a data ramp may be a structural colour. `--pele-series-3` used to be `muted`,
    /// which is also `--pele-muted` and, under Increase Contrast, `--pele-border` -- so in a pie it
    /// read as the inactive slice because it literally was the chrome colour. The accent is the one
    /// exception and it is deliberate: series 1 IS `--pele-accent`, the theme speaking in its own
    /// voice, and it is a focal colour rather than a piece of furniture.
    func testNoSeriesIsAStructuralColour() {
        let chrome = ["--pele-muted", "--pele-border", "--pele-line", "--pele-fg",
                      "--pele-bg", "--pele-surface", "--pele-surface-alt"]
        for appearance in appearances {
            for contrast in contrasts {
                let map = variables(appearance, contrast: contrast)
                let structural = Set(chrome.compactMap { map[$0]?.uppercased() })
                for key in Self.seriesProperties where key != "--pele-series-1" {
                    let colour = (map[key] ?? "").uppercased()
                    XCTAssertFalse(
                        structural.contains(colour),
                        "\(appearance) contrast=\(contrast) \(key) (\(colour)) is a chrome colour"
                    )
                }
            }
        }
    }

    /// What makes a chart survive a theme switch: sort the ramp by contrast against its own paper
    /// and the order has to come out the same in both appearances. It did not before -- series 3
    /// was `muted`, the darkest of the ramp on light paper and the lightest on dark -- so one
    /// category went from the quietest thing on the page to the loudest when a reader changed
    /// theme. Every member is now pinned to the same target ratio in both appearances, which is
    /// what this asserts the consequence of.
    func testTheRampHoldsItsRankOrderAcrossAppearances() {
        func order(_ appearance: MacMermaidTheme.Appearance) -> [String] {
            let map = variables(appearance)
            let paper = map["--pele-bg"] ?? ""
            return Self.seriesProperties
                .sorted { Self.contrast(map[$0] ?? "", paper) < Self.contrast(map[$1] ?? "", paper) }
        }
        XCTAssertEqual(order(.light), order(.dark), "the ramp reorders itself when the theme changes")
    }

    /// And the other half of a ramp being a ramp: a reader has to tell one member from the next,
    /// not merely from the paper. Eight colours confined between 4.71:1 and 6.74:1 can differ from
    /// each other by at most 1.43:1, so value alone cannot do it and hue has to -- the ramp is
    /// ordered so neighbours sit far apart in hue, and the pairs that are close in hue are pushed
    /// apart in value instead. Either channel passing is enough; neither passing is the failure.
    func testAdjacentSeriesAreTellableApart() {
        for appearance in appearances {
            let map = variables(appearance)
            for index in 1...8 {
                let here = map["--pele-series-\(index)"] ?? ""
                let next = map["--pele-series-\(index % 8 + 1)"] ?? ""
                let byValue = Self.contrast(here, next)
                let byHue = Self.hueGap(here, next)
                XCTAssertTrue(
                    byValue >= 1.10 || byHue >= 60,
                    "\(appearance) series \(index)/\(index % 8 + 1): \(here) and \(next) are "
                        + "\(byValue) apart in value and \(byHue) degrees apart in hue"
                )
            }
        }
    }

    /// The one accessibility control a reader has, and the thing it must not do is skip the weakest
    /// step in the drawing. It used to: the ramp moved `--pele-border` and `--pele-surface-alt` and
    /// left `--pele-surface` -- the 1.08:1 node face -- exactly where it was. Now it reaches three
    /// values. What it still does not touch is stated as an equality rather than left unsaid: the
    /// paper, the ink, the line (already the top of the ramp) and every fill that carries a
    /// bg-coloured label (each already over 4.5:1, so there is nothing there to fix and moving them
    /// would only compress the ramp's own separation).
    func testIncreaseContrastReachesTheQuietValues() {
        for appearance in appearances {
            let plain = variables(appearance)
            let raised = variables(appearance, contrast: true)
            let paper = plain["--pele-bg"] ?? "#FFFFFF"
            let label = "\(appearance)"

            XCTAssertEqual(raised["--pele-border"], plain["--pele-muted"], "\(label): border")
            XCTAssertGreaterThan(
                Self.contrast(raised["--pele-border"] ?? "", paper),
                Self.contrast(plain["--pele-border"] ?? "", paper),
                "\(label): the border got no stronger"
            )
            for key in ["--pele-surface", "--pele-surface-alt"] {
                XCTAssertGreaterThan(
                    Self.distance(raised[key] ?? "", paper),
                    Self.distance(plain[key] ?? "", paper),
                    "\(label): \(key) got no deeper -- the switch skipped it"
                )
            }
            // `--pele-muted` is not repeated here: it joined the fills list when the timeline
            // period bar turned out to paint a page-coloured label on it.
            let held = ["--pele-bg", "--pele-fg", "--pele-line"]
                + Self.fillsUnderBackgroundColouredLabels
            for key in held {
                XCTAssertEqual(raised[key], plain[key], "\(label): \(key) moved for no stated reason")
            }
        }
    }

    /// `--pele-surface` is the node face in 28 places in Pele's bundle, and in four of them --
    /// the gantt section band, the kanban column, the event-model lane, the sequence frame tab --
    /// it is filled with no stroke at all, so the step away from the paper IS the only signal. It
    /// used to be `paper2`: 1.08:1 light, 1.22:1 dark, and three gantt sections read as two.
    ///
    /// The floor asserted here is deliberately modest, because the ceiling is real: a band dark
    /// enough to reach 3:1 against the paper cannot hold ink at 4.5:1. Solved numerically, the
    /// deepest ink-over-paper wash that still carries ink at 4.5:1 is alpha 0.4719 in light and
    /// 0.3239 in dark, and those bands measure 2.61:1 and 2.62:1 against their own paper -- so
    /// WCAG 1.4.11's number is not available to a surface that gets written on. The ceiling
    /// asserted below is 2.6, the lower of the two. What is asserted is that the step is a step,
    /// that the second surface is a further one, and that ink survives both -- which is the shape
    /// of the ladder rather than the hexes in it.
    func testTheSurfaceIsAStepAReaderCanSee() {
        for appearance in appearances {
            for contrast in contrasts {
                let map = variables(appearance, contrast: contrast)
                let paper = map["--pele-bg"] ?? ""
                let ink = map["--pele-fg"] ?? ""
                let surface = map["--pele-surface"] ?? ""
                let alt = map["--pele-surface-alt"] ?? ""
                let label = "\(appearance) contrast=\(contrast)"

                XCTAssertGreaterThanOrEqual(
                    Self.contrast(surface, paper), 1.14,
                    "\(label): surface \(surface) is still the paper"
                )
                XCTAssertGreaterThanOrEqual(
                    Self.contrast(alt, surface), 1.14,
                    "\(label): the two surfaces have merged"
                )
                XCTAssertLessThanOrEqual(
                    Self.contrast(alt, paper), 2.6,
                    "\(label): surface-alt \(alt) is too dark to write ink on"
                )
                for (key, colour) in [("surface", surface), ("surface-alt", alt)] {
                    XCTAssertGreaterThanOrEqual(
                        Self.contrast(ink, colour), 4.5, "\(label): ink on \(key) (\(colour))"
                    )
                }
            }
        }
    }

    /// WCAG 1.4.11 wants the boundary of a component perceivable against what is OUTSIDE it, so
    /// the measure that matters for a bordered node is `--pele-border` against the paper, not
    /// against the fill it encloses. The inner measure was the one tried first and it is the one
    /// that fails: `soft` against its own node fill is 3.02:1 in light at the shipped depth but
    /// 2.77:1 once Increase Contrast deepens the fill, and against `--pele-surface-alt` it is
    /// under 3:1 in every appearance. The outer measure holds in all four and gets stronger where
    /// it is asked to -- 3.48:1 light and 4.44:1 dark, 6.11:1 and 7.07:1 with Increase Contrast on.
    ///
    /// Asserted here so the next person inherits this constraint rather than the one that reads
    /// like it should be true.
    func testTheBorderIsPerceivableAgainstThePaper() {
        for appearance in appearances {
            for contrast in contrasts {
                let map = variables(appearance, contrast: contrast)
                let border = map["--pele-border"] ?? ""
                let paper = map["--pele-bg"] ?? ""
                XCTAssertGreaterThanOrEqual(
                    Self.contrast(border, paper), 3.0,
                    "\(appearance) contrast=\(contrast): border \(border) on \(paper) is under 1.4.11"
                )
            }
        }
        // And the trade-off runs the right way: deepening the fill costs the inner measure and pays
        // the outer one, so Increase Contrast never hands the reader a weaker shape than it found.
        for appearance in appearances {
            let plain = variables(appearance, contrast: false)
            let raised = variables(appearance, contrast: true)
            let paper = plain["--pele-bg"] ?? ""
            for key in ["--pele-surface", "--pele-surface-alt"] {
                XCTAssertGreaterThan(
                    Self.contrast(raised[key] ?? "", paper),
                    Self.contrast(plain[key] ?? "", paper),
                    "\(appearance): \(key) did not gain against the paper under Increase Contrast"
                )
            }
        }
    }

    /// The surfaces are a ramp away from the paper, in that order, in both appearances -- which in
    /// dark means stepping lighter rather than darker, the direction a mirrored palette gets wrong.
    func testTheSurfacesStepAwayFromThePaperInOrder() {
        for appearance in appearances {
            for contrast in contrasts {
                let map = variables(appearance, contrast: contrast)
                let paper = map["--pele-bg"] ?? ""
                let label = "\(appearance) contrast=\(contrast)"
                XCTAssertGreaterThan(Self.distance(map["--pele-surface"] ?? "", paper), 0, "\(label): surface is the paper")
                XCTAssertGreaterThan(
                    Self.distance(map["--pele-surface-alt"] ?? "", paper),
                    Self.distance(map["--pele-surface"] ?? "", paper),
                    "\(label): the second surface is no further from the paper than the first"
                )
            }
        }
    }

    // MARK: - The settings tile

    /// `ThemeSample` draws a tile from `MacMermaidTheme.sample` before anything has been rendered.
    /// For this theme `variables` is empty, so a `sample` that still read it would hand the picker
    /// its white-and-black fallbacks -- a Pele tile that looks like no theme in the app.
    func testTheSettingsTileReadsThePelePalette() {
        for appearance in appearances {
            let built = theme(appearance)
            let map = variables(appearance)
            let sample = built.sample
            XCTAssertEqual(sample.paper, map["--pele-bg"], "\(appearance)")
            XCTAssertEqual(sample.ink, map["--pele-fg"], "\(appearance)")
            XCTAssertEqual(sample.line, map["--pele-line"], "\(appearance)")
            XCTAssertEqual(sample.accent, map["--pele-accent"], "\(appearance)")
        }
    }

    /// And the same reading from the other side: adding the Pele branch must not have changed what
    /// a mermaid theme's tile shows.
    func testTheMermaidThemesStillSampleTheirOwnVariables() {
        for id in [MermaidThemeID.system, .editorial] {
            for appearance in appearances {
                let built = MermaidThemeCatalogue.theme(
                    id, appearance: appearance, accentHex: "#FF00FF", increaseContrast: false
                )
                XCTAssertEqual(built.sample.paper, built.variables["background"], "\(id) \(appearance)")
                XCTAssertEqual(built.sample.ink, built.variables["primaryTextColor"], "\(id) \(appearance)")
                XCTAssertEqual(built.sample.line, built.variables["lineColor"], "\(id) \(appearance)")
            }
        }
    }

    // MARK: - WCAG arithmetic

    // A second copy of what `EditorialLadderTests` keeps privately. Deliberate: these four
    // functions are the yardstick the assertions above are written against, and a yardstick shared
    // between two suites is one that can be adjusted to make either of them pass.

    private static func channels(_ hex: String) -> [Double] {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        let value = Int(text, radix: 16) ?? 0
        return [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)]
    }

    /// WCAG 2.1 relative luminance.
    /// A ratio target pins how a colour reads AGAINST THE PAPER; it does not pin how heavy the
    /// colour looks beside its neighbours. The two came apart at series 5: hue 48 is intrinsically
    /// luminous, so at the chroma the rest of the ramp carries it hit its target against the dark
    /// paper at 40% lightness while every other dark member sat between 52% and 74%, and the pie
    /// showed one saturated ochre slice among seven pastels. Every ratio passed.
    ///
    /// So the spread is asserted as well as the ratios. 30 points is chosen to sit between the two:
    /// the ramp measures 25 points in light and 23 in dark today, and the version this test was
    /// written against measured 34.
    func testNoSeriesIsAWeightOutlier() {
        for appearance in appearances {
            let map = variables(appearance)
            let lightnesses = Self.seriesProperties.compactMap { map[$0].map(Self.lightness) }
            XCTAssertEqual(lightnesses.count, 8, "\(appearance)")
            let spread = (lightnesses.max() ?? 0) - (lightnesses.min() ?? 0)
            XCTAssertLessThanOrEqual(
                spread, 0.30,
                "\(appearance): the ramp spans \(Int(spread * 100)) points of lightness, so one "
                    + "member reads at a different weight from the rest"
            )
        }
    }

    /// HSL lightness: the midpoint of the brightest and darkest channel. Not luminance -- luminance
    /// is what the ratio already measures, and the point of the caller is that the two disagree.
    private static func lightness(_ hex: String) -> Double {
        let parts = channels(hex).map { $0 / 255 }
        return ((parts.max() ?? 0) + (parts.min() ?? 0)) / 2
    }

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

    /// How far one colour is from another in luminance, direction discarded. A surface ramp steps
    /// darker on light paper and lighter on dark, so the ratio cannot order it and the sign would
    /// have to be stated twice.
    private static func distance(_ a: String, _ b: String) -> Double {
        abs(luminance(a) - luminance(b))
    }

    /// The shorter way round the hue circle, in degrees. The second channel a ramp separates on:
    /// eight colours all held above 4.5:1 cannot be far apart in luminance, so for most of the
    /// pairs hue is what is left, and a hue is also the thing that has to stay recognisable when a
    /// palette colour is deepened rather than replaced.
    private static func hueGap(_ a: String, _ b: String) -> Double {
        let gap = abs(hue(a) - hue(b))
        return min(gap, 360 - gap)
    }

    private static func hue(_ hex: String) -> Double {
        let parts = channels(hex).map { $0 / 255 }
        let high = parts.max() ?? 0, low = parts.min() ?? 0
        let span = high - low
        guard span > 0 else { return 0 }
        let value: Double
        switch high {
        case parts[0]: value = (parts[1] - parts[2]) / span + (parts[1] < parts[2] ? 6 : 0)
        case parts[1]: value = (parts[2] - parts[0]) / span + 2
        default: value = (parts[0] - parts[1]) / span + 4
        }
        return value * 60
    }
}
