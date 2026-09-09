import Foundation

/// A colour the hint box can be drawn in, as three channels rather than a `Color`.
///
/// Core stays free of SwiftUI, and the stored form has to survive a round trip through
/// `UserDefaults` anyway, so the colour is carried as numbers here and turned into a `Color` at the
/// one place that draws it.
public struct HintTint: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// `#RRGGBB`, which is what the stored setting holds and what a palette entry is written as.
    ///
    /// Tolerant on the way in -- a leading `#` is optional and case does not matter -- because the
    /// value can be typed into `defaults write` by somebody scripting their setup, and strict on
    /// the way out so a stored value always reads the same.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

/// Which colour the hint box is drawn in.
///
/// The default follows the system accent, because that is what the hint looked like for every
/// version before this one and it is the colour the user already chose for their Mac. The override
/// exists because a hint is a *coloured* thing carrying meaning -- the frame says "there is a
/// diagram here", the chip says "click this" -- and around eight per cent of men see the accent
/// palette's blues and greens differently or barely at all. A colour somebody picked themselves is
/// the only one certain to be visible to them.
public enum HintTintChoice: Equatable, Sendable {
    case systemAccent
    case fixed(HintTint)

    /// The sentinel for "whatever the system accent is", which cannot be a colour: the accent is
    /// resolved at draw time and changes under the app.
    public static let systemStoredValue = "system"

    public var storedValue: String {
        switch self {
        case .systemAccent: Self.systemStoredValue
        case .fixed(let tint): tint.hex
        }
    }

    /// Anything unrecognised reads as the system accent rather than as an error. A setting written
    /// by a newer build, a hand-edited plist, a truncated value -- none of those is worth refusing
    /// to draw a hint over.
    public init(storedValue: String?) {
        guard let storedValue, storedValue != Self.systemStoredValue,
              let tint = HintTint(hex: storedValue) else {
            self = .systemAccent
            return
        }
        self = .fixed(tint)
    }
}

/// The colours offered as one-click choices.
///
/// Okabe and Ito's palette, published as a set that stays distinguishable under the common forms of
/// colour-vision deficiency -- protanopia, deuteranopia and tritanopia. Offered rather than
/// invented: a palette that has been checked is worth more here than eight colours that look nice
/// beside each other on one person's display, and it is what scientific figures use for the same
/// reason.
///
/// The order is the palette's own, which runs warm to cool and keeps adjacent swatches apart.
public enum HintTintPalette {
    public struct Entry: Equatable, Sendable {
        /// Names the swatch for the catalogue, as `hint.tint.<id>`. Not a colour name in English:
        /// "vermillion" is not a word most people reach for, and the catalogue can say "red-orange"
        /// in whichever language is on.
        public let id: String
        public let tint: HintTint

        init(_ id: String, _ hex: String) {
            self.id = id
            // Every literal below is a valid six-digit hex; a typo is a programming error and the
            // palette would be silently short one colour if it were dropped instead.
            guard let tint = HintTint(hex: hex) else {
                preconditionFailure("HintTintPalette entry \(id) is not a six-digit hex: \(hex)")
            }
            self.tint = tint
        }
    }

    public static let entries: [Entry] = [
        Entry("orange", "#E69F00"),
        Entry("skyBlue", "#56B4E9"),
        Entry("bluishGreen", "#009E73"),
        Entry("yellow", "#F0E442"),
        Entry("blue", "#0072B2"),
        Entry("vermillion", "#D55E00"),
        Entry("reddishPurple", "#CC79A7"),
    ]

    /// The palette entry a stored choice corresponds to, so the settings row can show which swatch
    /// is selected without the choice itself having to remember that it came from one.
    public static func entry(for choice: HintTintChoice) -> Entry? {
        guard case .fixed(let tint) = choice else { return nil }
        return entries.first { $0.tint == tint }
    }
}
