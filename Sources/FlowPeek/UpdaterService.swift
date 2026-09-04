import AppKit
import Foundation
import Sparkle

@MainActor
final class UpdaterService {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .flowPeekCheckForUpdates, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.controller.updater.canCheckForUpdates == true { self?.controller.checkForUpdates(nil) }
                else { NSSound.beep() }
            }
        }
    }
}
