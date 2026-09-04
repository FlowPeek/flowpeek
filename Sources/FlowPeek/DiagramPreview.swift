import AppKit
import FlowPeekCore
import OSLog
import SwiftUI

/// Owns one checked-out engine view and the whole render pipeline. Fit is computed from the
/// `viewBox` the render *returns*, so it can no longer run against an empty stage.
@MainActor
final class DiagramViewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case rendering
        case rendered(MermaidRenderResult)
        case failed(String)
    }

    @Published var title: String
    @Published private(set) var status: Status = .idle
    @Published private(set) var scale: Double = 1
    @Published private(set) var engine: MermaidEngineView?

    let seed: String
    private(set) var source: String
    private let pool: MermaidWebViewPool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Renderer")
    private var appearance = MermaidThemeFactory.currentAppearance()
    private var stageSize: CGSize = .zero
    private var needsFit = true
    private var renderTask: Task<Void, Never>?
    private var contrastObserver: (any NSObjectProtocol)?
    /// One silent retry per source, so a dead WebContent process cannot put the panel into a loop.
    private var didRetryAfterCrash = false
    private static var renderCounter: UInt64 = 0

    init(document: DiagramDocument, pool: MermaidWebViewPool = .shared) {
        title = document.title
        source = document.source.text
        seed = MermaidRenderIdentifier.seed(for: document.id)
        self.pool = pool
    }

    init(title: String, source: String = "", pool: MermaidWebViewPool = .shared) {
        self.title = title
        self.source = source
        seed = MermaidRenderIdentifier.seed(for: UUID())
        self.pool = pool
    }

    // MARK: - Lifecycle

    func attach() {
        guard engine == nil else { return }
        do {
            adopt(try pool.checkOut())
        } catch {
            status = .failed(error.localizedDescription)
            logger.error("no engine view available: \(error.localizedDescription, privacy: .public)")
            return
        }
        observeContrastChanges()
        render()
    }

    /// Everything a checked-out view needs before it can be rendered into. `checkIn` drops the
    /// viewport callback and resets the page's scale, so a view arriving from the pool — the first
    /// one or a replacement — carries neither: without this the readout keeps reporting the zoom of
    /// whichever view was here before, and a pinch moves nothing.
    private func adopt(_ view: MermaidEngineView) {
        view.onViewportChange = { [weak self] scale in self?.scale = scale }
        scale = 1
        engine = view
    }

    /// The net under every surface: whoever owned the model is supposed to call `release()`, and a
    /// model that is simply dropped instead still gives its engine back rather than stranding a
    /// WebContent process for the life of the process.
    isolated deinit {
        release()
    }

    func release() {
        renderTask?.cancel()
        renderTask = nil
        if let observer = contrastObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            contrastObserver = nil
        }
        if let engine {
            engine.onViewportChange = nil
            self.engine = nil
            pool.checkIn(engine)
        }
    }

    // MARK: - Inputs

    func update(source newValue: String) {
        guard newValue != source else { return }
        source = newValue
        didRetryAfterCrash = false
        render()
    }

    func update(appearance newValue: MacMermaidTheme.Appearance) {
        guard newValue != appearance else { return }
        appearance = newValue
        render()
    }

    /// The page fits itself once per render, but that first fit runs against the pooled view's own
    /// frame — the real stage size only arrives once SwiftUI has laid the panel out.
    func update(stageSize newValue: CGSize) {
        guard newValue != stageSize else { return }
        stageSize = newValue
        if needsFit { engine?.fitToStage() }
    }

    // MARK: - Viewport

    func zoom(by factor: Double) {
        needsFit = false
        engine?.zoom(by: factor)
    }

    func actualSize() {
        needsFit = false
        engine?.setScale(1)
    }

    func fit() {
        needsFit = true
        engine?.fitToStage()
    }

    // MARK: - Rendering

    private func render() {
        renderTask?.cancel()
        guard let engine else { return }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .idle
            return
        }
        Self.renderCounter += 1
        let request = MermaidRenderRequest(
            source: source,
            theme: MermaidThemeFactory.current(appearance),
            seed: seed,
            renderID: MermaidRenderIdentifier.renderID(Self.renderCounter)
        )
        status = .rendering
        renderTask = Task { [weak self] in
            let outcome: Result<MermaidRenderResult, MermaidRenderError>
            do {
                outcome = .success(try await engine.render(request))
            } catch let error as MermaidRenderError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.internalFailure(String(describing: error)))
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let result):
                if !result.scrubbed.isEmpty {
                    self.logger.error("scrubbed \(result.scrubbed.joined(separator: ","), privacy: .public) from a rendered diagram")
                }
                self.didRetryAfterCrash = false
                self.status = .rendered(result)
                self.needsFit = true
                self.engine?.fitToStage()
            case .failure(let error):
                // The key names the failure for triage; the formatted message can quote the user's
                // own selection (`.unknownDiagramType` carries all of it, `.parseFailure` an excerpt),
                // so it stays redacted unless private-data logging is enabled.
                self.logger.error(
                    "render failed: \(error.localizationKey, privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
                switch error {
                case .webContentTerminated, .navigationFailed:
                    self.recover(from: error, retrying: true)
                case .timedOut:
                    self.recover(from: error, retrying: false)
                default:
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// The engine is gone either way, so the panel always gets a live replacement — otherwise the
    /// zoom buttons, a theme switch and the next `update(source:)` all land on nothing.
    ///
    /// A dead WebContent process is worth one silent retry: the replacement renders in 5-11 ms and
    /// the user never learns the first one died. A timeout is not — re-running the same source buys
    /// another 8 s of spinner to arrive at the same sentence.
    private func recover(from failure: MermaidRenderError, retrying: Bool) {
        do {
            try replaceEngine()
        } catch {
            // The render error describes a process that no longer exists; what the user needs to
            // know now is that the engine could not be restarted.
            status = .failed(error.localizedDescription)
            logger.error("no replacement engine available: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard retrying, !didRetryAfterCrash else {
            status = .failed(failure.localizedDescription)
            return
        }
        didRetryAfterCrash = true
        render()
    }

    /// A view that timed out or terminated is never reused.
    private func replaceEngine() throws(MermaidRenderError) {
        if let engine {
            self.engine = nil
            pool.evict(engine)
        }
        adopt(try pool.checkOut())
        needsFit = true
    }

    private func observeContrastChanges() {
        guard contrastObserver == nil else { return }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }
}

/// The stage: the pooled web view on bare glass, plus the one thing that can appear instead of a
/// diagram — a specific, typed error. A blank stage is structurally unreachable.
struct DiagramStage: View {
    @ObservedObject var model: DiagramViewModel
    @Environment(\.colorScheme) private var colorScheme
    var inset: CGFloat = 0

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                MermaidWebView(engine: model.engine)
                    .onChange(of: proxy.size, initial: true) { _, size in model.update(stageSize: size) }
            }
            .padding(inset)
            if case .rendering = model.status {
                ProgressView().controlSize(.small)
            }
            if case .failed(let message) = model.status {
                ScrollView {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.red.opacity(0.32)))
                .padding(24)
            }
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            model.update(appearance: scheme == .dark ? .dark : .light)
        }
    }
}

/// The preview embedded in the AI window: owns its own pooled view for the lifetime of the surface.
struct MermaidPreviewSurface: View {
    let source: String
    var onFailure: ((String?) -> Void)?

    @StateObject private var model = DiagramViewModel(title: "")

    var body: some View {
        DiagramStage(model: model)
            .onAppear {
                model.update(source: source)
                model.attach()
            }
            .onDisappear { model.release() }
            .onChange(of: source) { _, value in model.update(source: value) }
            .onChange(of: model.status) { _, status in
                if case .failed(let message) = status { onFailure?(message) } else { onFailure?(nil) }
            }
    }
}

@MainActor
final class PreviewCoordinator: NSObject, NSWindowDelegate {
    /// A promoted preview and the model whose engine it is showing. Every window carries its own
    /// pair: one shared slot made the second "Open in Window" close the first window's twin and
    /// leak the first window's engine.
    private struct Promoted {
        let window: NSWindow
        let model: DiagramViewModel
    }

    private var quickPanel: NSPanel?
    private var quickModel: DiagramViewModel?
    private var promoted: [Promoted] = []
    private var dismissMonitors: [Any] = []
    private let pool: MermaidWebViewPool

    private static let quickSize = CGSize(width: 720, height: 520)
    private static let quickMinSize = CGSize(width: 360, height: 260)
    private static let windowSize = CGSize(width: 1000, height: 720)
    private static let windowMinSize = CGSize(width: 480, height: 340)
    private static let messageSize = CGSize(width: 460, height: 240)

    init(pool: MermaidWebViewPool = .shared) {
        self.pool = pool
        super.init()
    }

    func showQuick(document: DiagramDocument) {
        closeQuick()
        let model = DiagramViewModel(document: document, pool: pool)
        quickModel = model
        model.attach()
        let panel = makePanel(
            size: Self.quickSize,
            minSize: Self.quickMinSize,
            title: document.title,
            content: DiagramPreviewView(
                model: model,
                compact: true,
                onPromote: { [weak self] in self?.promote() },
                onClose: { [weak self] in self?.closeQuick() }
            )
        )
        quickPanel = panel
        installDismissMonitors()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The engine could not run, or the selection failed validation: say why, in a panel. This is
    /// the branch that used to be `NSSound.beep()`.
    func showMessage(title: String, message: String) {
        closeQuick()
        let panel = makePanel(
            size: Self.messageSize,
            minSize: Self.messageSize,
            title: title,
            content: PreviewMessageView(title: title, message: message) { [weak self] in self?.closeQuick() }
        )
        quickPanel = panel
        installDismissMonitors()
        panel.makeKeyAndOrderFront(nil)
    }

    func promote() {
        guard let model = quickModel else { return }
        dismissQuickPanel()
        // The window inherits the panel's live engine, so the quick slot must let go of it here
        // rather than release it: the next quick preview would otherwise check the engine back in
        // underneath the window that is still drawing with it.
        quickModel = nil
        let window = FlowPeekGlassWindow(
            contentRect: CGRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentViewController = NSHostingController(
            rootView: DiagramPreviewView(
                model: model,
                compact: false,
                onPromote: {},
                // Keyed to this window, not to whichever one the coordinator saw last: the close dot
                // of the older window used to close the newer one.
                onClose: { [weak self, weak window] in
                    guard let window else { return }
                    self?.close(window)
                }
            )
        )
        // NSHostingController resizes the window to the SwiftUI fitting size, which collapses a
        // 1000x720 window to ~87x111 — the content size has to be re-imposed afterwards.
        window.setContentSize(Self.windowSize)
        window.contentMinSize = Self.windowMinSize
        if let previous = promoted.last?.window {
            // Two diagrams are opened in windows to be compared; centring the second one would hide
            // it exactly behind the first. Clamped because a borderless window is not kept on the
            // screen for us, and the offsets accumulate.
            window.setFrameOrigin(ScreenGeometry.clamp(
                origin: CGPoint(x: previous.frame.minX + 26, y: previous.frame.minY - 26),
                size: window.frame.size,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ))
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        promoted.append(Promoted(window: window, model: model))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func selectionDidChange() { closeQuick() }

    func closeQuick() {
        dismissQuickPanel()
        releaseQuickModel()
    }

    /// Closes one promoted window and hands its engine back. The window is looked up rather than
    /// assumed, so a stale callback for a window that is already gone does nothing.
    private func close(_ window: NSWindow) {
        guard let index = promoted.firstIndex(where: { $0.window === window }) else { return }
        let entry = promoted.remove(at: index)
        entry.window.delegate = nil
        entry.window.close()
        entry.model.release()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === quickPanel {
            quickPanel = nil
            removeDismissMonitors()
            releaseQuickModel()
        } else if let index = promoted.firstIndex(where: { $0.window === closing }) {
            // Escape reaches `cancelOperation`, which closes the window without going through
            // `close(_:)`; this is the only path that returns that window's engine.
            let entry = promoted.remove(at: index)
            entry.window.delegate = nil
            entry.model.release()
        }
    }

    // MARK: - Internals

    private func makePanel(size: CGSize, minSize: CGSize, title: String, content: some View) -> NSPanel {
        // Borderless, like the onboarding and settings surfaces: the glass is the window, and the
        // close button is drawn by SwiftUI. `.resizable` still gives the edges a drag region.
        let panel = FlowPeekGlassPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: content)
        // Same collapse as `promote()`: 720x520 became ~215x111 without this.
        panel.setContentSize(size)
        panel.contentMinSize = minSize
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    private func dismissQuickPanel() {
        removeDismissMonitors()
        guard let panel = quickPanel else { return }
        quickPanel = nil
        panel.delegate = nil
        panel.close()
    }

    /// Unconditional: a quick panel closed while a promoted window is open still owns its own
    /// engine, and leaving it checked out cost the pool one pre-warmed view per preview.
    private func releaseQuickModel() {
        quickModel?.release()
        quickModel = nil
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.closeQuick() }
        }) { dismissMonitors.append(global) }
        // A local monitor never fires for a non-activating panel: the key window belongs to another
        // application, so the Escape key has to be observed globally.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.closeQuick() }
        }) { dismissMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.closeQuick()
            return nil
        }) { dismissMonitors.append(local) }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
    }
}

/// Quick Look's shape: one pane of glass, a thin chrome strip, and the diagram itself sitting
/// directly on the material with nothing boxed around it.
struct DiagramPreviewView: View {
    @ObservedObject var model: DiagramViewModel
    let compact: Bool
    let onPromote: () -> Void
    let onClose: () -> Void

    private var cornerRadius: CGFloat { compact ? 20 : 24 }

    var body: some View {
        FlowPeekGlassSurface(cornerRadius: cornerRadius) {
            VStack(spacing: 0) {
                chrome
                DiagramStage(model: model, inset: compact ? 8 : 14)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            FlowPeekWindowCloseButton(action: onClose)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            zoomCluster
            if compact {
                chromeButton("macwindow", help: "preview.open-window", action: onPromote)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var zoomCluster: some View {
        HStack(spacing: 1) {
            chromeButton("minus", help: "preview.zoom-out") { model.zoom(by: 0.8) }
            Text(verbatim: "\(Int((model.scale * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44)
            chromeButton("plus", help: "preview.zoom-in") { model.zoom(by: 1.25) }
            Divider().frame(height: 13).padding(.horizontal, 3)
            chromeButton("arrow.up.left.and.arrow.down.right", help: "preview.fit") { model.fit() }
            chromeButton("1.magnifyingglass", help: "preview.actual-size") { model.actualSize() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func chromeButton(
        _ symbol: String,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PreviewMessageView: View {
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        FlowPeekGlassSurface(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    FlowPeekWindowCloseButton(action: onClose)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(title).font(.headline).lineLimit(1)
                }
                ScrollView {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
