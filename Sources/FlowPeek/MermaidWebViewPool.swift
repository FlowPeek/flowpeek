import AppKit
import FlowPeekCore
import OSLog
import WebKit

/// Receives `{scale}` from the page whenever the viewport changes — a pinch, a wheel zoom, a
/// double-click, or a fit after a render. WebKit delivers on the main thread.
private final class MermaidViewportBridge: NSObject, WKScriptMessageHandler {
    @MainActor var onScale: ((Double) -> Void)?

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        guard let scale = body["scale"] as? Double, scale.isFinite, scale > 0 else { return }
        MainActor.assumeIsolated { self.onScale?(scale) }
    }
}

/// One pre-warmed web view that already carries the 3.5 MB engine. Warm-up costs 159-750 ms and a
/// render 5-11 ms, so a cold view is the difference between an instant preview and a visible stall.
@MainActor
final class MermaidEngineView: NSObject, MermaidRendering {
    let webView: WKWebView

    /// The page owns the zoom; Swift only requests changes and listens for the resulting scale, so a
    /// pinch inside the diagram and a click on the zoom button converge on the same number.
    var onViewportChange: ((Double) -> Void)?

    /// Raised when this view can never render again -- a dead WebContent process, a failed
    /// navigation. Whoever is showing the view has to hear about it even when no render is in
    /// flight, or an open preview keeps a rendered status over a page that no longer exists.
    var onFatal: ((MermaidRenderError) -> Void)?

    private let viewport: MermaidViewportBridge

    private let policy = MermaidWebPolicy()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Renderer")
    private let createdAt = Date()
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var state: State = .loading
    private var theme: MacMermaidTheme = MermaidThemeFactory.current(.light)
    private(set) var warmupMS = 0
    private(set) var isPoisoned = false

    private enum State {
        case loading
        case ready
        case failed(MermaidRenderError)
    }

    init(configuration: WKWebViewConfiguration) {
        let bridge = MermaidViewportBridge()
        configuration.userContentController.add(
            bridge,
            contentWorld: MermaidEngineAssets.world,
            name: MermaidEnginePage.viewportMessageName
        )
        viewport = bridge
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        bridge.onScale = { [weak self] scale in self?.onViewportChange?(scale) }
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.navigationDelegate = policy
        webView.uiDelegate = policy
        policy.onFinish = { [weak self] in self?.markReady() }
        policy.onFatal = { [weak self] in self?.markFailed($0) }
        webView.loadHTMLString(MermaidEnginePage.html, baseURL: nil)
    }

    /// Whether the diagram sits straight on the glass or on a solid canvas of its own.
    ///
    /// The page, the SVG and the space under the page are all transparent already, so the only
    /// thing between a diagram and the glass is the view's own backdrop. `underPageBackgroundColor`
    /// does not switch that off on macOS -- measured as a fully opaque panel interior -- and
    /// `isOpaque` is get-only on an `NSView`, so it goes through the one key WebKit exposes.
    /// Guarded and probed under the name KVC actually resolves (`_setDrawsBackground:`): the
    /// un-prefixed spelling reports false and the call would be skipped in silence.
    /// Returns whether the canvas is now what was asked for, and the answer cannot be dropped: a
    /// silent no-op here is a switch that lies about the drawing.
    func setBackgroundTransparent(_ transparent: Bool) -> Bool {
        guard webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) else { return false }
        webView.setValue(!transparent, forKey: "drawsBackground")
        // Without this the previous backdrop stays on screen until something else invalidates.
        webView.setNeedsDisplay(webView.bounds)
        return true
    }

    // MARK: - Rendering

    func render(_ request: MermaidRenderRequest) async throws(MermaidRenderError) -> MermaidRenderResult {
        let payload = try request.payloadJSON()
        let utf16 = request.source.utf16.count
        theme = request.theme
        let outcome = await watchdog { await self.renderOutcome(payload, sourceUTF16Count: utf16) }
        switch outcome {
        case .success(let result):
            return result
        case .failure(let error):
            if case .timedOut = error { poison(error) }
            throw error
        }
    }

    func selfTest() async -> MermaidEngineHealth {
        let payload = MermaidThemeFactory.selfTestPayloadJSON(theme)
        let outcome = await watchdog { await self.selfTestOutcome(payload) }
        switch outcome {
        case .success(let json):
            return MermaidGlueDecoder.health(from: json, warmupMS: warmupMS)
        case .failure(let error):
            return MermaidEngineHealth(status: .broken(error), engineVersion: nil, warmupMS: warmupMS, canaryMS: 0)
        }
    }

    private func selfTestOutcome(_ payload: String) async -> Result<String, MermaidRenderError> {
        do {
            try await waitUntilReady()
        } catch {
            return .failure(error)
        }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                MermaidEnginePage.selfTestInvocation,
                arguments: ["payload": payload],
                in: nil,
                contentWorld: MermaidEngineAssets.world
            )
        } catch {
            return .failure(MermaidRenderError.javaScriptException(error))
        }
        guard let json = raw as? String else {
            return .failure(.internalFailure("the self-test glue returned \(type(of: raw))"))
        }
        return .success(json)
    }

    func selfTest(theme: MacMermaidTheme) async -> MermaidEngineHealth {
        self.theme = theme
        return await selfTest()
    }

    /// Fit and zoom are applied to the wrapper, never to the `<svg>`, so text stays vector-crisp.
    func setScale(_ value: Double) { command(MermaidEnginePage.setScaleInvocation, ["scale": value]) }

    func zoom(by factor: Double) { command(MermaidEnginePage.zoomInvocation, ["factor": factor]) }

    /// Scales the diagram to fill the current stage, growing small diagrams rather than stranding
    /// them at their natural size.
    func fitToStage() { command(MermaidEnginePage.fitInvocation, [:]) }

    /// Scrolls the stage by a pixel delta, for the arrow keys: the page has no focusable element,
    /// so it can never receive a key event of its own.
    func pan(dx: Double, dy: Double) {
        command(MermaidEnginePage.panInvocation, ["dx": dx, "dy": dy])
    }

    private func command(_ body: String, _ arguments: [String: Any]) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await webView.callAsyncJavaScript(
                body,
                arguments: arguments,
                in: nil,
                contentWorld: MermaidEngineAssets.world
            )
        }
    }

    /// Returned to the pool: detached from whatever window held it and emptied.
    func clear() {
        webView.removeFromSuperview()
        Task { [weak self] in
            guard let self else { return }
            _ = try? await webView.callAsyncJavaScript(
                "document.getElementById('\(MermaidEnginePage.diagramElementID)').replaceChildren(); return true;",
                in: nil,
                contentWorld: MermaidEngineAssets.world
            )
        }
    }

    /// Escape hatch for the headless engine tests; nothing in the app calls it.
    @discardableResult
    func evaluate(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await waitUntilReady()
        return try await webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            contentWorld: MermaidEngineAssets.world
        )
    }

    func dispose() {
        onViewportChange = nil
        // Before the `markFailed` at the end of this method: disposal is itself a fatal transition,
        // and reporting it would call back into an owner that is deliberately throwing this view
        // away -- which is how a replacement turns into a loop.
        onFatal = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: MermaidEnginePage.viewportMessageName,
            contentWorld: MermaidEngineAssets.world
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        markFailed(.engineNotReady)
    }

    // MARK: - Internals

    private func renderOutcome(
        _ payload: String,
        sourceUTF16Count: Int
    ) async -> Result<MermaidRenderResult, MermaidRenderError> {
        do {
            try await waitUntilReady()
        } catch {
            return .failure(error)
        }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                MermaidEnginePage.renderInvocation,
                arguments: ["payload": payload],
                in: nil,
                contentWorld: MermaidEngineAssets.world
            )
        } catch {
            // Never `error.localizedDescription`: that is always "A JavaScript exception occurred".
            return .failure(MermaidRenderError.javaScriptException(error))
        }
        guard let json = raw as? String else {
            return .failure(.internalFailure("the render glue returned \(type(of: raw))"))
        }
        do {
            return .success(try MermaidGlueDecoder.result(from: json, sourceUTF16Count: sourceUTF16Count))
        } catch {
            return .failure(error)
        }
    }

    /// `callAsyncJavaScript` has no timeout of its own: a runaway render pins the WebContent
    /// process and the continuation never resumes. A task group cannot express this — it awaits
    /// every child, so the stuck one would hold the group open forever. The loser is abandoned.
    private func watchdog<T: Sendable>(
        _ work: @escaping @Sendable () async -> Result<T, MermaidRenderError>
    ) async -> Result<T, MermaidRenderError> {
        let race = WatchdogRace<T>()
        return await withCheckedContinuation { continuation in
            race.arm(continuation)
            Task { race.finish(await work()) }
            Task {
                try? await Task.sleep(for: .seconds(MermaidRenderLimits.timeoutSeconds))
                race.finish(.failure(.timedOut(seconds: MermaidRenderLimits.timeoutSeconds)))
            }
        }
    }

    private func waitUntilReady() async throws(MermaidRenderError) {
        switch state {
        case .ready: return
        case .failed(let error): throw error
        case .loading: break
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(continuation)
            }
        } catch let error as MermaidRenderError {
            throw error
        } catch {
            throw .engineNotReady
        }
    }

    private func markReady() {
        guard case .loading = state else { return }
        warmupMS = Int(Date().timeIntervalSince(createdAt) * 1000)
        state = .ready
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        logger.debug("engine page ready in \(self.warmupMS, privacy: .public) ms")
    }

    private func markFailed(_ error: MermaidRenderError) {
        if case .failed = state { return }
        state = .failed(error)
        isPoisoned = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: error) }
        logger.error("engine view failed: \(error.localizedDescription, privacy: .public)")
        // After the waiters: a render already in flight wins through its own failure path, which
        // knows the source and can quote it, and the owner then sees a `.rendering` status and
        // leaves this one alone.
        onFatal?(error)
    }

    private func poison(_ error: MermaidRenderError) {
        isPoisoned = true
        webView.stopLoading()
        logger.error("engine view poisoned: \(error.localizedDescription, privacy: .public)")
    }
}

/// Resumes exactly once, for whichever of the render and the timeout finishes first. The other
/// task is simply never awaited again.
private final class WatchdogRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, MermaidRenderError>, Never>?

    func arm(_ value: CheckedContinuation<Result<T, MermaidRenderError>, Never>) {
        lock.lock()
        continuation = value
        lock.unlock()
    }

    func finish(_ outcome: Result<T, MermaidRenderError>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}

/// Holds the pre-warmed views and the process-wide engine sources. A view that timed out,
/// terminated or failed navigation is destroyed and replaced, never reused.
@MainActor
final class MermaidWebViewPool {
    static let shared = MermaidWebViewPool()
    static let warmCount = 1
    static let capacity = 2

    private var idle: [MermaidEngineView] = []
    /// How many warm views the pool still holds. The lifecycle tests assert against it: a preview
    /// that was closed has to have handed its engine back, or the next one starts cold.
    var idleCount: Int { idle.count }
    private var cachedScripts: [WKUserScript]?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Renderer")
    private(set) var health: MermaidEngineHealth?

    func warmUp() {
        do {
            try fill()
        } catch {
            record(.broken(error))
        }
    }

    func checkOut() throws(MermaidRenderError) -> MermaidEngineView {
        try fill()
        if let index = idle.firstIndex(where: { !$0.isPoisoned }) {
            return idle.remove(at: index)
        }
        return try makeView()
    }

    func checkIn(_ view: MermaidEngineView) {
        guard !view.isPoisoned, idle.count < Self.capacity else {
            evict(view)
            return
        }
        view.clear()
        view.onViewportChange = nil
        // A pooled view must carry nothing of its last owner: a stale callback here would report a
        // later death to a view model whose surface has been closed for minutes.
        view.onFatal = nil
        view.setScale(1)
        idle.append(view)
    }

    func evict(_ view: MermaidEngineView) {
        idle.removeAll { $0 === view }
        view.dispose()
        try? fill()
    }

    /// engine_spec §7's anti-regression device: a canary render whose failure is reported by name.
    func runSelfTest(theme: MacMermaidTheme) async -> MermaidEngineHealth {
        do {
            let view = try checkOut()
            let result = await view.selfTest(theme: theme)
            checkIn(view)
            record(result.status, engineVersion: result.engineVersion, warmupMS: result.warmupMS, canaryMS: result.canaryMS)
            return result
        } catch {
            let failure = MermaidEngineHealth(status: .broken(error), engineVersion: nil, warmupMS: 0, canaryMS: 0)
            health = failure
            logger.error("engine self-test could not start: \(error.localizedDescription, privacy: .public)")
            return failure
        }
    }

    private func fill() throws(MermaidRenderError) {
        idle.removeAll { $0.isPoisoned }
        while idle.count < Self.warmCount {
            idle.append(try makeView())
        }
    }

    private func makeView() throws(MermaidRenderError) -> MermaidEngineView {
        let controller = WKUserContentController()
        for script in try userScripts() { controller.addUserScript(script) }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.suppressesIncrementalRendering = false
        return MermaidEngineView(configuration: configuration)
    }

    /// Parsing 3.5 MB is the expensive part, so the sources — and the `WKUserScript`s built from
    /// them — are read once per process and shared by every view.
    private func userScripts() throws(MermaidRenderError) -> [WKUserScript] {
        if let cachedScripts { return cachedScripts }
        let sources = [
            try MermaidEngineAssets.engineSource(),
            try MermaidEngineAssets.glueSource(),
        ]
        let scripts = sources.map {
            WKUserScript(
                source: $0,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: MermaidEngineAssets.world
            )
        }
        cachedScripts = scripts
        return scripts
    }

    private func record(
        _ status: MermaidEngineHealth.Status,
        engineVersion: String? = nil,
        warmupMS: Int = 0,
        canaryMS: Int = 0
    ) {
        let value = MermaidEngineHealth(status: status, engineVersion: engineVersion, warmupMS: warmupMS, canaryMS: canaryMS)
        health = value
        switch status {
        case .healthy:
            logger.log("engine healthy — warm-up \(warmupMS, privacy: .public) ms, canary \(canaryMS, privacy: .public) ms")
        case .degraded(let detail):
            logger.error("engine degraded — \(detail, privacy: .public)")
        case .broken(let error):
            logger.error("engine broken — \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Where the engine and the glue come from, and the content world all three share.
@MainActor
enum MermaidEngineAssets {
    static let world = WKContentWorld.world(name: MermaidEnginePage.contentWorldName)

    static func engineSource() throws(MermaidRenderError) -> String {
        try source(MermaidEnginePage.engineResourceName, MermaidEnginePage.engineResourceExtension)
    }

    static func glueSource() throws(MermaidRenderError) -> String {
        try source(MermaidEnginePage.glueResourceName, MermaidEnginePage.glueResourceExtension)
    }

    private static func source(_ name: String, _ extension: String) throws(MermaidRenderError) -> String {
        guard let url = Bundle.flowPeekResources.url(forResource: name, withExtension: `extension`),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw .engineMissing
        }
        return text
    }
}

/// Builds the theme handed to mermaid on every render, from the current appearance, accent colour
/// and the increase-contrast accessibility setting.
@MainActor
enum MermaidThemeFactory {
    static func current(_ appearance: MacMermaidTheme.Appearance) -> MacMermaidTheme {
        MacMermaidTheme(
            appearance: appearance,
            accentHex: NSColor.controlAccentColor.hexRGB,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    static func current() -> MacMermaidTheme { current(currentAppearance()) }

    static func currentAppearance() -> MacMermaidTheme.Appearance {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    static func selfTestPayloadJSON(_ theme: MacMermaidTheme) -> String {
        let object: [String: Any] = [
            "renderID": "fp-selftest",
            "seed": "flowpeek-selftest",
            "fontFamily": theme.fontFamily,
            "themeVariables": theme.variables,
            "themeCSS": theme.css,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

extension Bundle {
    static var flowPeekResources: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}

extension NSColor {
    var hexRGB: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#007AFF" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
