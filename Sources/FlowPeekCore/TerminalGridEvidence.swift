import CoreGraphics
import Foundation

/// What is known about one terminal surface's cell, kept across the readings that surface has given
/// and narrowed by each new one.
///
/// `TerminalWinsize` brackets the cell from a single `ioctl(TIOCGWINSZ)`: the terminal truncates, so
/// `rows = floor(ws_ypixel / cell)` and the cell is an integer in `(ws_ypixel/(rows + 1),
/// ws_ypixel/rows]`. That bracket is about `cell/rows` wide, so it holds one integer only once there
/// are roughly as many rows as there are pixels in a cell. A large font in a short window is where it
/// fails, and it fails by refusing. Measured live on Ghostty 1.3.1, macOS 26, backing scale 2:
///
///     font-size 13   rows 40   ws_ypixel 1280   (31.220, 32.000]   {32}             pinned
///     font-size 17   rows 31   ws_ypixel 1324   (41.375, 42.710]   {42}             pinned
///     a 7-row pane   rows  7   ws_ypixel  228   (28.500, 32.571]   {29,30,31,32}    refused
///
/// The readings of one surface are all about the same cell for as long as the font does not change,
/// so they intersect, and an intersection only ever shrinks. Measured on the surface in
/// `TerminalWinsize`'s own doc comment, resized: 228 pixels over 7 rows gives `{29,30,31,32}` and 528
/// over 16 rows gives `{32,33}`; together they give 32, which is the cell the taller readings of the
/// same surface confirm. Measured again on a font-17 surface dragged through ten heights: 428 pixels
/// over 10 rows gives `{39,40,41,42}` and 452 over 10 gives `{42,43,44,45}`, so twelve points of drag
/// closed it. A drag is many readings -- the pty walk takes under half a millisecond and the survey
/// is re-taken on every rect change -- and the rule of thumb from seventeen-reading drags is that it
/// closes once the readings' `ws_ypixel` have spanned about one cell, that is, one row of resize.
///
/// This is not a second way of guessing. Every candidate it keeps is a candidate the terminal's own
/// arithmetic admits for every reading taken, so the answer, when there is one, is the unique integer
/// consistent with all of them. When there is more than one it refuses, which is what happens today.
///
/// ## Why an empty intersection starts over rather than failing
///
/// The font can change under a surface, and then the old readings are about a cell that no longer
/// exists. Measured, with `ws_ypixel`/`ws_xpixel` held at 1176/1268 across three font steps on one
/// surface: 28 rows gives `{41,42}`, then 26 rows gives `{44,45}`, then 25 rows gives `{46,47}`. The
/// sets are disjoint, and disjoint is the signal. It is a trustworthy one because the readings are
/// never torn: Ghostty writes the whole winsize in one `TIOCSWINSZ`, and all twenty-seven readings
/// taken across two resize series satisfied `rows == floor(ws_ypixel / cell)` exactly, mid-drag
/// included. So an empty intersection means the thing being measured changed, never a race, and the
/// newest reading alone is the whole of what is still known.
///
/// The other invalidation worth naming needs no code, because it is the same intersection. A cell is
/// in `cellPixels(spanning: span, cells: cells)` exactly when `floor(span / cell) == cells`, which is
/// a function of the cell alone, so two different row counts over one unchanged span give disjoint
/// brackets. That is the case caught live and unprompted on the user's own surface: `/dev/ttys000`
/// read `ws_ypixel 1280 ws_xpixel 2250 rows 40 cols 140` at the start of a session and
/// `ws_ypixel 1280 ws_xpixel 2250 rows 22 cols 80` an hour later -- byte-identical pixels, a
/// different grid -- and `{32}` against `{56,57,58}` is empty without anything having to notice that
/// the pixels were equal.
///
/// ## Both axes
///
/// The width is intersected too, and not only because a wrapped line needs it. It is the witness that
/// catches a font change the height alone would miss: measured on one surface at a fixed 1176/1268
/// span, the pinned width moved 21, 22, 23 across font steps, and on the live surface above it moved
/// 16 to 28. Height alone would have had to rely on its own set emptying. The width is also the axis
/// that can go ambiguous on a narrow split -- its bracket is about `cellWidth/columns` wide, singleton
/// in every reading taken here across cells 22 to 59 and column counts 45 to 162, but not by right.
///
/// ## What was measured and deliberately left out
///
/// - **The font metrics.** Ghostty's cell is `round(ascent + descent + leading)` and
///   `round(max advance over U+0020...U+007E)` at `font-size * backingScale`, which reproduced all 82
///   measured configurations exactly, seven of them held out. It is left out anyway, because it needs
///   the font family and there is no per-surface channel for one: Ghostty's default is a JetBrains
///   Mono compiled into the binary, absent from the bundle, from `+list-fonts` and from a full
///   `CTFontCollection` scan, and an unresolvable family name falls back to that same font, so a name
///   in a config file is not evidence. Worse, a wrong family does not refuse -- over all 375 wrong
///   pairings it answered a single wrong cell 8.5% of the time at 20 rows and 20.8% at 7 rows, and a
///   wrong cell is a pixel per row, one whole row of drift down a 40-row pane. `adjust-cell-height`
///   and `adjust-cell-width` void the formula outright (measured 30 to 33 pixels, 16 to 18) and leave
///   no trace in `ws_*`.
/// - **A per-font ratio between the two axes.** The continuous ratio is a font constant, but both
///   axes are rounded to whole device pixels independently, so the realized ratio wobbles by 0.125 to
///   0.186 across sizes within one family against a discrimination budget of `1/cellWidth`, about
///   0.063. Best-fit constants missed by 1.00 to 1.70 pixels -- precisely the quantity in dispute.
/// - **Intersecting readings across surfaces.** One Ghostty process owns one pty per split and per
///   tab and the splits can run different font sizes, so a sibling's reading may only be refused by
///   the existing pixel guard, never used to narrow this pane. That is what `TerminalSurfaceKey` is
///   for.
/// - **Any bound on how long this may go unclosed.** A pane that is never resized never closes and
///   FlowPeek keeps refusing, which is today's behaviour. Nothing here may be put on a path that
///   assumes an answer eventually arrives.
///
/// ## What this does not touch
///
/// Where the first row starts is still assumed to be half the total padding, because no number of
/// readings can say otherwise: `ws_ypixel` is the drawing area with the padding already removed, so
/// it carries the sum and nothing about the split. Two measured surfaces, one at
/// `window-padding-y = 5,1` and one at `1,5`, were identical in every observable -- `AXFrame`
/// 808x492, `AXContentSize` 808x4844, `rows 30 cols 100 ws_ypixel 972 ws_xpixel 1608` -- while their
/// true top paddings were 10 and 2 device pixels. Half the total is right for the symmetric default
/// and two points low for that user, a tenth of a row; it is a constant shift, not a drift, and it is
/// unchanged by anything in this file.
public struct TerminalGridEvidence: Equatable, Sendable {
    /// What a reading did to the evidence. Returned so a caller can log or test it; nothing about the
    /// answer depends on it.
    public enum Outcome: Equatable, Sendable {
        /// The reading has no grid in it -- an unset winsize, or a span and a cell count that no
        /// whole cell inside `TerminalWinsize.cellPixelRange` explains. It says nothing, so it
        /// changes nothing, not even the last-seen time.
        case ignored
        /// The first reading of this surface.
        case seeded
        /// Intersected with what was known. The candidate sets are this reading's brackets and
        /// everything before, which is to say they got no wider.
        case narrowed
        /// Everything before was discarded and this reading is now the whole of what is known. Either
        /// an intersection came out empty -- the cell changed underneath -- or the surface has not
        /// been seen for longer than `idleLimit`.
        case restarted
    }

    /// Whether the answer needed more than the reading it is being applied to.
    public enum Provenance: Equatable, Sendable {
        /// The newest reading's own bracket pinned both axes. This is a measurement of the pane in
        /// front of the user and nothing else, which is the only thing that may be written to a
        /// cross-session store: a remembered height outlives the process that produced it and is then
        /// applied to windows nobody measured.
        case singleReading
        /// It took earlier readings of the same surface to get here. True, and true only for as long
        /// as the font has not changed since the earliest reading still in the intersection, so it
        /// stays in memory and stays keyed to this surface.
        case accumulated
    }

    /// A grid, and where the certainty in it came from.
    public struct Answer: Equatable, Sendable {
        public let grid: TerminalCellGrid
        public let provenance: Provenance

        public init(grid: TerminalCellGrid, provenance: Provenance) {
            self.grid = grid
            self.provenance = provenance
        }

        /// Whether this may be remembered for a window that has not been measured.
        public var mayBeRemembered: Bool { provenance == .singleReading }
    }

    /// How long a surface may go unread before what is known about it is dropped.
    ///
    /// Not a measured number, and it buys nothing on its own: the intersection is already exact for
    /// every reading in it. What it bounds is the one way this can be wrong -- a font change small
    /// enough to leave the pinned width alone that happens in the same poll gap as a resize, so that
    /// neither the width nor an emptied set witnesses it. That leaves a confident wrong cell which
    /// persists until something restarts the evidence. Sixty seconds costs only the narrowing a
    /// resize rebuilds in a couple of polls.
    public static let idleLimit: TimeInterval = 60

    /// Every cell height in device pixels consistent with every reading taken. More than one is a
    /// guess and refuses; none of them means nothing has been recorded.
    public private(set) var cellHeightCandidates: Set<Int> = []
    /// The same for the cell width.
    public private(set) var cellWidthCandidates: Set<Int> = []
    /// The newest reading. The rows, the columns and the pixel spans always come from it and never
    /// from an older one: an older reading described a window of a different size, and it is the
    /// current one that has to be squared against the pane on screen.
    public private(set) var latest: TerminalWinsize?
    /// When that reading was taken, as the caller supplied it. This type has no clock of its own.
    public private(set) var lastSeen: Date?
    /// How many readings are behind the current candidate sets.
    public private(set) var readingCount: Int = 0

    public init() {}

    // MARK: - Recording

    /// Fold one reading into what is known.
    @discardableResult
    public mutating func record(_ winsize: TerminalWinsize, at now: Date) -> Outcome {
        let heights = TerminalWinsize.cellPixels(spanning: winsize.heightInPixels, cells: winsize.rows)
        let widths = TerminalWinsize.cellPixels(spanning: winsize.widthInPixels, cells: winsize.columns)
        // A reading with no bracket on either axis is not a reading of a grid. Terminals that never
        // report a pixel size answer zeroes, and a pair that needs a cell outside `cellPixelRange`
        // answers nothing either. Neither is evidence that the cell changed, so neither disturbs what
        // is known.
        guard !heights.isEmpty, !widths.isEmpty else { return .ignored }

        guard let seen = lastSeen else {
            seed(winsize, heights: heights, widths: widths, at: now)
            return .seeded
        }
        // A clock that went backwards is a clock this type cannot reason about, and a surface not
        // seen for a while may have been reconfigured while nobody was looking.
        guard now >= seen, now.timeIntervalSince(seen) <= Self.idleLimit else {
            seed(winsize, heights: heights, widths: widths, at: now)
            return .restarted
        }

        let narrowedHeights = cellHeightCandidates.intersection(heights)
        let narrowedWidths = cellWidthCandidates.intersection(widths)
        // Either axis emptying is the same event -- a font change moves both -- so both start over
        // together rather than one axis carrying history the other has just disproved.
        guard !narrowedHeights.isEmpty, !narrowedWidths.isEmpty else {
            seed(winsize, heights: heights, widths: widths, at: now)
            return .restarted
        }

        cellHeightCandidates = narrowedHeights
        cellWidthCandidates = narrowedWidths
        latest = winsize
        lastSeen = now
        readingCount += 1
        return .narrowed
    }

    private mutating func seed(
        _ winsize: TerminalWinsize,
        heights: Set<Int>,
        widths: Set<Int>,
        at now: Date
    ) {
        cellHeightCandidates = heights
        cellWidthCandidates = widths
        latest = winsize
        lastSeen = now
        readingCount = 1
    }

    // MARK: - What is known

    /// The cell height in device pixels, when every reading together admits exactly one.
    public var cellHeightInPixels: Int? {
        cellHeightCandidates.count == 1 ? cellHeightCandidates.first : nil
    }

    /// The cell width in device pixels, when every reading together admits exactly one.
    public var cellWidthInPixels: Int? {
        cellWidthCandidates.count == 1 ? cellWidthCandidates.first : nil
    }

    /// The grid the newest reading describes once the cell is known, or nil when it cannot be trusted
    /// to describe the pane that was measured.
    ///
    /// Every refusal in `TerminalWinsize.grid(viewportSize:scale:)` still applies and is still stated
    /// in device pixels before anything is divided by a scale that might be wrong. This adds one
    /// refusal of its own and takes none away: an accumulated cell that is not in the newest
    /// reading's own bracket is refused rather than used. That cannot happen while `record` only ever
    /// intersects -- which is the point. Evidence may delete candidates; it may never introduce one.
    /// Substituting instead of intersecting is the only way the error here stops being sub-row: the
    /// measured font step from a 32-pixel cell to a 42-pixel one is five points per row, two hundred
    /// points down a 40-row pane, and no guard in `grid` can see it.
    public func grid(viewportSize: CGSize, scale: CGFloat) -> Answer? {
        guard let latest,
              let cellHeight = cellHeightInPixels,
              let cellWidth = cellWidthInPixels
        else { return nil }
        guard let grid = latest.grid(
            viewportSize: viewportSize,
            scale: scale,
            cellHeightInPixels: cellHeight,
            cellWidthInPixels: cellWidth
        ) else { return nil }
        let pinnedAlone = latest.cellHeightInPixels == cellHeight && latest.cellWidthInPixels == cellWidth
        return Answer(grid: grid, provenance: pinnedAlone ? .singleReading : .accumulated)
    }
}

extension TerminalWinsize {
    /// The grid this reading describes, with the cell supplied rather than taken from this reading's
    /// own bracket.
    ///
    /// The same guards as `grid(viewportSize:scale:)`, in the same order, in the same units, plus one
    /// that the shipped entry point does not need: the cell handed in has to be a cell this reading
    /// admits. It is written out again rather than shared with the shipped path because the shipped
    /// path's first act is to derive the cell from this one reading, and the whole point of a
    /// narrowed cell is that one reading was not enough to derive it.
    ///
    /// The two are checked against each other in the tests: wherever a reading's own bracket closes,
    /// both produce the same grid.
    public func grid(
        viewportSize: CGSize,
        scale: CGFloat,
        cellHeightInPixels cellHeight: Int,
        cellWidthInPixels cellWidth: Int
    ) -> TerminalCellGrid? {
        guard rows > 0, columns > 0, heightInPixels > 0, widthInPixels > 0 else { return nil }
        guard scale.isFinite, Self.scaleRange.contains(scale) else { return nil }
        guard viewportSize.height.isFinite, viewportSize.width.isFinite,
              viewportSize.height > 0, viewportSize.width > 0 else { return nil }

        // Intersection, never substitution.
        guard Self.cellPixels(spanning: heightInPixels, cells: rows).contains(cellHeight),
              Self.cellPixels(spanning: widthInPixels, cells: columns).contains(cellWidth)
        else { return nil }

        let verticalPadding = viewportSize.height * scale - CGFloat(heightInPixels)
        let horizontalPadding = viewportSize.width * scale - CGFloat(widthInPixels)
        guard verticalPadding >= -Self.paddingSlackInPixels,
              horizontalPadding >= -Self.paddingSlackInPixels else { return nil }
        guard verticalPadding <= TerminalGridInference.paddingLimitRows * CGFloat(cellHeight),
              horizontalPadding <= TerminalGridInference.paddingLimitRows * CGFloat(cellWidth)
        else { return nil }

        let rowHeight = CGFloat(cellHeight) / scale
        let width = CGFloat(cellWidth) / scale
        guard TerminalPeekPolicy.rowHeightRange.contains(rowHeight) else { return nil }
        guard TerminalGridInference.aspectRange.contains(width / rowHeight) else { return nil }

        return TerminalCellGrid(
            rows: rows,
            columns: columns,
            rowHeight: rowHeight,
            cellWidth: width,
            topPadding: max(0, verticalPadding / (2 * scale))
        )
    }
}

/// Which surface a reading came from, exactly enough that one surface's history can never be folded
/// into another's.
///
/// The pty minor alone is not it. `/dev/ttys004` served at least six different Ghostty instances in
/// twenty minutes of measuring here, and intersecting one surface's readings with its successor's is
/// either empty, which is harmless, or a wrong survivor, which is not. What identifies a surface is
/// the devfs node of its slave, created when the pty is cloned and destroyed when it is released:
/// `/dev/ttys004` was inode 8525 for one instance, `No such file or directory` between them, and 8533
/// for the next. It costs no extra syscall, because the probe already has the descriptor open for its
/// one `ioctl`, and taking the inode from that descriptor also closes the recycle race between
/// finding the device and opening it. The master's own vnode is useless for this: its inode was 605
/// for two different instances' surfaces, and its creation time is the moment it is asked.
///
/// The process identifier is here for the obvious reason and its start time for the less obvious one:
/// macOS recycles process identifiers, and a dead terminal's grid reaching a live one would be
/// invisible. `proc_bsdinfo.pbi_start_tvsec` is already in hand where the probe reads the device.
///
/// The backing scale is part of the identity because everything accumulated is in device pixels, and
/// the same font on a display of a different scale is a different number of them.
public struct TerminalSurfaceKey: Hashable, Sendable {
    public let processIdentifier: Int32
    /// `proc_bsdinfo.pbi_start_tvsec`, seconds since the epoch.
    public let processStartedAt: UInt64
    /// The minor device number of the pty, which is recycled and therefore never used alone.
    public let ptyMinor: Int32
    /// The inode of the devfs slave node, from `fstat` on the descriptor already open for the ioctl.
    public let ptyInode: UInt64
    /// The backing scale of the screen the surface's window is on.
    public let backingScale: CGFloat

    public init(
        processIdentifier: Int32,
        processStartedAt: UInt64,
        ptyMinor: Int32,
        ptyInode: UInt64,
        backingScale: CGFloat
    ) {
        self.processIdentifier = processIdentifier
        self.processStartedAt = processStartedAt
        self.ptyMinor = ptyMinor
        self.ptyInode = ptyInode
        self.backingScale = backingScale
    }
}

/// What is known about every surface currently worth remembering.
///
/// It is deliberately separate from the pty survey cache. That cache is invalidated whenever the pane
/// or its rectangle changes, which is continuously during exactly the resize that produces the
/// readings this needs; hanging the evidence off it would make the whole thing a no-op that still
/// passed its unit tests.
///
/// Nothing in here is written to disk. A narrowed cell is true of one surface of one process for as
/// long as its font does not change, and none of those survive a launch.
public struct TerminalGridEvidenceStore: Equatable, Sendable {
    /// How many surfaces are worth keeping. One process owns one pty per split and per tab, and a
    /// long session opens and closes many; the pruning below is the caller's job and the cap is what
    /// happens when the caller does not do it. Evicting costs only the narrowing, which the next
    /// resize rebuilds.
    public static let maximumSurfaces = 32

    public private(set) var surfaces: [TerminalSurfaceKey: TerminalGridEvidence] = [:]

    public init() {}

    /// Fold one reading into what is known about the surface it came from.
    @discardableResult
    public mutating func record(
        _ winsize: TerminalWinsize,
        from key: TerminalSurfaceKey,
        at now: Date
    ) -> TerminalGridEvidence.Outcome {
        // A scale outside the band is a scale nothing should be keyed on -- and a NaN one would key
        // an entry that no later lookup could ever equal, so it would be kept forever and found
        // never.
        guard key.backingScale.isFinite, TerminalWinsize.scaleRange.contains(key.backingScale) else {
            return .ignored
        }
        var evidence = surfaces[key] ?? TerminalGridEvidence()
        let outcome = evidence.record(winsize, at: now)
        guard outcome != .ignored else { return .ignored }
        surfaces[key] = evidence
        evict(keeping: key)
        return outcome
    }

    public func evidence(for key: TerminalSurfaceKey) -> TerminalGridEvidence? {
        surfaces[key]
    }

    /// The grid known for one surface, measured against the pane on screen at that surface's own
    /// scale -- never `NSScreen.main`'s, and never a scale other than the one the readings were
    /// accumulated at, which is why the scale is in the key.
    public func grid(for key: TerminalSurfaceKey, viewportSize: CGSize) -> TerminalGridEvidence.Answer? {
        surfaces[key]?.grid(viewportSize: viewportSize, scale: key.backingScale)
    }

    public mutating func forget(_ key: TerminalSurfaceKey) {
        surfaces.removeValue(forKey: key)
    }

    /// Drop every surface of every process that is no longer running. Call it unconditionally: the
    /// one place this can leak into a live window is a process identifier that has been recycled, and
    /// a prune that is guarded by some other cache being non-empty is a prune that does not run in
    /// exactly the sessions the pty answers.
    public mutating func forgetProcesses(notIn alive: Set<Int32>) {
        surfaces = surfaces.filter { alive.contains($0.key.processIdentifier) }
    }

    /// Drop every surface not seen since `cutoff`.
    public mutating func forgetSurfaces(notSeenSince cutoff: Date) {
        surfaces = surfaces.filter { ($0.value.lastSeen ?? .distantPast) >= cutoff }
    }

    public mutating func forgetEverything() {
        surfaces.removeAll()
    }

    private mutating func evict(keeping key: TerminalSurfaceKey) {
        while surfaces.count > Self.maximumSurfaces {
            let oldest = surfaces
                .filter { $0.key != key }
                .min { ($0.value.lastSeen ?? .distantPast) < ($1.value.lastSeen ?? .distantPast) }
            guard let oldest else { return }
            surfaces.removeValue(forKey: oldest.key)
        }
    }
}
