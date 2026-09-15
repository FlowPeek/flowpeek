import AppKit
import Combine
import FlowPeekCore
import Foundation
import OSLog
import Sparkle

/// Sparkle, with its own windows switched off.
///
/// FlowPeek has no business interrupting somebody. The standard interface answers "there is an
/// update" by taking the keyboard away mid-sentence, in a window that has to be dealt with before
/// anything else can happen -- for news that could have waited indefinitely. So this supplies its
/// own `SPUUserDriver`, which draws nothing at all: every callback Sparkle makes is turned into a
/// published `UpdateState`, and the menu bar panel and the settings pane show it where the reader is
/// already looking.
///
/// Nothing installs itself. The state machine stops at `readyToInstall` and waits, because an app
/// that replaces itself while somebody is reading a diagram is the same interruption wearing a
/// different hat.
@MainActor
final class UpdaterService: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    /// Whether Sparkle is in a position to check at all. False in a debug build with no feed.
    @Published private(set) var canCheck = false
    /// Whether FlowPeek fetches updates on its own and puts them in place the next time it starts.
    ///
    /// On by default, because the alternative is a reader running a months-old build without ever
    /// deciding to. It is a switch rather than a fact, though: some people want to know what changed
    /// before it changes, and a menu bar app that rewrites itself unasked is a fair thing to refuse.
    ///
    /// It never interrupts either way. With it on, the download happens quietly and the new version
    /// is written into place when FlowPeek next starts -- not over a diagram somebody is reading.
    @Published var automatic: Bool = UpdaterService.storedAutomatic {
        didSet {
            guard automatic != oldValue else { return }
            UserDefaults.standard.set(automatic, forKey: Self.automaticKey)
            updater?.automaticallyChecksForUpdates = automatic
            updater?.automaticallyDownloadsUpdates = automatic
        }
    }

    /// True for a few seconds after a check the reader asked for came back with nothing.
    ///
    /// A check that finds nothing is still an answer, and pressing a button that gives none is how
    /// a button comes to feel broken. It decays on its own, because a row that permanently says
    /// "up to date" is a row nobody reads -- and then the one time it says something else it is
    /// invisible too.
    @Published private(set) var confirmedCurrent = false
    private var confirmationTask: Task<Void, Never>?
    /// How long that answer stays up. Long enough to read, short enough not to become furniture.
    private static let confirmationLinger: Duration = .seconds(4)

    /// Whether there is anything worth a row right now: something waiting, something happening, or
    /// something just answered.
    var isNoteworthy: Bool { state.wantsAttention || state.isBusy || confirmedCurrent }

    static let automaticKey = "flowpeek.updates.automatic"
    private static var storedAutomatic: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }

    private let driver = UpdateDriver()
    private let hooks = UpdateHooks()
    private var updater: SPUUpdater?
    private var observer: NSObjectProtocol?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "Updater")

    /// Held so the reader's own press can answer a question Sparkle asked earlier.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    init() {
        driver.owner = self
        // A build with no feed has nothing to check against; starting the updater there logs an
        // error on every launch and can never succeed.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        // `SPUUpdater` directly rather than `SPUStandardUpdaterController`, which always builds the
        // standard windowed driver and gives no way to supply another.
        hooks.owner = self
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: hooks
        )
        updater.automaticallyChecksForUpdates = automatic
        updater.automaticallyDownloadsUpdates = automatic
        do {
            try updater.start()
            self.updater = updater
            canCheck = updater.canCheckForUpdates
        } catch {
            logger.error("the updater did not start: \(error.localizedDescription, privacy: .public)")
        }
        observer = NotificationCenter.default.addObserver(
            forName: .flowPeekCheckForUpdates, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    // MARK: - What the reader can ask for

    /// Look now. Does nothing while something is already in flight, so a second press cannot start
    /// a second check on top of the first.
    func check() {
        confirmationTask?.cancel()
        confirmedCurrent = false
        guard let updater, !state.isBusy else { return }
        guard updater.canCheckForUpdates else {
            state = .failed(String(localized: "update.error.cannot-check"))
            return
        }
        logger.info("check requested")
        updater.checkForUpdates()
    }

    /// Take the update that has been offered. Downloading and installing both run from here, and
    /// both report back through `state`.
    func install() {
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        logger.info("install accepted")
        reply(.install)
    }

    /// Not now. Sparkle is told to stop rather than to skip the version: skipping is a decision
    /// about every future build of that version, and a reader dismissing a row has not made it.
    func dismiss() {
        let reply = pendingChoice
        pendingChoice = nil
        state = .idle
        reply?(.dismiss)
    }

    // MARK: - What the driver reports

    fileprivate func offer(_ item: SUAppcastItem, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state = .available(version: item.displayVersionString)
        logger.info("update available: \(item.displayVersionString, privacy: .public)")
        // With automatic updates on, the fetching needs no permission -- it is the *installing*
        // that waits, and it waits for the next launch. So the offer is taken here and the reader
        // is told what is happening rather than asked whether it may.
        if acceptsSilently {
            pendingChoice = nil
            reply(.install)
            return
        }
        pendingChoice = reply
    }

    fileprivate func ready(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = state.version ?? ""
        pendingChoice = reply
        state = .readyToInstall(version: version)
    }

    /// Sparkle has staged an update that will be written in when FlowPeek next starts. Answering
    /// yes is what makes "automatic" mean "on restart" rather than "right now, mid-sentence".
    fileprivate func willInstallOnQuit(_ item: SUAppcastItem) -> Bool {
        guard automatic else { return false }
        logger.info("staged \(item.displayVersionString, privacy: .public) for the next launch")
        state = .readyToInstall(version: item.displayVersionString)
        return true
    }

    /// Whether an offer should be taken without asking. True only while the reader has left
    /// automatic updates on; otherwise the offer waits on the row in the panel.
    fileprivate var acceptsSilently: Bool { automatic }

    fileprivate func note(_ next: UpdateState) {
        state = next
    }

    fileprivate func downloadStarted() {
        expectedBytes = 0
        receivedBytes = 0
        state = .downloading(fraction: nil)
    }

    fileprivate func downloadExpects(_ length: UInt64) {
        expectedBytes = length
    }

    fileprivate func downloadReceived(_ length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        state = .downloading(fraction: min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    fileprivate func failed(_ error: Error) {
        // Sparkle reports "no update found" as an error. That is an answer, not a fault, and a red
        // row for it would train people to ignore the row that matters.
        let code = (error as NSError).code
        if code == Int(SUError.noUpdateError.rawValue) {
            state = .idle
            logger.info("no update found")
            confirmCurrent()
            return
        }
        pendingChoice = nil
        state = .failed(error.localizedDescription)
        logger.error("update failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Say "nothing to get" for a moment, then stop saying it.
    private func confirmCurrent() {
        confirmationTask?.cancel()
        confirmedCurrent = true
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationLinger)
            guard !Task.isCancelled else { return }
            self?.confirmedCurrent = false
        }
    }

    fileprivate func finished() {
        pendingChoice = nil
        if case .failed = state { return }
        if case .readyToInstall = state { return }
        state = .idle
    }
}

/// The half of Sparkle that would have drawn windows. It draws nothing and reports everything.
@MainActor
private final class UpdateDriver: NSObject, SPUUserDriver {
    weak var owner: UpdaterService?

    /// Sparkle's "may I check automatically?" prompt on first launch. Answered without asking:
    /// checking is on, and telling nobody is the point of the rest of this file.
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.note(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        owner?.offer(appcastItem, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.failed(error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.failed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.downloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.downloadExpects(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.downloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.note(.downloading(fraction: 1))
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.ready(reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        owner?.note(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        owner?.note(.idle)
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        owner?.finished()
    }
}


/// The updater's delegate, kept apart from the driver because they answer different questions: the
/// driver is asked what to show, this is asked what to do.
@MainActor
private final class UpdateHooks: NSObject, SPUUpdaterDelegate {
    weak var owner: UpdaterService?

    /// Sparkle has an update staged and is asking whether to leave it for the next launch. Yes,
    /// while automatic updates are on: that is the whole of what "automatic" means here.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated { owner?.willInstallOnQuit(item) ?? false }
    }
}
