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
        case failed(MermaidFailurePresentation)
    }

    @Published var title: String
    @Published private(set) var status: Status = .idle
    /// Raised beside the title when a diagram drew but not as written. Never blocking: the diagram
    /// is on screen, and this is the only place FlowPeek admits it is not all of it.
    @Published private(set) var notice: DiagramNotice?
    @Published private(set) var scale: Double = 1
    @Published private(set) var engine: MermaidEngineView?
    /// Transparent by default: a diagram reads as part of the glass rather than as a slide pasted
    /// on top of it. Some palettes -- a light-themed diagram over a dark desktop -- need the solid
    /// canvas back, so this is one click away in the preview's own chrome and remembered after.
    @Published var backgroundTransparent = DiagramViewModel.storedTransparency {
        didSet {
            UserDefaults.standard.set(backgroundTransparent, forKey: DiagramViewModel.transparencyKey)
            engine?.setBackgroundTransparent(backgroundTransparent)
        }
    }

    static let transparencyKey = "flowpeek.preview.transparentBackground"
    private static var storedTransparency: Bool {
        UserDefaults.standard.object(forKey: transparencyKey) as? Bool ?? true
    }

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
            status = .failed(MermaidFailurePresentation.make(error))
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
        view.setBackgroundTransparent(backgroundTransparent)
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

    /// `render()` gives up when there is no engine, and `replaceEngine()` can leave it nil, so the
    /// button in the failure card has to be allowed to check a view back out first.
    func retry() {
        if engine == nil { attach() } else { render() }
    }

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
        notice = nil
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
                self.notice = result.notice
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
                self.notice = nil
                switch error {
                case .webContentTerminated, .navigationFailed:
                    self.recover(from: error, retrying: true)
                case .timedOut:
                    self.recover(from: error, retrying: false)
                default:
                    self.status = .failed(MermaidFailurePresentation.make(error, source: self.source))
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
            status = .failed(MermaidFailurePresentation.make(error))
            logger.error("no replacement engine available: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard retrying, !didRetryAfterCrash else {
            status = .failed(MermaidFailurePresentation.make(failure, source: source))
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
            if case .failed(let presentation) = model.status {
                DiagramFailureView(
                    presentation: presentation,
                    source: model.source,
                    onRetry: { model.retry() }
                )
            }
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            model.update(appearance: scheme == .dark ? .dark : .light)
        }
    }
}

/// The failure card. Two tiers, in this order: what went wrong and what to do about it, in the
/// reader's own language; then, folded away, the engine's own words — a jison caret diagram only
/// starts to mean something in a fixed-width font, and the "No diagram type detected … for text:"
/// message carries the whole selection back, which nobody needs to read.
struct DiagramFailureView: View {
    let presentation: MermaidFailurePresentation
    let source: String
    let onRetry: () -> Void

    @State private var showsDetails = false

    var body: some View {
        // Nothing here grows without a bound — the headline and the hint are one sentence each, the
        // quote is clipped at two lines, and only the engine text scrolls — so the card needs no
        // scroll view of its own, and nesting one would fight the disclosure's.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(verbatim: presentation.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quoted = presentation.quotedLine {
                Text(verbatim: quoted)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let hint = presentation.hint {
                Text(verbatim: hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                switch presentation.recovery {
                case .retry:
                    Button("preview.failure.retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                case .fixSource:
                    Button("preview.failure.copy-source") { copy(source) }
                        .buttonStyle(.borderedProminent)
                case .none:
                    EmptyView()
                }
                if presentation.engineDetails != nil {
                    Button("preview.failure.copy-details") { copy(report) }
                }
            }
            .controlSize(.small)
            if let details = presentation.engineDetails {
                DisclosureGroup(isExpanded: $showsDetails) {
                    ScrollView {
                        Text(verbatim: details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                } label: {
                    Text("preview.failure.details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.orange.opacity(0.32)))
        .padding(24)
    }

    /// The engine text plus the build it came from: everything we would ask for in a bug report.
    private var report: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return presentation.diagnosticReport + "\nFlowPeek \(version ?? "?")"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                // The inspector has room for one line, so it gets the headline and the offending
                // line — never the engine text the card keeps behind its disclosure.
                if case .failed(let presentation) = status { onFailure?(presentation.plainSummary) } else { onFailure?(nil) }
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

    /// Fired whenever the answer to "is there a promoted window to go back to" changes, so the
    /// menu-bar entry that offers the way back can appear and disappear with it.
    var onPromotedChange: ((Bool) -> Void)?

    private var quickPanel: NSPanel?
    private var quickModel: DiagramViewModel?
    private var promoted: [Promoted] = [] {
        didSet {
            guard promoted.isEmpty != oldValue.isEmpty else { return }
            onPromotedChange?(!promoted.isEmpty)
        }
    }
    private var dismissMonitors: [Any] = []
    private let pool: MermaidWebViewPool
    /// The message panel reuses `quickPanel` but has a fixed size, so its frame is never stored.
    private var quickPanelIsDiagram = false
    /// Surfaces whose layout has settled. The resizes that happen while a surface is being built
    /// are FlowPeek's own; recording them made the remembered size grow with every open.
    private var shownSurfaces: Set<PreviewSizeMemory.Surface> = []
    /// Long enough for SwiftUI's first layout passes to finish, short enough that a user cannot
    /// have finished a resize drag inside it.
    private static let settleDelay: Duration = .milliseconds(400)

    init(pool: MermaidWebViewPool = .shared) {
        self.pool = pool
        super.init()
    }

    private func markSettled(_ surface: PreviewSizeMemory.Surface) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            self?.shownSurfaces.insert(surface)
        }
    }

    private static let quickSize = CGSize(width: 720, height: 520)
    private static let quickMinSize = CGSize(width: 360, height: 260)
    private static let windowSize = CGSize(width: 1000, height: 720)
    private static let windowMinSize = CGSize(width: 480, height: 340)
    private static let messageSize = CGSize(width: 460, height: 240)

    /// The size the user last dragged this surface to, or nil if they never have.
    private func rememberedSize(for surface: PreviewSizeMemory.Surface) -> CGSize? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: surface.widthKey) != nil,
              defaults.object(forKey: surface.heightKey) != nil else { return nil }
        return CGSize(
            width: defaults.double(forKey: surface.widthKey),
            height: defaults.double(forKey: surface.heightKey)
        )
    }

    private func remember(_ size: CGSize, for surface: PreviewSizeMemory.Surface, minimum: CGSize) {
        guard PreviewSizeMemory.shouldRemember(size, minimum: minimum) else { return }
        UserDefaults.standard.set(Double(size.width), forKey: surface.widthKey)
        UserDefaults.standard.set(Double(size.height), forKey: surface.heightKey)
    }

    /// Where the preview is about to appear, so a size saved on a large display is capped here.
    private func targetVisibleFrame() -> CGRect? {
        ScreenGeometry.visibleFrame(
            containing: NSEvent.mouseLocation,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        ) ?? NSScreen.main?.visibleFrame
    }

    private func openingSize(
        for surface: PreviewSizeMemory.Surface,
        fallback: CGSize,
        minimum: CGSize
    ) -> CGSize {
        PreviewSizeMemory.size(
            stored: rememberedSize(for: surface),
            fallback: fallback,
            minimum: minimum,
            visibleFrame: targetVisibleFrame()
        )
    }

    /// Which surface a window belongs to, or nil for the fixed-size message panel. Every promoted
    /// window shares the one remembered size: the size is a property of the surface, not of which
    /// copy of it happens to be on screen.
    private func surface(of window: NSWindow) -> PreviewSizeMemory.Surface? {
        if window === quickPanel, quickPanelIsDiagram { return .quick }
        if promoted.contains(where: { $0.window === window }) { return .window }
        return nil
    }

    func showQuick(document: DiagramDocument) {
        closeQuick()
        let model = DiagramViewModel(document: document, pool: pool)
        quickModel = model
        model.attach()
        quickPanelIsDiagram = true
        let panel = makePanel(
            size: openingSize(for: .quick, fallback: Self.quickSize, minimum: Self.quickMinSize),
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
        markSettled(.quick)
    }

    /// The engine could not run, or the selection failed validation: say why, in a panel. This is
    /// the branch that used to be `NSSound.beep()`.
    func showMessage(title: String, message: String) {
        closeQuick()
        quickPanelIsDiagram = false
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
        let opening = openingSize(for: .window, fallback: Self.windowSize, minimum: Self.windowMinSize)
        let window = FlowPeekGlassWindow(
            contentRect: CGRect(origin: .zero, size: opening),
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
        // See `makePanel`: a hosting controller would re-impose SwiftUI's fitting size on every
        // layout and the window could not be resized at all.
        let hosting = NSHostingView(
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
        hosting.frame = CGRect(origin: .zero, size: opening)
        window.contentView = ResizableContentView(content: hosting)
        window.setFrame(CGRect(origin: window.frame.origin, size: opening), display: false)
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
        markSettled(.window)
    }

    /// Whether there is a promoted window to go back to, for the menu-bar entry that offers it.
    var hasPromotedPreviews: Bool { !promoted.isEmpty }

    /// Brings every promoted preview back in front. A borderless window has no entry in the Window
    /// menu and no Dock icon of its own, so once another app is in front of it the menu bar is the
    /// only way back to it.
    func revealPromoted() {
        guard !promoted.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Ordered oldest first so the most recently opened one ends up on top, which is where the
        // user last left it.
        for entry in promoted { entry.window.orderFront(nil) }
        promoted.last?.window.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// Appends to the file named by FLOWPEEK_TRACE, so a dismissal can be attributed to the path
    /// that caused it instead of guessed at. Does nothing unless that variable is set.
    private func trace(_ what: String) {
        guard let path = ProcessInfo.processInfo.environment["FLOWPEEK_TRACE"] else { return }
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(what)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    #else
    private func trace(_ what: String) {}
    #endif

    func selectionDidChange() {
        trace("selectionDidChange")
        closeQuick()
    }

    func closeQuick() {
        trace("closeQuick")
        dismissQuickPanel()
        releaseQuickModel()
    }

    /// Closes one promoted window and hands its engine back. The window is looked up rather than
    /// assumed, so a stale callback for a window that is already gone does nothing.
    private func close(_ window: NSWindow) {
        guard let index = promoted.firstIndex(where: { $0.window === window }) else { return }
        let entry = promoted.remove(at: index)
        if promoted.isEmpty { shownSurfaces.remove(.window) }
        entry.window.delegate = nil
        entry.window.close()
        entry.model.release()
    }

    // MARK: - NSWindowDelegate

    /// Any resize after the surface is on screen, not just the end of a live drag: a size set by
    /// zooming, by another window manager, or through accessibility is just as much the size the
    /// user chose, and none of those produce a live-resize notification.
    func windowDidResize(_ notification: Notification) {
        guard let resized = notification.object as? NSWindow,
              let surface = surface(of: resized),
              shownSurfaces.contains(surface) else { return }
        let size = resized.frame.size
        trace("resize \(surface.rawValue) \(Int(size.width))x\(Int(size.height))")
        remember(size, for: surface, minimum: surface == .quick ? Self.quickMinSize : Self.windowMinSize)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === quickPanel {
            shownSurfaces.remove(.quick)
            quickPanel = nil
            removeDismissMonitors()
            releaseQuickModel()
        } else if let index = promoted.firstIndex(where: { $0.window === closing }) {
            // Escape reaches `cancelOperation`, which closes the window without going through
            // `close(_:)`; this is the only path that returns that window's engine.
            let entry = promoted.remove(at: index)
            if promoted.isEmpty { shownSurfaces.remove(.window) }
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
        // A hosting *view*, not a hosting controller. A controller pushes SwiftUI's fitting size
        // onto the window on every layout, so the surface was not really resizable: a resize to
        // 900x640 collapsed straight back to 320x220, which is exactly the minimum in
        // `DiagramPreviewView`'s frame. The window owns its size; SwiftUI fills it.
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = ResizableContentView(content: hosting)
        panel.setFrame(CGRect(origin: panel.frame.origin, size: size), display: false)
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
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                // Clicking or dragging inside the preview is interaction with the preview. Without
                // this the resize edge dismissed the very panel being resized.
                guard !OwnWindowHitTest.contains(location) else {
                    self?.trace("mouseDown ignored (own window)")
                    return
                }
                self?.trace("mouseDown dismiss")
                self?.closeQuick()
            }
        }) { dismissMonitors.append(global) }
        // A local monitor never fires for a non-activating panel: the key window belongs to another
        // application, so the Escape key has to be observed globally.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                self?.trace("escape dismiss")
                self?.closeQuick()
            }
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

    @State private var showsNotice = false

    private var cornerRadius: CGFloat { compact ? 20 : 24 }

    private var hasDiagram: Bool {
        if case .failed = model.status { return false }
        return true
    }

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
            if let notice = model.notice { noticeBadge(notice) }
            Spacer(minLength: 12)
            chromeButton(
                model.backgroundTransparent ? "checkerboard.rectangle" : "square.fill",
                help: model.backgroundTransparent ? "preview.background.solid" : "preview.background.transparent"
            ) { model.backgroundTransparent.toggle() }
            zoomCluster
                .disabled(!hasDiagram)
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

    /// Quiet on purpose: the diagram did render, so this is a footnote next to its title and never
    /// a sheet, an alert, or anything that has to be dismissed before reading the diagram.
    private func noticeBadge(_ notice: DiagramNotice) -> some View {
        Button { showsNotice.toggle() } label: {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey(DiagramNotice.badgeKey))
        .accessibilityLabel(Text(LocalizedStringKey(DiagramNotice.badgeKey)))
        .popover(isPresented: $showsNotice, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(DiagramNotice.badgeKey)).font(.headline)
                ForEach(notice.reasons, id: \.self) { reason in
                    Text(LocalizedStringKey(reason.localizationKey))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !notice.details.isEmpty {
                    Text(verbatim: String(
                        format: String(localized: String.LocalizationValue(DiagramNotice.detailsKey)),
                        notice.details.joined(separator: ", ")
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
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
