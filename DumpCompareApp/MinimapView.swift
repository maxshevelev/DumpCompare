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
final class MinimapView: NSView {
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

        static let insignificant = CellState(isSignificant: false, isModified: false, isDifferent: false)
        static let significant = CellState(isSignificant: true, isModified: false, isDifferent: false)

        init(isSignificant: Bool, isModified: Bool, isDifferent: Bool) {
            self.isSignificant = isSignificant
            self.isModified = isModified
            self.isDifferent = isDifferent
        }

        /// The cell for one byte of the dump. Significance is that byte's own —
        /// nothing is merged, so a single 0x00 among real content stays muted.
        init(_ state: HexByteState) {
            isSignificant = state.byte != 0x00 && state.byte != 0xFF
            isModified = state.isModified
            isDifferent = state.isDifferent
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

    private(set) var mapLayout: MapLayout = .single
    /// The maps currently drawn (file sizes + selections). Readable so tests can
    /// inspect them.
    private(set) var maps: [Map] = []

    /// The byte range each map's pane currently has visible, by map index —
    /// what the grey viewport band mirrors, and what the map's own window is
    /// derived from. A nil entry (or an empty range) means that pane's scroll
    /// viewport is empty (no file, or the pane shows no bytes).
    private(set) var viewports: [Range<UInt64>?] = []

    /// The first hex row drawn at the top of every map. One shared window for
    /// both maps: the panes are synchronized by absolute offset (§9), so the
    /// same offset must sit at the same y on both. Derived from the panes —
    /// never set from outside.
    private(set) var topRow: UInt64 = 0

    /// The store the render mode is remembered in. Injectable so tests can pin a
    /// mode in an isolated suite instead of reading the user's own preference.
    static var defaults: UserDefaults = .standard

    /// Which way the maps draw. Detail is the historical behaviour; overview is
    /// chosen for files too large for detail to say anything useful (§19.4).
    private(set) var renderMode: RenderMode = .detail

    /// The overview's data, by map index. Empty in detail mode, or while a
    /// background pass is still computing it.
    private(set) var overviewSummaries: [OverviewSummary] = []

    /// Fired when the number of overview rows the panel can show changes — a
    /// resize, a layout flip, or a switch into overview — so the controller can
    /// recompute the summary at the new density.
    var onOverviewRowCountChanged: (() -> Void)?

    /// Supplies the per-byte state the map paints, for one byte range of one
    /// map. Called from `draw` for the visible rows only — the map stores no
    /// cells, so this is the whole data path.
    var byteStates: ((_ mapIndex: Int, _ range: Range<UInt64>) -> [HexByteState])?

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
        updateTopRow()
        invalidateAll()
    }

    /// Switches how the maps draw. The overview's data is dropped on the way
    /// out and requested on the way in, so a stale picture is never shown.
    func setRenderMode(_ mode: RenderMode) {
        guard renderMode != mode else { return }
        renderMode = mode
        if mode == .detail {
            overviewSummaries = []
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
        guard overviewSummaries != summaries else { return }
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
        guard renderMode == .overview, overviewSummaries.indices.contains(index) else { return }
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

    /// The overview picture for one map, if it is current.
    private func overviewSummary(forMapAt index: Int) -> OverviewSummary? {
        guard overviewSummaries.indices.contains(index) else { return nil }
        let summary = overviewSummaries[index]
        return summary.rowCount > 0 ? summary : nil
    }

    /// Replaces the maps (file sizes). Selections are re-applied by the caller
    /// afterwards — a rebuild and a selection change race.
    func setMaps(_ maps: [Map]) {
        // This runs on every edit, and an edit almost never changes a file's
        // size: bail out before the full repaint, and keep the selections the
        // fresh maps would otherwise drop until the caller re-applies them.
        guard maps.map(\.fileSize) != self.maps.map(\.fileSize) else { return }
        let extentChanged = maps.map(\.fileSize).max() != self.maps.map(\.fileSize).max()
        self.maps = maps
        updateTopRow()
        invalidateAll()
        // The overview's bins are built over the longest file, so a new file
        // invalidates them.
        if renderMode == .overview, extentChanged {
            overviewSummaries = []
            overviewStandIns = [:]
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

    /// Marks only these rectangles for repaint. Scrolling calls into the panel
    /// on every wheel tick, and the maps themselves do not change between edits:
    /// in overview a full repaint would redraw a whole dump's picture — 16 cells
    /// per device pixel row — to move a 7 pt chevron (§19.9).
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
    /// and in overview only the two margin chevrons — the rest of the band is
    /// deliberately never drawn there (§19.6).
    private func viewportDamage() -> [NSRect] {
        let rects = viewportRects()
        switch renderMode {
        case .detail: return rects
        case .overview: return rects.flatMap { overviewMarkerRects(for: $0) }
        }
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

    override func layout() {
        super.layout()
        // A resize changes how many rows fit, which moves the window, and
        // re-derives the divider's position from the new bounds.
        updateTopRow()
        invalidateAll()
        // The overview bins the file into one row per pixel, so a height change
        // changes the bins themselves: the summary has to be recomputed.
        guard renderMode == .overview else { return }
        let rows = overviewRowCount()
        guard rows != lastReportedOverviewRowCount else { return }
        lastReportedOverviewRowCount = rows
        onOverviewRowCountChanged?()
    }

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
            switch renderMode {
            case .detail: drawCells(forMapAt: index, in: content, dirtyRect: dirtyRect)
            case .overview: drawOverviewRows(forMapAt: index, in: content, dirtyRect: dirtyRect)
            }
        }
        drawViewports(dirtyRect: dirtyRect)
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
        var rows: [ByteRow] = []
        rows.reserveCapacity(states.count / Int(Self.bytesPerRow) + 1)
        var offset = 0
        while offset < states.count {
            let end = min(offset + Int(Self.bytesPerRow), states.count)
            let cells = states[offset..<end].filter { !$0.isEOF }.map(CellState.init)
            if cells.isEmpty { break }  // past EOF: no more rows to draw
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
    private func contentArea(within area: NSRect, forMapAt index: Int) -> NSRect {
        let pad = Self.contentPadding
        switch mapLayout {
        case .single, .stacked:
            return NSRect(x: area.minX + pad, y: area.minY,
                          width: max(0, area.width - pad * 2),
                          height: area.height)
        case .sideBySide:
            // index 0 keeps the left pad (outer edge), index 1 the right one.
            let inset = index == 0 ? (area.minX + pad) : area.minX
            return NSRect(x: inset, y: area.minY,
                          width: max(0, area.width - pad),
                          height: area.height)
        }
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
                if state.isDifferent {
                    HexTheme.differenceFill.setFill()
                    NSRect(x: rect.minX, y: y, width: cellWidth, height: rowStep).fill()
                }
                // The byte itself is drawn on top of that background, so a
                // modified byte shows as red ink on orange, exactly as the hex
                // panes draw it.
                let color = state.isModified ? HexTheme.modifiedText
                    : (state.isSignificant ? HexTheme.byteText : HexTheme.mutedByteText)
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
        let ink = HexTheme.byteText
        let tones = (0...255).map { ink.withAlphaComponent(Self.overviewTone(density: UInt8($0))) }
        let columns = Int(Self.bytesPerRow)
        let extent = max(summary.extent, 1)
        for row in rows {
            let y = top + CGFloat(row) * rowHeight
            let modified = summary.modified.indices.contains(row) ? summary.modified[row] : 0
            let different = summary.different.indices.contains(row) ? summary.different[row] : 0
            let rowStart = extent * UInt64(row) / UInt64(summary.rowCount)
            let rowEnd = extent * UInt64(row + 1) / UInt64(summary.rowCount)
            let span = rowEnd - rowStart
            for column in 0..<columns {
                let bit = UInt16(1) << UInt16(column)
                let densityIndex = row * columns + column
                let density = summary.density.indices.contains(densityIndex)
                    ? summary.density[densityIndex] : 0
                let sliceStart = rowStart + span * UInt64(column) / UInt64(columns)
                // Past this file's end there is nothing of it to draw — not a
                // fill, not an event. That is what leaves the shorter file's
                // tail empty (§9).
                guard sliceStart < fileSize else { continue }
                let isEvent = modified & bit != 0 || different & bit != 0
                // An event is one cell of a one-pixel row, invisible inside a
                // dense region, so it is drawn two pixels tall — it spills into
                // the next row rather than disappearing.
                let rect = NSRect(x: cells[column].x, y: y,
                                  width: cells[column].width,
                                  height: isEvent ? rowHeight * 2 : rowHeight)
                if modified & bit != 0 {
                    HexTheme.modifiedText.setFill()
                } else if different & bit != 0 {
                    HexTheme.differenceFill.setFill()
                } else {
                    tones[Int(density)].setFill()
                }
                rect.fill()
            }
        }
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
            // Nothing is drawn across the content: a line spanning the panel
            // costs a whole row of the picture, and on a dump every row counts.
            // The position is marked by a chevron in each side margin instead,
            // where there is nothing to hide (§19.6).
            drawOverviewViewportMarkers(visible, dirtyRect: dirtyRect)
        }
    }

    /// Marks the viewport's position with a chevron in each outer margin, pointing
    /// inward, level with the middle of the visible slice. The margins are the
    /// `contentPadding` frame the cells never reach, so the markers cost no
    /// detail.
    private func drawOverviewViewportMarkers(_ rects: [NSRect], dirtyRect: NSRect) {
        Self.viewportEdge.setFill()
        for band in rects {
            for (slot, box) in overviewMarkerRects(for: band).enumerated() {
                guard box.maxY >= dirtyRect.minY, box.minY <= dirtyRect.maxY else { continue }
                // The left chevron points right, the right one points left: both
                // aim at the content between them.
                let apexX = slot == 0 ? box.maxX : box.minX
                let baseX = slot == 0 ? box.minX : box.maxX
                let path = NSBezierPath()
                path.move(to: NSPoint(x: baseX, y: box.minY))
                path.line(to: NSPoint(x: apexX, y: box.midY))
                path.line(to: NSPoint(x: baseX, y: box.maxY))
                path.close()
                path.fill()
            }
        }
    }

    private static let overviewMarkerHeight: CGFloat = 7

    /// The two boxes the chevrons occupy, level with the middle of the band and
    /// inside the side margins, so they never overlap a cell. Shared by drawing
    /// and by invalidation, which is what keeps a scroll's repaint this small.
    private func overviewMarkerRects(for band: NSRect) -> [NSRect] {
        let width = min(Self.contentPadding - 2, 5)
        guard width > 1 else { return [] }
        let height = Self.overviewMarkerHeight
        let y = band.midY - height / 2
        return [NSRect(x: band.minX, y: y, width: width, height: height),
                NSRect(x: band.maxX - width, y: y, width: width, height: height)]
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

    /// Moves the caret of `mapIndex`'s pane to `offset` and centres it there.
    /// The map draws real bytes, so a click on one means that byte — unlike a
    /// drag of the band, which is a scrollbar gesture and leaves the caret be.
    var onSelectOffset: ((_ mapIndex: Int, _ offset: UInt64) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bands = viewportRects()
        if let band = bands.first(where: { $0.contains(point) }) {
            // The band is the drag handle: grabbing it scrolls and must not
            // disturb the caret.
            dragGrabOffset = point.y - band.minY
            return
        }
        // Off the band: the click means the byte drawn under it, so the caret
        // goes there and the pane centres on it. The drag then continues from
        // the band's middle, so the press can still turn into a scroll.
        guard let band = bands.first else { return }
        if let (mapIndex, offset) = byteOffset(at: point) {
            onSelectOffset?(mapIndex, offset)
        }
        dragGrabOffset = band.height / 2
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = dragGrabOffset, let height = viewportRects().first?.height else { return }
        let point = convert(event.locationInWindow, from: nil)
        requestScroll(bandTop: point.y - grab, bandHeight: height)
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
            guard byte < maps[index].fileSize else {
                // Past this file's end: fall back to its last byte so a click
                // low on a short map still lands somewhere real.
                guard maps[index].fileSize > 0 else { return nil }
                return (index, maps[index].fileSize - 1)
            }
            return (index, byte)
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
            let fileSize = maps[index].fileSize
            guard fileSize > 0 else { return nil }
            return (index, min(offset, fileSize - 1))
        }
        return nil
    }

    override func mouseUp(with event: NSEvent) {
        dragGrabOffset = nil
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
