import CoreGraphics
import Foundation

/// The contract every integration plugin speaks, and the arithmetic that puts its answers on a
/// screen.
///
/// One shape for all of them on purpose. An editor that cannot be read through the accessibility
/// API can almost always be extended instead, and every one of those extensions has the same job:
/// say which Mermaid blocks are visible and where they are in the window. So the wire format is
/// defined once, here, and adding an editor is a plugin that writes this JSON plus one entry in
/// `AppIntegration.known`. No Swift in the watching path knows which editor it is talking to.
///
/// It is a published contract rather than a private one. Anybody can speak it: an editor's own
/// developer, a plugin author, or FlowPeek itself on behalf of an editor that has no other way in.
/// FlowPeek watches every provider it finds, whether or not it has ever heard of the application.
/// `docs/INTEGRATIONS.md` is the document that says so.
///
/// ## The contract
///
/// Three files in `~/Library/Application Support/FlowPeek/integrations/<provider id>/`:
///
/// - `integration.json` — the provider writes it once. It says which application this is, so
///   FlowPeek knows whose window to measure against. This file appearing is the whole of
///   registration; there is nothing to call and nobody to ask.
/// - `ask` — FlowPeek touches it while it wants answers, and deletes it when it stops. Its
///   modification date is the question; a provider that finds it older than a few seconds should go
///   back to idle, because FlowPeek has gone away.
/// - `answer.json` — the provider writes it, atomically, whenever the picture changes and only
///   while `ask` is fresh.
///
/// Both files name their `version`, so a provider newer than the app reading it is left alone
/// rather than misread. Coordinates are the window's own **content area**, top-left origin, in
/// points: no application knows where its own window is on somebody's screen, and FlowPeek does.
///
/// Content area rather than window frame because that is what a toolkit hands its own code.
/// Sublime's `text_to_window` answered 34 for a line the window frame put 66 down, the difference
/// being the title bar, and expecting every provider to add a number macOS has changed between
/// releases — 28 once, 32 now — is expecting them to get it wrong. FlowPeek asks the system
/// instead, and a provider whose window has no title bar says so with `content_inset_top`.
public enum IntegrationWatch {
    /// One answer. The field names are the wire format's, so the two sides can only drift with a
    /// version bump.
    public struct Answer: Codable, Equatable, Sendable {
        public struct Block: Codable, Equatable, Sendable {
            public var range: [Int]
            public var clipped: Bool
            /// Window coordinates, top-left origin, device independent pixels.
            public var x: Double
            public var top: Double
            public var bottom: Double
            public var text: String

            public init(range: [Int], clipped: Bool, x: Double, top: Double, bottom: Double, text: String) {
                self.range = range
                self.clipped = clipped
                self.x = x
                self.top = top
                self.bottom = bottom
                self.text = text
            }
        }

        public var version: Int
        public var ok: Bool
        public var at: Double?
        public var lineHeight: Double?
        public var emWidth: Double?
        /// How far the content area sits below the top of the window frame, when the provider knows
        /// better than the system does: zero for a window with no title bar, or a measured value
        /// for a window with unusual chrome. Left out by everybody else.
        public var contentInsetTop: Double?
        public var blocks: [Block]?

        enum CodingKeys: String, CodingKey {
            case version, ok, at, blocks
            case lineHeight = "line_height"
            case emWidth = "em_width"
            case contentInsetTop = "content_inset_top"
        }

        public init(
            version: Int,
            ok: Bool,
            at: Double? = nil,
            lineHeight: Double? = nil,
            emWidth: Double? = nil,
            contentInsetTop: Double? = nil,
            blocks: [Block]? = nil
        ) {
            self.version = version
            self.ok = ok
            self.at = at
            self.lineHeight = lineHeight
            self.emWidth = emWidth
            self.contentInsetTop = contentInsetTop
            self.blocks = blocks
        }
    }

    /// Where providers register themselves, under the user's Application Support directory.
    public static let directoryName = "integrations"
    public static let manifestName = "integration.json"
    public static let askName = "ask"
    public static let answerName = "answer.json"

    /// The wire format this build of FlowPeek knows how to read. An answer from a newer provider is
    /// left alone rather than guessed at.
    public static let supportedVersion = 1

    /// A provider saying who it speaks for.
    ///
    /// The bundle identifiers are the point of it: FlowPeek measures an answer against the window
    /// of the application in front, so it has to know which application this provider belongs to.
    /// Everything else is for the reader.
    public struct Manifest: Codable, Equatable, Sendable {
        public var version: Int
        public var id: String
        public var name: String
        public var bundleIdentifiers: [String]

        public init(version: Int = IntegrationWatch.supportedVersion, id: String, name: String, bundleIdentifiers: [String]) {
            self.version = version
            self.id = id
            self.name = name
            self.bundleIdentifiers = bundleIdentifiers
        }

        /// Whether this manifest can be acted on. A provider that names no application, or names
        /// itself nothing, is ignored rather than guessed at: the identifier is what its directory
        /// is found by and the bundle identifier is what its answers are measured against.
        public var isUsable: Bool {
            version == IntegrationWatch.supportedVersion
                && !id.isEmpty
                && !name.isEmpty
                && !bundleIdentifiers.isEmpty
                && bundleIdentifiers.allSatisfy { !$0.isEmpty }
        }
    }

    /// How stale an answer may be before it is treated as nothing. The plugin rewrites only when
    /// something moved, so a still editor's answer is old on purpose; this is the limit past which
    /// it is more likely that Sublime has stopped answering.
    public static let freshness: TimeInterval = 6

    /// How wide a frame is drawn, as a share of the editor's width.
    ///
    /// The plugin reports where a block starts and how tall it is, and says nothing about how wide
    /// it is: the API has no measure of a rendered line's right edge. So the frame runs from the
    /// block's left edge to a fixed distance short of the window's, which is the same shape the
    /// terminal watch draws for the same reason.
    public static let rightInset: Double = 24

    /// Whether an answer is worth drawing at all.
    public static func isUsable(_ answer: Answer, now: Double) -> Bool {
        guard answer.ok, answer.version == supportedVersion else { return false }
        guard let at = answer.at else { return true }
        return now - at <= freshness
    }

    /// One block's rectangle on screen, in AppKit coordinates.
    ///
    /// - Parameters:
    ///   - block: as the plugin reported it, in window coordinates with a top-left origin.
    ///   - window: the editor window's frame, top-left origin, as `CGWindowListCopyWindowInfo`
    ///     reports it.
    ///   - contentInsetTop: how far the content area is below the frame's top edge. The provider's
    ///     own figure when it gave one, the system's title bar height otherwise.
    ///   - flipReference: the `maxY` of the screen AppKit measures from.
    public static func screenRect(
        of block: Answer.Block,
        window: CGRect,
        contentInsetTop: CGFloat,
        flipReference: CGFloat
    ) -> CGRect? {
        let height = block.bottom - block.top
        guard height > 0, block.x.isFinite, block.top.isFinite else { return nil }
        let left = window.minX + block.x
        let right = max(left + 1, window.maxX - rightInset)
        let topLeftOrigin = CGRect(
            x: left,
            y: window.minY + contentInsetTop + block.top,
            width: right - left,
            height: height
        )
        let rect = ScreenGeometry.axToAppKit(topLeftOrigin, flipReference: flipReference)
        return ScreenGeometry.isUsable(rect) ? rect : nil
    }

    /// The blocks worth framing, in the order the plugin found them.
    ///
    /// A block running off the top or bottom of the viewport is dropped rather than framed at the
    /// edge: a frame with one side missing reads as a rendering fault, and the block underneath is
    /// half unreadable anyway.
    public static func drawable(_ answer: Answer) -> [Answer.Block] {
        (answer.blocks ?? []).filter { !$0.clipped && $0.bottom > $0.top }
    }
}
