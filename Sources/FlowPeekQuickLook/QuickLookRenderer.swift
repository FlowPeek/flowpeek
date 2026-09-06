import FlowPeekCore
import WebKit

/// One load, one render, one answer.
@MainActor
enum QuickLookRenderer {
    /// Long enough for a large diagram on a cold process, short enough that Quick Look's own
    /// patience is not what the user runs out of.
    private static let timeout: Duration = .seconds(8)

    static func draw(_ request: MermaidRenderRequest, in web: WKWebView) async throws {
        let payload = try request.payloadJSON()
        try await load(web)
        let raw = try await web.callAsyncJavaScript(
            MermaidEnginePage.renderInvocation,
            arguments: ["payload": payload],
            in: nil,
            contentWorld: WKContentWorld.world(name: MermaidEnginePage.contentWorldName)
        )
        guard let json = raw as? String else {
            throw MermaidRenderError.internalFailure("the render glue returned \(type(of: raw))")
        }
        // Decoded rather than trusted: a failure carries the line the user has to look at, and
        // throwing it here is what makes Quick Look say so instead of showing an empty page.
        _ = try MermaidGlueDecoder.result(from: json, sourceUTF16Count: request.source.utf16.count)
    }

    private static func load(_ web: WKWebView) async throws {
        let watcher = LoadWatcher()
        web.navigationDelegate = watcher
        web.loadHTMLString(MermaidEnginePage.html, baseURL: nil)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await watcher.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MermaidRenderError.internalFailure("the preview page did not load in time")
            }
            try await group.next()
            group.cancelAll()
        }
        web.navigationDelegate = nil
    }
}

/// Turns the delegate callback into something awaitable, and fails rather than hanging when the
/// page cannot load at all.
///
/// The answer is remembered rather than only forwarded. A page built from a string can finish
/// loading before the task that awaits it has even started, and an earlier version resumed nothing
/// in that case and then suspended forever -- which Quick Look showed as a spinner that never
/// stopped.
@MainActor
private final class LoadWatcher: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var outcome: Result<Void, any Error>?

    func wait() async throws {
        if let outcome { return try outcome.get() }
        try await withCheckedThrowingContinuation { continuation in
            if let outcome {
                continuation.resume(with: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }

    private func settle(_ result: Result<Void, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settle(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        settle(.failure(error))
    }
}
