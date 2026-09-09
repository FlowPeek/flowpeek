import FlowPeekCore
import SwiftUI

/// The hint box, drawn small, in whatever colour is selected.
///
/// The illustration for this setting is the thing being set, so there is nothing to animate: a
/// script that walked through printing and framing would be showing the terminal watch again, and
/// the question here is only "what colour". It is still built from the skeleton pieces, so it reads
/// as the same object the other cards draw.
struct HintTintPreview: View {
    @Environment(\.skeletonTint) private var skeletonTint

    private static let rows: [Double] = [0.52, 0.31, 0.44, 0.28]

    var size: CGSize = Skeleton.cardSize

    var body: some View {
        SkeletonWindow {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Skeleton.rowGap) {
                    ForEach(Self.rows.indices, id: \.self) { index in
                        SkeletonRow(width: Self.rows[index])
                    }
                }
                frame
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private var frame: some View {
        let height = CGFloat(Self.rows.count) * Skeleton.rowHeight
            + CGFloat(Self.rows.count - 1) * Skeleton.rowGap + 6
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(skeletonTint.opacity(0.9), lineWidth: 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(skeletonTint.opacity(0.10))
            )
            .frame(height: height)
            .overlay(alignment: .topTrailing) { SkeletonLabel().padding(2) }
            .offset(y: -3)
    }
}

/// Picks the colour the frame and the chip are drawn in.
///
/// Two ways in, because they answer different questions. The swatches are a published palette that
/// stays separable under the common colour-vision deficiencies, so somebody who knows they cannot
/// rely on the accent has a row of colours that were checked rather than chosen by eye. The picker
/// is for everyone the palette does not happen to suit -- a deficiency is not a category with seven
/// members, and the only colour certain to work is the one its user can see.
struct HintTintPicker: View {
    @Binding var choice: HintTintChoice

    /// What the well shows and writes. Bound rather than derived so dragging in the picker updates
    /// the outline on screen as it goes.
    private var custom: Binding<Color> {
        Binding(
            get: { choice.color },
            set: { newValue in
                guard let tint = newValue.hintTint else { return }
                choice = .fixed(tint)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                swatch(for: .systemAccent, isSelected: choice == .systemAccent) {
                    // The accent is a swatch like any other, drawn in whatever the accent currently
                    // is, so "follow the system" is a colour the user can see rather than a word.
                    Circle().fill(Color.accentColor)
                }
                Divider().frame(height: 16)
                ForEach(HintTintPalette.entries, id: \.id) { entry in
                    let candidate = HintTintChoice.fixed(entry.tint)
                    swatch(for: candidate, isSelected: choice == candidate) {
                        Circle().fill(candidate.color)
                    }
                }
            }
            HStack(spacing: 8) {
                ColorPicker(selection: custom, supportsOpacity: false) {
                    Text("settings.hint-tint.custom")
                        .font(.callout)
                }
                .labelsHidden()
                Text("settings.hint-tint.custom")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func swatch(
        for candidate: HintTintChoice,
        isSelected: Bool,
        @ViewBuilder fill: () -> some View
    ) -> some View {
        Button {
            choice = candidate
        } label: {
            fill()
                .frame(width: 18, height: 18)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(isSelected ? 0.75 : 0.15), lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(Text(candidate.pickerLabel))
        .accessibilityLabel(Text(candidate.pickerLabel))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension HintTintChoice {
    /// What the swatch is called, for the tooltip and for VoiceOver -- which is the one reader that
    /// cannot see which colour it is.
    var pickerLabel: LocalizedStringKey {
        switch self {
        case .systemAccent: "settings.hint-tint.system"
        case .fixed:
            if let entry = HintTintPalette.entry(for: self) {
                LocalizedStringKey("hint-tint.\(entry.id)")
            } else {
                "settings.hint-tint.custom"
            }
        }
    }
}

extension Color {
    /// The channels behind a `Color`, for storing one.
    ///
    /// Resolved through `NSColor` in the sRGB space on purpose: a colour picked on a wide-gamut
    /// display carries components outside 0...1, and a hex has to come back out of it. `HintTint`
    /// clamps, so the stored value is the nearest colour sRGB can name.
    var hintTint: HintTint? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return HintTint(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }
}
