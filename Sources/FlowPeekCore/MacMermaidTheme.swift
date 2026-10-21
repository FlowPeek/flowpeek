import Foundation

public struct MacMermaidTheme: Equatable, Sendable {
    public enum Appearance: Sendable { case light, dark }

    /// mermaid reads the top-level `fontFamily` into its `--mermaid-font-family` custom property;
    /// `themeVariables.fontFamily` alone leaves that at the Trebuchet default.
    public static let systemFontStack = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"

    /// Kept so the renderer can pick mermaid's matching base palette; diagram types that hardcode
    /// their colours ignore `variables` entirely and only respond to the base theme.
    public let appearance: Appearance
    public let variables: [String: String]
    public let css: String
    public let fontFamily: String
    /// The face this theme paints EDGE LABELS in, which need not be `fontFamily`. The name is from
    /// when the editorial `.edgeLabel` rule set a monospace stack; it now sets the sans, and this
    /// carries the sans. It is carried in the payload because the renderer measures a label before
    /// it draws it and has to measure the face that will be painted -- measuring the sans and
    /// painting the mono made every edge label's backing rect narrower than the words on it, which
    /// is text spilling off both ends of its own mask, visible on cand.mmd's two "originalQuoteId"
    /// labels at the edges of the drawing.
    public let monoFontFamily: String
    /// The spacing and edge shape this theme asks mermaid for. `.unset` means "say nothing", which
    /// is what every theme said before themes were plural.
    public let arrangement: MermaidArrangement
    /// The two ends of this theme's own range, used when a label has to be repainted to be legible
    /// at all. Taken from the theme rather than fixed, so a corrected label reads as part of the
    /// drawing instead of as a warning -- which is the whole reason these were never black and
    /// white in the first place.
    public let darkInk: String
    public let lightInk: String
    /// The one colour this theme uses to say "look here". Named rather than dug out of `variables`,
    /// because a settings tile has to draw a theme before anything has been rendered in it, and
    /// hunting for it under `noteBorderColor` would tie the picker to which variable happens to
    /// carry it this month.
    public let accent: String
    /// Whose vocabulary the values above are written in, and -- for a theme that does not speak
    /// mermaid's -- the values that replace them. See `Engine`.
    public let engine: Engine

    /// Which drawing engine a theme's values are written for.
    ///
    /// Two of the three themes here are mermaid `themeVariables` plus a stylesheet, which is one
    /// vocabulary and reaches two renderers: mermaid itself, and flowpeek-flow.js, which reads the
    /// same payload and the same CSS. Pele reads neither. It is themed only through its own CSS
    /// custom properties, so a Pele theme has nothing to put in `variables` or `css` and everything
    /// to put somewhere else -- which is the associated value here.
    ///
    /// AN EXPLICIT CASE RATHER THAN A MARKER STRING, against the precedent next door. The glue
    /// turns the ladder sweep on by looking for `.fp-ladder` in the theme's CSS
    /// (flowpeek-glue.js:459), and the obvious cheap move was a second marker for Pele. It is the
    /// wrong read of what that marker says. `.fp-ladder` is not "use the other renderer": it is
    /// "this stylesheet has rules for the classes the sweep writes", a question about the CSS,
    /// asked of the CSS, and the renderer choice beside it is made separately and per diagram type
    /// (`LADDER_TYPES`, flowpeek-glue.js:462). A Pele theme answers a different question -- one
    /// engine for every diagram type -- and answering it through a CSS string would mean shipping a
    /// stylesheet nothing compiles, carrying a marker whose only job is to be absent. The case also
    /// buys what a string cannot: `variables` and `css` are unreachable for `.pele` because they do
    /// not exist on it, so a Pele theme cannot be half-written.
    ///
    /// Carrying the two facts as one value is the point. A `renderer` flag beside a variable map
    /// could disagree with it; this cannot.
    public enum Engine: Equatable, Sendable {
        /// mermaid's `themeVariables` and stylesheet, in `variables` and `css`.
        case mermaid
        /// Pele's CSS custom properties, keyed by their full property names (`--pele-bg`, not
        /// `bg`): the seam writes them as declarations, and a full name is one it cannot misspell
        /// half of.
        case pele(variables: [String: String])
    }

    /// The look FlowPeek has always drawn, and the one every reader gets until they choose
    /// otherwise. Reached through `MermaidThemeCatalogue.theme(.system, ...)`; the initialiser below
    /// stays for the callers that predate the catalogue and is what this returns.
    public static func system(
        appearance: Appearance,
        accentHex: String,
        increaseContrast: Bool
    ) -> MacMermaidTheme {
        MacMermaidTheme(appearance: appearance, accentHex: accentHex, increaseContrast: increaseContrast)
    }

    /// The handful of colours a picture of this theme is drawn from, by role. For a settings tile,
    /// which has to show what a theme looks like before anything has been drawn in it.
    ///
    /// Asked of the engine rather than of `variables`, because `variables` is one engine's
    /// vocabulary. The fallbacks on each side are that engine's own documented defaults -- mermaid's
    /// here, and for Pele the values its emitted `<svg>` carries in `var(--pele-bg,#fff)` and its
    /// neighbours -- so a tile drawn from a theme that said nothing still shows what that theme
    /// would actually draw.
    public var sample: (paper: String, ink: String, line: String, accent: String) {
        switch engine {
        case .mermaid:
            return (
                paper: variables["background"] ?? "#FFFFFF",
                ink: variables["primaryTextColor"] ?? "#000000",
                line: variables["lineColor"] ?? "#AEAEB2",
                accent: accent
            )
        case .pele(let pele):
            return (
                paper: pele["--pele-bg"] ?? "#FFFFFF",
                ink: pele["--pele-fg"] ?? "#1F1F1F",
                line: pele["--pele-line"] ?? "#1F1F1F",
                accent: accent
            )
        }
    }

    // MARK: - Editorial

    /// An imitation of the look at github.com/cathrynlavery/diagram-design, as far as mermaid can be
    /// made to go.
    ///
    /// The first cut of this theme kept the palette's restraint and lost the palette: every node was
    /// paper on paper behind a 12% hairline, and the coral was spent only on notes, which most
    /// previews do not contain. Measured against the source, that is the wrong half. Across its 56
    /// examples the coral is 9.5% of paint operations and lands on exactly one node -- three examples
    /// use none at all -- while 56% is an ink/muted/soft ramp. What makes those pages read as drawn
    /// rather than flat is the seven-rung node ladder, and what makes the ladder legible is its
    /// STROKE ramp: ink, muted, soft, and a light composite, with the fills only a wash apart. So the
    /// ladder below is built stroke-first, and the accent is the last thing spent rather than the fix.
    ///
    /// Three departures from the source, each with its own reason:
    ///
    /// The accent is fixed rather than the reader's. It marks the one thing to look at first --
    /// "coral is editorial, not a flag" -- and spending a reader's graphite or pink there would put a
    /// sixth colour into a five-colour palette at the place the palette works hardest.
    ///
    /// Arrow labels are 12px, not the source's 8px. Its own floor is "Hangul goes muddy below 12px;
    /// if a Korean name doesn't fit at 12px, cut the name, don't shrink the type", and Korean is first
    /// class here. Hierarchy is carried by weight and colour instead, which is how the source
    /// separates a node name from its sublabel anyway.
    ///
    /// No legend strip. The source mandates one and it is what normally licenses the colour, but a
    /// legend has to extend the viewBox before the glue measures the drawing or it falls outside every
    /// PNG and PDF export, and its words would enter the spoken narration as text the diagram does not
    /// contain. The redundancy requirement is met by construction instead: every rung differs from its
    /// neighbours in at least two of {fill, stroke, stroke width, dash}, so the whole ladder survives
    /// greyscale with the hue deleted.
    static func editorial(
        appearance: Appearance,
        increaseContrast: Bool
    ) -> MacMermaidTheme {
        let dark = appearance == .dark

        // The palette, verbatim.
        let paper = dark ? "#2D3142" : "#F5F5F5"
        let paper2 = dark ? "#393E53" : "#ECECEC"
        let ink = dark ? "#F5F5F5" : "#2D3142"
        let muted = dark ? "#BFC0C0" : "#4F5D75"
        let soft = dark ? "#8E98AC" : "#7A8399"
        // A hairline at 12% normally; the solid rule when the reader has asked for more contrast,
        // which is the source's own stronger border rather than a colour invented for the occasion.
        // It frames zones and secondary boxes only. It is deliberately NOT `nodeBorder` any more:
        // routing every border through a 12% alpha also painted ER relationship labels
        // (`.edgeLabel .label{fill:nodeBorder}`) and the state end bullet at 12%, which is how one
        // assignment produced three separate ghosts.
        let rule = increaseContrast ? (dark ? "#BFC0C0" : "#4F5D75")
                                    : (dark ? "rgba(245,245,245,0.12)" : "rgba(45,49,66,0.12)")
        let accent = dark ? "#F08A59" : "#EB6C36"
        // The second chromatic family, and the only one legible enough to carry meaning on its own:
        // 6.1:1 on light paper. Edges only -- the source never puts it on a node body.
        let link = dark ? "#6A95D8" : "#2E5AA8"
        // #6A95D8 is 4.24:1 on dark paper, under the readable ratio, so the words take a lighter mix
        // for the same reason the accent's do.
        let linkText = dark ? "#8FB3E8" : link

        // --- the ladder ------------------------------------------------------
        //
        // Four node surfaces, one hue, no legend. The fills are the source's `ink @ 0.0x`
        // expressions composited over `paper` and written as opaque hex -- not cosmetic: `parseRGB`
        // in flowpeek-glue.js drops alpha, so an rgba ink wash is measured by the label-contrast
        // pass as solid ink, the ink label above it computes at roughly 1:1, and the pass would
        // repaint it to `lightInk`, i.e. paper on paper.
        //
        // Measured honestly: adjacent fills are 1.02-1.15:1 apart, which is what the source ships
        // too. The ladder is carried by the STROKE ramp -- ink 11.8:1, muted 6.1:1, soft 3.4:1, a
        // 55% ink composite 3.2:1 -- each of which clears the 3:1 WCAG 1.4.11 asks of a graphical
        // object, with the fill and the dash as the second and third encodings.
        //
        // Increase Contrast reaches all of it -- it is the one accessibility control a reader has,
        // and the first cut of this ladder routed around it. The washes deepen by 1.6, the quiet
        // stroke goes from 3.2:1 to 4.5:1 (and stays below `muted`, so the ramp keeps its order),
        // every outline widens to 1.25px. Four rungs either way, each one
        // further from its neighbours.
        let wash = increaseContrast ? 1.6 : 1.0
        let inkWash = { (alpha: Double) in Self.blend(ink, alpha * wash, over: paper) }
        // The one rung the source does not derive: white in light, paper-2 in dark, because white on
        // a dark page would be brighter than the ink it is outlined with.
        let backendFill = dark ? paper2 : "#FFFFFF"
        let storeFill = inkWash(0.10)
        let entryFill = Self.blend(muted, 0.16 * wash, over: paper)
        let terminalFill = inkWash(0.04)
        // Not a rung: the faintest wash, which state composites and gantt sections still take.
        let faintFill = inkWash(0.02)
        // 0.10 in both appearances. style-guide.md says 0.10 and the shipped dark assets use 0.08;
        // on a screen at preview size the difference is one RGB level, so one number is stated here
        // rather than two that have to be kept in step.
        let focalFill = Self.blend(accent, 0.10, over: paper)
        // The quiet end of the stroke ramp. Composited rather than left as rgba() so it can be
        // reasoned about: 3.2:1 light, 4.8:1 dark. The source's own 0.30 measures 1.78:1, which is
        // not a boundary on a screen -- it gets away with it because it always ships a legend.
        let quietStroke = Self.blend(ink, increaseContrast ? 0.68 : 0.55, over: paper)
        let strokeWidth = increaseContrast ? "1.25px" : "1px"

        // Zones: an ink wash per nesting depth, so a reader sees how deep a box sits without counting
        // frames. The first cut of this theme drew every zone as a 12% hairline with no fill, and
        // the visual review found the cost: in a four-deep nest the levels looked alike, and a
        // one-level "Edge" group barely read as a group. Pele's answer is a wash per level -- a
        // cluster is `--_a` at 0.5 (see the `.pele` notes below), and with `--_a` at ink @ 0.16 that
        // stacks to ink @ 0.08, 0.12, 0.14 and 0.15 -- deeper than the store rung at 0.10 from the
        // second level on, so a cylinder there would sink into its zone.
        //
        // These stay under it, a fixed 0.02 per level, and the ceiling is set by the strokes, not by
        // the look. Darkening the ground under a node lowers the contrast of its outline, and the
        // first outline to go is `soft`, the entry stroke, at 3.48:1 on light paper; 0.08 is the
        // deepest wash it still clears 3:1 on (3.02:1), 0.09 is not (2.96:1). Measured as built,
        // light: 1.04:1 from each level to the next, 1.15:1 from paper to the fourth; dark: 1.06:1
        // and 1.27:1. `muted` eyebrow text stays at 5.29:1 or better on every rung in both.
        //
        // What it costs, measured rather than hidden: `quietStroke`, the terminal
        // outline, is 3.19:1 on light paper and falls to 2.98, 2.87 and 2.77:1 on the second to
        // fourth rungs, so a terminal node nested two deep or more is under 3:1 at the default
        // contrast. Holding it would mean a darker quiet stroke, which would pass `soft` and break
        // the ramp's order; Increase Contrast is the reader's way out, and it holds there (3.92:1 at
        // the deepest). Dark keeps it everywhere (3.74:1 at the deepest).
        //
        // Not deepened by Increase Contrast, unlike the node washes: there the zone outline is
        // already the solid `rule` (5.29:1 or better against every rung), which is the boundary
        // that setting asks for, and scaling the washes by 1.6 would take `soft` to 2.69:1.
        let zones = [0.02, 0.04, 0.06, 0.08].map { Self.blend(ink, $0, over: paper) }

        // A node in a zone takes its rung's wash over the ZONE, not over paper. The washes above
        // are the source's `ink @ 0.0x`, a translucent layer over whatever is under it; they are
        // composited over paper only because an rgba fill cannot be shipped (see the ladder note),
        // and once zones were filled that shortcut stopped meaning what the source means. The
        // fixed hexes landed on the zone ladder's own values: terminal (0.04) IS the depth-1 wash
        // and the optional rung there was then (0.02) the depth-0 wash, so a sink one zone deep measured 1.000:1 against
        // its ground in light and dark -- the second review's ghosted NAT Gateway -- and one rung
        // further down the sign flipped and the "marked" node was lighter than its zone. Dark's
        // backend has the same problem from the other side: paper-2 is 1.020:1 on the depth-2 wash
        // and darker than the depth-3 one. Composited over the ground, every rung keeps the ratio
        // and direction it has on paper at every depth, in all four appearances, within 0.06:1
        // (terminal light 1.073 on paper, 1.068-1.075 in zones; entry dark+IC 1.759 on paper,
        // 1.663-1.738 in zones); ink text stays 5.59:1 or better on the deepest of them.
        //
        // Dark's backend is not a wash of anything, so it is carried as the step from paper to
        // paper-2, taken from the ground instead. Light's is white, which no zone reaches.
        //
        // The rejected alternative was a shallower zone ladder that steps between the rungs. Five
        // node washes and four zone washes cannot all be kept apart in the 0.02-0.10 band the
        // `soft` stroke allows (see above), and it would still be the zone choosing how a node
        // reads; the node knowing its ground is one class (`fp-on-depth-N`) the renderer already
        // has the answer for.
        let onZones = { (fill: (String) -> String) in zones.map(fill) }
        let backendOnZones = onZones { ground in
            dark ? Self.shift(ground, by: paper2, from: paper) : backendFill
        }

        let ladder: [Rung] = [
            // The workhorse, and what a decision diamond gets too: the source's own legend draws
            // DECISION as a plain white diamond.
            Rung(token: "backend", fill: backendFill, onZones: backendOnZones,
                 stroke: ink, width: strokeWidth, dash: nil),
            // A cylinder [(…)] is the author declaring a datastore out loud -- the one place shape
            // decides a rung, and import-mermaid.md's own mapping.
            Rung(token: "store", fill: storeFill, onZones: onZones { Self.blend(ink, 0.10 * wash, over: $0) },
                 stroke: muted, width: strokeWidth, dash: nil),
            // In-degree 0. import-mermaid.md gives exactly this to its two entry rects, which are
            // the same shape as the backend rect beside them: structure decides, not shape.
            Rung(token: "entry", fill: entryFill, onZones: onZones { Self.blend(muted, 0.16 * wash, over: $0) },
                 stroke: soft, width: strokeWidth, dash: nil),
            // Out-degree 0. The quietest surface on the page -- measured, all three non-focal ovals
            // in the source's own flowchart take this, including the start oval.
            Rung(token: "terminal", fill: terminalFill, onZones: onZones { Self.blend(ink, 0.04 * wash, over: $0) },
                 stroke: quietStroke, width: strokeWidth, dash: nil),
            // No optional rung. It was given to a node whose every edge was `-.->` and drew it with a
            // dashed border, which put what the source said about a link onto the box at its end; the
            // held-out review read it as a claim on six nodes in three sources. A dashed line here is
            // now only ever a link. flowpeek-flow.js `tagLadder` has the rest.
            // No focal rung. The source spends its one coral on the node its author chose; a
            // flowchart names none, and the renderers picked one by degree instead -- measured, 8
            // of 172 sweep drawings and 6 of the review's 16 sources, five of which a reader took
            // as a claim the source never made. flowpeek-flow.js `tagLadder` has the numbers.
        ]

        // One family, extended with Apple SD Gothic Neo per the source's instruction to widen the
        // stack for Korean rather than swap the skin.
        //
        // The source wants three, and says the three-way contrast is load-bearing; this theme used to
        // follow it and paint arrow labels in ui-monospace tracked 0.04em. Rejected on what it drew,
        // not on taste. A connector label here is a phrase the author wrote ("no, the signature does
        // not match and the request may be forged", "결제 요청 및 영수증 발행"), not an identifier,
        // and set in mono it read as code. SF Mono's space is a full cell, so with the tracking a
        // word gap became a hole and a Hangul phrase fell apart into separate tokens; the tracking
        // also pried each syllable block off the next ("아 니 오"), against how Hangul is set. And
        // the mono is the wide face -- measured with CoreText at 12px, a space is 7.42px against the
        // sans's 3.38 and an "a" 7.42 against 6.62, while a Hangul syllable is 10.38 in both because
        // both fall back to Apple SD Gothic Neo -- so the same words took more of the edge budget:
        // a 4-line block on the review's 13. That budget was swept against the mono and has been
        // re-derived against this face (`EDGE_WRAP_PX`, flowpeek-flow.js). The contrast the
        // source wants between a node name and the words on an arrow is still here, carried the way
        // the 12px note above says this theme carries hierarchy: weight (600 against 400) and colour
        // (ink against muted).
        let sans = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Apple SD Gothic Neo', sans-serif"

        // A depth ladder for the three types mermaid indexes by depth itself. It alternates ink and
        // muted rather than stepping the ink wash, because `cScaleN` is used as an unstroked node
        // FILL *and* as the stroke of an 11px branch: a wash there is an eleven-pixel invisible line.
        var sections: [String: String] = [:]
        for rung in 0..<12 {
            sections["cScale\(rung)"] = rung % 2 == 0 ? ink : muted
            sections["cScaleLabel\(rung)"] = paper
            sections["cScaleInv\(rung)"] = muted
        }

        var variables: [String: String] = [
            "fontFamily": sans,
            // 12, from the allowed ramp of 8/12/16/20/24/28/32/40, and the Hangul floor.
            "fontSize": "12px",
            "background": paper,
            // The default node surface is the backend rung, so every type without a structural sweep
            // still gets a real box. `mainBkg` has to be said out loud: theme-default hardcodes
            // #ECECFF before its `||` defaults run, so `primaryColor` alone never reaches a node.
            "primaryColor": backendFill,
            "mainBkg": backendFill,
            "primaryTextColor": ink,
            "primaryBorderColor": muted,
            "nodeBorder": muted,
            "secondaryColor": paper2,
            "secondaryTextColor": ink,
            "secondaryBorderColor": rule,
            "tertiaryColor": paper2,
            "tertiaryTextColor": ink,
            "tertiaryBorderColor": rule,
            "lineColor": muted,
            "textColor": ink,
            "titleColor": ink,
            "nodeTextColor": ink,
            // What a zone the stylesheet cannot place by depth falls back to. The fills themselves
            // are in the stylesheet, by depth; see `zones` above.
            "clusterBkg": zones[0],
            "clusterBorder": rule,
            "edgeLabelBackground": paper,
            "labelColor": ink,
            // Notes give the accent up. A diagram with five notes drew five coral outlines, which is
            // the source's own "coral on every important node" anti-pattern; a note is not a rung.
            "noteBkgColor": terminalFill,
            "noteTextColor": ink,
            "noteBorderColor": muted,
            // Sequence. Its type sizes are set in the stylesheet below rather than here: these read
            // as numbers in mermaid's own sequence config, and a "12px" string handed to them as a
            // theme variable is dropped without complaint -- measured, the messages stayed at 16px
            // while every node label was 12.
            "actorFontFamily": sans,
            "messageFontFamily": sans,
            "noteFontFamily": sans,
            "actorBkg": backendFill,
            "actorBorder": ink,
            "actorTextColor": ink,
            "actorLineColor": muted,
            "signalColor": muted,
            "signalTextColor": ink,
            "labelBoxBkgColor": paper2,
            "labelBoxBorderColor": rule,
            "labelTextColor": ink,
            "loopTextColor": muted,
            // Furniture, not a focal element: a sequence diagram can carry a dozen activation bars.
            "activationBkgColor": storeFill,
            "activationBorderColor": muted,
            "sequenceNumberColor": paper,
            // State. The ladder mermaid gives away through variables alone.
            "stateBkg": backendFill,
            // MUST accompany stateBkg: theme-default evaluates
            // `stateLabelColor || stateBkg || primaryTextColor` BEFORE defaulting stateBkg, so
            // setting stateBkg alone paints every state label the colour of its own box.
            "stateLabelColor": ink,
            "stateBorder": ink,
            "specialStateColor": muted,
            // Reads as the end bullet's fill in mermaid's stylesheet, but nothing in 11.17.2 carries
            // `circle.state-end` -- the end pseudo-state is drawn as a two-path rough ring. Set to a
            // real colour anyway so that if mermaid starts emitting it, it is not the 12% ghost it
            // used to be. State diagrams get no accent: there is no element to put it on.
            "innerEndBackground": muted,
            "compositeBackground": faintFill,
            "compositeTitleBackground": paper2,
            "altBackground": storeFill,
            "transitionColor": muted,
            "transitionLabelColor": muted,
            "labelBackgroundColor": paper,
            // ER: the ink ladder applied to a table, for free.
            "rowOdd": backendFill,
            "rowEven": terminalFill,
            "erEdgeLabelBackground": paper,
            "classText": ink,
            "relationColor": muted,
            "relationLabelColor": muted,
            // Gantt, finished rather than half-touched: left alone it is periwinkle sections, a pure
            // red critical task and a literal `red` today-line. The today-line is the one thing a
            // reader looks at first and there is exactly one of it, so it is the accent; everything
            // else is the ladder, and the critical task is told apart by an ink border.
            "sectionBkgColor": faintFill,
            "altSectionBkgColor": paper,
            "sectionBkgColor2": storeFill,
            "excludeBkgColor": paper2,
            "taskBkgColor": backendFill,
            "taskBorderColor": muted,
            "taskTextColor": ink,
            "taskTextDarkColor": ink,
            "taskTextLightColor": paper,
            "taskTextOutsideColor": ink,
            "taskTextClickableColor": ink,
            "activeTaskBkgColor": entryFill,
            "activeTaskBorderColor": ink,
            "doneTaskBkgColor": terminalFill,
            "doneTaskBorderColor": soft,
            "critBkgColor": storeFill,
            "critBorderColor": ink,
            "gridColor": rule,
            "vertLineColor": rule,
            "todayLineColor": accent,
            // A mindmap's root is its one unambiguous focal element, so it takes the focal tint --
            // one accent, no heuristic. `git0`/`gitBranchLabel0` are shared with gitGraph's branch 0,
            // which therefore also becomes pale coral: accepted, it is the trunk.
            "git0": focalFill,
            "gitBranchLabel0": ink,
            "errorBkgColor": terminalFill,
            "errorTextColor": ink,
        ]
        variables.merge(sections) { current, _ in current }

        // What the variables cannot say. Every colour here is a token above; the structural class
        // tokens (`fp-backend` … `fp-terminal`, `fp-cross`) are written by
        // flowpeek-glue.js from the graph's own shape, and every decision about what they look like
        // is here. Specificity is (0,2,1) against mermaid's own (0,1,1), so no `!important` is
        // needed -- and an author's `classDef`, which mermaid emits after this stylesheet with
        // `!important`, still beats all of it by construction.
        let css = """
        /* The glue runs its structural sweep only for a theme whose stylesheet can paint what the
           sweep tags. It looks for this marker in the theme CSS before mermaid ever compiles it, so
           the system theme -- which has no `.fp-` rules -- is untouched and its goldens do not move.
           The rule itself matches nothing. */
        .fp-ladder { --fp-ladder: on; }
        /* rx only where it does something. It is inert on <polygon> and <path>, whose corners live
           in `points`/`d`, and `:not([rx])` leaves mermaid's own rx="5" on `(round)` alone -- that
           attribute is the one shape cue separating `[rect]` from `(round)`. */
        .node rect.basic:not([rx]) { rx: 6px; ry: 6px; }
        .node rect, .node polygon, .node path, .node circle, .node ellipse { stroke-width: \(strokeWidth); }
        /* A zone takes the wash of its depth. `fp-depth-N` is written by flowpeek-flow.js; a zone
           drawn by mermaid carries no depth and takes the first rung. The last rule is depth 3 and
           everything under it, written as "has a depth class and is not 0-2" so the renderer does
           not have to know how many rungs there are. */
        .cluster rect { fill: \(zones[0]); stroke: \(rule); stroke-width: 0.8px; rx: 8px; ry: 8px; }
        .cluster.fp-depth-1 rect { fill: \(zones[1]); }
        .cluster.fp-depth-2 rect { fill: \(zones[2]); }
        .cluster[class*="fp-depth-"]:not(.fp-depth-0):not(.fp-depth-1):not(.fp-depth-2) rect { fill: \(zones[3]); }
        /* 600 on the name, 400 everywhere else: the source carries hierarchy in weight and colour
           rather than in size, which is what lets every label sit on the 12px Hangul floor. */
        .node .label text, .node .nodeLabel, .nodeLabel { font-weight: 600; }
        /* `==>` is the author asking for weight, and weight is this theme's non-colour channel, so
           it is scoped around rather than flattened -- but brought into the ladder's range from
           mermaid's 3.5px. */
        .edgePath path:not(.edge-thickness-thick), .flowchart-link:not(.edge-thickness-thick), .relation {
            stroke-width: 1.2px;
        }
        .flowchart-link.edge-thickness-thick, .edgePath path.edge-thickness-thick { stroke-width: 2.4px; }
        /* The sans, untracked: why not the mono is at `sans` above. `letter-spacing` is said rather
           than left out because mermaid's own stylesheet is not the only thing that could set it,
           and the renderer measures this register at `normal` (flowpeek-flow.js `makeMetrics`). */
        .edgeLabel, .edgeLabel .label text, .edgeLabel foreignObject div {
            font-family: \(sans);
            font-weight: 400;
            letter-spacing: normal;
            color: \(muted);
            fill: \(muted);
        }
        .edgeLabel rect, .edgeLabel .background, rect.background { fill: \(paper); }
        /* The zone eyebrow. The source sets this in `soft`, which measures 3.5:1 on paper -- fine
           for an outline, under this app's own 4.5:1 bar for words, and the label-contrast pass
           never sees a cluster label. `soft` stays what it is here: a stroke colour, not an ink. */
        .cluster .cluster-label text, .cluster text { fill: \(muted); font-weight: 600; letter-spacing: 0.06em; }
        marker path, marker polygon, .marker { fill: \(muted); stroke: \(muted); }

        /* The ladder. Mermaid emits no shape class and no shape attribute, so each rung has to name
           every form it can be drawn as: rect.basic (rect and round), circle.basic, polygon
           (diamond, hexagon, subroutine, parallelogram, trapezoid), the bare path (cylinder), the
           circles inside a doublecircle's wrapper, and the two-path group (stadium, terminator),
           whose fill and outline are different elements -- one rule setting both would fill the
           outline path and double-paint the shape. */
        \(ladder.map(Self.rungCSS).joined(separator: "\n"))

        /* The edge class, for a path that leaves one zone and enters another -- the source's
           own trigger for it. The dash is not decoration: hue alone would be the only carrier, and
           link-blue against muted is 1.003:1 in greyscale. Never on a node body. */
        .flowchart-link.fp-cross, .edgePath path.fp-cross { stroke: \(link); stroke-dasharray: 6,3; }
        marker.fp-marker-cross path, marker.fp-marker-cross polygon { fill: \(link); stroke: \(link); }
        .edgeLabels g.label.fp-cross text, .edgeLabels g.label.fp-cross tspan { fill: \(linkText); }

        /* Sequence draws its own lines outside the edge classes above, and its dashed reply arrow
           kept mermaid's stock violet: measured, the variables alone do not reach it. */
        .messageLine0, .messageLine1, line.loopLine, .actor-line {
            stroke: \(muted);
            stroke-width: 1.2px;
        }
        /* Sequence writes `font-size: 16px` inline onto every <text> it draws, from its own config,
           and measured: setting actorFontSize and messageFontSize there does not change it. An
           inline style beats a stylesheet, so this is one of the two places in this theme that has
           to insist -- the alternative is the one diagram type that is mostly words sitting four
           points off every other type. */
        .messageText { fill: \(ink); font-size: 12px !important; font-weight: 400 !important; }
        text.actor, text.actor > tspan, .actor-box text {
            font-size: 12px !important;
            font-weight: 600 !important;
        }
        .noteText, .noteText > tspan { font-size: 12px !important; font-weight: 400 !important; }
        .loopText, .loopText > tspan, .labelText { font-size: 12px !important; }
        .messageText, .loopText, .noteText { font-weight: 400; }
        /* Flat by construction: the source's first anti-pattern is a shadow. */
        .node *, .cluster *, .edgePath * { filter: none; }
        .label, .nodeLabel, text { -webkit-font-smoothing: antialiased; }
        /* The same mermaid 11.17.2 patch the system theme carries, for the same reason: mindmap
           labels are drawn by the shared node renderer while mindmap's own stylesheet still centres
           a class it no longer emits, so without this the text starts at the node's midpoint. */
        .mindmap-node .label text, .mindmap-node > text { text-anchor: middle; }
        """

        return MacMermaidTheme(
            appearance: appearance,
            variables: variables,
            css: css,
            fontFamily: sans,
            // The face `.edgeLabel` paints, so the renderer measures what it draws.
            monoFontFamily: sans,
            // Gaps from the source's own allowed ramp (20/24/32/40/48); 32 and 40 sit between its
            // 24 "standard" and 40 "presentation" figures, and a preview is closer to presentation.
            // `padding` is held here rather than handed to `look: "neo"`, which would replace it
            // with per-shape constants nobody can reach.
            arrangement: MermaidArrangement(
                nodeSpacing: 32,
                rankSpacing: 40,
                padding: 16,
                // The bottom of the ramp. The margin is drawn inside the picture that is then scaled
                // to fit, so it buys no room on screen and only makes every label smaller. The preview
                // frames the SVG twice already -- the glue's `fit()` keeps `vp.pad` 24px each side,
                // inside `DiagramStage`'s 8 or 14pt inset -- while `DiagramExporter` adds nothing,
                // so this is an export's only frame and the case the number has to serve. Over
                // differential.mjs's 175 drawings the total area is 12,291,296 px² at 24 and
                // 11,544,256 at 20, against Pele's 9,969,933 at its own 8. Lower values were measured
                // and not taken: the ramp is the source style's and not this file's to extend. Wider
                // than the flow renderer: mermaid draws state and class diagrams with this margin too.
                diagramPadding: 20,
                // What every family that reads mermaid's one curve setting gets, unchanged.
                curve: "rounded",
                // And what a true flowchart gets instead: orthogonal routing, which is the half of
                // the source's connector rule only the layout engine can do. `rounded` rounds the
                // bends but leaves dagre free to run an edge diagonally between ranks, and
                // "diagonal connectors are an automatic fail" there. The square corners `step`
                // leaves are rounded into quarter-arcs by `roundEdges` in the glue -- the half only
                // a path rewrite can do. Kept off every other family: a state diagram renders
                // through the same dagre code, and `step` there detached every arrowhead.
                flowchartCurve: "step",
                wrappingWidth: 160
            ),
            // A repainted label lands on the theme's own two ends.
            darkInk: ink,
            lightInk: paper,
            accent: accent
        )
    }

    // MARK: - Pele

    /// FlowPeek's editorial colours handed to Pele (github.com/obsidianmd/pele), which draws them
    /// its own way.
    ///
    /// Pele is a third-party renderer, MIT, vendored at `Resources/pele.global.js`. It is a third
    /// option rather than a replacement, and it is not here because it agrees with the other two: it
    /// decides a diagram's layout itself and it respects mermaid's own direction less than
    /// FlowPeek's renderer does. So this theme sets colour and type and nothing else. There is no
    /// arrangement to ask for -- `MermaidArrangement` is mermaid's dagre config, which Pele never
    /// reads -- and no stylesheet, because Pele is themed through the `--pele-*` custom properties
    /// below and nothing else.
    ///
    /// What it shares with `.editorial` is the palette, so the three entries in the picker read as
    /// one app: paper #F5F5F5, ink #2D3142, muted #4F5D75, soft #7A8399, and their dark
    /// counterparts. What it does not share is the ladder -- Pele chooses its own node surfaces --
    /// nor, any longer, every chromatic hex: Pele puts the palette in places editorial never does,
    /// and three of them are measured below.
    ///
    /// THE MAPPINGS THAT ARE NOT ONE-TO-ONE, because Pele's vocabulary is smaller:
    ///
    /// `--pele-line` takes `ink`, not `muted`. Editorial separates a node outline (ink) from an edge
    /// (`lineColor`, muted); Pele has one variable for both, and its own default sets it equal to
    /// `--pele-fg`. Keeping that relationship keeps the weight balance Pele was drawn against;
    /// giving it `muted` would lighten every connector relative to every word, which is editing
    /// Pele's drawing rather than recolouring it. `--pele-border` -- Pele's own default #8a8a8a is a
    /// mid grey, not a hairline -- takes the role editorial's `rule` plays, so it gets `soft`:
    /// 3.48:1 on light paper, 4.44:1 on dark, clearing the 3:1 WCAG 1.4.11 asks of a graphical
    /// object. ink is 11.82:1 in both, muted 6.11/7.07.
    ///
    /// WHAT A BACKGROUND-COLOURED LABEL COSTS. Pele paints a label that sits on a filled shape as
    /// `<text class="pele-label" fill="var(--_bg)">` -- the PAGE colour, chosen without looking at
    /// what is underneath. Grepping the bundle for `var(--_bg)` used as a text fill, four fills can
    /// end up carrying one, and every one of them is reachable from a property set here:
    ///   - `--pele-accent`, a gantt task bar whose label fits inside it (pele.global.js `Ae`/`he`);
    ///   - `--pele-critical`, the same bar when the task is `crit` -- the crit branch is chosen
    ///     before the label branch, so a crit bar gets a bg label too;
    ///   - `--pele-series-N`, a pie slice label, a treemap leaf label, a gitgraph branch label;
    ///   - `--pele-line`, the sequence message-number badge -- ink under paper, 11.82:1, already
    ///     the strongest pairing in the theme and the reason `--pele-line` is not touched here.
    /// So every one of those fills has to hold 13px regular text, which is WCAG AA 4.5:1; the
    /// large-text 3:1 exception does not reach 13px regular. That is the floor the accent, the
    /// critical colour and all eight series are built to below -- not 3:1, which is what a fill
    /// nobody writes on needs and what this theme used to ask of them.
    ///
    /// `--pele-accent` is therefore a deeper coral in light: #B24212, 5.23:1, where #EB6C36 was
    /// 2.86:1. The hue is unmoved (18 degrees in both), so it is the editorial coral burnt down
    /// rather than a new colour; the dark accent is the editorial token #F08A59 untouched, because
    /// it already measures 5.21:1. Accent is not only a chart fill, so every place it lands was
    /// measured before it moved -- six sites in the bundle, and not one of them is worse for it.
    /// It is the gantt bar fill (the defect); the gantt today-line, a 2px stroke and a small solid
    /// head, which goes 2.86 to 5.23 and was only ever asked for 3:1; a kanban ticket link, which
    /// is real 13px TEXT on paper and was failing at 2.86:1 -- that one is fixed as a side effect;
    /// a wardley trend arrow and its circle, strokes on paper, likewise stronger; and a tree-view
    /// row highlight, accent at 0.14 opacity, which gets slightly deeper with the ink on top of it
    /// going 10.27:1 to 9.67:1. The cost is
    /// real and it is this: on paper, as a focal stroke, #B24212 is a quieter coral than #EB6C36.
    /// Taking the other side -- leaving accent bright and darkening only the gantt bar -- is not
    /// available, because the bar IS `--_c`; there is no separate bar property to set.
    ///
    /// `--pele-critical` is now set, reversing the earlier decision to leave it at Pele's #e45756.
    /// That decision was right about words and wrong about this: #e45756 is 3.32:1 light and 3.56:1
    /// dark, which is fine for a stroke and not fine under a label, and a crit gantt bar carries
    /// one. #D72422 (4.62:1) and #EA7978 (4.61:1) are the same hue, deepened to clear the floor.
    /// `--pele-error` stays unset on purpose and the reason is now reachability, not contrast:
    /// it colours only the HTML error overlay Pele's `mount` API creates, and FlowPeek calls
    /// `pele.render` directly and reports its own failures, so nothing in this app ever paints it.
    ///
    /// THE SERIES RAMP. Series 1 and 2 stay the theme's own two chromatic families, accent and link.
    /// Series 3 is no longer `muted`: `muted` is also `--pele-muted` and, under Increase Contrast,
    /// `--pele-border`, so in a pie it read as the inactive slice because it literally was the
    /// chrome colour. The remaining six are Pele's own default hues -- green, purple, gold, brown,
    /// teal -- plus one indigo, placed in the 217-to-318 degree gap, which is the widest hole the
    /// other seven leave on the hue circle, so it is spaced off the ramp rather than invented.
    /// Pele's own #e45756 is still kept out of the ramp, and now for a sharper reason than before: a
    /// red here would be the critical colour this theme has just started setting.
    ///
    /// Every member is pinned to a target ratio against the paper, and the SAME target is used in
    /// both appearances. That is what makes the rank order survive a theme switch -- sorted by
    /// contrast, the ramp is 5 < 7 < 3 < 1 < 4 < 2 < 8 < 6 in light and 5 < 7 < 3 < 1 < 4 < 2 < 8 < 6
    /// in dark, the same list. Light measures 5.23, 6.13, 4.94, 5.45, 4.71, 6.74, 4.81, 6.22; dark
    /// 5.21, 6.15, 4.92, 5.49, 4.72, 6.70, 4.81, 6.20. Two targets are chosen to leave a token
    /// exactly where it was: 5.21 is the dark accent's own measurement, so the dark coral is still
    /// #F08A59, and 6.13 is the light link's, so the light blue is still #2E5AA8.
    ///
    /// Series 5 is the ramp's one deliberate break from mirroring itself, and it is here because a
    /// ratio target does not pin a colour's WEIGHT. Hue 48 is intrinsically luminous -- relative
    /// luminance weights green at .7152 and red at .2126, and a yellow is most of both -- so at the
    /// chroma the other members carry it reaches its target against the dark paper far earlier than
    /// they do. Mirrored, it came out #BB9910: lightness 40% where every other dark member sits
    /// between 52% and 74%, which in a pie read as one saturated ochre slice among seven pastels.
    /// Dropping only the DARK gold to 35% chroma makes it hit the same 4.72:1 at 51% lightness, in
    /// the band with the rest. The cost is stated rather than hidden: gold is now the one member
    /// whose chroma differs between appearances (85% light, 35% dark), and it moves nearer brown in
    /// dark (dE 57.9 to 32.6, against 45.1 for the coral-brown pair that is already accepted). The
    /// alternative -- dropping both -- was measured and rejected: it leaves dark lightness at 48%,
    /// still outside the band, so it changes the light ramp without fixing the dark one.
    ///
    /// The order of the eight is a packing decision, not a preference. Eight colours between 4.71
    /// and 6.74 can differ by at most 1.43:1 from each other, so value cannot separate all of them
    /// and hue has to; the ramp is ordered so that neighbours are far apart in hue (the smallest
    /// index-adjacent hue gap is 81 degrees, between indigo and teal) and the pairs that are CLOSE
    /// in hue are pushed apart in value instead: gold and brown sit 26 degrees apart and 1.43:1
    /// apart, coral and brown 4 degrees apart and 1.29:1, blue and indigo 39 and 1.27:1, coral and
    /// gold 30 and 1.11:1. The weakest index-adjacent pair in value is 3-4, green and purple at
    /// 1.10:1 -- 157 degrees of hue between them.
    ///
    /// THE SURFACE. `--pele-surface` was `paper2`, and `paper2` against `paper` is 1.08:1 light and
    /// 1.22:1 dark. For a node that is defensible and editorial does the same thing -- its workhorse
    /// node face is white on #F5F5F5, 1.09:1, with the boundary carried by the outline. Pele does
    /// not always draw that outline. Four constructs fill with `--_s` and set no stroke at all: the
    /// gantt section band, the kanban column, the event-model lane, and the sequence frame tab. In
    /// those the step IS the signal, which is why three gantt sections read as two. So the BASE step
    /// moves, and the claim is about Pele specifically: editorial leans on a node ladder with five
    /// rungs above its paper, Pele leans on this one value.
    ///
    /// `ink @ 0.08` over paper, scaled by the same 1.6 the editorial ladder uses, which makes
    /// Increase Contrast reach it at last -- 1.15:1 to 1.26:1 light, 1.27:1 to 1.47:1 dark.
    /// `--pele-surface-alt` follows to `ink @ 0.16` so the two do not merge: paper to surface is
    /// 1.15:1 and surface to surface-alt 1.16:1 in light, 1.27:1 and 1.27:1 in dark -- an even
    /// three-rung ladder, and each step is the rung step of editorial's own node ladder
    /// (`faintFill` at ink @ 0.02 against `storeFill` at ink @ 0.10: 1.16:1 light, 1.28:1 dark)
    /// rather than a number invented here. Ink still clears everything that sits on them: 8.05:1 at
    /// worst on surface, 5.48:1 at worst on surface-alt, both in dark + contrast.
    ///
    /// The depth is held by the ladder and by the picture, NOT by WCAG 1.4.11 against the fill the
    /// border encloses. That measure was tried first and abandoned, and the abandonment is worth
    /// recording because it is easy to re-derive: `soft` against its own node fill is 3.02:1 light
    /// and 3.50:1 dark at 0.08 and 2.96:1 light at 0.09, which looks like it pins the value -- but
    /// Increase Contrast then deepens the fill to 0.128 and the same measure falls to 2.77:1, so
    /// the rule fails at the setting a reader turns on to see better. Against `--pele-surface-alt`
    /// it never held at all (2.61:1 light, 2.75:1 dark). The measure is the wrong one: what 1.4.11
    /// wants perceivable is the component's boundary against what is OUTSIDE it, which is `soft`
    /// against the paper -- 3.48:1 light, 4.44:1 dark, rising to 6.11:1 and 7.07:1 under Increase
    /// Contrast as the border goes to `muted`. That is asserted. And the two signals trade off in
    /// the right direction: a deeper fill is a quieter border against its own interior and a
    /// stronger shape against the page (surface-alt vs paper goes 1.33:1 to 1.62:1 in light), so
    /// the contrast switch never leaves the reader with less than it found.
    ///
    /// The other end of the range is a real ceiling: a band dark enough to hit 3:1 against the
    /// paper cannot hold ink at 4.5:1. The deepest wash that still does is alpha 0.4719 in light
    /// and 0.3239 in dark, and those measure 2.61:1 and 2.62:1 against their paper -- so 3:1 is
    /// unavailable to any surface that gets written on, and no band here may pass 2.6:1.
    ///
    /// Increase Contrast now reaches three values rather than two: `--pele-border` goes soft to
    /// muted (3.48 to 6.11 light, 4.44 to 7.07 dark) and both surfaces deepen by 1.6. It still does
    /// not touch the ramp or the accent -- every one of those already clears 4.5:1 in all four
    /// appearances, so there is nothing there for it to fix, and moving them would only compress the
    /// ramp's own separation -- nor `--pele-line`, which is the top of the ramp already.
    static func pele(appearance: Appearance, increaseContrast: Bool) -> MacMermaidTheme {
        let dark = appearance == .dark

        // The editorial palette, same tokens, same hexes -- except the coral, which is deepened in
        // light because Pele writes bg-coloured labels on it. See the note above for the six places
        // the accent lands and what the move costs each of them.
        let paper = dark ? "#2D3142" : "#F5F5F5"
        let ink = dark ? "#F5F5F5" : "#2D3142"
        let muted = dark ? "#BFC0C0" : "#4F5D75"
        let soft = dark ? "#8E98AC" : "#7A8399"
        // 5.23:1 light (was #EB6C36, 2.86:1), 5.21:1 dark -- the dark editorial token untouched,
        // because 5.21 is already over the 4.5:1 a label on a gantt bar needs. Hue 18 either way.
        let accent = dark ? "#F08A59" : "#B24212"
        // The same job on the other side of the ramp: the LIGHT editorial token untouched at
        // 6.13:1, the dark one lifted from #6A95D8 (4.24:1, under the floor) to 6.15:1.
        let link = dark ? "#96B5E4" : "#2E5AA8"
        // Pele's own critical hue, deepened from #e45756 (3.32/3.56) to clear the same floor: a
        // `crit` gantt task is drawn in this and its label is painted in the page colour.
        let critical = dark ? "#EA7978" : "#D72422"

        let wash = increaseContrast ? 1.6 : 1.0
        // The arithmetic done here and shipped as opaque hex, as `.editorial` does it: an `rgba()`
        // handed to a custom property composites over whatever is behind the `<svg>` at paint time,
        // not over this theme's paper, so a wash stated that way is a different colour depending on
        // where the drawing is shown.
        //
        // A wash rather than `paper2`, which is what makes Increase Contrast able to move it at all.
        // 0.08 and 0.16 put the two steps at 1.15:1 and 1.16:1 in light, 1.27:1 and 1.27:1 in dark,
        // matching the rung step of editorial's own node ladder. See the note above for why the
        // depth is not pinned by the border against the fill it encloses.
        let surface = Self.blend(ink, 0.08 * wash, over: paper)
        let surfaceAlt = Self.blend(ink, 0.16 * wash, over: paper)

        let sans = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Apple SD Gothic Neo', sans-serif"
        let mono = "ui-monospace, 'SF Mono', Menlo, 'Apple SD Gothic Neo', monospace"

        // coral, blue, green, purple, gold, brown, indigo, teal. Every one carries bg-coloured text
        // in a pie, a treemap or a gitgraph, so every one is pinned to a target ratio against the
        // paper and the same target is used in both appearances -- which is what holds the rank
        // order across a theme switch. No member is a structural colour: `muted` used to be third.
        let series = dark
            ? [accent, link, "#61B258", "#C69DBB", "#AE9C56", "#CCB7AA", "#A596CC", "#82BFBA"]
            : [accent, link, "#3E7737", "#8B507B", "#846B0B", "#6C5040", "#765EB1", "#336360"]

        var variables: [String: String] = [
            "--pele-bg": paper,
            "--pele-fg": ink,
            "--pele-muted": muted,
            "--pele-line": ink,
            "--pele-surface": surface,
            "--pele-surface-alt": surfaceAlt,
            "--pele-border": increaseContrast ? muted : soft,
            "--pele-accent": accent,
            "--pele-critical": critical,
            // Editorial rounds a node at 6px and a zone at 8px. Pele has one radius for both, so it
            // gets the node's: it is the corner on almost every shape in almost every diagram.
            "--pele-radius": "6px",
            "--pele-font": sans,
            "--pele-font-mono": mono,
        ]
        // Pele reads these as `--pele-series-1` through `--pele-series-8` and wraps modulo 8.
        for (index, colour) in series.enumerated() {
            variables["--pele-series-\(index + 1)"] = colour
        }

        return MacMermaidTheme(
            appearance: appearance,
            // Empty on purpose, both of them. These are mermaid's `themeVariables` and mermaid's
            // stylesheet, and this theme is not drawn by mermaid; a plausible-looking set here would
            // be a second palette nobody renders and nobody maintains. The emptiness also keeps the
            // glue honest by construction: its structural sweep and its arrowhead rewrite both
            // trigger on finding `.fp-ladder` in this string, so there is nothing here for either to
            // find.
            variables: [:],
            css: "",
            fontFamily: sans,
            monoFontFamily: mono,
            arrangement: .unset,
            // BOTH ends are the ink, which is not the shape `.editorial` gives this pair, and the
            // reason is measured. The label-contrast pass does run on Pele's output, and the only
            // labels it ever corrects there are the ones sitting on a fill Pele drew with
            // `fill-opacity` -- a gantt `active` bar is `--_c` at 0.25, a cluster is `--_a` at 0.5,
            // a cynefin region 0.18. `parseRGB` in the glue keeps only the rgb and drops the alpha,
            // so the pass measures the SOLID colour and the paint is a wash of it over the paper.
            // Every one of those washes is near the paper, so the ink is always the right answer
            // and the paper is always the wrong one: on the light `active` bar, really #E4C8BC, ink
            // reads 8.15:1 and the paper 1.45:1; on the dark one, really #5E4748, 7.80:1 and
            // 1.52:1. Leaving `lightInk` as the paper is what put page-coloured text on a mid-tone
            // fill one more time, by our own hand rather than Pele's -- in dark that had already
            // happened, because ink on the solid dark accent measures 2.27:1 and the pass has been
            // flipping that label to the paper since the day this theme shipped. Every fill the
            // pass measures CORRECTLY under this theme already clears its threshold, so nothing is
            // given up by never choosing the light end.
            darkInk: ink,
            lightInk: ink,
            accent: accent,
            engine: .pele(variables: variables)
        )
    }

    /// One rung of the node ladder: a fill, a stroke, and the two channels that are not colour.
    private struct Rung {
        let token: String
        let fill: String
        /// The fill on each zone depth, deepest last; the last entry also serves every depth below it.
        let onZones: [String]
        let stroke: String
        let width: String
        let dash: String?
    }

    private static func rungCSS(_ rung: Rung) -> String {
        let dash = rung.dash.map { " stroke-dasharray: \($0);" } ?? ""
        return """
        .node.fp-\(rung.token) rect.basic,
        .node.fp-\(rung.token) circle.basic,
        .node.fp-\(rung.token) polygon.label-container,
        .node.fp-\(rung.token) path.basic.label-container,
        .node.fp-\(rung.token) g.label-container circle {
            fill: \(rung.fill); stroke: \(rung.stroke); stroke-width: \(rung.width);\(dash)
        }
        .node.fp-\(rung.token) g.outer-path path:nth-child(1) { fill: \(rung.fill); stroke: none; }
        .node.fp-\(rung.token) g.outer-path path:nth-child(2) {
            fill: none; stroke: \(rung.stroke); stroke-width: \(rung.width);\(dash)
        }
        """ + rung.onZones.enumerated().compactMap { depth, fill -> String? in
            // Every depth or none: the selectors do not cascade into one another, so a depth left
            // out would fall back to the paper fill, not to the depth above it.
            guard rung.onZones.contains(where: { $0 != rung.fill }) else { return nil }
            // `fp-on-depth-N` is written on a node by flowpeek-flow.js (and as 0 by the glue, whose
            // zones all take the first rung); the last depth matches as "has one and is not 0..N-1",
            // the same uncapped form the zone rules use.
            let on = depth < rung.onZones.count - 1
                ? ".fp-on-depth-\(depth)"
                : "[class*=\"fp-on-depth-\"]" + (0..<depth).map { ":not(.fp-on-depth-\($0))" }.joined()
            let node = ".node.fp-\(rung.token)\(on)"
            return "\n\(node) rect.basic, \(node) circle.basic, \(node) polygon.label-container, "
                + "\(node) path.basic.label-container, \(node) g.label-container circle, "
                + "\(node) g.outer-path path:nth-child(1) { fill: \(fill); }"
        }.joined()
    }

    /// `colour`'s step away from `from`, taken from `base` instead, as an opaque hex.
    private static func shift(_ base: String, by colour: String, from origin: String) -> String {
        guard let b = channels(base), let c = channels(colour), let o = channels(origin) else { return base }
        let moved = (0..<3).map { min(255, max(0, b[$0] + c[$0] - o[$0])) }
        return String(format: "#%02X%02X%02X", moved[0], moved[1], moved[2])
    }

    /// `colour @ alpha` over `base`, as an opaque hex.
    ///
    /// The source states its ladder as `ink @ 0.05`; this does that arithmetic here instead of
    /// shipping the `rgba()`. Not cosmetic: `parseRGB` in flowpeek-glue.js keeps only the rgb and
    /// drops the alpha, so an rgba ink wash is measured by the label-contrast pass as solid ink --
    /// the ink label above it computes at roughly 1:1 and the pass repaints it to `lightInk`, which
    /// is paper on paper. Anything that stays `rgba()` here is a stroke, which that pass never reads.
    private static func blend(_ colour: String, _ alpha: Double, over base: String) -> String {
        guard let top = channels(colour), let bottom = channels(base) else { return colour }
        let mixed = (0..<3).map { index -> Int in
            let value = Double(bottom[index]) + (Double(top[index]) - Double(bottom[index])) * alpha
            return min(255, max(0, Int(value.rounded())))
        }
        return String(format: "#%02X%02X%02X", mixed[0], mixed[1], mixed[2])
    }

    private static func channels(_ hex: String) -> [Int]? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return [(value >> 16) & 255, (value >> 8) & 255, value & 255]
    }

    /// For a theme that supplies its own values outright rather than deriving them from the
    /// system's. Not public: a theme belongs in the catalogue beside the others, not at a call site.
    init(
        appearance: Appearance,
        variables: [String: String],
        css: String,
        fontFamily: String,
        monoFontFamily: String? = nil,
        arrangement: MermaidArrangement,
        darkInk: String,
        lightInk: String,
        accent: String,
        // Defaulted so that the two themes written before there was a second vocabulary say
        // nothing about one. There is no `.mermaid` theme that would rather be something else.
        engine: Engine = .mermaid
    ) {
        self.engine = engine
        self.appearance = appearance
        self.variables = variables
        self.css = css
        self.fontFamily = fontFamily
        // A theme that paints its edge labels in the body face says nothing, and gets the body face.
        self.monoFontFamily = monoFontFamily ?? fontFamily
        self.arrangement = arrangement
        self.darkInk = darkInk
        self.lightInk = lightInk
        self.accent = accent
    }

    public init(appearance: Appearance, accentHex: String, increaseContrast: Bool) {
        self.appearance = appearance
        engine = .mermaid
        let dark = appearance == .dark
        fontFamily = Self.systemFontStack
        monoFontFamily = Self.systemFontStack
        arrangement = .unset
        darkInk = LabelContrast.darkInk
        lightInk = LabelContrast.lightInk
        accent = accentHex
        let line = dark ? (increaseContrast ? "#98989D" : "#636366") : (increaseContrast ? "#636366" : "#AEAEB2")
        variables = [
            "fontFamily": Self.systemFontStack,
            "fontSize": "15px",
            "background": dark ? "#1C1C1E" : "#FFFFFF",
            "primaryColor": dark ? "#2C2C2E" : "#F2F2F7",
            "primaryTextColor": dark ? "#FFFFFF" : "#000000",
            "primaryBorderColor": line,
            "lineColor": line,
            "secondaryColor": dark ? "#3A3A3C" : "#E5E5EA",
            "tertiaryColor": dark ? "#1C1C1E" : "#FFFFFF",
            "noteBkgColor": dark ? "#3A3A3C" : "#FFF9C4",
            "noteTextColor": dark ? "#FFFFFF" : "#1C1C1E",
            "actorBkg": dark ? "#2C2C2E" : "#F2F2F7",
            "actorBorder": accentHex,
            "actorTextColor": dark ? "#FFFFFF" : "#000000",
            "signalColor": line,
            "signalTextColor": dark ? "#FFFFFF" : "#000000",
            "labelBoxBkgColor": dark ? "#2C2C2E" : "#F2F2F7",
            "labelBoxBorderColor": line,
            "labelTextColor": dark ? "#FFFFFF" : "#000000",
            "loopTextColor": dark ? "#FFFFFF" : "#000000",
            "activationBkgColor": dark ? "#3A3A3C" : "#E5E5EA",
            "activationBorderColor": accentHex,
        ]
        // The mindmap rule is a patch over mermaid 11.17.2, not a preference. Mindmap labels are
        // drawn by the shared node renderer -- `.node.mindmap-node > .label > text`, with the
        // tspan at `x="0"` -- while mindmap's own stylesheet still centres `.mindmap-node-label`,
        // a class the renderer no longer emits: it appears once in the CSS and on nothing at all.
        // With no `text-anchor`, the text starts at the node's centre and runs off its right edge.
        // Measured on `mindmap\n    id[I am a square]`: a 125-point box with the label beginning at
        // its midpoint. Every other type ships `.node .label text{text-anchor:middle}` and is fine,
        // which is why this is one selector rather than a blanket rule.
        css = """
        .node rect,.node circle,.node polygon,.node path { stroke-width: 1.25px; }
        .edgeLabel { background-color: transparent !important; }
        .label, .nodeLabel, text { -webkit-font-smoothing: antialiased; }
        .mindmap-node .label text, .mindmap-node > text { text-anchor: middle; }
        """
    }
}
