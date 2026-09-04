import AppKit
import FlowPeekCore
import XCTest

@testable import FlowPeek

/// The asked-for clipboard route, end to end through the real `AppState`: the live pasteboard read
/// and the panel it produces are both AppKit, so this is the only place they can be driven.
@MainActor
final class ClipboardRouteTests: XCTestCase {
    /// One case's own panels. Every FlowPeek surface has `isReleasedWhenClosed` false, so the
    /// windows other cases opened stay in `NSApp.windows` for the life of the process; a case counts
    /// from a baseline it takes itself.
    @MainActor
    private struct PanelScope {
        private let existing: Set<ObjectIdentifier>

        init() { existing = Set(NSApp.windows.map(ObjectIdentifier.init)) }

        var titles: [String] {
            NSApp.windows
                .filter { $0 is FlowPeekGlassPanel && $0.isVisible && !existing.contains(ObjectIdentifier($0)) }
                .map(\.title)
        }
    }

    /// `AppState.shared.clipboard` reads `NSPasteboard.general`, so a case owns the pasteboard for
    /// its duration and puts back whatever it found there — along with the hot keys, which belong to
    /// the running app rather than to the case. Written as a wrapper rather than as `setUp`, which
    /// XCTest declares outside the main actor.
    private func owningTheClipboard(_ body: () throws -> Void) rethrows {
        let restored = NSPasteboard.general.string(forType: .string)
        defer {
            AppState.shared.previews.closeQuick()
            if let restored {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(restored, forType: .string)
            }
            AppState.shared.applyEnabledState()
        }
        try body()
    }

    private func copy(_ text: String) {
        AppState.shared.clipboard.write(text)
    }

    /// The copy the poller can never report: it writes off everything already on the pasteboard when
    /// the watch starts, so a diagram copied before FlowPeek was launched was never witnessed — and
    /// the key the tutorial teaches used to answer only for witnessed copies.
    func testTheKeyOpensADiagramNobodyWitnessedBeingCopied() {
        owningTheClipboard {
            let scope = PanelScope()
            copy("flowchart TD\n  A[unwitnessed] --> B[opened]")

            AppState.shared.previewCopied()

            XCTAssertEqual(scope.titles, [String(localized: "diagram.clipboard-title")])
        }
    }

    /// A diagram too big to draw has to be told about. It used to be answered either with "there is
    /// no Mermaid diagram on the clipboard" or — with a remembered copy in memory — by silently
    /// opening that older diagram under the title "Copied Diagram".
    func testAnOversizedCopyReportsItsSizeRatherThanOpeningTheLastOne() {
        owningTheClipboard {
            let remembered = PanelScope()
            copy("flowchart TD\n  A[remembered] --> B")
            AppState.shared.previewCopied()
            XCTAssertFalse(
                remembered.titles.isEmpty,
                "the remembered copy has to be in memory for there to be a fallback to refuse"
            )
            AppState.shared.previews.closeQuick()

            let scope = PanelScope()
            copy("flowchart TD\n" + String(repeating: "  A --> B\n", count: 20_000))
            AppState.shared.previewCopied()

            XCTAssertEqual(scope.titles, [String(localized: "clipboard.error.title")])
        }
    }

    /// The chord in that panel's copy is rendered from the store, and only while something holds it.
    /// A dormant route has no registered hot key — and the panel is reachable from a menu row that
    /// is always enabled — so naming the stored combination there would advertise a key that goes
    /// nowhere.
    func testNoChordIsNamedWhileNothingHoldsOne() throws {
        try owningTheClipboard {
            let shortcuts = AppState.shared.shortcuts
            shortcuts.setActiveActions([])
            XCTAssertNil(AppState.shared.clipboardShortcutDisplay)

            shortcuts.setActiveActions([.previewClipboard])
            try XCTSkipIf(
                shortcuts.unavailableActions.contains(.previewClipboard),
                "another process holds the combination, which is the other reason not to name it"
            )
            XCTAssertEqual(
                AppState.shared.clipboardShortcutDisplay,
                shortcuts.shortcuts[.previewClipboard].display
            )
        }
    }
}
