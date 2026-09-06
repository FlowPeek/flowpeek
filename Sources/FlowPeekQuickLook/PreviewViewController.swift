import AppKit
import FlowPeekCore
import QuickLookUI
import WebKit

/// Space-bar in Finder, for a `.mmd` file.
///
/// The same engine the app draws with, in a bundle of its own: an extension gets its own copy of
/// mermaid and the glue because it is a separate process with a separate bundle, and
/// `Bundle.main` inside it is this extension rather than FlowPeek.
///
/// Deliberately one web view and one render. The app's pool exists because a preview has to open in
/// the time it takes to let go of a key; Quick Look already has a spinner, and a pool that
/// pre-warms would be warming a process macOS is about to kill.
final class PreviewViewController: NSViewController, QLPreviewingController {
    /// Bigger than this is not a diagram anybody is going to read at a glance, and reading it into
    /// a preview extension is reading it into a process with a watchdog on it.
    private static let maximumFileBytes = 2 * 1024 * 1024

    /// One preview per process in practice, but Quick Look reuses an extension for several files in
    /// a row when the user arrows through a folder, and two renders sharing an id share a
    /// stylesheet.
    private static var renderCounter: UInt64 = 0

    private static func nextRenderCounter() -> UInt64 {
        renderCounter += 1
        return renderCounter
    }

    private var webView: WKWebView?

    override func loadView() {
        view = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 520))
        view.wantsLayer = true
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = try Self.read(url)
        // Validated with the same rules the app uses, so a file Quick Look refuses is a file the
        // app would refuse too, with the same words.
        let source = try MermaidSource(rawValue: text)
        let theme = QuickLookTheme.current()
        // Both identifiers come from `MermaidRenderIdentifier` rather than being invented here.
        // mermaid scopes the stylesheet it generates as `#<renderID> .node rect { … }`, and a CSS
        // identifier may not begin with a digit -- a raw `UUID().uuidString` starts with one about
        // three times in five, and when it did the whole rule set silently failed to match: black
        // fills, no strokes, and a diagram that looked like a row of solid rectangles.
        let request = MermaidRenderRequest(
            source: source.text,
            theme: theme,
            seed: MermaidRenderIdentifier.seed(for: UUID()),
            renderID: MermaidRenderIdentifier.renderID(Self.nextRenderCounter())
        )
        let web = try Self.makeWebView(frame: view.bounds)
        webView = web
        // Constraints rather than a frame and an autoresizing mask: Quick Look sizes this view
        // after `loadView`, and a web view created against a bounds that was still zero stays zero.
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        try await QuickLookRenderer.draw(request, in: web)
    }

    private static func read(_ url: URL) throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maximumFileBytes else { throw MermaidRenderError.internalFailure("the file is too large to preview") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MermaidRenderError.internalFailure("the file is not UTF-8 text")
        }
        return text
    }

    /// The engine and the glue as user scripts in FlowPeek's own content world, and a page that can
    /// reach nothing: `default-src 'none'` is in the document itself.
    private static func makeWebView(frame: CGRect) throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let world = WKContentWorld.world(name: MermaidEnginePage.contentWorldName)
        for name in [
            (MermaidEnginePage.engineResourceName, MermaidEnginePage.engineResourceExtension),
            (MermaidEnginePage.glueResourceName, MermaidEnginePage.glueResourceExtension),
        ] {
            guard let url = Bundle.main.url(forResource: name.0, withExtension: name.1),
                  let script = try? String(contentsOf: url, encoding: .utf8) else {
                throw MermaidRenderError.engineMissing
            }
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
            )
        }
        let web = WKWebView(frame: frame, configuration: configuration)
        // Opaque, unlike the app's: Quick Look draws this on its own panel, and a transparent web
        // view there is a diagram floating on whatever the panel is made of.
        return web
    }
}
