import Cocoa

/// The minimap panel shown to the right of the hex panes (§ N).
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
/// **The scale is fixed**, so the file does *not* fit the panel: 4 pt per hex row
/// means a 1 MB file is ~262 000 pt tall while the panel shows ~150 rows. The map
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

    /// The render scale, fixed by design: a byte cell is `byteHeight` tall with
    /// `rowGap` between rows, so one hex row costs `rowStep` no matter how large
    /// the file is. This is what makes the map a window rather than an overview.
    static let byteHeight: CGFloat = 3
    static let rowGap: CGFloat = 1
    static var rowStep: CGFloat { byteHeight + rowGap }

    /// Bytes per hex row — the dump's row width, and the map's.
    static let bytesPerRow: UInt64 = 16

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
    /// edge to edge too (§ N).
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
        needsDisplay = true
    }

    /// Replaces the maps (file sizes). Selections are re-applied by the caller
    /// afterwards — a rebuild and a selection change race.
    func setMaps(_ maps: [Map]) {
        self.maps = maps
        updateTopRow()
        needsDisplay = true
    }

    /// Moves one map's selection overlay. Cheap — no data rebuild — so it is
    /// safe to call on every caret/selection change (e.g. a mouse drag).
    func updateSelection(_ selection: Range<UInt64>?, forMapAt index: Int) {
        guard maps.indices.contains(index) else { return }
        guard maps[index].selection != selection else { return }
        maps[index].selection = selection
        needsDisplay = true
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
        self.viewports = viewports
        updateTopRow()
        needsDisplay = true
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

    /// The minimum height of the viewport band, for a pane so short it shows
    /// barely a row.
    static let viewportMinHeight: CGFloat = 4

    /// The viewport band's fill — a translucent grey that reads as a "you are
    /// here" band over the cells without hiding them. Lightened in dark
    /// appearance so it lifts off the near-black paper.
    private static let viewportFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.95, alpha: 0.16)
            : NSColor(white: 0.15, alpha: 0.14)
    }

    /// The maps draw top-down, matching the stacked panes' flipped coordinates
    /// (first pane on top), so a stacked divider lands at the same y as the
    /// panes' divider.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
        needsDisplay = true
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
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Three passes rather than one per map: side-by-side draws a single
        // viewport band across *both* maps, so the band cannot belong to a
        // per-map pass. Splitting the passes also keeps the layering — cells,
        // then the band, then the selection on top of it, so a selection inside
        // the viewport stays readable.
        for index in maps.indices {
            // The map's content (cells, selection) sits in a 10 pt side frame
            // away from the panel's side edges; the viewport band deliberately
            // runs edge to edge past it (§ N).
            drawCells(forMapAt: index,
                      in: contentArea(within: area(forMapAt: index), forMapAt: index),
                      dirtyRect: dirtyRect)
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
            // exactly the seam the shared band exists to remove (§ N).
            drawVerticalDivider(at: bounds.midX, in: dirtyRect, yielding: viewportRects())
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
    /// the shared viewport band is measured against (§ N).
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
    private func updateTopRow() {
        let newTop = derivedTopRow()
        guard newTop != topRow else { return }
        topRow = newTop
        needsDisplay = true
    }

    private func derivedTopRow() -> UInt64 {
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

    // MARK: - Overlays

    /// The y a byte offset sits at inside a map, in the map's own coordinates.
    /// Offsets above the window come out negative and below it past the map's
    /// height — the callers clip.
    private func y(of offset: UInt64, in area: NSRect) -> CGFloat {
        let row = Double(offset) / Double(Self.bytesPerRow)
        return area.minY + CGFloat(row - Double(topRow)) * Self.rowStep
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
    /// rows' own height — and is clipped to the map. A pane so short it shows
    /// barely a row still gets `viewportMinHeight`. Nil when there is nothing to
    /// draw, or when the visible rows fall outside the window entirely.
    private func viewportRect(_ viewport: Range<UInt64>?, in area: NSRect) -> NSRect? {
        guard let viewport, !viewport.isEmpty, area.height > 0 else { return nil }
        var y0 = y(of: viewport.lowerBound, in: area)
        var y1 = y(of: viewport.upperBound, in: area)
        if y1 - y0 < Self.viewportMinHeight {
            y1 = y0 + Self.viewportMinHeight
        }
        y0 = max(y0, area.minY)
        y1 = min(y1, area.maxY)
        guard y1 > y0 else { return nil }
        return NSRect(x: area.minX, y: y0, width: area.width, height: y1 - y0)
    }

    /// Fills the bands that intersect the repaint region. Drawn under the
    /// selection overlay so a selection inside the viewport stays readable.
    private func drawViewports(dirtyRect: NSRect) {
        let rects = viewportRects()
        guard !rects.isEmpty else { return }
        Self.viewportFill.setFill()
        for rect in rects where rect.maxY >= dirtyRect.minY && rect.minY <= dirtyRect.maxY {
            rect.fill()
        }
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

    // MARK: - Dragging the viewport (§ N)

    /// Where in the band the drag was grabbed, in points from the band's top, so
    /// the band keeps its grip on the cursor for the whole drag. Nil when no
    /// drag is in flight.
    private var dragGrabOffset: CGFloat?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bands = viewportRects()
        if let band = bands.first(where: { $0.contains(point) }) {
            dragGrabOffset = point.y - band.minY
            return
        }
        // A click off the band jumps: the band centres on the clicked row, and
        // the drag continues from its middle.
        let height = bands.first?.height ?? Self.viewportMinHeight
        dragGrabOffset = height / 2
        requestScroll(bandTop: point.y - height / 2, bandHeight: height)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = dragGrabOffset else { return }
        let point = convert(event.locationInWindow, from: nil)
        let height = viewportRects().first?.height ?? Self.viewportMinHeight
        requestScroll(bandTop: point.y - grab, bandHeight: height)
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
        let windowRows = UInt64(max(0, windowRowCount()))
        guard totalRows > 0, windowRows > 0 else { return }
        let offsetInMap = max(0, bandTop - area(forMapAt: 0).minY)

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
