import Foundation

/// Everything the preview can be asked to do from the keyboard, independent of which surface asked.
public enum PreviewCommand: Equatable, Sendable {
    case zoomIn
    case zoomOut
    case fit
    case actualSize
    case pan(dx: Double, dy: Double)
    case copyImage
    case copySource
    case save
    case close
}

/// One key press, reduced to the parts a binding depends on. Virtual key codes, not characters:
/// the codes are layout-independent, and `charactersIgnoringModifiers` for the zoom keys already
/// disagrees between a US and a German keyboard.
public struct PreviewKeyStroke: Equatable, Sendable {
    public let keyCode: UInt16
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool

    public init(keyCode: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    public var isUnmodified: Bool { !command && !shift && !option && !control }
}

/// Which keys reach which surface, and what they do there.
///
/// The two preview surfaces receive keyboard input in completely different ways, so they cannot
/// share a binding table. The promoted window is an ordinary activating window: it becomes key,
/// the application is frontmost, and Command combinations are FlowPeek's to take. The quick panel
/// is `.nonactivatingPanel` floating over somebody else's frontmost window: nothing is dispatched
/// to it, its keys are only ever *observed* through a global monitor, and a global monitor cannot
/// consume what it sees. So in the panel:
///
/// - No Command combination is bound. ⌘C there would still be delivered to the application the
///   user is actually typing in, and FlowPeek would overwrite the clipboard they just filled.
/// - Only Escape is answered from the global monitor. The viewport keys are unmodified characters,
///   so while somebody else's window is frontmost they belong to whatever the user is typing into:
///   answering them there means a `-` typed into an editor also zooms a panel floating over it,
///   with nothing on screen to explain why. They are answered only once the panel itself is the
///   key window, where the local monitor sees them and can consume them.
public enum PreviewKeyBinding {
    public enum Surface: Sendable {
        /// The quick panel while somebody else's window is frontmost: keys are merely observed, and
        /// an observer cannot take a key away from the application it was meant for.
        case observedPanel
        /// The quick panel once it is the key window, so its keys arrive and can be consumed.
        case panel
        case window
    }

    /// About a line of a flowchart per press, and a screenful in five presses with Shift held.
    public static let panStep: Double = 60
    public static let fastPanStep: Double = 300

    private enum Key {
        static let one: UInt16 = 18
        static let zero: UInt16 = 29
        static let equal: UInt16 = 24
        static let minus: UInt16 = 27
        static let w: UInt16 = 13
        static let c: UInt16 = 8
        static let s: UInt16 = 1
        static let escape: UInt16 = 53
        static let keypadMinus: UInt16 = 78
        static let keypadPlus: UInt16 = 69
        static let keypadZero: UInt16 = 82
        static let keypadOne: UInt16 = 83
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    public static func command(for stroke: PreviewKeyStroke, surface: Surface) -> PreviewCommand? {
        // Option is the ambient-peek hold and Control belongs to whatever the user is doing
        // elsewhere; neither ever means a preview command.
        guard !stroke.option, !stroke.control else { return nil }
        // Escape first, because it is the only thing an observer may answer.
        if surface == .observedPanel {
            return stroke.keyCode == Key.escape && stroke.isUnmodified ? .close : nil
        }
        if let pan = pan(for: stroke) { return pan }
        switch surface {
        case .observedPanel:
            return nil
        case .panel:
            guard stroke.keyCode != Key.escape else { return stroke.isUnmodified ? .close : nil }
            guard !stroke.command else { return nil }
            return viewport(for: stroke)
        case .window:
            guard stroke.command else { return nil }
            switch stroke.keyCode {
            case Key.w: return stroke.shift ? nil : .close
            case Key.c: return stroke.shift ? .copySource : .copyImage
            case Key.s: return stroke.shift ? nil : .save
            default: return viewport(for: stroke)
            }
        }
    }

    /// Shift is allowed on the zoom keys because `+` is Shift-`=` on most layouts, so the two
    /// spellings of "zoom in" must not disagree.
    private static func viewport(for stroke: PreviewKeyStroke) -> PreviewCommand? {
        switch stroke.keyCode {
        case Key.equal, Key.keypadPlus: return .zoomIn
        case Key.minus, Key.keypadMinus: return .zoomOut
        case Key.zero, Key.keypadZero: return stroke.shift ? nil : .fit
        case Key.one, Key.keypadOne: return stroke.shift ? nil : .actualSize
        default: return nil
        }
    }

    /// Arrows pan on both surfaces and take no Command: in the window they would otherwise collide
    /// with the system's word- and line-jump equivalents.
    private static func pan(for stroke: PreviewKeyStroke) -> PreviewCommand? {
        guard !stroke.command else { return nil }
        let step = stroke.shift ? fastPanStep : panStep
        switch stroke.keyCode {
        case Key.left: return .pan(dx: -step, dy: 0)
        case Key.right: return .pan(dx: step, dy: 0)
        case Key.up: return .pan(dx: 0, dy: -step)
        case Key.down: return .pan(dx: 0, dy: step)
        default: return nil
        }
    }
}

extension PreviewKeyBinding {
    /// The key a surface really answers for a command, written the way a menu writes it.
    ///
    /// Composed here rather than translated — the glyphs are the same in every language. This is a
    /// second table and not the dispatch one: it spells keys for a reader, where `command(for:_:)`
    /// reads key codes, and the two are held together by the round trip the tests put every glyph
    /// through rather than by sharing code. The panel's are bare characters: it binds no Command
    /// combination, because a global monitor cannot take ⌘C away from the application underneath it.
    public static func glyph(for command: PreviewCommand, surface: Surface) -> String? {
        switch surface {
        case .observedPanel:
            // Escape is the only thing an observer may answer, so it is the only thing to promise.
            return command == .close ? "esc" : nil
        case .panel:
            switch command {
            case .zoomIn: return "+"
            case .zoomOut: return "−"
            case .fit: return "0"
            case .actualSize: return "1"
            case .close: return "esc"
            case .pan, .copyImage, .copySource, .save: return nil
            }
        case .window:
            switch command {
            case .zoomIn: return "⌘+"
            case .zoomOut: return "⌘−"
            case .fit: return "⌘0"
            case .actualSize: return "⌘1"
            case .copyImage: return "⌘C"
            case .copySource: return "⌘⇧C"
            case .save: return "⌘S"
            case .close: return "⌘W"
            case .pan: return nil
            }
        }
    }
}
