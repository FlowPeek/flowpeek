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

    static let rowHeight: CGFloat = 5
    static let rowGap: CGFloat = 6
    static let corner: CGFloat = 3

    /// Three sizes, because the same drawing has to work in three places. A settings card has a
    /// column of text beside it, an onboarding step has the middle of a window, and a checklist row
    /// has whatever is left after the badge and the instructions. The pieces are drawn at fixed
    /// sizes rather than scaled, so a five-point row is five points everywhere and the drawings
    /// stay recognisably the same object.
    static let cardSize = CGSize(width: 168, height: 104)
    static let stepSize = CGSize(width: 268, height: 150)
    static let rowSize = CGSize(width: 196, height: 116)
}

private struct SkeletonTintKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    /// The colour the drawings use for anything that stands for FlowPeek's own hint box.
    ///
    /// An environment value rather than a constant, because these drawings exist to show the user
    /// what the hint looks like -- and once the colour is theirs to choose, a drawing in the accent
    /// would be illustrating somebody else's app. Injected once where the drawings are hosted, so a
    /// scene never has to know where the colour came from.
    var skeletonTint: Color {
        get { self[SkeletonTintKey.self] }
        set { self[SkeletonTintKey.self] = newValue }
    }
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
    @Environment(\.skeletonTint) private var skeletonTint
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
                .strokeBorder(skeletonTint.opacity(0.55), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func node(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .strokeBorder(skeletonTint.opacity(0.75), lineWidth: 1)
            .frame(width: width, height: 10)
    }

    private var edge: some View {
        Rectangle().fill(skeletonTint.opacity(0.5)).frame(width: 1, height: 6)
    }
}

/// A key, drawn as a cap so a held one and a tapped one are the same object in two states.
struct SkeletonKey: View {
    @Environment(\.skeletonTint) private var skeletonTint
    let glyph: String
    var pressed = false

    var body: some View {
        Text(glyph)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(pressed ? .white : .primary.opacity(0.6))
            .frame(width: 18, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(pressed ? skeletonTint : Skeleton.line(0.12))
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
    @Environment(\.skeletonTint) private var skeletonTint
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
        .background(skeletonTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The label FlowPeek puts on a frame, at the size these drawings work at.
struct SkeletonLabel: View {
    @Environment(\.skeletonTint) private var skeletonTint
    var body: some View {
        HStack(spacing: 2) {
            Circle().fill(.white.opacity(0.9)).frame(width: 3, height: 3)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.white.opacity(0.9))
                .frame(width: 18, height: 3)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(skeletonTint, in: Capsule())
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
    @Environment(\.skeletonTint) private var skeletonTint
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

    var size: CGSize = Skeleton.cardSize

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
            .frame(width: size.width, height: size.height)
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
            .strokeBorder(skeletonTint.opacity(loud ? 0.9 : 0.42), lineWidth: loud ? 1.5 : 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(skeletonTint.opacity(loud ? 0.10 : 0))
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
    @Environment(\.skeletonTint) private var skeletonTint
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

    var size: CGSize = Skeleton.cardSize

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
                                            .fill(skeletonTint.opacity(0.22))
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
            .frame(width: size.width, height: size.height)
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
    @Environment(\.skeletonTint) private var skeletonTint
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

    var size: CGSize = Skeleton.cardSize

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
            .frame(width: size.width, height: size.height)
        }
        .accessibilityHidden(true)
    }

    private func frame(framed: Bool) -> some View {
        let pitch = Skeleton.rowHeight + Skeleton.rowGap
        let top = CGFloat(Self.block.lowerBound) * pitch - 3
        let height = CGFloat(Self.block.count) * Skeleton.rowHeight
            + CGFloat(Self.block.count - 1) * Skeleton.rowGap + 6
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(skeletonTint.opacity(framed ? 0.9 : 0.3), lineWidth: framed ? 1.5 : 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(skeletonTint.opacity(framed ? 0.10 : 0))
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
    @Environment(\.skeletonTint) private var skeletonTint
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

    var size: CGSize = Skeleton.cardSize

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
                                    .fill(skeletonTint.opacity(taps(stage) > index ? 0.9 : 0.18))
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(stage == .opened ? SkeletonDiagram.backdropOpacity : 1)

                    if stage == .opened { SkeletonDiagram() }
                }
            }
            .frame(width: size.width, height: size.height)
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

// MARK: - Select it

/// What the drag route does: text is selected, a small button appears at the end of the selection,
/// and pressing it draws.
enum SelectionStage: Equatable, Sendable {
    case idle
    case dragging
    case offered
    case opened
}

struct SelectionScene: View {
    @Environment(\.skeletonTint) private var skeletonTint
    static let script = SkeletonScript<SelectionStage>(
        [
            .init(.idle, 0.7),
            .init(.dragging, 0.9),
            .init(.offered, 1.5),
            .init(.opened, 1.6),
        ],
        resting: .offered
    )

    private static let rows: [Double] = [0.44, 0.60, 0.36, 0.30, 0.50]
    private static let block = 1...3

    var size: CGSize = Skeleton.cardSize

    var body: some View {
        SkeletonPlayer(Self.script, initial: .idle) { stage in
            SkeletonWindow {
                ZStack(alignment: .topLeading) {
                    Group {
                        VStack(alignment: .leading, spacing: Skeleton.rowGap) {
                            ForEach(Self.rows.indices, id: \.self) { index in
                                SkeletonRow(
                                    width: Self.rows[index],
                                    level: selected(stage, index) ? 0.44 : 0.18
                                )
                                .background(alignment: .leading) {
                                    if selected(stage, index) {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(skeletonTint.opacity(0.22))
                                            .frame(width: 110, height: 9)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if stage != .idle {
                            // At the end of the selection, which is where the real button goes.
                            button(offered: stage != .dragging)
                                .offset(x: 104, y: CGFloat(Self.block.upperBound) * pitch - 4)
                        }
                    }
                    .opacity(stage == .opened ? SkeletonDiagram.backdropOpacity : 1)
                    if stage == .opened { SkeletonDiagram() }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityHidden(true)
    }

    private var pitch: CGFloat { Skeleton.rowHeight + Skeleton.rowGap }

    private func selected(_ stage: SelectionStage, _ index: Int) -> Bool {
        stage != .idle && Self.block.contains(index)
    }

    /// The pointer holds the drag; the button arrives beside it a beat later.
    private func button(offered: Bool) -> some View {
        HStack(spacing: 3) {
            SkeletonPointer()
            if offered {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(skeletonTint)
                    .frame(width: 16, height: 13)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }
}

// MARK: - The permission

/// What the permission step asks for, and where. The list is System Settings; the tick is the one
/// the user has to make; the frame afterwards is FlowPeek able to do its job.
enum PermissionStage: Equatable, Sendable {
    case listed
    case ticked
    case working
}

struct PermissionScene: View {
    @Environment(\.skeletonTint) private var skeletonTint
    static let script = SkeletonScript<PermissionStage>(
        [
            .init(.listed, 1.1),
            .init(.ticked, 1.4),
            .init(.working, 1.7),
        ],
        resting: .working
    )

    var size: CGSize = Skeleton.cardSize

    var body: some View {
        SkeletonPlayer(Self.script, initial: .listed) { stage in
            SkeletonWindow {
                if stage == .working {
                    working
                } else {
                    list(ticked: stage == .ticked)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityHidden(true)
    }

    /// Three rows with a switch each, the middle one FlowPeek's. Nothing names it, because a
    /// skeleton that spelled out "FlowPeek" would be a screenshot with the pixels removed.
    private func list(ticked: Bool) -> some View {
        VStack(spacing: Skeleton.rowGap + 2) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Skeleton.line(index == 1 ? 0.34 : 0.16))
                        .frame(width: index == 1 ? 46 : 34, height: Skeleton.rowHeight)
                    Spacer(minLength: 0)
                    toggle(on: index == 1 && ticked)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            SkeletonPointer().offset(x: 4, y: 8)
        }
    }

    private func toggle(on: Bool) -> some View {
        Capsule()
            .fill(on ? skeletonTint : Skeleton.line(0.16))
            .frame(width: 18, height: 10)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white.opacity(on ? 0.95 : 0.6))
                    .frame(width: 8, height: 8)
                    .padding(1)
            }
    }

    /// The grant having landed: a block of text with FlowPeek's frame around it.
    private var working: some View {
        VStack(alignment: .leading, spacing: Skeleton.rowGap) {
            ForEach(0..<4, id: \.self) { index in
                SkeletonRow(width: [0.5, 0.34, 0.28, 0.44][index], level: index == 1 || index == 2 ? 0.3 : 0.18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(skeletonTint.opacity(0.9), lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(skeletonTint.opacity(0.10))
                )
                .frame(height: 2 * Skeleton.rowHeight + Skeleton.rowGap + 6)
                .overlay(alignment: .topTrailing) { SkeletonLabel().padding(2) }
                .offset(y: CGFloat(Skeleton.rowHeight + Skeleton.rowGap) - 3)
                .transition(.opacity)
        }
    }
}

// MARK: - Launch at login

/// What the login switch buys: the menu bar already has FlowPeek in it when the Mac comes back.
enum LaunchStage: Equatable, Sendable {
    case bare
    case arriving
    case ready
}

struct LaunchScene: View {
    @Environment(\.skeletonTint) private var skeletonTint
    static let script = SkeletonScript<LaunchStage>(
        [
            .init(.bare, 1.0),
            .init(.arriving, 0.6),
            .init(.ready, 1.8),
        ],
        resting: .ready
    )

    var size: CGSize = Skeleton.cardSize

    var body: some View {
        SkeletonPlayer(Self.script, initial: .bare) { stage in
            VStack(spacing: 0) {
                menuBar(stage)
                // A screen under the bar, so the bar reads as the top of one. Without it the strip
                // floated over a hundred and thirty points of nothing, which said "empty" where
                // the card is saying "already there".
                desktop(stage)
            }
            .frame(width: size.width, height: size.height)
            .background(Skeleton.line(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Skeleton.line(0.14), lineWidth: 1)
            )
        }
        .accessibilityHidden(true)
    }

    /// Two windows the user was already working in. Dim, and dimmer before the mark arrives: the
    /// beat this card is about is the Mac coming back, and nothing else on screen is the subject.
    private func desktop(_ stage: LaunchStage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            window(rows: [0.7, 0.5, 0.6, 0.4])
            window(rows: [0.5, 0.65, 0.45])
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(stage == .bare ? 0.5 : 1)
    }

    private func window(rows: [Double]) -> some View {
        VStack(alignment: .leading, spacing: Skeleton.rowGap) {
            ForEach(rows.indices, id: \.self) { index in
                SkeletonRow(width: rows[index], level: 0.13)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Skeleton.line(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Skeleton.line(0.1), lineWidth: 1)
        )
    }

    /// The bar is drawn as the real one is read: the app's own mark at the right-hand end, among
    /// the other status items.
    private func menuBar(_ stage: LaunchStage) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Skeleton.line(0.2))
                .frame(width: 8, height: 4)
            Spacer(minLength: 0)
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Skeleton.line(0.16))
                    .frame(width: 7, height: 4)
            }
            if stage != .bare {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(skeletonTint)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 15)
        .background(Skeleton.line(0.08))
    }
}

// MARK: - Welcome

/// The three ways in, one after another over the same block: a selection with its button, a copy
/// with its badge, and the pointer with its frame. The welcome card promises three, so it shows
/// three rather than picking a favourite.
enum WelcomeStage: Equatable, Sendable {
    case select
    case copy
    case point
}

struct WelcomeScene: View {
    @Environment(\.skeletonTint) private var skeletonTint
    static let script = SkeletonScript<WelcomeStage>(
        [
            .init(.select, 1.5),
            .init(.copy, 1.5),
            .init(.point, 1.5),
        ],
        resting: .point
    )

    private static let rows: [Double] = [0.46, 0.62, 0.34, 0.28, 0.50, 0.38]
    private static let block = 1...3
    private static let selectionWidth: CGFloat = 110

    var size: CGSize = Skeleton.cardSize

    var body: some View {
        SkeletonPlayer(Self.script, initial: .select) { stage in
            SkeletonWindow {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: Skeleton.rowGap) {
                        ForEach(Self.rows.indices, id: \.self) { index in
                            SkeletonRow(
                                width: Self.rows[index],
                                level: Self.block.contains(index) ? 0.34 : 0.18
                            )
                            .background(alignment: .leading) {
                                if stage == .select, Self.block.contains(index) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(skeletonTint.opacity(0.22))
                                        .frame(width: 110, height: 9)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    switch stage {
                    case .select:
                        // At the end of the selection, which is where the real button appears --
                        // the highlight behind the rows is a fixed width, so this is the same
                        // number rather than a guess about it.
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(skeletonTint)
                            .frame(width: 16, height: 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(x: Self.selectionWidth + 4, y: CGFloat(Self.block.upperBound) * pitch)
                    case .copy:
                        SkeletonBadge()
                    case .point:
                        frame
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityHidden(true)
    }

    private var pitch: CGFloat { Skeleton.rowHeight + Skeleton.rowGap }

    private var frame: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(skeletonTint.opacity(0.9), lineWidth: 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(skeletonTint.opacity(0.10))
            )
            .frame(height: CGFloat(Self.block.count) * Skeleton.rowHeight
                + CGFloat(Self.block.count - 1) * Skeleton.rowGap + 6)
            .overlay(alignment: .topLeading) {
                SkeletonPointer().offset(x: 40, y: 12)
            }
            .offset(y: CGFloat(Self.block.lowerBound) * pitch - 3)
            .transition(.opacity)
    }
}


// MARK: - Where the app lives

/// The last card's drawing: the mark in the menu bar, and the menu it opens.
///
/// A menu-bar app has no window to come back to, so the answer to "where did it go" is a place on
/// screen rather than a sentence. The drawing points at that place and then opens what is there,
/// because the menu is not only how the app is found -- it is where everything about it is changed.
enum MenuBarStage: Equatable, Sendable {
    case mark
    case opened
    case configuring
}

struct MenuBarScene: View {
    @Environment(\.skeletonTint) private var skeletonTint
    static let script = SkeletonScript<MenuBarStage>(
        [
            .init(.mark, 1.2),
            .init(.opened, 1.3),
            .init(.configuring, 1.7),
        ],
        resting: .opened
    )

    var size: CGSize = Skeleton.cardSize

    var body: some View {
        SkeletonPlayer(Self.script, initial: .mark) { stage in
            VStack(spacing: 0) {
                menuBar(highlighted: stage != .mark)
                if stage != .mark {
                    menu(configuring: stage == .configuring)
                        .padding(.trailing, 10)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height)
            .background(Skeleton.line(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Skeleton.line(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .accessibilityHidden(true)
    }

    private func menuBar(highlighted: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Skeleton.line(0.2))
                .frame(width: 8, height: 4)
            Spacer(minLength: 0)
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Skeleton.line(0.16))
                    .frame(width: 7, height: 4)
            }
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(skeletonTint)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(skeletonTint.opacity(highlighted ? 0.22 : 0))
                )
        }
        .padding(.horizontal, 7)
        .frame(height: 16)
        .background(Skeleton.line(0.08))
    }

    /// The menu itself: a few rows and a switch, because what the card is saying is not "here is an
    /// icon" but "everything is set from here". The switch moving is the whole claim.
    private func menu(configuring: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Skeleton.line(index == 1 && configuring ? 0.4 : 0.2))
                        .frame(width: [34, 42, 28, 38][index], height: Skeleton.rowHeight)
                    Spacer(minLength: 0)
                    if index == 1 {
                        // Outlined even when off. Unoutlined at nine points the capsule was the
                        // same grey as the row behind it and all that read was the knob, which
                        // looks like a bullet rather than a switch.
                        Capsule()
                            .fill(configuring ? skeletonTint : Skeleton.line(0.14))
                            .frame(width: 18, height: 10)
                            .overlay(Capsule().strokeBorder(Skeleton.line(0.22), lineWidth: 0.5))
                            .overlay(alignment: configuring ? .trailing : .leading) {
                                Circle()
                                    .fill(.white.opacity(configuring ? 0.95 : 0.7))
                                    .frame(width: 8, height: 8)
                                    .padding(1)
                            }
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 104)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Skeleton.line(0.18), lineWidth: 1)
        )
    }
}
