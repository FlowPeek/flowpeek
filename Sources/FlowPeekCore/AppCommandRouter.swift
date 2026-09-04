public enum AppCommand: Equatable, Sendable {
    case showSettings
}

public struct AppCommandRouter {
    private let showSettings: () -> Void

    public init(showSettings: @escaping () -> Void) {
        self.showSettings = showSettings
    }

    public func handle(_ command: AppCommand) {
        switch command {
        case .showSettings:
            showSettings()
        }
    }
}
