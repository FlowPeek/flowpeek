import AppKit
import SwiftUI
import WebKit

/// A thin host for a pooled engine view. It owns no page, no script, no render state and no dedupe:
/// the whole pipeline lives in `DiagramViewModel`, which awaits the render before fitting.
struct MermaidWebView: NSViewRepresentable {
    let engine: MermaidEngineView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        guard let webView = engine?.webView else { return }
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
