import AppKit
import FlowPeekCore
import SwiftUI

/// The outline that sits over a detected block, plus a small hint naming the key that opens it.
/// Click-through everywhere except the hint, so holding the modifier never blocks the app underneath.
@MainActor
final class AmbientHighlightCoordinator {
    var onActivate: (() -> Void)?

    /// What colour to draw the frame and the chip in. Set from settings and pushed straight at the
    /// model, so a change lands on an outline that is already on screen.
    var tint: HintTintChoice {
        get { model.tint }
        set { model.tint = newValue }
    }

    /// How far the stroke sits outside the block, so it frames the text instead of touching it.
    private static let inset: CGFloat = 5
    private static let hintBarHeight: CGFloat = 20
    private static let gap: CGFloat = 4
    private static let fade: TimeInterval = 0.14

    private var panel: NSPanel?
    private var model = AmbientHighlightModel()
    /// The outline currently on screen, in AppKit coordinates. Held so the pointer can be measured
    /// against it without re-reading anything.
    private var outline: CGRect?
    private var pointerMonitor: Any?
    private var flagsMonitor: Any?
    /// Where the pointer is, reported by the panel itself while the pointer is over it. A global
    /// monitor never sees those moves, because they are delivered to FlowPeek.
    var onPointerOverPanel: ((CGPoint) -> Void)?

    /// Whether this coordinator watches the pointer and the modifier itself.
    ///
    /// False for one of several frames drawn at once: a terminal showing three diagrams gets three
    /// panels, and three copies of the same two global monitors would each answer the same question
    /// about the same pointer. `TerminalOutlineCoordinator` keeps one pair and tells each frame
    /// what it found.
    private let tracksPointer: Bool

    init(tracksPointer: Bool = true) {
        self.tracksPointer = tracksPointer
    }

    /// Hold this and a quiet outline becomes the button: click the block itself rather than
    /// aiming at the pill. The same key the pointer route uses, so "hold Option and FlowPeek shows
    /// you what it can open" means one thing across the app.
    ///
    /// The frame is all the feedback there is, and it has to be: the pointer cannot be changed to
    /// a hand. FlowPeek is a menu-bar app whose frame is a non-activating panel, and the cursor
    /// over another application's window belongs to that application -- measured against iTerm2
    /// and Ghostty with a cursor rectangle on a container view, a cursor rectangle on the hosting
    /// view itself, and `NSCursor.push` from a hover, all three of which left the terminal's own
    /// Option-held I-beam in place. So the frame brightens and fills, and the label says which
    /// key, because that is what a background app can say.
    private static let armingModifier: NSEvent.ModifierFlags = .option
    /// Compared against these alone: caps lock, the function flag and the numeric-pad flag ride
    /// along on real events and would break an equality test against the whole mask.
    private static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// What a quiet outline's label says to do with it.
    ///
    /// Composed here rather than written out in the catalogues: the glyph belongs to the code that
    /// decides which modifier arms the frame, and a translator should not have to keep a keyboard
    /// symbol in step with it.
    static var armedChip: String { "⌥ " + String(localized: "terminal.hint.click") }

    /// How loudly the outline announces itself.
    enum Style {
        /// The pointer route. The frame and its button appear together: the user is holding a key
        /// down and is owed an immediate answer about what it will open.
        case declared
        /// The terminal route. The frame appears on its own and stays faint, and the button only
        /// when the pointer comes near it.
        ///
        /// Nothing asked for this outline -- it is drawn over text the user is reading, possibly
        /// for minutes at a time, and a filled frame with a label above it was covering the line
        /// above the block. So at rest it is a thin line and nothing else, the button lives inside
        /// the frame where there is no text to cover, and it is revealed on approach.
        case quiet
    }

    /// Places the frame, and reports whether there was anything drawable to place it around.
    @discardableResult
    func show(_ candidate: AmbientCandidate, chip: String, style: Style = .declared) -> Bool {
        // A block scrolled half past the bottom of the display, or simply taller than it, is clipped
        // to what is on screen. Moving the panel instead — which is what keeping a whole window
        // visible would do — drew the frame around unrelated text further up the page.
        guard let outline = ScreenGeometry.clip(
            candidate.bounds.insetBy(dx: -Self.inset, dy: -Self.inset),
            screenFrames: NSScreen.screens.map(\.frame)
        ), outline.width >= AmbientPeekPolicy.minimumSize.width,
              outline.height >= AmbientPeekPolicy.minimumSize.height else {
            hide()
            return false
        }

        model.keyword = candidate.detection.diagramKeyword
        model.chip = chip
        model.anchor = candidate.anchor
        model.style = style

        // A quiet outline carries its button inside itself, so it needs no room above or below.
        let chrome = style == .quiet ? 0 : Self.hintBarHeight + Self.gap
        let panel = panel ?? makePanel()

        // AppKit's y grows upward while a VStack lays its first child out at the top, so the panel
        // has to extend *above* the block and the outline row has to be exactly the block's height.
        // Extending below instead pushed the outline down by the height of the hint.
        let placement = style == .quiet ? .inside : self.placement(for: outline, chrome: chrome)
        model.placement = placement
        model.outlineHeight = outline.height

        // Whatever the hint does, the outline row keeps the block's own rectangle: the panel grows
        // away from it, never over it.
        let origin: CGPoint
        let size: CGSize
        switch placement {
        case .above:
            origin = outline.origin
            size = CGSize(width: outline.width, height: outline.height + chrome)
        case .below:
            origin = CGPoint(x: outline.minX, y: outline.minY - chrome)
            size = CGSize(width: outline.width, height: outline.height + chrome)
        case .inside:
            origin = outline.origin
            size = outline.size
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: false)

        self.outline = outline
        switch style {
        case .declared:
            stopTrackingPointer()
            model.isRevealed = true
        case .quiet:
            guard tracksPointer else { break }
            startTrackingPointer()
            // Evaluated from the live state rather than waiting for an event: a block that appears
            // under a pointer already sitting on it, or while Option is already down, should
            // arrive ready rather than on the next twitch.
            updateReveal(NSEvent.mouseLocation)
            setArmed(Self.isArming(NSEvent.modifierFlags))
        }

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 1
        }
        return true
    }

    // MARK: - Driven from outside

    /// The rectangle this frame is drawn around, for a coordinator measuring the pointer against
    /// several of them at once.
    var outlineRect: CGRect? { outline }

    /// Told, rather than worked out, when this frame is one of several.
    func setRevealed(_ revealed: Bool) {
        guard !tracksPointer, model.style == .quiet, model.isRevealed != revealed else { return }
        model.isRevealed = revealed
    }

    func setArmedExternally(_ armed: Bool) {
        guard !tracksPointer else { return }
        setArmed(armed)
    }

    static func isArmingModifier(_ flags: NSEvent.ModifierFlags) -> Bool { isArming(flags) }

    func hide() {
        stopTrackingPointer()
        outline = nil
        model.isRevealed = false
        model.isArmed = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            // AppKit runs this on the main thread; saying so is what lets the panel be touched
            // from a closure the compiler sees as nonisolated.
            MainActor.assumeIsolated { panel?.orderOut(nil) }
        }
    }

    // MARK: - Approach

    /// The pointer is watched globally rather than with a tracking area, because the panel is over
    /// somebody else's window: at rest nothing in it is hit-testable, so it is never told that the
    /// pointer arrived. A global monitor is also blind to the moment the pointer crosses onto the
    /// button itself -- which needs no handling, because the button lives inside the frame, so the
    /// last position the monitor did see was already inside it.
    private func startTrackingPointer() {
        if pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] _ in
                Task { @MainActor in self?.updateReveal(NSEvent.mouseLocation) }
            }
        }
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let armed = Self.isArming(event.modifierFlags)
            Task { @MainActor in self?.setArmed(armed) }
        }
    }

    private func stopTrackingPointer() {
        [pointerMonitor, flagsMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        pointerMonitor = nil
        flagsMonitor = nil
    }

    private static func isArming(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(significantModifiers) == armingModifier
    }

    private func updateReveal(_ pointer: CGPoint) {
        guard model.style == .quiet, let outline else { return }
        let revealed = TerminalPeekPolicy.revealsButton(pointer: pointer, outline: outline)
        guard revealed != model.isRevealed else { return }
        model.isRevealed = revealed
    }

    /// The modifier went down or came up. While it is down the whole frame takes clicks, so this is
    /// also the moment the outline stops being decoration -- and the moment it has to look like it.
    private func setArmed(_ armed: Bool) {
        guard model.style == .quiet, model.isArmed != armed else { return }
        model.isArmed = armed
    }

    /// Where the hint can go without displacing the outline. A block that fills the display's height
    /// leaves room for neither bar, so the last case puts the hint inside the frame rather than
    /// letting it push the outline off the text.
    private func placement(for outline: CGRect, chrome: CGFloat) -> AmbientHighlightModel.Placement {
        guard let screen = ScreenGeometry.visibleFrame(
            containing: CGPoint(x: outline.midX, y: outline.midY),
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        ) else { return .above }
        if outline.maxY + chrome <= screen.maxY { return .above }
        if outline.minY - chrome >= screen.minY { return .below }
        return .inside
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Mouse-moved events have to be delivered for the tracking area below to report anything.
        panel.acceptsMouseMovedEvents = true
        let hosting = NSHostingView(
            rootView: AmbientHighlightView(
                model: model,
                hintBarHeight: Self.hintBarHeight,
                gap: Self.gap,
                activate: { [weak self] in
                    self?.hide()
                    self?.onActivate?()
                }
            )
        )
        let container = PointerReportingView()
        container.onPointer = { [weak self] point in self?.onPointerOverPanel?(point) }
        container.addSubview(hosting)
        // Constraints rather than an autoresizing mask: the container starts at zero size, and
        // proportional resizing from zero is undefined -- the hosting view never grows with it.
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        self.panel = panel
        return panel
    }
}

@MainActor
final class AmbientHighlightModel: ObservableObject {
    /// Where the hint sits relative to the outline. `inside` is for a block that reaches both edges
    /// of the display: there is nowhere to put a bar without moving the frame off the text.
    enum Placement {
        case above
        case below
        case inside
    }

    @Published var keyword: String?
    /// The word or chord in the pill at the end of the hint: the chord that opens the outlined
    /// diagram where one is registered, and the name of the action where the outline was raised by
    /// the terminal watch and there is nothing to press.
    @Published var chip = ""
    @Published var outlineHeight: CGFloat = 0
    @Published var placement: Placement = .above
    /// What the frame is actually around. A caret-anchored read frames the line or the pane the
    /// caret is in, never the block, so the hint says where the diagram came from instead of
    /// letting the outline claim to be drawn around it.
    @Published var anchor: AmbientCandidate.Anchor = .pointer
    @Published var style: AmbientHighlightCoordinator.Style = .declared
    /// Whether the button is on screen. Always true for a declared outline; for a quiet one it
    /// follows the pointer.
    @Published var isRevealed = true
    /// Whether the modifier that turns the whole frame into the button is down.
    @Published var isArmed = false
    /// What colour to draw in. On the model rather than read from `AppState` where it is used,
    /// because these views are hosted in a panel of their own and a settings change has to reach
    /// them the same way every other change does.
    @Published var tint: HintTintChoice = .systemAccent
}

extension HintTintChoice {
    /// The colour to draw with. `.systemAccent` resolves to `Color.accentColor` here rather than
    /// being stored as a colour, so it keeps following the accent when the user changes it.
    var color: Color {
        switch self {
        case .systemAccent: .accentColor
        case .fixed(let tint): Color(red: tint.red, green: tint.green, blue: tint.blue)
        }
    }
}

/// A slow breath, for a frame that sits over somebody else's text without being asked.
///
/// A line at a fixed faint opacity either disappears into the terminal's own colours or does not,
/// depending on the theme and on what is behind it. Moving between two faint values instead is what
/// makes it findable without making it loud: the eye catches the change rather than the line.
///
/// Deliberately slow -- almost three seconds for the whole cycle -- and shallow. A quick or a deep
/// pulse reads as an alert about something that needs attention, and this needs none: it is an
/// offer, and it may be on screen for as long as the diagram is.
///
/// One layer's opacity, animated by Core Animation rather than redrawn by SwiftUI, and it stops
/// when the pointer arrives or the outline goes.
/// Reports the pointer while it is over the panel, which a global monitor cannot.
///
/// A global mouse monitor is blind to events delivered to FlowPeek itself, and a panel takes those
/// the moment the pointer is over it -- even with nothing inside it hit-testable, which is how the
/// frame stays click-through. With one frame that did not matter: being over the panel meant being
/// over the block, which is the answer the frame already had. With several it does, because moving
/// from one frame to the next crosses nothing but FlowPeek's own windows -- so nothing was reported
/// and the frame the pointer had left kept its label.
///
/// A tracking area rather than a hover handler, because it does not need the view to take hits, and
/// `.activeAlways` is what makes it report for an app that is not the active one.
final class PointerReportingView: NSView {
    var onPointer: ((CGPoint) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { report() }
    override func mouseMoved(with event: NSEvent) { report() }
    override func mouseExited(with event: NSEvent) { report() }

    private func report() {
        // The live location rather than the event's, which arrives in the panel's own coordinates.
        onPointer?(NSEvent.mouseLocation)
    }
}

struct BreathingOpacity: ViewModifier {
    private static let period: TimeInterval = 1.4
    private static let floor: Double = 0.42

    let isActive: Bool
    @State private var exhaled = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive && exhaled ? Self.floor : 1)
            .onAppear { restart() }
            .onChange(of: isActive) { _, _ in restart() }
    }

    private func restart() {
        // Settled without animation first: assigning through the repeating curve is what leaves a
        // cancelled breath half-taken, and the brightened frame would then be dimmer than it should
        // be for as long as the pointer stayed.
        withAnimation(.linear(duration: 0)) { exhaled = false }
        guard isActive else { return }
        withAnimation(.easeInOut(duration: Self.period).repeatForever(autoreverses: true)) {
            exhaled = true
        }
    }
}

struct AmbientHighlightView: View {
    @ObservedObject var model: AmbientHighlightModel
    let hintBarHeight: CGFloat
    let gap: CGFloat
    let activate: () -> Void

    var body: some View {
        content
            .animation(.easeOut(duration: 0.12), value: model.isRevealed)
            .animation(.easeOut(duration: 0.12), value: model.isArmed)
    }

    @ViewBuilder
    private var content: some View {
        switch model.placement {
        case .above:
            stack { hint; outline }
        case .below:
            stack { outline; hint }
        case .inside:
            // Trailing for a quiet outline. The frame the terminal watch draws runs the width of
            // the terminal while its text does not, so the right-hand end of the first row is the
            // one place inside the block that is reliably empty -- and putting the button there is
            // what stopped it covering the line above.
            outline.overlay(alignment: model.style == .quiet ? .topTrailing : .topLeading) {
                hint.padding(model.style == .quiet ? 5 : 0)
            }
        }
    }

    private func stack(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: gap, content: content)
            // Pinned, not centred: a centred stack would spread the slack evenly and shift the
            // outline off the text by half the hint's height.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A frame nobody asked for has to be quiet enough to read text through, so at rest it is a
    /// one-point line at a little over a third opacity and no fill at all. It brightens to the
    /// declared weight when the pointer approaches, which is also when the button appears.
    private var isLoud: Bool { model.style == .declared || model.isRevealed || model.isArmed }

    private var outline: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(model.tint.color.opacity(isLoud ? 0.85 : 0.40), lineWidth: isLoud ? 2 : 1)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Barely more fill while armed than while merely approached. The frame is
                    // about to take a click, but the pointer already says so, and a heavier tint
                    // over a block the width of a terminal reads as a slab rather than a hint.
                    .fill(model.tint.color.opacity(model.isArmed ? 0.10 : (isLoud ? 0.07 : 0)))
            )
            .modifier(BreathingOpacity(isActive: !isLoud))
            .frame(height: model.outlineHeight)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: activate)
            // Decoration over someone else's window, so it must never eat a click -- until the
            // user asks for it by holding the modifier down, which is the whole point of arming:
            // aiming at a small pill to open a block you are already looking at is work, and the
            // block itself is the bigger target.
            .allowsHitTesting(model.isArmed)
    }

    /// Rendered only while it is wanted rather than faded to nothing, because a transparent button
    /// still swallows the click that was meant for the terminal underneath it.
    @ViewBuilder
    private var hint: some View {
        if model.style == .quiet {
            if model.isRevealed || model.isArmed {
                // A label, not a button. What opens the diagram is a click on the block itself, and
                // a pill that said "Option-click" while also answering a plain click on the pill
                // would be two answers to one question -- and the smaller of the two targets.
                pill
                    .allowsHitTesting(false)
                    .help(String(localized: String.LocalizationValue(model.anchor.hintHelpKey)))
            }
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: activate) { pill }
            .buttonStyle(.plain)
            .help(String(localized: String.LocalizationValue(model.anchor.hintHelpKey)))
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 10, weight: .semibold))
            Text(model.keyword ?? String(localized: "ambient.hint.generic"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let note = model.anchor.hintNoteKey {
                Text(String(localized: String.LocalizationValue(note)))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .opacity(0.85)
            }
            Text(model.chip)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                // The bar can be no wider than the outline, and the outline can be the 80-point
                // floor. The chip is the one thing the hint exists to show, so it takes its width
                // first and the keyword beside it truncates instead.
                .layoutPriority(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 8)
        // Both axes pinned. Height alone left the pill free to take the width of whatever it was
        // laid into, and in an overlay over a block the width of a terminal that is the width of
        // the terminal -- a capsule several hundred points long across the first row.
        .frame(height: hintBarHeight)
        .fixedSize()
        .background(model.tint.color, in: Capsule())
        .foregroundStyle(.white)
        .contentShape(Capsule())
    }
}
