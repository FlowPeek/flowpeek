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
    /// Every value below is that project's own, read from its style guide and its example markup:
    /// the paper/ink/muted/soft/rule palette, the 12px 600-weight node name, the 1.2 edge stroke,
    /// the rx=6 node box, the coral accent and the gaps from its allowed ramp. What that project
    /// has and mermaid does not -- per-node-type opacity ladders, orthogonal connector routing with
    /// quarter-arc elbows, index numerals, legend strips, dot paper -- is skipped rather than
    /// approximated, because a half-imitation of a device reads worse than its absence.
    ///
    /// Two deliberate departures, each with the source's own reasoning behind it:
    ///
    /// The accent is fixed rather than the reader's. It exists to mark the one or two things to
    /// look at first -- "coral is editorial, not a flag" -- and spending a reader's graphite or pink
    /// on that would put a sixth colour into a five-colour palette at the one place the palette is
    /// doing the most work.
    ///
    /// Arrow labels are 12px, not the 8px the source ships. Its own hard floor is "Hangul goes
    /// muddy below 12px; if a Korean name doesn't fit at 12px, cut the name, don't shrink the type",
    /// and Korean is a first-class language here, so the floor wins over the ratio. Hierarchy is
    /// carried by weight and colour instead, which is how the source separates a node name from its
    /// sublabel anyway.
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
        let rule = increaseContrast ? (dark ? "#BFC0C0" : "#4F5D75")
                                    : (dark ? "rgba(245,245,245,0.12)" : "rgba(45,49,66,0.12)")
        let accent = dark ? "#F08A59" : "#EB6C36"
        let accentTint = dark ? "rgba(240,138,89,0.10)" : "rgba(235,108,54,0.08)"

        // Three families, because the source says the three-way contrast is load-bearing -- and its
        // own CSS already falls back to system-ui / serif / ui-monospace, so substituting the faces
        // is what it expects rather than something invented here. Extended with Apple SD Gothic Neo
        // per its instruction to widen the stack for Korean rather than swap the skin.
        let sans = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Apple SD Gothic Neo', sans-serif"
        let mono = "ui-monospace, 'SF Mono', Menlo, 'Apple SD Gothic Neo', monospace"

        let variables: [String: String] = [
            "fontFamily": sans,
            // 12, from the allowed ramp of 8/12/16/20/24/28/32/40, and the Hangul floor.
            "fontSize": "12px",
            "background": paper,
            // Node fill is paper too: in this language a box is told apart from the page by its
            // hairline, not by a different fill. Subgraph containers take paper-2.
            "primaryColor": paper,
            "mainBkg": paper,
            "primaryTextColor": ink,
            "primaryBorderColor": rule,
            "secondaryColor": paper2,
            "secondaryTextColor": ink,
            "secondaryBorderColor": rule,
            "tertiaryColor": paper2,
            "tertiaryTextColor": ink,
            "tertiaryBorderColor": rule,
            "lineColor": muted,
            "textColor": ink,
            "titleColor": ink,
            "nodeBorder": rule,
            "nodeTextColor": ink,
            "clusterBkg": paper2,
            "clusterBorder": rule,
            "edgeLabelBackground": paper,
            "labelColor": ink,
            // Notes are the one place the accent tint earns its keep without being a flag.
            "noteBkgColor": accentTint,
            "noteTextColor": ink,
            "noteBorderColor": accent,
            // Sequence. Its type sizes are set in the stylesheet below rather than here: these
            // read as numbers in mermaid's own sequence config, and a "12px" string handed to them
            // as a theme variable is dropped without complaint -- measured, the messages stayed at
            // 16px while every node label was 12.
            "actorFontFamily": sans,
            "messageFontFamily": sans,
            "noteFontFamily": sans,
            "actorBkg": paper,
            "actorBorder": rule,
            "actorTextColor": ink,
            "actorLineColor": muted,
            "signalColor": muted,
            "signalTextColor": ink,
            "labelBoxBkgColor": paper2,
            "labelBoxBorderColor": rule,
            "labelTextColor": ink,
            "loopTextColor": soft,
            "activationBkgColor": accentTint,
            "activationBorderColor": accent,
            "sequenceNumberColor": paper,
            // State and class.
            "altBackground": paper2,
            "classText": ink,
            // Relationship and error ink, so a link reads as a link rather than as the body colour.
            "relationColor": muted,
            "relationLabelColor": soft,
            "errorBkgColor": accentTint,
            "errorTextColor": ink,
        ]

        // What the variables cannot say. Kept to geometry, weight and the two type roles: every
        // colour above is a token, and nothing here introduces one.
        let css = """
        .node rect, .node polygon, .node path { stroke-width: 1px; rx: 6px; ry: 6px; }
        .node circle, .node ellipse { stroke-width: 1px; }
        .cluster rect { stroke-width: 1px; rx: 8px; ry: 8px; }
        /* 600 on the name, 400 everywhere else: the source carries hierarchy in weight and colour
           rather than in size, which is what lets every label sit on the 12px Hangul floor. */
        .node .label text, .node .nodeLabel, .nodeLabel { font-weight: 600; }
        .edgePath path, .flowchart-link, .relation { stroke-width: 1.2px; }
        .edgeLabel, .edgeLabel .label text, .edgeLabel foreignObject div {
            font-family: \(mono);
            font-weight: 400;
            letter-spacing: 0.04em;
            color: \(muted);
            fill: \(muted);
        }
        .edgeLabel rect, .edgeLabel .background, rect.background { fill: \(paper); }
        .cluster .cluster-label text, .cluster text { fill: \(soft); font-weight: 600; letter-spacing: 0.06em; }
        marker path, marker polygon, .marker { fill: \(muted); stroke: \(muted); }
        /* Sequence draws its own lines outside the edge classes above, and its dashed reply arrow
           kept mermaid's stock violet: measured, the variables alone do not reach it. */
        .messageLine0, .messageLine1, line.loopLine, .actor-line {
            stroke: \(muted);
            stroke-width: 1.2px;
        }
        /* Sequence writes `font-size: 16px` inline onto every <text> it draws, from its own
           config, and measured: setting actorFontSize and messageFontSize there does not change it.
           An inline style beats a stylesheet, so this is one of the two places in this theme that
           has to insist -- the alternative is the one diagram type that is mostly words sitting four
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
            // Gaps from the source's own allowed ramp (20/24/32/40/48); 32 and 40 sit between its
            // 24 "standard" and 40 "presentation" figures, and a preview is closer to presentation.
            // `padding` is held here rather than handed to `look: "neo"`, which would replace it
            // with per-shape constants nobody can reach.
            arrangement: MermaidArrangement(
                nodeSpacing: 32,
                rankSpacing: 40,
                padding: 16,
                diagramPadding: 24,
                curve: "rounded",
                wrappingWidth: 160
            ),
            // A repainted label lands on the theme's own two ends.
            darkInk: ink,
            lightInk: paper,
            accent: accent
        )
    }

    /// For a theme that supplies its own values outright rather than deriving them from the
    /// system's. Not public: a theme belongs in the catalogue beside the others, not at a call site.
    init(
        appearance: Appearance,
        variables: [String: String],
        css: String,
        fontFamily: String,
        arrangement: MermaidArrangement,
        darkInk: String,
        lightInk: String,
        accent: String
    ) {
        self.appearance = appearance
        self.variables = variables
        self.css = css
        self.fontFamily = fontFamily
        self.arrangement = arrangement
        self.darkInk = darkInk
        self.lightInk = lightInk
        self.accent = accent
    }

    public init(appearance: Appearance, accentHex: String, increaseContrast: Bool) {
        self.appearance = appearance
        let dark = appearance == .dark
        fontFamily = Self.systemFontStack
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
