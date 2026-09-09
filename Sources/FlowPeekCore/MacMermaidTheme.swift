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

    public init(appearance: Appearance, accentHex: String, increaseContrast: Bool) {
        self.appearance = appearance
        let dark = appearance == .dark
        fontFamily = Self.systemFontStack
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
