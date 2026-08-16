import DumpCompareCore
import XCTest
@testable import DumpCompare

/// The dirty-rows contract behind drag selection (§3.3): a selection move must
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

    func testSelectionFromEmptyCaretInvalidatesAnchorRowAndBelow() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        // A drag that starts on the caret's own byte fills only that row; the
        // row below is redrawn to cover the new edge's stroke.
        let rects = hexView.changedSelectionRects(
            from: selection(0, 0, size: 200),
            to: selection(0, 5, size: 200))
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1])
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

    func testBareCaretMoveInvalidatesCaretRowsAndNeighbours() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        // Arrow-key caret move from byte 5 to byte 40: only the two rows that
        // show a caret change (plus their neighbours for the caret bar's
        // stroke) — the whole span between them must not repaint.
        let rects = hexView.changedSelectionRects(
            from: selection(5, 5, size: 200),
            to: selection(40, 40, size: 200))
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [0, 1, 2, 3])
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
    /// Block) must invalidate only the on-screen rows — not every row between
    /// the old and new positions, which on a large file is millions of display
    /// rects unioned on the main thread. The virtualization guarantee that
    /// bounds a jump's repaint cost, mirroring
    /// `testBytesChangeClampsToVisibleRows` for the content path (§3.3).
    func testFarSelectionJumpClampsToVisibleRows() throws {
        // 5000 bytes ≈ 313 rows; the viewport shows ~30. Jumping the selection
        // from the caret at 0 to byte 4000 spans ~250 rows but must redraw only
        // the visible ones (plus their edge rows for the outline's stroke).
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 5000))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout
        let viewport = try XCTUnwrap(hexView.enclosingScrollView?.contentView.bounds)
        let visible = layout.visibleRowRange(in: viewport)

        let rects = hexView.changedSelectionRects(
            from: selection(0, 0, size: 5000),
            to: selection(4000, 4016, size: 5000))
        let invalidated = rows(rects, rowHeight: layout.rowHeight)

        // Only the visible rows plus one edge row on each side may repaint.
        XCTAssertLessThanOrEqual(invalidated.count, visible.count + 2,
                                 "a far selection jump must redraw only the visible rows plus their edges")
        XCTAssertFalse(invalidated.contains { $0 > visible.upperBound },
                       "no row below the viewport may be invalidated")
        XCTAssertFalse(invalidated.contains { $0 < visible.lowerBound - 1 && $0 >= 0 },
                       "no row above the viewport may be invalidated")
    }

    /// The drag hot path (§3.3): `mouseDragged` drives `moveCaret(to:
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
