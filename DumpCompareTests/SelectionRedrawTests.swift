import DumpCompareCore
import XCTest
@testable import DumpCompare

/// The dirty-rows contract behind drag selection (§13): a selection move must
/// invalidate only the rows whose rendering actually changes — not the whole
/// hex view. `changedSelectionRects(from:to:)` is the pure geometry that
/// decides, so these tests pin exactly which rows it redraws for the shapes a
/// real drag can produce. A regression here (e.g. a selection move invalidating
/// every visible row again) would resurrect the drag lag on tall windows.
///
/// The redrawn set deliberately includes one row on each side of the changed
/// rows: the selection's outline (mirrored contour, caret bar, cross-column
/// link) is a stroked line whose far-end edge sits on a row boundary and
/// extends a couple of pixels into the row past it. That row is where an old
/// edge's stroke would otherwise ghost after a drag, so it must repaint too.
@MainActor
final class SelectionRedrawTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sel-redraw-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A pane hosting a real hex view in a real window (same pattern as
    /// `MouseSelectionTests`), so `changedSelectionRects` runs against a real
    /// layout. The temp file stays on disk; the caller removes it when done.
    private func makePane(_ bytes: [UInt8]) throws -> (HexView, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        let filePane = FilePaneView(viewModel: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        filePane.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(filePane)
        NSLayoutConstraint.activate([
            filePane.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            filePane.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            filePane.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            filePane.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.layoutIfNeeded()
        let hexView = try XCTUnwrap(filePane.scrollView.documentView as? HexView)
        return (hexView, url)
    }

    /// The set of row indices the returned rects cover, so assertions read as
    /// "rows {1, 2} are invalidated" rather than comparing pixel rects.
    private func rows(_ rects: [CGRect], rowHeight: CGFloat) -> Set<Int> {
        Set(rects.map { Int(($0.minY / rowHeight).rounded()) })
    }

    private func selection(_ start: UInt64, _ end: UInt64, size: UInt64) -> SelectionModel {
        SelectionModel(start: start, end: end, fileSize: size)
    }

    func testGrowingSelectionInvalidatesChangedRowsAndEdges() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        // Row 0 (bytes 0…15) was already selected; the drag adds rows 1–2. The
        // old selection's bottom edge (at the bottom of row 0) and the new
        // selection's bottom edge (below row 2) straddle their boundaries, so
        // rows 0 and 3 join the redraw.
        let rects = hexView.changedSelectionRects(
            from: selection(0, 16, size: 200),
            to: selection(0, 48, size: 200))
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1, 2, 3])
    }

    func testShrinkingSelectionInvalidatesRetiredRowsAndEdges() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        // Dragging back shrinks the tail: rows 1–2 lose their fill, and the
        // old bottom edge (below row 2) clears along with it.
        let rects = hexView.changedSelectionRects(
            from: selection(0, 48, size: 200),
            to: selection(0, 16, size: 200))
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1, 2, 3])
    }

    /// Shift+Right selecting the FIRST byte must repaint the caret's own row: a
    /// caret at P and a one-byte selection [P, P+1) share a byte span, so the
    /// span XOR alone misses the handoff and the byte keeps its caret-only
    /// pixels — the "1 selected in the status bar, nothing highlighted" bug.
    func testCaretToFirstByteSelectionRepaintsCaretRow() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        let rects = hexView.changedSelectionRects(
            from: selection(5, 5, size: 200),   // caret at byte 5
            to: selection(5, 6, size: 200))     // first byte selected
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1],
                       "the caret's own row must repaint when the first byte is selected")
    }

    /// The mirror image: a one-byte selection collapsing back to the caret must
    /// also clear its fill rather than leave the byte highlighted.
    func testOneByteSelectionCollapseRepaintsCaretRow() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        let rects = hexView.changedSelectionRects(
            from: selection(5, 6, size: 200),   // first byte selected
            to: selection(5, 5, size: 200))     // back to the caret
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1],
                       "the selected byte's row must repaint when it collapses back to a caret")
    }

    func testSelectionCollapsingToCaretAtNewOffsetInvalidatesBothRows() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        // Selection [5, 20) collapses to a caret at byte 20 (row 1): the old
        // selection's row 0 must clear and the caret's new row 1 must appear.
        let rects = hexView.changedSelectionRects(
            from: selection(5, 20, size: 200),
            to: selection(20, 20, size: 200))
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1, 2])
    }

    /// The row-boundary case: typing consumes byte 15 (last of row 0), the
    /// caret lands on byte 16 (first of row 1). The span XOR only invalidates
    /// byte 15, so without the caret-move rule the new caret row would never
    /// repaint and the bar would vanish mid-typing.
    func testTypingAcrossRowBoundaryInvalidatesBothCaretRows() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        let rects = hexView.changedSelectionRects(
            from: selection(15, 40, size: 200),
            to: selection(16, 40, size: 200))
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1, 2])
    }

    func testUnchangedSelectionInvalidatesNothing() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }

        // A no-op move must not repaint a single row.
        let rects = hexView.changedSelectionRects(
            from: selection(0, 16, size: 200),
            to: selection(0, 16, size: 200))
        XCTAssertTrue(rects.isEmpty)
    }

    /// A selection jumping far beyond the viewport (a search result, Select
    /// Block) must invalidate only the rows the selection actually left and
    /// entered — never the gap between them, which on a large file is millions
    /// of display rects unioned on the main thread. Off-screen rows are still
    /// invalidated: a selection that scrolls back into view must not keep stale
    /// pixels (the layer-backed stale-highlight bug). This O(old + new rows)
    /// bound replaced the old viewport clamp (§13).
    func testFarSelectionJumpInvalidatesOnlyOldAndNewSpans() throws {
        // 5000 bytes ≈ 313 rows; the viewport shows ~30. Jumping the selection
        // from the caret at 0 to byte 4000 (row 250) must invalidate the old
        // caret's row and the new block's rows — and nothing in between.
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 5000))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout

        let rects = hexView.changedSelectionRects(
            from: selection(0, 0, size: 5000),
            to: selection(4000, 4016, size: 5000))
        let invalidated = rows(rects, rowHeight: layout.rowHeight)

        // The caret's row 0 and the new block's row 250, each with one edge row.
        XCTAssertEqual(invalidated, [0, 1, 249, 250, 251],
                       "a far selection jump must invalidate the old and new spans only")
    }

    /// The stale-highlight bug: select block A, scroll it off the visible
    /// viewport, then select block B elsewhere. A's rows keep their old fill
    /// after scrolling back because the old viewport clamp dropped them from
    /// the invalidation — they were never marked dirty, and a layer-backed pane
    /// does not repaint unmarked rows that scroll back into view. A's rows must
    /// be invalidated even though they are off-screen (§13).
    func testOffScreenOldSelectionStaysInvalidated() throws {
        // 2000 bytes ≈ 125 rows; the viewport shows ~35. Scroll so rows 0-10
        // (block A) sit above the visible area — exactly the user's repro: the
        // old block is off-screen when the new block is selected.
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 2000))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout
        let clip = try XCTUnwrap(hexView.enclosingScrollView?.contentView)
        clip.setBoundsOrigin(NSPoint(x: 0, y: CGFloat(35) * layout.rowHeight))
        hexView.displayIfNeeded()

        // Select-block A at bytes 0..<176 (rows 0-10), then select block B at
        // bytes 640..<720 (rows 40-44).
        let rects = hexView.changedSelectionRects(
            from: selection(0, 176, size: 2000),
            to: selection(640, 720, size: 2000))
        let invalidated = rows(rects, rowHeight: layout.rowHeight)

        // Block A's rows are off-screen yet must repaint, or the stale fill
        // survives the scroll back; block B's rows repaint as the new fill.
        XCTAssertEqual(invalidated, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
                                     39, 40, 41, 42, 43, 44, 45],
                       "the off-screen old selection must stay invalidated so it repaints on scroll-back")
    }

    /// Select All on a large file would otherwise emit one display rect per row
    /// — hundreds of thousands on a big file — so a change spanning more than a
    /// threshold of rows collapses to a single full-bounds rect. Layer-backed
    /// display repaints that rect only where visible, so the cost stays
    /// O(visible) per frame (§13).
    func testHugeSelectionChangeFallsBackToOneFullBoundsRect() throws {
        // 200,000 bytes = 12,500 rows > the 4096-row threshold → full-bounds.
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200_000))
        defer { try? FileManager.default.removeItem(at: url) }

        let rects = hexView.changedSelectionRects(
            from: selection(0, 0, size: 200_000),
            to: selection(0, 200_000, size: 200_000))
        XCTAssertEqual(rects, [hexView.bounds])
    }

    /// The drag hot path (§13): `mouseDragged` drives `moveCaret(to:
    /// extendSelection:true)` and then reports the click's input region on
    /// every event. Before the fix the region report re-broadcast a *full*
    /// change, so each drag event fell through to `reloadData()` — a whole-
    /// pane repaint whose cost scales with the window height. That is exactly
    /// the lag the user still saw after the dirty-row work. A drag must go
    /// through the selection-only path exclusively.
    func testDragSelectionNeverTriggersFullRefresh() throws {
        let url = try tempFile([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        var fullRefreshes = 0
        var selectionRefreshes = 0
        pane.onChange = { fullRefreshes += 1 }
        pane.onSelectionChanged = { selectionRefreshes += 1 }

        // The per-event sequence a drag produces, extended across 6 rows. The
        // input region stays `.hex`, so each region report is a no-op.
        for offset: UInt64 in stride(from: 16, through: 96, by: 16) {
            pane.moveCaret(to: offset, extendSelection: true)
            pane.setInputRegion(.hex)
        }
        XCTAssertEqual(fullRefreshes, 0, "a drag must never trigger a full refresh (reloadData)")
        XCTAssertEqual(selectionRefreshes, 6)
    }

    /// Crossing from the hex column into the ASCII column moves the caret bar —
    /// a selection-only redraw of the caret's row, never a full refresh.
    func testInputRegionChangeUsesSelectionOnlyRedraw() throws {
        let url = try tempFile([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        var fullRefreshes = 0
        var selectionRefreshes = 0
        pane.onChange = { fullRefreshes += 1 }
        pane.onSelectionChanged = { selectionRefreshes += 1 }

        pane.setInputRegion(.ascii)
        XCTAssertEqual(fullRefreshes, 0)
        XCTAssertEqual(selectionRefreshes, 1)
        // Re-reporting the same region is a no-op.
        pane.setInputRegion(.ascii)
        XCTAssertEqual(selectionRefreshes, 1)
    }
}
