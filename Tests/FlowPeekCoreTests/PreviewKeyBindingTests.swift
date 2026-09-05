import XCTest

@testable import FlowPeekCore

/// Which keys the two preview surfaces answer, and — more importantly — which ones they must not.
///
/// The quick panel is a non-activating panel: its keys are only ever *observed* through a global
/// monitor, which cannot consume them, so anything bound there also still reaches the application
/// the user is actually typing in. That is the whole reason the two tables differ.
final class PreviewKeyBindingTests: XCTestCase {
    private enum Code {
        static let one: UInt16 = 18
        static let zero: UInt16 = 29
        static let equal: UInt16 = 24
        static let minus: UInt16 = 27
        static let keypadPlus: UInt16 = 69
        static let w: UInt16 = 13
        static let c: UInt16 = 8
        static let s: UInt16 = 1
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let a: UInt16 = 0
    }

    private func panel(_ code: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) -> PreviewCommand? {
        PreviewKeyBinding.command(
            for: PreviewKeyStroke(keyCode: code, command: command, shift: shift, option: option, control: control),
            surface: .panel
        )
    }

    private func window(_ code: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) -> PreviewCommand? {
        PreviewKeyBinding.command(
            for: PreviewKeyStroke(keyCode: code, command: command, shift: shift, option: option, control: control),
            surface: .window
        )
    }

    // MARK: - The quick panel

    func testThePanelZoomsFromTheBareKeys() {
        XCTAssertEqual(panel(Code.equal), .zoomIn)
        XCTAssertEqual(panel(Code.keypadPlus), .zoomIn)
        XCTAssertEqual(panel(Code.minus), .zoomOut)
        XCTAssertEqual(panel(Code.zero), .fit)
        XCTAssertEqual(panel(Code.one), .actualSize)
    }

    /// `+` is Shift-`=` on most layouts, so the two spellings of "zoom in" must agree.
    func testShiftDoesNotBreakZoomIn() {
        XCTAssertEqual(panel(Code.equal, shift: true), .zoomIn)
        XCTAssertEqual(window(Code.equal, command: true, shift: true), .zoomIn)
    }

    /// The one that would do real damage. A global monitor cannot consume the event, so a ⌘C bound
    /// here would fire while the frontmost application is also copying, and FlowPeek would
    /// overwrite the clipboard the user had just filled.
    func testThePanelBindsNoCommandCombinationAtAll() {
        XCTAssertNil(panel(Code.c, command: true))
        XCTAssertNil(panel(Code.c, command: true, shift: true))
        XCTAssertNil(panel(Code.s, command: true))
        XCTAssertNil(panel(Code.w, command: true))
        XCTAssertNil(panel(Code.zero, command: true))
        XCTAssertNil(panel(Code.escape, command: true))
    }

    func testEscapeClosesTheQuickPanel() {
        XCTAssertEqual(panel(Code.escape), .close)
    }

    /// Escape in the promoted window reaches `cancelOperation` through the responder chain; the
    /// monitor must not claim it as well.
    func testTheWindowLeavesEscapeToTheResponderChain() {
        XCTAssertNil(window(Code.escape))
    }

    // MARK: - The promoted window

    func testTheWindowNeedsCommandForEveryZoomKey() {
        XCTAssertEqual(window(Code.equal, command: true), .zoomIn)
        XCTAssertEqual(window(Code.minus, command: true), .zoomOut)
        XCTAssertEqual(window(Code.zero, command: true), .fit)
        XCTAssertEqual(window(Code.one, command: true), .actualSize)
        XCTAssertNil(window(Code.equal), "a bare key in a window belongs to whatever has focus there")
        XCTAssertNil(window(Code.zero))
    }

    func testTheWindowCopiesSavesAndCloses() {
        XCTAssertEqual(window(Code.c, command: true), .copyImage)
        XCTAssertEqual(window(Code.c, command: true, shift: true), .copySource)
        XCTAssertEqual(window(Code.s, command: true), .save)
        XCTAssertEqual(window(Code.w, command: true), .close)
    }

    // MARK: - Panning

    func testArrowsPanBothSurfacesWithoutAModifier() {
        let step = PreviewKeyBinding.panStep
        XCTAssertEqual(panel(Code.left), .pan(dx: -step, dy: 0))
        XCTAssertEqual(panel(Code.right), .pan(dx: step, dy: 0))
        XCTAssertEqual(panel(Code.up), .pan(dx: 0, dy: -step))
        XCTAssertEqual(panel(Code.down), .pan(dx: 0, dy: step))
        XCTAssertEqual(window(Code.down), .pan(dx: 0, dy: step))
    }

    func testShiftPansFasterOnBothSurfaces() {
        let fast = PreviewKeyBinding.fastPanStep
        XCTAssertGreaterThan(fast, PreviewKeyBinding.panStep)
        XCTAssertEqual(panel(Code.right, shift: true), .pan(dx: fast, dy: 0))
        XCTAssertEqual(window(Code.right, shift: true), .pan(dx: fast, dy: 0))
    }

    /// ⌘← and ⌘→ are the system's line-jump equivalents; a preview must not shadow them.
    func testCommandArrowsAreNotPanning() {
        XCTAssertNil(panel(Code.left, command: true))
        XCTAssertNil(window(Code.left, command: true))
    }

    // MARK: - Everything else

    func testOptionAndControlAreNeverPreviewCommands() {
        for code in [Code.equal, Code.zero, Code.left, Code.c, Code.escape] {
            XCTAssertNil(panel(code, option: true), "option is the ambient-peek hold")
            XCTAssertNil(panel(code, control: true))
            XCTAssertNil(window(code, command: true, option: true))
            XCTAssertNil(window(code, command: true, control: true))
        }
    }

    func testAnUnboundKeyIsLeftAlone() {
        XCTAssertNil(panel(Code.a))
        XCTAssertNil(window(Code.a, command: true))
    }

    // MARK: - What an observer may answer

    /// While somebody else's window is frontmost the panel's keys are only observed, and an
    /// observer cannot take a key away from the application it was meant for. Answering an
    /// unmodified character there means a `-` typed into an editor also zooms a panel floating over
    /// it, with nothing on screen to explain why.
    func testAnObservedPanelAnswersEscapeAndNothingElse() {
        XCTAssertEqual(
            PreviewKeyBinding.command(for: PreviewKeyStroke(keyCode: 53), surface: .observedPanel),
            .close
        )
        for keyCode: UInt16 in [24, 27, 29, 18, 69, 78, 82, 83, 123, 124, 125, 126] {
            XCTAssertNil(
                PreviewKeyBinding.command(for: PreviewKeyStroke(keyCode: keyCode), surface: .observedPanel),
                "key \(keyCode) must not be answered while it belongs to another application"
            )
        }
    }

    /// Once the panel is the key window the same keys arrive properly and can be consumed, so the
    /// viewport is driveable from the keyboard there.
    func testTheKeyPanelStillAnswersTheViewportKeys() {
        XCTAssertEqual(PreviewKeyBinding.command(for: PreviewKeyStroke(keyCode: 24), surface: .panel), .zoomIn)
        XCTAssertEqual(PreviewKeyBinding.command(for: PreviewKeyStroke(keyCode: 27), surface: .panel), .zoomOut)
        XCTAssertEqual(PreviewKeyBinding.command(for: PreviewKeyStroke(keyCode: 29), surface: .panel), .fit)
        XCTAssertEqual(PreviewKeyBinding.command(for: PreviewKeyStroke(keyCode: 18), surface: .panel), .actualSize)
        XCTAssertEqual(
            PreviewKeyBinding.command(for: PreviewKeyStroke(keyCode: 123), surface: .panel),
            .pan(dx: -PreviewKeyBinding.panStep, dy: 0)
        )
    }
}

/// What each surface is allowed to tell the user its keys are. A hint is a promise, and the panel
/// and the window keep different ones — which is exactly how the chrome got to advertise ⌘0 on a
/// surface where the working key is a bare `0`.
final class PreviewKeyGlyphTests: XCTestCase {
    private let viewport: [PreviewCommand] = [.zoomIn, .zoomOut, .fit, .actualSize]

    /// The panel binds no Command combination, so it must never display one: ⌘C there would be
    /// delivered to the application the user is typing in, not to the preview.
    func testThePanelAdvertisesTheBareKeysItReallyTakes() {
        for command in viewport {
            let glyph = PreviewKeyBinding.glyph(for: command, surface: .panel)
            XCTAssertNotNil(glyph, "\(command) works in the panel and has to be discoverable there")
            XCTAssertFalse(glyph?.contains("⌘") ?? true, "the panel answers no Command combination")
        }
        XCTAssertNil(PreviewKeyBinding.glyph(for: .copyImage, surface: .panel))
        XCTAssertNil(PreviewKeyBinding.glyph(for: .save, surface: .panel))
    }

    func testTheWindowAdvertisesTheCommandCombinationsItConsumes() {
        for command in viewport + [.copyImage, .copySource, .save, .close] {
            let glyph = PreviewKeyBinding.glyph(for: command, surface: .window)
            XCTAssertEqual(glyph?.hasPrefix("⌘"), true, "\(command) is a Command combination in the window")
        }
    }

    /// An observer can answer Escape and nothing else, so Escape is the only key it may promise.
    func testAnObservedPanelPromisesOnlyTheKeyItCanAnswer() {
        XCTAssertNotNil(PreviewKeyBinding.glyph(for: .close, surface: .observedPanel))
        for command in viewport {
            XCTAssertNil(PreviewKeyBinding.glyph(for: command, surface: .observedPanel))
        }
    }

    /// The glyph table and the dispatch table are written separately, so the only thing keeping a
    /// hint from advertising a key its surface throws away is this: every cap that is displayed is
    /// pressed here, on the surface that displayed it, and has to come back as the command it was
    /// offered for.
    func testEveryKeyCapAdvertisedIsOneTheSurfaceReallyAnswers() throws {
        let commands: [PreviewCommand] = viewport + [.copyImage, .copySource, .save, .close]
        for surface: PreviewKeyBinding.Surface in [.observedPanel, .panel, .window] {
            for command in commands {
                guard let glyph = PreviewKeyBinding.glyph(for: command, surface: surface) else { continue }
                XCTAssertEqual(
                    PreviewKeyBinding.command(for: try stroke(pressing: glyph), surface: surface),
                    command,
                    "\(surface) offers \(glyph) for \(command)"
                )
            }
        }
    }

    /// The key a cap names, as the keyboard actually sends it. Written from the key caps rather
    /// than from either table, so it can hold the two of them to each other: `+` is Shift and the
    /// `=` key, and the typographic minus a menu prints is the hyphen key.
    private func stroke(pressing glyph: String) throws -> PreviewKeyStroke {
        var cap = Substring(glyph)
        var command = false
        var shift = false
        while let modifier = cap.first, modifier == "⌘" || modifier == "⇧" {
            if modifier == "⌘" { command = true } else { shift = true }
            cap = cap.dropFirst()
        }
        let codes: [String: UInt16] = ["esc": 53, "0": 29, "1": 18, "C": 8, "S": 1, "W": 13, "+": 24, "−": 27]
        let keyCode = try XCTUnwrap(codes[String(cap)], "no key is known for the cap \(glyph)")
        return PreviewKeyStroke(keyCode: keyCode, command: command, shift: shift || cap == "+")
    }

    /// Panning has no glyph anywhere: the arrows are not written into a tooltip on either surface.
    func testPanningIsNotAdvertisedAsAKeyCap() {
        for surface: PreviewKeyBinding.Surface in [.observedPanel, .panel, .window] {
            XCTAssertNil(PreviewKeyBinding.glyph(for: .pan(dx: 60, dy: 0), surface: surface))
        }
    }
}
