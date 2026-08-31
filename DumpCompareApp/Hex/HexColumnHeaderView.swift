import Cocoa

/// The pinned column header above the hex dump: the column names — "Offset",
/// the sequential byte offsets "00".."0F" over the hex cells, and "Decoded
/// text" — in ink blue, separated from the rows by a thin rule.
///
/// Sits in the pane chrome above the scroll view, so it never scrolls
/// vertically; it mirrors the scroll view's horizontal offset so the labels
/// stay aligned with the columns as the dump scrolls sideways.
final class HexColumnHeaderView: NSView {
    /// The hex view supplying the grid geometry. The label positions come from
    /// `hexLayout`, the glyph ink from the same font/baseline as the rows.
    weak var hexView: HexView?

    /// The clip view's horizontal scroll offset; the drawing shifts left by it
    /// so each label tracks the column it names.
    var horizontalOffset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    /// The column names at the row's edges.
    private static let offsetTitle = "Offset"
    private static let asciiTitle = "Decoded text"

    /// The sequential byte offset shown above a hex cell: "00".."0F", one
    /// two-digit index per byte, aligned with the byte's cell (§6).
    private static func columnIndex(_ column: Int) -> String {
        String(format: "%02X", column)
    }

    /// Vertical padding above and below the labels. Without it the strip is one
    /// hex row tall and the ink — drawn at the row baseline — nearly touches the
    /// top and bottom edges (§6).
    static let verticalPadding: CGFloat = 4

    /// Height: one hex row plus symmetric top/bottom padding, so the labels
    /// have breathing room instead of hugging the strip's edges.
    var headerHeight: CGFloat { (hexView?.hexLayout.rowHeight ?? 17) + 2 * Self.verticalPadding }

    /// How many times the pane has told the header the grid geometry changed
    /// (word size / appearance). A test hook: `needsDisplay` isn't reliably
    /// readable in a headless test host, so tests assert this instead.
    private(set) var gridRefreshCount = 0

    /// Redraws the header because the underlying grid geometry changed (word
    /// size, appearance). The label positions are re-derived from
    /// `hexView.hexLayout` in `draw`, so a plain redraw is enough.
    func refreshForGridChange() {
        gridRefreshCount += 1
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let hexView else { return }
        let layout = hexView.hexLayout

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // The labels are drawn at the grid's own x positions, and "Decoded
        // text" sits at the far end of a full hex row — in a pane too narrow
        // to show a whole row it lands past the strip's trailing edge, as does
        // the rule below. `NSView` does not clip its drawing to its bounds, so
        // without this the strip paints straight over whatever sits beside the
        // pane: the other file pane, the minimap. The rows themselves need no
        // such clip — they are inside the scroll view's clip view; this strip
        // is pinned outside it (§6).
        NSBezierPath(rect: bounds).setClip()
        NSGraphicsContext.current?.cgContext.translateBy(x: -horizontalOffset, y: 0)

        // The row baseline shifted down by the header's vertical padding, so
        // the ink stays centered in the taller strip.
        let baseline = hexView.hexBaseline + Self.verticalPadding
        draw(Self.offsetTitle, x: layout.offsetColumnFrame(row: 0).minX, baseline: baseline)
        for column in 0..<HexLayout.bytesPerRow {
            draw(Self.columnIndex(column), x: layout.hexByteX(column: column), baseline: baseline)
        }
        draw(Self.asciiTitle, x: layout.asciiX(column: 0), baseline: baseline)

        // Thin ink-blue rule separating the header from the dump.
        HexTheme.inkBlue.withAlphaComponent(0.35).setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        rule.line(to: NSPoint(x: layout.contentWidth, y: bounds.height - 0.5))
        rule.lineWidth = 1
        rule.stroke()
    }

    private func draw(_ text: String, x: CGFloat, baseline: CGFloat) {
        guard let font = hexView?.hexFont else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: HexTheme.inkBlue,
        ]
        (text as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: attributes)
    }

    /// The frames the labels are drawn into (view coordinates, already shifted
    /// by `horizontalOffset`): the offset title, one frame per byte-offset
    /// index (each as wide as a byte cell), and the ASCII title. Exposed
    /// (internal) for tests.
    func labelFrames() -> (offset: CGRect, columns: [CGRect], ascii: CGRect) {
        let layout = hexView?.hexLayout ?? HexLayout(charWidth: 8, rowHeight: 17)
        let shift = -horizontalOffset
        let height = headerHeight
        let columns = (0..<HexLayout.bytesPerRow).map { column in
            CGRect(x: layout.hexByteX(column: column) + shift, y: 0,
                   width: layout.hexByteWidth, height: height)
        }
        return (
            CGRect(x: layout.offsetColumnFrame(row: 0).minX + shift, y: 0,
                   width: layout.offsetColumnWidth, height: height),
            columns,
            CGRect(x: layout.asciiX(column: 0) + shift, y: 0,
                   width: layout.asciiColumnWidth, height: height)
        )
    }
}
