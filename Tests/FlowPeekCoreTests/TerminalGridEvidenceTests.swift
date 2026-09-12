import XCTest

@testable import FlowPeekCore

/// The numbers here were read live from Ghostty 1.3.1 on macOS 26 at backing scale 2 by walking the
/// terminal's process tree to its pty and asking it one `ioctl(TIOCGWINSZ)`. Where a reading is a
/// pair of numbers from one measurement and a pair from another -- a height series whose widths were
/// not written down, say -- the comment on the test says so.
///
/// They are here because the whole claim of `TerminalGridEvidence` is that it never invents a cell:
/// it only ever deletes candidates the terminal's own arithmetic has already ruled out. A change that
/// turns a deletion into a substitution is worth exactly one pixel per row, which is a whole row of
/// drift by the fortieth, and no guard downstream can see it.
final class TerminalGridEvidenceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func later(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: - The ambiguous pane that closes

    /// The case this exists for. A live seven-row pane -- `ws_row 7`, `ws_ypixel 228` -- brackets to
    /// `(28.5, 32.571]`, four candidates, and FlowPeek refuses it today and still refuses it here.
    /// One resize of the same surface settles it: 528 pixels over 16 rows brackets to `(31.06, 33.0]`
    /// and only 32 is in both. Both readings are from the four-height series in `TerminalWinsize`'s
    /// doc comment; the width fields are the same surface's measured 140 columns over 2250 pixels,
    /// unchanged because the resize was vertical.
    func testTheSevenRowPaneIsAmbiguousAloneAndClosesWhenTheSurfaceIsResized() throws {
        let short = TerminalWinsize(rows: 7, columns: 140, heightInPixels: 228, widthInPixels: 2250)
        let taller = TerminalWinsize(rows: 16, columns: 140, heightInPixels: 528, widthInPixels: 2250)
        let shortPane = CGSize(width: 1129, height: 118)
        let tallerPane = CGSize(width: 1129, height: 268)

        var evidence = TerminalGridEvidence()
        XCTAssertEqual(evidence.record(short, at: start), .seeded)
        XCTAssertEqual(evidence.cellHeightCandidates, [29, 30, 31, 32])
        XCTAssertEqual(evidence.cellWidthCandidates, [16])
        XCTAssertNil(evidence.cellHeightInPixels, "four candidates is a guess")
        XCTAssertNil(evidence.grid(viewportSize: shortPane, scale: 2))
        XCTAssertNil(short.grid(viewportSize: shortPane, scale: 2), "and that is today's behaviour")

        XCTAssertEqual(evidence.record(taller, at: later(1)), .narrowed)
        XCTAssertEqual(evidence.cellHeightCandidates, [32])
        let answer = try XCTUnwrap(evidence.grid(viewportSize: tallerPane, scale: 2))
        XCTAssertEqual(answer.grid.rowHeight, 16.000, accuracy: 0.001)
        XCTAssertEqual(answer.grid.cellWidth, 8.000, accuracy: 0.001)
        XCTAssertEqual(answer.grid.topPadding, 2.0, accuracy: 0.001)
        XCTAssertEqual(answer.grid.rows, 16)

        // And back. The evidence is about the surface, not about the window height it was taken at,
        // so the pane that could not answer for itself is answered now.
        XCTAssertEqual(evidence.record(short, at: later(2)), .narrowed)
        XCTAssertEqual(evidence.cellHeightCandidates, [32])
        let reframed = try XCTUnwrap(evidence.grid(viewportSize: shortPane, scale: 2))
        XCTAssertEqual(reframed.grid.rowHeight, 16.000, accuracy: 0.001)
        XCTAssertEqual(reframed.grid.rows, 7)
        XCTAssertEqual(reframed.grid.topPadding, 2.0, accuracy: 0.001)
    }

    /// Measured on a font-17 surface dragged through ten window heights: reading one is 428 pixels
    /// over 10 rows, `{39,40,41,42}`, and reading two is 452 over 10, `{42,43,44,45}`. Twelve points
    /// of drag, two readings, and the true 42-pixel cell is the only survivor. The width fields carry
    /// the 61-column / 1288-pixel pair measured at the same font size, because the series recorded
    /// heights only and the width has to be pinned for the grid to be answered at all.
    func testTwelvePointsOfDragClosesAFontSeventeenSurface() throws {
        let first = TerminalWinsize(rows: 10, columns: 61, heightInPixels: 428, widthInPixels: 1288)
        let second = TerminalWinsize(rows: 10, columns: 61, heightInPixels: 452, widthInPixels: 1288)

        var evidence = TerminalGridEvidence()
        evidence.record(first, at: start)
        XCTAssertEqual(evidence.cellHeightCandidates, [39, 40, 41, 42])
        XCTAssertNil(evidence.grid(viewportSize: CGSize(width: 648, height: 218), scale: 2))

        XCTAssertEqual(evidence.record(second, at: later(0.25)), .narrowed)
        XCTAssertEqual(evidence.cellHeightCandidates, [42])
        let answer = try XCTUnwrap(evidence.grid(viewportSize: CGSize(width: 648, height: 230), scale: 2))
        XCTAssertEqual(answer.grid.rowHeight, 21.000, accuracy: 0.001)
        XCTAssertEqual(answer.grid.cellWidth, 10.500, accuracy: 0.001)
        XCTAssertEqual(answer.provenance, .accumulated)
    }

    /// The reporting user's own configuration, reproduced here at the same 17-point size: a 700x700
    /// point window gives `rows 30 cols 69 ws_ypixel 1388 ws_xpixel 1380`, bracket `(44.77, 46.27]`,
    /// two candidates, refused. The same surface in native fullscreen gives `rows 47 ws_ypixel 2148`,
    /// bracket `(44.75, 45.70]`, and 45 is the only cell in both. The fullscreen reading's width
    /// fields are the only derived numbers in this file: `ws_xpixel 3820` and `cols 191` follow from
    /// the measured five-point horizontal padding and the 20-pixel cell, not from a pty. They are
    /// here so the width axis stays pinned; the height numbers either side are measured.
    func testTheReportersWindowedPaneClosesWhenTheyGoFullScreen() throws {
        let windowed = TerminalWinsize(rows: 30, columns: 69, heightInPixels: 1388, widthInPixels: 1380)
        let fullScreen = TerminalWinsize(rows: 47, columns: 191, heightInPixels: 2148, widthInPixels: 3820)
        let windowedPane = CGSize(width: 700, height: 700)

        var evidence = TerminalGridEvidence()
        evidence.record(windowed, at: start)
        XCTAssertEqual(evidence.cellHeightCandidates, [45, 46])
        XCTAssertNil(evidence.grid(viewportSize: windowedPane, scale: 2))

        XCTAssertEqual(evidence.record(fullScreen, at: later(5)), .narrowed)
        XCTAssertEqual(evidence.cellHeightCandidates, [45])
        XCTAssertEqual(evidence.record(windowed, at: later(10)), .narrowed)

        let answer = try XCTUnwrap(evidence.grid(viewportSize: windowedPane, scale: 2))
        XCTAssertEqual(answer.grid.rowHeight, 22.500, accuracy: 0.001)
        XCTAssertEqual(answer.grid.rows, 30)

        // And the half it cannot fix. That configuration sets `window-padding-y = 5,1`, so the true
        // top padding is five points and the total is six; half the total is three. The cell is now
        // exact and the frame still sits two points high, a tenth of a row. Nothing in the winsize
        // distinguishes `5,1` from `1,5`: two surfaces so configured were identical in every
        // observable, down to `AXContentSize`, with true top paddings of 10 and 2 device pixels.
        XCTAssertEqual(answer.grid.topPadding, 3.0, accuracy: 0.001)
        XCTAssertEqual(5.0 - answer.grid.topPadding, 2.0, accuracy: 0.001)
    }

    // MARK: - The panes that were never ambiguous

    /// Font size 13, the pane everything else was measured against: `rows 40 cols 140
    /// ws_ypixel 1280 ws_xpixel 2250`, one candidate on each axis from one look. A second identical
    /// reading changes nothing, because an intersection with itself is itself.
    func testTheThirteenPointPaneIsPinnedByOneReading() throws {
        let measured = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        let pane = CGSize(width: 1129, height: 644)

        var evidence = TerminalGridEvidence()
        XCTAssertEqual(evidence.record(measured, at: start), .seeded)
        XCTAssertEqual(evidence.cellHeightCandidates, [32])
        XCTAssertEqual(evidence.cellWidthCandidates, [16])

        let answer = try XCTUnwrap(evidence.grid(viewportSize: pane, scale: 2))
        XCTAssertEqual(answer.grid.rowHeight, 16.000, accuracy: 0.001)
        XCTAssertEqual(answer.grid.cellWidth, 8.000, accuracy: 0.001)
        XCTAssertEqual(answer.grid.topPadding, 2.0, accuracy: 0.001)
        XCTAssertEqual(answer.provenance, .singleReading)

        XCTAssertEqual(evidence.record(measured, at: later(0.25)), .narrowed)
        XCTAssertEqual(evidence.cellHeightCandidates, [32])
        XCTAssertEqual(evidence.grid(viewportSize: pane, scale: 2), answer)
    }

    /// Font size 17 on a taller pane: `rows 31 ws_ypixel 1324` brackets to `(41.375, 42.710]` and
    /// `cols 61 ws_xpixel 1288` to `(20.774, 21.115]`. Both singletons, so the accumulator has
    /// nothing to add and does not pretend otherwise.
    func testTheSeventeenPointPaneIsPinnedByOneReading() throws {
        let measured = TerminalWinsize(rows: 31, columns: 61, heightInPixels: 1324, widthInPixels: 1288)
        var evidence = TerminalGridEvidence()
        evidence.record(measured, at: start)
        XCTAssertEqual(evidence.cellHeightCandidates, [42])
        XCTAssertEqual(evidence.cellWidthCandidates, [21])

        let answer = try XCTUnwrap(evidence.grid(viewportSize: CGSize(width: 648, height: 666), scale: 2))
        XCTAssertEqual(answer.grid.rowHeight, 21.000, accuracy: 0.001)
        XCTAssertEqual(answer.grid.cellWidth, 10.500, accuracy: 0.001)
        XCTAssertEqual(answer.grid.topPadding, 2.0, accuracy: 0.001)
        XCTAssertEqual(answer.provenance, .singleReading)
    }

    /// Only a cell a single reading pinned by itself may ever be written to the cross-session store,
    /// because that value outlives the process that produced it and is then applied to windows nobody
    /// measured. A narrowed cell is true of one surface for as long as its font holds, and says so.
    func testOnlyACellPinnedByOneReadingMayBeRemembered() throws {
        let pinned = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        var alone = TerminalGridEvidence()
        alone.record(pinned, at: start)
        let pinnedAnswer = try XCTUnwrap(alone.grid(viewportSize: CGSize(width: 1129, height: 644), scale: 2))
        XCTAssertTrue(pinnedAnswer.mayBeRemembered)

        var accumulated = TerminalGridEvidence()
        accumulated.record(TerminalWinsize(rows: 7, columns: 140, heightInPixels: 228, widthInPixels: 2250), at: start)
        accumulated.record(TerminalWinsize(rows: 16, columns: 140, heightInPixels: 528, widthInPixels: 2250), at: later(1))
        let narrowed = try XCTUnwrap(
            accumulated.grid(viewportSize: CGSize(width: 1129, height: 268), scale: 2)
        )
        XCTAssertEqual(narrowed.grid.rowHeight, 16.000, accuracy: 0.001)
        XCTAssertFalse(narrowed.mayBeRemembered)
    }

    // MARK: - Starting over

    /// A font change on one surface, measured three steps deep with `ws_ypixel` and `ws_xpixel` held
    /// at 1176 and 1268 throughout: 28 rows gives `{41,42}`, 26 gives `{44,45}`, 25 gives `{46,47}`,
    /// and the widths go 21, 22, 23. Every intersection is empty, so the evidence starts over from
    /// the newest reading rather than answering. Nothing else in the winsize says the font moved.
    func testAFontChangeEmptiesTheIntersectionAndStartsOver() {
        let before = TerminalWinsize(rows: 28, columns: 60, heightInPixels: 1176, widthInPixels: 1268)
        let after = TerminalWinsize(rows: 26, columns: 57, heightInPixels: 1176, widthInPixels: 1268)
        let larger = TerminalWinsize(rows: 25, columns: 55, heightInPixels: 1176, widthInPixels: 1268)
        let pane = CGSize(width: 638, height: 592)

        var evidence = TerminalGridEvidence()
        evidence.record(before, at: start)
        XCTAssertEqual(evidence.cellHeightCandidates, [41, 42])
        XCTAssertEqual(evidence.cellWidthCandidates, [21])

        XCTAssertEqual(evidence.record(after, at: later(1)), .restarted)
        XCTAssertEqual(evidence.cellHeightCandidates, [44, 45], "the newest reading alone")
        XCTAssertEqual(evidence.cellWidthCandidates, [22])
        XCTAssertEqual(evidence.readingCount, 1)
        XCTAssertNil(evidence.grid(viewportSize: pane, scale: 2), "two candidates, so refuse")

        XCTAssertEqual(evidence.record(larger, at: later(2)), .restarted)
        XCTAssertEqual(evidence.cellHeightCandidates, [46, 47])
        XCTAssertEqual(evidence.cellWidthCandidates, [23])
        XCTAssertNil(evidence.grid(viewportSize: pane, scale: 2))
    }

    /// Caught live and unprompted during the measuring: `/dev/ttys000` read `rows 40 cols 140
    /// ws_ypixel 1280 ws_xpixel 2250` at the start of a session and `rows 22 cols 80` with
    /// byte-identical pixels an hour later. Nothing in the reading announces the font change, and
    /// nothing has to: a cell is in a bracket exactly when `floor(span / cell)` is the row count,
    /// which is a function of the cell, so two row counts over one span can never share a candidate.
    /// The intersection is empty by construction.
    func testAConstantPixelSpanWithADifferentRowCountCannotShareACandidate() {
        let before = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        let after = TerminalWinsize(rows: 22, columns: 80, heightInPixels: 1280, widthInPixels: 2250)
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 1280, cells: 22), [56, 57, 58])
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 2250, cells: 80), [28])

        var evidence = TerminalGridEvidence()
        evidence.record(before, at: start)
        XCTAssertEqual(evidence.record(after, at: later(3600)), .restarted)
        XCTAssertEqual(evidence.cellHeightCandidates, [56, 57, 58])
        XCTAssertNil(evidence.cellHeightInPixels)

        // The general statement, over every row count one span admits.
        var owner: [Int: Int] = [:]
        for rows in 1...60 {
            for cell in TerminalWinsize.cellPixels(spanning: 1280, cells: rows) {
                XCTAssertNil(owner[cell], "cell \(cell) claimed by both \(owner[cell] ?? -1) and \(rows) rows")
                owner[cell] = rows
            }
        }
    }

    /// A surface nobody has looked at for a while may have been reconfigured while nobody was
    /// looking. The one way this can be wrong is a font change too small to move the pinned width
    /// that happens in the same poll gap as a resize, so that neither witness fires; an idle limit
    /// bounds how long such a survivor can live. Just under the limit it still narrows.
    func testEvidenceIsDroppedWhenASurfaceHasNotBeenReadForAWhile() {
        let short = TerminalWinsize(rows: 7, columns: 140, heightInPixels: 228, widthInPixels: 2250)
        let taller = TerminalWinsize(rows: 16, columns: 140, heightInPixels: 528, widthInPixels: 2250)

        var promptly = TerminalGridEvidence()
        promptly.record(short, at: start)
        XCTAssertEqual(promptly.record(taller, at: later(TerminalGridEvidence.idleLimit - 1)), .narrowed)
        XCTAssertEqual(promptly.cellHeightCandidates, [32])

        var idle = TerminalGridEvidence()
        idle.record(short, at: start)
        XCTAssertEqual(idle.record(taller, at: later(TerminalGridEvidence.idleLimit + 1)), .restarted)
        XCTAssertEqual(idle.cellHeightCandidates, [32, 33], "the newest reading alone, so still refusing")
        XCTAssertNil(idle.cellHeightInPixels)

        // A clock that went backwards is a clock this cannot reason about.
        var rewound = TerminalGridEvidence()
        rewound.record(short, at: later(10))
        XCTAssertEqual(rewound.record(taller, at: start), .restarted)
    }

    // MARK: - Intersection, never substitution

    /// The load-bearing invariant, over every cell a terminal could have and every plausible row
    /// count: whatever survives, survives in the newest reading's own bracket, and where it closes it
    /// closes on the cell the readings were built from.
    func testANarrowedCellIsAlwaysAMemberOfTheLatestReadingsOwnBracket() {
        for cell in 8...64 {
            for rows in 1...80 {
                // Two readings of one surface at the same cell: the first with no sub-cell leftover,
                // the second with the most there can be.
                let flush = TerminalWinsize(rows: rows, columns: 140, heightInPixels: rows * cell, widthInPixels: 2250)
                let ragged = TerminalWinsize(
                    rows: rows, columns: 140,
                    heightInPixels: rows * cell + cell - 1, widthInPixels: 2250
                )
                var evidence = TerminalGridEvidence()
                evidence.record(flush, at: start)
                evidence.record(ragged, at: later(0.25))

                let bracket = TerminalWinsize.cellPixels(spanning: ragged.heightInPixels, cells: rows)
                XCTAssertTrue(
                    evidence.cellHeightCandidates.isSubset(of: bracket),
                    "cell \(cell), rows \(rows): evidence may delete candidates, never introduce one"
                )
                XCTAssertTrue(evidence.cellHeightCandidates.contains(cell), "the truth is never deleted")
                if let answer = evidence.cellHeightInPixels {
                    XCTAssertEqual(answer, cell, "cell \(cell), rows \(rows)")
                }
            }
        }
    }

    /// A cell from another font, handed to a reading that does not admit it, is refused rather than
    /// used. Unreachable through `record`, which only intersects -- which is exactly why it is worth
    /// stating: the measured step from a 32-pixel cell to a 42-pixel one is five points per row, two
    /// hundred points down a 40-row pane, and no guard in the grid can see it.
    func testACellTheReadingDoesNotAdmitIsRefused() {
        let measured = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        let pane = CGSize(width: 1129, height: 644)
        XCTAssertNotNil(measured.grid(viewportSize: pane, scale: 2, cellHeightInPixels: 32, cellWidthInPixels: 16))
        XCTAssertNil(measured.grid(viewportSize: pane, scale: 2, cellHeightInPixels: 42, cellWidthInPixels: 16))
        XCTAssertNil(measured.grid(viewportSize: pane, scale: 2, cellHeightInPixels: 32, cellWidthInPixels: 21))
    }

    /// And through `record`: a 42-pixel cell in hand, then a reading that admits only 29 to 32, gives
    /// 29 to 32 and no answer at all. It never gives 42.
    func testEvidenceFromAnotherFontIsStartedOverRatherThanSubstituted() {
        var evidence = TerminalGridEvidence()
        evidence.record(TerminalWinsize(rows: 31, columns: 61, heightInPixels: 1324, widthInPixels: 1288), at: start)
        XCTAssertEqual(evidence.cellHeightInPixels, 42)

        evidence.record(TerminalWinsize(rows: 7, columns: 140, heightInPixels: 228, widthInPixels: 2250), at: later(1))
        XCTAssertEqual(evidence.cellHeightCandidates, [29, 30, 31, 32])
        XCTAssertNil(evidence.cellHeightInPixels)
        XCTAssertNil(evidence.grid(viewportSize: CGSize(width: 1129, height: 118), scale: 2))
    }

    /// Where one reading already closes the bracket, the narrowed path and the shipped path are the
    /// same grid. The two carry the same guards written out twice, and this is what keeps them from
    /// drifting apart.
    func testTheNarrowedPathAgreesWithTheShippedPathWhereverThatOneAnswers() throws {
        let cases: [(TerminalWinsize, CGSize)] = [
            (TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250),
             CGSize(width: 1129, height: 644)),
            (TerminalWinsize(rows: 41, columns: 140, heightInPixels: 1328, widthInPixels: 2250),
             CGSize(width: 1129, height: 668)),
            (TerminalWinsize(rows: 31, columns: 61, heightInPixels: 1324, widthInPixels: 1288),
             CGSize(width: 648, height: 666)),
            (TerminalWinsize(rows: 40, columns: 140, heightInPixels: 640, widthInPixels: 1125),
             CGSize(width: 1129, height: 644)),
        ]
        for (winsize, pane) in cases {
            for scale in [CGFloat(1), 2] {
                let shipped = winsize.grid(viewportSize: pane, scale: scale)
                var evidence = TerminalGridEvidence()
                evidence.record(winsize, at: start)
                let narrowed = evidence.grid(viewportSize: pane, scale: scale)?.grid
                XCTAssertEqual(shipped, narrowed, "\(winsize) at scale \(scale)")
            }
            let cell = try XCTUnwrap(winsize.cellHeightInPixels)
            XCTAssertTrue(
                TerminalWinsize.cellPixels(spanning: winsize.heightInPixels, cells: winsize.rows).contains(cell)
            )
        }
    }

    // MARK: - The refusals

    /// Two candidates is a guess whether they came from one reading or ten. Twenty rows over 640
    /// pixels is `(30.476, 32.000]`, and a second reading of the same window size says the same
    /// thing again.
    func testEvidenceThatHasNotClosedStillRefuses() {
        let short = TerminalWinsize(rows: 20, columns: 140, heightInPixels: 640, widthInPixels: 2250)
        var evidence = TerminalGridEvidence()
        evidence.record(short, at: start)
        evidence.record(short, at: later(0.25))
        XCTAssertEqual(evidence.cellHeightCandidates, [31, 32])
        XCTAssertNil(evidence.cellHeightInPixels)
        XCTAssertNil(evidence.grid(viewportSize: CGSize(width: 1129, height: 324), scale: 2))
    }

    /// A width that cannot be pinned is a reading that cannot place a wrapped line, so it refuses
    /// even when the height is certain. Here the columns are few enough that the width brackets to
    /// two: 640 pixels over 20 columns is `(30.476, 32.000]`.
    func testAnUnpinnedWidthRefusesEvenWhenTheHeightIsCertain() {
        let narrow = TerminalWinsize(rows: 40, columns: 20, heightInPixels: 1280, widthInPixels: 640)
        var evidence = TerminalGridEvidence()
        evidence.record(narrow, at: start)
        XCTAssertEqual(evidence.cellHeightCandidates, [32])
        XCTAssertEqual(evidence.cellWidthCandidates, [31, 32])
        XCTAssertNil(evidence.grid(viewportSize: CGSize(width: 324, height: 644), scale: 2))
    }

    /// A reading with no grid in it says nothing, so it changes nothing -- not the candidates, not
    /// the reading the grid would be measured against, not even the last-seen time that the idle
    /// limit is counted from. Terminals that never report a pixel size answer zeroes; a row count no
    /// cell inside `TerminalWinsize.cellPixelRange` can explain answers an empty bracket.
    func testAReadingWithNoGridInItIsIgnoredAndLeavesTheEvidenceAlone() throws {
        let measured = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        var evidence = TerminalGridEvidence()
        evidence.record(measured, at: start)
        let before = evidence

        XCTAssertEqual(
            evidence.record(TerminalWinsize(rows: 0, columns: 0, heightInPixels: 0, widthInPixels: 0), at: later(1)),
            .ignored
        )
        XCTAssertEqual(
            evidence.record(TerminalWinsize(rows: 40, columns: 140, heightInPixels: 0, widthInPixels: 0), at: later(2)),
            .ignored
        )
        // 400 rows in 1280 pixels needs a cell of three, under the four-pixel floor.
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 1280, cells: 400), [])
        XCTAssertEqual(
            evidence.record(TerminalWinsize(rows: 400, columns: 140, heightInPixels: 1280, widthInPixels: 2250), at: later(3)),
            .ignored
        )
        XCTAssertEqual(evidence, before)

        // Nothing was recorded at all, so there is nothing to answer with.
        var empty = TerminalGridEvidence()
        XCTAssertEqual(empty.record(TerminalWinsize(rows: 0, columns: 0, heightInPixels: 0, widthInPixels: 0), at: start), .ignored)
        XCTAssertNil(empty.lastSeen)
        XCTAssertNil(empty.grid(viewportSize: CGSize(width: 1129, height: 644), scale: 2))
        XCTAssertEqual(try XCTUnwrap(before.latest), measured)
    }

    /// Narrowing the cell does not soften one guard the shipped reading carries. The reading is still
    /// squared against the pane that was measured, on both axes and in device pixels, before anything
    /// is divided by a scale that might be wrong.
    func testTheCertaintyDoesNotSoftenAnyGuardTheReadingAlreadyCarried() {
        let measured = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        let pane = CGSize(width: 1129, height: 644)
        var evidence = TerminalGridEvidence()
        evidence.record(measured, at: start)
        XCTAssertEqual(evidence.cellHeightInPixels, 32, "the cell is certain either way")

        // The same reading believed at the wrong scale: 40 rows of 32 points do not fit a 644-point
        // pane, and the padding comes out at -636 pixels.
        XCTAssertNil(evidence.grid(viewportSize: pane, scale: 1))
        XCTAssertNil(evidence.grid(viewportSize: pane, scale: 4))
        XCTAssertNil(evidence.grid(viewportSize: pane, scale: .nan))
        // A pane that is nothing like the reading: one Ghostty process owns one pty per split and per
        // tab, and the accessibility tree names none of them.
        XCTAssertNil(evidence.grid(viewportSize: CGSize(width: 1129, height: 900), scale: 2))
        XCTAssertNil(evidence.grid(viewportSize: CGSize(width: 700, height: 644), scale: 2))
        XCTAssertNil(evidence.grid(viewportSize: CGSize(width: 0, height: 0), scale: 2))

        // A pty taller than the pane it claims to describe, with the bracket still closed, so it is
        // the inequality that refuses.
        var taller = TerminalGridEvidence()
        taller.record(TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1300, widthInPixels: 2250), at: start)
        XCTAssertEqual(taller.cellHeightInPixels, 32)
        XCTAssertNil(taller.grid(viewportSize: pane, scale: 2))

        // Sub-pixel disagreement between accessibility's doubles and the pty's whole pixels is slack,
        // not a negative padding.
        var slack = TerminalGridEvidence()
        slack.record(measured, at: start)
        XCTAssertEqual(slack.grid(viewportSize: CGSize(width: 1129, height: 639.8), scale: 2)?.grid.topPadding, 0)
    }

    // MARK: - Whose surface it is

    /// The pty minor is recycled: `/dev/ttys004` served at least six different Ghostty instances in
    /// twenty minutes of measuring, with the devfs slave inode going 8525, then absent, then 8533.
    /// Two surfaces that share a minor and nothing else are two surfaces, and intersecting one's
    /// readings with the other's is either empty, which is harmless, or a wrong survivor, which is
    /// not.
    func testARecycledPtyMinorDoesNotInheritAnotherSurfacesEvidence() {
        let first = TerminalSurfaceKey(
            processIdentifier: 1510, processStartedAt: 1789000000,
            ptyMinor: 4, ptyInode: 8525, backingScale: 2
        )
        let second = TerminalSurfaceKey(
            processIdentifier: 1510, processStartedAt: 1789000000,
            ptyMinor: 4, ptyInode: 8533, backingScale: 2
        )
        var store = TerminalGridEvidenceStore()
        store.record(TerminalWinsize(rows: 7, columns: 140, heightInPixels: 228, widthInPixels: 2250), from: first, at: start)
        store.record(TerminalWinsize(rows: 16, columns: 140, heightInPixels: 528, widthInPixels: 2250), from: second, at: start)

        XCTAssertEqual(store.evidence(for: first)?.cellHeightCandidates, [29, 30, 31, 32])
        XCTAssertEqual(store.evidence(for: second)?.cellHeightCandidates, [32, 33])
        XCTAssertNil(store.grid(for: first, viewportSize: CGSize(width: 1129, height: 118)))
        XCTAssertNil(store.grid(for: second, viewportSize: CGSize(width: 1129, height: 268)))
    }

    /// macOS recycles process identifiers, and the prune only runs when the frontmost application
    /// changes, so a process can die and be reborn between two of them. The start time is already in
    /// hand where the probe reads the device. The backing scale is in the key for a different reason:
    /// everything accumulated is in device pixels, and the same font on a display of another scale is
    /// a different number of them.
    func testARecycledProcessIdentifierAndAChangedScaleAreDifferentSurfaces() {
        let winsize = TerminalWinsize(rows: 7, columns: 140, heightInPixels: 228, widthInPixels: 2250)
        let original = TerminalSurfaceKey(
            processIdentifier: 1510, processStartedAt: 1789000000, ptyMinor: 0, ptyInode: 707, backingScale: 2
        )
        let reborn = TerminalSurfaceKey(
            processIdentifier: 1510, processStartedAt: 1789099999, ptyMinor: 0, ptyInode: 707, backingScale: 2
        )
        let otherDisplay = TerminalSurfaceKey(
            processIdentifier: 1510, processStartedAt: 1789000000, ptyMinor: 0, ptyInode: 707, backingScale: 1
        )
        var store = TerminalGridEvidenceStore()
        store.record(winsize, from: original, at: start)
        XCTAssertNil(store.evidence(for: reborn))
        XCTAssertNil(store.evidence(for: otherDisplay))
        XCTAssertEqual(store.surfaces.count, 1)

        store.record(winsize, from: reborn, at: start)
        store.record(winsize, from: otherDisplay, at: start)
        XCTAssertEqual(store.surfaces.count, 3)
    }

    /// A scale outside the band is a scale nothing should be keyed on, and a `NaN` one would key an
    /// entry that no later lookup could equal -- kept forever, found never.
    func testAnImplausibleScaleIsNotKeyedOn() {
        let winsize = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        var store = TerminalGridEvidenceStore()
        for scale in [CGFloat.nan, 0, 4] {
            let key = TerminalSurfaceKey(
                processIdentifier: 1510, processStartedAt: 1789000000,
                ptyMinor: 0, ptyInode: 707, backingScale: scale
            )
            XCTAssertEqual(store.record(winsize, from: key, at: start), .ignored)
        }
        XCTAssertTrue(store.surfaces.isEmpty)
    }

    /// A dead terminal's grid must not reach a live one, and the prune has to be callable
    /// unconditionally -- the session where the pty answers everything is exactly the session where a
    /// prune guarded by some other cache never runs.
    func testWhatADeadProcessLeavesBehindIsNothing() {
        let winsize = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        let alive = TerminalSurfaceKey(
            processIdentifier: 1510, processStartedAt: 1789000000, ptyMinor: 0, ptyInode: 707, backingScale: 2
        )
        let dead = TerminalSurfaceKey(
            processIdentifier: 2021, processStartedAt: 1789000001, ptyMinor: 4, ptyInode: 8525, backingScale: 2
        )
        var store = TerminalGridEvidenceStore()
        store.record(winsize, from: alive, at: start)
        store.record(winsize, from: dead, at: start)

        store.forgetProcesses(notIn: [1510])
        XCTAssertNotNil(store.evidence(for: alive))
        XCTAssertNil(store.evidence(for: dead))

        store.forgetSurfaces(notSeenSince: later(1))
        XCTAssertTrue(store.surfaces.isEmpty)

        store.record(winsize, from: alive, at: start)
        store.forgetEverything()
        XCTAssertTrue(store.surfaces.isEmpty)
    }

    /// The cap is what happens when the caller forgets to prune. Evicting costs only the narrowing,
    /// which the next resize rebuilds; the surface just read is never the one evicted.
    func testTheStoreKeepsABoundedNumberOfSurfaces() throws {
        let winsize = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
        var store = TerminalGridEvidenceStore()
        var newest: TerminalSurfaceKey?
        for index in 0..<(TerminalGridEvidenceStore.maximumSurfaces * 2) {
            let key = TerminalSurfaceKey(
                processIdentifier: Int32(1000 + index), processStartedAt: 1789000000,
                ptyMinor: Int32(index), ptyInode: UInt64(8000 + index), backingScale: 2
            )
            store.record(winsize, from: key, at: later(Double(index)))
            newest = key
            XCTAssertLessThanOrEqual(store.surfaces.count, TerminalGridEvidenceStore.maximumSurfaces)
        }
        XCTAssertEqual(store.surfaces.count, TerminalGridEvidenceStore.maximumSurfaces)
        XCTAssertNotNil(store.evidence(for: try XCTUnwrap(newest)))
    }
}
