public enum AppCommand: Equatable, Sendable {
    case showSettings
    /// Bring a promoted preview window back in front. A borderless window has no Dock icon and no
    /// entry in the Window menu, so once another app covers it the menu bar is the only way back.
    case revealPreview
}

public struct AppCommandRouter {
    private let showSettings: () -> Void
    private let revealPreview: () -> Void

    public init(showSettings: @escaping () -> Void, revealPreview: @escaping () -> Void) {
        self.showSettings = showSettings
        self.revealPreview = revealPreview
    }

    public func handle(_ command: AppCommand) {
        switch command {
        case .showSettings:
            showSettings()
        case .revealPreview:
            revealPreview()
        }
    }
}
