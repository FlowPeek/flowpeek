import Foundation

/// Where an update has got to, as something a view can draw.
///
/// The whole point of this type is that an update is a *state of the app*, not an event that
/// interrupts it. Sparkle's own interface answers the same question with a window that takes the
/// keyboard away mid-sentence; this is the same information, in a form the menu bar panel and the
/// settings pane can show quietly and the reader can act on when they feel like it.
public enum UpdateState: Equatable, Sendable {
    /// Nothing to say. Either nothing has been checked yet, or the last check found nothing.
    case idle
    /// A check the reader asked for is in flight. Not published for background checks, which must
    /// stay invisible until they have something to report.
    case checking
    /// There is a newer version. `version` is its display version, for a reader who wants to know
    /// what they are being offered.
    case available(version: String)
    /// Being fetched. `fraction` is 0...1, or nil while the size is still unknown.
    case downloading(fraction: Double?)
    /// Downloaded and unpacked. Nothing else happens until the reader says so.
    case readyToInstall(version: String)
    /// Being written into place. The app is about to go away and come back.
    case installing
    /// The last thing tried did not work. Kept rather than thrown away so the reader is not left
    /// wondering why nothing happened.
    case failed(String)

    /// Whether this is worth putting in front of somebody. The three states that are waiting on a
    /// decision; the rest are either nothing or already in hand.
    public var wantsAttention: Bool {
        switch self {
        case .available, .readyToInstall, .failed: true
        case .idle, .checking, .downloading, .installing: false
        }
    }

    /// Whether an update is somewhere in the pipeline, which is what stops a second check starting
    /// on top of one already running.
    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        case .idle, .available, .readyToInstall, .failed: false
        }
    }

    /// The version being offered, where there is one.
    public var version: String? {
        switch self {
        case .available(let version), .readyToInstall(let version): version
        default: nil
        }
    }
}
