import Cocoa

/// The minimap panel shown to the right of the hex panes (§ N).
///
/// Stage 2 lays the panel out: one file = one map, so single-file mode shows a
/// single map over the whole panel; side-by-side comparison splits the panel
/// with a vertical divider at its exact center (one map per pane); stacked
/// comparison splits it with a horizontal divider that mirrors the panes'
/// draggable divider — the line moves as the panes' divider moves.
///
/// Stage 3 fills the maps with the files' contents as a miniature hex dump:
/// the hex column only (no offset, no ASCII), each byte a small rectangle at
/// most `byteHeight` tall, with `rowGap` between rows, so the panel reads as a
/// grid of pixels. Columns keep the hex dump's proportions (two characters per
/// byte, one-character gaps between words, two-character gap between the 8-byte
/// groups) scaled to the content width. A row of the dump is one `ByteRow` of
/// up to 16 per-byte cells; the last row can be shorter for a partial hex row.
/// A cell is coloured by what its byte(s) hold — the same colours the hex
/// panes use, layered the same way: a byte that differs from the companion
/// gets an orange background over the whole cell, and the byte itself is drawn
/// on top — red when modified (`modifiedText`), ink when significant
/// (`byteText`), muted for a 0x00/0xFF fill (`mutedByteText`). The current
/// selection is drawn as a translucent blue overlay on top of the cells
/// (`selectionFill`), mirroring the selection fill in the panes.
///
/// A small file keeps one mini row per hex row and is drawn at the map's top
/// (byte height 3 pt), leaving the rest of the map empty; a large file
/// collapses groups of hex rows onto as many mini rows as fit the map's height
/// (`rowCapacity(areaHeight:)`), each cell's state aggregating its group's
/// bytes. The viewport and selection overlays are measured against the map's
/// content height and run edge to edge, independent of how much of it the
/// cells actually fill.
///
/// The viewport band is per map — except side-by-side, which draws a single
/// rectangle across the whole panel on a shared offset axis, because the panes
/// scroll in lockstep and a band interrupted by the gutter read as broken. See
/// `viewportRects()`.
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

    /// One map: the file's size (for byte→cell mapping) and its precomputed
    /// mini hex rows. A row per hex row up to the map's `rowCapacity`; a larger
    /// file collapses onto exactly that many rows.
    struct Map {
        let fileSize: UInt64
        let rows: [ByteRow]
        /// The file's current selection, drawn as an overlay on top of the
        /// cells; nil (or empty) when the caret sits alone.
        var selection: Range<UInt64>?
    }

    /// One mini hex row of the map: the per-byte state of each of its 1...16
    /// cells (the last row holds fewer when the file's final hex row is short).
    struct ByteRow {
        let cells: [CellState]
    }

    /// The flags that colour a byte cell, by what the byte(s) it covers contain.
    /// A cell can carry any combination: a byte can be significant and modified,
    /// differ from the companion, and so on — the renderer layers them (diff is
    /// a background, the byte itself is drawn on top), matching the hex panes,
    /// which show modified (red ink) and difference (background) together.
    struct CellState: Equatable {
        /// The byte is not a 0x00/0xFF fill.
        var isSignificant: Bool
        /// The byte was modified since the file was last read from disk.
        var isModified: Bool
        /// The byte differs from the companion file.
        var isDifferent: Bool

        static let insignificant = CellState(isSignificant: false, isModified: false, isDifferent: false)
        static let significant = CellState(isSignificant: true, isModified: false, isDifferent: false)
    }

    /// Render density comes from the map's height, not a fixed constant: a byte
    /// cell is at most this tall, with `rowGap` breathing room between rows, so
    /// a map can hold `rowCapacity` mini rows. A file small enough for its hex
    /// rows to fit 1:1 never fills the map (cells stay 3 pt tall, rows drawn
    /// from the top); a larger file aggregates hex rows down to the capacity.
    static let byteHeight: CGFloat = 3
    static let rowGap: CGFloat = 1

    /// How many mini rows fit a map `areaHeight` tall: every row costs
    /// `byteHeight` plus a trailing `rowGap` except the last. Small heights
    /// collapse to zero rows (nothing fits).
    static func rowCapacity(areaHeight: CGFloat) -> Int {
        guard areaHeight > 0 else { return 0 }
        return max(0, Int(floor((areaHeight + rowGap) / (byteHeight + rowGap))))
    }

    /// Side inset of the maps' content from the panel's edges — the cells sit
    /// in a 10 pt frame on either side, matching the breathing room the hex
    /// panes give their dumps. Only horizontal: the rows run edge to edge top
    /// and bottom. The viewport rectangle deliberately ignores this inset and
    /// runs edge to edge too (§ N).
    static let contentPadding: CGFloat = 10

    /// In side-by-side mode the two maps sit on either side of an inner gutter
    /// this wide — a fraction of the panel's full width — so the minimap's
    /// split echoes the gap between the two side-by-side panes and the gap
    /// scales with the panel's own width.
    static let sideBySideGutterFraction: CGFloat = 0.05

    private(set) var mapLayout: MapLayout = .single
    /// The maps currently drawn (file sizes + byte cells). Updated by `setMaps`
    /// after a background rebuild; readable so tests can inspect the cells.
    private(set) var maps: [Map] = []

    /// The byte range each map's pane currently has visible, by map index —
    /// what the grey viewport rectangle mirrors. A nil entry (or an empty
    /// range) means that pane's scroll viewport is empty (no file, or the pane
    /// shows no bytes). Kept separate from the maps so a scroll only moves the
    /// overlay and never rebuilds the cells.
    private(set) var viewports: [Range<UInt64>?] = []

    /// Invoked when a resize changes the row density the maps should be built
    /// with — e.g. the panel grew tall enough to fit more rows, or a stacked
    /// divider dragged the top map shorter. The caller re-runs the data build
    /// with `rowCapacities()`; the map's own resize handling only repaints.
    var onRowCapacityChanged: (() -> Void)?

    /// The number of mini rows each map's data should be built with, derived
    /// from the current layout and bounds. Indexed like `maps`.
    func rowCapacities() -> [Int] {
        switch mapLayout {
        case .single:
            return [Self.rowCapacity(areaHeight: bounds.height)]
        case .sideBySide:
            return [Self.rowCapacity(areaHeight: bounds.height),
                    Self.rowCapacity(areaHeight: bounds.height)]
        case .stacked(let fraction):
            let frac = min(max(fraction, 0), 1)
            return [Self.rowCapacity(areaHeight: bounds.height * frac),
                    Self.rowCapacity(areaHeight: bounds.height * (1 - frac))]
        }
    }

    /// Adopts a new map split, redrawing the divider lines only when the split
    /// actually changed (a stacked fraction can move by a hair on every pane
    /// divider tick, so compare with tolerance).
    func setMapLayout(_ layout: MapLayout) {
        guard !mapLayout.equivalent(to: layout) else { return }
        mapLayout = layout
        needsDisplay = true
    }

    /// Replaces the maps' contents (file sizes + byte cells). The panel keeps the
    /// current selections unless `updateSelection` is called afterwards — a
    /// rebuild and a selection change race, so the caller re-applies them.
    func setMaps(_ maps: [Map]) {
        self.maps = maps
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

    /// Moves the maps' viewport rectangles. A scroll reports the visible byte
    /// range of each pane; the panel redraws only the overlay — no data rebuild,
    /// no file read — so it is cheap enough for live scrolling.
    func setViewports(_ viewports: [Range<UInt64>?]) {
        guard viewports != self.viewports else { return }
        self.viewports = viewports
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

    /// The minimum height of the viewport band. On a huge file one visible page
    /// is a hair-thin slice of the whole — thinner than a pixel on a ~600 pt
    /// map — so the band is clamped to at least this tall or it reads as a
    /// missing overlay.
    static let viewportMinHeight: CGFloat = 4

    /// The viewport rectangle's fill — a translucent grey that reads as a
    /// "you are here" band over the cells without hiding them. Lightened in
    /// dark appearance so it lifts off the near-black paper.
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
        // A resize re-derives the divider's position from the new bounds (the
        // centered vertical line, or the fraction × new height), so repaint.
        needsDisplay = true
        notifyRowCapacityChangeIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Three passes rather than one per map: side-by-side draws a single
        // viewport band across *both* maps, so the band cannot belong to a
        // per-map pass. Splitting the passes also keeps the layering a per-map
        // loop used to give for free — cells, then the band, then the selection
        // on top of it, so a selection inside the viewport stays readable.
        for (index, map) in maps.enumerated() {
            // The map's content (cells, selection) sits in a 10 pt side frame
            // away from the panel's side edges; the viewport rectangle
            // deliberately runs edge to edge past it (§ N).
            drawByteGrid(of: map, in: contentArea(within: area(forMapAt: index), forMapAt: index),
                         dirtyRect: dirtyRect)
        }
        drawViewports(dirtyRect: dirtyRect)
        for (index, map) in maps.enumerated() {
            // The overlay mirrors the map's actual rows: a small file's map
            // fills only the top of the panel, so the selection is measured
            // against the rows' real extent, not the panel height.
            drawSelection(map.selection, fileSize: map.fileSize,
                          in: contentArea(within: area(forMapAt: index), forMapAt: index),
                          contentHeight: contentHeight(of: map), dirtyRect: dirtyRect)
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

    /// Whether the density the maps were built with no longer matches what the
    /// current height/layout asks for. Only meaningful when the data is built:
    /// a small file whose hex rows already fit 1:1 (rows == hex rows) is done
    /// regardless of how much taller the map gets; a file past its capacity is
    /// re-collapsed when the capacity moves. Fires at most once per layout pass
    /// (the rebuild lands the count back in sync, so the next pass is quiet).
    private func notifyRowCapacityChangeIfNeeded() {
        guard !maps.isEmpty else { return }
        let capacities = rowCapacities()
        guard capacities.count == maps.count else { return }
        for (map, capacity) in zip(maps, capacities) {
            let hexRows = (map.fileSize + 15) / 16
            let desiredCount = min(Int(hexRows), capacity)
            if map.rows.count != desiredCount {
                onRowCapacityChanged?()
                return
            }
        }
    }

    // MARK: - Byte grid

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

    private func drawByteGrid(of map: Map, in area: NSRect, dirtyRect: NSRect) {
        let rows = map.rows
        guard !rows.isEmpty, area.height > 0, area.width > 0 else { return }
        let (origins, cellWidth) = byteColumnLayout(contentWidth: area.width)
        guard cellWidth > 0 else { return }
        let rowStep = Self.byteHeight + Self.rowGap
        // Draw only the rows that intersect the dirty region, so a scroll-
        // adjacent repaint doesn't re-fill the whole panel.
        let firstRow = max(0, Int(floor((dirtyRect.minY - area.minY) / rowStep)))
        let lastRow = min(rows.count - 1,
                          Int(floor((dirtyRect.maxY - area.minY) / rowStep)))
        guard lastRow >= firstRow else { return }
        for i in firstRow...lastRow {
            let y = area.minY + CGFloat(i) * rowStep
            let row = rows[i]
            for (j, state) in row.cells.enumerated() {
                guard j < origins.count else { break }
                let rect = NSRect(x: area.minX + origins[j],
                                  y: y,
                                  width: cellWidth,
                                  height: Self.byteHeight)
                // Difference is a background over the whole cell (the byte
                // columns stay separate — the gaps between cells show the
                // panel's paper, so a diff read as dotted, not a solid stripe).
                if state.isDifferent {
                    HexTheme.differenceFill.setFill()
                    rect.fill()
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

    /// The vertical extent the map's rows actually occupy, from the map's top:
    /// `rows.count` mini rows each `byteHeight + rowGap` tall, minus the
    /// trailing gap. A small file whose hex rows fit 1:1 draws only this tall;
    /// a large file aggregates to the panel's row capacity, so its extent
    /// matches the panel's height. The viewport and selection overlays are
    /// measured against this extent — not the panel's full height — so they
    /// mirror the real picture on the map.
    private func contentHeight(of map: Map) -> CGFloat {
        guard !map.rows.isEmpty else { return 0 }
        return CGFloat(map.rows.count) * (Self.byteHeight + Self.rowGap) - Self.rowGap
    }

    /// The "you are here" band(s) the panel draws, as rectangles — the geometry
    /// `draw` fills. Internal so tests can assert the band's shape and position
    /// without reading pixels.
    ///
    /// Side-by-side returns exactly ONE rectangle spanning the whole panel: the
    /// panes scroll in lockstep by absolute offset (§9), so a band per map — cut
    /// in two by the gutter between them — read as a broken overlay rather than
    /// one viewport. The single band runs on a shared offset axis: the longer
    /// file's size over its map's content height, which is the app's
    /// absolute-offset rule applied to the panel. A consequence worth knowing:
    /// when the two files differ in size, the band sits where those bytes are on
    /// the longer file's map, and not where the shorter map draws them — the
    /// maps' own rows still run on each file's own scale.
    ///
    /// Single-file and stacked return one band per map. Stacked cannot share a
    /// band: its maps sit above each other, so the two bands are at different y
    /// by construction and one rectangle over both would swallow the divider and
    /// everything between them.
    func viewportRects() -> [NSRect] {
        switch mapLayout {
        case .single, .stacked:
            return maps.indices.compactMap { index in
                viewportRect(viewport: viewport(forMapAt: index),
                             fileSize: maps[index].fileSize,
                             in: area(forMapAt: index),
                             contentHeight: contentHeight(of: maps[index]))
            }
        case .sideBySide:
            guard let reference = referenceMapIndex() else { return [] }
            let rect = viewportRect(viewport: unifiedViewport(),
                                    fileSize: maps[reference].fileSize,
                                    in: bounds,
                                    contentHeight: contentHeight(of: maps[reference]))
            return rect.map { [$0] } ?? []
        }
    }

    /// The map the shared band is measured against: the one holding the longer
    /// file. Its map is also the taller one — more bytes means at least as many
    /// hex rows, hence at least as many mini rows — so the band is measured over
    /// the full offset axis of the comparison.
    private func referenceMapIndex() -> Int? {
        maps.indices.max(by: { maps[$0].fileSize < maps[$1].fileSize })
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

    /// One band's rectangle: the visible slice as a fraction of `fileSize`, laid
    /// over `contentHeight` inside `area`. It runs edge to edge on every side —
    /// the full width of `area` (poking past the padded cells) and the file
    /// fraction against `contentHeight`, so on a small file that fills only the
    /// top of the panel the band hugs the rows instead of stretching to the
    /// panel's height. A visible page of a huge file measures less than a pixel,
    /// so the band is given at least `viewportMinHeight` (kept inside the rows'
    /// extent) — the overlay still reads as a hair-thin slice that moves as the
    /// pane scrolls. Nil when there is nothing to draw.
    private func viewportRect(viewport: Range<UInt64>?, fileSize: UInt64,
                              in area: NSRect, contentHeight: CGFloat) -> NSRect? {
        guard let viewport, !viewport.isEmpty, fileSize > 0, contentHeight > 0 else { return nil }
        let startFraction = CGFloat(min(viewport.lowerBound, fileSize)) / CGFloat(fileSize)
        let endFraction = CGFloat(min(viewport.upperBound, fileSize)) / CGFloat(fileSize)
        guard endFraction > startFraction else { return nil }
        var y0 = area.minY + startFraction * contentHeight
        var y1 = area.minY + endFraction * contentHeight
        let minHeight = min(Self.viewportMinHeight, contentHeight)
        if y1 - y0 < minHeight {
            y1 = min(y0 + minHeight, area.minY + contentHeight)
            y0 = max(y1 - minHeight, area.minY)
        }
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

    private func drawSelection(_ selection: Range<UInt64>?, fileSize: UInt64,
                               in area: NSRect, contentHeight: CGFloat, dirtyRect: NSRect) {
        guard let selection, !selection.isEmpty, fileSize > 0, contentHeight > 0 else { return }
        let startFraction = CGFloat(min(selection.lowerBound, fileSize)) / CGFloat(fileSize)
        let endFraction = CGFloat(min(selection.upperBound, fileSize)) / CGFloat(fileSize)
        guard endFraction > startFraction else { return }
        let y0 = area.minY + startFraction * contentHeight
        let y1 = area.minY + endFraction * contentHeight
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
