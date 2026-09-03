import Cocoa
import Cocoa
import DumpCompareCore

/// What changed in the pane's content, so the hex view can invalidate only the
/// affected rows or columns instead of repainting the whole pane — the content
/// counterpart of the selection-only redraw (§13). The view model
/// reports the affected region; the view computes the dirty screen rects from
/// it.
enum HexViewChange: Equatable {
    /// Bytes were overwritten in this range — the glyphs and fills in those
    /// rows must repaint. Row-granular: one whole row redraws per touched byte.
    case bytes(in: Range<UInt64>)
    /// The text decoder changed — only the decoded-text column is affected.
    case textDecoding
}

/// One piece of the segment partition that intersects a drawn range, with the
/// palette index that tints it (§21.3). The range is the piece's full byte
/// range; the drawing clamps it to the row it fills.
struct HexSegmentSpan: Equatable {
    let range: Range<UInt64>
    let colorIndex: Int
}

/// Supplies the bytes and selection the hex view renders (§6).
@MainActor
protocol HexViewDataSource: AnyObject {
    var fileSize: UInt64 { get }
    /// How far the pane must be scrollable, in bytes: its own file, or the
    /// comparison's extent when the companion is longer (§9). The two panes
    /// scroll by absolute offset, so both must reach the longer file's end; the
    /// rows past this pane's own EOF are simply empty.
    var scrollExtent: UInt64 { get }
    func hexByteStates(in range: Range<UInt64>) -> [HexByteState]
    /// The bookmarked rows in `range` (a range of offsets), for the offset
    /// column's per-row drawing (§20). A set per range rather than a call per
    /// row, the same shape as `hexByteStates`.
    func hexBookmarkedRows(in range: Range<UInt64>) -> Set<UInt64>
    /// The segment pieces in `range` (a range of offsets), with the palette
    /// index that tints each, for the row's background tint (§21.3). A list per
    /// range rather than a call per row, the same shape as `hexBookmarkedRows`.
    /// Empty when the pane is one piece (no cuts) — there is nothing to tint.
    func hexSegmentSpans(in range: Range<UInt64>) -> [HexSegmentSpan]
    /// The matches of the active search that overlap `range`, for the dump's
    /// grey match highlight (§11). A list per range rather than a call per row,
    /// the same shape as `hexSegmentSpans`; a match starting before the range
    /// and reaching into it is included. Empty when no search is active, and
    /// when the set is too large to hold positions for.
    func hexMatchRanges(in range: Range<UInt64>) -> [Range<UInt64>]
    /// The current match — what the find indicator marks in yellow — or nil
    /// when the caret is not on one (§11).
    func hexCurrentMatch() -> Range<UInt64>?
    /// The bookmark on the row containing `offset`, if any (§20.2). One row, not
    /// a range: this answers the questions about a single row — what the mark's
    /// tooltip says, what VoiceOver reads, whether a right-clicked address
    /// carries a mark — where the per-range set above serves the drawing.
    func hexBookmark(atRowContaining offset: UInt64) -> Bookmark?
    func hexSelection() -> SelectionModel
    /// The byte the caret logically occupies for reveal purposes: the moving
    /// edge of the selection (last byte when extended forward, first byte when
    /// extended backward), or the caret itself when the selection is empty.
    func hexCaretRevealOffset() -> UInt64
    func hexCaretNibble() -> Int
    func hexInputRegion() -> HexInputRegion
    /// Whether the caret should be drawn. False while a block is selected and
    /// the user is not typing into it — the selection fill already shows the
    /// active region; true when the selection is empty or when typing is
    /// consuming the selection, so the caret marks the next byte to land (§7.4).
    var hexCaretVisible: Bool { get }
    /// The pane's typing mode: when true the caret is drawn as a red vertical
    /// line at the byte boundary (insert mode) instead of the blue nibble bar.
    var hexInsertMode: Bool { get }
    /// Whether the caret sits on a genuinely half-typed insert-mode byte (the
    /// high nibble landed, the low nibble is still pending) — as opposed to a
    /// mid-byte caret a click placed. The view shows the dim `_` placeholder in
    /// the low-nibble slot only in this state (§7).
    var hexHasPendingInsert: Bool { get }
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
    /// `center` says whether the move should centre the caret if it landed off
    /// screen. The view sets it from whether the caret was *already* off screen
    /// before the move: an arrow pressed while the caret is out of view brings
    /// the view back to it (centred), whereas an arrow that merely pushes the
    /// caret past an edge keeps the minimum-scroll follow (§10.4).
    func hexEditor(_ editor: HexView, moveCaretBy delta: Int64, extendSelection: Bool, center: Bool)
    func hexEditor(_ editor: HexView, moveCaretTo offset: UInt64, extendSelection: Bool, center: Bool)
    func hexEditorSelectAll(_ editor: HexView)
    func hexEditor(_ editor: HexView, didClickAt offset: UInt64, region: HexInputRegion, extendSelection: Bool, nibble: Int)
}

/// A virtualized hex dump: only rows intersecting the visible rect are drawn,
/// so arbitrarily large files scroll without materializing their rows (§6,
/// §13.8). Rendered from a `HexViewDataSource` and driven by a
/// `HexEditorDelegate`.
final class HexView: NSView, NSViewToolTipOwner {
    weak var dataSource: HexViewDataSource?
    weak var delegate: HexEditorDelegate?

    /// Fired when this hex view becomes the window's first responder, i.e. the
    /// pane the user is actually editing in. The pane uses it to make the
    /// active-pane pointer follow keyboard focus (§3.3), so clicking a dump and
    /// typing into it always target the same pane.
    var onFocus: (() -> Void)?

    /// Fired whenever the rows visible in the scroll viewport change — a scroll,
    /// a resize, a content-size change. The minimap uses the reported byte range
    /// to draw its viewport rectangle over the map (§19).
    var onVisibleRangeChanged: ((Range<UInt64>) -> Void)?

    /// Whether this hex view is the active pane. The caret is drawn only on the
    /// active pane, at the next typed byte — the caret when there is no
    /// selection, the selection's leading edge while one is held (§7.4); both
    /// panes draw closed contours mirroring the *other* pane's selection, and
    /// the inactive pane additionally traces the active pane's bare caret as a
    /// single-byte contour. Defaults to true (single-file mode).
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
    /// Observes the clip's bounds for scrolling, so the minimap's viewport
    /// rectangle tracks the visible rows. The clip posts `boundsDidChange` on
    /// scroll (and `frameDidChange` on resize — both feed the same callback).
    private var clipBoundsObserver: NSObjectProtocol?

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
    /// supplies it so the "Select Block from Here at «address»" and "Copy offset" actions
    /// resolve the exact offset and pane (§10.2). When nil (the default) the
    /// right-click falls through to `super` unchanged.
    var offsetMenuProvider: ((UInt64) -> NSMenu)?

    /// Called when an address in the Offset column is double-clicked, with that
    /// row's start offset — the mouse gesture for marking a row (§20.3).
    var onOffsetDoubleClick: ((UInt64) -> Void)?

    /// Asks for the bookmark on row `from` to be moved to row `to`, with `lastRow`
    /// the last row this view draws — the far edge a mark may be dragged to
    /// (§20.6). Returns the row the mark actually landed on, which is not always
    /// `to`: a row another bookmark holds is jumped over, and a mark with nowhere
    /// to go stays where it is (nil). The view drags the mark by the answer, so a
    /// refused step leaves the pointer running ahead of a mark that stopped.
    var onBookmarkDrag: ((_ from: UInt64, _ to: UInt64, _ lastRow: UInt64) -> UInt64?)?

    /// The row of the mark being dragged, updated as it moves (§20.6). Non-nil
    /// for the whole gesture, so a drag that started on a mark moves that mark
    /// instead of extending a selection — including from the autoscroll timer's
    /// ticks, which is what lets a mark be dragged past the visible edge.
    private var draggingBookmarkRow: UInt64?

    /// The row the pointer was last resolved to during a mark's drag. A step is
    /// taken only when this changes — the mark answers the pointer *crossing* a
    /// row, not the row the pointer happens to be over (§20.6).
    ///
    /// This is what stops a mark that has just jumped over another from shuffling
    /// back and forth: after the jump the mark sits past the obstacle while the
    /// pointer is still on the obstacle's row, so re-reading that row would
    /// compute the jump again — in the other direction, since the mark is now on
    /// the far side of it. Answering only the crossing makes the jump final until
    /// the pointer really moves on.
    private var draggingBookmarkPointerRow: Int?

    /// How far past a row's edge the pointer must travel before a drag counts it
    /// as being on the next row (§20.6). A hand resting on a mouse jitters by
    /// about a pixel, and on a row boundary that jitter would step the mark to
    /// and fro; two points of hysteresis costs nothing at the speed a drag
    /// actually moves and makes the boundary hold still.
    static let bookmarkDragHysteresis: CGFloat = 2

    /// Ideal width of the hex grid (offset column + hex + ASCII). The window
    /// delegate uses this to zoom-to-fit (§3.1) instead of zooming to max.
    var hexContentWidth: CGFloat { currentLayout.contentWidth }

    /// Ideal height of the hex grid — all rows for the current file size. The
    /// window delegate uses this to zoom-to-fit the window height (§3.1).
    var hexContentHeight: CGFloat { currentLayout.totalHeight(fileSize: dataSource?.scrollExtent ?? 0) }

    /// Geometry of the current dump, used internally for hit-testing and
    /// exposed (internal) for tests. (`layout` itself is NSView's method.)
    var hexLayout: HexLayout { currentLayout }

    /// Font and baseline shared with the pane's column header, so its labels
    /// align with the rows they name.
    var hexFont: NSFont { font }
    var hexBaseline: CGFloat { baseline }

    // MARK: - Init

    init() {
        font = AppearanceSettings.font()
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
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
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
    /// enclosing scroll view picks up the new content size. The row that sat at
    /// the vertical centre of the viewport before the change is re-centred
    /// after it, so the middle of what was visible stays mid-pane instead of
    /// drifting with the rescaled document.
    private func applyAppearance() {
        // Capture the anchor in the *old* layout, before the metrics change.
        let anchor = visibleCenterOffset()
        font = AppearanceSettings.font()
        charWidth = AppearanceSettings.charWidth(for: font)
        rowHeight = Self.rowHeight(for: font)
        baseline = AppearanceSettings.centeredBaseline(font: font, rowHeight: rowHeight)
        // The cached attribute dictionaries carry the old font, and the
        // decoded-text column's monospacing verdict was measured in it.
        textAttributesCache.removeAll()
        asciiColumnMonospacedCheck = nil
        reloadData()
        if let anchor {
            centerRow(containing: anchor)
        }
    }

    /// The byte offset at the vertical centre of the current viewport, measured
    /// in the *current* (pre-change) layout — the anchor `applyAppearance`
    /// re-centres after a row-height or font change, so the middle of what was
    /// visible stays mid-pane (§3.2). Nil when there is nothing to anchor: no
    /// scroll view, an empty file, or a zero-height viewport.
    private func visibleCenterOffset() -> UInt64? {
        guard let dataSource, let clip = enclosingScrollView?.contentView else { return nil }
        let extent = dataSource.scrollExtent
        guard extent > 0, clip.bounds.height > 0 else { return nil }
        let layout = currentLayout
        let centreY = clip.bounds.minY + clip.bounds.height / 2
        let row = max(0, Int(floor(centreY / layout.rowHeight)))
        return min(UInt64(row) * UInt64(HexLayout.bytesPerRow), extent - 1)
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
        updateContentFrame()
        refreshBookmarkTooltipRect()
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

    /// Past this many rows a per-row invalidation is replaced with one
    /// full-bounds rect: emitting millions of rects would cost more than the
    /// redraw it saves. It costs nothing in fidelity — layer-backed display
    /// draws only the visible part of that rect now and keeps the rest invalid
    /// until it is scrolled to (§3.3).
    private static let maxInvalidatedRows: UInt64 = 4096

    /// Row frames whose selection rendering differs between `old` and `new`. A
    /// selection change only ever moves its ends (or a bare caret), so the
    /// affected rows are exactly those one selection covers and the other does
    /// not — the symmetric difference of the two spans, plus the rows a caret
    /// sits on (a caret is drawn at `start` while a selection fills from its
    /// anchor). Exposed (internal) so tests can pin the exact invalidation
    /// contract (§3.3).
    func changedSelectionRects(from old: SelectionModel, to new: SelectionModel) -> [CGRect] {
        // Each selection as a half-open span; a bare caret occupies the single
        // byte at `start`.
        let oldRange = old.isEmpty ? old.start..<(old.start + 1) : old.start..<old.end
        let newRange = new.isEmpty ? new.start..<(new.start + 1) : new.start..<new.end

        // The head one span alone covers and the tail the other alone covers.
        // Unlike the union of the two gaps this never includes the region
        // between two disjoint spans, so a jump from the caret to a far-away
        // block (a search result, Select Block) invalidates only the rows the
        // selection actually left and entered — never every row between them.
        var ranges: [Range<UInt64>] = []
        if oldRange.lowerBound < newRange.lowerBound {
            ranges.append(oldRange.lowerBound..<min(oldRange.upperBound, newRange.lowerBound))
        } else if newRange.lowerBound < oldRange.lowerBound {
            ranges.append(newRange.lowerBound..<min(newRange.upperBound, oldRange.lowerBound))
        }
        if oldRange.upperBound > newRange.upperBound {
            ranges.append(max(oldRange.lowerBound, newRange.upperBound)..<oldRange.upperBound)
        } else if newRange.upperBound > oldRange.upperBound {
            ranges.append(max(newRange.lowerBound, oldRange.upperBound)..<newRange.upperBound)
        }

        // Off-screen rows are invalidated too — deliberately no viewport clamp.
        // When the view is layer-backed (as in the live app's window), a
        // selection scrolled out of view keeps its old pixels until its rows are
        // marked dirty; the clamp let a stale block survive a scroll away and
        // back. Each XOR piece is bounded by a selection span, so a far jump
        // still costs O(old + new rows) rather than the gap between them. A
        // whole-file change (Select All on a large file) would emit millions of
        // per-row rects, so it falls back to one full-bounds rect; layer-backed
        // display repaints that rect only where visible, so it stays O(visible)
        // per frame (§3.3).
        let totalBytes = ranges.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        if totalBytes / UInt64(HexLayout.bytesPerRow) > Self.maxInvalidatedRows {
            return [bounds]
        }

        var rows = Set<Int>()
        for range in ranges {
            guard range.lowerBound < range.upperBound else { continue }
            let first = Int(range.lowerBound / UInt64(HexLayout.bytesPerRow))
            let last = Int((range.upperBound - 1) / UInt64(HexLayout.bytesPerRow))
            guard last >= first else { continue }
            for row in first...last { rows.insert(row) }
        }

        // A bare caret at P and a one-byte selection [P, P+1) render differently
        // — a thin bar vs a filled cell — yet collapse to the same byte span, so
        // the span XOR above misses the caret→selection handoff: the byte keeps
        // its caret-only pixels and the first selected byte never highlights
        // until a second press repaints the whole row. The caret sits on a
        // point, so whichever side is a caret must mark its row dirty even when
        // its span coincides with the other side's (§3.3).
        if old.isEmpty { rows.insert(Int(old.start / UInt64(HexLayout.bytesPerRow))) }
        if new.isEmpty { rows.insert(Int(new.start / UInt64(HexLayout.bytesPerRow))) }
        // The caret draws on the leading edge of a selection too (§7.4), so a
        // start that moved — typing consumes a byte, or a drag pulls the edge
        // up — must repaint both rows it left and entered. The span XOR alone
        // misses it when the move is a single byte: the old span's head and the
        // new span's head share the same body, so only the byte that stopped
        // being selected is in the symmetric difference, and the caret's new
        // row (at the new start) never repaints.
        if old.start != new.start {
            rows.insert(Int(old.start / UInt64(HexLayout.bytesPerRow)))
            rows.insert(Int(new.start / UInt64(HexLayout.bytesPerRow)))
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
        // A companion edit can change *this* pane's scroll extent — in
        // comparison mode the extent is the longer file (§9) — so the document
        // is resized here too, not only on this pane's own reloads.
        updateContentFrame()
        for rect in contentChangeRects(change) {
            setNeedsDisplay(rect)
        }
    }

    /// Sizes the document to the current layout and scroll extent. Cheap enough
    /// to call on every reload: it only touches the frame when it changed.
    private func updateContentFrame() {
        let height = currentLayout.totalHeight(fileSize: dataSource?.scrollExtent ?? 0)
        let width = max(currentLayout.contentWidth,
                        enclosingScrollView?.contentSize.width ?? currentLayout.contentWidth)
        guard width != frame.width || height != frame.height else { return }
        setFrameSize(NSSize(width: width, height: height))
    }

    /// The rects whose rendering changed with `change` — the content
    /// counterpart of `changedSelectionRects`, and it follows the same
    /// off-screen rule.
    ///
    /// Nothing is clamped to the viewport. A layer-backed view keeps the pixels
    /// of a row it has already drawn, so a byte changed while its row was off
    /// screen still showed its old value when scrolled back to — the very reason
    /// `changedSelectionRects` stopped clamping. Marking the off-screen rows is
    /// cheap: the display draws only the visible part now and defers the rest
    /// until it is scrolled into view. A range spanning more than
    /// `maxInvalidatedRows` falls back to one full-bounds rect rather than
    /// millions of per-row ones.
    ///
    /// `.bytes` invalidates the rows the range spans; `.textDecoding`
    /// invalidates the decoded-text column band over the whole document, since
    /// the decoder feeds every row's text, not just the visible ones. Exposed
    /// (internal) so tests can pin the exact invalidation contract (§3.3
    /// extension).
    func contentChangeRects(_ change: HexViewChange) -> [CGRect] {
        let layout = currentLayout
        let fileSize = dataSource?.fileSize ?? 0
        switch change {
        case .bytes(let range):
            guard range.lowerBound < range.upperBound, range.lowerBound < fileSize else { return [] }
            let first = Int(range.lowerBound / UInt64(HexLayout.bytesPerRow))
            let last = Int((min(range.upperBound, fileSize) - 1) / UInt64(HexLayout.bytesPerRow))
            guard last >= first else { return [] }
            guard UInt64(last - first) + 1 <= Self.maxInvalidatedRows else { return [bounds] }
            return (first...last).map { layout.rowFrame(row: $0) }
        case .textDecoding:
            guard bounds.height > 0 else { return [] }
            return [CGRect(x: layout.asciiX(column: 0), y: 0,
                           width: layout.asciiColumnWidth, height: bounds.height)]
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
            self?.notifyVisibleRangeChanged()
        }
        // A scroll moves the clip's bounds, not its frame, so the viewport
        // rectangle needs a separate observer (§19). frameDidChange covers
        // resizes; boundsDidChange covers scrolling.
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.notifyVisibleRangeChanged()
        }
        notifyVisibleRangeChanged()
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

    // MARK: - Visible range (§19)

    /// The byte range covered by the rows currently visible in the scroll
    /// viewport — the file slice the minimap's viewport rectangle mirrors.
    /// Rows map to bytes row-granular (`[firstRow*16, lastRow*16)`), clamped to
    /// the file size so a viewport past the end never reports bytes that do not
    /// exist. Empty when the file is empty or the view is not in a scroll view.
    func visibleByteRange() -> Range<UInt64> {
        guard let dataSource, let clip = enclosingScrollView?.contentView else {
            return 0..<0
        }
        let fileSize = dataSource.fileSize
        let viewport = clip.bounds
        guard viewport.height > 0, fileSize > 0 else { return 0..<0 }
        let rows = currentLayout.visibleRowRange(in: viewport)
        guard !rows.isEmpty else { return 0..<0 }
        let start = min(UInt64(rows.lowerBound) * UInt64(HexLayout.bytesPerRow), fileSize)
        let end = min(UInt64(rows.upperBound) * UInt64(HexLayout.bytesPerRow), fileSize)
        guard end > start else { return 0..<0 }
        return start..<end
    }

    /// Reports the current visible byte range to `onVisibleRangeChanged`.
    private func notifyVisibleRangeChanged() {
        onVisibleRangeChanged?(visibleByteRange())
    }

    // MARK: - Bookmark tooltips (§20.2)

    /// The tooltip tag covering the Offset column. Internal so a test can see
    /// that the rect is registered at all — the hover itself cannot be driven.
    private(set) var bookmarkTooltipTag: NSView.ToolTipTag?

    /// The rect that tag covers, so an unchanged geometry re-registers nothing:
    /// `reloadData` runs on every edit, and there is no reason to churn AppKit's
    /// tooltip bookkeeping per typed byte.
    private var bookmarkTooltipRect: CGRect?

    /// Registers one tooltip rect over the whole Offset column rather than one
    /// per marked row: AppKit asks the owner for the string at the hovered
    /// point, so a single rect answers for every row and nothing has to be
    /// re-registered when a bookmark is added, renamed or removed — only when
    /// the column itself moves or the content grows.
    private func refreshBookmarkTooltipRect() {
        let layout = currentLayout
        let column = CGRect(x: layout.leftPadding, y: 0,
                            width: layout.offsetColumnWidth + layout.gapAfterOffset,
                            height: max(frame.height, bounds.height))
        guard column.width > 0, column.height > 0 else { return }
        guard column != bookmarkTooltipRect else { return }
        if let bookmarkTooltipTag {
            removeToolTip(bookmarkTooltipTag)
        }
        bookmarkTooltipTag = addToolTip(column, owner: self, userData: nil)
        bookmarkTooltipRect = column
    }

    /// A marked row's NAME under the pointer, and nothing else: the address is
    /// right there under the pointer, drawn on the mark, so a tooltip repeating
    /// it would explain a thing to itself. An unmarked row, and a marked row with
    /// no name, return "" — no tooltip at all (§20.3). The minimap's marks say
    /// the address as well, because there the arrow's position only approximates
    /// it (§19.4.3).
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let dataSource else { return "" }
        let hoveredRow = Int(floor(point.y / currentLayout.rowHeight))
        guard hoveredRow >= 0 else { return "" }
        let offset = currentLayout.byteOffset(row: hoveredRow, column: 0)
        guard offset < dataSource.scrollExtent,
              let bookmark = dataSource.hexBookmark(atRowContaining: offset),
              !bookmark.name.isEmpty else { return "" }
        return bookmark.name
    }

    // MARK: - Accessibility (§15)

    override func accessibilityLabel() -> String? { accessibilityTitle }

    override func accessibilityValue() -> Any? {
        guard let dataSource else { return "" }
        let selection = dataSource.hexSelection()
        let size = dataSource.fileSize
        let start = String(selection.start, radix: 16).uppercased()
        // The bookmark mark is purely visual otherwise, so the row the caret is
        // on says whether it is marked, and what the mark is called — the only
        // way a bookmark reaches a screen reader while moving through the dump
        // (§15, §20.2).
        let mark = dataSource.hexBookmark(atRowContaining: selection.start)
            .map { " Bookmarked row: \($0.displayName)." } ?? ""
        if selection.isEmpty {
            return "Offset 0x\(start).\(mark) File size \(size) bytes."
        }
        let end = String(selection.end, radix: 16).uppercased()
        return "Offset 0x\(start), \(selection.count) bytes selected through 0x\(end).\(mark) File size \(size) bytes."
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

        // The bookmarked rows in the drawn range, asked once per range rather
        // than per row (§20) — the same shape as `hexByteStates`.
        let bookmarkedRows: Set<UInt64>
        if rows.isEmpty {
            bookmarkedRows = []
        } else {
            let lower = UInt64(rows.lowerBound) * UInt64(HexLayout.bytesPerRow)
            let upper = UInt64(rows.upperBound) * UInt64(HexLayout.bytesPerRow)
            bookmarkedRows = dataSource.hexBookmarkedRows(in: lower..<upper)
        }

        // The segment pieces in the drawn range, asked once per range rather
        // than per row (§21.3) — the same shape as `hexBookmarkedRows`. Each row
        // tints the spans that intersect it, split at any cut that falls inside.
        let segmentSpans: [HexSegmentSpan]
        if rows.isEmpty {
            segmentSpans = []
        } else {
            let lower = UInt64(rows.lowerBound) * UInt64(HexLayout.bytesPerRow)
            let upper = UInt64(rows.upperBound) * UInt64(HexLayout.bytesPerRow)
            segmentSpans = dataSource.hexSegmentSpans(in: lower..<upper)
        }

        // The matches in the drawn range, asked once per range like the pieces
        // above (§11). The set answers with whole matches, including one that
        // starts above the range and reaches into it.
        let matchRanges: [Range<UInt64>]
        if rows.isEmpty {
            matchRanges = []
        } else {
            let lower = UInt64(rows.lowerBound) * UInt64(HexLayout.bytesPerRow)
            let upper = UInt64(rows.upperBound) * UInt64(HexLayout.bytesPerRow)
            matchRanges = dataSource.hexMatchRanges(in: lower..<upper)
        }
        // The one match the user is standing on, marked in yellow over
        // everything else (§11).
        let currentMatch = dataSource.hexCurrentMatch()

        // The row whose address carries a right-click menu, if any. A bookmarked
        // row shows that menu through its own mark — outlined instead of filled
        // (§20.4) — because the accent ring lands on top of the fill. A menu
        // opened on a byte frames that byte and leaves the mark alone.
        let contextMenuRowAddress: UInt64? = {
            guard let contextMenuOffset, contextMenuOffset < fileSize,
                  !contextMenuFramesByte else { return nil }
            return layout.byteOffset(row: layout.rowColumn(of: contextMenuOffset).row, column: 0)
        }()

        // Two passes over the rows: every row's backgrounds first, then the
        // find indicator, then every row's glyphs. The indicator is one shape
        // around the whole match (§11) rather than a piece per row, so it cannot
        // be drawn inside a row's own turn — and it has to sit over the fills
        // and under the bytes.
        for pass in RowPass.allCases {
            for row in rows {
                guard UInt64(row) < rowCount else { break }
                let rowAddress = layout.byteOffset(row: row, column: 0)
                drawRow(
                    row: row, layout: layout, fileSize: fileSize,
                    selection: selection, baseline: baseline,
                    drawsOffset: drawsOffset, drawsHex: drawsHex, drawsAscii: drawsAscii,
                    isBookmarked: bookmarkedRows.contains(rowAddress),
                    bookmarkOutlined: rowAddress == contextMenuRowAddress,
                    segmentSpans: segmentSpans,
                    matchRanges: matchRanges,
                    currentMatch: currentMatch,
                    pass: pass
                )
            }
            if pass == .backgrounds, let currentMatch {
                drawFindIndicator(match: currentMatch, layout: layout,
                                  drawsHex: drawsHex, drawsAscii: drawsAscii)
            }
        }

        // Caret: on the active pane, at the byte the next typed character
        // lands on. With a selection the caret is hidden — the selection fill
        // already shows the active region — and reappears at the selection's
        // start the moment typing begins to consume it (text-editor behaviour,
        // §7.4).
        if isActive && dataSource.hexCaretVisible {
            drawCaret(offset: selection.start, layout: layout, nibble: nibble, region: region, rowCount: rowCount)
        }

        // Cross-column link: with no selection, the active caret outlines the
        // byte in the column it is not in, linking the hex and ASCII views of
        // the same byte — the same rounded contour the mirrors use (§3.3). A
        // selection already fills both columns, so the link stays selection-free.
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
        // on in the hex column. A bookmarked row's address is the exception:
        // its mark occupies that exact rect, so the mark is outlined in the
        // bookmark colour instead of being buried under the ring (§20.4).
        if let contextMenuOffset, contextMenuOffset < fileSize {
            let (row, column) = layout.rowColumn(of: contextMenuOffset)
            if contextMenuFramesByte {
                drawContextMenuFrame(around: layout.hexByteFrame(row: row, column: column))
            } else if !isBookmarked(rowStartingAt: layout.byteOffset(row: row, column: 0)) {
                drawContextMenuFrame(around: layout.offsetColumnFrame(row: row))
            }
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
                         drawsOffset: Bool, drawsHex: Bool, drawsAscii: Bool,
                         isBookmarked: Bool, bookmarkOutlined: Bool,
                         segmentSpans: [HexSegmentSpan],
                         matchRanges: [Range<UInt64>],
                         currentMatch: Range<UInt64>?,
                         pass: RowPass) {
        let rowStart = layout.byteOffset(row: row, column: 0)
        let rowEnd = rowStart + UInt64(HexLayout.bytesPerRow)
        let rowY = layout.rowFrame(row: row).minY
        let states = dataSource?.hexByteStates(in: rowStart..<rowEnd) ?? []

        // The part of the current match that falls on this row, as columns —
        // the bytes whose ink the indicator forces (§11).
        let indicatorColumns: Range<Int>? = {
            guard let currentMatch else { return nil }
            let start = max(currentMatch.lowerBound, rowStart)
            let end = min(currentMatch.upperBound, rowEnd)
            guard start < end else { return nil }
            return Int(start - rowStart)..<Int(end - rowStart)
        }()

        if pass == .glyphs {
            drawRowGlyphs(row: row, rowStart: rowStart, rowEnd: rowEnd, rowY: rowY,
                          states: states, layout: layout, fileSize: fileSize,
                          baseline: baseline, drawsHex: drawsHex, drawsAscii: drawsAscii,
                          indicatorColumns: indicatorColumns)
            return
        }

        // Segment tint: a pale band behind the whole row — from the panel's
        // left edge to the row's right edge, the Offset column included — split
        // at any cut that falls inside the row (§21.3). It is the bottom of the layering stack: the offset column,
        // the difference and selection fills, and the glyphs are all drawn over
        // it, so what a byte *is* outranks which piece it belongs to. Drawn
        // whenever any band of the row is repainted, because the band reaches
        // every band — clipped to the dirty rect, it repaints only the part that
        // is actually being redrawn.
        if drawsOffset || drawsHex || drawsAscii {
            drawSegmentTint(row: row, rowStart: rowStart, rowEnd: rowEnd,
                            fileSize: fileSize, layout: layout, spans: segmentSpans)
        }

        // Offset column, on top of the tint.
        if drawsOffset {
            let offsetText = String(rowStart, radix: 16, uppercase: true).leftPadded(to: layout.offsetColumnChars, with: "0")
            let offsetFrame = layout.offsetColumnFrame(row: row)
            if isBookmarked {
                // A bookmarked row's address stands on a purple right-pointing
                // arrow — the breakpoint-style mark the eye catches when scanning
                // rather than reading addresses (§20). The mark is the offset's
                // background, so the address is drawn on top of it in the colour
                // for text on a filled selection. While the row's own right-click
                // menu is up the mark is a purple outline instead: there is no
                // fill to read against, so the address keeps its ink (§20.4).
                // Drawn after the segment tint, so the arrow's tip — which
                // reaches into the gap past the Offset column — is never buried
                // under a piece's band (§21.3).
                drawBookmarkMark(in: layout, row: row, outlined: bookmarkOutlined)
                if bookmarkOutlined {
                    drawOffset(offsetText, in: offsetFrame, baseline: baseline,
                               normal: HexTheme.inkBlue, muted: HexTheme.mutedInkBlue)
                } else {
                    drawOffset(offsetText, in: offsetFrame, baseline: baseline,
                               normal: HexTheme.bookmarkTextColor,
                               muted: HexTheme.mutedBookmarkText)
                }
            } else {
                drawOffset(offsetText, in: offsetFrame, baseline: baseline,
                           normal: HexTheme.inkBlue, muted: HexTheme.mutedInkBlue)
            }
        }

        // The grey match highlight: every occurrence of the search pattern,
        // under the difference fill (§6, §11). Grey yields to orange because
        // telling two dumps apart is what the app is for — a match buried under
        // a difference is still reachable, since Find Next brings the indicator
        // to it and the map marks it.
        if drawsHex || drawsAscii {
            drawMatchFills(row: row, rowStart: rowStart, rowEnd: rowEnd,
                           matches: matchRanges, layout: layout,
                           drawsHex: drawsHex, drawsAscii: drawsAscii)
        }

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
                              drawsHex: drawsHex, drawsAscii: drawsAscii,
                              skipping: indicatorColumns)
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

    }

    /// Which half of a row is being drawn. The row pass runs twice so the find
    /// indicator — one shape around the whole match — can be drawn over every
    /// row's fills and under every row's bytes (§11).
    enum RowPass: CaseIterable {
        case backgrounds
        case glyphs
    }

    /// Cell content: the hex column and the decoded-text column, each drawn as
    /// one attributed string of colour runs (§ Option B) — a handful of draw
    /// calls per row instead of one per glyph. The hex digits (0-9A-F) and gap
    /// spaces are all exactly `charWidth` wide, so the single string lands every
    /// glyph on the same cell grid the per-glyph draws did. The decoded-text
    /// column is combined only when its characters are monospaced too;
    /// otherwise it falls back to per-cell drawing so a wide glyph (a substitute
    /// font) never drifts its neighbours.
    private func drawRowGlyphs(row: Int, rowStart: UInt64, rowEnd: UInt64, rowY: CGFloat,
                               states: [HexByteState], layout: HexLayout, fileSize: UInt64,
                               baseline: CGFloat, drawsHex: Bool, drawsAscii: Bool,
                               indicatorColumns: Range<Int>?) {
        if drawsHex {
            let hexString = hexColumnAttributedString(
                states: states, layout: layout,
                pendingLowNibbleColumn: pendingLowNibbleColumn(rowStart: rowStart, rowEnd: rowEnd,
                                                              fileSize: fileSize),
                indicatorColumns: indicatorColumns)
            if hexString.length > 0 {
                hexString.draw(at: NSPoint(x: layout.hexByteX(column: 0), y: rowY + baseline))
            }
        }
        if drawsAscii {
            if asciiColumnIsMonospaced {
                let asciiString = asciiColumnAttributedString(states: states,
                                                              indicatorColumns: indicatorColumns)
                if asciiString.length > 0 {
                    asciiString.draw(at: NSPoint(x: layout.asciiX(column: 0), y: rowY + baseline))
                }
            } else {
                drawAsciiCells(states: states, layout: layout, rowY: rowY, baseline: baseline,
                               indicatorColumns: indicatorColumns)
            }
        }
    }

    /// Fills the segment tint for one row (§21.3): a pale band edge to edge —
    /// the Offset column included — split at any cut that falls inside the row.
    /// Past the file's end there is no tint: no bytes, no piece.
    ///
    /// Each piece is one continuous rect from its left edge to its right edge,
    /// so a row of pieces reads as one unbroken stretch rather than a row of
    /// tinted cells. The edges are where the eye looks for a boundary, so they
    /// are placed to read cleanly:
    ///
    /// - A piece that opens the row starts at the panel's own left edge — the
    ///   band reaches past the Offset column to the edge, not just the bytes.
    /// - A piece that closes the row ends at the row's right edge.
    /// - A boundary *inside* the row falls at the middle of the gap between the
    ///   two bytes it separates. Two adjacent pieces meet at exactly that point,
    ///   so there is no slit of paper between their fills.
    private func drawSegmentTint(row: Int, rowStart: UInt64, rowEnd: UInt64,
                                 fileSize: UInt64, layout: HexLayout,
                                 spans: [HexSegmentSpan]) {
        guard !spans.isEmpty else { return }
        let rowY = layout.rowFrame(row: row).minY
        let rowHeight = layout.rowHeight
        // The row's bytes end at the file size; past EOF there is no tint.
        let lastByte = min(rowEnd, fileSize)
        guard lastByte > rowStart else { return }

        // The middle of the gap between byte `column - 1` and byte `column` in
        // the hex column — the place a boundary between the two bytes falls.
        func midGapX(before column: Int) -> CGFloat {
            (layout.hexByteX(column: column - 1) + layout.hexByteWidth
             + layout.hexByteX(column: column)) / 2
        }

        for span in spans {
            // The piece's bytes within this row, clamped to the present bytes.
            let start = max(span.range.lowerBound, rowStart)
            let end = min(span.range.upperBound, lastByte)
            guard end > start else { continue }
            let first = Int(start - rowStart)
            let last = Int(end - rowStart) - 1
            HexTheme.segmentTints[span.colorIndex].setFill()

            // Left edge: the panel's own left edge when the piece opens the row
            // (the band reaches past the Offset column to the edge), else the
            // mid-gap before its first byte. Right edge: the row's right edge
            // when the piece closes the row, else the mid-gap after its last
            // byte.
            let left = first == 0 ? bounds.minX : midGapX(before: first)
            let right = last == HexLayout.bytesPerRow - 1
                ? bounds.maxX
                : midGapX(before: last + 1)
            NSBezierPath(rect: CGRect(x: left, y: rowY,
                                      width: right - left, height: rowHeight)).fill()
        }
    }

    /// The hex column of `states` as one attributed string, colour runs per
    /// byte: each byte's two digits, then the grid spacing between cells — none
    /// inside a word, one space between words, two between the two 8-byte
    /// groups. Drawn at the column's origin, the fixed `charWidth` advance lands
    /// every digit on the same cell the per-glyph code used. EOF cells draw
    /// nothing, so the string ends at the first one. Exposed (internal) so tests
    /// can pin the spacing against the layout's own geometry.
    func hexColumnAttributedString(states: [HexByteState], layout: HexLayout,
                                   pendingLowNibbleColumn: Int? = nil,
                                   indicatorColumns: Range<Int>? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentColor: NSColor?
        var pending = ""
        for column in 0..<HexLayout.bytesPerRow {
            guard column < states.count, !states[column].isEOF else { break }
            let color = indicatorColumns?.contains(column) == true
                ? HexTheme.indicatorTextColor(for: states[column])
                : HexTheme.textColor(for: states[column])
            if color !== currentColor {
                appendRun(&pending, to: result, color: currentColor)
                currentColor = color
            }
            if column == pendingLowNibbleColumn {
                // Insert mode, byte half typed: the low nibble is not a zero the
                // user entered, it is an empty slot waiting for the second digit.
                // The dim `_` goes into the row's own string — painting it over
                // the finished row would have to erase the cell first, and that
                // erase punched a hole in whatever the cell stood on: the
                // difference orange, a selection fill, the EOF hatch.
                let digits = hexDigits(states[column].byte)
                pending += String(digits.prefix(1))
                appendRun(&pending, to: result, color: currentColor)
                var slot = "_"
                appendRun(&slot, to: result, color: HexTheme.mutedTextColor)
                currentColor = nil
            } else {
                pending += hexDigits(states[column].byte)
            }
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
    private func asciiColumnAttributedString(states: [HexByteState],
                                             indicatorColumns: Range<Int>? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentColor: NSColor?
        var pending = ""
        for column in 0..<HexLayout.bytesPerRow {
            guard column < states.count, !states[column].isEOF else { break }
            let state = states[column]
            let char = textDecoder.decode(state.byte)
            let inIndicator = indicatorColumns?.contains(column) == true
            let color = textDecoder.isDisplayable(state.byte)
                ? (inIndicator ? HexTheme.indicatorTextColor(for: state)
                               : HexTheme.textColor(for: state))
                : (inIndicator ? HexTheme.mutedIndicatorInk : HexTheme.mutedTextColor)
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
    private func drawAsciiCells(states: [HexByteState], layout: HexLayout, rowY: CGFloat,
                                baseline: CGFloat, indicatorColumns: Range<Int>? = nil) {
        for column in 0..<HexLayout.bytesPerRow {
            guard column < states.count, !states[column].isEOF else { break }
            let state = states[column]
            let asciiRect = CGRect(x: layout.asciiX(column: column), y: rowY,
                                   width: layout.charWidth, height: layout.rowHeight)
            let char = textDecoder.decode(state.byte)
            let inIndicator = indicatorColumns?.contains(column) == true
            let color = textDecoder.isDisplayable(state.byte)
                ? (inIndicator ? HexTheme.indicatorTextColor(for: state)
                               : HexTheme.textColor(for: state))
                : (inIndicator ? HexTheme.mutedIndicatorInk : HexTheme.mutedTextColor)
            draw(text: String(char), in: asciiRect, baseline: baseline, color: color)
        }
    }

    /// Fills the selection's span of `row` as one continuous rectangle through
    /// the hex column and one through the ASCII column — no gaps between words
    /// or byte cells, and no gap between the two 8-byte groups (§6). Each half
    /// is drawn only when its column band is being repainted.
    /// Fills the grey behind every match crossing this row (§11).
    ///
    /// One continuous fill per match, exactly like the selection's: a match
    /// spans its bytes through the word and group gaps, and a match crossing a
    /// row boundary is drawn as its part of each row.
    private func drawMatchFills(row: Int, rowStart: UInt64, rowEnd: UInt64,
                                matches: [Range<UInt64>], layout: HexLayout,
                                drawsHex: Bool, drawsAscii: Bool) {
        guard !matches.isEmpty else { return }
        let rowFrame = layout.rowFrame(row: row)
        HexTheme.matchFill.setFill()
        for match in matches {
            let start = max(match.lowerBound, rowStart)
            let end = min(match.upperBound, rowEnd)
            guard start < end else { continue }
            let firstColumn = Int(start - rowStart)
            let lastColumn = Int(end - rowStart) - 1
            if drawsHex {
                let left = layout.hexByteX(column: firstColumn)
                let right = layout.hexByteX(column: lastColumn) + layout.hexByteWidth
                NSBezierPath(rect: CGRect(x: left, y: rowFrame.minY,
                                          width: right - left, height: layout.rowHeight)).fill()
            }
            if drawsAscii {
                let left = layout.asciiX(column: firstColumn)
                let right = layout.asciiX(column: lastColumn) + layout.charWidth
                NSBezierPath(rect: CGRect(x: left, y: rowFrame.minY,
                                          width: right - left, height: layout.rowHeight)).fill()
            }
        }
    }

    /// Draws the find indicator around the current match (§11): a yellow
    /// bubble with a hairline border and a shadow below and to the right of it
    /// — the relief that tells the current match apart from the greys of all the
    /// others.
    ///
    /// The outline is the **selection mirror's** own: `contour(of:layout:region:)`
    /// and `roundedContourPath` build it, so the indicator stands off the glyphs
    /// exactly as far as a mirrored selection does (2 pt where a spacer allows
    /// it, flush where it would land on a neighbouring glyph), rounds by the
    /// same radius, and traces one staircase around a match that crosses rows
    /// rather than a pill per row. One algorithm, two users — a frame that
    /// hugged the glyphs read as a box drawn on the text rather than as
    /// something the text sits on.
    ///
    /// Drawn between the row backgrounds and the glyphs, which is why the row
    /// pass runs twice (see `RowPass`).
    private func drawFindIndicator(match: Range<UInt64>, layout: HexLayout,
                                   drawsHex: Bool, drawsAscii: Bool) {
        guard let dataSource, match.lowerBound < match.upperBound else { return }
        let span = SelectionModel(start: match.lowerBound, end: match.upperBound,
                                  fileSize: dataSource.fileSize)
        var loops: [[CGPoint]] = []
        if drawsHex { loops.append(contentsOf: contour(of: span, layout: layout, region: .hex)) }
        if drawsAscii {
            loops.append(contentsOf: contour(of: span, layout: layout, region: .ascii))
        }

        // How high the bubble is off the page right now — 0 at rest, 1 at the
        // top of the hop. Everything about the lift follows from it.
        let lift = Self.indicatorLift(atPhase: indicatorBouncePhase())
        let elevation = Self.indicatorElevation(atLift: lift)
        for loop in loops where loop.count >= 3 {
            let path = roundedContourPath(loops: [loop], radius: Self.mirrorContourRadius)
            if lift > 0 {
                // The plate grows about its own centre and does not move: it
                // must stay lined up with the bytes it is highlighting, so the
                // hop expands it evenly in every direction rather than lifting
                // it off its row. What says "higher" is the shadow.
                //
                // Each column's loop scales about its own centre — scaling the
                // two together would drag the hex and text plates towards each
                // other instead of growing them in place.
                let box = path.bounds
                var transform = AffineTransform(translationByX: box.midX, byY: box.midY)
                transform.scale(elevation.scale)
                transform.translate(x: -box.midX, y: -box.midY)
                path.transform(using: transform)
            }
            // The shadow is drawn from the plate's own geometry rather than by
            // `NSShadow`, and that is a correctness decision, not a stylistic
            // one: an `NSShadow` offset is interpreted in whatever coordinate
            // space the current graphics context happens to be in, and this
            // view is drawn through two different ones — the window's layer on
            // screen and a bitmap context under `cacheDisplay` — which
            // disagreed about which way "down" is. Twice the shadow was
            // measured going down in a render test while going up on screen.
            //
            // Strokes of the same path cannot disagree: they live in the same
            // space as the plate, where +y is down because row 1 is drawn
            // below row 0. Each stroke straddles the outline, and the plate's
            // own fill goes on last and hides every inner half — so what is
            // left is an outer halo whose reach is the widest stroke.
            drawIndicatorShadow(around: path, shadow: elevation.ambient)
            drawIndicatorShadow(around: path, shadow: elevation.key)
            HexTheme.findIndicatorFill.setFill()
            path.fill()
        }
    }

    // MARK: - The indicator's hop (§11)

    /// The bubble's shadow at rest, in two parts — the recipe a raised surface
    /// needs, and the reason a single offset shadow read as "bare on the
    /// top-left": with the blur no wider than the drop, the light side gets
    /// nothing at all.
    ///
    /// - **ambient**: no offset, a soft even halo, so the plate has a faint
    ///   edge on *every* side and is not cut out of the page.
    /// - **key**: a short drop down and to the right, which is what gives the
    ///   bottom-right side its weight.
    ///
    /// **Positive height is downward here**, measured rather than assumed: this
    /// view is flipped and `NSShadow` follows the same space, so a negative
    /// height casts the shadow *up* (which is how a first attempt got it
    /// backwards). A render test pins the direction and the weighting.
    static let indicatorAmbientBlur: CGFloat = 2
    static let indicatorAmbientAlpha: CGFloat = 0.28
    /// Short on purpose: the plate is lifted a little way off the page, not
    /// floating above it, so the drop is about a point either way.
    static let indicatorShadowOffset = NSSize(width: 1, height: 1.5)
    static let indicatorShadowBlur: CGFloat = 3
    static let indicatorShadowAlpha: CGFloat = 0.42

    /// How long the hop lasts. Slow enough to be *seen*: at a quarter of a
    /// second the jump registered as a flicker, which is worse than nothing —
    /// the eye reads it as a redraw glitch.
    static let indicatorBounceDuration: TimeInterval = 0.55
    /// How much bigger the plate gets, and how much deeper its shadow, at the
    /// top of the hop. The plate does not move — see `drawFindIndicator`.
    static let indicatorLiftScale: CGFloat = 0.14
    /// The key shadow drops and spreads as the bubble climbs; the ambient halo
    /// widens with it, so the plate keeps its edge on the light side too.
    static let indicatorLiftShadowDrop: CGFloat = 2
    static let indicatorLiftShadowSpread: CGFloat = 1
    static let indicatorLiftShadowBlur: CGFloat = 2.5
    static let indicatorLiftAmbientBlur: CGFloat = 2

    /// When the current hop started, or nil when nothing is hopping.
    private var indicatorBounceStarted: TimeInterval?
    private var indicatorDisplayLink: CADisplayLink?
    /// Forces the hop's phase, for tests that need a frame of the animation
    /// rather than a moment of the clock.
    var indicatorBouncePhaseForTests: CGFloat?

    /// How high off the page the bubble is, `phase` of the way through the hop:
    /// one clear jump and a small second one, the shape a thing that has been
    /// dropped has. 0 at both ends, 1 at the top of the first jump.
    ///
    /// Pure, so the shape is asserted without a clock.
    static func indicatorLift(atPhase phase: CGFloat) -> CGFloat {
        guard phase > 0, phase < 1 else { return 0 }
        /// One parabolic arc between two phases, peaking at `height`.
        func arc(from: CGFloat, to: CGFloat, height: CGFloat) -> CGFloat {
            guard phase >= from, phase <= to else { return 0 }
            let t = (phase - from) / (to - from)
            return height * 4 * t * (1 - t)
        }
        return max(arc(from: 0, to: 0.62, height: 1),
                   arc(from: 0.62, to: 1, height: 0.3))
    }

    /// One shadow of the plate: where it falls, how far it reaches, and how
    /// dark it is at the plate's edge. Two of these make the plate read as
    /// raised (see `indicatorAmbientBlur`).
    struct IndicatorShadow: Equatable {
        /// Offset in the plate's own space: `height` positive is **down**,
        /// because row 1 is drawn below row 0.
        var offset: NSSize
        /// How far past the plate's outline the shadow reaches.
        var blur: CGFloat
        /// Opacity at the plate's edge; it falls off over `blur`.
        var alpha: CGFloat
    }

    /// Paints one shadow as concentric strokes of `path`, offset by the
    /// shadow's own offset: the innermost ring is the darkest and each ring out
    /// is lighter, which is what makes the edge soft. Drawn before the plate's
    /// fill, which covers the inner halves.
    private func drawIndicatorShadow(around path: NSBezierPath, shadow: IndicatorShadow) {
        guard shadow.blur > 0, shadow.alpha > 0 else { return }
        let copy = path.copy() as! NSBezierPath
        if shadow.offset != .zero {
            copy.transform(using: AffineTransform(translationByX: shadow.offset.width,
                                                  byY: shadow.offset.height))
        }
        // One ring per point of reach, plus a half-point step so a fractional
        // reach still draws something.
        let rings = max(Int(shadow.blur.rounded()), 1)
        for ring in (1...rings).reversed() {
            let reach = shadow.blur * CGFloat(ring) / CGFloat(rings)
            // Linear falloff from the edge outwards, and each ring is drawn
            // over the ones outside it, so the accumulated opacity is highest
            // against the plate.
            let alpha = shadow.alpha * (1 - CGFloat(ring - 1) / CGFloat(rings)) / CGFloat(rings)
            HexTheme.indicatorShadow.withAlphaComponent(alpha).setStroke()
            copy.lineWidth = reach * 2
            copy.stroke()
        }
    }

    /// What a given lift does to the bubble: its size, how far it rises, and
    /// the two shadows it casts. Pure and in one place, so "higher means a
    /// bigger shadow" is a fact about the code rather than about three call
    /// sites.
    static func indicatorElevation(atLift lift: CGFloat)
        -> (scale: CGFloat, ambient: IndicatorShadow, key: IndicatorShadow) {
        let clamped = min(max(lift, 0), 1)
        return (scale: 1 + indicatorLiftScale * clamped,
                ambient: IndicatorShadow(
                    offset: .zero,
                    blur: indicatorAmbientBlur + indicatorLiftAmbientBlur * clamped,
                    alpha: indicatorAmbientAlpha + 0.08 * clamped),
                // The plate climbs *visually* while its shadow stays on the
                // page, so the drop between them grows with the height (§11).
                key: IndicatorShadow(
                    offset: NSSize(width: indicatorShadowOffset.width
                                    + indicatorLiftShadowSpread * clamped,
                                   height: indicatorShadowOffset.height
                                    + indicatorLiftShadowDrop * clamped),
                    blur: indicatorShadowBlur + indicatorLiftShadowBlur * clamped,
                    alpha: indicatorShadowAlpha + 0.15 * clamped))
    }

    /// Starts the hop — called when the indicator lands on another match.
    ///
    /// Driven by the view's own `CADisplayLink` (macOS 14's
    /// `displayLink(target:selector:)`), which is the platform's frame clock:
    /// the bubble is painted by `draw(_:)` along with the bytes it sits on, so
    /// what animates is the redraw, and the rows the indicator covers are the
    /// only thing invalidated.
    ///
    /// Core Animation's own `CASpringAnimation` would be the API for this if the
    /// bubble were a layer of its own — see `Design/FIND_HIGHLIGHT_PLAN.md` for
    /// why it is not (a sublayer composites *above* the view's drawing, so the
    /// bubble would cover the bytes it is supposed to sit under).
    func bounceFindIndicator() {
        indicatorBounceStarted = Date().timeIntervalSinceReferenceDate
        if indicatorDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(stepIndicatorBounce))
            link.add(to: .main, forMode: .common)
            indicatorDisplayLink = link
        }
        redrawFindIndicatorRows()
    }

    /// A view that has left its window has no frame clock and nothing to
    /// animate: the hop is dropped rather than left running against a display
    /// link the window took with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endIndicatorBounce() }
    }

    @objc private func stepIndicatorBounce() {
        if indicatorBouncePhase() >= 1 { endIndicatorBounce() }
        redrawFindIndicatorRows()
    }

    /// How far through the hop we are, 0...1; 1 when nothing is hopping.
    private func indicatorBouncePhase() -> CGFloat {
        if let forced = indicatorBouncePhaseForTests { return forced }
        guard let started = indicatorBounceStarted else { return 1 }
        let elapsed = Date().timeIntervalSinceReferenceDate - started
        return CGFloat(min(max(elapsed / Self.indicatorBounceDuration, 0), 1))
    }

    private func endIndicatorBounce() {
        indicatorDisplayLink?.invalidate()
        indicatorDisplayLink = nil
        indicatorBounceStarted = nil
    }

    /// Whether a hop is running, for tests.
    var isBouncingFindIndicatorForTests: Bool { indicatorBounceStarted != nil }

    /// Repaints the rows the indicator covers — the bounce's damage, and all of
    /// it: the pop grows the bubble by a couple of points, which stays inside
    /// the rows it already spans plus the padding around them.
    private func redrawFindIndicatorRows() {
        guard let rect = indicatorDamageRect() else {
            setNeedsDisplay(bounds)
            return
        }
        setNeedsDisplay(rect)
    }

    /// Everything the find indicator can paint over during a hop: the rows its
    /// match crosses, grown by the plate's own growth at the top of the hop and
    /// by the furthest its shadow can then reach.
    ///
    /// The generous margin is the fix for a real artifact, not caution. The
    /// plate is drawn during whatever repaint is in flight — often a full one,
    /// the first time a match is shown after the view has scrolled — so its peak
    /// shadow lands wherever it reaches, while the frames that follow only
    /// invalidated the rows plus a couple of points. On macOS 15 that left the
    /// outer ring of the peak shadow on screen for good: a second, larger
    /// shadow around the settled plate. Nil when there is no current match.
    func indicatorDamageRect() -> NSRect? {
        guard let match = dataSource?.hexCurrentMatch(), match.lowerBound < match.upperBound
        else { return nil }
        let layout = currentLayout
        let firstRow = Int(match.lowerBound / UInt64(HexLayout.bytesPerRow))
        let lastRow = Int((match.upperBound - 1) / UInt64(HexLayout.bytesPerRow))
        let rows = layout.rowFrame(row: firstRow).union(layout.rowFrame(row: lastRow))
        // At the top of the hop the plate is `indicatorLiftScale` bigger about
        // its own centre, so each edge moves out by half of that.
        let growth = Self.indicatorLiftScale / 2
        let peak = Self.indicatorElevation(atLift: 1)
        let reach = max(peak.ambient.blur + abs(peak.ambient.offset.width),
                        peak.key.blur + max(abs(peak.key.offset.width),
                                            abs(peak.key.offset.height)))
        return rows.insetBy(dx: -(rows.width * growth + reach + Self.mirrorContourPadding),
                            dy: -(rows.height * growth + reach + Self.mirrorContourPadding))
    }

    /// Fills the selection for one row, leaving out the columns the find
    /// indicator covers (§11).
    ///
    /// Find Next selects the match it lands on, so the two coincide — and the
    /// yellow plate is the statement about that range. Painting the blue under
    /// it is not only redundant: the plate *rises* during its hop, and the blue
    /// peeked out from under it like a misdrawn edge.
    private func drawSelectionFill(row: Int, rowStart: UInt64, rowEnd: UInt64,
                                   selection: SelectionModel, layout: HexLayout,
                                   drawsHex: Bool, drawsAscii: Bool,
                                   skipping indicatorColumns: Range<Int>? = nil) {
        let selStart = max(selection.start, rowStart)
        let selEnd = min(selection.end, rowEnd)
        guard selStart < selEnd else { return }
        let firstColumn = Int(selStart - rowStart)
        let lastColumn = Int(selEnd - rowStart) - 1
        let rowFrame = layout.rowFrame(row: row)
        HexTheme.selectionFill.setFill()

        // The row's selected columns, minus the indicator's — at most two runs.
        var runs: [ClosedRange<Int>] = [firstColumn...lastColumn]
        if let indicatorColumns {
            runs = runs.flatMap { run -> [ClosedRange<Int>] in
                let cut = indicatorColumns
                guard cut.lowerBound <= run.upperBound, cut.upperBound > run.lowerBound else {
                    return [run]
                }
                var parts: [ClosedRange<Int>] = []
                if run.lowerBound < cut.lowerBound {
                    parts.append(run.lowerBound...(cut.lowerBound - 1))
                }
                if run.upperBound > cut.upperBound - 1 {
                    parts.append(cut.upperBound...run.upperBound)
                }
                return parts
            }
        }

        for run in runs {
            if drawsHex {
                let hexLeft = layout.hexByteX(column: run.lowerBound)
                let hexRight = layout.hexByteX(column: run.upperBound) + layout.hexByteWidth
                NSBezierPath(rect: CGRect(x: hexLeft, y: rowFrame.minY,
                                          width: hexRight - hexLeft,
                                          height: layout.rowHeight)).fill()
            }
            if drawsAscii {
                let asciiLeft = layout.asciiX(column: run.lowerBound)
                let asciiRight = layout.asciiX(column: run.upperBound) + layout.charWidth
                NSBezierPath(rect: CGRect(x: asciiLeft, y: rowFrame.minY,
                                          width: asciiRight - asciiLeft,
                                          height: layout.rowHeight)).fill()
            }
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

    /// Whether the row starting at `rowAddress` carries a bookmark. Asks for
    /// that one row instead of reusing the drawn range's set: the right-click
    /// anchor can sit outside the dirty rows the pass is painting (§20.4).
    private func isBookmarked(rowStartingAt rowAddress: UInt64) -> Bool {
        dataSource?.hexBookmark(atRowContaining: rowAddress) != nil
    }

    /// The bookmark mark: a right-pointing arrow (a rectangle with a pointed
    /// right end) in the bookmark colour that is the marked offset's background
    /// — the breakpoint-style mark the eye catches when scanning rather than
    /// reading addresses (§20).
    ///
    /// Its body is the right-click focus ring's own rect — the Offset column
    /// padded by `mirrorContourPadding`, rounded by `mirrorContourRadius` — so
    /// the mark and the ring are the same shape at the same size; the tip
    /// reaches into the gap before the hex column, never touching it.
    ///
    /// `outlined` strokes that shape instead of filling it, in the bookmark
    /// colour and the ring's line width. That is how a bookmarked row shows its
    /// right-click menu: the accent ring drawn on top of the fill is unreadable,
    /// so the mark itself becomes the ring and the standard frame is skipped
    /// (§20.4).
    private func drawBookmarkMark(in layout: HexLayout, row: Int, outlined: Bool) {
        let frame = Self.bookmarkMarkBody(in: layout, row: row)
        let tip = Self.bookmarkTipReach(height: frame.height, gap: layout.gapAfterOffset)
        let path = Self.bookmarkMarkPath(body: frame, tipReach: tip)
        if outlined {
            HexTheme.bookmarkColor.setStroke()
            path.lineWidth = Self.mirrorContourLineWidth
            // Dashed, not solid: at the ring's line width a closed purple loop
            // around an address reads as a heavy slab, and the mark it replaces
            // was a fill — the dashes say "this row is marked, and the menu is
            // about it" without shouting louder than the mark did (§20.4).
            path.setLineDash(Self.bookmarkOutlineDashes, count: 2, phase: 0)
            path.stroke()
        } else {
            HexTheme.bookmarkColor.setFill()
            path.fill()
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
        return contour(of: span, layout: layout, region: .hex)
            + contour(of: span, layout: layout, region: .ascii)
    }

    /// The closed contour of `span` in one column region. The hex column pads
    /// its edges only where a spacer exists — at word boundaries — and the
    /// ASCII column only at its outer edges, so the stroke never lands on a
    /// neighbor glyph. The single source of contour geometry for both the
    /// opposite-pane mirror and the active pane's cross-column link.
    private func contour(of span: SelectionModel, layout: HexLayout,
                         region: HexInputRegion) -> [[CGPoint]] {
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
                         padRight: @escaping (Int) -> Bool) -> [[CGPoint]] {
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
        } else if firstRow + 1 == lastRow, lastCol < firstCol {
            // Two rows whose parts share no column — a span that starts in the
            // right of one row and ends in the left of the next. There is no
            // staircase to trace here: the outline is two separate rectangles,
            // and joining them produced a line running back across the row
            // boundary between them, which outlined nothing at all.
            let firstBottomY = layout.rowFrame(row: firstRow).maxY
            let lastTopY = layout.rowFrame(row: lastRow).minY
            return [
                deduplicated([
                    CGPoint(x: left(firstCol), y: topY),
                    CGPoint(x: right(HexLayout.bytesPerRow - 1), y: topY),
                    CGPoint(x: right(HexLayout.bytesPerRow - 1), y: firstBottomY),
                    CGPoint(x: left(firstCol), y: firstBottomY),
                ]),
                deduplicated([
                    CGPoint(x: left(0), y: lastTopY),
                    CGPoint(x: right(lastCol), y: lastTopY),
                    CGPoint(x: right(lastCol), y: bottomY),
                    CGPoint(x: left(0), y: bottomY),
                ]),
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
        return [deduplicated(points)]
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
        // A single byte is always one loop.
        return contour(of: span, layout: currentLayout, region: region).first ?? []
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

    /// The apex angle of the bookmark mark's tip (§20.4) — blunt rather than
    /// sharp, so the mark reads as a flag beside the address instead of an arrow
    /// pointing at the bytes. The reach that produces it follows from the mark's
    /// height, so the angle holds at every font size.
    static let bookmarkTipAngle: CGFloat = 120 * .pi / 180

    /// The dash pattern the mark's outline is stroked with while a context menu
    /// is up (§20.4): dash, gap. Internal so a test can sample between dashes.
    static let bookmarkOutlineDashes: [CGFloat] = [3, 2]

    /// The mark's outline: the pentagon of `body` with a `tipReach` point on its
    /// right, corners rounded like the right-click focus ring's (§20.4). Shared
    /// by the fill and the stroke, and by the tests, so the shape is stated once.
    ///
    /// The path starts halfway along the top edge rather than at a corner.
    /// `appendArc` leaves the path on the edge *after* the corner it rounds, so a
    /// path beginning at the top-left vertex ended with `close()` drawing a spur
    /// back into that sharp vertex — a visible notch on the outlined mark.
    /// Starting mid-edge, the closing line runs along the edge itself.
    static func bookmarkMarkPath(body: CGRect, tipReach: CGFloat) -> NSBezierPath {
        let (top, bottom, left, right) = (body.minY, body.maxY, body.minX, body.maxX)
        // Pentagon vertices, clockwise from top-left; the tip is the rightmost.
        let points = [
            NSPoint(x: left, y: top),
            NSPoint(x: right, y: top),
            NSPoint(x: right + tipReach, y: (top + bottom) / 2),
            NSPoint(x: right, y: bottom),
            NSPoint(x: left, y: bottom),
        ]
        let path = NSBezierPath()
        path.move(to: NSPoint(x: (left + right) / 2, y: top))
        for i in 1...points.count {
            path.appendArc(from: points[i % points.count],
                           to: points[(i + 1) % points.count],
                           radius: mirrorContourRadius)
        }
        path.close()
        return path
    }

    /// The bookmark mark's body: the right-click focus ring's own rect, so mark
    /// and ring are one shape at one size (§20.4). The tip grows out of its
    /// right edge.
    static func bookmarkMarkBody(in layout: HexLayout, row: Int) -> CGRect {
        layout.offsetColumnFrame(row: row).insetBy(dx: -mirrorContourPadding, dy: 0)
    }

    /// The rect a bookmark's naming popover points at: the mark on the row
    /// containing `offset`, in this view's coordinates. The popover is about that
    /// row, so it hangs off the mark rather than off the pane (§20.3).
    func bookmarkMarkRect(forRowContaining offset: UInt64) -> CGRect {
        let layout = currentLayout
        return Self.bookmarkMarkBody(in: layout, row: layout.rowColumn(of: offset).row)
    }

    /// The rect a cut's popover points at: the byte cell for `offset` in the hex
    /// column, in this view's coordinates. The popover is about where the cut
    /// will land, so it hangs off that byte rather than off the pane (§21.3).
    /// `.zero` when there is no byte to point at (no file, or an offset past
    /// EOF).
    func byteCellRect(for offset: UInt64) -> CGRect {
        guard let dataSource else { return .zero }
        let layout = currentLayout
        let (row, column) = layout.rowColumn(of: offset)
        guard UInt64(row) < layout.rowCount(fileSize: dataSource.fileSize) else { return .zero }
        let rowFrame = layout.rowFrame(row: row)
        return CGRect(x: layout.hexByteX(column: column), y: rowFrame.minY,
                      width: layout.hexByteWidth, height: rowFrame.height)
    }

    /// The rect a cut's popover points at: the caret's own byte cell in the hex
    /// column. The popover is about where the cut will land, so it hangs off the
    /// caret rather than off the pane (§21.3).
    func caretRect() -> CGRect {
        guard let dataSource else { return .zero }
        return byteCellRect(for: dataSource.hexSelection().start)
    }

    /// How far the bookmark mark's tip reaches past its body for a mark of
    /// `height`, given the `gap` before the hex column. Each of the tip's two
    /// edges rises over half the height, so the reach that opens the apex to
    /// `bookmarkTipAngle` is (height / 2) / tan(angle / 2) — the angle then holds
    /// at every font size, since the height scales with the font. The reach is
    /// clamped to the gap (less the padding the body already spends in it, and a
    /// point of air) because the tip must never touch the hex column (§20.4).
    static func bookmarkTipReach(height: CGFloat, gap: CGFloat) -> CGFloat {
        let reach = (height / 2) / tan(bookmarkTipAngle / 2)
        return max(0, min(reach, gap - mirrorContourPadding - 1))
    }

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

    /// The column of `rowStart..<rowEnd` whose low nibble is an empty slot: the
    /// byte a half-typed insert-mode entry has opened (its high nibble landed,
    /// the second digit is still to come), drawn as a dim `_` inside the row's
    /// own hex string (§7). Nil on every other row and in every other state.
    ///
    /// Guarded to the active pane, insert mode, and a *genuinely pending* insert
    /// (`hexHasPendingInsert`) — a mid-byte caret a click placed (nibble 1,
    /// nothing typed) keeps showing the byte's own low nibble.
    private func pendingLowNibbleColumn(rowStart: UInt64, rowEnd: UInt64,
                                        fileSize: UInt64) -> Int? {
        guard isActive, let dataSource, dataSource.hexInsertMode,
              dataSource.hexHasPendingInsert, dataSource.hexCaretNibble() == 1 else { return nil }
        let offset = dataSource.hexSelection().start
        guard offset >= rowStart, offset < rowEnd, offset < fileSize else { return nil }
        return Int(offset - rowStart)
    }

    private func drawCaret(offset: UInt64, layout: HexLayout, nibble: Int,
                           region: HexInputRegion, rowCount: UInt64) {
        let (row, column) = layout.rowColumn(of: offset)
        guard UInt64(row) < rowCount else { return }
        let insertMode = dataSource?.hexInsertMode ?? false
        let x: CGFloat
        let width: CGFloat
        if insertMode {
            // Insert mode: a thin red vertical line. Before the first digit it
            // sits on the byte's left boundary (where the byte will be
            // inserted); after the first digit it shifts to between the two
            // nibbles, on the low-nibble side. The ASCII region is whole-byte,
            // so its line stays on the cell's left edge.
            x = region == .ascii
                ? layout.asciiX(column: column)
                : layout.hexByteX(column: column) + (nibble == 1 ? layout.charWidth : 0)
            width = 1
        } else if region == .ascii {
            // Overwrite mode: a thick underline under the current character.
            x = layout.asciiX(column: column)
            width = layout.charWidth
        } else {
            x = layout.caretX(row: row, column: column, nibble: nibble)
            width = layout.charWidth
        }
        let rowFrame = layout.rowFrame(row: row)
        let rect: CGRect
        if insertMode {
            // A full-height vertical line.
            rect = CGRect(x: x, y: rowFrame.minY, width: width, height: rowFrame.height)
        } else {
            // An underline at the cell's bottom edge — below the glyph (whose ink
            // is centred in the row), so it never covers the symbol. It starts
            // exactly at the row's last 2 pt and runs 2 pt past the edge, so it
            // reads as a solid bar overlapping the row below (the byte beneath)
            // without eating into the row it belongs to.
            let barHeight: CGFloat = 2
            let extendDown: CGFloat = 2
            rect = CGRect(x: x, y: rowFrame.maxY - barHeight,
                          width: width, height: barHeight + extendDown)
        }
        (insertMode ? HexTheme.insertCaretColor : HexTheme.caretColor).setFill()
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

    /// The offset column's address as an attributed string: the leading zeros in
    /// `muted`, the significant part in `normal` (§6). The split is at the first
    /// non-zero digit, so an all-zero address (row 0) is muted in full. One
    /// attributed string keeps the monospaced cells aligned.
    func offsetAddress(_ offsetText: String, normal: NSColor, muted: NSColor) -> NSAttributedString {
        let leadingZeros = offsetText.prefix(while: { $0 == "0" }).count
        let attributed = NSMutableAttributedString(string: offsetText,
                                                   attributes: attributes(for: normal))
        if leadingZeros > 0 {
            attributed.setAttributes(attributes(for: muted),
                                     range: NSRange(location: 0, length: leadingZeros))
        }
        return attributed
    }

    /// Draws the offset column's address with its leading zeros dimmed, so the
    /// significant part of the address stands out (§6).
    private func drawOffset(_ offsetText: String, in frame: CGRect, baseline: CGFloat,
                            normal: NSColor, muted: NSColor) {
        offsetAddress(offsetText, normal: normal, muted: muted)
            .draw(at: NSPoint(x: frame.minX, y: frame.minY + baseline))
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

    /// Reveals the caret. `center` selects how: a navigation command that jumped
    /// the caret (`center: true`) centres it when it landed outside the viewport
    /// — the join's seam, a search hit, a go-to — while incremental navigation
    /// (arrow keys, mouse, Home/End; `center: false`) takes the minimum scroll
    /// that keeps the caret on screen, with no jump to the centre (§10.4).
    ///
    /// While a mouse drag is in progress the pane is driven by the pointer, not
    /// the caret: the drag anchor may legitimately scroll out of view, and
    /// yanking it back would fight the drag-selection autoscroll (§6). So the
    /// caret is revealed only outside a drag.
    func revealCaret(center: Bool = false) {
        guard !dragEngaged, let dataSource else { return }
        // The caret's reveal position is the selection's *moving* edge, not its
        // anchor: extending a selection follows the edge being dragged, so the
        // viewport tracks the newest byte, not the fixed start (§10.4).
        let caret = dataSource.hexCaretRevealOffset()
        if center {
            // A command moved the caret to a new location: if it is outside the
            // viewport, centre it; if it is already on screen, leave the view put.
            guard !isRowVisible(containing: caret) else { return }
            centerRow(containing: caret)
        } else {
            // Incremental navigation: the minimum scroll that keeps the caret on
            // screen — no jump to the centre, which would disorient (§10.4).
            let layout = currentLayout
            let (row, column) = layout.rowColumn(of: caret)
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
    }

    /// Redraws the row the caret sits on without scrolling. Used when the
    /// caret's *appearance* changes (a typing-mode flip) but its position does
    /// not — a scroll would yank the view away from where the user was reading.
    /// The overwrite-mode underline extends a couple of pixels below the row's
    /// bottom edge, so the invalidation reaches a little past the row frame or
    /// that sliver stays stale.
    func redrawCaret() {
        guard let dataSource else { return }
        let layout = currentLayout
        let selection = dataSource.hexSelection()
        let (row, _) = layout.rowColumn(of: selection.start)
        let frame = layout.rowFrame(row: row)
        setNeedsDisplay(frame.insetBy(dx: 0, dy: -3))
    }

    /// Redraws the row whose start offset is `rowStart` without scrolling — a
    /// bookmark mark appeared or disappeared there (§20). The mark is the
    /// offset's arrow (the Offset column and its right-pointing tip), so the
    /// row's frame repaints. Off-screen rows are marked dirty too: a
    /// layer-backed view keeps their old pixels until they are redrawn.
    func redrawRow(startingAt rowStart: UInt64) {
        let layout = currentLayout
        let row = Int(rowStart / UInt64(HexLayout.bytesPerRow))
        setNeedsDisplay(layout.rowFrame(row: row))
    }

    /// The single "centre an offset" primitive: scrolls so the row containing
    /// `offset` is at the vertical centre of the visible area (clamped to the
    /// document's edges), so the byte is shown mid-pane rather than at its top
    /// or bottom edge. Shared by the centred caret reveal and the "go to"
    /// actions (§10.4, §11).
    private func centerRow(containing offset: UInt64) {
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

    /// Whether the row containing `offset` is already within the visible
    /// viewport — the test that decides a centred reveal is needed at all: a
    /// command that lands the caret on screen leaves the view where it is.
    private func isRowVisible(containing offset: UInt64) -> Bool {
        guard let scroll = enclosingScrollView else { return true }
        let layout = currentLayout
        let (row, _) = layout.rowColumn(of: offset)
        return layout.rowFrame(row: row).intersects(scroll.contentView.bounds)
    }

    /// Always centres the row containing `offset` (a "go to" action: the caller
    /// asked for this offset, so it is centred whether or not it was in view).
    /// Used after a search result lands (§11).
    func revealOffsetCentered(_ offset: UInt64) {
        centerRow(containing: offset)
    }

    /// Scrolls the row containing `offset` to the *top* of the visible area
    /// (clamped to the document's edges). The minimap's drag and wheel map a
    /// position on the map to a byte offset and ask for exactly that: the offset
    /// becomes the first visible row, which is the position the minimap's own
    /// window is derived from (§19).
    func scrollRowToTop(containing offset: UInt64) {
        guard let scroll = enclosingScrollView else { return }
        let layout = currentLayout
        let (row, _) = layout.rowColumn(of: offset)
        let clip = scroll.contentView
        let maxOriginY = max(0, bounds.height - clip.bounds.height)
        let originY = min(max(0, layout.rowFrame(row: row).minY), maxOriginY)
        guard abs(originY - clip.bounds.origin.y) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: originY))
        scroll.reflectScrolledClipView(clip)
    }

    /// The visible viewport's height in points — the clip view's height, not the
    /// document's, whose `bounds.height` is the whole file: a page must be what
    /// fits on screen, not the entire dump.
    private var viewportHeight: CGFloat {
        enclosingScrollView?.contentView.bounds.height ?? 0
    }

    /// One page in whole rows: the full rows that fit the viewport, times the row
    /// height — the Fn+Up/Down step (a full viewport, no overlap).
    private var pageScrollPoints: CGFloat {
        let rowHeight = currentLayout.rowHeight
        guard rowHeight > 0 else { return 0 }
        return CGFloat(max(1, Int(viewportHeight / rowHeight))) * rowHeight
    }

    /// Scrolls the viewport by one page without moving the caret (§10.5). Clamped
    /// to [0, maxVerticalScroll]; a no-op while a drag owns the pointer (§6).
    func scrollViewportByPage(down: Bool) {
        guard !dragEngaged, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let target = clip.bounds.origin.y + (down ? pageScrollPoints : -pageScrollPoints)
        let originY = min(max(0, target), maxVerticalScroll)
        guard abs(originY - clip.bounds.origin.y) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: originY))
        scroll.reflectScrolledClipView(clip)
    }

    /// Scrolls the viewport to the document's top without moving the caret (§10.5).
    func scrollViewportToTop() {
        guard !dragEngaged, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        guard clip.bounds.origin.y > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: 0))
        scroll.reflectScrolledClipView(clip)
    }

    /// Scrolls the viewport to the document's bottom without moving the caret (§10.5).
    func scrollViewportToBottom() {
        guard !dragEngaged, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let originY = maxVerticalScroll
        guard abs(originY - clip.bounds.origin.y) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: originY))
        scroll.reflectScrolledClipView(clip)
    }

    /// Reveals the current selection the way the caret is revealed by a
    /// navigation command (§10.4): if it is already fully on screen the view
    /// does not move at all, and only a selection that is off screen (or half
    /// off it) is centred.
    ///
    /// This is what a step through the search's matches uses (§11): pressing
    /// Find Next on a match two rows down should move the highlight, not the
    /// page under it.
    func revealSelectionCenteredIfNeeded() {
        guard let dataSource else { return }
        let selection = dataSource.hexSelection()
        let first = selection.start
        let last = selection.isEmpty ? selection.start : selection.end - 1
        // Both ends, because a match can straddle a row boundary and a match
        // hanging over the viewport's edge is not "visible".
        guard !(isRowVisible(containing: first) && isRowVisible(containing: last)) else { return }
        revealSelectionCentered()
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
        // A mark's drag engages on the press itself (there is no dead zone to
        // leave: it moves only when the pointer reaches another row), so it does
        // not wait for `dragEngaged` the way a selection does.
        guard let last = lastDragPoint, dragEngaged || draggingBookmarkRow != nil else {
            stopDragAutoscroll()
            return
        }
        let point = convert(last, from: nil)
        let effective = dragAutoscrollStep(at: point)
        if draggingBookmarkRow != nil {
            moveDraggedBookmark(to: effective)
        } else {
            extendDragSelection(at: effective)
        }
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
        // A double click on an address marks that row (§20.3). The click that
        // came before it has already placed the caret there, which is where the
        // gesture would leave it anyway; the second click adds the mark instead
        // of placing the caret again.
        if event.clickCount == 2,
           let offset = offsetColumnOffset(at: convert(event.locationInWindow, from: nil)) {
            onOffsetDoubleClick?(offset)
            return
        }
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        // Pressing on a mark takes hold of it: the drag that follows moves the
        // bookmark (§20.6). The press still places the caret, so a press and
        // release on an address is the click it has always been — only a press
        // that then travels to another row moves anything.
        draggingBookmarkRow = bookmarkMarkRow(at: mouseDownLocation ?? .zero)
        if let grabbed = draggingBookmarkRow {
            // The gesture starts on the mark's own row, so the first step comes
            // when the pointer leaves it.
            draggingBookmarkPointerRow = currentLayout.rowColumn(of: grabbed).row
            NSCursor.closedHand.push()
        }
        // A shift-click extends immediately; an unmodified click needs to leave
        // the dead zone before the selection engages.
        dragEngaged = event.modifierFlags.contains(.shift)
        handleMouse(event, extendSelection: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        if draggingBookmarkRow != nil {
            lastDragPoint = event.locationInWindow
            // The same autoscroll the selection uses (§6): a mark dragged past
            // the visible edge scrolls the pane, and the timer keeps it going
            // while the pointer is held there.
            let effective = dragAutoscrollStep(at: convert(event.locationInWindow, from: nil))
            moveDraggedBookmark(to: effective)
            updateDragAutoscrollTimer(at: convert(event.locationInWindow, from: nil))
            return
        }
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
        if draggingBookmarkRow != nil {
            draggingBookmarkRow = nil
            draggingBookmarkPointerRow = nil
            NSCursor.pop()
        }
        super.mouseUp(with: event)
    }

    /// The bookmarked row whose mark is under `point`, if any. The mark fills its
    /// row's Offset column (§20.4), so a press anywhere on that address is a
    /// press on the mark — there is nothing else drawn there to hit.
    private func bookmarkMarkRow(at point: CGPoint) -> UInt64? {
        guard let offset = offsetColumnOffset(at: point),
              dataSource?.hexBookmark(atRowContaining: offset) != nil else { return nil }
        return offset
    }

    /// One step of a mark's drag: the row under the pointer, clamped to the rows
    /// this view actually draws. The mark follows the answer rather than the
    /// pointer — a row another bookmark holds is jumped over, and a mark that
    /// cannot move stays put while the pointer runs on (§20.6).
    private func moveDraggedBookmark(to point: CGPoint) {
        guard let from = draggingBookmarkRow, let dataSource, let onBookmarkDrag else { return }
        let layout = currentLayout
        let fileSize = dataSource.fileSize
        guard fileSize > 0, layout.rowHeight > 0 else { return }
        // A step happens when the pointer CROSSES into another row, and only
        // then: see `draggingBookmarkPointerRow`.
        let previous = draggingBookmarkPointerRow ?? layout.rowColumn(of: from).row
        let row = pointerRow(at: point.y, comingFrom: previous, layout: layout)
        guard row != previous else { return }
        draggingBookmarkPointerRow = row
        // The rows that hold bytes: the caret row past a file whose length is a
        // multiple of 16 is not a row a bookmark belongs on. The far end is the
        // store's to enforce (it is handed `lastRow` below); the near end is
        // this view's, because a pointer above the first row gives a negative
        // row index and there is no such offset.
        let lastDataRow = layout.rowColumn(of: fileSize - 1).row
        let target = layout.byteOffset(row: row, column: 0)
        guard target != from else { return }
        if let landed = onBookmarkDrag(from, target, layout.byteOffset(row: lastDataRow, column: 0)) {
            draggingBookmarkRow = landed
        }
    }

    /// The row a drag counts the pointer as being on, given the row it was last
    /// counted on: a new row is taken only once the pointer is
    /// `bookmarkDragHysteresis` points inside it, so a pointer resting on a row
    /// boundary stays on the row it came from (§20.6).
    private func pointerRow(at y: CGFloat, comingFrom previous: Int, layout: HexLayout) -> Int {
        let raw = max(0, Int(floor(y / layout.rowHeight)))
        guard raw != previous else { return previous }
        let hysteresis = Self.bookmarkDragHysteresis
        if raw > previous {
            // Downwards: far enough below the new row's top edge.
            return y >= CGFloat(raw) * layout.rowHeight + hysteresis ? raw : previous
        }
        // Upwards: far enough above the new row's bottom edge.
        return y <= CGFloat(raw + 1) * layout.rowHeight - hysteresis ? raw : previous
    }

    /// What a right-click in the dump anchors the context menu to (§10.2).
    struct ContextMenuAnchor {
        let offset: UInt64
        /// True when the anchor is a single hex byte (the menu was opened on a
        /// byte in the hex column); false when it is the Offset column's row
        /// address, whose frame spans the whole column.
        let framesByte: Bool
        /// The nibble the caret lands on when the menu opens — the click's
        /// position within the anchored byte for a hex-column click, 0 for the
        /// Offset column. See `contextMenuAnchor`.
        let nibble: Int
    }

    /// Right-click on an address in the Offset column or on a byte in the hex
    /// column: frames the anchor with the standard focus ring and pops the
    /// offset context menu ("Select Block from Here at «address»", "Copy offset") built by
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
        placeContextMenuCaret(anchor)
        beginContextMenu(at: anchor)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        endContextMenu(at: anchor)
    }

    /// Moves the caret to the byte the context menu anchors to (§10.2), so the
    /// caret tracks the right-clicked byte exactly as a left-click would place
    /// it. Skipped when the right-click lands inside the current selection:
    /// placing the caret clears the selection, and the menu's selection-scoped
    /// items ("Copy", "Fill Selection…", "Delete Bytes…") operate on it.
    ///
    /// Split out of `rightMouseDown` because `popUpContextMenu` runs a blocking
    /// tracking loop no test can enter: this is the caret move the right-click
    /// performs, drivable on its own (§10.2).
    func placeContextMenuCaret(_ anchor: ContextMenuAnchor) {
        let selection = dataSource?.hexSelection()
        if let selection, !selection.isEmpty,
           anchor.offset >= selection.start, anchor.offset < selection.end {
            return
        }
        delegate?.hexEditor(self, didClickAt: anchor.offset, region: .hex,
                            extendSelection: false, nibble: anchor.nibble)
    }

    /// Records that `anchor`'s context menu is up and repaints what that
    /// changes. Split out of `rightMouseDown` because `popUpContextMenu` runs a
    /// blocking tracking loop no test can enter: this is the state the pane is
    /// in while the menu is visible, drivable on its own (§10.2, §20.4).
    func beginContextMenu(at anchor: ContextMenuAnchor) {
        contextMenuOffset = anchor.offset
        contextMenuFramesByte = anchor.framesByte
        invalidateContextMenuFrame(for: anchor.offset)
    }

    /// Clears the anchor once its menu is dismissed. The rows must be
    /// invalidated even though the offset is already gone — the no-argument
    /// form guards on it, so the clear passes the anchor's row explicitly, or
    /// §3.3 region-redraw leaves the frame on screen (§10.2).
    func endContextMenu(at anchor: ContextMenuAnchor) {
        contextMenuOffset = nil
        contextMenuFramesByte = false
        invalidateContextMenuFrame(for: anchor.offset)
    }

    /// Invalidates the rows a context-menu frame around `offset` draws on and
    /// returns their rects. Takes the offset explicitly (rather than reading
    /// `contextMenuOffset`) so the clearing call after the menu works even
    /// though the anchor is already nil — the rows must be repainted without
    /// the frame, or §3.3 region-redraw leaves the focus ring on screen (§10.2).
    @discardableResult
    func invalidateContextMenuFrame(for offset: UInt64) -> [CGRect] {
        let row = currentLayout.rowColumn(of: offset).row
        var rows = [row]
        if row > 0 { rows.append(row - 1) }
        rows.append(row + 1)
        var rects: [CGRect] = []
        rects.reserveCapacity(rows.count)
        for invalidRow in rows {
            let rect = currentLayout.rowFrame(row: invalidRow)
            setNeedsDisplay(rect)
            rects.append(rect)
        }
        return rects
    }

    /// The anchor for a right-click context menu: the Offset column maps to the
    /// row's start address, and the hex column maps to the clicked byte's own
    /// offset. Returns nil for the ASCII column, the gaps, and anywhere past
    /// EOF (the empty caret row, or a placeholder byte in a partial last row).
    ///
    /// The anchor also carries the nibble the caret lands on (§10.2): the
    /// right-clicked byte — the same byte the menu frames — not where a
    /// left-click's `hexClickPlacement` might send the caret, which for a click
    /// in the gap before the byte would be the *previous* byte. The nibble is
    /// the click's position within the anchored byte, using the same
    /// mode-dependent threshold a left-click uses; a click in the gap before the
    /// byte (which `hitTest` still hands to it) lands on the byte's left
    /// boundary, since there is no nibble before it.
    func contextMenuAnchor(for event: NSEvent) -> ContextMenuAnchor? {
        guard let dataSource else { return nil }
        let layout = currentLayout
        let point = convert(event.locationInWindow, from: nil)
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)
        guard let hit = layout.hitTest(point: point, rowCount: rowCount) else { return nil }
        let offset: UInt64
        let framesByte: Bool
        let nibble: Int
        switch hit.column {
        case .offset:
            offset = layout.byteOffset(row: hit.row, column: 0)
            framesByte = false
            nibble = 0
        case .hex(let column):
            offset = layout.byteOffset(row: hit.row, column: column)
            framesByte = true
            nibble = contextMenuCaretNibble(atX: point.x, column: column, layout: layout)
        case .ascii:
            return nil
        }
        guard offset < dataSource.fileSize else { return nil }
        return ContextMenuAnchor(offset: offset, framesByte: framesByte, nibble: nibble)
    }

    /// The nibble a right-click at `x` places the caret on, within `column`'s
    /// byte (§10.2). Measured from the byte's own left edge with the same
    /// mode-dependent threshold a left-click uses — the byte's centre in
    /// overwrite mode, the high-nibble character's middle in insert mode. A
    /// click in the gap before the byte (where `hitTest` still reports this
    /// byte) has no nibble to the left of it, so it lands on the byte's left
    /// boundary.
    private func contextMenuCaretNibble(atX x: CGFloat, column: Int, layout: HexLayout) -> Int {
        let byteX = layout.hexByteX(column: column)
        guard x >= byteX else { return 0 }
        if dataSource?.hexInsertMode ?? false {
            return x - byteX >= layout.charWidth / 2 ? 1 : 0
        }
        return x - byteX >= layout.charWidth ? 1 : 0
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
    /// low-nibble one (§3.3) — sits close enough to the byte's centre that a
    /// 1 px jitter would cross the drag-selection boundary there and select
    /// the byte by accident, so the drag must leave the zone before the
    /// selection engages. Clicks outside the zone (a byte's outer quarters, or
    /// the offset/ASCII columns) are clear positions and any drag engages
    /// immediately. The zone spans the click's row, so vertical movement
    /// engages too.
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

    /// The row-start offset of the address under `point`, or nil when the point
    /// is not on one — the hex or ASCII columns, or past the last row (§20.3).
    private func offsetColumnOffset(at point: CGPoint) -> UInt64? {
        guard let dataSource else { return nil }
        let layout = currentLayout
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)
        guard let hit = layout.hitTest(point: point, rowCount: rowCount),
              case .offset = hit.column else { return nil }
        return layout.byteOffset(row: hit.row, column: 0)
    }

    /// The byte and nibble a click at `x` places the caret on (§3.3). The
    /// column is what `hitTest` reported; the returned column can differ by
    /// one when the click sits in the gap before it (see below).
    ///
    /// Overwrite mode: the caret is the underline under one nibble character,
    /// so each nibble's zone is the character it underlines plus the nearer
    /// half of each adjacent inter-byte gap — the left nibble runs from the
    /// middle of the preceding gap to the byte's centre, the right nibble from
    /// the centre to the middle of the following gap. The zones meet exactly
    /// on the nibble boundary, the byte's centre, and a side with no inter-byte
    /// gap (a byte packed into a multi-byte word, or the row's first/last byte
    /// against a column gap) ends at the byte's own edge. `hitTest` hands a
    /// whole gap to the *following* byte, so a click in the gap's first half
    /// arrives as the following byte but belongs to the previous byte's right
    /// nibble — the returned column is that previous byte.
    ///
    /// Insert mode: the caret is a vertical line, so the byte is always the
    /// hit one and the threshold stays where it was — the middle of the
    /// high-nibble character, a large target so the mid-byte caret is easy to
    /// reach without aiming at the gap.
    private func hexClickPlacement(atX x: CGFloat, column: Int, layout: HexLayout)
        -> (column: Int, nibble: Int) {
        let byteX = layout.hexByteX(column: column)
        if dataSource?.hexInsertMode ?? false {
            return (column, x - byteX >= layout.charWidth / 2 ? 1 : 0)
        }
        if x >= byteX {
            // Inside the byte's own cell: the byte's centre splits the nibbles.
            return (column, x - byteX >= layout.charWidth ? 1 : 0)
        }
        // In the gap before the byte — which exists only for column > 0, the
        // row's first byte starting the hex region. The gap's nearer half
        // belongs to the previous byte's right nibble; the far half to this
        // byte's left nibble.
        guard column > 0 else { return (column, 0) }
        let previous = column - 1
        let gapMid = (layout.hexByteX(column: previous) + layout.hexByteWidth + byteX) / 2
        return x < gapMid ? (previous, 1) : (column, 0)
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
            let placement = hexClickPlacement(atX: point.x, column: column, layout: layout)
            offset = layout.byteOffset(row: hit.row, column: placement.column)
            region = .hex
            nibble = placement.nibble
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
        let chars = event.charactersIgnoringModifiers ?? ""
        guard let value = chars.unicodeScalars.first?.value else {
            super.keyDown(with: event)
            return
        }
        let extend = flags.contains(.shift)

        // Whether this move should centre the caret: only when the caret is
        // *already* out of view. An arrow pressed while the caret is off screen
        // brings the view back to it (centred); an arrow that merely pushes it
        // past an edge keeps the minimum-scroll follow (§10.4). Checked before
        // the move, since a step that lands on the edge must still autoscroll.
        let center = !isRowVisible(containing: dataSource.hexCaretRevealOffset())

        // Cmd+arrow: text-editor row/file caret jumps (§10.5). Handled here, not
        // as menu key equivalents — the active pane is already in hand, and the
        // plain navigation keys are keyDown-only. Scoped to Cmd WITHOUT Option or
        // Control: the View menu owns Cmd+Option(+Shift)+arrow for difference
        // navigation (§10.3), and any other Cmd+/Ctrl+ key defers to the menu.
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            let caret = dataSource.hexSelection().start
            switch value {
            case 0xF702:  // Cmd+Left → row start
                delegate.hexEditor(self, moveCaretTo: caret - (caret % UInt64(HexLayout.bytesPerRow)),
                                   extendSelection: extend, center: center)
            case 0xF703:  // Cmd+Right → the row's last byte (caret) / through it (selection)
                let rowStart = caret - (caret % UInt64(HexLayout.bytesPerRow))
                let rowEnd = min(rowStart + UInt64(HexLayout.bytesPerRow), dataSource.fileSize)
                // A bare caret lands *on* the last byte; a selection's half-open
                // end sits one past it, so both reveal the same byte (§10.5).
                // An empty file has no last byte, and the guard has to be a
                // branch: `max(0, rowEnd - 1)` would not clamp anything, since
                // `rowEnd - 1` is evaluated first and traps on an unsigned zero.
                let last = rowEnd == 0 ? 0 : rowEnd - 1
                delegate.hexEditor(self, moveCaretTo: extend ? rowEnd : last,
                                   extendSelection: extend, center: center)
            case 0xF700:  // Cmd+Up → file start
                delegate.hexEditor(self, moveCaretTo: 0, extendSelection: extend, center: center)
            case 0xF701:  // Cmd+Down → file end
                delegate.hexEditor(self, moveCaretTo: dataSource.fileSize, extendSelection: extend, center: center)
            default:
                super.keyDown(with: event)   // any other Cmd+ key → the menu
            }
            return
        }

        if flags.contains(.command) || flags.contains(.control) {
            // Cmd+A / Cmd+C / Cmd+V / Cmd+L… are handled by menu key
            // equivalents; leave this keystroke to the menu system.
            super.keyDown(with: event)
            return
        }

        switch value {
        case 0x7F:  // Backspace — fills the previous byte with 0x00 (§7.3)
            delegate.hexEditorDeleteBackward(self)
        case 0xF728:  // Forward Delete — fills the current byte with 0x00
            delegate.hexEditorDeleteForward(self)
        case 0xF700:  // Up
            delegate.hexEditor(self, moveCaretBy: -Int64(HexLayout.bytesPerRow), extendSelection: extend, center: center)
        case 0xF701:  // Down
            delegate.hexEditor(self, moveCaretBy: Int64(HexLayout.bytesPerRow), extendSelection: extend, center: center)
        case 0xF702:  // Left
            delegate.hexEditor(self, moveCaretBy: -1, extendSelection: extend, center: center)
        case 0xF703:  // Right
            delegate.hexEditor(self, moveCaretBy: 1, extendSelection: extend, center: center)
        // Page Up/Down and Home/End scroll the viewport and leave the caret
        // where it is — the platform's own behaviour for these keys, the one
        // Xcode and TextEdit have (§10.5). On a Mac keyboard they ARE Fn+arrow:
        // the firmware translates the chord, so the event is the same key and
        // there is nothing here to tell apart. `.function` in particular cannot:
        // AppKit sets it for every key in the 0xF700–0xF8FF range, these four
        // and the plain arrows included.
        case 0xF72C: scrollViewportByPage(down: false)  // Page Up   (Fn+Up)
        case 0xF72D: scrollViewportByPage(down: true)   // Page Down (Fn+Down)
        case 0xF729: scrollViewportToTop()              // Home      (Fn+Left)
        case 0xF72B: scrollViewportToBottom()           // End       (Fn+Right)
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

    /// Caret colour in insert mode: a red vertical line at the byte boundary,
    /// the classic "insert" caret, distinct from the blue overwrite bar.
    static let insertCaretColor = NSColor.systemRed

    /// Bookmark colour (§20). The SDK has no semantic bookmark colour and the
    /// app's palette is otherwise spoken for — red is modified bytes and the
    /// insert caret, orange is a difference, the accent is the caret and mirror
    /// frames, ink blue is the addresses — so purple, which is free, marks a
    /// bookmarked row. It reads as a mark rather than a state: green would say
    /// "matches", which a bookmark says nothing about.
    static let bookmarkColor = NSColor.systemPurple

    /// The address drawn on a filled bookmark mark. The semantic colour for
    /// text on a filled selection: white in both appearances, and named rather
    /// than literal so it follows the SDK if that ever changes (§20.4).
    static let bookmarkTextColor = NSColor.alternateSelectedControlTextColor

    /// The address's leading zeros on a filled bookmark mark — the bookmark text
    /// dimmed so the significant part of the address stands out, as in the plain
    /// offset column (§6, §20.4).
    static let mutedBookmarkText = NSColor(name: nil) { _ in
        NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.40)
    }

    /// Ink blue for the column header and the offset column (§6): a pale,
    /// slightly desaturated blue that reads as a quiet secondary element next
    /// to the dump's byte content, lighter on dark backgrounds so it stays
    /// legible without competing with the bytes.
    static let inkBlue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.58, green: 0.73, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.33, green: 0.54, blue: 0.78, alpha: 1)
    }

    /// The offset column's leading zeros, dimmed so the significant part of the
    /// address stands out (§6): the same ink blue at reduced opacity, so the
    /// padding digits read as "not the address" around the part the eye lands on.
    static let mutedInkBlue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.58, green: 0.73, blue: 0.92, alpha: 0.40)
            : NSColor(srgbRed: 0.33, green: 0.54, blue: 0.78, alpha: 0.40)
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

    /// Every occurrence of the current search pattern (§11): the platform's own
    /// unfocused-selection grey — what a selection looks like in a view that
    /// does not have focus, which is exactly the statement being made ("a match,
    /// but not the one you are standing on"). It is the grey Xcode puts behind
    /// the other occurrences, and it is opaque, so it covers the segment tint —
    /// correct per §6, where a byte's state outranks which piece it belongs to.
    static let matchFill = NSColor.unemphasizedSelectedTextBackgroundColor

    /// The current match — the find indicator (§11). `findHighlightColor` is
    /// the platform's own: what `NSTextView.showFindIndicator(for:)` flashes,
    /// and the yellow Xcode marks the current occurrence with. It is pure yellow
    /// and **the same in both appearances**, which is why the ink over it is
    /// forced below rather than left to `labelColor`.
    static let findIndicatorFill = NSColor.findHighlightColor
    /// The shadow under the bubble — the only thing that makes the yellow read
    /// as raised, since the platform's own indicator has no outline and a dark
    /// rim around yellow reads as a box drawn on the text. A fixed black, not a
    /// semantic colour: it falls on a fixed yellow, so it must not follow the
    /// appearance.
    static let indicatorShadow = NSColor.black

    /// Ink for a byte inside the find indicator. Black, per Apple's own
    /// instruction for `findHighlightColor` — in dark mode `labelColor` would be
    /// white on yellow. A **modified** byte keeps its red: an unsaved edit is
    /// data-integrity information, red on yellow still reads as red, and losing
    /// it because the caret happens to be there would be the worse trade. The
    /// muted `0x00`/`0xFF` dimming is dropped — 40 % label on yellow is a smear.
    static let indicatorInk = NSColor.black
    /// A placeholder character in the decoded-text column, inside the
    /// indicator: dimmed black rather than dimmed label, for the same reason.
    static let mutedIndicatorInk = NSColor.black.withAlphaComponent(0.45)

    static func indicatorTextColor(for state: HexByteState) -> NSColor {
        state.isModified ? modifiedText : indicatorInk
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

    /// The six segment tints, cycled by label (§21.3): S0 light green, S1 light
    /// pink, S2 pale blue, S3 pale yellow, S4 lavender, S5 peach. A small set of
    /// pastels — enough colour to tell one piece from the next, never enough to
    /// draw the eye — in the spirit of how Fusion 360 tints components.
    ///
    /// Two sets, one order: the light-theme set sits barely off the paper, the
    /// dark-theme set is the same hues at the other end of the lightness range,
    /// so S1 is "the pink one" in both. Each set is checked by test against the
    /// three rules that make a tint a tint rather than a state: it stays
    /// legible under the muted `0x00`/`0xFF` fill, neighbours are plainly
    /// different (that is what draws the boundary), and nothing is mistakable
    /// for the orange difference, the accent selection, or the bookmark purple.
    static let segmentTints: [NSColor] = [
        // S0 — light green
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.16, green: 0.25, blue: 0.17, alpha: 1)
                : NSColor(srgbRed: 0.84, green: 0.94, blue: 0.84, alpha: 1)
        },
        // S1 — light pink
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.29, green: 0.17, blue: 0.21, alpha: 1)
                : NSColor(srgbRed: 0.97, green: 0.85, blue: 0.88, alpha: 1)
        },
        // S2 — pale blue
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.16, green: 0.22, blue: 0.30, alpha: 1)
                : NSColor(srgbRed: 0.84, green: 0.90, blue: 0.98, alpha: 1)
        },
        // S3 — pale yellow
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.29, green: 0.27, blue: 0.15, alpha: 1)
                : NSColor(srgbRed: 0.98, green: 0.95, blue: 0.80, alpha: 1)
        },
        // S4 — lavender
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.23, green: 0.19, blue: 0.31, alpha: 1)
                : NSColor(srgbRed: 0.89, green: 0.85, blue: 0.97, alpha: 1)
        },
        // S5 — peach
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.31, green: 0.23, blue: 0.16, alpha: 1)
                : NSColor(srgbRed: 0.99, green: 0.89, blue: 0.82, alpha: 1)
        },
    ]

    /// The colour a hovered strip block is painted in — the same hue as the
    /// piece's tint, but louder, so the piece under the cursor stands out
    /// without changing its identity (§19.4.4). The tints are pastels, so a
    /// fixed step (rather than a multiplier) is what makes a pale tint read as
    /// "the same colour, just louder". In dark theme the tints sit at the dark
    /// end of the range, where pushing saturation alone does not lift a thin
    /// strip off the near-black paper — so the hover lifts the brightness as
    /// well as the saturation there. In light theme the other tints are bright
    /// enough to read against the white paper, so only the saturation moves —
    /// but the green is the exception: a pale green reads as near-white at full
    /// brightness, so its hover dips the brightness and pushes the saturation a
    /// little further, so the band reads as a weighty green rather than a wash.
    static func saturatedHighlight(of color: NSColor, in appearance: NSAppearance) -> NSColor {
        // The tint is a dynamic (catalog) colour, and the HSB component
        // accessors are not valid on a catalog colour — it must first be
        // resolved to a concrete colour in the given appearance (the view's,
        // since this runs inside `draw`).
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let rgb = resolved else { return color }
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Dark theme: the tint is dark, so the hover lifts brightness as well as
        // saturation — a dark, muddy band does not read as a colour in a 6 pt
        // strip, and saturation alone does not move it off the paper.
        // Light theme: the tints are bright enough to read against the white
        // paper, so only the saturation moves — except the green, whose pale hue
        // reads as near-white at full brightness. Its hover dips the brightness
        // and pushes the saturation a little further, so the band reads as a
        // weighty green rather than a wash.
        let isGreen = !isDark
            && rgb.hueComponent >= 0.25 && rgb.hueComponent <= 0.45
        let saturation = min(1, rgb.saturationComponent
            + (isDark ? 0.20 : (isGreen ? 0.45 : 0.30)))
        let brightness: CGFloat
        if isDark {
            brightness = min(1, rgb.brightnessComponent + 0.35)
        } else if isGreen {
            brightness = max(0, rgb.brightnessComponent - 0.12)
        } else {
            brightness = rgb.brightnessComponent
        }
        return NSColor(hue: rgb.hueComponent,
                       saturation: saturation,
                       brightness: brightness,
                       alpha: rgb.alphaComponent)
    }
}

extension String {
    /// Left-pads with `pad` until the string is at least `length` characters.
    func leftPadded(to length: Int, with pad: String) -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

extension UInt64 {
    /// The app's address for this offset: upper-case hex, at least eight digits
    /// (§10) — the shape the Offset column, the bookmark list, and the context-
    /// menu titles all share. `hexAddress` adds the `0x` prefix the offset input
    /// fields carry on their own.
    var bareAddress: String {
        String(self, radix: 16, uppercase: true).leftPadded(to: 8, with: "0")
    }

    var hexAddress: String {
        "0x" + bareAddress
    }
}

extension Range where Bound == UInt64 {
    /// The range's last byte — the inclusive end of the half-open range, so a
    /// piece read as "first…last" names the bytes it holds, not the first byte
    /// past them. The one place the half-open-to-inclusive conversion lives, so
    /// every site that shows a piece's address range (the status bar, the strip
    /// tooltip, the cut-edit header) reads the same first-to-last bytes (§21.3).
    var lastByte: UInt64 { upperBound - 1 }
}
