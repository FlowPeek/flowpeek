import Foundation

/// The handful of mermaid config values a theme is allowed to set.
///
/// A closed struct rather than a dictionary of loosely-typed values, for two reasons and the second
/// is the important one.
///
/// It has to be `Codable`. `MermaidRenderPayload` is `Codable` and is genuinely decoded in the
/// tests, so a member that could only encode would take `Decodable` synthesis down with it and stop
/// the whole payload compiling.
///
/// And it has to be closed. A theme is a set of values, not a way to reach mermaid's configuration:
/// with a free-form dictionary the only thing standing between a theme and `securityLevel` or
/// `htmlLabels` would be a key allowlist in JavaScript. Here a theme cannot express those keys at
/// all, because there is nowhere to put them.
///
/// Everything is optional and nil means "say nothing", so a theme that sets none of it emits no
/// config at all and the renderer behaves exactly as it did before this type existed.
public struct MermaidArrangement: Codable, Equatable, Sendable {
    /// Gap between nodes on the same rank, in points.
    public var nodeSpacing: Int?
    /// Gap between ranks.
    public var rankSpacing: Int?
    /// Space inside a node, around its label. What holds node height; this is the knob `look: "neo"`
    /// would take away, which is why the editorial theme sets a look of nothing and owns this.
    public var padding: Int?
    /// Space around the whole drawing.
    public var diagramPadding: Int?
    /// How edges are drawn between the points dagre routed them through: "basis" (mermaid's
    /// default), "linear", "step", "stepAfter", "stepBefore", "rounded".
    public var curve: String?
    /// The curve a true flowchart gets, where it should differ from `curve`.
    ///
    /// mermaid keeps one curve setting and more than one diagram family reads it: a state diagram
    /// renders through the same dagre code and takes whatever `flowchart.curve` says. So a theme
    /// that wants orthogonal routing in a flowchart cannot simply set `curve` -- measured, `step`
    /// there left every state transition's arrowhead detached from its box and pointing the wrong
    /// way. This is the value that reaches a flowchart only; `curve` keeps reaching everything, so
    /// the families that were never meant to change do not.
    public var flowchartCurve: String?
    /// Where a label longer than this wraps, in points.
    public var wrappingWidth: Int?

    public init(
        nodeSpacing: Int? = nil,
        rankSpacing: Int? = nil,
        padding: Int? = nil,
        diagramPadding: Int? = nil,
        curve: String? = nil,
        flowchartCurve: String? = nil,
        wrappingWidth: Int? = nil
    ) {
        self.nodeSpacing = nodeSpacing
        self.rankSpacing = rankSpacing
        self.padding = padding
        self.diagramPadding = diagramPadding
        self.curve = curve
        self.flowchartCurve = flowchartCurve
        self.wrappingWidth = wrappingWidth
    }

    /// Nothing to say. The default, and what every theme that predates this type uses.
    public static let unset = MermaidArrangement()

    public var isEmpty: Bool { self == .unset }
}
