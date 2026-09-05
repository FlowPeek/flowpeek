import AppKit
import FlowPeekCore
import OSLog
import UniformTypeIdentifiers
import WebKit

/// Turns a rendered diagram into something that can leave the panel.
///
/// The SVG is already in hand — `MermaidRenderResult.svg` — so that one is a string operation. The
/// bitmap and the vector are drawn by WebKit, in a throw-away page of exactly the diagram's size
/// (see `MermaidEnginePage.exportDocument`), never in the live preview: the live page's scroller is
/// its own viewport, so a snapshot of it is the part the user happens to be looking at.
@MainActor
final class DiagramExporter {
    struct Request {
        let svg: String
        let size: CGSize
        /// The canvas a bitmap is flattened onto. PNG has no useful transparent story once it is
        /// pasted — a light diagram on a dark slide loses its strokes — so it gets the same solid
        /// colour the diagram was themed for; PDF and SVG stay transparent, which is what a vector
        /// asset is for.
        let backgroundHex: String
    }

    enum Failure: LocalizedError {
        case nothingRendered
        case pageFailed(String)
        case pageTimedOut(seconds: Int)
        case noBitmap

        var errorDescription: String? {
            switch self {
            case .nothingRendered: "there is no rendered diagram to export"
            case .pageFailed(let detail): "the export page did not load: \(detail)"
            case .pageTimedOut(let seconds): "the export page did not load within \(seconds)s"
            case .noBitmap: "WebKit produced no bitmap for the export page"
            }
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Export")

    func data(_ format: DiagramExportFormat, for request: Request) async throws -> Data {
        guard !request.svg.isEmpty, request.size.width > 0, request.size.height > 0 else {
            throw Failure.nothingRendered
        }
        // The vector is already in hand, so only the drawn formats need a page at all.
        guard format.needsRedraw else {
            return Data(DiagramSVGDocument.standalone(request.svg).utf8)
        }
        let session = try await Session(
            request: request,
            opaque: format == .png,
            logger: logger
        )
        defer { session.finish() }
        return format == .png ? try await session.png() : try await session.pdf()
    }

    /// Writes an export to a file the user picks. Returns false when they cancel.
    @discardableResult
    func save(_ format: DiagramExportFormat, for request: Request, title: String) async throws -> Bool {
        let data = try await data(format, for: request)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagramExportName.fileName(for: title, format: format)
        if let type = UTType(format.contentType) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // FlowPeek is LSUIElement showing a non-activating panel, so without this the save panel
        // appears without keyboard focus: the name field cannot be typed into and Return does
        // nothing. Activating also takes FlowPeek's own keys out of its global monitors, which is
        // what keeps Escape cancelling the save panel instead of closing the preview behind it.
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.beginSheetless() == .OK, let url = panel.url else { return false }
        // The preview can go while the panel is up: a click in another application dismisses the
        // quick panel, which releases its model and cancels this task. Nothing is written for a
        // surface that no longer exists.
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        return true
    }

    /// One throw-away web view, alive for the length of one export. Two loads per copy (opaque for
    /// the bitmap, transparent for the vector) cost a navigation each: the page carries neither
    /// mermaid nor the glue, so there is nothing to warm.
    ///
    /// The view is never put in a window and never on screen. Measured: `takeSnapshot` with
    /// `afterScreenUpdates` still returns the drawn page for a view with no window at all -- an
    /// off-screen host panel made no difference to the bitmap and only added a window to tear down.
    @MainActor
    private final class Session {
        private let webView: WKWebView
        private let policy = MermaidWebPolicy()
        /// The whole-point rectangle the page is laid out and captured in.
        private let size: CGSize
        /// The diagram's own fractional size, which the bitmap's pixel count is derived from: a
        /// `viewBox` is fractional, and rounding it up before doubling drifts the export off the
        /// size the panel reports.
        private let natural: CGSize
        /// The load in flight, and the clock on it. Both are cleared by whichever of the three
        /// outcomes arrives first.
        private var pending: CheckedContinuation<Void, any Error>?
        private var deadline: Task<Void, Never>?

        init(request: Request, opaque: Bool, logger: Logger) async throws {
            natural = request.size
            size = CGSize(width: request.size.width.rounded(.up), height: request.size.height.rounded(.up))
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // Nothing in this document is scripted, and the SVG inside it was scrubbed by the glue
            // before it ever reached Swift.
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
            webView.navigationDelegate = policy
            webView.uiDelegate = policy
            if !opaque, webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
                webView.setValue(false, forKey: "drawsBackground")
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pending = continuation
                policy.onFinish = { [weak self] in self?.settle(.success(())) }
                policy.onFatal = { [weak self] error in
                    self?.settle(.failure(Failure.pageFailed(error.localizedDescription)))
                }
                // A navigation decision that reaches neither callback — a cancelled one does — used
                // to leave this continuation, and the web view behind it, alive for the life of the
                // process, with ⌘C reporting nothing at all. The same clock the renders run under.
                deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(MermaidRenderLimits.timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    self?.settle(.failure(Failure.pageTimedOut(seconds: MermaidRenderLimits.timeoutSeconds)))
                }
                webView.loadHTMLString(
                    MermaidEnginePage.exportDocument(
                        svg: request.svg,
                        width: Double(request.size.width),
                        height: Double(request.size.height),
                        background: opaque ? request.backgroundHex : "transparent"
                    ),
                    baseURL: nil
                )
            }
            logger.debug("export page loaded at \(Int(self.size.width), privacy: .public)x\(Int(self.size.height), privacy: .public)")
        }

        func pdf() async throws -> Data {
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            return try await webView.pdf(configuration: configuration)
        }

        func png() async throws -> Data {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            configuration.afterScreenUpdates = true
            // `snapshotWidth` is documented in *points*, and WebKit then multiplies by the backing
            // scale of the screen the view is on: measured, a snapshotWidth of 216 came back 432
            // pixels wide on this display. So the requested pixel count is divided back out, and a
            // 2x export is 2x on a Retina display and on a 1x one alike.
            if let pixels = DiagramExportImage.pixelSize(for: natural) {
                let backing = NSScreen.main?.backingScaleFactor ?? 2
                configuration.snapshotWidth = NSNumber(value: Double(pixels.width) / max(1, backing))
            }
            let image = try await webView.takeSnapshot(configuration: configuration)
            guard let tiff = image.tiffRepresentation,
                  let representation = NSBitmapImageRep(data: tiff),
                  let png = representation.representation(using: .png, properties: [:]) else {
                throw Failure.noBitmap
            }
            return png
        }

        /// Whichever outcome arrives first wins; the other two find nothing to resume.
        private func settle(_ outcome: Result<Void, any Error>) {
            guard let continuation = pending else { return }
            pending = nil
            deadline?.cancel()
            deadline = nil
            continuation.resume(with: outcome)
        }

        func finish() {
            deadline?.cancel()
            deadline = nil
            policy.onFinish = nil
            policy.onFatal = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
    }
}

@MainActor
extension NSSavePanel {
    /// `beginSheetModal(for:)` needs a parent window, and the surface that asked for the save is a
    /// borderless non-activating panel that must not be blocked by a sheet — closing the preview
    /// while its own sheet is up strands the sheet. `begin` is modal to nothing instead, which also
    /// means the panel outlives the preview rather than closing with it: a click in another
    /// application dismisses the quick panel, and the save panel would be left standing over a
    /// released model, still able to write a file for a surface that is gone. So the caller's
    /// cancellation takes it down here.
    ///
    /// The level is raised for the same reason the modality changed: the preview is `.floating` and
    /// both are centred, so an ordinary save panel opens *underneath* the panel that asked for it.
    fileprivate func beginSheetless() async -> NSApplication.ModalResponse {
        level = .modalPanel
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                begin { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(nil) }
        }
    }
}

/// Writes one diagram to the clipboard in every form we can produce, richest last: an application
/// takes the first type it understands, and "it pasted as a picture" is the outcome that has to
/// hold everywhere. Keynote, Pages and Sketch ask for PDF by name and still get the vector.
@MainActor
enum DiagramPasteboard {
    static func write(_ payloads: [(DiagramExportFormat, Data)]) {
        guard !payloads.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let ordered = DiagramExportFormat.clipboardOrder.compactMap { format in
            payloads.first { $0.0 == format }
        }
        pasteboard.clearContents()
        pasteboard.declareTypes(ordered.map { NSPasteboard.PasteboardType($0.0.contentType) }, owner: nil)
        for (format, data) in ordered {
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(format.contentType))
        }
    }

    static func write(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
