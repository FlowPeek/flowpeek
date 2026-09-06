import AppKit
import FlowPeekCore

/// The theme a Quick Look preview draws with.
///
/// Read from the system setting rather than from the view. The app's `MermaidThemeFactory` asks
/// `NSApp.effectiveAppearance`, and an extension has no `NSApp`; asking the view instead looked
/// right and was not -- the diagram is prepared before the view is in a window, so
/// `effectiveAppearance` answers the process default and a dark Quick Look panel got a light
/// diagram: black strokes and black text on a black ground, which draws as solid black boxes.
///
/// `AppleInterfaceStyle` lives in the global domain, which `UserDefaults.standard` reads even from
/// inside the sandbox, and it is absent rather than "Light" when the Mac is in light mode.
enum QuickLookTheme {
    static func current() -> MacMermaidTheme {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? ""
        return MacMermaidTheme(
            appearance: style.lowercased().contains("dark") ? .dark : .light,
            accentHex: NSColor.controlAccentColor.hexRGB,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

private extension NSColor {
    /// The same conversion the app uses. Duplicated rather than shared because the app's copy lives
    /// beside the web view pool, which an extension has no business linking.
    var hexRGB: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#007AFF" }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }
}
