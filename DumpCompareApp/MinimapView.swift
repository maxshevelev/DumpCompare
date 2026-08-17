import Cocoa

/// The minimap panel shown to the right of the hex panes (§ N).
///
/// Stage 2 lays the panel out: one file = one map, so single-file mode shows a
/// single map over the whole panel; side-by-side comparison splits the panel
/// with a vertical divider at its exact center (one map per pane); stacked
/// comparison splits it with a horizontal divider that mirrors the panes'
/// draggable divider — the line moves as the panes' divider moves.
///
/// Stage 3 fills the maps with the files' contents as horizontal stripes, one
/// per `maxRenderRows` slot regardless of file size (a huge file collapses onto
/// a fixed number of stripes instead of one stripe per hex row). A stripe is
/// coloured by the state of the bytes it covers — the same colours the hex
/// panes use:
/// - every byte a 0x00/0xFF fill → muted (`mutedByteText`);
/// - at least one significant byte → ink (`byteText`);
/// - at least one differing byte → orange (`differenceFill`);
/// and the current selection is drawn as a translucent blue overlay on top of
/// the stripes (`selectionFill`), mirroring the selection fill in the panes.
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

    /// One map: the file's size (for byte→stripe mapping) and its precomputed
    /// stripes. `rows` always has exactly `maxRenderRows` entries.
    struct Map {
        let fileSize: UInt64
        let rows: [Row]
        /// The file's current selection, drawn as an overlay on top of the
        /// stripes; nil (or empty) when the caret sits alone.
        var selection: Range<UInt64>?
    }

    /// How a stripe is coloured, by what the bytes it covers contain.
    enum Row {
        /// No significant byte and no difference — all 0x00/0xFF fill.
        case insignificant
        /// At least one byte that is not a 0x00/0xFF fill.
        case significant
        /// At least one byte that differs from the companion file.
        case different
    }

    /// Fixed render density: at most this many stripes per map regardless of
    /// file size, so a giant file collapses onto a few thousand stripes instead
    /// of one per hex row (which would be millions for a big file).
    static let maxRenderRows = 2048

    /// Inset of the maps' content from the panel's edges — the stripes sit in a
    /// 6 pt frame on every side, matching the breathing room the hex panes give
    /// their dumps. The viewport rectangle deliberately ignores this inset and
    /// runs edge to edge (§ N).
    static let contentPadding: CGFloat = 6

    private(set) var mapLayout: MapLayout = .single
    /// The maps currently drawn (file sizes + stripes). Updated by `setMaps`
    /// after a background rebuild; readable so tests can inspect the stripes.
    private(set) var maps: [Map] = []

    /// The byte range each map's pane currently has visible, by map index —
    /// what the grey viewport rectangle mirrors. A nil entry (or an empty
    /// range) means that pane's scroll viewport is empty (no file, or the pane
    /// shows no bytes). Kept separate from the maps so a scroll only moves the
    /// overlay and never rebuilds the stripes.
    private(set) var viewports: [Range<UInt64>?] = []

    /// Adopts a new map split, redrawing the divider lines only when the split
    /// actually changed (a stacked fraction can move by a hair on every pane
    /// divider tick, so compare with tolerance).
    func setMapLayout(_ layout: MapLayout) {
        guard !mapLayout.equivalent(to: layout) else { return }
        mapLayout = layout
        needsDisplay = true
    }

    /// Replaces the maps' contents (file sizes + stripes). The panel keeps the
    /// current selections unless `updateSelection` is called afterwards — a
    /// rebuild and a selection change race, so the caller re-applies them.
    func setMaps(_ maps: [Map]) {
        self.maps = maps
        needsDisplay = true
    }

    /// Moves one map's selection overlay. Cheap — no stripe rebuild — so it is
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
    /// range of each pane; the panel redraws only the overlay — no stripe
    /// rebuild, no file read — so it is cheap enough for live scrolling.
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

    /// The viewport rectangle's fill — a translucent grey that reads as a
    /// "you are here" band over the stripes without hiding them. Lightened in
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
        layer?.backgroundColor = Self.background.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // A resize re-derives the divider's position from the new bounds (the
        // centered vertical line, or the fraction × new height), so repaint.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (index, map) in maps.enumerated() {
            let area = area(forMapAt: index)
            // The map's content (stripes, selection) sits in a 6 pt frame away
            // from the panel's edges; the viewport rectangle deliberately runs
            // edge to edge past it (§ N).
            let content = contentArea(within: area)
            drawStripes(of: map, in: content, dirtyRect: dirtyRect)
            drawViewport(viewport: viewport(forMapAt: index), fileSize: map.fileSize,
                         in: area, dirtyRect: dirtyRect)
            drawSelection(map.selection, fileSize: map.fileSize, in: content, dirtyRect: dirtyRect)
        }
        switch mapLayout {
        case .single:
            break
        case .sideBySide:
            drawVerticalDivider(at: bounds.midX, in: dirtyRect)
        case .stacked(let fraction):
            let y = min(max(fraction, 0), 1) * bounds.height
            drawHorizontalDivider(at: y, in: dirtyRect)
        }
    }

    // MARK: - Stripes

    private func area(forMapAt index: Int) -> NSRect {
        let width = bounds.width
        let height = bounds.height
        switch mapLayout {
        case .single:
            return bounds
        case .sideBySide:
            let half = width / 2
            if index == 0 {
                return NSRect(x: 0, y: 0, width: half, height: height)
            }
            return NSRect(x: half, y: 0, width: width - half, height: height)
        case .stacked(let fraction):
            let split = min(max(fraction, 0), 1) * height
            if index == 0 {
                return NSRect(x: 0, y: 0, width: width, height: split)
            }
            return NSRect(x: 0, y: split, width: width, height: height - split)
        }
    }

    /// The padded region a map's content is drawn in: `area` inset by
    /// `contentPadding` on every side, so the file's lines sit in a frame away
    /// from the panel's edges — matching the breathing room the hex panes give
    /// their dumps. Never negative (a tiny map just collapses to no content).
    private func contentArea(within area: NSRect) -> NSRect {
        let pad = Self.contentPadding
        return NSRect(x: area.minX + pad, y: area.minY + pad,
                      width: max(0, area.width - pad * 2),
                      height: max(0, area.height - pad * 2))
    }

    private func drawStripes(of map: Map, in area: NSRect, dirtyRect: NSRect) {
        let rows = map.rows
        guard !rows.isEmpty, area.height > 0 else { return }
        let stripeHeight = area.height / CGFloat(rows.count)
        // The map's stripes only cover the area rows that intersect the dirty
        // region; clip to it so a scroll-adjacent repaint doesn't re-fill the
        // whole panel.
        let firstStripe = max(0, Int((dirtyRect.minY - area.minY) / max(stripeHeight, 0.0001)))
        let lastStripe = min(rows.count - 1,
                             Int((dirtyRect.maxY - area.minY) / max(stripeHeight, 0.0001)))
        guard lastStripe >= firstStripe else { return }
        for i in firstStripe...lastStripe {
            let color: NSColor
            switch rows[i] {
            case .insignificant: color = HexTheme.mutedByteText
            case .significant: color = HexTheme.byteText
            case .different: color = HexTheme.differenceFill
            }
            color.setFill()
            NSRect(x: area.minX,
                   y: area.minY + CGFloat(i) * stripeHeight,
                   width: area.width,
                   height: stripeHeight).fill()
        }
    }

    /// Draws the pane's visible slice as a grey band over the map — the
    /// minimap's "you are here" rectangle. Unlike the stripes, the band runs
    /// edge to edge: full map width, and the file fraction against the map's
    /// full height, so it pokes past the padded lines on every side. Drawn
    /// under the selection overlay so a selection inside the viewport stays
    /// readable.
    private func drawViewport(viewport: Range<UInt64>?, fileSize: UInt64,
                              in area: NSRect, dirtyRect: NSRect) {
        guard let viewport, !viewport.isEmpty, fileSize > 0 else { return }
        let startFraction = CGFloat(min(viewport.lowerBound, fileSize)) / CGFloat(fileSize)
        let endFraction = CGFloat(min(viewport.upperBound, fileSize)) / CGFloat(fileSize)
        guard endFraction > startFraction else { return }
        let y0 = area.minY + startFraction * area.height
        let y1 = area.minY + endFraction * area.height
        let rect = NSRect(x: area.minX, y: y0, width: area.width, height: y1 - y0)
        guard rect.maxY >= dirtyRect.minY, rect.minY <= dirtyRect.maxY else { return }
        Self.viewportFill.setFill()
        rect.fill()
    }

    private func drawSelection(_ selection: Range<UInt64>?, fileSize: UInt64,
                               in area: NSRect, dirtyRect: NSRect) {
        guard let selection, !selection.isEmpty, fileSize > 0 else { return }
        let startFraction = CGFloat(min(selection.lowerBound, fileSize)) / CGFloat(fileSize)
        let endFraction = CGFloat(min(selection.upperBound, fileSize)) / CGFloat(fileSize)
        guard endFraction > startFraction else { return }
        let y0 = area.minY + startFraction * area.height
        let y1 = area.minY + endFraction * area.height
        guard y1 > y0, y1 >= dirtyRect.minY, y0 <= dirtyRect.maxY else { return }
        HexTheme.selectionFill.setFill()
        NSRect(x: area.minX, y: y0, width: area.width, height: y1 - y0).fill()
    }

    private func drawVerticalDivider(at x: CGFloat, in dirtyRect: NSRect) {
        guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { return }
        Self.dividerFill.setFill()
        let top = min(dirtyRect.maxY, bounds.maxY)
        let bottom = max(dirtyRect.minY, bounds.minY)
        guard top > bottom else { return }
        NSRect(x: x, y: bottom, width: 1, height: top - bottom).fill()
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
