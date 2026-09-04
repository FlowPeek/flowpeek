import FlowPeekCore
import WebKit

/// The render view is allowed exactly one navigation — the inline engine page — and nothing else:
/// no subframe, no scheme, no same-document jump, no response, no new window, no JS dialog.
/// Every failure is reported as a typed `MermaidRenderError` instead of being swallowed.
@MainActor
final class MermaidWebPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// `loadHTMLString(_:baseURL: nil)` navigates to `about:blank`; that is the only allowed URL.
    static let allowedURL = URL(string: "about:blank")!

    var onFinish: (() -> Void)?
    var onFatal: ((MermaidRenderError) -> Void)?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let allowed = navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.navigationType == .other
            && (url == nil || url == Self.allowedURL)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFatal?(.navigationFailed(String(describing: error)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFatal?(.navigationFailed(String(describing: error)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onFatal?(.webContentTerminated)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) { completionHandler() }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) { completionHandler(false) }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) { completionHandler(nil) }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) { completionHandler(nil) }
}
