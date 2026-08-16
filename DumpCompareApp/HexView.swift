import Cocoa
import DumpCompareCore

/// What changed in the pane's content, so the hex view can invalidate only the
/// affected rows or columns instead of repainting the whole pane — the content
/// counterpart of the selection-only redraw (§3.3 extension). The view model
/// reports the affected region; the view computes the dirty screen rects from
/// it.
enum HexViewChange: Equatable {
    /// Bytes were overwritten in this range — the glyphs and fills in those
    /// rows must repaint. Row-granular: one whole row redraws per touched byte.
    case bytes(in: Range<UInt64>)
    /// The text decoder changed — only the decoded-text column is affected.
    case textDecoding
}

/// Supplies the bytes and selection the hex view renders (§6).
@MainActor
protocol HexViewDataSource: AnyObject {
    var fileSize: UInt64 { get }
    func hexByteStates(in range: Range<UInt64>) -> [HexByteState]
    func hexSelection() -> SelectionModel
    func hexCaretNibble() -> Int
    func hexInputRegion() -> HexInputRegion
    /// The opposite pane's selection, clamped to this pane's file size — what
    /// this pane frames to mirror the other pane (§3.3). Nil in single-file
    /// mode (no companion).
    func hexMirroredSelection() -> SelectionModel?
}

/// Receives editing input from the hex view (§7). The view-model owns caret,
/// selection, and edit semantics; the view only captures input and renders.
@MainActor
protocol HexEditorDelegate: AnyObject {
    func hexEditor(_ editor: HexView, typeHexNibble digit: Int)
    func hexEditor(_ editor: HexView, typeASCIIByte byte: UInt8)
    func hexEditorDeleteForward(_ editor: HexView)
    func hexEditorDeleteBackward(_ editor: HexView)
    func hexEditor(_ editor: HexView, moveCaretBy delta: Int64, extendSelection: Bool)
    func hexEditor(_ editor: HexView, moveCaretTo offset: UInt64, extendSelection: Bool)
    func hexEditorSelectAll(_ editor: HexView)
    func hexEditor(_ editor: HexView, didClickAt offset: UInt64, region: HexInputRegion, extendSelection: Bool, nibble: Int)
}

/// A virtualized hex dump: only rows intersecting the visible rect are drawn,
/// so arbitrarily large files scroll without materializing their rows (§6,
/// §13.8). Rendered from a `HexViewDataSource` and driven by a
/// `HexEditorDelegate`.
final class HexView: NSView {
    weak var dataSource: HexViewDataSource?
    weak var delegate: HexEditorDelegate?

    /// Fired when this hex view becomes the window's first responder, i.e. the
    /// pane the user is actually editing in. The pane uses it to make the
    /// active-pane pointer follow keyboard focus (§3.3), so clicking a dump and
    /// typing into it always target the same pane.
    var onFocus: (() -> Void)?

    /// Whether this hex view is the active pane. The caret is drawn only on the
    /// active pane, and only when there is no selection (§3.3); both panes draw
    /// closed contours mirroring the *other* pane's selection, and the inactive
    /// pane additionally traces the active pane's bare caret as a single-byte
    /// contour. Defaults to true (single-file mode).
    var isActive = true {
        didSet { needsDisplay = true }
    }

    /// Accessible label for the grid, e.g. "Hex dump — File A" (§15).
    var accessibilityTitle = "Hex dump"

    /// The active text decoder for the decoded-text column. The view model
    /// rebuilds this whenever the user changes the decoding settings.
    var textDecoder: any TextDecoder {
        didSet {
            // The decoded-text column's one-string path depends on the new
            // decoder's characters, so its monospacing verdict is re-derived.
            asciiColumnMonospacedCheck = nil
            // Only the decoded-text column is drawn from the decoder — the hex
            // glyphs are decoder-independent. Invalidate just that band, so a
            // decoding change repaints the ASCII column instead of the whole
            // pane (§3.3 extension).
            invalidateTextColumn()
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var font: NSFont
    private var rowHeight: CGFloat
    private var charWidth: CGFloat
    private var baseline: CGFloat
    private var currentLayout: HexLayout
    private var wordSizeObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var textDecodingObserver: NSObjectProtocol?
    /// Observes the enclosing scroll view's clip frame so the document width
    /// tracks the viewport; `layout()` alone isn't called on a frame-based
    /// document view when the scroll view resizes (§6). The clip posts
    /// `frameDidChange` on resize and `boundsDidChange` on scroll — the width
    /// only depends on the former.
    private var clipFrameObserver: NSObjectProtocol?

    /// Attribute dictionaries shared by every glyph in the row (§ Option B): the
    /// hex, offset, and decoded-text columns draw with the same handful of
    /// colours, so one dictionary per colour replaces a fresh dictionary per
    /// glyph. Built with the current `font`, so it is cleared when the font
    /// changes.
    private var textAttributesCache: [ObjectIdentifier: [NSAttributedString.Key: Any]] = [:]

    /// Cached verdict on whether the decoded-text column can be drawn as one
    /// string (every character the decoder can emit is exactly one cell wide in
    /// the current font). `nil` before the first draw or after the font/decoder
    /// changes.
    private var asciiColumnMonospacedCheck: Bool?

    /// The window point where the current mouse-down landed; the drag-selection
    /// dead zone is anchored to it (§3.3).
    private var mouseDownLocation: CGPoint?
    /// Whether the current click has become a drag. Once the pointer leaves the
    /// dead zone the flag sticks, so later `mouseDragged` events keep extending.
    private var dragEngaged = false
    /// The last drag pointer's window location. The drag-autoscroll timer
    /// converts it back to view coordinates on every tick: the pointer sits at a
    /// fixed spot on screen while the document scrolls under it, so re-deriving
    /// the view position each tick keeps the pointer beyond the visible edge and
    /// the scroll continuous (§6).
    private var lastDragPoint: CGPoint?
    /// Drives continuous scrolling while a drag-selection pointer is held
    /// beyond the visible top or bottom edge (§6): each tick scrolls a step and
    /// extends the selection to the row at the edge. Invalidated when the
    /// pointer re-enters the pane or the drag ends.
    private var autoscrollTimer: Timer?

    /// The offset whose address is framed while its context menu is up — the
    /// row's start address for a right-click on the Offset column, or the
    /// clicked byte's offset for a right-click on a hex byte — or nil when no
    /// context menu is showing. `rightMouseDown` sets it for the lifetime of
    /// the pop-up and clears it on dismissal; `draw(_:)` paints the standard
    /// focus ring around that anchor while it is set (§10.2).
    private(set) var contextMenuOffset: UInt64?

    /// Whether the context-menu frame wraps a single hex byte (the menu was
    /// opened on a byte in the hex column) rather than the Offset column's
    /// row address. Only meaningful while `contextMenuOffset` is set.
    private var contextMenuFramesByte = false

    /// Builds the context menu shown when the user right-clicks an address in
    /// the Offset column or a byte in the hex column. The pane/controller
    /// supplies it so the "Select block from here" and "Copy offset" actions
    /// resolve the exact offset and pane (§10.2). When nil (the default) the
    /// right-click falls through to `super` unchanged.
    var offsetMenuProvider: ((UInt64) -> NSMenu)?

    /// Ideal width of the hex grid (offset column + hex + ASCII). The window
    /// delegate uses this to zoom-to-fit (§3.1) instead of zooming to max.
    var hexContentWidth: CGFloat { currentLayout.contentWidth }

    /// Ideal height of the hex grid — all rows for the current file size. The
    /// window delegate uses this to zoom-to-fit the window height (§3.1).
    var hexContentHeight: CGFloat { currentLayout.totalHeight(fileSize: dataSource?.fileSize ?? 0) }

    /// Geometry of the current dump, used internally for hit-testing and
    /// exposed (internal) for tests. (`layout` itself is NSView's method.)
    var hexLayout: HexLayout { currentLayout }

    /// Font and baseline shared with the pane's column header, so its labels
    /// align with the rows they name.
    var hexFont: NSFont { font }
    var hexBaseline: CGFloat { baseline }

    // MARK: - Init

    init() {
        font = AppearanceSettings.font(size: 13)
        charWidth = AppearanceSettings.charWidth(for: font)
        rowHeight = Self.rowHeight(for: font)
        baseline = AppearanceSettings.centeredBaseline(font: font, rowHeight: rowHeight)
        currentLayout = HexLayout(charWidth: charWidth, rowHeight: rowHeight, wordSize: WordSize.current.rawValue)
        let currentSettings = TextDecodingSettingsStore().settings
        textDecoder = TextDecoderRegistry.make(identifier: currentSettings.identifier, placeholder: currentSettings.placeholder)
        super.init(frame: .zero)
        // Expose the grid to VoiceOver with a live value describing the caret
        // and selection (§15 accessibility).
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // Re-lay out when the word size changes (§6).
        wordSizeObserver = NotificationCenter.default.addObserver(
            forName: WordSize.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        // Re-lay out when the font or row-height factor changes (§3.2).
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        // Rebuild the decoder when text-decoding settings change.
        textDecodingObserver = NotificationCenter.default.addObserver(
            forName: TextDecodingSettingsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTextDecodingSettings()
        }
    }

    deinit {
        if let wordSizeObserver {
            NotificationCenter.default.removeObserver(wordSizeObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let textDecodingObserver {
            NotificationCenter.default.removeObserver(textDecodingObserver)
        }
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
        }
        stopDragAutoscroll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The vertical pitch of one row. The font's natural line height (glyph
    /// ascender→descender, padded by 4pt for breathing room) is scaled down by
    /// the user's row-height factor so more information fits on screen. The
    /// baseline is recomputed from the resulting height, so the glyph ink stays
    /// vertically centred in the tighter row (§3.2).
    private static func rowHeight(for font: NSFont) -> CGFloat {
        let natural = ceil(font.ascender - font.descender) + 4
        return ceil(natural * AppearanceSettings.rowHeightScale)
    }

    /// Re-derives the font metrics and re-lays out after an Appearance change
    /// (§3.2). The frame grows or shrinks with the new row height, so the
    /// enclosing scroll view picks up the new content size.
    private func applyAppearance() {
        font = AppearanceSettings.font(size: 13)
        charWidth = AppearanceSettings.charWidth(for: font)
        rowHeight = Self.rowHeight(for: font)
        baseline = AppearanceSettings.centeredBaseline(font: font, rowHeight: rowHeight)
        // The cached attribute dictionaries carry the old font, and the
        // decoded-text column's monospacing verdict was measured in it.
        textAttributesCache.removeAll()
        asciiColumnMonospacedCheck = nil
        reloadData()
    }

    /// Rebuilds the active text decoder from the current settings.
    private func applyTextDecodingSettings() {
        let store = TextDecodingSettingsStore()
        let currentSettings = store.settings
        textDecoder = TextDecoderRegistry.make(identifier: currentSettings.identifier, placeholder: currentSettings.placeholder)
    }

    // MARK: - Data refresh

    /// The local selection the view last drew (or last diffed against).
    /// `reloadSelection()` compares the current selection against this to
    /// invalidate only the rows whose appearance changed (§3.3).
    private var lastDrawnSelection = SelectionModel.empty(at: 0, fileSize: 0)
    /// The opposite pane's selection the view last drew (nil in single-file
    /// mode, when there is nothing to mirror).
    private var lastDrawnMirroredSelection: SelectionModel?
    /// The caret's input region (hex/ASCII column) the view last drew. The
    /// caret bar lives in one column or the other, so a region change moves it
    /// without moving the selection — `reloadSelection()` invalidates the
    /// caret's row for that (§3.3).
    private var lastDrawnInputRegion: HexInputRegion?

    /// Recomputes the content frame and redraws. Call when the file size,
    /// layout, or content changes — anything a selection-only redraw cannot
    /// cover.
    func reloadData() {
        currentLayout = makeLayout()
        let height = currentLayout.totalHeight(fileSize: dataSource?.fileSize ?? 0)
        let width = max(currentLayout.contentWidth, enclosingScrollView?.contentSize.width ?? currentLayout.contentWidth)
        if width != frame.width || height != frame.height {
            setFrameSize(NSSize(width: width, height: height))
        }
        // A full redraw repaints everything, so the diff baselines catch up to
        // the current state — otherwise a later `reloadSelection` would
        // invalidate rows this redraw already made current.
        lastDrawnSelection = dataSource?.hexSelection() ?? SelectionModel.empty(at: 0, fileSize: 0)
        lastDrawnMirroredSelection = dataSource?.hexMirroredSelection()
        lastDrawnInputRegion = dataSource?.hexInputRegion()
        needsDisplay = true
    }

    /// Redraws only the rows whose rendering changed when the selection moved
    /// (no bytes changed): the rows the old and new local selections cover
    /// differently, plus the same for the mirrored selection. Called on every
    /// drag-selection event and mirrored-caret move. A full `reloadData()` per
    /// event was what made drag selection lag on tall windows — the redraw
    /// cost there scaled with the number of visible rows (§3.3).
    func reloadSelection() {
        let newLocal = dataSource?.hexSelection() ?? SelectionModel.empty(at: 0, fileSize: 0)
        let newMirrored = dataSource?.hexMirroredSelection()
        let newRegion = dataSource?.hexInputRegion()
        var rects = changedSelectionRects(from: lastDrawnSelection, to: newLocal)
        if newMirrored != lastDrawnMirroredSelection {
            rects += changedSelectionRects(
                from: lastDrawnMirroredSelection ?? SelectionModel.empty(at: 0, fileSize: 0),
                to: newMirrored ?? SelectionModel.empty(at: 0, fileSize: 0)
            )
        }
        if newRegion != lastDrawnInputRegion {
            // The caret bar moved between the hex and ASCII columns (a click
            // into the other column): its row must repaint even though the
            // selection itself did not change (§3.3).
            let caret = newLocal.start
            if caret < dataSource?.fileSize ?? 0 {
                let row = Int(caret / UInt64(HexLayout.bytesPerRow))
                rects.append(currentLayout.rowFrame(row: row))
            }
        }
        lastDrawnSelection = newLocal
        lastDrawnMirroredSelection = newMirrored
        lastDrawnInputRegion = newRegion
        for rect in rects {
            setNeedsDisplay(rect)
        }
    }

    /// Row frames whose selection rendering differs between `old` and `new`. A
    /// selection change only ever moves its ends (or a bare caret), so the
    /// affected rows are those spanning the gaps between the old and new
    /// starts and ends — plus the rows a caret sits on, since a caret is drawn
    /// at `start` while a selection fills from its anchor. Exposed (internal)
    /// so tests can pin the exact invalidation contract (§3.3).
    func changedSelectionRects(from old: SelectionModel, to new: SelectionModel) -> [CGRect] {
        var rows = Set<Int>()
        func addRows(in range: Range<UInt64>) {
            guard range.lowerBound < range.upperBound else { return }
            let first = Int(range.lowerBound / UInt64(HexLayout.bytesPerRow))
            let last = Int((range.upperBound - 1) / UInt64(HexLayout.bytesPerRow))
            guard last >= first else { return }
            for row in first...last { rows.insert(row) }
        }
        if old.isEmpty && new.isEmpty {
            // A bare caret moving: only the two caret rows change (the caret is
            // drawn at `start`), not the whole span between them.
            addRows(in: old.start..<old.start + 1)
            addRows(in: new.start..<new.start + 1)
        } else {
            addRows(in: min(old.start, new.start)..<max(old.start, new.start))
            addRows(in: min(old.end, new.end)..<max(old.end, new.end))
            // A caret at `start` appears or disappears at the boundary of a
            // selection; its row is not always inside the gaps above (e.g.
            // selection → caret at a new offset).
            if old.isEmpty { addRows(in: old.start..<old.start + 1) }
            if new.isEmpty { addRows(in: new.start..<new.start + 1) }
        }
        guard !rows.isEmpty else { return [] }
        // The selection's outline — the mirrored contour, the caret bar, the
        // cross-column link — is a stroked line whose top/bottom edges sit on
        // row boundaries when the selection ends at one, and its ~2px stroke
        // (plus rounded corners) extends into the row past that boundary. A
        // redraw of only the changed rows would leave the old far-end edge
        // behind in the preserved row above/below. One row on each side of the
        // changed set catches both the old and the new edge (§3.3).
        var expanded = Set<Int>()
        for row in rows {
            if row > 0 { expanded.insert(row - 1) }
            expanded.insert(row)
            expanded.insert(row + 1)
        }
        return expanded.map { currentLayout.rowFrame(row: $0) }
    }

    /// Redraws only the rows/columns affected by a content change — byte
    /// overwrites or a text-decoder change — instead of repainting the whole
    /// pane. The content counterpart of `reloadSelection()`. Called by the pane
    /// when the view model reports an edit (§3.3 extension).
    func reloadContent(_ change: HexViewChange) {
        for rect in contentChangeRects(change) {
            setNeedsDisplay(rect)
        }
    }

    /// The rects whose rendering changed with `change` — the content
    /// counterpart of `changedSelectionRects`. `.bytes` invalidates the rows the
    /// range spans, clamped to the visible viewport so a huge fill/paste costs
    /// no more than the rows on screen (off-screen rows repaint fresh when
    /// scrolled in — the virtualization guarantee). `.textDecoding` invalidates
    /// the decoded-text column band of the visible viewport. Exposed (internal)
    /// so tests can pin the exact invalidation contract (§3.3 extension).
    func contentChangeRects(_ change: HexViewChange) -> [CGRect] {
        let layout = currentLayout
        let fileSize = dataSource?.fileSize ?? 0
        let viewport = enclosingScrollView?.contentView.bounds ?? bounds
        switch change {
        case .bytes(let range):
            guard range.lowerBound < range.upperBound, range.lowerBound < fileSize else { return [] }
            let first = Int(range.lowerBound / UInt64(HexLayout.bytesPerRow))
            let last = Int((min(range.upperBound, fileSize) - 1) / UInt64(HexLayout.bytesPerRow))
            guard last >= first else { return [] }
            // Intersect the range's rows with the viewport numerically, not by
            // scanning every row in the range: a full-file fill/paste can span
            // millions of rows, and the loop must cost only the rows on screen
            // (off-screen rows repaint fresh when scrolled in — the
            // virtualization guarantee). O(visible) regardless of range size.
            let visible = layout.visibleRowRange(in: viewport)
            let intersectFirst = max(first, visible.lowerBound)
            let intersectLast = min(last, visible.upperBound - 1)
            guard intersectLast >= intersectFirst else { return [] }
            return (intersectFirst...intersectLast).map { layout.rowFrame(row: $0) }
        case .textDecoding:
            guard viewport.height > 0 else { return [] }
            return [CGRect(x: layout.asciiX(column: 0), y: viewport.minY,
                           width: layout.asciiColumnWidth, height: viewport.height)]
        }
    }

    /// Invalidates the decoded-text column band of the visible viewport — the
    /// rect a decoder change can affect. Shares its geometry with
    /// `contentChangeRects(.textDecoding)`.
    private func invalidateTextColumn() {
        for rect in contentChangeRects(.textDecoding) {
            setNeedsDisplay(rect)
        }
    }

    private func makeLayout() -> HexLayout {
        let fileSize = dataSource?.fileSize ?? 0
        let digits = max(8, fileSize > 0 ? String(fileSize, radix: 16).count : 8)
        return HexLayout(charWidth: charWidth, rowHeight: rowHeight,
                         offsetColumnChars: digits, wordSize: WordSize.current.rawValue)
    }

    override func layout() {
        super.layout()
        refreshContentWidth()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Track the enclosing scroll view's viewport: when the pane or window
        // is resized (window zoom-to-fit, splitter drag), the clip's frame
        // changes and the document width must be recomputed — not left at a
        // stale width that would let the pane scroll horizontally into empty
        // space (§6).
        guard let clip = enclosingScrollView?.contentView, clipFrameObserver == nil else { return }
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.refreshContentWidth()
        }
    }

    /// Recomputes the document width to `max(contentWidth, viewport width)`.
    /// `reloadData()` does this for content and word-size changes; this covers
    /// the viewport changing, where the document frame would otherwise stay at
    /// the pre-resize width. The frame is never wider than the content unless
    /// it has to fill a wider viewport, so there is no empty scrollable space.
    private func refreshContentWidth() {
        guard let scroll = enclosingScrollView else { return }
        let width = max(currentLayout.contentWidth, scroll.contentSize.width)
        if width != frame.width {
            setFrameSize(NSSize(width: width, height: frame.height))
        }
    }

    // MARK: - Accessibility (§15)

    override func accessibilityLabel() -> String? { accessibilityTitle }

    override func accessibilityValue() -> Any? {
        guard let dataSource else { return "" }
        let selection = dataSource.hexSelection()
        let size = dataSource.fileSize
        let start = String(selection.start, radix: 16).uppercased()
        if selection.isEmpty {
            return "Offset 0x\(start). File size \(size) bytes."
        }
        let end = String(selection.end, radix: 16).uppercased()
        return "Offset 0x\(start), \(selection.count) bytes selected through 0x\(end). File size \(size) bytes."
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        let ok = super.becomeFirstResponder()
        if ok {
            onFocus?()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Confine all drawing to the dirty region: a selection-only redraw
        // invalidates just the affected rows, and the rows outside them keep
        // their previous pixels. Painting the whole bounds here (or drawing
        // the mirror contour outside the dirty region) would wipe that
        // preserved content (§3.3). With a full `needsDisplay = true` the
        // dirty rect is the whole bounds, so nothing is lost.
        NSBezierPath(rect: dirtyRect).addClip()
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()

        guard let dataSource else { return }
        let layout = currentLayout
        let fileSize = dataSource.fileSize
        let rowCount = layout.rowCount(fileSize: fileSize)
        let selection = dataSource.hexSelection()
        let nibble = dataSource.hexCaretNibble()
        let region = dataSource.hexInputRegion()

        // The three column bands a row can be asked to repaint. Each is tested
        // against the dirty rect, so a `.textDecoding` change (which invalidates
        // only the ASCII band) redraws just the decoded-text column instead of
        // every glyph in every visible row; a full-width dirty rect draws all
        // three, exactly as before (§3.3 extension).
        let drawsOffset = CGRect(x: layout.leftPadding, y: 0,
                                 width: layout.offsetColumnWidth, height: bounds.height)
            .intersects(dirtyRect)
        let hexBand = CGRect(x: layout.hexByteX(column: 0), y: 0,
                             width: layout.hexByteX(column: HexLayout.bytesPerRow - 1)
                                 + layout.hexByteWidth - layout.hexByteX(column: 0),
                             height: bounds.height)
        let asciiBand = CGRect(x: layout.asciiX(column: 0), y: 0,
                               width: layout.asciiColumnWidth, height: bounds.height)
        let drawsHex = hexBand.intersects(dirtyRect)
        let drawsAscii = asciiBand.intersects(dirtyRect)

        let rows = layout.visibleRowRange(in: dirtyRect)

        for row in rows {
            guard UInt64(row) < rowCount else { break }
            drawRow(
                row: row, layout: layout, fileSize: fileSize,
                selection: selection, baseline: baseline,
                drawsOffset: drawsOffset, drawsHex: drawsHex, drawsAscii: drawsAscii
            )
        }

        // Caret: only on the active pane, and only when there is no selection.
        if isActive && selection.isEmpty {
            drawCaret(offset: selection.start, layout: layout, nibble: nibble, region: region, rowCount: rowCount)
        }

        // Cross-column link: with no selection, the active caret outlines the
        // byte in the column it is not in, linking the hex and ASCII views of
        // the same byte — the same rounded contour the mirrors use (§3.3).
        if isActive && selection.isEmpty {
            drawCrossColumnLink()
        }

        // Mirror the opposite pane: a selection is traced with one closed
        // contour on both panes, and a bare caret on the opposite pane is
        // traced onto the inactive pane only (§3.3). `drawMirrorContour`
        // guards internally when there is nothing to mirror.
        drawMirrorContour()

        // Context-menu anchor: while a right-click menu is up, frame the
        // right-clicked anchor with the standard focus ring (§10.2) — the
        // Offset column's row address, or the single byte the menu was opened
        // on in the hex column.
        if let contextMenuOffset, contextMenuOffset < fileSize {
            let (row, column) = layout.rowColumn(of: contextMenuOffset)
            let frame = contextMenuFramesByte
                ? layout.hexByteFrame(row: row, column: column)
                : layout.offsetColumnFrame(row: row)
            drawContextMenuFrame(around: frame)
        }
    }

    /// Draws one row, confined to the column bands the dirty rect intersects
    /// (`drawsOffset`/`drawsHex`/`drawsAscii`). A full-width dirty rect draws all
    /// three in exactly the previous order and output; a column-band-only dirty
    /// rect (the decoded-text column after a decoding change) draws just that
    /// band's fills and glyphs, skipping the other bands' strings (§3.3
    /// extension).
    private func drawRow(row: Int, layout: HexLayout, fileSize: UInt64,
                         selection: SelectionModel, baseline: CGFloat,
                         drawsOffset: Bool, drawsHex: Bool, drawsAscii: Bool) {
        let rowStart = layout.byteOffset(row: row, column: 0)
        let rowEnd = rowStart + UInt64(HexLayout.bytesPerRow)
        let rowY = layout.rowFrame(row: row).minY

        // Offset column.
        if drawsOffset {
            let offsetText = String(rowStart, radix: 16, uppercase: true).leftPadded(to: layout.offsetColumnChars, with: "0")
            draw(text: offsetText, in: layout.offsetColumnFrame(row: row),
                 baseline: baseline, color: HexTheme.inkBlue)
        }

        let states = dataSource?.hexByteStates(in: rowStart..<rowEnd) ?? []

        // Backgrounds: EOF cells and the comparison difference stay per-byte;
        // the selection is one continuous fill across the whole selected span
        // of the row (§6), through the word and group gaps.
        if drawsHex || drawsAscii {
            for column in 0..<HexLayout.bytesPerRow {
                let state = states.indices.contains(column) ? states[column] : HexByteState(isEOF: true)
                guard !state.isEOF, state.isDifferent else { continue }
                HexTheme.differenceFill.setFill()
                let hexFrame = layout.hexByteFrame(row: row, column: column)
                if drawsHex {
                    NSBezierPath(rect: hexFrame).fill()
                }
                if drawsAscii {
                    NSBezierPath(rect: CGRect(x: layout.asciiX(column: column), y: hexFrame.minY,
                                              width: layout.charWidth, height: layout.rowHeight)).fill()
                }
            }
            drawSelectionFill(row: row, rowStart: rowStart, rowEnd: rowEnd,
                              selection: selection, layout: layout,
                              drawsHex: drawsHex, drawsAscii: drawsAscii)
        }

        // EOF placeholder styling, per cell: the muted fill and hatch mark the
        // file's end (§15). A file is a prefix, so EOF cells always trail — the
        // glyph strings below simply end at the first one.
        if drawsHex || drawsAscii {
            for column in 0..<HexLayout.bytesPerRow {
                let state = states.indices.contains(column) ? states[column] : HexByteState(isEOF: true)
                guard state.isEOF else { continue }
                var eofRects: [CGRect] = []
                let hexFrame = layout.hexByteFrame(row: row, column: column)
                if drawsHex { eofRects.append(hexFrame) }
                if drawsAscii {
                    eofRects.append(CGRect(x: layout.asciiX(column: column), y: hexFrame.minY,
                                           width: layout.charWidth, height: layout.rowHeight))
                }
                if !eofRects.isEmpty {
                    HexTheme.eofFill.setFill()
                    for rect in eofRects { NSBezierPath(rect: rect).fill() }
                    // Style cue for EOF (§15): a fine diagonal hatch over the
                    // muted fill so the file's end reads without relying on
                    // color alone.
                    drawEOFHatch(in: eofRects)
                }
            }
        }

        // Cell content: the hex column and the decoded-text column, each drawn
        // as one attributed string of colour runs (§ Option B) — a handful of
        // draw calls per row instead of one per glyph. The hex digits (0-9A-F)
        // and gap spaces are all exactly `charWidth` wide, so the single string
        // lands every glyph on the same cell grid the per-glyph draws did. The
        // decoded-text column is combined only when its characters are
        // monospaced too; otherwise it falls back to per-cell drawing so a wide
        // glyph (a substitute font) never drifts its neighbours.
        if drawsHex {
            let hexString = hexColumnAttributedString(states: states, layout: layout)
            if hexString.length > 0 {
                hexString.draw(at: NSPoint(x: layout.hexByteX(column: 0), y: rowY + baseline))
            }
        }
        if drawsAscii {
            if asciiColumnIsMonospaced {
                let asciiString = asciiColumnAttributedString(states: states)
                if asciiString.length > 0 {
                    asciiString.draw(at: NSPoint(x: layout.asciiX(column: 0), y: rowY + baseline))
                }
            } else {
                drawAsciiCells(states: states, layout: layout, rowY: rowY, baseline: baseline)
            }
        }
    }

    /// The hex column of `states` as one attributed string, colour runs per
    /// byte: each byte's two digits, then the grid spacing between cells — none
    /// inside a word, one space between words, two between the two 8-byte
    /// groups. Drawn at the column's origin, the fixed `charWidth` advance lands
    /// every digit on the same cell the per-glyph code used. EOF cells draw
    /// nothing, so the string ends at the first one. Exposed (internal) so tests
    /// can pin the spacing against the layout's own geometry.
    func hexColumnAttributedString(states: [HexByteState], layout: HexLayout) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentColor: NSColor?
        var pending = ""
        for column in 0..<HexLayout.bytesPerRow {
            guard column < states.count, !states[column].isEOF else { break }
            let color = HexTheme.textColor(for: states[column])
            if color !== currentColor {
                appendRun(&pending, to: result, color: currentColor)
                currentColor = color
            }
            pending += hexDigits(states[column].byte)
            if column < HexLayout.bytesPerRow - 1 {
                let inWord = (column % HexLayout.groupSize) % layout.wordSize
                if inWord == layout.wordSize - 1 {
                    // End of a word: one space (two between the two groups).
                    pending += (column == HexLayout.groupSize - 1) ? "  " : " "
                }
            }
        }
        appendRun(&pending, to: result, color: currentColor)
        return result
    }

    /// The decoded-text column of `states` as one attributed string: sixteen
    /// contiguous characters (the ASCII column has no word or group gaps),
    /// colour per byte — dimmed for non-displayable placeholders, the byte's
    /// text colour otherwise. Drawn in one call only when every emitted
    /// character is one cell wide (`asciiColumnIsMonospaced`).
    private func asciiColumnAttributedString(states: [HexByteState]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentColor: NSColor?
        var pending = ""
        for column in 0..<HexLayout.bytesPerRow {
            guard column < states.count, !states[column].isEOF else { break }
            let state = states[column]
            let char = textDecoder.decode(state.byte)
            let color = textDecoder.isDisplayable(state.byte)
                ? HexTheme.textColor(for: state)
                : HexTheme.mutedTextColor
            if color !== currentColor {
                appendRun(&pending, to: result, color: currentColor)
                currentColor = color
            }
            pending.append(char)
        }
        appendRun(&pending, to: result, color: currentColor)
        return result
    }

    /// Per-cell fallback for the decoded-text column, used when a character the
    /// decoder can emit is wider than one cell (a glyph missing from the font
    /// falls back to a substitute). Each character draws at its own cell's
    /// origin, so a wide glyph never pushes its neighbours off the grid.
    private func drawAsciiCells(states: [HexByteState], layout: HexLayout, rowY: CGFloat, baseline: CGFloat) {
        for column in 0..<HexLayout.bytesPerRow {
            guard column < states.count, !states[column].isEOF else { break }
            let state = states[column]
            let asciiRect = CGRect(x: layout.asciiX(column: column), y: rowY,
                                   width: layout.charWidth, height: layout.rowHeight)
            let char = textDecoder.decode(state.byte)
            let color = textDecoder.isDisplayable(state.byte)
                ? HexTheme.textColor(for: state)
                : HexTheme.mutedTextColor
            draw(text: String(char), in: asciiRect, baseline: baseline, color: color)
        }
    }

    /// Fills the selection's span of `row` as one continuous rectangle through
    /// the hex column and one through the ASCII column — no gaps between words
    /// or byte cells, and no gap between the two 8-byte groups (§6). Each half
    /// is drawn only when its column band is being repainted.
    private func drawSelectionFill(row: Int, rowStart: UInt64, rowEnd: UInt64,
                                   selection: SelectionModel, layout: HexLayout,
                                   drawsHex: Bool, drawsAscii: Bool) {
        let selStart = max(selection.start, rowStart)
        let selEnd = min(selection.end, rowEnd)
        guard selStart < selEnd else { return }
        let firstColumn = Int(selStart - rowStart)
        let lastColumn = Int(selEnd - rowStart) - 1
        let rowFrame = layout.rowFrame(row: row)
        HexTheme.selectionFill.setFill()
        if drawsHex {
            let hexLeft = layout.hexByteX(column: firstColumn)
            let hexRight = layout.hexByteX(column: lastColumn) + layout.hexByteWidth
            NSBezierPath(rect: CGRect(x: hexLeft, y: rowFrame.minY,
                                      width: hexRight - hexLeft, height: layout.rowHeight)).fill()
        }
        if drawsAscii {
            let asciiLeft = layout.asciiX(column: firstColumn)
            let asciiRight = layout.asciiX(column: lastColumn) + layout.charWidth
            NSBezierPath(rect: CGRect(x: asciiLeft, y: rowFrame.minY,
                                      width: asciiRight - asciiLeft, height: layout.rowHeight)).fill()
        }
    }

    /// Draws a fine diagonal hatch over the given rects to mark EOF cells.
    private func drawEOFHatch(in rects: [CGRect]) {
        HexTheme.eofHatch.setStroke()
        for rect in rects {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 2))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 2))
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Closed contours that mirror the opposite pane — one loop around the span
    /// in the hex column and one around it in the ASCII column (the companion's
    /// selection, clamped to this pane's file size). A non-empty selection is
    /// traced on both panes; a bare caret on the companion is traced as a
    /// single byte, but only onto the opposite (inactive) pane, because the
    /// pane that owns the caret already draws it as a bar. Each loop is the
    /// perimeter of the span traced with line segments and padded outward
    /// horizontally so the stroke clears the glyphs — but only where the
    /// boundary is a word boundary, where a spacer already exists. Padding a
    /// boundary that runs through the middle of a word (or between ASCII
    /// characters) would push the line onto the neighbor glyph, so those edges
    /// stay flush. A selection covering several rows reads as one continuous
    /// outline rather than per-row frames. Empty when there is no companion
    /// selection (or nothing to mirror). Exposed (internal) for tests.
    func mirrorContours() -> [[CGPoint]] {
        guard let dataSource,
              let mirrored = dataSource.hexMirroredSelection() else { return [] }
        // A caret-only companion selection mirrors as a single byte onto this
        // pane only when this pane is inactive — the pane that owns the caret
        // would otherwise get a box around its own caret on top of the caret
        // bar and cross-column link.
        let span: SelectionModel
        if mirrored.isEmpty {
            guard !isActive, mirrored.start < dataSource.fileSize else { return [] }
            span = SelectionModel(start: mirrored.start, end: mirrored.start + 1,
                                  fileSize: dataSource.fileSize)
        } else {
            span = mirrored
        }
        let layout = currentLayout
        return [
            contour(of: span, layout: layout, region: .hex),
            contour(of: span, layout: layout, region: .ascii),
        ]
    }

    /// The closed contour of `span` in one column region. The hex column pads
    /// its edges only where a spacer exists — at word boundaries — and the
    /// ASCII column only at its outer edges, so the stroke never lands on a
    /// neighbor glyph. The single source of contour geometry for both the
    /// opposite-pane mirror and the active pane's cross-column link.
    private func contour(of span: SelectionModel, layout: HexLayout,
                         region: HexInputRegion) -> [CGPoint] {
        switch region {
        case .hex:
            let wordSize = layout.wordSize
            return contour(of: span, layout: layout, x: layout.hexByteX, width: layout.hexByteWidth,
                           padLeft: { c in c % wordSize == 0 },
                           padRight: { c in (c + 1) % wordSize == 0 })
        case .ascii:
            return contour(of: span, layout: layout, x: layout.asciiX, width: layout.charWidth,
                           padLeft: { c in c == 0 },
                           padRight: { c in c == HexLayout.bytesPerRow - 1 })
        }
    }

    /// The closed perimeter of `selection` in one column region: a clockwise
    /// polygon tracing the outline of the whole span from its top-left corner.
    /// Steps inward on the first row's left and the last row's right when the
    /// selection starts or ends mid-row; coincident vertices are dropped.
    /// A vertical edge sits `Self.mirrorContourPadding` outside the cells only
    /// when the corresponding `padLeft`/`padRight` permits it (word boundary or
    /// column edge); otherwise it stays flush so the stroke never overlaps a
    /// neighbor glyph.
    private func contour(of selection: SelectionModel, layout: HexLayout,
                         x: @escaping (Int) -> CGFloat, width: CGFloat,
                         padLeft: @escaping (Int) -> Bool,
                         padRight: @escaping (Int) -> Bool) -> [CGPoint] {
        let pad = Self.mirrorContourPadding
        // Left edge of a selected column, padded outward when a spacer precedes
        // the cell.
        let left = { (c: Int) -> CGFloat in x(c) - (padLeft(c) ? pad : 0) }
        // Right edge of a selected column (past its cell), padded outward when
        // a spacer follows the cell.
        let right = { (c: Int) -> CGFloat in x(c) + width + (padRight(c) ? pad : 0) }
        let firstRow = Int(selection.start / UInt64(HexLayout.bytesPerRow))
        let lastRow = Int((selection.end - 1) / UInt64(HexLayout.bytesPerRow))
        let firstCol = Int(selection.start % UInt64(HexLayout.bytesPerRow))
        let lastCol = Int((selection.end - 1) % UInt64(HexLayout.bytesPerRow))
        let topY = layout.rowFrame(row: firstRow).minY
        let bottomY = layout.rowFrame(row: lastRow).maxY
        var points: [CGPoint]
        if firstRow == lastRow || (firstCol == 0 && lastCol == HexLayout.bytesPerRow - 1) {
            // A single row, or several full-width rows: a plain rectangle.
            points = [
                CGPoint(x: left(firstCol), y: topY),
                CGPoint(x: right(lastCol), y: topY),
                CGPoint(x: right(lastCol), y: bottomY),
                CGPoint(x: left(firstCol), y: bottomY),
            ]
        } else {
            // Several rows with a partial first/last row: the right edge steps
            // in at the last row and the left edge steps in at the first row.
            let firstBottomY = layout.rowFrame(row: firstRow).maxY
            let lastTopY = layout.rowFrame(row: lastRow).minY
            points = [
                CGPoint(x: left(firstCol), y: topY),
                CGPoint(x: right(HexLayout.bytesPerRow - 1), y: topY),
                CGPoint(x: right(HexLayout.bytesPerRow - 1), y: lastTopY),
                CGPoint(x: right(lastCol), y: lastTopY),
                CGPoint(x: right(lastCol), y: bottomY),
                CGPoint(x: left(0), y: bottomY),
                CGPoint(x: left(0), y: firstBottomY),
                CGPoint(x: left(firstCol), y: firstBottomY),
            ]
        }
        return deduplicated(points)
    }

    /// Drops vertices that aren't corners, so the polygon stays the minimal
    /// outline of the selection. A selection that starts at column 0 or ends at
    /// column 15 leaves a zero-length "step" edge in the staircase: a pair of
    /// coincident vertices that collapses into one straight-through vertex.
    /// Without removing that too, the rounding pass would treat its 0° turn as
    /// a corner and sweep a 180° semicircle — a "beak" bulging out of the
    /// outline near the bottom-right corner (§3.3).
    private func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
        // Coincident vertices: a zero-length step edge collapses to one vertex.
        var compact: [CGPoint] = []
        for point in points {
            if let last = compact.last, last == point { continue }
            compact.append(point)
        }
        // Straight-through vertices: once the coincident pair is gone, the
        // surviving step vertex has collinear incoming/outgoing edges, so it
        // marks no corner and must go too.
        let n = compact.count
        guard n > 2 else { return compact }
        var result: [CGPoint] = []
        for i in 0..<n {
            let prev = compact[(i - 1 + n) % n]
            let cur = compact[i]
            let next = compact[(i + 1) % n]
            if !Self.isStraightThrough(prev, cur, next) {
                result.append(cur)
            }
        }
        return result
    }

    /// True when `mid` lies on a straight run between `prev` and `next` — the
    /// two edges point the same way, so `mid` marks no corner.
    private static func isStraightThrough(_ prev: CGPoint, _ mid: CGPoint,
                                          _ next: CGPoint) -> Bool {
        let dIn = CGPoint(x: mid.x - prev.x, y: mid.y - prev.y)
        let dOut = CGPoint(x: next.x - mid.x, y: next.y - mid.y)
        let lenIn = hypot(dIn.x, dIn.y)
        let lenOut = hypot(dOut.x, dOut.y)
        guard lenIn > 0, lenOut > 0 else { return false }
        // Same unit direction → collinear same-way; perpendicular or reversed
        // edges are real corners. The staircase's edges are exactly
        // horizontal/vertical, so the dot is exactly 1 for a straight run.
        let dot = (dIn.x * dOut.x + dIn.y * dOut.y) / (lenIn * lenOut)
        return dot > 0.999
    }

    /// The active pane's cross-column link as one closed contour: the byte the
    /// caret sits on, outlined in the column it is not in — the hex cell when
    /// the caret is in the ASCII region, or the ASCII char when it is in the
    /// hex region — so the same byte is highlighted in both columns. Uses the
    /// same contour rules (and therefore the same drawing code) as the
    /// opposite-pane mirror. Empty when this pane is inactive, has no data, or
    /// the caret is at EOF. Exposed (internal) for tests.
    func crossLinkContour() -> [CGPoint] {
        guard isActive, let dataSource else { return [] }
        let fileSize = dataSource.fileSize
        let offset = dataSource.hexSelection().start
        guard offset < fileSize else { return [] }
        let span = SelectionModel(start: offset, end: offset + 1, fileSize: fileSize)
        let region: HexInputRegion = dataSource.hexInputRegion() == .ascii ? .hex : .ascii
        return contour(of: span, layout: currentLayout, region: region)
    }

    /// Draws the active pane's cross-column link (§3.3).
    private func drawCrossColumnLink() {
        drawContours([crossLinkContour()])
    }

    /// Strokes a set of closed contour loops with the shared mirror rendering:
    /// rounded corners and the configured line width and opacity. One code path
    /// for the opposite-pane mirror and the active pane's cross-column link, so
    /// all the accent outlines in the app look the same.
    private func drawContours(_ loops: [[CGPoint]]) {
        guard !loops.isEmpty else { return }
        HexTheme.mirrorFrame.withAlphaComponent(Self.mirrorContourAlpha).setStroke()
        let path = roundedContourPath(loops: loops, radius: Self.mirrorContourRadius)
        path.lineWidth = Self.mirrorContourLineWidth
        path.stroke()
    }

    /// How far the mirrored-selection contour sits outside the cells on the
    /// left and right, so the stroke doesn't overlap the characters.
    static let mirrorContourPadding: CGFloat = 2

    /// Corner radius of the mirrored-selection contour's rounded corners.
    static let mirrorContourRadius: CGFloat = 3

    /// Stroke width of the mirrored-selection contour.
    static let mirrorContourLineWidth: CGFloat = 2

    /// Opacity of the mirrored-selection contour's stroke.
    static let mirrorContourAlpha: CGFloat = 0.6

    /// Strokes the mirrored selection as a single closed contour: the hex and
    /// ASCII loops from `mirrorContours()` are appended to one path and stroked
    /// once, so the outline around the whole selection reads as a single shape
    /// (§3.3). The stroke is padded off the glyphs horizontally, its corners
    /// are rounded, and it is drawn at `mirrorContourAlpha` opacity so it
    /// doesn't fight with the byte highlighting underneath.
    private func drawMirrorContour() {
        drawContours(mirrorContours())
    }

    /// Builds one `NSBezierPath` from the closed contour loops, rounding every
    /// corner of each rectilinear polygon with a `radius`-pt quarter-circle arc
    /// instead of a sharp `line(to:)` join. This has to be done by hand because
    /// `lineJoinStyle = .round` only rounds to `lineWidth / 2` (1px for our 2px
    /// stroke), not the requested 3px.
    ///
    /// For a corner at `points[i]` with unit edge directions `in` (from the
    /// previous vertex) and `out` (to the next), the arc's centre sits on the
    /// corner's inward diagonal — `centre = corner + (out − in) × radius` — and
    /// the arc runs from the tangent point on the incoming edge to the one on
    /// the outgoing edge. The radius is clamped to half the shortest edge so a
    /// narrow step in the staircase can't produce an inverted arc.
    private func roundedContourPath(loops: [[CGPoint]], radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for points in loops {
            guard points.count >= 3 else { continue }
            let n = points.count
            var shortestEdge = CGFloat.greatestFiniteMagnitude
            for i in 0..<n {
                let a = points[i]
                let b = points[(i + 1) % n]
                shortestEdge = min(shortestEdge, hypot(b.x - a.x, b.y - a.y))
            }
            let r = min(radius, shortestEdge / 2)

            // Where the arc leaves the incoming edge, per corner — the anchor
            // for the straight runs between arcs.
            var tangentsIn = [CGPoint](repeating: .zero, count: n)
            for i in 0..<n {
                let dIn = Self.edgeDirection(from: points[(i - 1 + n) % n], to: points[i])
                tangentsIn[i] = CGPoint(x: points[i].x - dIn.x * r,
                                        y: points[i].y - dIn.y * r)
            }

            path.move(to: tangentsIn[0])
            for i in 0..<n {
                let cur = points[i]
                let prev = points[(i - 1 + n) % n]
                let next = points[(i + 1) % n]
                let dIn = Self.edgeDirection(from: prev, to: cur)
                let dOut = Self.edgeDirection(from: cur, to: next)
                let centre = CGPoint(x: cur.x + (dOut.x - dIn.x) * r,
                                     y: cur.y + (dOut.y - dIn.y) * r)
                let tangentOut = CGPoint(x: cur.x + dOut.x * r, y: cur.y + dOut.y * r)
                Self.appendCornerArc(to: path, centre: centre, radius: r,
                                     from: tangentsIn[i], to: tangentOut)
                path.line(to: tangentsIn[(i + 1) % n])
            }
            path.close()
        }
        return path
    }

    /// Unit vector along the edge `from → to`. Consecutive contour vertices are
    /// always distinct, so the edge can't be zero-length here.
    private static func edgeDirection(from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        return CGPoint(x: dx / length, y: dy / length)
    }

    /// Appends the quarter-circle arc that rounds one corner: from the tangent
    /// point on the incoming edge to the one on the outgoing edge, centred on
    /// the corner's inward diagonal. Emitted as short line segments — the sweep
    /// is the ±90° turn the rectilinear polygon makes.
    private static func appendCornerArc(to path: NSBezierPath, centre: CGPoint,
                                        radius: CGFloat, from start: CGPoint,
                                        to end: CGPoint, segments: Int = 6) {
        let startAngle = atan2(start.y - centre.y, start.x - centre.x)
        let endAngle = atan2(end.y - centre.y, end.x - centre.x)
        var sweep = endAngle - startAngle
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        for k in 1...segments {
            let t = CGFloat(k) / CGFloat(segments)
            let angle = startAngle + sweep * t
            path.line(to: CGPoint(x: centre.x + radius * cos(angle),
                                  y: centre.y + radius * sin(angle)))
        }
    }

    private func drawCaret(offset: UInt64, layout: HexLayout, nibble: Int,
                           region: HexInputRegion, rowCount: UInt64) {
        let (row, column) = layout.rowColumn(of: offset)
        guard UInt64(row) < rowCount else { return }
        let x: CGFloat
        let width: CGFloat
        if region == .ascii {
            x = layout.asciiX(column: column)
            width = 1
        } else {
            x = layout.caretX(row: row, column: column, nibble: nibble)
            width = 2
        }
        let rect = CGRect(x: x, y: layout.rowFrame(row: row).minY, width: width, height: layout.rowHeight)
        HexTheme.caretColor.setFill()
        NSBezierPath(rect: rect).fill()
    }

    // MARK: - Text helpers

    private func hexDigits(_ byte: UInt8) -> String {
        let table = Self.hexTable
        return "\(table[Int(byte >> 4)])\(table[Int(byte & 0x0F)])"
    }

    private static let hexTable = Array("0123456789ABCDEF")

    private func draw(text: String, in frame: CGRect, baseline: CGFloat, color: NSColor) {
        (text as NSString).draw(at: NSPoint(x: frame.minX, y: frame.minY + baseline),
                                withAttributes: attributes(for: color))
    }

    /// Attribute dictionary for a text colour: the shared font plus the colour,
    /// with kerning pinned off so a row drawn as one string never shifts a glyph
    /// off its cell (the monospaced fonts already don't kern; this makes it
    /// explicit). Built once per colour and cached (`textAttributesCache`).
    private func attributes(for color: NSColor) -> [NSAttributedString.Key: Any] {
        let key = ObjectIdentifier(color)
        if let cached = textAttributesCache[key] {
            return cached
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: 0,
        ]
        textAttributesCache[key] = attributes
        return attributes
    }

    /// Whether the decoded-text column can be drawn as one string, re-derived
    /// after the font or decoder changes (the verdict is cached in
    /// `asciiColumnMonospacedCheck`).
    private var asciiColumnIsMonospaced: Bool {
        if asciiColumnMonospacedCheck == nil {
            asciiColumnMonospacedCheck = verifyAsciiColumnIsMonospaced()
        }
        return asciiColumnMonospacedCheck == true
    }

    /// Every character the decoder can emit for a row must be exactly one cell
    /// wide in the current font. A glyph missing from the font falls back to a
    /// substitute whose advance can differ — a single string would then drift
    /// every cell after it, so the combined decoded-text column is gated on this
    /// check. The placeholder is already covered: `decode` returns it for every
    /// non-displayable byte.
    private func verifyAsciiColumnIsMonospaced() -> Bool {
        var distinct = Set<Character>()
        for byte in UInt8.min...UInt8.max {
            distinct.insert(textDecoder.decode(byte))
        }
        for char in distinct {
            let width = (String(char) as NSString).size(withAttributes: [.font: font]).width
            if abs(width - charWidth) > 0.001 {
                return false
            }
        }
        return true
    }

    /// Appends the accumulated colour run to a column string, starting a new run.
    private func appendRun(_ pending: inout String, to result: NSMutableAttributedString, color: NSColor?) {
        guard !pending.isEmpty, let color else { return }
        result.append(NSAttributedString(string: pending, attributes: attributes(for: color)))
        pending = ""
    }

    /// The frame around the right-clicked address while its context menu is up
    /// (§10.2). Drawn with the exact same algorithm and style as the selection
    /// contours (§3.3): flush with the row's top and bottom edges, padded
    /// `mirrorContourPadding` outside the left/right edges, then stroked via
    /// `drawContours` with the mirror's accent colour, alpha, line width and
    /// corner radius — so the frame is indistinguishable from a mirror contour.
    private func drawContextMenuFrame(around frame: CGRect) {
        let padded = frame.insetBy(dx: -Self.mirrorContourPadding, dy: 0)
        drawContours([[CGPoint(x: padded.minX, y: padded.minY),
                       CGPoint(x: padded.maxX, y: padded.minY),
                       CGPoint(x: padded.maxX, y: padded.maxY),
                       CGPoint(x: padded.minX, y: padded.maxY)]])
    }

    // MARK: - Scrolling

    /// Scrolls the caret into view within the enclosing scroll view.
    ///
    /// While a mouse drag is in progress the pane is driven by the pointer, not
    /// the caret: the drag anchor may legitimately scroll out of view, and
    /// yanking it back would fight the drag-selection autoscroll (§6). So the
    /// caret is revealed only outside a drag.
    func revealCaret() {
        guard !dragEngaged, let dataSource else { return }
        let layout = currentLayout
        let selection = dataSource.hexSelection()
        let (row, column) = layout.rowColumn(of: selection.start)
        let region = dataSource.hexInputRegion()
        let rect: CGRect
        if region == .ascii {
            rect = CGRect(x: layout.asciiX(column: column),
                          y: layout.rowFrame(row: row).minY,
                          width: layout.charWidth, height: layout.rowHeight)
        } else {
            rect = layout.hexByteFrame(row: row, column: column)
        }
        scrollToVisible(rect)
    }

    /// Scrolls the row containing `offset` to the vertical centre of the visible
    /// area (clamped to the document's edges), so the byte is shown mid-pane
    /// instead of at its top or bottom edge. Used after a search result lands
    /// (§11).
    func revealOffsetCentered(_ offset: UInt64) {
        guard let scroll = enclosingScrollView else { return }
        let layout = currentLayout
        let (row, _) = layout.rowColumn(of: offset)
        let rowFrame = layout.rowFrame(row: row)
        let clip = scroll.contentView
        let maxOriginY = max(0, bounds.height - clip.bounds.height)
        let originY = min(max(0, rowFrame.midY - clip.bounds.height / 2), maxOriginY)
        guard abs(originY - clip.bounds.origin.y) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: originY))
        scroll.reflectScrolledClipView(clip)
    }

    /// Scrolls the current selection (or the caret when there is none) to the
    /// vertical centre of the visible area.
    func revealSelectionCentered() {
        guard let dataSource else { return }
        let selection = dataSource.hexSelection()
        let offset = selection.isEmpty ? selection.start : selection.start + selection.count / 2
        revealOffsetCentered(offset)
    }

    // MARK: - Drag autoscroll (§6)

    /// The furthest the document can scroll down: content height minus the
    /// viewport, or zero when the content fits the viewport.
    private var maxVerticalScroll: CGFloat {
        guard let scroll = enclosingScrollView else { return 0 }
        return max(0, bounds.height - scroll.contentView.bounds.height)
    }

    /// Whether a drag pointer is beyond the visible top or bottom edge.
    private func isBeyondVisibleEdge(_ point: CGPoint) -> Bool {
        guard let scroll = enclosingScrollView else { return false }
        let visible = scroll.contentView.bounds
        return point.y < visible.minY || point.y > visible.maxY
    }

    /// Whether the pane has room to keep scrolling toward a pointer beyond the
    /// visible edge: the document still has rows in that direction.
    private func canAutoscrollToward(_ point: CGPoint) -> Bool {
        guard let scroll = enclosingScrollView else { return false }
        let visible = scroll.contentView.bounds
        if point.y < visible.minY { return visible.origin.y > 0 }
        if point.y > visible.maxY { return visible.origin.y < maxVerticalScroll }
        return false
    }

    /// One drag-autoscroll step. When the pointer is beyond the visible top or
    /// bottom edge, scrolls the pane toward it by exactly the overshoot — the
    /// speed is directly proportional to how far past the edge the pointer
    /// sits, HexFiend's rule, with no saturation (§6) — and returns the
    /// pointer position that should drive the selection: clamped to the visible
    /// edge, so the selection keeps extending to the row at the edge while the
    /// pane scrolls. The point is clamped even when nothing scrolls (the
    /// document edge), so the selection settles at the edge row instead of
    /// stalling where the last scroll step happened to land.
    private func dragAutoscrollStep(at point: CGPoint) -> CGPoint {
        guard let scroll = enclosingScrollView else { return point }
        let clip = scroll.contentView
        let visible = clip.bounds
        let overshoot = point.y < visible.minY ? point.y - visible.minY
            : point.y > visible.maxY ? point.y - visible.maxY
            : 0
        guard overshoot != 0 else { return point }
        // Linear step, taken from HexFiend's autoscroll: it scrolls
        // amountToScroll = overshoot / lineHeight lines per periodic tick,
        // i.e. exactly `overshoot` pixels — the scroll distance equals the
        // pointer's overshoot, so the speed grows in lockstep with how far past
        // the edge the pointer sits. No exponential ramp, no saturation: a
        // pointer barely past the edge creeps, a pointer far out glides fast.
        // The document edge clamps the scroll, as HexFiend's scrollByLines:
        // MIN(maxScroll, location + lines) does.
        let step = abs(overshoot)
        let originY = min(max(0, visible.origin.y + (overshoot > 0 ? step : -step)), maxVerticalScroll)
        if abs(originY - visible.origin.y) > 0.5 {
            clip.setBoundsOrigin(NSPoint(x: visible.origin.x, y: originY))
            scroll.reflectScrolledClipView(clip)
        }
        let current = clip.bounds
        return CGPoint(x: point.x, y: min(max(point.y, current.minY), current.maxY))
    }

    /// Arms the repeating timer that keeps scrolling while a drag pointer is
    /// held beyond the visible top or bottom edge; stops it once the pointer
    /// re-enters the pane or the document runs out. Called from `mouseDragged`.
    private func updateDragAutoscrollTimer(at point: CGPoint) {
        guard isBeyondVisibleEdge(point), canAutoscrollToward(point) else {
            stopDragAutoscroll()
            return
        }
        guard autoscrollTimer == nil else { return }
        // The timer must fire while the mouse button is held with the pointer
        // still. A live probe under NSApplication.run showed the real drag loop
        // runs in the default/common mode (currentMode == nil during
        // mouseDragged) and that .common timers fire there ~30/s, so scheduling
        // in the common modes alone is what keeps the scroll going between drag
        // events. The event-tracking mode is added as well to cover any lap in
        // which AppKit does switch into it — a timer registered for both modes
        // fires in whichever the loop happens to be in.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.performDragAutoscrollTick()
        }
        autoscrollTimer = timer
        RunLoop.main.add(timer, forMode: RunLoop.Mode(rawValue: "kCFRunLoopEventTrackingMode"))
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One autoscroll timer tick: scroll toward the held pointer and extend the
    /// selection to the edge row. Stops once the document edge is reached or
    /// the pointer is no longer beyond the edge. The pointer is re-converted
    /// from the fixed window location every tick, so the scroll keeps going
    /// while the pointer is held beyond the edge and only stops when the
    /// document runs out (§6). Internal (not private) so tests can drive a tick
    /// synchronously without spinning the run loop.
    func performDragAutoscrollTick() {
        guard let last = lastDragPoint, dragEngaged else {
            stopDragAutoscroll()
            return
        }
        let point = convert(last, from: nil)
        let effective = dragAutoscrollStep(at: point)
        extendDragSelection(at: effective)
        // Re-convert after the scroll step: a held pointer's document
        // coordinate advances with the scroll (its screen position stays put,
        // so the content scrolls past it), keeping the overshoot constant. The
        // pre-scroll point would already be inside the post-scroll viewport, so
        // checking it would stop the scroll after the very first step (§6).
        let continuedPoint = convert(last, from: nil)
        if !canAutoscrollToward(continuedPoint) {
            stopDragAutoscroll()
        }
    }

    private func stopDragAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        // A shift-click extends immediately; an unmodified click needs to leave
        // the dead zone before the selection engages.
        dragEngaged = event.modifierFlags.contains(.shift)
        handleMouse(event, extendSelection: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        if !dragEngaged {
            let point = convert(event.locationInWindow, from: nil)
            if let origin = mouseDownLocation, !dragHasLeftDeadZone(from: origin, to: point) {
                return  // still a click — the pointer has not left the dead zone
            }
            dragEngaged = true
        }
        lastDragPoint = event.locationInWindow
        // When the pointer is pushed past the visible top or bottom edge the
        // pane scrolls so the selection can keep extending (§6); while the
        // pointer is held there, `updateDragAutoscrollTimer` keeps the scroll
        // going between drag events. The point is re-derived after the scroll,
        // so a pointer the scroll has already brought inside doesn't re-arm.
        let viewPoint = convert(event.locationInWindow, from: nil)
        let effective = dragAutoscrollStep(at: viewPoint)
        extendDragSelection(at: effective)
        updateDragAutoscrollTimer(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        stopDragAutoscroll()
        mouseDownLocation = nil
        lastDragPoint = nil
        dragEngaged = false
        super.mouseUp(with: event)
    }

    /// What a right-click in the dump anchors the context menu to (§10.2).
    struct ContextMenuAnchor {
        let offset: UInt64
        /// True when the anchor is a single hex byte (the menu was opened on a
        /// byte in the hex column); false when it is the Offset column's row
        /// address, whose frame spans the whole column.
        let framesByte: Bool
    }

    /// Right-click on an address in the Offset column or on a byte in the hex
    /// column: frames the anchor with the standard focus ring and pops the
    /// offset context menu ("Select block from here", "Copy offset") built by
    /// `offsetMenuProvider`. `NSMenu.popUpContextMenu` runs the menu's tracking
    /// loop synchronously, so the frame stays up for the whole time the menu is
    /// visible and clears once it is dismissed (§10.2).
    override func rightMouseDown(with event: NSEvent) {
        guard let anchor = contextMenuAnchor(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        guard let menu = offsetMenuProvider?(anchor.offset) else {
            super.rightMouseDown(with: event)
            return
        }
        contextMenuOffset = anchor.offset
        contextMenuFramesByte = anchor.framesByte
        invalidateContextMenuFrame()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        contextMenuOffset = nil
        contextMenuFramesByte = false
        invalidateContextMenuFrame()
    }

    /// Invalidates the rows the context-menu frame draws on — the anchor's row
    /// plus one on each side, because the frame is a stroked line whose 2px
    /// stroke sits on the row's top/bottom edges and bleeds a pixel into the
    /// adjacent rows (the same convention as `changedSelectionRects`, §3.3).
    /// The frame always lives inside a single row, so no whole-pane redraw is
    /// needed to show or clear it (§3.3 extension).
    private func invalidateContextMenuFrame() {
        guard let contextMenuOffset else { return }
        let row = currentLayout.rowColumn(of: contextMenuOffset).row
        var rows = [row]
        if row > 0 { rows.append(row - 1) }
        rows.append(row + 1)
        for invalidRow in rows {
            setNeedsDisplay(currentLayout.rowFrame(row: invalidRow))
        }
    }

    /// The anchor for a right-click context menu: the Offset column maps to the
    /// row's start address, and the hex column maps to the clicked byte's own
    /// offset. Returns nil for the ASCII column, the gaps, and anywhere past
    /// EOF (the empty caret row, or a placeholder byte in a partial last row).
    func contextMenuAnchor(for event: NSEvent) -> ContextMenuAnchor? {
        guard let dataSource else { return nil }
        let layout = currentLayout
        let point = convert(event.locationInWindow, from: nil)
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)
        guard let hit = layout.hitTest(point: point, rowCount: rowCount) else { return nil }
        let offset: UInt64
        let framesByte: Bool
        switch hit.column {
        case .offset:
            offset = layout.byteOffset(row: hit.row, column: 0)
            framesByte = false
        case .hex(let column):
            offset = layout.byteOffset(row: hit.row, column: column)
            framesByte = true
        case .ascii:
            return nil
        }
        guard offset < dataSource.fileSize else { return nil }
        return ContextMenuAnchor(offset: offset, framesByte: framesByte)
    }

    /// The right-clicked address for a context menu — the row's start offset
    /// for a click on the Offset column, or the clicked byte's offset for a
    /// click in the hex column; nil when the click is in the ASCII column, the
    /// gaps, or past EOF.
    func rightClickedOffset(for event: NSEvent) -> UInt64? {
        contextMenuAnchor(for: event)?.offset
    }

    /// Whether a drag started at `origin` has moved far enough at `point` to
    /// extend the selection. A hex click that lands inside a byte's dead zone —
    /// from the middle of the high-nibble character to the middle of the
    /// low-nibble one (§3.3) — is a mid-byte caret placement, so it must leave
    /// the zone before a drag selects: the zone's boundary sits on the byte's
    /// centre, where a 1 px jitter would otherwise flip the selection end and
    /// select the byte by accident. Clicks outside the zone (a byte's outer
    /// quarters, or the offset/ASCII columns) are clear positions and any drag
    /// engages immediately. The zone spans the click's row, so vertical
    /// movement engages too.
    private func dragHasLeftDeadZone(from origin: CGPoint, to point: CGPoint) -> Bool {
        let layout = currentLayout
        guard let dataSource else { return true }
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)
        guard let hit = layout.hitTest(point: origin, rowCount: rowCount),
              case .hex(let column) = hit.column else { return true }
        let rowFrame = layout.rowFrame(row: hit.row)
        let zoneMinX = layout.highNibbleMidX(column: column)
        let zoneMaxX = layout.lowNibbleMidX(column: column)
        let originInZone = origin.x >= zoneMinX && origin.x <= zoneMaxX
            && origin.y >= rowFrame.minY && origin.y <= rowFrame.maxY
        guard originInZone else { return true }
        let pointInZone = point.x >= zoneMinX && point.x <= zoneMaxX
            && point.y >= rowFrame.minY && point.y <= rowFrame.maxY
        return !pointInZone
    }

    /// Extends the drag selection to the byte whose cell-centre the pointer has
    /// crossed (§6): the byte under the pointer joins the selection — including
    /// the row's last byte, which needs no following byte to be reachable. This
    /// is the drag branch of `handleMouse`, shared with the drag-autoscroll
    /// timer so a pointer held beyond the visible edge keeps selecting as the
    /// pane scrolls.
    private func extendDragSelection(at point: CGPoint) {
        guard let dataSource, let delegate else { return }
        let layout = currentLayout
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)
        let end: UInt64
        if let mapped = layout.dragEndOffset(point: point, rowCount: rowCount) {
            end = mapped
        } else if point.y >= CGFloat(rowCount) * layout.rowHeight {
            // The pointer is below the last row — past EOF, or the pane is
            // scrolled to its bottom edge. A pointer there selects through the
            // end of the file (§6).
            end = dataSource.fileSize
        } else {
            return
        }
        let asciiStart = layout.asciiX(column: 0)
        let region: HexInputRegion = (point.x >= asciiStart && point.x < asciiStart + layout.asciiColumnWidth)
            ? .ascii : .hex
        delegate.hexEditor(self, didClickAt: end, region: region, extendSelection: true, nibble: 0)
    }

    private func handleMouse(_ event: NSEvent, extendSelection: Bool) {
        guard let dataSource, let delegate else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Dragging (or shift-click) extends the selection — see
        // `extendDragSelection`; a plain click places the caret.
        if extendSelection {
            extendDragSelection(at: point)
            return
        }

        let layout = currentLayout
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)
        guard let hit = layout.hitTest(point: point, rowCount: rowCount) else { return }

        let offset: UInt64
        let region: HexInputRegion
        var nibble = 0
        switch hit.column {
        case .offset:
            offset = layout.byteOffset(row: hit.row, column: 0)
            region = .hex
        case .hex(let column):
            offset = layout.byteOffset(row: hit.row, column: column)
            region = .hex
            // A click on the first half of the byte's high-nibble char places
            // the caret before it; anywhere from the second half of that char
            // onward places it between the two chars — a large target, so the
            // mid-byte caret is easy to reach without aiming at the gap (§3.3).
            nibble = (point.x - layout.hexByteX(column: column)) >= layout.charWidth / 2 ? 1 : 0
        case .ascii(let column):
            offset = layout.byteOffset(row: hit.row, column: column)
            region = .ascii
        }
        delegate.hexEditor(self, didClickAt: offset, region: region, extendSelection: extendSelection, nibble: nibble)
    }

    override func keyDown(with event: NSEvent) {
        guard let delegate, let dataSource else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            // Cmd+A / Cmd+C / Cmd+V / Cmd+G… are handled by menu key
            // equivalents; leave this keystroke to the menu system.
            super.keyDown(with: event)
            return
        }

        let chars = event.charactersIgnoringModifiers ?? ""
        let extend = flags.contains(.shift)
        guard let first = chars.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        let value = first.value

        switch value {
        case 0x7F:  // Backspace — fills the previous byte with 0x00 (§7.3)
            delegate.hexEditorDeleteBackward(self)
        case 0xF728:  // Forward Delete — fills the current byte with 0x00
            delegate.hexEditorDeleteForward(self)
        case 0xF700:  // Up
            delegate.hexEditor(self, moveCaretBy: -Int64(HexLayout.bytesPerRow), extendSelection: extend)
        case 0xF701:  // Down
            delegate.hexEditor(self, moveCaretBy: Int64(HexLayout.bytesPerRow), extendSelection: extend)
        case 0xF702:  // Left
            delegate.hexEditor(self, moveCaretBy: -1, extendSelection: extend)
        case 0xF703:  // Right
            delegate.hexEditor(self, moveCaretBy: 1, extendSelection: extend)
        case 0xF72C:  // Page Up
            delegate.hexEditor(self, moveCaretBy: -Int64(pageStep()), extendSelection: extend)
        case 0xF72D:  // Page Down
            delegate.hexEditor(self, moveCaretBy: Int64(pageStep()), extendSelection: extend)
        case 0xF729:  // Home
            delegate.hexEditor(self, moveCaretTo: 0, extendSelection: extend)
        case 0xF72B:  // End
            delegate.hexEditor(self, moveCaretTo: dataSource.fileSize, extendSelection: extend)
        case 0x1B:  // Escape
            super.keyDown(with: event)
        default:
            if dataSource.hexInputRegion() == .hex {
                // Hex column: only printable ASCII digits are meaningful.
                guard value >= 0x20, value <= 0x7E else {
                    super.keyDown(with: event)
                    return
                }
                if let digit = Self.hexDigitValue(value) {
                    delegate.hexEditor(self, typeHexNibble: digit)
                } else {
                    NSSound.beep()
                }
            } else {
                // Decoded text column: any non-control key is tried against the
                // active decoding table; characters it can't encode are rejected
                // with a beep (§3.2).
                guard value >= 0x20 else {
                    super.keyDown(with: event)
                    return
                }
                let character = Character(UnicodeScalar(value)!)
                if let byte = textDecoder.encode(character) {
                    delegate.hexEditor(self, typeASCIIByte: byte)
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func pageStep() -> Int {
        max(1, Int(bounds.height / currentLayout.rowHeight)) * HexLayout.bytesPerRow
    }

    private static func hexDigitValue(_ scalar: UInt32) -> Int? {
        switch scalar {
        case 0x30...0x39: return Int(scalar - 0x30)
        case 0x41...0x46: return Int(scalar - 0x41) + 10
        case 0x61...0x66: return Int(scalar - 0x61) + 10
        default: return nil
        }
    }
}

/// Dynamic colors for hex cells (§6: Dark Mode support, difference = background,
/// unsaved modification = red foreground, selection stays legible).
enum HexTheme {
    static let byteText = NSColor.labelColor

    /// Text for "fill" bytes (0x00, 0xFF) — the label dimmed so significant
    /// bytes stand out (§6). A translucent label keeps the colour mode-correct
    /// and stays legible over selection and difference fills.
    static let mutedByteText = NSColor(name: nil) { _ in
        NSColor.labelColor.withAlphaComponent(0.40)
    }

    /// Muted color for placeholder characters in the decoded text column.
    static let mutedTextColor = NSColor(name: nil) { _ in
        NSColor.labelColor.withAlphaComponent(0.35)
    }

    static let modifiedText = NSColor.systemRed
    static let caretColor = NSColor.controlAccentColor

    /// Ink blue for the column header and the offset column (§6): a pale,
    /// slightly desaturated blue that reads as a quiet secondary element next
    /// to the dump's byte content, lighter on dark backgrounds so it stays
    /// legible without competing with the bytes.
    static let inkBlue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.58, green: 0.73, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.33, green: 0.54, blue: 0.78, alpha: 1)
    }

    /// Text colour for a byte. A modified byte keeps its red warning; otherwise
    /// a fill byte (0x00, 0xFF) is drawn muted so the significant bytes read
    /// more contrasty than the padding around them (§6).
    static func textColor(for state: HexByteState) -> NSColor {
        if state.isModified { return modifiedText }
        if state.byte == 0x00 || state.byte == 0xFF { return mutedByteText }
        return byteText
    }

    static let differenceFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemOrange.withAlphaComponent(0.45)
            : NSColor.systemOrange.withAlphaComponent(0.35)
    }

    static let selectionFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemBlue.withAlphaComponent(0.35)
            : NSColor.systemBlue.withAlphaComponent(0.22)
    }

    static let eofFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 0.5)
            : NSColor(white: 0.80, alpha: 0.5)
    }

    /// Hatch strokes over EOF cells (a non-color "end of file" cue, §15).
    static let eofHatch = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.55, alpha: 0.6)
            : NSColor(white: 0.45, alpha: 0.6)
    }

    /// Thin frame mirroring the opposite pane's selection onto this pane
    /// (§3.3). The accent color ties the two panes' views of the same range.
    static let mirrorFrame = NSColor.controlAccentColor
}

extension String {
    /// Left-pads with `pad` until the string is at least `length` characters.
    func leftPadded(to length: Int, with pad: String) -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}
