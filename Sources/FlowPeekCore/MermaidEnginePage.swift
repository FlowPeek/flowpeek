import Foundation

/// The whole document the render web view ever loads: an inline page with no subresource of any
/// kind. mermaid and `flowpeek-glue.js` arrive as `WKUserScript`s in a named content world, which
/// WebKit exempts from the page CSP — so `script-src` is deliberately absent and an injected
/// `<script>` inside an SVG label can never execute.
public enum MermaidEnginePage {
    /// `base-uri`, `form-action` and `frame-ancestors` do not fall back to `default-src`, so each
    /// must be stated. `style-src 'unsafe-inline'` is load-bearing: mermaid emits its entire theme
    /// as a `<style>` element inside the SVG plus inline style attributes.
    public static let contentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    public static let stageElementID = "stage"
    public static let diagramElementID = "diagram"
    public static let errorElementID = "error"
    /// Where mermaid is told to render. See `measure` in the CSS below.
    public static let measureElementID = "measure"

    /// A scrolling stage that centres a canvas whose *layout* size tracks the zoom, so panning is
    /// native scrolling and zooming is a cheap GPU transform on the wrapper. The `<svg>` is pinned to
    /// its natural pixel size by the glue, never left at mermaid's `width="100%"`.
    ///
    /// `#measure` is where mermaid is told to render. It is off-screen but deliberately *in the
    /// render tree*: renderers that lay out with `getBBox()` -- eventmodeling's data blocks among
    /// them -- throw "svg element not in render tree" in mermaid's own default container, and
    /// `display:none` here would reintroduce exactly that. It is given room to lay out at natural
    /// size and emptied again after every render.
    public static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
    <style>
    html,body{margin:0;height:100%;background:transparent;color-scheme:light dark}
    #stage{position:absolute;inset:0;overflow:auto;display:flex;cursor:grab}
    #stage.grabbing{cursor:grabbing}
    #stage::-webkit-scrollbar{width:0;height:0}
    #canvas{margin:auto;position:relative;flex:none}
    #diagram{position:absolute;top:0;left:0;transform-origin:0 0}
    #diagram svg{display:block;max-width:none;background:transparent}
    #error{display:none}
    #measure{position:absolute;left:-99999px;top:0;width:4000px;height:4000px;overflow:hidden}
    </style></head><body><div id="stage"><div id="canvas"><div id="diagram"></div></div></div><div id="error"></div><div id="measure"></div></body></html>
    """

    /// Name of the `WKContentWorld` the engine, the glue and every `callAsyncJavaScript` share.
    public static let contentWorldName = "flowpeek"

    public static let engineResourceName = "mermaid"
    public static let engineResourceExtension = "min.js"
    public static let glueResourceName = "flowpeek-glue"
    public static let glueResourceExtension = "js"

    /// The one call the integrator makes per render; `payload` is `MermaidRenderRequest.payloadJSON()`.
    public static let renderInvocation = "return await window.__flowpeek.render(payload);"
    public static let selfTestInvocation = "return await window.__flowpeek.selfTest(payload);"
    public static let setScaleInvocation = "return window.__flowpeek.setScale(scale);"
    public static let zoomInvocation = "return window.__flowpeek.zoomBy(factor);"
    public static let fitInvocation = "return window.__flowpeek.fit();"

    /// The `WKScriptMessageHandler` name the glue posts viewport changes to, so a pinch or a
    /// scroll-wheel zoom inside the page keeps the Swift-side zoom readout honest.
    public static let viewportMessageName = "flowpeekViewport"
}
