import AppKit
import FlowPeekCore

/// Every diagram the terminal watch can see, framed at once.
///
/// A terminal showing two diagrams is showing two diagrams. Framing only the biggest one left the
/// other with no way to be opened at all -- there is no pointing at it, no selecting it, nothing:
/// the frame is the entire affordance, so a block without one is a block FlowPeek is pretending not
/// to have found.
///
/// One panel per block, and one pair of global monitors for all of them. Each frame could watch the
/// pointer itself, and three frames would then be three monitors answering the same question about
/// the same pointer on every mouse move; instead this asks once and tells each frame whether the
/// pointer is near *it*. Which is also what makes hovering one block reveal that block's label and
/// not its neighbour's.
@MainActor
final class TerminalOutlineCoordinator {
    /// Fired with the index of the frame that was activated, into the array last shown.
    var onActivate: ((Int) -> Void)?

    /// More than this on screen at once is not a terminal anybody is reading -- it is `cat` of a
    /// document full of diagrams -- and a screen of frames is worse than none. The blocks are in
    /// buffer order, so the ones kept are the ones nearest the top.
    static let maximumOutlines = 4

    private var frames: [AmbientHighlightCoordinator] = []
    /// Held as well as forwarded, because the frames are built on demand: one raised after a
    /// settings change would otherwise open in the previous colour.
    private var storedTint: HintTintChoice = .systemAccent

    var tint: HintTintChoice {
        get { storedTint }
        set {
            storedTint = newValue
            for frame in frames { frame.tint = newValue }
        }
    }
    private var pointerMonitor: Any?
    private var flagsMonitor: Any?
    private var isArmed = false

    func show(_ candidates: [AmbientCandidate], chip: String) {
        guard !candidates.isEmpty else {
            hide()
            return
        }
        let wanted = Array(candidates.prefix(Self.maximumOutlines))
        // Frames are reused in order rather than matched to blocks: a panel is a rectangle and a
        // label, both of which are set from scratch on every show, so the cheapest correct thing is
        // to hand the first block to the first panel. Reusing them also keeps a block that merely
        // moved from fading out and back in.
        while frames.count < wanted.count {
            let index = frames.count
            let frame = AmbientHighlightCoordinator(tracksPointer: false)
            frame.tint = storedTint
            frame.onActivate = { [weak self] in self?.onActivate?(index) }
            frame.onPointerOverPanel = { [weak self] point in self?.update(pointer: point) }
            frames.append(frame)
        }
        for (index, frame) in frames.enumerated() {
            guard index < wanted.count else {
                frame.hide()
                continue
            }
            frame.show(wanted[index], chip: chip, style: .quiet)
        }
        startTracking()
        update(pointer: NSEvent.mouseLocation)
        setArmed(AmbientHighlightCoordinator.isArmingModifier(NSEvent.modifierFlags))
    }

    func hide() {
        stopTracking()
        isArmed = false
        frames.forEach { $0.hide() }
    }

    // MARK: - The pointer, once for all of them

    private func startTracking() {
        if pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] _ in
                Task { @MainActor in self?.update(pointer: NSEvent.mouseLocation) }
            }
        }
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let armed = AmbientHighlightCoordinator.isArmingModifier(event.modifierFlags)
            Task { @MainActor in self?.setArmed(armed) }
        }
    }

    private func stopTracking() {
        [pointerMonitor, flagsMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        pointerMonitor = nil
        flagsMonitor = nil
    }

    /// Only the nearest frame reveals its label.
    ///
    /// Two blocks a couple of rows apart both fall inside the reveal margin, and two labels lit at
    /// once says the pointer is on both. The nearest one wins; a pointer inside a frame is at no
    /// distance from it, so a block being pointed at always beats a block merely near.
    private func update(pointer: CGPoint) {
        let distances = frames.map { frame -> CGFloat? in
            guard let outline = frame.outlineRect,
                  TerminalPeekPolicy.revealsButton(pointer: pointer, outline: outline) else { return nil }
            return Self.distance(from: pointer, to: outline)
        }
        let nearest = distances.enumerated()
            .compactMap { index, distance in distance.map { (index, $0) } }
            .min { $0.1 < $1.1 }?.0
        for (index, frame) in frames.enumerated() {
            frame.setRevealed(index == nearest)
        }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        frames.forEach { $0.setArmedExternally(armed) }
    }
}
