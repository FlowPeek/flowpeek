import FlowPeekCore
import SwiftUI

/// The little drawings that show what a switch does, and the pieces they are drawn from.
///
/// Skeletons rather than screenshots: grey bars standing in for text, a rounded rectangle standing
/// in for a window. A screenshot of a terminal invites the reader to read it, which is the opposite
/// of the point -- the mechanic is where the frame appears and when the label arrives, and any real
/// content is noise around that. Skeletons also cost nothing to keep true: they have no language to
/// translate, no theme to match and no diagram that can go out of date.
enum Skeleton {
    /// Everything is drawn from these three weights, so a scene cannot invent its own greys and
    /// drift away from the others.
    static func line(_ level: Double = 0.30) -> Color { .primary.opacity(level) }
    static let accent = Color.accentColor

    static let rowHeight: CGFloat = 5
    static let rowGap: CGFloat = 6
    static let corner: CGFloat = 3
}

/// Plays a script by moving one piece of state at each step, rather than by redrawing every frame.
///
/// A frame-by-frame timeline would have the settings window animating continuously for as long as
/// it is open, once per card. Moving a stage and letting Core Animation interpolate between two
/// pictures costs a handful of transactions a second instead, and gives the easing for free.
///
/// Reduced motion gets the script's resting stage and no loop at all -- one frame that shows the
/// mechanic having happened, which is what the drawing is for.
struct SkeletonPlayer<Stage: Equatable & Sendable, Content: View>: View {
    static var crossfade: TimeInterval { 0.32 }

    let script: SkeletonScript<Stage>
    @ViewBuilder let content: (Stage) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: Stage

    init(
        _ script: SkeletonScript<Stage>,
        initial: Stage,
        @ViewBuilder content: @escaping (Stage) -> Content
    ) {
        self.script = script
        self.content = content
        _stage = State(initialValue: initial)
    }

    var body: some View {
        content(stage).task { await play() }
    }

    private func play() async {
        guard !script.isEmpty else { return }
        guard !reduceMotion else {
            if let resting = script.resting { stage = resting }
            return
        }
        while !Task.isCancelled {
            for step in script.steps {
                withAnimation(.easeInOut(duration: Self.crossfade)) { stage = step.stage }
                do {
                    try await Task.sleep(for: .seconds(step.duration))
                } catch {
                    return
                }
            }
        }
    }
}

// MARK: - Pieces

/// A window, with the traffic lights every reader recognises and nothing else.
struct SkeletonWindow<Content: View>: View {
    var titleBar = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titleBar {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Skeleton.line(0.22)).frame(width: 4, height: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(Skeleton.line(0.06))
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(7)
        }
        .background(Skeleton.line(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Skeleton.line(0.14), lineWidth: 1)
        )
    }
}

/// One row of pretend text. The width is the only thing that varies, which is what makes a stack of
/// them read as prose rather than as a bar chart.
struct SkeletonRow: View {
    let width: Double
    var level: Double = 0.20
    var indent: Double = 0

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: Skeleton.corner, style: .continuous)
                .fill(Skeleton.line(level))
                .frame(width: max(6, geometry.size.width * width), height: Skeleton.rowHeight)
                .offset(x: geometry.size.width * indent)
        }
        .frame(height: Skeleton.rowHeight)
    }
}

/// The pointer. Small, and shaped enough to be read as a cursor at eleven points tall.
struct SkeletonPointer: View {
    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.55))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

/// The diagram that opens: three nodes and the edges between them, which is the least that reads
/// as a diagram rather than as more boxes. Every mechanic ends with one of these, so they all end
/// looking like the same thing happened -- which is the point, because it is.
struct SkeletonDiagram: View {
    /// How far down what the diagram opened over is pushed while it is on screen. Without this the
    /// nodes sat among the rows they had been read out of, and the drawing read as clutter rather
    /// than as a window that had opened on top of something.
    static let backdropOpacity: Double = 0.4

    var body: some View {
        VStack(spacing: 5) {
            node(width: 26)
            edge
            node(width: 32)
            edge
            node(width: 22)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Skeleton.accent.opacity(0.55), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func node(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .strokeBorder(Skeleton.accent.opacity(0.75), lineWidth: 1)
            .frame(width: width, height: 10)
    }

    private var edge: some View {
        Rectangle().fill(Skeleton.accent.opacity(0.5)).frame(width: 1, height: 6)
    }
}

/// A key, drawn as a cap so a held one and a tapped one are the same object in two states.
struct SkeletonKey: View {
    let glyph: String
    var pressed = false

    var body: some View {
        Text(glyph)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(pressed ? .white : .primary.opacity(0.6))
            .frame(width: 18, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(pressed ? Skeleton.accent : Skeleton.line(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(pressed ? .clear : Skeleton.line(0.2), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.92 : 1)
    }
}

/// A chord, drawn as separate caps.
///
/// Two keys rather than one label reading "⌘C": the copy is something the reader does with both
/// hands on the keyboard, and a single cap says it is one key they have not found yet.
struct SkeletonChord: View {
    let glyphs: [String]
    var pressed = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(glyphs, id: \.self) { glyph in
                SkeletonKey(glyph: glyph, pressed: pressed)
            }
        }
    }
}

/// The badge the clipboard watch slides in under the menu bar.
struct SkeletonBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.white.opacity(0.9))
                .frame(width: 14, height: 3)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.white.opacity(0.35))
                .frame(width: 12, height: 7)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(Skeleton.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The label FlowPeek puts on a frame, at the size these drawings work at.
struct SkeletonLabel: View {
    var body: some View {
        HStack(spacing: 2) {
            Circle().fill(.white.opacity(0.9)).frame(width: 3, height: 3)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.white.opacity(0.9))
                .frame(width: 18, height: 3)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Skeleton.accent, in: Capsule())
    }
}

// MARK: - Watch the terminal

/// What the terminal watch does, in four beats: output arrives, a diagram in it gets a faint frame,
/// the pointer comes near and the frame brightens with its label, and the diagram opens.
enum TerminalWatchStage: Equatable, Sendable {
    case printing
    case framed
    case approached
    case opened
}

struct TerminalWatchScene: View {
    static let script = SkeletonScript<TerminalWatchStage>(
        [
            .init(.printing, 1.1),
            .init(.framed, 1.5),
            .init(.approached, 1.6),
            .init(.opened, 1.8),
        ],
        resting: .approached
    )

    /// Which rows the diagram occupies. Two rows of output above it and two below, so the frame is
    /// visibly around part of the screen rather than around all of it.
    private static let block = 2...4
    private static let rows: [Double] = [0.55, 0.34, 0.30, 0.62, 0.46, 0.40, 0.24]

    var body: some View {
        SkeletonPlayer(Self.script, initial: .printing) { stage in
            SkeletonWindow {
                ZStack(alignment: .topLeading) {
                    Group {
                        rows(upTo: stage == .printing ? 5 : Self.rows.count)
                        if stage != .printing { frame(stage) }
                        if stage == .approached || stage == .opened { pointer }
                    }
                    .opacity(stage == .opened ? SkeletonDiagram.backdropOpacity : 1)
                    if stage == .opened { SkeletonDiagram() }
                }
            }
            .frame(width: 168, height: 104)
        }
        .accessibilityHidden(true)
    }

    private func rows(upTo count: Int) -> some View {
        VStack(alignment: .leading, spacing: Skeleton.rowGap) {
            ForEach(Self.rows.indices, id: \.self) { index in
                SkeletonRow(
                    width: index < count ? Self.rows[index] : 0,
                    level: Self.block.contains(index) ? 0.32 : 0.18,
                    indent: Self.block.contains(index) && index != Self.block.lowerBound ? 0.08 : 0
                )
                .opacity(index < count ? 1 : 0)
            }
        }
    }

    /// The frame, over exactly the rows the diagram occupies. Its geometry is worked out from the
    /// same row height and gap the rows are laid out with, so the two cannot drift apart.
    private func frame(_ stage: TerminalWatchStage) -> some View {
        let pitch = Skeleton.rowHeight + Skeleton.rowGap
        let top = CGFloat(Self.block.lowerBound) * pitch - 3
        let height = CGFloat(Self.block.count) * Skeleton.rowHeight
            + CGFloat(Self.block.count - 1) * Skeleton.rowGap + 6
        let loud = stage != .framed
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Skeleton.accent.opacity(loud ? 0.9 : 0.42), lineWidth: loud ? 1.5 : 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Skeleton.accent.opacity(loud ? 0.10 : 0))
            )
            .frame(height: height)
            .overlay(alignment: .topTrailing) {
                if loud { SkeletonLabel().padding(2) }
            }
            .offset(y: top)
    }

    private var pointer: some View {
        SkeletonPointer()
            .offset(x: 62, y: 42)
    }

}

// MARK: - Watch the clipboard

/// What the clipboard watch does: a diagram is copied out of an app whose text FlowPeek cannot
/// read, a badge arrives under the menu bar naming the key, and the key opens it.
enum ClipboardWatchStage: Equatable, Sendable {
    case idle
    case selected
    case copied
    case badged
    case opened
}

struct ClipboardWatchScene: View {
    static let script = SkeletonScript<ClipboardWatchStage>(
        [
            .init(.idle, 0.8),
            .init(.selected, 0.9),
            // Short, because a keypress is short. Long enough to be read as a press rather than as
            // the keys simply being there.
            .init(.copied, 0.45),
            .init(.badged, 1.5),
            .init(.opened, 1.6),
        ],
        resting: .badged
    )

    private static let rows: [Double] = [0.5, 0.66, 0.42, 0.58, 0.30]
    private static let selected = 1...3

    var body: some View {
        SkeletonPlayer(Self.script, initial: .idle) { stage in
            SkeletonWindow {
                ZStack(alignment: .topTrailing) {
                    Group {
                        VStack(alignment: .leading, spacing: Skeleton.rowGap) {
                            ForEach(Self.rows.indices, id: \.self) { index in
                                SkeletonRow(
                                    width: Self.rows[index],
                                    level: highlighted(stage, index) ? 0.44 : 0.18
                                )
                                .background(alignment: .leading) {
                                    if highlighted(stage, index) {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(Skeleton.accent.opacity(0.22))
                                            .frame(width: 120, height: 9)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if stage == .badged { SkeletonBadge() }
                    }
                    .opacity(stage == .opened ? SkeletonDiagram.backdropOpacity : 1)
                    if stage == .opened { SkeletonDiagram() }
                    // Bottom right, where hold to peek keeps its own key: across the four drawings
                    // that corner always means "the keyboard's part in this".
                    SkeletonChord(glyphs: ["⌘", "C"], pressed: stage == .copied)
                        .opacity(stage == .idle ? 0.55 : 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 168, height: 104)
        }
        .accessibilityHidden(true)
    }

    /// Selected while it is being selected and while it is being copied. The selection survives a
    /// copy in every app there is, but the badge is what the next beat is about, and two things
    /// lit at once would split the reader's attention between them.
    private func highlighted(_ stage: ClipboardWatchStage, _ index: Int) -> Bool {
        (stage == .selected || stage == .copied) && Self.selected.contains(index)
    }
}

// MARK: - Hold to peek

/// What hold to peek does: the key goes down, the pointer arrives on a block, the block is framed,
/// and the chord opens it.
enum HoldToPeekStage: Equatable, Sendable {
    case idle
    case holding
    case framed
    case opened
}

struct HoldToPeekScene: View {
    static let script = SkeletonScript<HoldToPeekStage>(
        [
            .init(.idle, 0.8),
            .init(.holding, 1.0),
            .init(.framed, 1.6),
            .init(.opened, 1.6),
        ],
        resting: .framed
    )

    private static let rows: [Double] = [0.46, 0.62, 0.34, 0.28, 0.52, 0.38]
    private static let block = 2...3

    var body: some View {
        SkeletonPlayer(Self.script, initial: .idle) { stage in
            SkeletonWindow {
                ZStack(alignment: .topLeading) {
                    Group {
                        VStack(alignment: .leading, spacing: Skeleton.rowGap) {
                            ForEach(Self.rows.indices, id: \.self) { index in
                                SkeletonRow(
                                    width: Self.rows[index],
                                    level: Self.block.contains(index) ? 0.30 : 0.18,
                                    indent: Self.block.contains(index) ? 0.06 : 0
                                )
                            }
                        }
                        if stage != .idle {
                            frame(framed: stage != .holding)
                            SkeletonPointer().offset(x: 52, y: 30)
                        }
                    }
                    .opacity(stage == .opened ? SkeletonDiagram.backdropOpacity : 1)
                    if stage == .opened { SkeletonDiagram() }
                    // The key stays at full strength through the whole loop: it is the thing being
                    // held, and dimming it while the diagram opens would say it had been let go.
                    SkeletonKey(glyph: "⌥", pressed: stage != .idle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 168, height: 104)
        }
        .accessibilityHidden(true)
    }

    private func frame(framed: Bool) -> some View {
        let pitch = Skeleton.rowHeight + Skeleton.rowGap
        let top = CGFloat(Self.block.lowerBound) * pitch - 3
        let height = CGFloat(Self.block.count) * Skeleton.rowHeight
            + CGFloat(Self.block.count - 1) * Skeleton.rowGap + 6
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Skeleton.accent.opacity(framed ? 0.9 : 0.3), lineWidth: framed ? 1.5 : 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Skeleton.accent.opacity(framed ? 0.10 : 0))
            )
            .frame(height: height)
            .overlay(alignment: .topTrailing) {
                if framed { SkeletonLabel().padding(2) }
            }
            .offset(y: top)
    }
}

// MARK: - Press Option twice

/// What the gesture does: two taps on a key that is otherwise doing nothing, and the diagram on the
/// clipboard opens. The gap between the taps is the setting beside it, so the drawing shows two
/// distinct presses rather than one long one.
enum DoubleTapStage: Equatable, Sendable {
    case idle
    case first
    case between
    case second
    case opened
}

struct DoubleTapScene: View {
    static let script = SkeletonScript<DoubleTapStage>(
        [
            .init(.idle, 0.9),
            .init(.first, 0.28),
            .init(.between, 0.24),
            .init(.second, 0.28),
            .init(.opened, 1.7),
        ],
        resting: .opened
    )

    var body: some View {
        SkeletonPlayer(Self.script, initial: .idle) { stage in
            SkeletonWindow(titleBar: false) {
                ZStack {
                    VStack(spacing: 9) {
                        SkeletonKey(glyph: "⌥", pressed: stage == .first || stage == .second)
                            .scaleEffect(stage == .first || stage == .second ? 1.12 : 1)
                        HStack(spacing: 4) {
                            ForEach(0..<2, id: \.self) { index in
                                Circle()
                                    .fill(Skeleton.accent.opacity(taps(stage) > index ? 0.9 : 0.18))
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(stage == .opened ? SkeletonDiagram.backdropOpacity : 1)

                    if stage == .opened { SkeletonDiagram() }
                }
            }
            .frame(width: 168, height: 104)
        }
        .accessibilityHidden(true)
    }

    private func taps(_ stage: DoubleTapStage) -> Int {
        switch stage {
        case .idle: 0
        case .first, .between: 1
        case .second, .opened: 2
        }
    }
}
