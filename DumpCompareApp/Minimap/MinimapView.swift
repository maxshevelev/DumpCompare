import Cocoa

/// The minimap panel shown to the right of the hex panes (§19).
///
/// The panel is divided into maps that mirror the pane arrangement: one file =
/// one map, so single-file mode shows a single map over the whole panel;
/// side-by-side comparison splits the panel with a vertical divider at its exact
/// center (one map per pane); stacked comparison splits it with a horizontal
/// divider that mirrors the panes' draggable divider — the line moves as the
/// panes' divider moves.
///
/// A map draws the file as a miniature hex dump: the hex column only (no offset,
/// no ASCII), one cell per byte, `byteHeight` tall with `rowGap` between rows, so
/// the panel reads as a grid of pixels. Columns keep the hex dump's proportions
/// (two characters per byte, one-character gaps between words, two-character gap
/// between the 8-byte groups) scaled to the content width. Every byte gets its
/// own cell and its own colour — nothing is aggregated — coloured the way the hex
/// panes colour it and layered the same way: a byte that differs from the
/// companion gets an orange background over the whole cell, and the byte itself
/// is drawn on top — red when modified (`modifiedText`), ink when significant
/// (`byteText`), muted for a 0x00/0xFF fill (`mutedByteText`). The selection is a
/// translucent blue overlay on top (`selectionFill`), mirroring the panes.
///
/// **The scale is fixed**, so the file does *not* fit the panel: 3 pt per hex row
/// means a 1 MB file is ~197 000 pt tall while the panel shows ~200 rows. The map
/// is therefore a window onto the file, `topRow` being the first hex row drawn,
/// and it is *virtualized* — no cells are stored and only the visible rows are
/// ever read (`byteStates`), so a 4 GB file costs exactly what a 4 KB one does.
///
/// The window is not scrolled independently: it is derived from the panes, the
/// way VS Code's and Xcode's minimaps are (`updateTopRow`). Its position within
/// the file matches the panes' own, which puts the viewport band at the map's top
/// at the file's start and at its bottom at the file's end — so the band is
/// always fully on the map, and the map doubles as a proportional scrollbar the
/// band can be dragged along (`mouseDown`/`mouseDragged`, `onScrollToOffset`).
final class MinimapView: NSView, NSViewToolTipOwner {
    /// How the panel is divided into maps for the open file(s).
    enum MapLayout {
        /// One map over the whole panel (single-file mode, or nothing open).
        case single
        /// Comparison, side-by-side panes: two maps split by a vertical line
        /// at the panel's exact center.
        case sideBySide
        /// Comparison, stacked panes: two maps split by a horizontal line at
        /// the same proportion as the panes' divider (top = pane 1).
        case stacked(fraction: CGFloat)
    }

    /// One map: the file's size (for the byte→row mapping) and its selection.
    /// The cells are not here — they are pulled per repaint for the visible rows
    /// only, so a map of any file costs the same.
    struct Map {
        let fileSize: UInt64
        /// The file's current selection, drawn as an overlay on top of the
        /// cells; nil (or empty) when the caret sits alone.
        var selection: Range<UInt64>?
    }

    /// One piece of a pane's partition, as the strip beside the map paints it:
    /// the piece's byte range and which tint it wears (its index into
    /// `HexTheme.segmentTints`). The tint is by *position* — the piece's index
    /// in the partition — so the strip and the dump's row tints are the same
    /// legend, and a boundary on the strip is a boundary in the dump (§21.3).
    struct SegmentBlock: Equatable {
        let range: Range<UInt64>
        let colorIndex: Int
    }
    /// One mini hex row of the map: the per-byte state of each of its 1...16
    /// cells (the last row of a file holds fewer when its final hex row is short).
    struct ByteRow {
        let cells: [CellState]
    }

    /// The flags that colour a byte cell. A cell can carry any combination: a
    /// byte can be significant and modified, differ from the companion, and so
    /// on — the renderer layers them (diff is a background, the byte itself is
    /// drawn on top), matching the hex panes, which show modified (red ink) and
    /// difference (background) together.
    struct CellState: Equatable {
        /// The byte is not a 0x00/0xFF fill.
        var isSignificant: Bool
        /// The byte was modified since the file was last read from disk.
        var isModified: Bool
        /// The byte differs from the companion file.
        var isDifferent: Bool
        /// The byte belongs to an occurrence of the active search pattern
        /// (§11). A byte state like the two above, which is why it is drawn in
        /// the map's content and not in its margin.
        var isMatch: Bool
        /// The byte belongs to the *current* match — the one the find indicator
        /// marks in the dump.
        var isCurrentMatch: Bool

        static let insignificant = CellState(isSignificant: false, isModified: false, isDifferent: false)
        static let significant = CellState(isSignificant: true, isModified: false, isDifferent: false)

        init(isSignificant: Bool, isModified: Bool, isDifferent: Bool,
             isMatch: Bool = false, isCurrentMatch: Bool = false) {
            self.isSignificant = isSignificant
            self.isModified = isModified
            self.isDifferent = isDifferent
            self.isMatch = isMatch
            self.isCurrentMatch = isCurrentMatch
        }

        /// The cell for one byte of the dump. Significance is that byte's own —
        /// nothing is merged, so a single 0x00 among real content stays muted.
        init(_ state: HexByteState) {
            isSignificant = state.byte != 0x00 && state.byte != 0xFF
            isModified = state.isModified
            isDifferent = state.isDifferent
            isMatch = false
            isCurrentMatch = false
        }
    }

    /// How a map draws its file (§19.4).
    enum RenderMode: String {
        /// One cell per byte at a fixed scale: the map is a window onto the file
        /// around the panes' position. Reads like a miniature hex dump.
        case detail
        /// The whole file at once, one device pixel per row: the map is an
        /// overview of the dump's layout. A cell is a *slice* of the row's bytes
        /// coloured by how much of it is real content, so erased 0xFF padding,
        /// code and mixed regions separate at a glance.
        case overview
    }

    /// The overview's precomputed picture of one file: it cannot be pulled per
    /// repaint the way `detail` pulls its window, because every row is on screen
    /// at once — an 8 MB dump would be read on every draw. The controller
    /// computes this in the background and hands it over.
    ///
    /// Rows are binned over the *comparison's* extent (the longer of the open
    /// files), not each file's own length, so the same height means the same
    /// absolute offset on both maps (§9). Rows past a shorter file's end simply
    /// carry no content.
    struct OverviewSummary: Equatable {
        /// The extent the rows are binned over — the longest open file.
        let extent: UInt64
        let rowCount: Int
        /// `rowCount * 16` values, row-major: the share of bytes in that cell's
        /// slice that are not a 0x00/0xFF fill, 0...255.
        var density: [UInt8]
        /// Per row, a bit per column holding at least one modified byte.
        var modified: [UInt16]
        /// Per row, a bit per column holding at least one byte that differs from
        /// the companion.
        var different: [UInt16]

        static let empty = OverviewSummary(extent: 0, rowCount: 0, density: [],
                                          modified: [], different: [])
    }

    /// The search's matches as the overview draws them (§11): a bit per column
    /// per row, the same shape as `OverviewSummary`'s `modified` and
    /// `different` masks, so the stretch rule for a file smaller than one byte
    /// per row comes along for free (§19.4.2).
    ///
    /// A value of its own rather than a field of the summary, because its
    /// lifetime is different: the summary is invalidated by *bytes*, this by
    /// the *pattern*, and a new search must not trigger a density rebuild.
    struct MatchOverlay: Equatable {
        /// The extent the rows are binned over — the same one the summary uses.
        let extent: UInt64
        let rowCount: Int
        /// Per row, a bit per column holding at least one match.
        var matched: [UInt16]
        /// The same for the current match alone — the one the dump plates.
        var current: [UInt16]

        static let empty = MatchOverlay(extent: 0, rowCount: 0, matched: [], current: [])
    }

    /// How dark the overview draws its content. Deliberately short of full ink:
    /// the dump itself renders a dense row as *glyphs* on paper, which reads as a
    /// mid grey, and a byte that is a 0x00/0xFF fill is drawn muted rather than
    /// left blank. Mapping "all content" to solid black and "all padding" to bare
    /// paper turned the map into black islands on white; these bounds put it in
    /// the tonal range the dump beside it actually occupies (§19.4.2).
    static let overviewMinTone: CGFloat = 0.10
    static let overviewMaxTone: CGFloat = 0.55
    /// Lifts the low end so a sparse slice separates from an empty one instead of
    /// vanishing into the floor.
    static let overviewToneGamma: CGFloat = 0.75

    /// The render scale, fixed by design: a byte cell is `byteHeight` tall with
    /// `rowGap` between rows, so one hex row costs `rowStep` no matter how large
    /// the file is. This is what makes the map a window rather than an overview.
    static let byteHeight: CGFloat = 2
    static let rowGap: CGFloat = 1
    static var rowStep: CGFloat { byteHeight + rowGap }

    /// Bytes per hex row — the dump's row width, and the map's. `nonisolated`
    /// because the overview's background pass bins by it.
    nonisolated static let bytesPerRow: UInt64 = 16

    /// How many hex rows a map `areaHeight` tall can show: every row costs
    /// `byteHeight` plus a trailing `rowGap` except the last. Small heights
    /// collapse to zero rows (nothing fits).
    static func visibleRowCount(areaHeight: CGFloat) -> Int {
        guard areaHeight > 0 else { return 0 }
        return max(0, Int(floor((areaHeight + rowGap) / rowStep)))
    }

    /// Side inset of the maps' content from the panel's edges — the cells sit
    /// in a 10 pt frame on either side, matching the breathing room the hex
    /// panes give their dumps. Only horizontal: the rows run edge to edge top
    /// and bottom. The viewport band deliberately ignores this inset and runs
    /// edge to edge too (§19).
    static let contentPadding: CGFloat = 10

    /// In side-by-side mode the two maps sit on either side of an inner gutter
    /// this wide — a fraction of the panel's full width — so the minimap's
    /// split echoes the gap between the two side-by-side panes and the gap
    /// scales with the panel's own width.
    static let sideBySideGutterFraction: CGFloat = 0.05

    /// The colour strip's width — the legend beside each map that paints the
    /// partition at a glance (§19.4.4). Six points: wide enough to read as a
    /// swatch at a glance, narrow enough to stay a margin and not a second map.
    static let segmentStripWidth: CGFloat = 6

    /// The gap between the strip and the map's content — a sliver of paper that
    /// keeps the legend from crowding the dump it names, and that the render
    /// test checks is actually empty (nothing is painted in it).
    static let segmentStripGap: CGFloat = 2

    private(set) var mapLayout: MapLayout = .single
    /// The maps currently drawn (file sizes + selections). Readable so tests can
    /// inspect them.
    private(set) var maps: [Map] = []

    /// The per-pane partitions the strip beside each map paints, by map index.
    /// The strip is absent for a pane with a single piece (or no file): a single
    /// colour over a whole file is noise, the same rule the dump's row tint
    /// follows (§21.3) — so a one-piece pane stores its lone block but draws no
    /// strip, and the strip appears the moment a cut makes a second piece.
    private(set) var segmentBlocks: [[SegmentBlock]] = []

    /// The strip block under the pointer, if any — the one `drawSegmentStrip`
    /// paints with a more saturated shade, so the hovered piece reads as "the
    /// one under the cursor" without changing what colour it is (§19.4.4). Nil
    /// when the pointer is off every strip.
    private var hoveredStripBlock: (mapIndex: Int, pieceIndex: Int)?

    /// The tracking area that feeds the strip's hover highlight.
    private var stripTrackingArea: NSTrackingArea?

    /// The byte range each map's pane currently has visible, by map index —
    /// what the grey viewport band mirrors, and what the map's own window is
    /// derived from. A nil entry (or an empty range) means that pane's scroll
    /// viewport is empty (no file, or the pane shows no bytes).
    private(set) var viewports: [Range<UInt64>?] = []

    /// Whether the overview viewport is currently drawn as a rectangle over the
    /// content rather than the margin chevrons. Sticky across the 1 pt of
    /// overlap between `overviewBandShortHeight` and `overviewBandTallHeight` —
    /// the hysteresis that keeps a scroll hovering on the boundary from
    /// flickering between the two looks (§19.6).
    private var overviewUsesRectangle = false

    /// The first hex row drawn at the top of every map. One shared window for
    /// both maps: the panes are synchronized by absolute offset (§9), so the
    /// same offset must sit at the same y on both. Derived from the panes —
    /// never set from outside.
    private(set) var topRow: UInt64 = 0

    /// Which way the maps draw. Detail is the historical behaviour; overview is
    /// chosen for files too large for detail to say anything useful (§19.4).
    private(set) var renderMode: RenderMode = .detail

    /// The overview's data, by map index. Empty in detail mode, or while a
    /// background pass is still computing the first one for a file.
    private(set) var overviewSummaries: [OverviewSummary] = []

    /// True when the picture in `overviewSummaries` was binned over a different
    /// extent than the files now have — an edit changed the length of the longest
    /// one, so every row covers a slightly different slice.
    ///
    /// The picture is kept and stretched over the map (the same stand-in path a
    /// resize uses) until the background pass replaces it. Dropping it instead
    /// blanked the panel on every inserted byte, which is a worse lie than a
    /// picture that is a fraction of a percent out of date, and an irritating
    /// one: it blinked (§19.9).
    private(set) var overviewBinsAreStale = false

    /// One overlay per map, or empty when no search is running (§11).
    private(set) var matchOverlays: [MatchOverlay] = []

    /// Hands the panel the search's matches for the overview. Cheap enough to
    /// hand over whole: it is a couple of hundred bytes per map, derived from
    /// the match set rather than read from the file.
    func setMatchOverlays(_ overlays: [MatchOverlay]) {
        guard overlays != matchOverlays else { return }
        matchOverlays = overlays
        guard renderMode == .overview else { return }
        invalidateAll()
    }

    /// Fired when the number of overview rows the panel can show changes — a
    /// resize, a layout flip, or a switch into overview — so the controller can
    /// recompute the summary at the new density.
    var onOverviewRowCountChanged: (() -> Void)?

    /// Fired when the panel's height changes what the overview could say about
    /// the open file — it is worth showing only while a pixel row stands for at
    /// least one byte (§19.4). Unlike `onOverviewRowCountChanged` this fires in
    /// both modes, because the answer decides whether overview may be *entered*.
    var onOverviewUsefulnessChanged: (() -> Void)?

    /// Supplies the per-byte state the map paints, for one byte range of one
    /// map. Called from `draw` for the visible rows only — the map stores no
    /// cells, so this is the whole data path.
    var byteStates: ((_ mapIndex: Int, _ range: Range<UInt64>) -> [HexByteState])?

    /// The active search's matches inside a range of one map's file, pulled per
    /// repaint like the byte states — the map reads the same set the dump does,
    /// so the two cannot disagree about where the matches are (§11).
    var matchRanges: ((_ mapIndex: Int, _ range: Range<UInt64>) -> [Range<UInt64>])?
    /// The current match in one map's file, if any — what the dump marks with
    /// the find indicator.
    var currentMatchRange: ((_ mapIndex: Int) -> Range<UInt64>?)?

    /// Asks for the panes to scroll so that `offset`'s hex row sits at the top
    /// of the pane — the minimap's drag and wheel both go through it. The panes
    /// then report their new viewport, which slides the map's own window.
    var onScrollToOffset: ((UInt64) -> Void)?

    /// Adopts a new map split, redrawing the divider lines only when the split
    /// actually changed (a stacked fraction can move by a hair on every pane
    /// divider tick, so compare with tolerance).
    func setMapLayout(_ layout: MapLayout) {
        guard !mapLayout.equivalent(to: layout) else { return }
        mapLayout = layout
        // The strips move with the layout, so a hover on the old position is
        // stale: clear it (the next mouse move re-establishes it).
        hoveredStripBlock = nil
        updateTopRow()
        invalidateAll()
    }

    /// Switches how the maps draw. The overview's data is dropped on the way
    /// out and requested on the way in, so a stale picture is never shown.
    func setRenderMode(_ mode: RenderMode) {
        guard renderMode != mode else { return }
        renderMode = mode
        // A fresh mode starts with a fresh viewport look; the first height
        // decides it.
        overviewUsesRectangle = false
        if mode == .detail {
            overviewSummaries = []
            overviewBinsAreStale = false
            settleTimer?.invalidate()
            settleTimer = nil
            geometryIsSettling = false
        }
        overviewStandIns = [:]
        updateTopRow()
        invalidateAll()
        if mode == .overview { onOverviewRowCountChanged?() }
    }

    /// Adopts a freshly computed overview picture.
    func setOverviewSummaries(_ summaries: [OverviewSummary]) {
        guard overviewSummaries != summaries else {
            // Same picture, but it is the current one again: the bins it was
            // built over are the files' own extent now.
            overviewBinsAreStale = false
            return
        }
        overviewBinsAreStale = false
        let damage = overviewDamage(from: overviewSummaries, to: summaries)
        overviewSummaries = summaries
        overviewStandIns = [:]
        if let damage { invalidate(damage) } else { invalidateAll() }
    }

    /// Replaces the values for `rows` in one map's picture and repaints just
    /// them. This is how an edit reaches the overview: the rows a byte lands in
    /// are recomputed from the file, and the rest of the picture — the whole dump
    /// either side of it — is left alone (§19.9).
    func updateOverviewRows(_ rows: ClosedRange<Int>, density: [UInt8],
                            modified: [UInt16], different: [UInt16], forMapAt index: Int) {
        // A stale picture is not patched: its rows cover different slices of the
        // file than the caller measured, so the marks would land in the wrong
        // place. The pass that is already on its way replaces the whole thing.
        guard renderMode == .overview, !overviewBinsAreStale,
              overviewSummaries.indices.contains(index) else { return }
        let columns = Int(Self.bytesPerRow)
        var summary = overviewSummaries[index]
        guard rows.lowerBound >= 0, rows.upperBound < summary.rowCount,
              density.count == rows.count * columns, modified.count == rows.count,
              different.count == rows.count,
              summary.density.count >= (rows.upperBound + 1) * columns,
              summary.modified.count > rows.upperBound,
              summary.different.count > rows.upperBound else { return }
        summary.density.replaceSubrange((rows.lowerBound * columns)..<((rows.upperBound + 1) * columns),
                                        with: density)
        summary.modified.replaceSubrange(rows, with: modified)
        summary.different.replaceSubrange(rows, with: different)
        guard summary != overviewSummaries[index] else { return }
        overviewSummaries[index] = summary
        // The stretched stand-in for this map is now the old picture.
        overviewStandIns[index] = nil

        let area = contentArea(within: area(forMapAt: index), forMapAt: index)
        let rowHeight = overviewRowHeight
        guard rowHeight > 0, area.height > 0 else { return }
        let y = area.minY + CGFloat(rows.lowerBound) * rowHeight
        // One row of slack below: an event mark is two pixels tall, so a mark in
        // the last patched row paints into the row after it (§19.4.2).
        let height = min(CGFloat(rows.count + 1) * rowHeight, area.maxY - y)
        guard height > 0 else { return }
        invalidate([NSRect(x: area.minX, y: y, width: area.width, height: height)])
    }

    /// The rows two overview pictures disagree on, as rectangles — or nil when
    /// they are not comparable row for row (first picture, new file, resized
    /// panel) and the whole panel has to be repainted.
    ///
    /// A byte edit moves a handful of rows out of a thousand, so this is what
    /// keeps editing a big dump from repainting its whole picture (§19.9).
    private func overviewDamage(from old: [OverviewSummary],
                                to new: [OverviewSummary]) -> [NSRect]? {
        guard renderMode == .overview, old.count == new.count, maps.count == new.count,
              !new.isEmpty else { return nil }
        let rowHeight = overviewRowHeight
        guard rowHeight > 0 else { return nil }
        var rects: [NSRect] = []
        for index in new.indices {
            let (before, after) = (old[index], new[index])
            guard before.rowCount == after.rowCount, before.extent == after.extent,
                  before.density.count == after.density.count,
                  before.modified.count == after.modified.count,
                  before.different.count == after.different.count else { return nil }
            guard before != after else { continue }
            let area = contentArea(within: area(forMapAt: index), forMapAt: index)
            var row = 0
            while row < after.rowCount {
                guard Self.overviewRow(row, differsIn: before, and: after) else {
                    row += 1
                    continue
                }
                let start = row
                while row < after.rowCount,
                      Self.overviewRow(row, differsIn: before, and: after) { row += 1 }
                // An event cell is drawn two pixels tall, so the last changed
                // row also dirties the pixel row below it.
                rects.append(NSRect(x: area.minX,
                                    y: area.minY + CGFloat(start) * rowHeight,
                                    width: area.width,
                                    height: CGFloat(row - start + 1) * rowHeight))
            }
        }
        return rects
    }

    /// Whether one row's cells differ between two pictures of the same shape.
    private static func overviewRow(_ row: Int, differsIn before: OverviewSummary,
                                    and after: OverviewSummary) -> Bool {
        guard before.modified.indices.contains(row) else { return false }
        if before.modified[row] != after.modified[row] { return true }
        if before.different[row] != after.different[row] { return true }
        let columns = Int(bytesPerRow)
        let start = row * columns
        guard start + columns <= before.density.count else { return false }
        for column in start..<(start + columns) where before.density[column] != after.density[column] {
            return true
        }
        return false
    }

    /// One device pixel in this view's coordinates — the overview's row height,
    /// so a row is exactly as thin as the display can draw.
    var overviewRowHeight: CGFloat {
        1 / (window?.backingScaleFactor ?? 2)
    }

    /// How many overview rows the shortest map can show. Shared by both maps so
    /// the offset axis stays common (§9).
    func overviewRowCount() -> Int {
        guard !maps.isEmpty else { return 0 }
        let height = maps.indices.map { area(forMapAt: $0).height }.min() ?? 0
        guard height > 0, overviewRowHeight > 0 else { return 0 }
        return max(0, Int(floor(height / overviewRowHeight)))
    }

    /// Whether the detail window can show the whole file at once. False means
    /// detail would only ever show a sliver of it, which is when the overview
    /// earns its place (§19.4).
    func detailWindowFitsWholeFile() -> Bool {
        let rows = referenceRowCount()
        return rows == 0 || rows <= UInt64(max(0, windowRowCount()))
    }

    /// The size up to which detail is the more informative view, and a file
    /// opens in it (§19.4). A few hundred hex rows: a panel of any usual height
    /// shows most of such a file byte by byte, while the overview would have
    /// little left to compress. Fixed rather than derived from the panel's
    /// current height, so which mode a file opens in does not depend on the
    /// window's size at that moment.
    static let detailPreferredMaxSize: UInt64 = 4 * 1024

    /// Whether the overview would compress the file rather than magnify it: it
    /// is worth showing while every pixel row stands for at least one byte.
    ///
    /// Below that each byte is stretched over several rows — a blown-up smear of
    /// a file that detail shows whole, byte by byte, with real per-byte state. So
    /// the mode is not offered there at all (§19.4). An unlaid-out panel has no
    /// answer yet and counts as useful, so the switch is never disabled on the
    /// strength of geometry that does not exist.
    func overviewIsInformative() -> Bool {
        let rows = overviewRowCount()
        guard rows > 0 else { return true }
        return (maps.map(\.fileSize).max() ?? 0) >= UInt64(rows)
    }

    /// The overview picture for one map, if it is current.
    private func overviewSummary(forMapAt index: Int) -> OverviewSummary? {
        guard overviewSummaries.indices.contains(index) else { return nil }
        let summary = overviewSummaries[index]
        return summary.rowCount > 0 ? summary : nil
    }

    /// Replaces the per-pane partitions the strip paints. A cut, a removal, a
    /// rename's neighbour renumber, or a content edit that moves a cut all land
    /// here; the guard keeps a repaint out of the no-ops (a rename fires no
    /// invalidation, and neither does re-handing the same partition). Readable
    /// so tests can assert what the strip will draw.
    func setSegmentBlocks(_ blocks: [[SegmentBlock]]) {
        guard segmentBlocks != blocks else { return }
        segmentBlocks = blocks
        invalidateAll()
    }

    /// Replaces the maps (file sizes). Selections are re-applied by the caller
    /// afterwards — a rebuild and a selection change race.
    func setMaps(_ maps: [Map]) {
        // This runs on every edit, and an edit almost never changes a file's
        // size: bail out before the full repaint, and keep the selections the
        // fresh maps would otherwise drop until the caller re-applies them.
        guard maps.map(\.fileSize) != self.maps.map(\.fileSize) else { return }
        let oldExtent = self.maps.map(\.fileSize).max() ?? 0
        let newExtent = maps.map(\.fileSize).max() ?? 0
        let extentChanged = newExtent != oldExtent
        self.maps = maps
        updateTopRow()
        // A repaint only if the picture can actually look different. In overview
        // mode a typed byte moves the extent by one, which moves every row's
        // slice by a fraction of a byte and its own end by less than a pixel:
        // nothing to see, and repainting the panel for it cost 35-44 ms of main
        // thread per keystroke on two maps (§19.9). The marks an edit does make
        // visible invalidate their own rows.
        let rowSpan = renderMode == .overview
            ? max(newExtent, oldExtent) / UInt64(max(overviewRowCount(), 1))
            : 0
        let pictureMoved = renderMode != .overview
            || oldExtent.absoluteDifference(to: newExtent) >= max(rowSpan, 1)
        if pictureMoved {
            invalidateAll()
        }
        // The overview's bins are built over the longest file, so a change to
        // its length invalidates them — but the picture is kept, stale, and
        // stretched over the map until the background pass lands. The stand-in
        // images are built from it, so they are kept too.
        if renderMode == .overview, extentChanged {
            overviewBinsAreStale = true
            onOverviewRowCountChanged?()
        }
    }

    /// Moves one map's selection overlay. Cheap — no data rebuild — so it is
    /// safe to call on every caret/selection change (e.g. a mouse drag).
    func updateSelection(_ selection: Range<UInt64>?, forMapAt index: Int) {
        guard maps.indices.contains(index) else { return }
        guard maps[index].selection != selection else { return }
        let vacated = selectionRect(forMapAt: index)
        maps[index].selection = selection
        invalidate([vacated, selectionRect(forMapAt: index)].compactMap { $0 })
    }

    /// The strip one map's selection overlay covers, if any — the same geometry
    /// `drawSelection` paints, so an invalidation of it is exact.
    private func selectionRect(forMapAt index: Int) -> NSRect? {
        guard maps.indices.contains(index), let selection = maps[index].selection,
              !selection.isEmpty else { return nil }
        let area = contentArea(within: area(forMapAt: index), forMapAt: index)
        guard area.height > 0 else { return nil }
        let y0 = max(y(of: selection.lowerBound, in: area), area.minY)
        let y1 = min(y(of: selection.upperBound, in: area), area.maxY)
        guard y1 > y0 else { return nil }
        return NSRect(x: area.minX, y: y0, width: area.width, height: y1 - y0)
    }

    /// Repaints the cells that draw `range` of one map's file — the bytes an
    /// edit, an undo or a save just changed underneath the map. Detail mode
    /// pulls its cells from the panes as it draws, so a repaint is all it takes;
    /// overview paints a precomputed summary instead, and its own rebuild
    /// invalidates the rows that moved (§19.9).
    func invalidateBytes(in range: Range<UInt64>) {
        guard renderMode == .detail, !range.isEmpty else { return }
        // Whole rows, on every map: one byte is drawn as a cell in a row, and a
        // byte edited in one file changes the difference state the other map
        // paints at that same offset (§9).
        let firstRow = range.lowerBound / Self.bytesPerRow
        let lastRow = (range.upperBound - 1) / Self.bytesPerRow
        var rects: [NSRect] = []
        for index in maps.indices {
            let area = contentArea(within: area(forMapAt: index), forMapAt: index)
            guard area.height > 0 else { continue }
            let y0 = max(y(of: firstRow * Self.bytesPerRow, in: area), area.minY)
            let y1 = min(y(of: (lastRow + 1) * Self.bytesPerRow, in: area), area.maxY)
            guard y1 > y0 else { continue }   // the change is outside the window
            rects.append(NSRect(x: area.minX, y: y0, width: area.width, height: y1 - y0))
        }
        guard !rects.isEmpty else { return }
        invalidate(rects)
    }

    /// Repaints every cell of every map — for a change no byte range describes:
    /// an insert or delete that shifted the file, a save that cleared the red
    /// cells, a fresh comparison index.
    func invalidateCells() {
        guard renderMode == .detail else { return }
        invalidateAll()
    }

    /// The selection currently overlaid on a map (for tests).
    func selection(forMapAt index: Int) -> Range<UInt64>? {
        guard maps.indices.contains(index) else { return nil }
        return maps[index].selection
    }

    /// The visible byte range currently mirrored on a map (for tests).
    func viewport(forMapAt index: Int) -> Range<UInt64>? {
        guard viewports.indices.contains(index) else { return nil }
        return viewports[index]
    }

    /// Adopts the panes' visible byte ranges: moves the viewport band *and*
    /// slides the map's window, since the window is derived from the panes.
    func setViewports(_ viewports: [Range<UInt64>?]) {
        guard viewports != self.viewports else { return }
        // The area the old overlay occupied has to be repainted whether or not
        // the new one lands anywhere near it, so it is measured before the move.
        let vacated = viewportDamage()
        self.viewports = viewports
        if updateTopRow() {
            invalidateAll()
        } else {
            invalidate(vacated + viewportDamage())
        }
    }

    // MARK: - Bookmarks (§19.4.3, §20)

    /// The bookmarks the maps mark in their margins. One list for every map,
    /// because a bookmark is an absolute offset (§8): a marked row lands at the
    /// same height on both maps of a comparison, which is the whole point of
    /// sharing the list. Kept sorted by row, so the drawing order is the file's.
    ///
    /// The names ride along because a mark has no text of its own: hovering one
    /// names it (§19.4.3).
    private(set) var bookmarks: [Bookmark] = []

    /// Replaces the bookmarks. Only the margins the marks live in are repainted:
    /// a bookmark changes nothing about the file's picture, and repainting a
    /// full-dump overview to add one arrow is what §19.9 is about. A name that
    /// changed repaints nothing at all — the arrows have not moved — but the
    /// tooltip is re-registered, since it is the name that it reads out.
    func setBookmarks(_ marks: [Bookmark]) {
        let sorted = marks.sorted { $0.row < $1.row }
        guard sorted != bookmarks else { return }
        let rowsMoved = sorted.map(\.row) != bookmarks.map(\.row)
        bookmarks = sorted
        refreshBookmarkTooltip()
        guard rowsMoved else { return }
        invalidate(maps.indices.compactMap { bookmarkMargin(forMapAt: $0)?.strip })
    }

    /// The base of a bookmark's mark. Still smaller than the viewport marker's
    /// (`viewportMarkerSide`) — the two can share a margin and the viewport is the
    /// one the eye should find first — but a point wider than it first was: at 6 pt
    /// the arrow read as a speck beside the purple slab in the dump's gutter. The
    /// base is what grows, so the triangle stays equilateral and its reach across
    /// the margin grows with it. Internal so tests can sample a mark.
    static let bookmarkMarkSide: CGFloat = 7

    /// The strip a map's bookmark marks are drawn in, and which way they point.
    ///
    /// The marks live in the map's side margin — outside the content area, so a
    /// mark never covers a byte — pointing inward at the rows they mark, the way
    /// the overview's viewport chevrons do (§19.6). Which margin depends on the
    /// layout: side by side, the inner edges have no padding at all (the two
    /// dumps meet at the gutter), so map 1's marks go in its right margin and
    /// point left. Nil when the map has no margin to draw in.
    ///
    /// The segment strip owns the right margin when it is visible, so the marks
    /// keep to the left margin there — the strip's column is not paper they can
    /// share, and a mark past it would point at the strip, not the row it names.
    private func bookmarkMargin(forMapAt index: Int) -> (strip: NSRect, pointsRight: Bool)? {
        guard maps.indices.contains(index) else { return nil }
        let area = area(forMapAt: index)
        let content = contentArea(within: area, forMapAt: index)
        guard area.height > 0 else { return nil }
        let left = content.minX - area.minX
        var right = area.maxX - content.maxX
        // The strip's claim on the right margin (its gap plus its width) is not
        // paper the marks can use, so it is deducted before the wider-margin test.
        if segmentStripVisible(forMapAt: index) {
            right = max(0, right - (Self.segmentStripGap + Self.segmentStripWidth))
        }
        // The wider margin wins, so a layout that pads only one side is drawn on
        // that side; ties go left, which is where a reader looks first.
        if left >= right, left > 1 {
            return (NSRect(x: area.minX, y: area.minY, width: left, height: area.height), true)
        }
        if right > 1 {
            return (NSRect(x: content.maxX, y: area.minY, width: right, height: area.height), false)
        }
        return nil
    }

    /// The box a bookmarked row's mark occupies on map `index`, or nil when that
    /// map does not show the row: past the end of *its* file (§9 — a comparison's
    /// shorter file has no such row to mark), or outside the detail window.
    /// Shared by drawing, hit-testing and tests, so what is asserted is what is
    /// painted and what the pointer finds.
    func bookmarkMarkRect(row: UInt64, forMapAt index: Int) -> NSRect? {
        guard maps.indices.contains(index), let margin = bookmarkMargin(forMapAt: index) else {
            return nil
        }
        let fileSize = maps[index].fileSize
        guard fileSize > 0, row < fileSize else { return nil }
        let area = self.area(forMapAt: index)
        let content = contentArea(within: area, forMapAt: index)
        // The row's own y, from the same mapping the selection overlay uses, so
        // a mark and the row it marks cannot drift apart.
        let rowY = y(of: row, in: content)
        // A row the window has scrolled past is not marked. The row's own y is
        // what is tested, not the mark's box: half a mark hanging over the top
        // edge still belongs to a row that is on screen.
        guard rowY >= area.minY - Self.rowStep, rowY <= area.maxY else { return nil }
        return Self.marginMarkerBox(pointingRight: margin.pointsRight,
                                    apexAt: margin.pointsRight
                                        ? content.minX - Self.overviewMarkerInset
                                        : content.maxX + Self.overviewMarkerInset,
                                    midY: rowY + Self.byteHeight / 2,
                                    side: Self.bookmarkMarkSide)
    }

    /// Draws the bookmark marks: a small purple triangle per marked row in each
    /// map's margin, pointing at the row it marks. Purple is the bookmark colour
    /// throughout (§20.4), which keeps a mark apart from the grey viewport marker
    /// that can share the margin with it — the shape is the same, deliberately,
    /// because both say the same kind of thing about a position (§19.4.3).
    /// Marks the current match in the margin, in overview only (§11).
    ///
    /// At a row per 13 KB the match's yellow cells are one pixel tall and easy
    /// to miss, and the margin arrow is the shape the panel already uses for
    /// "the thing you are looking at is here" (§19.6). In detail the cells are
    /// exact and two points tall, so nothing is added there. Yellow is free in
    /// that margin: grey is the viewport, purple is a bookmark.
    private func drawCurrentMatchMarker(dirtyRect: NSRect) {
        guard renderMode == .overview else { return }
        for index in maps.indices {
            guard let match = currentMatchRange?(index),
                  let margin = bookmarkMargin(forMapAt: index),
                  margin.strip.intersects(dirtyRect),
                  // The mark is placed by offset; `bookmarkMarkRect` takes one.
                  let box = bookmarkMarkRect(row: match.lowerBound, forMapAt: index),
                  box.maxY >= dirtyRect.minY, box.minY <= dirtyRect.maxY else { continue }
            (HexTheme.findIndicatorFill.usingColorSpace(.deviceRGB)
                ?? HexTheme.findIndicatorFill).setFill()
            Self.marginMarkerPath(in: box, pointingRight: margin.pointsRight).fill()
        }
    }

    /// Where the current match's margin marker sits, for tests.
    func currentMatchMarkerRect(forMapAt index: Int) -> NSRect? {
        guard renderMode == .overview, let match = currentMatchRange?(index) else { return nil }
        return bookmarkMarkRect(row: match.lowerBound, forMapAt: index)
    }

    private func drawBookmarkMarks(dirtyRect: NSRect) {
        guard !bookmarks.isEmpty else { return }
        (HexTheme.bookmarkColor.usingColorSpace(.deviceRGB) ?? HexTheme.bookmarkColor).setFill()
        for index in maps.indices {
            guard let margin = bookmarkMargin(forMapAt: index),
                  margin.strip.intersects(dirtyRect) else { continue }
            for bookmark in bookmarks {
                guard let box = bookmarkMarkRect(row: bookmark.row, forMapAt: index),
                      box.maxY >= dirtyRect.minY, box.minY <= dirtyRect.maxY else { continue }
                Self.marginMarkerPath(in: box, pointingRight: margin.pointsRight).fill()
            }
        }
    }

    /// Paints the segment strip beside each map: one colour band per piece, from
    /// `HexTheme.segmentTints` — the same tints as the dump's own row background,
    /// so the 6 pt legend and the data it names agree on colour (§19.4.4). A band
    /// runs from one cut to the next, at the y the map's own rows use, so a
    /// boundary on the strip is a boundary in the dump. The block under the
    /// pointer is painted a louder shade of its own tint (§19.4.4). The gap
    /// beside the content is left unpainted: it is paper, not a piece.
    private func drawSegmentStrip(dirtyRect: NSRect) {
        for index in maps.indices {
            guard let strip = segmentStripRect(forMapAt: index),
                  strip.intersects(dirtyRect) else { continue }
            let area = area(forMapAt: index)
            let clip = strip.intersection(dirtyRect)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: strip).addClip()
            for (pieceIndex, block) in segmentBlocks[index].enumerated() {
                let y0 = stripY(of: block.range.lowerBound, in: area)
                let y1 = stripY(of: block.range.upperBound, in: area)
                guard y1 > y0 else { continue }
                let band = NSRect(x: strip.minX, y: y0, width: strip.width, height: y1 - y0)
                guard band.intersects(clip) else { continue }
                let tint = HexTheme.segmentTints[block.colorIndex % HexTheme.segmentTints.count]
                // The block under the pointer is painted a more saturated shade
                // of its own tint — the same colour, just louder, so the hovered
                // piece reads as "the one under the cursor" (§19.4.4).
                let isHovered = hoveredStripBlock?.mapIndex == index
                    && hoveredStripBlock?.pieceIndex == pieceIndex
                let fill = isHovered
                    ? HexTheme.saturatedHighlight(of: tint, in: effectiveAppearance)
                    : tint
                (fill.usingColorSpace(.deviceRGB) ?? fill).setFill()
                band.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - The margin markers' shape (§19.6, §19.4.3)

    /// An equilateral triangle's height for a base of `side` — what a marker
    /// reaches back from its apex.
    static func marginMarkerReach(side: CGFloat) -> CGFloat {
        side * sqrt(3) / 2
    }

    /// The box a margin marker occupies: `side` tall, centred on `midY`, and
    /// reaching back from `apexAt` toward the map's outer edge.
    static func marginMarkerBox(pointingRight: Bool, apexAt apexX: CGFloat,
                                midY: CGFloat, side: CGFloat) -> NSRect {
        let reach = marginMarkerReach(side: side)
        return NSRect(x: pointingRight ? apexX - reach : apexX,
                      y: midY - side / 2, width: reach, height: side)
    }

    /// The marker itself: an **equilateral** triangle pointing inward at the map,
    /// its base on the outer edge of `box` and its apex on the inner one. One
    /// shape for both markers — a viewport's position and a bookmark's row are
    /// the same kind of statement, so they are the same arrow, and only the size
    /// and the colour tell them apart (§19.6, §19.4.3).
    static func marginMarkerPath(in box: NSRect, pointingRight: Bool) -> NSBezierPath {
        let apexX = pointingRight ? box.maxX : box.minX
        let baseX = pointingRight ? box.minX : box.maxX
        let path = NSBezierPath()
        path.move(to: NSPoint(x: baseX, y: box.minY))
        path.line(to: NSPoint(x: apexX, y: box.midY))
        path.line(to: NSPoint(x: baseX, y: box.maxY))
        path.close()
        return path
    }

    // MARK: - Naming a mark on hover (§19.4.3)

    /// The one tooltip rect over the whole panel: the answer is computed from the
    /// pointer's position, so a mark that moves with a scroll, a mode switch or a
    /// resize needs no re-registration — only a change of the panel's own bounds
    /// or of the list does.
    private var bookmarkTooltipTag: NSView.ToolTipTag?

    private func refreshBookmarkTooltip() {
        if let tag = bookmarkTooltipTag {
            removeToolTip(tag)
            bookmarkTooltipTag = nil
        }
        guard !bookmarks.isEmpty, !bounds.isEmpty else { return }
        bookmarkTooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    /// The bookmark whose mark is under `point`, if any. The mark's own box is
    /// the target, grown a little: a 6 pt arrow in a 10 pt margin is a small
    /// thing to hit, and a tooltip that only answers on the pixel is a tooltip
    /// nobody sees.
    func bookmark(atMarkPoint point: NSPoint) -> Bookmark? {
        for index in maps.indices {
            for bookmark in bookmarks {
                guard let box = bookmarkMarkRect(row: bookmark.row, forMapAt: index) else { continue }
                if box.insetBy(dx: -2, dy: -2).contains(point) { return bookmark }
            }
        }
        return nil
    }

    /// The current name of a piece — the store fires no invalidation for a
    /// rename, so the strip asks for it at hover time rather than storing a copy
    /// that would go stale (§21.3).
    var segmentPieceName: ((_ mapIndex: Int, _ pieceIndex: Int) -> String)?

    /// The hover text for a point on the segment strip, or "" for none. A point
    /// within the snap distance of a cut names the boundary (the offset); a point
    /// over a piece names the piece — its label, range, size and name, the shape
    /// the form's list writes (§19.4.4, §21.4).
    func segmentStripTooltipText(at point: NSPoint) -> String {
        for index in maps.indices {
            guard let strip = segmentStripRect(forMapAt: index), strip.contains(point) else { continue }
            // A cut within the snap distance names the boundary, not the piece:
            // the pointer is on the line between two colours, and the line is
            // the more precise fact.
            if let (_, offset) = nearestCut(to: point, in: index) {
                return "0x\(String(offset, radix: 16).uppercased())"
            }
            guard let pieceIndex = segmentPiece(at: point, onMapAt: index) else { continue }
            let block = segmentBlocks[index][pieceIndex]
            let label = Segment.label(for: pieceIndex)
            let start = String(block.range.lowerBound, radix: 16).uppercased()
            let end = String(block.range.lastByte, radix: 16).uppercased()
            let size = FilePaneView.friendlySize(UInt64(block.range.count))
            var text = "\(label) — 0x\(start)…0x\(end), \(size)"
            if let name = segmentPieceName?(index, pieceIndex), !name.isEmpty {
                text += " · \(name)"
            }
            return text
        }
        return ""
    }

    /// What hovering the panel says: the segment strip's answer for a point on
    /// it, else a bookmark's for a point on its mark, else nothing (no tooltip).
    /// The strip is checked first: it is a legend the user reads, and its answer
    /// is the more specific one where the two could overlap (§19.4.4, §19.4.3).
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let stripText = segmentStripTooltipText(at: point)
        if !stripText.isEmpty {
            return stripText
        }
        guard let bookmark = bookmark(atMarkPoint: point) else { return "" }
        let address = bookmark.row.bareAddress
        return bookmark.name.isEmpty ? address : "\(address): \(bookmark.name)"
    }

    /// Marks only these rectangles for repaint. Scrolling calls into the panel
    /// on every wheel tick, and the maps themselves do not change between edits:
    /// in overview a full repaint would redraw a whole dump's picture — 16 cells
    /// per device pixel row — to move the viewport marker (§19.9).
    ///
    /// Correctness rests on `draw` painting *everything* that intersects the
    /// repaint region, which it does: each pass clips itself to `dirtyRect`, so
    /// a vacated strip comes back with its cells, divider and selection intact.
    private func invalidate(_ rects: [NSRect]) {
        lastRepaintRequest = rects.filter { !$0.isEmpty }
        repaintRequests += 1
        for rect in rects where !rect.isEmpty {
            // A pixel of slack on each side covers the anti-aliased edge of a
            // chevron or a band that does not land on a pixel boundary.
            setNeedsDisplay(rect.insetBy(dx: -1, dy: -1).intersection(bounds))
        }
    }

    /// Repaints the whole panel — for the changes that genuinely move every
    /// pixel: a new file, a mode or layout switch, a resize, a theme change.
    private func invalidateAll() {
        lastRepaintRequest = nil
        repaintRequests += 1
        needsDisplay = true
    }

    /// What the last change asked to repaint: the rectangles, or nil for the
    /// whole panel. Exists so the dirty-region rules can be asserted (§19.9) —
    /// "a scroll does not repaint the maps" is otherwise invisible to a test.
    private(set) var lastRepaintRequest: [NSRect]?

    /// How many repaints have been asked for, ever. `lastRepaintRequest` says
    /// *what*, but it is overwritten by the next request — and a change can
    /// reach the map as several — so a test that only needs "the map was told
    /// to repaint at all" watches this instead.
    private(set) var repaintRequests = 0

    /// Where the viewport overlay actually puts ink: the band itself in detail,
    /// and in overview either the band (when it is drawn as a rectangle) or the
    /// two margin chevrons — a sliver's rest of the band is deliberately never
    /// drawn there (§19.6).
    private func viewportDamage() -> [NSRect] {
        let rects = viewportRects()
        switch renderMode {
        case .detail: return rects
        case .overview:
            return rects.flatMap { band in
                overviewUsesRectangle(forHeight: band.height) ? [band] : overviewMarkerRects(for: band)
            }
        }
    }

    /// The overview viewport's current look for a band of `height` points.
    /// Below `overviewBandShortHeight` it is the margin chevrons, above
    /// `overviewBandTallHeight` it is the rectangle over the content, and in
    /// between it keeps whichever look it already has. The one-point overlap is
    /// the hysteresis: as a scroll pulls the band's height around the split, the
    /// style flips only when the height crosses an edge, never every frame
    /// (§19.6).
    private func overviewUsesRectangle(forHeight height: CGFloat) -> Bool {
        if height > Self.overviewBandTallHeight {
            overviewUsesRectangle = true
        } else if height < Self.overviewBandShortHeight {
            overviewUsesRectangle = false
        }
        return overviewUsesRectangle
    }

    /// The panel's quiet background — the same paper the hex dumps sit on, so
    /// the panel reads as part of the content area while idle.
    private static let background = NSColor.textBackgroundColor

    /// The divider between two maps — the same grey the pane split uses, so
    /// the minimap's internal split reads as an echo of the pane layout.
    private static let dividerFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.32, alpha: 1)
            : NSColor(white: 0.80, alpha: 1)
    }

    /// The viewport band's fill — a translucent grey that reads as a "you are
    /// here" band over the cells without hiding them. Lightened in dark
    /// appearance so it lifts off the near-black paper.
    private static let viewportFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.95, alpha: 0.16)
            : NSColor(white: 0.15, alpha: 0.14)
    }

    /// The viewport band's edges in overview, where the translucent fill alone
    /// is too faint to find: the same grey at full strength.
    private static let viewportEdge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.95, alpha: 0.75)
            : NSColor(white: 0.15, alpha: 0.65)
    }

    /// The maps draw top-down, matching the stacked panes' flipped coordinates
    /// (first pane on top), so a stacked divider lands at the same y as the
    /// panes' divider.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The map must not paint past its own edges. AppKit hands it a dirty
        // rect covering the *panel* — measured 49 pt above the map's own top,
        // the height of the header — and `clipsToBounds` is false by default,
        // so the background fill below reached the chrome and painted the mode
        // switch out of existence (§19.2).
        clipsToBounds = true
        applyBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The layer background is a *resolved* CGColor, so the one baked in
        // `init` — before the view is in a window — keeps the launch theme's
        // pixels through a light/dark switch. Re-resolve it against the current
        // appearance, the same way the Find bar and the results panel do
        // (§3.1). The dynamic colours used in `draw` resolve per paint already.
        applyBackgroundColor()
        // The stand-in has the old theme's colours baked into its pixels.
        overviewStandIns = [:]
        invalidateAll()
    }

    /// Resolves the panel's paper colour against the current appearance and
    /// paints the layer with it.
    private func applyBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.background.cgColor
        }
    }

    /// The strip's hover highlight needs mouse-moved events, which AppKit only
    /// delivers for a tracking area. The area covers the whole panel (the strip
    /// can sit in any map's margin or gutter), and `.inVisibleRect` keeps it
    /// glued to the bounds across a resize.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = stripTrackingArea {
            removeTrackingArea(area)
        }
        stripTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(stripTrackingArea!)
    }

    /// The strip block under `point`, if any — the map and piece whose strip the
    /// pointer is on. Reuses the strip's own hit-test, so the highlight names the
    /// same piece the tooltip and the menu do (§19.4.4).
    private func stripBlock(at point: NSPoint) -> (mapIndex: Int, pieceIndex: Int)? {
        for index in maps.indices {
            if let pieceIndex = segmentPiece(at: point, onMapAt: index) {
                return (index, pieceIndex)
            }
        }
        return nil
    }

    /// Sets the hovered strip block, repainting only the strips that change —
    /// the one the pointer left and the one it landed on. A hover is not a file
    /// change, so it must not repaint the maps (§19.9).
    private func setHoveredStripBlock(_ block: (mapIndex: Int, pieceIndex: Int)?) {
        guard hoveredStripBlock?.mapIndex != block?.mapIndex
            || hoveredStripBlock?.pieceIndex != block?.pieceIndex else { return }
        var rects: [NSRect] = []
        if let old = hoveredStripBlock, let strip = segmentStripRect(forMapAt: old.mapIndex) {
            rects.append(strip)
        }
        if let new = block, let strip = segmentStripRect(forMapAt: new.mapIndex) {
            rects.append(strip)
        }
        hoveredStripBlock = block
        invalidate(rects)
    }

    override func layout() {
        super.layout()
        // The tooltip covers the panel, so its rect follows the bounds.
        refreshBookmarkTooltip()
        // A resize changes how many rows fit, which moves the window, and
        // re-derives the divider's position from the new bounds.
        updateTopRow()
        invalidateAll()
        // A height change moves the line between a whole-file picture and a
        // magnified one, which decides whether overview is offered at all.
        let informative = overviewIsInformative()
        if informative != lastReportedOverviewUsefulness {
            lastReportedOverviewUsefulness = informative
            onOverviewUsefulnessChanged?()
        }
        // The overview bins the file into one row per pixel, so a height change
        // changes the bins themselves: the summary has to be recomputed.
        guard renderMode == .overview else { return }
        let rows = overviewRowCount()
        guard rows != lastReportedOverviewRowCount else { return }
        lastReportedOverviewRowCount = rows
        onOverviewRowCountChanged?()
    }

    /// Tracks the last answer reported, so a layout pass that changes nothing
    /// does not churn the controller.
    private var lastReportedOverviewUsefulness = true

    /// The row count the controller last computed a summary for, so a layout
    /// pass that changes nothing does not ask for a rebuild.
    private var lastReportedOverviewRowCount = 0

    override func draw(_ dirtyRect: NSRect) {

        super.draw(dirtyRect)
        // Since only the changed rectangles are invalidated (§19.9), a repaint
        // has to start from the panel's paper rather than from whatever the
        // previous frame left in the backing store — otherwise the chevron a
        // scroll moved away from would stay behind. Clipped to the repaint
        // region, so this is one small fill, not a full-panel one.
        Self.background.setFill()
        // Clipped explicitly as well as by `clipsToBounds`: the rect AppKit
        // passes here is the panel's, not the map's.
        dirtyRect.intersection(bounds).fill()
        // Three passes rather than one per map: side-by-side draws a single
        // viewport band across *both* maps, so the band cannot belong to a
        // per-map pass. Splitting the passes also keeps the layering — cells,
        // then the band, then the selection on top of it, so a selection inside
        // the viewport stays readable.
        for index in maps.indices {
            // The map's content (cells, selection) sits in a 10 pt side frame
            // away from the panel's side edges; the viewport band deliberately
            // runs edge to edge past it (§19).
            let content = contentArea(within: area(forMapAt: index), forMapAt: index)
            // A map the repaint does not reach is skipped whole. Side by side,
            // one map's rows are invalidated on their own — an edit belongs to
            // one file — and drawing the other map's thousand rows into a dirty
            // rect that excludes them cost 30 ms of the main thread (§19.9).
            guard content.intersects(dirtyRect) else { continue }
            switch renderMode {
            case .detail: drawCells(forMapAt: index, in: content, dirtyRect: dirtyRect)
            case .overview: drawOverviewRows(forMapAt: index, in: content, dirtyRect: dirtyRect)
            }
        }
        // The strip is a legend beside the content; the viewport band runs edge
        // to edge past it, so the band is painted over the strip to stay the
        // topmost "you are here" marker (§19.4.4).
        drawSegmentStrip(dirtyRect: dirtyRect)
        drawViewports(dirtyRect: dirtyRect)
        // The current match's own marker, under the bookmarks: a bookmark is
        // something the user placed, a match is where they happen to be
        // standing (§11).
        drawCurrentMatchMarker(dirtyRect: dirtyRect)
        // After the viewport, so a bookmark's mark is not buried under the grey
        // chevron when the two land in the same margin: there are few marks and
        // they are what the user put there on purpose.
        drawBookmarkMarks(dirtyRect: dirtyRect)
        for index in maps.indices {
            drawSelection(maps[index].selection,
                          in: contentArea(within: area(forMapAt: index), forMapAt: index),
                          dirtyRect: dirtyRect)
        }
        switch mapLayout {
        case .single:
            break
        case .sideBySide:
            // The band is a single rectangle *over* both maps, so the divider
            // yields to it: a 1 pt line painted across the band would put back
            // exactly the seam the shared band exists to remove (§19).
            // Only the detail band crosses the divider; the overview marks its
            // position in the margins, so the line stays whole there.
            drawVerticalDivider(at: bounds.midX, in: dirtyRect,
                                yielding: renderMode == .detail ? viewportRects() : [])
        case .stacked(let fraction):
            let y = min(max(fraction, 0), 1) * bounds.height
            drawHorizontalDivider(at: y, in: dirtyRect)
        }
    }

    // MARK: - The window onto the file

    /// The rows the shared window spans — the smallest of the maps', so the
    /// window (and the band inside it) fits every map. Stacked maps differ in
    /// height; side-by-side ones do not.
    private func windowRowCount() -> Int {
        maps.indices.map { Self.visibleRowCount(areaHeight: area(forMapAt: $0).height) }.min() ?? 0
    }

    /// Total hex rows of the longest open file — the extent the window slides
    /// over. The longer file is the comparison's extent, and its map is the one
    /// the shared viewport band is measured against (§19).
    private func referenceRowCount() -> UInt64 {
        let size = maps.map(\.fileSize).max() ?? 0
        return (size + Self.bytesPerRow - 1) / Self.bytesPerRow
    }

    /// Re-derives the window's first row from the panes.
    ///
    /// The window's position within the file matches the panes' own: at the
    /// file's start the window is at row 0, at its end the window's last row is
    /// the file's last. That is what keeps the viewport band fully on the map —
    /// it travels the map's height exactly once over the whole file — and it is
    /// how VS Code positions its minimap. A file short enough to fit sits at
    /// row 0 and the band moves inside it directly.
    /// Returns whether the window actually moved. A moved window slides the
    /// whole picture, so the caller has to repaint everything; an unmoved one
    /// leaves the cells where they are, and only the overlay that prompted the
    /// call needs redrawing (§19.9).
    @discardableResult
    private func updateTopRow() -> Bool {
        let newTop = derivedTopRow()
        guard newTop != topRow else { return false }
        topRow = newTop
        return true
    }

    private func derivedTopRow() -> UInt64 {
        // Overview shows the whole file, so there is no window to position.
        guard renderMode == .detail else { return 0 }
        let totalRows = referenceRowCount()
        let windowRows = UInt64(max(0, windowRowCount()))
        guard windowRows > 0, totalRows > windowRows else { return 0 }
        guard let visible = unifiedViewport() else { return 0 }
        let paneTop = visible.lowerBound / Self.bytesPerRow
        let paneRows = max(1, (visible.upperBound - visible.lowerBound + Self.bytesPerRow - 1)
            / Self.bytesPerRow)
        // The panes cannot scroll past this row, so it is the 100 % mark.
        guard totalRows > paneRows else { return 0 }
        let maxPaneTop = totalRows - paneRows
        let fraction = min(1, Double(min(paneTop, maxPaneTop)) / Double(maxPaneTop))
        return UInt64((fraction * Double(totalRows - windowRows)).rounded())
    }

    /// The byte range a map shows right now: the shared window clamped to that
    /// map's own file, so a map whose file ended higher up simply draws fewer
    /// rows (its EOF area stays empty).
    private func windowByteRange(forMapAt index: Int) -> Range<UInt64> {
        guard maps.indices.contains(index) else { return 0..<0 }
        let fileSize = maps[index].fileSize
        let rows = Self.visibleRowCount(areaHeight: area(forMapAt: index).height)
        guard rows > 0, fileSize > 0 else { return 0..<0 }
        let start = topRow.multipliedReportingOverflow(by: Self.bytesPerRow)
        guard !start.overflow, start.partialValue < fileSize else { return 0..<0 }
        let end = (topRow + UInt64(rows)).multipliedReportingOverflow(by: Self.bytesPerRow)
        let upper = end.overflow ? fileSize : min(end.partialValue, fileSize)
        return start.partialValue..<upper
    }

    /// The cells a map is showing, row by row — what `draw` paints. Internal so
    /// tests can assert the picture without reading pixels.
    func visibleCells(forMapAt index: Int) -> [ByteRow] {
        // Detail draws per-byte cells; overview has no such thing — it draws
        // density over slices, from a precomputed summary.
        guard renderMode == .detail else { return [] }
        let range = windowByteRange(forMapAt: index)
        guard !range.isEmpty, let states = byteStates?(index, range) else { return [] }
        // The window's matches as flags per byte, so marking a cell is a lookup
        // rather than a walk of the match list per byte.
        var matched = [Bool](repeating: false, count: states.count)
        var current = [Bool](repeating: false, count: states.count)
        func mark(_ flags: inout [Bool], _ match: Range<UInt64>) {
            let lower = max(match.lowerBound, range.lowerBound)
            let upper = min(match.upperBound, range.upperBound)
            guard lower < upper else { return }
            for offset in lower..<upper {
                let index = Int(offset - range.lowerBound)
                if index < flags.count { flags[index] = true }
            }
        }
        for match in matchRanges?(index, range) ?? [] { mark(&matched, match) }
        if let match = currentMatchRange?(index) { mark(&current, match) }

        var rows: [ByteRow] = []
        rows.reserveCapacity(states.count / Int(Self.bytesPerRow) + 1)
        var offset = 0
        while offset < states.count {
            let end = min(offset + Int(Self.bytesPerRow), states.count)
            var cells = states[offset..<end].filter { !$0.isEOF }.map(CellState.init)
            if cells.isEmpty { break }  // past EOF: no more rows to draw
            for column in cells.indices {
                cells[column].isMatch = matched[offset + column]
                cells[column].isCurrentMatch = current[offset + column]
            }
            rows.append(ByteRow(cells: cells))
            offset = end
        }
        return rows
    }

    // MARK: - Cells

    private func area(forMapAt index: Int) -> NSRect {
        let width = bounds.width
        let height = bounds.height
        switch mapLayout {
        case .single:
            return bounds
        case .sideBySide:
            // The two maps flank a 5 % gutter of the panel's full width,
            // centered on the panel; the divider line sits at the gutter's
            // centre (the panel's centre). Basing it on the whole width (not
            // the padded content) makes the gap scale with the panel's width.
            let innerGap = Self.sideBySideGutterFraction * max(0, width)
            let half = (width - innerGap) / 2
            if index == 0 {
                return NSRect(x: 0, y: 0, width: half, height: height)
            }
            return NSRect(x: half + innerGap, y: 0,
                          width: width - half - innerGap, height: height)
        case .stacked(let fraction):
            let split = min(max(fraction, 0), 1) * height
            if index == 0 {
                return NSRect(x: 0, y: 0, width: width, height: split)
            }
            return NSRect(x: 0, y: split, width: width, height: height - split)
        }
    }

    /// The padded region a map's content is drawn in: `area` inset by
    /// `contentPadding` on the sides only, so the file's lines sit in a frame
    /// away from the panel's side edges while running edge to edge top and
    /// bottom. In side-by-side mode each map keeps only its outer padding: the
    /// inner edges drop the inset so the two dumps meet at the gutter and the
    /// visible gap between them is exactly the 5 % gutter — which scales with
    /// the panel — rather than the gutter plus two fixed pads. Never negative
    /// (a tiny map just collapses to no content).
    ///
    /// When a map's segment strip is visible, the strip takes the inner edge of
    /// the gutter (see `segmentStripRect`), so the content is pulled in past it
    /// to leave the strip its `segmentStripGap` of paper on each side — the
    /// layout the user reads as Map – gap – strip – gap – separator (§19.4.4).
    ///
    /// The strip's own right edge sits `contentPadding` from the panel's right
    /// edge — the same inset the content carries on the left — so the margins
    /// read as symmetric: the content is framed by `contentPadding` on the left,
    /// and the strip (the rightmost element) by `contentPadding` on the right.
    /// The content's right edge is pulled in past the strip to make that room,
    /// leaving the strip its `segmentStripGap` of paper on the content side.
    private func contentArea(within area: NSRect, forMapAt index: Int) -> NSRect {
        let pad = Self.contentPadding
        // The strip's full claim on the right margin: its gap of paper plus its
        // own width. Added to the padding, it is how far the content's right
        // edge retreats so the strip can sit `contentPadding` from the edge.
        let stripSpan = Self.segmentStripGap + Self.segmentStripWidth
        switch mapLayout {
        case .single, .stacked:
            let rightInset = pad + (segmentStripVisible(forMapAt: index) ? stripSpan : 0)
            return NSRect(x: area.minX + pad, y: area.minY,
                          width: max(0, area.width - pad - rightInset),
                          height: area.height)
        case .sideBySide:
            // index 0 keeps the left pad (outer edge); its strip sits in the
            // gutter against the separator line, so the content's inner edge is
            // pulled in past it to leave the strip its gap of paper (§19.4.4).
            // index 1 keeps the right pad; its strip sits in its own right
            // margin (like a single map's), so the content's inner edge meets
            // the gutter and the strip lives in the outer padding.
            if index == 0 {
                let stripVisible = segmentStripVisible(forMapAt: index)
                let gutterSpan = Self.segmentStripGap * 2 + Self.segmentStripWidth
                let x = area.minX + pad
                let inner = stripVisible ? (bounds.midX - gutterSpan) : area.maxX
                return NSRect(x: x, y: area.minY,
                              width: max(0, inner - x), height: area.height)
            }
            let x = area.minX
            let rightInset = pad + (segmentStripVisible(forMapAt: index) ? stripSpan : 0)
            let inner = area.maxX - rightInset
            return NSRect(x: x, y: area.minY,
                          width: max(0, inner - x), height: area.height)
        }
    }

    // MARK: - The segment strip (§19.4.4)

    /// Whether the strip is drawn for a map: only when its pane is actually
    /// partitioned — two or more pieces. A single piece has nothing to separate,
    /// so the legend is absent, the same rule the dump's row tint follows
    /// (§21.3). The strip appears the moment a cut makes a second piece.
    func segmentStripVisible(forMapAt index: Int) -> Bool {
        segmentBlocks.indices.contains(index) && segmentBlocks[index].count > 1
    }

    /// The strip a map's partition is painted in, or nil when the pane is one
    /// piece (or the map is not laid out). It runs the map's full height, so a
    /// block's colour band sits at the same y as the rows it tints in the dump.
    ///
    /// Single and stacked maps paint it in the map's right margin, a
    /// `segmentStripWidth` column `segmentStripGap` of paper away from the
    /// content's right edge, its own right edge sitting `contentPadding` from
    /// the panel's right edge — the same inset the content carries on the left,
    /// so the panel's margins read as symmetric (§19.4.4). The content's right
    /// edge is pulled in past the strip to make that room (see `contentArea`),
    /// and the bookmark marks keep to the left margin the strip vacates.
    ///
    /// Side by side, the two maps' strips sit on opposite sides of the panel:
    /// the left map's strip is in the gutter against the separator line (the
    /// content is pulled in to make room — see `contentArea`), and the right
    /// map's strip is in its own right margin, exactly as a single map's is.
    /// Each strip is on the outer side of its own map, not tucked against the
    /// separator (§19.4.4).
    func segmentStripRect(forMapAt index: Int) -> NSRect? {
        guard segmentStripVisible(forMapAt: index) else { return nil }
        let area = area(forMapAt: index)
        guard area.height > 0 else { return nil }
        let x: CGFloat
        switch mapLayout {
        case .sideBySide where index == 0:
            // The left map's strip sits in the gutter against the separator line.
            x = bounds.midX - Self.segmentStripGap - Self.segmentStripWidth
        default:
            // Single, stacked, and the right map in side-by-side: the strip is in
            // the map's own right margin, `segmentStripGap` of paper from the
            // content's right edge. Because `contentArea` already pulled the
            // content in past the strip, its right edge lands `contentPadding`
            // from the panel's right edge — symmetric with the content's left
            // inset (§19.4.4).
            let content = contentArea(within: area, forMapAt: index)
            x = content.maxX + Self.segmentStripGap
            guard x + Self.segmentStripWidth <= area.maxX else { return nil }
        }
        return NSRect(x: x, y: area.minY, width: Self.segmentStripWidth, height: area.height)
    }

    /// The y a byte offset sits at on a map's strip — the same mapping the map's
    /// rows use, so a boundary on the strip is a boundary in the dump. Offsets
    /// above the window come out negative and below it past the map's height;
    /// the callers clip to the strip.
    private func stripY(of offset: UInt64, in area: NSRect) -> CGFloat {
        y(of: offset, in: area)
    }

    /// The overview's column geometry: 16 *contiguous* cells across the content
    /// width. Deliberately not the hex dump's proportions — a column here is a
    /// slice of the row's bytes, not a byte column, and the dump's word and group
    /// gaps turn into hard vertical bars once a row is one pixel tall, which made
    /// the map read as a barcode instead of a field. The columns stay decorative,
    /// so what is left is a continuous surface with faint seams (§19.4).
    private func overviewColumnLayout(in content: NSRect) -> [(x: CGFloat, width: CGFloat)] {
        let columns = Int(Self.bytesPerRow)
        guard content.width > 0, columns > 0 else { return [] }
        // Snapped to the device pixel grid in *absolute* coordinates, and each
        // cell measured to the next boundary rather than given one shared width.
        //
        // Both details matter, and each caused the same symptom — hairline
        // vertical stripes down a solid region. A shared width leaves gaps where
        // the snapped boundaries sit a pixel further apart; snapping relative to
        // the content instead of the view puts every boundary of the *second*
        // map mid-pixel, because its content starts after a gutter that is a
        // fraction of the panel's width.
        let pixel = overviewRowHeight
        func snap(_ column: Int) -> CGFloat {
            let x = content.minX + content.width * CGFloat(column) / CGFloat(columns)
            return (x / pixel).rounded() * pixel
        }
        let edges = (0...columns).map(snap)
        return (0..<columns).map { (x: edges[$0], width: max(pixel, edges[$0 + 1] - edges[$0])) }
    }

    /// The byte cells' geometry for a content region `areaWidth` wide: the x
    /// origin of each of the 16 byte columns and the shared cell width, both in
    /// the hex dump's proportions (two chars per byte, one-char word gap,
    /// two-char gap between the 8-byte groups) scaled so the full hex column
    /// spans the region exactly.
    private func byteColumnLayout(contentWidth: CGFloat)
        -> (origins: [CGFloat], cellWidth: CGFloat) {
        let wordSize = max(1, WordSize.current.rawValue)
        let bytesPerGroup = 8
        let wordsPerGroup = bytesPerGroup / wordSize
        let byteWidth: CGFloat = 2
        let wordGap: CGFloat = 1
        let groupGap: CGFloat = 2
        let wordWidth = CGFloat(wordSize) * byteWidth
        let groupWidth = CGFloat(wordsPerGroup) * wordWidth
            + CGFloat(wordsPerGroup - 1) * wordGap
        let hexColumnsWidth = 2 * groupWidth + groupGap
        let scale = hexColumnsWidth > 0 ? contentWidth / hexColumnsWidth : 0

        var origins: [CGFloat] = []
        origins.reserveCapacity(16)
        for column in 0..<16 {
            let group = column / bytesPerGroup
            let inGroup = column % bytesPerGroup
            let word = inGroup / wordSize
            let inWord = inGroup % wordSize
            let hexX = CGFloat(group) * (groupWidth + groupGap)
                + CGFloat(word) * (wordWidth + wordGap)
                + CGFloat(inWord) * byteWidth
            origins.append(hexX * scale)
        }
        return (origins, byteWidth * scale)
    }

    private func drawCells(forMapAt index: Int, in area: NSRect, dirtyRect: NSRect) {
        guard area.height > 0, area.width > 0 else { return }
        let rows = visibleCells(forMapAt: index)
        guard !rows.isEmpty else { return }
        let (origins, cellWidth) = byteColumnLayout(contentWidth: area.width)
        guard cellWidth > 0 else { return }
        let rowStep = Self.rowStep
        // Draw only the rows that intersect the dirty region, so a repaint of
        // one band's worth of rows doesn't re-fill the whole panel.
        let firstRow = max(0, Int(floor((dirtyRect.minY - area.minY) / rowStep)))
        let lastRow = min(rows.count - 1,
                          Int(floor((dirtyRect.maxY - area.minY) / rowStep)))
        guard lastRow >= firstRow else { return }
        for i in firstRow...lastRow {
            let y = area.minY + CGFloat(i) * rowStep
            for (j, state) in rows[i].cells.enumerated() {
                guard j < origins.count else { break }
                let rect = NSRect(x: area.minX + origins[j],
                                  y: y,
                                  width: cellWidth,
                                  height: Self.byteHeight)
                // Difference is a background *behind* the byte, so it has to be
                // taller than the byte or the opaque ink on top would hide it
                // completely — which is what happened while both used the same
                // rect: a difference only showed where the byte was a muted
                // (translucent) fill, i.e. never in real content. Filling the
                // whole row step leaves the inter-row gap orange, so a differing
                // run reads as a continuous orange band behind the bytes, while
                // the columns stay separated horizontally.
                // A match is a background too, and it layers where the dump
                // layers it (§6): under the difference, because telling two
                // dumps apart outranks it, and the current match over both,
                // because that is where the user is standing (§11). Each fills
                // the whole row step, like the difference, so a run of matches
                // reads as a continuous band behind the bytes.
                if state.isMatch {
                    HexTheme.matchFill.setFill()
                    NSRect(x: rect.minX, y: y, width: cellWidth, height: rowStep).fill()
                }
                if state.isDifferent {
                    HexTheme.differenceFill.setFill()
                    NSRect(x: rect.minX, y: y, width: cellWidth, height: rowStep).fill()
                }
                if state.isCurrentMatch {
                    HexTheme.findIndicatorFill.setFill()
                    NSRect(x: rect.minX, y: y, width: cellWidth, height: rowStep).fill()
                }
                // The byte itself is drawn on top of that background, so a
                // modified byte shows as red ink on orange, exactly as the hex
                // panes draw it. Over the indicator's fixed yellow the ink is
                // forced the way the dump forces it — `labelColor` there would
                // be white on yellow in dark mode.
                let color: NSColor
                if state.isCurrentMatch {
                    color = state.isModified ? HexTheme.modifiedText : HexTheme.indicatorInk
                } else {
                    color = state.isModified ? HexTheme.modifiedText
                        : (state.isSignificant ? HexTheme.byteText : HexTheme.mutedByteText)
                }
                color.setFill()
                rect.fill()
            }
        }
    }

    /// Draws one map's overview: a row per device pixel, each row's 16 cells
    /// shaded by how much real content their slice of bytes holds, with the rare
    /// and actionable states painted over the shading.
    ///
    /// Priority is density, then difference, then modified. A cell that is both
    /// differing and modified shows as modified: at hundreds of bytes per cell
    /// the two overlap often, and the red is the signal the user just created —
    /// the difference is still legible in the neighbouring cells of the same
    /// region. In detail mode both show at once, which is where that matters.
    private func drawOverviewRows(forMapAt index: Int, in area: NSRect, dirtyRect: NSRect) {
        guard area.width > 0, area.height > 0,
              let summary = overviewSummary(forMapAt: index) else { return }
        let rowHeight = overviewRowHeight
        guard rowHeight > 0 else { return }
        // While the frame is still moving, or until a resize's background pass
        // catches up with the new row count, the known picture is stretched over
        // the map instead of being redrawn cell by cell: exact is thousands of
        // fills, and a drag delivers a frame change per mouse move (§19.9).
        // The stand-in is for a picture whose *geometry* no longer matches the
        // panel — a resize, a frame still moving. A picture that is merely stale
        // in its bins (an edit moved the extent) has the right number of rows, so
        // it is drawn directly: stretching it 1:1 would be the same pixels, and
        // building the stand-in image costs 20 ms — per keystroke, since an edit
        // invalidates the cache (§19.9).
        if geometryIsSettling || summary.rowCount != overviewRowCount() {
            drawOverviewStandIn(forMapAt: index, in: area)
            return
        }
        let cells = overviewColumnLayout(in: area)
        guard !cells.isEmpty else { return }
        let first = max(0, Int(floor((dirtyRect.minY - area.minY) / rowHeight)))
        let last = min(summary.rowCount - 1, Int(floor((dirtyRect.maxY - area.minY) / rowHeight)))
        guard last >= first else { return }
        drawOverviewCells(summary, fileSize: maps.indices.contains(index) ? maps[index].fileSize : 0,
                          rows: first...last, top: area.minY, cells: cells, rowHeight: rowHeight)
        drawOverviewMatches(forMapAt: index, rows: first...last, top: area.minY,
                            cells: cells, rowHeight: rowHeight)
    }

    /// Marks the search's matches over the overview's density picture (§11).
    ///
    /// Like a difference, a match is drawn two pixel rows tall: one cell of a
    /// one-pixel row is invisible inside a dense region, so it spills into the
    /// next row rather than disappearing. The mark is a thinned version of the
    /// find indicator's yellow rather than the dump's grey — see
    /// `HexTheme.overviewMatchMark` — and the current match goes on top of it at
    /// full strength.
    private func drawOverviewMatches(forMapAt index: Int, rows: ClosedRange<Int>,
                                     top: CGFloat, cells: [(x: CGFloat, width: CGFloat)],
                                     rowHeight: CGFloat) {
        guard matchOverlays.indices.contains(index) else { return }
        let overlay = matchOverlays[index]
        guard overlay.rowCount > 0 else { return }
        let columns = Int(Self.bytesPerRow)
        let matchInk = (HexTheme.overviewMatchMark.usingColorSpace(.deviceRGB)
                         ?? HexTheme.overviewMatchMark)
        let currentInk = (HexTheme.findIndicatorFill.usingColorSpace(.deviceRGB)
                          ?? HexTheme.findIndicatorFill)

        for row in rows {
            guard overlay.matched.indices.contains(row) else { break }
            let matched = overlay.matched[row]
            let current = overlay.current.indices.contains(row) ? overlay.current[row] : 0
            guard matched != 0 || current != 0 else { continue }
            let y = top + CGFloat(row) * rowHeight
            // Neighbouring cells that draw the same thing are one fill, as in
            // the density pass: a run of matches is usually contiguous.
            var runColour: NSColor?
            var runFrom = 0
            var runTo = -1
            func flush() {
                guard let colour = runColour, runTo >= runFrom else {
                    runColour = nil
                    return
                }
                colour.setFill()
                NSRect(x: cells[runFrom].x, y: y,
                       width: cells[runTo].x + cells[runTo].width - cells[runFrom].x,
                       height: rowHeight * 2).fill()
                runColour = nil
            }
            for column in 0..<min(columns, cells.count) {
                let bit = UInt16(1) << UInt16(column)
                let colour: NSColor? = current & bit != 0 ? currentInk
                    : (matched & bit != 0 ? matchInk : nil)
                if colour === runColour, runTo == column - 1 {
                    runTo = column
                } else {
                    flush()
                    runColour = colour
                    runFrom = column
                    runTo = column
                }
            }
            flush()
        }
    }

    /// Draws one map's cells into the current context: `rows` of `summary`, the
    /// first of them starting at `top`, each `rowHeight` tall, with the columns
    /// laid out by `cells`.
    ///
    /// Shared by the on-screen pass and by the stand-in image (§19.9), which
    /// renders at one pixel per row through this same routine. That sharing is
    /// the point: composing the stand-in's colours by hand instead left it
    /// slightly more saturated than the picture it stands for, because this path
    /// blends through CoreGraphics in the window's colour space and 35 % orange
    /// over white does not land in the same place in plain sRGB arithmetic.
    private func drawOverviewCells(_ summary: OverviewSummary, fileSize: UInt64,
                                   rows: ClosedRange<Int>, top: CGFloat,
                                   cells: [(x: CGFloat, width: CGFloat)],
                                   rowHeight: CGFloat) {
        // The tone ramp, resolved once per pass rather than per cell: a full
        // overview is ~19 000 cells, and deriving each one's colour from the ink
        // was most of the cost of drawing it. Rebuilt every pass, so a theme
        // change still lands (the ink is a dynamic colour).
        // Resolved to concrete colours, not just derived once. The theme's inks
        // are dynamic (they answer per appearance), and `setFill()` on a dynamic
        // colour resolves it every single time — which, at one call per row of a
        // thousand-row map, was most of the 13-29 ms a map's cells took to draw.
        // Resolving here happens inside `draw`, so the appearance in force is
        // the right one.
        func resolved(_ colour: NSColor) -> NSColor {
            colour.usingColorSpace(.deviceRGB) ?? colour
        }
        let ink = HexTheme.byteText
        let tones = (0...255).map {
            resolved(ink.withAlphaComponent(Self.overviewTone(density: UInt8($0))))
        }
        let differenceInk = resolved(HexTheme.differenceFill)
        let modifiedInk = resolved(HexTheme.modifiedText)
        let columns = Int(Self.bytesPerRow)
        let extent = max(summary.extent, 1)
        func lastColumnInFile(rowStart: UInt64, span: UInt64) -> Int {
            Self.lastColumnInFile(rowStart: rowStart, span: span, fileSize: fileSize)
        }

        /// One fill across a row, up to where the file ends: what a row draws
        /// when a single colour covers all of it.
        func fillRow(_ colour: NSColor, y: CGFloat, rowStart: UInt64, span: UInt64) {
            let last = lastColumnInFile(rowStart: rowStart, span: span)
            guard last >= 0, let first = cells.first, cells.indices.contains(last) else { return }
            colour.setFill()
            NSRect(x: first.x, y: y,
                   width: cells[last].x + cells[last].width - first.x,
                   height: rowHeight * 2).fill()
        }

        // Consecutive rows that are one colour across their whole width are
        // filled together: an edited file's tail is a thousand red rows, and a
        // thousand fills of one pixel each cost the same as the picture they
        // replace. Only rows entirely inside the file join a run — the one or
        // two rows the file's end falls in are drawn on their own.
        var runColour: NSColor?
        var runFirstRow = 0
        var runLastRow = -1
        func flushRun() {
            guard let colour = runColour, runLastRow >= runFirstRow,
                  let first = cells.first, let last = cells.last else {
                runColour = nil
                return
            }
            colour.setFill()
            let y = top + CGFloat(runFirstRow) * rowHeight
            let height = CGFloat(runLastRow - runFirstRow) * rowHeight + rowHeight * 2
            NSRect(x: first.x, y: y,
                   width: last.x + last.width - first.x, height: height).fill()
            runColour = nil
        }

        for row in rows {
            let y = top + CGFloat(row) * rowHeight
            let modified = summary.modified.indices.contains(row) ? summary.modified[row] : 0
            let different = summary.different.indices.contains(row) ? summary.different[row] : 0
            let rowStart = extent * UInt64(row) / UInt64(summary.rowCount)
            let rowEnd = extent * UInt64(row + 1) / UInt64(summary.rowCount)
            let span = rowEnd - rowStart

            let wholeRow: NSColor? = modified != 0
                ? modifiedInk
                : (different == .max ? differenceInk : nil)
            if let colour = wholeRow, lastColumnInFile(rowStart: rowStart, span: span) == columns - 1 {
                if runColour === colour, runLastRow == row - 1 {
                    runLastRow = row
                } else {
                    flushRun()
                    runColour = colour
                    runFirstRow = row
                    runLastRow = row
                }
                continue
            }
            flushRun()

            // A row holding bytes the user changed is red across its whole width
            // (§19.4). Per cell the mark was drawn and unfindable: one edited
            // byte is one cell of sixteen in one row of a thousand, and at this
            // scale the column it happened in says almost nothing — a column of
            // a 16 MB dump's row is a kilobyte. Differences keep their per-cell
            // shading, which is what makes the shape of a run legible, except
            // when they cover the row whole and there is no shape to show.
            //
            // Both cases are also one fill instead of sixteen, which is what
            // keeps typing smooth: an insert leaves the whole tail modified and,
            // in a comparison, differing, so nearly every row is one of these —
            // and a full repaint of two maps' worth of cells took 138 ms on the
            // main thread, once per rebuild (§19.9).
            if modified != 0 {
                fillRow(modifiedInk, y: y, rowStart: rowStart, span: span)
                continue
            }
            if different == .max {
                fillRow(differenceInk, y: y, rowStart: rowStart, span: span)
                continue
            }

            // Neighbouring cells that draw the same thing are one fill. A dump's
            // rows are mostly uniform — sixteen cells of erased padding, sixteen
            // of dense content — so this is the difference between 40 000 fills
            // for two maps and a couple of thousand (§19.9).
            var cellColour: NSColor?
            var cellEvent = false
            var cellFrom = 0
            var cellTo = -1
            func flushCells() {
                guard let colour = cellColour, cellTo >= cellFrom else {
                    cellColour = nil
                    return
                }
                colour.setFill()
                NSRect(x: cells[cellFrom].x, y: y,
                       width: cells[cellTo].x + cells[cellTo].width - cells[cellFrom].x,
                       height: cellEvent ? rowHeight * 2 : rowHeight).fill()
                cellColour = nil
            }

            for column in 0..<columns {
                let bit = UInt16(1) << UInt16(column)
                let densityIndex = row * columns + column
                let density = summary.density.indices.contains(densityIndex)
                    ? summary.density[densityIndex] : 0
                let sliceStart = rowStart + span * UInt64(column) / UInt64(columns)
                // Past this file's end there is nothing of it to draw — not a
                // fill, not an event. That is what leaves the shorter file's
                // tail empty (§9).
                guard sliceStart < fileSize else { break }
                // An event is one cell of a one-pixel row, invisible inside a
                // dense region, so it is drawn two pixels tall — it spills into
                // the next row rather than disappearing.
                let isEvent = different & bit != 0
                let colour = isEvent ? differenceInk : tones[Int(density)]
                if cellColour === colour, cellEvent == isEvent, cellTo == column - 1 {
                    cellTo = column
                } else {
                    flushCells()
                    cellColour = colour
                    cellEvent = isEvent
                    cellFrom = column
                    cellTo = column
                }
            }
            flushCells()
        }
        flushRun()
    }

    /// The last column of a row that still belongs to a file of `fileSize`, for a
    /// row covering `span` bytes from `rowStart` — where a row-wide fill has to
    /// stop, because a map draws nothing of its file past its end (§9). Returns
    /// -1 for a row that begins past the end, and the last column for a row
    /// entirely inside the file.
    ///
    /// Internal so the rule can be tested directly: it decides a couple of cells
    /// in the single row a file's end falls in, which is not something pixel
    /// sampling catches reliably.
    static func lastColumnInFile(rowStart: UInt64, span: UInt64, fileSize: UInt64) -> Int {
        let columns = Int(bytesPerRow)
        guard fileSize > rowStart else { return -1 }
        let bytes = fileSize - rowStart
        guard bytes < span else { return columns - 1 }
        return min(columns - 1, Int(bytes * UInt64(columns) / max(span, 1)))
    }

    // MARK: - The stand-in picture across a resize (§19.9)

    /// The picture at its own natural resolution — one pixel per row, one per
    /// column — per map. Built from the summary rather than captured from the
    /// screen, so it survives any number of resizes, and thrown away when the
    /// summary or the theme changes.
    private var overviewStandIns: [Int: NSImage] = [:]

    /// Whether the frame is still being changed, and the picture should be
    /// stretched rather than redrawn. Any frame change counts, not just one that
    /// re-bins the file: dragging the panel's own width redraws the same rows at
    /// a new width, which is just as expensive and just as visible (§19.9).
    private var geometryIsSettling = false
    private var settleTimer: Timer?

    /// How long after the last frame change the exact picture is drawn. Short
    /// enough to feel immediate on mouse-up, long enough that a drag's stream of
    /// changes never pays for an exact repaint.
    static let geometrySettleDelay: TimeInterval = 0.12

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed, renderMode == .overview else { return }
        geometryIsSettling = true
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.geometrySettleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleGeometry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// The frame has stopped moving: draw the picture properly.
    private func settleGeometry() {
        settleTimer = nil
        guard geometryIsSettling else { return }
        geometryIsSettling = false
        invalidateAll()
    }

    /// How many times the stand-in has been drawn. A test seam: which of the two
    /// paths a repaint took is otherwise invisible.
    private(set) var standInDraws = 0

    /// Stretches the known picture over the map's current area. Nearest
    /// neighbour, not smoothing: this stands in for exact pixels, so it should
    /// read as the same picture at a coarser scale rather than as a blur.
    private func drawOverviewStandIn(forMapAt index: Int, in area: NSRect) {
        guard let image = overviewStandIn(forMapAt: index) else { return }
        standInDraws += 1
        let context = NSGraphicsContext.current
        let interpolation = context?.imageInterpolation ?? .default
        context?.imageInterpolation = .none
        // `respectFlipped` is not the default, and this view is flipped (row 0 is
        // the file's start, at the top): without it the stand-in came out
        // mirrored top to bottom until the exact pass replaced it.
        image.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
        context?.imageInterpolation = interpolation
    }

    /// Renders one map's summary into an image, or returns the one already built:
    /// the picture at its own natural resolution, one pixel per row and per
    /// column, drawn by the same routine that draws it on screen.
    ///
    /// Called from `draw`, so the dynamic inks resolve against the appearance in
    /// force; `viewDidChangeEffectiveAppearance` drops the cache.
    private func overviewStandIn(forMapAt index: Int) -> NSImage? {
        if let cached = overviewStandIns[index] { return cached }
        guard let summary = overviewSummary(forMapAt: index) else { return nil }
        let columns = Int(Self.bytesPerRow)
        let rows = summary.rowCount
        guard rows > 0, columns > 0 else { return nil }
        // Composited in the window's own colour space, not a generic one: the
        // translucent fills are blended by CoreGraphics in whatever space the
        // destination uses, and 35 % orange over white lands in a slightly
        // different place in sRGB than in the display's wider gamut — enough to
        // see the stand-in as the more saturated of the two.
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let cgContext = CGContext(data: nil, width: columns, height: rows,
                                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let context = NSGraphicsContext(cgContext: cgContext, flipped: false)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // A bitmap context has its origin at the bottom; flip it so a row's y is
        // the same expression the view uses, and row 0 lands at the top.
        cgContext.translateBy(x: 0, y: CGFloat(rows))
        cgContext.scaleBy(x: 1, y: -1)
        let bounds = NSRect(x: 0, y: 0, width: CGFloat(columns), height: CGFloat(rows))
        Self.background.setFill()
        bounds.fill()
        drawOverviewCells(summary,
                          fileSize: maps.indices.contains(index) ? maps[index].fileSize : 0,
                          rows: 0...(rows - 1), top: 0,
                          cells: (0..<columns).map { (x: CGFloat($0), width: 1) },
                          rowHeight: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgContext.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: columns, height: rows))
        overviewStandIns[index] = image
        return image
    }

    /// The ink alpha for a cell holding `density` content, mapped into the tonal    /// The ink alpha for a cell holding `density` content, mapped into the tonal
    /// band the dump itself occupies rather than the full paper-to-black range.
    static func overviewTone(density: UInt8) -> CGFloat {
        let fraction = CGFloat(density) / 255
        let shaped = fraction > 0 ? pow(fraction, overviewToneGamma) : 0
        return overviewMinTone + (overviewMaxTone - overviewMinTone) * shaped
    }

    // MARK: - Overlays

    /// The y a byte offset sits at inside a map, in the map's own coordinates.
    /// Offsets above the window come out negative and below it past the map's
    /// height — the callers clip.
    private func y(of offset: UInt64, in area: NSRect) -> CGFloat {
        switch renderMode {
        case .detail:
            let row = Double(offset) / Double(Self.bytesPerRow)
            return area.minY + CGFloat(row - Double(topRow)) * Self.rowStep
        case .overview:
            // The whole extent spans the drawn rows, so an offset is a fraction
            // of it. Binned over the *longest* file so both maps share the axis.
            let extent = overviewExtent()
            let rows = overviewRowCount()
            guard extent > 0, rows > 0 else { return area.minY }
            let fraction = min(1, Double(offset) / Double(extent))
            return area.minY + CGFloat(fraction) * CGFloat(rows) * overviewRowHeight
        }
    }

    /// The byte extent the overview's rows are binned over: the longest open
    /// file, so the same height means the same absolute offset on both maps.
    private func overviewExtent() -> UInt64 {
        maps.map(\.fileSize).max() ?? 0
    }

    /// The "you are here" band(s) the panel draws, as rectangles — the geometry
    /// `draw` fills. Internal so tests can assert the band's shape and position
    /// without reading pixels.
    ///
    /// Side-by-side returns exactly ONE rectangle spanning the whole panel: the
    /// panes scroll in lockstep by absolute offset (§9), so a band per map — cut
    /// in two by the gutter between them — read as a broken overlay rather than
    /// one viewport. Both maps share one window and one scale, so the single
    /// band is exact for both.
    ///
    /// Single-file and stacked return one band per map. Stacked cannot share a
    /// band: its maps sit above each other, so the two bands are at different y
    /// by construction and one rectangle over both would swallow the divider and
    /// everything between them.
    func viewportRects() -> [NSRect] {
        switch mapLayout {
        case .single, .stacked:
            return maps.indices.compactMap { index in
                viewportRect(unifiedViewport(), in: area(forMapAt: index))
            }
        case .sideBySide:
            guard !maps.isEmpty else { return [] }
            return viewportRect(unifiedViewport(), in: bounds).map { [$0] } ?? []
        }
    }

    /// The visible byte range across both panes. Synchronized scrolling reports
    /// the same offsets in both (§9), except the shorter file clamps its range
    /// at its own EOF, so the union is what the two panes actually have on
    /// screen. Robust if the two ever drift apart: the band then covers both.
    private func unifiedViewport() -> Range<UInt64>? {
        let ranges = viewports.compactMap { $0 }.filter { !$0.isEmpty }
        guard !ranges.isEmpty else { return nil }
        let lower = ranges.map(\.lowerBound).min() ?? 0
        let upper = ranges.map(\.upperBound).max() ?? 0
        guard lower < upper else { return nil }
        return lower..<upper
    }

    /// One band's rectangle: the visible rows laid out at the map's own fixed
    /// scale, from the window's first row. It runs edge to edge on every side —
    /// the full width of `area` (poking past the padded cells) and the visible
    /// rows' own height — and is clipped to the map. No minimum height: at this
    /// scale the band is as tall as the rows it stands for (a pane showing one
    /// row gets one row), and the pane always shows several.
    private func viewportRect(_ viewport: Range<UInt64>?, in area: NSRect) -> NSRect? {
        guard let viewport, !viewport.isEmpty, area.height > 0 else { return nil }
        var y0 = max(y(of: viewport.lowerBound, in: area), area.minY)
        var y1 = min(y(of: viewport.upperBound, in: area), area.maxY)
        if renderMode == .overview {
            // A visible page of an 8 MB dump is a small fraction of a pixel, so
            // in overview the band gets a floor — two device pixels, enough to
            // carry its edge lines — and reads as a position marker rather than
            // an extent (§19.6).
            let floorHeight = 2 * overviewRowHeight
            if y1 - y0 < floorHeight {
                y1 = min(y0 + floorHeight, area.maxY)
                y0 = max(y1 - floorHeight, area.minY)
            }
        }
        guard y1 > y0 else { return nil }
        return NSRect(x: area.minX, y: y0, width: area.width, height: y1 - y0)
    }

    /// Fills the bands that intersect the repaint region. Drawn under the
    /// selection overlay so a selection inside the viewport stays readable.
    private func drawViewports(dirtyRect: NSRect) {
        let rects = viewportRects()
        guard !rects.isEmpty else { return }
        let visible = rects.filter { $0.maxY >= dirtyRect.minY && $0.minY <= dirtyRect.maxY }
        guard !visible.isEmpty else { return }
        switch renderMode {
        case .detail:
            Self.viewportFill.setFill()
            for rect in visible { rect.fill() }
        case .overview:
            // A band tall enough to carry its own edges is drawn as a real
            // rectangle over the content, exactly like the detail band: the
            // cells stay visible through the translucent fill. Only a sliver —
            // a large file's visible page is less than a row — falls back to
            // the margin chevrons, where a rectangle would hide a row of the
            // picture for nothing. The split carries hysteresis (§19.6): every
            // map's band is the same height, so one decision covers them all.
            if let first = visible.first, overviewUsesRectangle(forHeight: first.height) {
                Self.viewportFill.setFill()
                for rect in visible { rect.fill() }
            } else {
                drawOverviewViewportMarkers(visible, dirtyRect: dirtyRect)
            }
        }
    }

    /// Marks the viewport's position with a chevron in each outer margin, pointing
    /// inward, level with the middle of the visible slice. The chevrons run
    /// almost the whole `contentPadding` margin, stopping `overviewMarkerInset`
    /// short of the map's content edge — the arrow points *at* the map it marks
    /// without touching it, and a sliver of paper keeps it from crowding the
    /// cells. Painted the same grey as the band's edges, so the marker belongs
    /// to the viewport overlay rather than to the file's picture.
    private func drawOverviewViewportMarkers(_ rects: [NSRect], dirtyRect: NSRect) {
        Self.viewportEdge.setFill()
        for band in rects {
            for (slot, box) in overviewMarkerRects(for: band).enumerated() {
                guard box.maxY >= dirtyRect.minY, box.minY <= dirtyRect.maxY else { continue }
                // The left marker points right, the right one points left: both
                // aim at the content between them.
                Self.marginMarkerPath(in: box, pointingRight: slot == 0).fill()
            }
        }
    }

    /// The band heights that switch the overview viewport between its two
    /// looks. The two edges overlap by 1 pt: a band growing past
    /// `overviewBandTallHeight` becomes a rectangle over the content (like the
    /// detail band), shrinking below `overviewBandShortHeight` becomes the
    /// margin chevrons, and a height between the two keeps whichever look it
    /// already has. The overlap is the hysteresis that stops a scroll hovering
    /// on the boundary from flickering between rectangle and chevrons. Internal
    /// so tests can pick heights on either side.
    static let overviewBandShortHeight: CGFloat = 4
    static let overviewBandTallHeight: CGFloat = 5

    /// The base of the viewport marker's triangle — big enough to find at a
    /// glance on a full-dump overview, small enough to stay an index rather than
    /// a cover, and small enough that an equilateral triangle's height still fits
    /// the margin it points across. Internal so tests can measure the shape.
    static let viewportMarkerSide: CGFloat = 9

    /// The paper left between the marker's apex and the map's content edge.
    /// The arrow points at the map without reaching it, so the marker costs the
    /// map no detail. Internal so tests can sample around the marker.
    static let overviewMarkerInset: CGFloat = 2

    /// The two boxes the markers occupy, level with the middle of the band: an
    /// equilateral triangle's box either side, apex `overviewMarkerInset` short
    /// of the map's content edge. Shared by drawing and by invalidation, which is
    /// what keeps a scroll's repaint this small. Internal so a test can measure
    /// the viewport marker against a bookmark's mark (§19.6) — the two must be
    /// the same arrow at two sizes, and nothing else exposes this one's geometry.
    func overviewMarkerRects(for band: NSRect) -> [NSRect] {
        let side = Self.viewportMarkerSide
        let inset = Self.overviewMarkerInset
        guard Self.marginMarkerReach(side: side) + inset <= Self.contentPadding else { return [] }
        return [Self.marginMarkerBox(pointingRight: true,
                                     apexAt: band.minX + Self.contentPadding - inset,
                                     midY: band.midY, side: side),
                Self.marginMarkerBox(pointingRight: false,
                                     apexAt: band.maxX - Self.contentPadding + inset,
                                     midY: band.midY, side: side)]
    }

    private func drawSelection(_ selection: Range<UInt64>?, in area: NSRect, dirtyRect: NSRect) {
        guard let selection, !selection.isEmpty, area.height > 0 else { return }
        var y0 = y(of: selection.lowerBound, in: area)
        var y1 = y(of: selection.upperBound, in: area)
        y0 = max(y0, area.minY)
        y1 = min(y1, area.maxY)
        guard y1 > y0, y1 >= dirtyRect.minY, y0 <= dirtyRect.maxY else { return }
        HexTheme.selectionFill.setFill()
        NSRect(x: area.minX, y: y0, width: area.width, height: y1 - y0).fill()
    }

    /// Draws the 1 pt line between two side-by-side maps, broken wherever one of
    /// `yielding` crosses it — the viewport band, which is drawn as one
    /// rectangle over both maps and must read as unbroken. The line resumes
    /// below the band, so the split between the maps is still legible.
    private func drawVerticalDivider(at x: CGFloat, in dirtyRect: NSRect,
                                     yielding gaps: [NSRect] = []) {
        guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { return }
        Self.dividerFill.setFill()
        let top = min(dirtyRect.maxY, bounds.maxY)
        let bottom = max(dirtyRect.minY, bounds.minY)
        guard top > bottom else { return }
        // Walk down the line, emitting the segments the gaps leave behind. Only
        // gaps that actually cross this x can break it.
        var y = bottom
        for gap in gaps.filter({ $0.minX <= x && $0.maxX >= x }).sorted(by: { $0.minY < $1.minY }) {
            if gap.minY > y {
                NSRect(x: x, y: y, width: 1, height: min(gap.minY, top) - y).fill()
            }
            y = max(y, gap.maxY)
            if y >= top { return }
        }
        guard top > y else { return }
        NSRect(x: x, y: y, width: 1, height: top - y).fill()
    }

    private func drawHorizontalDivider(at y: CGFloat, in dirtyRect: NSRect) {
        guard y >= dirtyRect.minY - 1, y <= dirtyRect.maxY + 1 else { return }
        Self.dividerFill.setFill()
        let right = min(dirtyRect.maxX, bounds.maxX)
        let left = max(dirtyRect.minX, bounds.minX)
        guard right > left else { return }
        NSRect(x: left, y: y, width: right - left, height: 1).fill()
    }

    // MARK: - Accessibility (§15, §19)

    /// The panel is one accessible element, not a grid of thousands of byte
    /// cells: a 2 pt cell carries nothing a reader can use on its own, while the
    /// panel as a whole has something worth saying — which part of the file the
    /// panes are on. Every navigation it offers with the pointer is available
    /// from the keyboard in the panes themselves (§10), so it is deliberately not
    /// a keyboard focus stop; VoiceOver reaches it by exploring the window.
    ///
    /// A hidden panel is collapsed to zero width rather than removed from the
    /// hierarchy, so it has to opt out explicitly — otherwise a minimap the user
    /// has turned off would still be announced.
    override func isAccessibilityElement() -> Bool { bounds.width >= 1 }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityRoleDescription() -> String? { "minimap" }

    override func accessibilityLabel() -> String? { "Minimap" }

    /// What the panes are showing, in the terms the hex dump announces (hex
    /// offsets, size in bytes) — that is the actionable fact here, since the
    /// map's own window follows the panes rather than moving on its own.
    override func accessibilityValue() -> Any? {
        guard !maps.isEmpty else { return "No file open." }
        let sizes = maps.map(\.fileSize)
        let sizeText = sizes.count > 1
            ? "File sizes \(sizes[0]) and \(sizes[1]) bytes."
            : "File size \(sizes[0]) bytes."
        guard let visible = unifiedViewport() else {
            return "Nothing visible. " + sizeText
        }
        let start = String(visible.lowerBound, radix: 16).uppercased()
        let end = String(visible.upperBound, radix: 16).uppercased()
        let subject = maps.count > 1 ? "Panes" : "Pane"
        return "\(subject) showing 0x\(start) through 0x\(end). " + sizeText
    }

    override func accessibilityHelp() -> String? {
        "Drag the highlighted band to scroll the file. "
            + "Click elsewhere on the map to move the cursor to that byte."
    }

    // MARK: - Dragging the viewport (§19)

    /// Where in the band the drag was grabbed, in points from the band's top, so
    /// the band keeps its grip on the cursor for the whole drag. Nil when no
    /// drag is in flight.
    private var dragGrabOffset: CGFloat?

    /// Brings `offset` into view in `mapIndex`'s pane, centred, and makes that
    /// pane the active one. The map draws real bytes, so a click on one means
    /// "take me to that byte".
    ///
    /// It moves neither the caret nor the selection: a click on the map
    /// navigates, and where the caret was left is not the map's to change (§19).
    /// The band's drag goes through `onScrollToOffset` instead — a scrollbar
    /// gesture, which scrolls without activating a pane.
    var onSelectOffset: ((_ mapIndex: Int, _ offset: UInt64) -> Void)?

    /// The right-click menu for a point on the segment strip, built by the
    /// controller to act on the piece under it (§21.3). Nil when the point is not
    /// on a strip piece, or the controller offers no menu.
    var segmentStripMenu: ((_ mapIndex: Int, _ pieceIndex: Int, _ point: NSPoint) -> NSMenu?)?

    /// The byte offset a y on a map stands for — the inverse of `y(of:in:)`. In
    /// detail the window's first row is the base; in overview the whole extent
    /// spans the drawn rows. Clamped to the file's start.
    private func offset(atY y: CGFloat, in area: NSRect) -> UInt64 {
        switch renderMode {
        case .detail:
            let row = Double(max(0, y - area.minY)) / Double(Self.rowStep) + Double(topRow)
            return UInt64(row) * Self.bytesPerRow
        case .overview:
            let extent = overviewExtent()
            let rows = overviewRowCount()
            guard extent > 0, rows > 0 else { return 0 }
            let fraction = min(1, max(0, (y - area.minY) / (CGFloat(rows) * overviewRowHeight)))
            return UInt64(fraction * Double(extent))
        }
    }

    /// The piece under a point on map `index`'s strip, by the byte the point's y
    /// stands for — the inverse of the strip's own y mapping, so the piece a
    /// hover or a right-click names is the one whose colour is under the pointer.
    /// Nil when the point is not on the strip, or past the file's end.
    func segmentPiece(at point: NSPoint, onMapAt index: Int) -> Int? {
        guard let strip = segmentStripRect(forMapAt: index), strip.contains(point) else { return nil }
        let area = area(forMapAt: index)
        let offset = offset(atY: point.y, in: area)
        guard offset < maps[index].fileSize else { return nil }
        return segmentBlocks[index].firstIndex { $0.range.contains(offset) }
    }

    /// The pointer moved over the panel: update the strip's hover highlight.
    /// The highlight is the only thing a move changes — the maps and the band
    /// are untouched, so no scroll and no caret move ride on a hover.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredStripBlock(stripBlock(at: point))
    }

    /// The pointer left the panel: clear the strip's hover highlight.
    override func mouseExited(with event: NSEvent) {
        setHoveredStripBlock(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The segment strip positions like the map does: a click on it means
        // "take me here" — the pane goes to the byte the click's y stands for,
        // or to the nearest cut's exact offset when one is in reach (§19.4.4).
        // Checked before the band, which runs edge to edge and would otherwise
        // swallow the strip's clicks as a drag.
        if let (mapIndex, offset) = segmentStripClick(at: point) {
            onSelectOffset?(mapIndex, offset)
            return
        }
        let bands = viewportRects()
        if let band = bands.first(where: { $0.contains(point) }) {
            // The band is the drag handle: grabbing it starts a scroll, so the
            // press must not also be read as a "take me here" jump.
            dragGrabOffset = point.y - band.minY
            return
        }
        // Off the band: the click means the byte drawn under it — or the row of a
        // bookmark whose mark it landed near (§19.6) — so the pane centres on it.
        // The drag then continues from the band's middle, so the press can still
        // turn into a scroll.
        if let (mapIndex, offset) = snappedOffset(at: point) {
            onSelectOffset?(mapIndex, offset)
        }
        // The band comes from the panes' reported visible range, so it can be
        // missing while the map itself is already drawing cells. That must not
        // swallow the click — it is the gesture that says "take me here" — so
        // only the drag depends on a band, measured after the click has moved
        // the panes.
        dragGrabOffset = (bands.first ?? viewportRects().first).map { $0.height / 2 }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = dragGrabOffset, let height = viewportRects().first?.height else { return }
        let point = convert(event.locationInWindow, from: nil)
        requestScroll(bandTop: point.y - grab, bandHeight: height)
    }

    /// How near a bookmark's mark a click may land and still mean that bookmark
    /// (§19.6). Internal so tests can click just inside and just outside it.
    static let bookmarkSnapDistance: CGFloat = 4

    /// How near the top or bottom edge of a map a click may land and still mean
    /// the file's start or end (§19.7). The overview is proportional, so the
    /// exact start and end are single pixels at the very top and bottom — hard to
    /// hit. A small zone at each edge snaps to the start or end, the way a cut's
    /// snap distance makes a segment boundary reachable (§19.4.4). Internal so
    /// tests can click just inside and just outside it.
    static let fileEdgeSnapDistance: CGFloat = 4

    /// What a click on the panel means: the row of a bookmark whose mark it
    /// landed on or near, else the file's start or end when the click is in the
    /// edge zone, else the byte drawn under it (§19.6, §19.7).
    ///
    /// Snapping is what makes a mark on a full-dump overview reachable at all: a
    /// row there is kilobytes, so the pointer can be dead on the arrow and still
    /// resolve to an offset a dozen rows off the bookmark. The mark is the target
    /// the user aimed at, and this is the only place that reads it that way —
    /// dragging the band is a scrollbar gesture and never snaps, since a
    /// continuous scroll that jumped to a bookmark would fight the drag.
    func snappedOffset(at point: NSPoint) -> (mapIndex: Int, offset: UInt64)? {
        nearestBookmarkMark(to: point) ?? fileEdgeOffset(at: point) ?? byteOffset(at: point)
    }

    /// The file's start or end a click in the top or bottom edge zone of a map
    /// stands for, in overview mode: the top zone means the file's first byte,
    /// the bottom zone its last. The overview is proportional, so the exact start
    /// and end are single pixels at the very top and bottom — hard to hit. A
    /// small zone at each edge snaps to the start or end, the way a cut's snap
    /// distance makes a segment boundary reachable (§19.4.4). The offset is
    /// snapped to the file's own bounds, so a shorter file's bottom zone means
    /// its own last byte, not the longer file's end. Nil when the point is not in
    /// either zone (or the mode is not overview), so the caller falls through to
    /// the proportional offset.
    private func fileEdgeOffset(at point: NSPoint) -> (mapIndex: Int, offset: UInt64)? {
        guard renderMode == .overview else { return nil }
        let distance = Self.fileEdgeSnapDistance
        for index in maps.indices {
            let area = area(forMapAt: index)
            guard area.contains(point) else { continue }
            if point.y - area.minY <= distance {
                guard maps[index].fileSize > 0 else { return nil }
                return (index, 0)
            }
            if area.maxY - point.y <= distance {
                guard maps[index].fileSize > 0 else { return nil }
                return (index, maps[index].fileSize - 1)
            }
        }
        return nil
    }

    /// The bookmark whose mark is nearest `point`, within the snap distance of
    /// it. Nearest by the mark's own centre line: two marks a few rows apart on
    /// an overview can both be in range, and the one aimed at is the closer.
    private func nearestBookmarkMark(to point: NSPoint) -> (mapIndex: Int, offset: UInt64)? {
        var best: (mapIndex: Int, offset: UInt64, distance: CGFloat)?
        for index in maps.indices {
            for bookmark in bookmarks {
                guard let box = bookmarkMarkRect(row: bookmark.row, forMapAt: index),
                      box.insetBy(dx: -Self.bookmarkSnapDistance,
                                  dy: -Self.bookmarkSnapDistance).contains(point) else { continue }
                let distance = abs(point.y - box.midY)
                if best == nil || distance < best!.distance {
                    best = (index, bookmark.row, distance)
                }
            }
        }
        return best.map { (mapIndex: $0.mapIndex, offset: $0.offset) }
    }

    // MARK: - The segment strip's click (§19.4.4)

    /// The map and byte a click on the segment strip stands for: the nearest cut
    /// within the snap distance (the pane goes to its exact offset), or the byte
    /// drawn at the click's y when no cut is in reach. The strip positions like
    /// the map does — a click anywhere on it means "take me here" — a cut is just
    /// a target worth snapping to, the way a bookmark's mark is (§19.6.1). Nil
    /// when the point is not on any strip, so the caller falls through to the
    /// map's own click meaning. Internal so tests can assert the target without
    /// synthesizing clicks.
    func segmentStripClick(at point: NSPoint) -> (mapIndex: Int, offset: UInt64)? {
        for index in maps.indices {
            guard let strip = segmentStripRect(forMapAt: index) else { continue }
            // The strip is a 4 pt column; grow it by the snap distance so a cut
            // at its very edge is still reachable, and a click just off it is not
            // mistaken for the strip.
            let hit = strip.insetBy(dx: -Self.bookmarkSnapDistance,
                                    dy: -Self.bookmarkSnapDistance)
            guard hit.contains(point) else { continue }
            if let (mapIndex, offset) = nearestCut(to: point, in: index) {
                return (mapIndex, offset)
            }
            // No cut in reach: the byte the click's y stands for, clamped to the
            // file's own end (the strip's y can run a row past it).
            let area = area(forMapAt: index)
            let offset = offset(atY: point.y, in: area)
            return (index, min(offset, maps[index].fileSize - 1))
        }
        return nil
    }

    /// The cut nearest `point` on map `index`, within the snap distance of it.
    /// The cuts are the block boundaries — each block's start, except the first,
    /// which is the file start, not a cut — and the nearest is by the cut's own y.
    private func nearestCut(to point: NSPoint, in index: Int) -> (mapIndex: Int, offset: UInt64)? {
        let area = area(forMapAt: index)
        var best: (offset: UInt64, distance: CGFloat)?
        for block in segmentBlocks[index].dropFirst() {
            let cutY = stripY(of: block.range.lowerBound, in: area)
            let distance = abs(point.y - cutY)
            guard distance <= Self.bookmarkSnapDistance else { continue }
            if best == nil || distance < best!.distance {
                best = (block.range.lowerBound, distance)
            }
        }
        return best.map { (mapIndex: index, offset: $0.offset) }
    }

    /// The map and byte a point on the panel lands on, by the *window* mapping —
    /// the byte actually drawn there, row from y and column from x. Nil outside
    /// every map, or past the file's end. Internal so tests can assert the
    /// mapping without synthesizing clicks.
    func byteOffset(at point: NSPoint) -> (mapIndex: Int, offset: UInt64)? {
        if renderMode == .overview { return overviewByteOffset(at: point) }
        for index in maps.indices {
            let area = area(forMapAt: index)
            guard area.contains(point) else { continue }
            let content = contentArea(within: area, forMapAt: index)
            let row = topRow + UInt64(max(0, floor((point.y - area.minY) / Self.rowStep)))
            let (origins, _) = byteColumnLayout(contentWidth: content.width)
            // The last column whose cell starts at or before the point, so the
            // gaps between cells belong to the column on their left. A point
            // left of the first column stays on column 0.
            var column = 0
            for (j, origin) in origins.enumerated() where point.x >= content.minX + origin {
                column = j
            }
            let offset = row.multipliedReportingOverflow(by: Self.bytesPerRow)
            guard !offset.overflow else { return nil }
            let byte = offset.partialValue + UInt64(column)
            guard let snapped = snappedOffset(byte, forMapAt: index) else { return nil }
            return (index, snapped)
        }
        return nil
    }

    /// The byte an overview point stands for. The row gives the slice of the
    /// extent, and the column narrows it within that slice — the columns are
    /// decorative here, but using them turns a 7 KB row into a 437 byte target.
    private func overviewByteOffset(at point: NSPoint) -> (mapIndex: Int, offset: UInt64)? {
        let extent = overviewExtent()
        let rows = overviewRowCount()
        guard extent > 0, rows > 0 else { return nil }
        for index in maps.indices {
            let area = area(forMapAt: index)
            guard area.contains(point) else { continue }
            let content = contentArea(within: area, forMapAt: index)
            let row = min(rows - 1, max(0, Int(floor((point.y - area.minY) / overviewRowHeight))))
            let rowStart = extent * UInt64(row) / UInt64(rows)
            let rowEnd = extent * UInt64(row + 1) / UInt64(rows)
            let cells = overviewColumnLayout(in: content)
            var column = 0
            for (j, cell) in cells.enumerated() where point.x >= cell.x {
                column = j
            }
            let slice = (rowEnd - rowStart) * UInt64(column) / Self.bytesPerRow
            let offset = rowStart + slice
            guard let snapped = snappedOffset(offset, forMapAt: index) else { return nil }
            return (index, snapped)
        }
        return nil
    }

    /// The byte a raw offset stands for in map `index`, snapped to the file's
    /// own bounds. The map is binned over the *longest* file's extent, so a
    /// shorter map's tail is empty paper: a click there would compute an offset
    /// past the file's end, and this pulls it back onto the file's last byte.
    /// That is what makes the start and end zones of a map resolve to the start
    /// and end of the file — and, for the shorter file of a pair, put its end in
    /// the pane's centre rather than off the bottom of it (§19.7). Nil for an
    /// empty file, which has no byte to land on.
    func snappedOffset(_ offset: UInt64, forMapAt index: Int) -> UInt64? {
        let size = maps.indices.contains(index) ? maps[index].fileSize : 0
        guard size > 0 else { return nil }
        return min(offset, size - 1)
    }

    override func mouseUp(with event: NSEvent) {
        dragGrabOffset = nil
    }

    /// A right-click on the segment strip offers the menu that acts on the piece
    /// under it (§21.3) — the same menu the form's row offers, so one shape in
    /// both places. The menu is built by the controller (it is the one that can
    /// save, replace, select, edit, split and remove), and popped up here. A
    /// right-click elsewhere on the panel does nothing: the map has no other
    /// context menu.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for index in maps.indices {
            guard let pieceIndex = segmentPiece(at: point, onMapAt: index) else { continue }
            if let menu = segmentStripMenu?(index, pieceIndex, point) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
        }
    }

    /// Asks the panes to scroll so the viewport band's top lands at `bandTop`.
    ///
    /// The window slides with the panes, which makes the band travel the map's
    /// full height exactly once over the whole file — so the map *is* a
    /// proportional scrollbar and the band's position maps back to the panes'
    /// scroll position by simple proportion. A file that fits the window has no
    /// sliding to undo, so there the band's y is the row directly.
    private func requestScroll(bandTop: CGFloat, bandHeight: CGFloat) {
        guard let onScrollToOffset, !maps.isEmpty else { return }
        let totalRows = referenceRowCount()
        guard totalRows > 0 else { return }
        let offsetInMap = max(0, bandTop - area(forMapAt: 0).minY)

        if renderMode == .overview {
            // The map is the whole file, so it is a plain proportional scroll
            // bar. The band sits at its pixel floor here and so cannot say how
            // tall a page is — take that from the panes' own visible range.
            let rows = overviewRowCount()
            let paneRows = unifiedViewport()
                .map { max(1, ($0.upperBound - $0.lowerBound + Self.bytesPerRow - 1) / Self.bytesPerRow) } ?? 1
            let maxPaneTop = totalRows > paneRows ? totalRows - paneRows : 0
            let travel = CGFloat(rows) * overviewRowHeight - bandHeight
            guard rows > 0, travel > 0, maxPaneTop > 0 else { return }
            let fraction = min(1, max(0, Double(offsetInMap / travel)))
            let target = UInt64((fraction * Double(maxPaneTop)).rounded())
            onScrollToOffset(min(target, totalRows - 1) * Self.bytesPerRow)
            return
        }

        let windowRows = UInt64(max(0, windowRowCount()))
        guard windowRows > 0 else { return }
        let row: UInt64
        if totalRows <= windowRows {
            row = UInt64(max(0, (offsetInMap / Self.rowStep).rounded()))
        } else {
            let travel = CGFloat(windowRows) * Self.rowStep - bandHeight
            let paneRows = max(1, UInt64((bandHeight / Self.rowStep).rounded()))
            let maxPaneTop = totalRows > paneRows ? totalRows - paneRows : 0
            guard travel > 0, maxPaneTop > 0 else { return }
            let fraction = min(1, max(0, Double(offsetInMap / travel)))
            row = UInt64((fraction * Double(maxPaneTop)).rounded())
        }
        onScrollToOffset(min(row, totalRows - 1) * Self.bytesPerRow)
    }

    /// A wheel over the panel scrolls the *panes*, at the map's own scale (one
    /// hex row per `rowStep` of scrolling) — the map has no scroll position of
    /// its own to move.
    override func scrollWheel(with event: NSEvent) {
        guard let onScrollToOffset, let visible = unifiedViewport() else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * Self.rowStep
        let rows = Int((delta / Self.rowStep).rounded())
        guard rows != 0 else { return }
        let totalRows = referenceRowCount()
        guard totalRows > 0 else { return }
        let paneTop = Int64(visible.lowerBound / Self.bytesPerRow)
        let target = max(0, paneTop - Int64(rows))
        let clamped = min(UInt64(target), totalRows - 1)
        onScrollToOffset(clamped * Self.bytesPerRow)
    }
}

private extension MinimapView.MapLayout {
    /// Whether two layouts draw the same divider (a stacked fraction equal to
    /// within a hair counts as unchanged).
    func equivalent(to other: MinimapView.MapLayout) -> Bool {
        switch (self, other) {
        case (.single, .single), (.sideBySide, .sideBySide):
            return true
        case (.stacked(let a), .stacked(let b)):
            return abs(a - b) < 0.0001
        default:
            return false
        }
    }
}


private extension UInt64 {
    /// The distance between two unsigned values, whichever is larger — the
    /// subtraction that does not trap.
    func absoluteDifference(to other: UInt64) -> UInt64 {
        self > other ? self - other : other - self
    }
}
