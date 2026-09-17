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
    /// The face this theme paints EDGE LABELS in, which need not be `fontFamily` and in the
    /// editorial theme is not: its `.edgeLabel` rule sets a monospace stack. It is carried in the
    /// payload because the renderer measures a label before it draws it and has to measure the face
    /// that will be painted -- measuring the sans and painting the mono made every edge label's
    /// backing rect narrower than the words on it, which is text spilling off both ends of its own
    /// mask, visible on cand.mmd's two "originalQuoteId" labels at the edges of the drawing.
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
    public var sample: (paper: String, ink: String, line: String, accent: String) {
        (
            paper: variables["background"] ?? "#FFFFFF",
            ink: variables["primaryTextColor"] ?? "#000000",
            line: variables["lineColor"] ?? "#AEAEB2",
            accent: accent
        )
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
        // Accent text, for the one small label that carries the accent off its node. The stroke hue
        // itself measures 2.86:1 on paper -- fine for a graphical object at 2px, under the app's own
        // 4.5:1 readable ratio for 12px words, and the label-contrast pass cannot rescue an edge
        // label (its mask rect is a sibling of the text, so `paperUnder` finds nothing behind it).
        // So the words get a darker mix of the same hue: 5.9:1 light, 5.2:1 dark.
        let accentText = dark ? accent : "#A33F13"
        // The second chromatic family, and the only one legible enough to carry meaning on its own:
        // 6.1:1 on light paper. Edges only -- the source never puts it on a node body.
        let link = dark ? "#6A95D8" : "#2E5AA8"
        // #6A95D8 is 4.24:1 on dark paper, under the readable ratio, so the words take a lighter mix
        // for the same reason the accent's do.
        let linkText = dark ? "#8FB3E8" : link

        // --- the ladder ------------------------------------------------------
        //
        // Five node surfaces, one hue, no legend. The fills are the source's `ink @ 0.0x`
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
        // every outline widens to 1.25px and the focal one to 2.4px. Five rungs either way, each one
        // further from its neighbours.
        let wash = increaseContrast ? 1.6 : 1.0
        let inkWash = { (alpha: Double) in Self.blend(ink, alpha * wash, over: paper) }
        // The one rung the source does not derive: white in light, paper-2 in dark, because white on
        // a dark page would be brighter than the ink it is outlined with.
        let backendFill = dark ? paper2 : "#FFFFFF"
        let storeFill = inkWash(0.10)
        let entryFill = Self.blend(muted, 0.16 * wash, over: paper)
        let terminalFill = inkWash(0.04)
        let optionalFill = inkWash(0.02)
        // 0.10 in both appearances. style-guide.md says 0.10 and the shipped dark assets use 0.08;
        // on a screen at preview size the difference is one RGB level, so one number is stated here
        // rather than two that have to be kept in step.
        let focalFill = Self.blend(accent, 0.10, over: paper)
        // The quiet end of the stroke ramp. Composited rather than left as rgba() so it can be
        // reasoned about: 3.2:1 light, 4.8:1 dark. The source's own 0.30 measures 1.78:1, which is
        // not a boundary on a screen -- it gets away with it because it always ships a legend.
        let quietStroke = Self.blend(ink, increaseContrast ? 0.68 : 0.55, over: paper)
        let strokeWidth = increaseContrast ? "1.25px" : "1px"
        // type-line.md: "focus is carried by stroke weight, not tone -- 2.4px focal against 1.2px".
        // Twice the ladder's weight, taken literally, because the hue cannot carry it alone.
        let focalWidth = increaseContrast ? "2.4px" : "2px"
        let accentEdgeWidth = increaseContrast ? "2.4px" : "2px"

        let ladder: [Rung] = [
            // The workhorse, and what a decision diamond gets too: the source's own legend draws
            // DECISION as a plain white diamond.
            Rung(token: "backend", fill: backendFill, stroke: ink, width: strokeWidth, dash: nil),
            // A cylinder [(…)] is the author declaring a datastore out loud -- the one place shape
            // decides a rung, and import-mermaid.md's own mapping.
            Rung(token: "store", fill: storeFill, stroke: muted, width: strokeWidth, dash: nil),
            // In-degree 0. import-mermaid.md gives exactly this to its two entry rects, which are
            // the same shape as the backend rect beside them: structure decides, not shape.
            Rung(token: "entry", fill: entryFill, stroke: soft, width: strokeWidth, dash: nil),
            // Out-degree 0. The quietest surface on the page -- measured, all three non-focal ovals
            // in the source's own flowchart take this, including the start oval.
            Rung(token: "terminal", fill: terminalFill, stroke: quietStroke, width: strokeWidth, dash: nil),
            // Reached only by `-.->`: the author saying "conditional". Same stroke as terminal, so
            // the dash is what tells them apart, and it survives greyscale.
            Rung(token: "optional", fill: optionalFill, stroke: quietStroke, width: strokeWidth, dash: "4,3"),
            // At most one per diagram, and usually none. Its label stays ink.
            Rung(token: "focal", fill: focalFill, stroke: accent, width: focalWidth, dash: nil),
        ]

        // Three families, because the source says the three-way contrast is load-bearing -- and its
        // own CSS already falls back to system-ui / serif / ui-monospace, so substituting the faces
        // is what it expects rather than something invented here. Extended with Apple SD Gothic Neo
        // per its instruction to widen the stack for Korean rather than swap the skin.
        let sans = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Apple SD Gothic Neo', sans-serif"
        let mono = "ui-monospace, 'SF Mono', Menlo, 'Apple SD Gothic Neo', monospace"

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
            // A zone is a hairline frame, never a filled band: the stylesheet takes its fill to
            // `none` so no rung can collide with the surface it sits on.
            "clusterBkg": paper,
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
            "compositeBackground": optionalFill,
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
            "sectionBkgColor": optionalFill,
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
        // tokens (`fp-backend` … `fp-focal`, `fp-accent`, `fp-cross`) are written by
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
        .cluster rect { fill: none; stroke: \(rule); stroke-width: 0.8px; rx: 8px; ry: 8px; }
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
        .edgeLabel, .edgeLabel .label text, .edgeLabel foreignObject div {
            font-family: \(mono);
            font-weight: 400;
            letter-spacing: 0.04em;
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

        /* The accent edge: its stroke, its own arrowhead -- cloned by the glue so every other arrow
           keeps the shared marker -- and its label, which is the part usually forgotten and the part
           that carries the accent off the node and along the flow. */
        .flowchart-link.fp-accent, .edgePath path.fp-accent { stroke: \(accent); stroke-width: \(accentEdgeWidth); }
        marker.fp-marker-accent path, marker.fp-marker-accent polygon { fill: \(accent); stroke: \(accent); }
        .edgeLabels g.label.fp-accent text, .edgeLabels g.label.fp-accent tspan { fill: \(accentText); }

        /* The second edge class, for a path that leaves one zone and enters another -- the source's
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
            monoFontFamily: mono,
            // Gaps from the source's own allowed ramp (20/24/32/40/48); 32 and 40 sit between its
            // 24 "standard" and 40 "presentation" figures, and a preview is closer to presentation.
            // `padding` is held here rather than handed to `look: "neo"`, which would replace it
            // with per-shape constants nobody can reach.
            arrangement: MermaidArrangement(
                nodeSpacing: 32,
                rankSpacing: 40,
                padding: 16,
                diagramPadding: 24,
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

    /// One rung of the node ladder: a fill, a stroke, and the two channels that are not colour.
    private struct Rung {
        let token: String
        let fill: String
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
        """
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
        accent: String
    ) {
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
