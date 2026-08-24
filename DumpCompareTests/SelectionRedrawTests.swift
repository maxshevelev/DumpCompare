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

    /// The span XOR plus the ±1 edge expansion, in both directions and in the
    /// collapse-to-a-caret shape. One test for the three, because
    /// `changedSelectionRects` is symmetric in `(old, new)` — every branch of it
    /// treats the two alike — so a from/to mirror cannot fail on its own.
    func testAChangedSelectionInvalidatesItsRowsAndTheirEdges() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight
        func changedRows(from old: SelectionModel, to new: SelectionModel) -> Set<Int> {
            rows(hexView.changedSelectionRects(from: old, to: new), rowHeight: rowHeight)
        }

        // Row 0 (bytes 0…15) was already selected; the drag adds rows 1–2. The
        // old selection's bottom edge (at the bottom of row 0) and the new one's
        // (below row 2) straddle their boundaries, so rows 0 and 3 join in.
        XCTAssertEqual(changedRows(from: selection(0, 16, size: 200),
                                   to: selection(0, 48, size: 200)),
                       [0, 1, 2, 3], "growing the selection repaints the rows it gained, plus the edges")
        XCTAssertEqual(changedRows(from: selection(0, 48, size: 200),
                                   to: selection(0, 16, size: 200)),
                       [0, 1, 2, 3], "and dragging back repaints exactly the same rows")

        // A selection collapsing to a caret elsewhere: the old span's rows clear
        // and the caret's own row appears.
        XCTAssertEqual(changedRows(from: selection(5, 20, size: 200),
                                   to: selection(20, 20, size: 200)),
                       [0, 1, 2], "a collapse to a caret repaints the old span and the caret's row")
    }

    /// The caret's own row has to repaint when a selection starts or ends at it,
    /// even though the span XOR is empty there — `if old.isEmpty` /
    /// `if new.isEmpty` in `changedSelectionRects`. Both directions in one test,
    /// again because the function is symmetric in `(old, new)`.
    func testACaretTurningIntoASelectionRepaintsItsOwnRow() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight
        func changedRows(from old: SelectionModel, to new: SelectionModel) -> Set<Int> {
            rows(hexView.changedSelectionRects(from: old, to: new), rowHeight: rowHeight)
        }

        XCTAssertEqual(changedRows(from: selection(5, 5, size: 200),
                                   to: selection(5, 6, size: 200)),
                       [0, 1], "the caret's own row must repaint when the first byte is selected")
        XCTAssertEqual(changedRows(from: selection(5, 6, size: 200),
                                   to: selection(5, 5, size: 200)),
                       [0, 1], "and when that one byte collapses back to a caret")
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

        // The same rule seen from the other side: the OLD span may be far above
        // the viewport and must still be invalidated, or its fill survives the
        // scroll back. (There is nothing to scroll here — `changedSelectionRects`
        // never reads the viewport, which is exactly why this holds.)
        let backwards = rows(hexView.changedSelectionRects(
            from: selection(0, 176, size: 5000),
            to: selection(4000, 4016, size: 5000)), rowHeight: layout.rowHeight)
        XCTAssertEqual(backwards, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 249, 250, 251],
                       "an off-screen old selection stays invalidated, whole")
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
        pane.onChange = { _ in fullRefreshes += 1 }
        pane.onSelectionChanged = { _ in selectionRefreshes += 1 }

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
        pane.onChange = { _ in fullRefreshes += 1 }
        pane.onSelectionChanged = { _ in selectionRefreshes += 1 }

        pane.setInputRegion(.ascii)
        XCTAssertEqual(fullRefreshes, 0)
        XCTAssertEqual(selectionRefreshes, 1)
        // Re-reporting the same region is a no-op.
        pane.setInputRegion(.ascii)
        XCTAssertEqual(selectionRefreshes, 1)
    }
}
