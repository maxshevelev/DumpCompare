import DumpCompareCore
import XCTest
@testable import DumpCompare

/// The dirty-rect contract for content changes (§13): a byte edit
/// must fire `onContentChanged` with the exact overwritten range — never a full
/// `onChange` — a decoding change must touch only the decoded-text column, and
/// the companion pane must repaint the same rows when this pane edits (its diff
/// background recomputes live). `contentChangeRects` is the pure geometry that
/// decides, so these tests pin exactly which rows/columns it redraws and which
/// notification channel an edit uses, mirroring `SelectionRedrawTests` for the
/// selection path.
@MainActor
final class ContentRedrawTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A pane hosting a real hex view in a real window (same pattern as
    /// `SelectionRedrawTests.makePane`), so `contentChangeRects` runs against a
    /// real layout and viewport. The temp file stays on disk; the caller
    /// removes it when done.
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

    // MARK: - contentChangeRects geometry

    func testBytesChangeInvalidatesExactRows() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let rowHeight = hexView.hexLayout.rowHeight

        // Bytes 17…32 span rows 1 (16…31) and 2 (32…47); only those two rows
        // need repainting — not the whole pane.
        let rects = hexView.contentChangeRects(.bytes(in: 17..<33))
        XCTAssertEqual(rows(rects, rowHeight: rowHeight), [1, 2])
    }

    func testTextDecodingChangeInvalidatesOnlyAsciiBand() throws {
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout

        // A decoder change repaints the decoded-text column and no other column
        // — but over the whole document, not just the visible part: the decoder
        // feeds every row's text, and a row already drawn keeps its pixels until
        // it is marked dirty (§13).
        let rects = hexView.contentChangeRects(.textDecoding)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, layout.asciiX(column: 0))
        XCTAssertEqual(rects[0].width, layout.asciiColumnWidth)
        XCTAssertEqual(rects[0].minY, 0)
        XCTAssertEqual(rects[0].height, hexView.bounds.height)
        // This fixture is *shorter* than the viewport, which is what makes the
        // assertion above discriminating: clamped to the viewport the band would
        // have been the taller of the two.
        let viewport = try XCTUnwrap(hexView.enclosingScrollView?.contentView.bounds)
        XCTAssertLessThan(rects[0].height, viewport.height)
    }

    func testBytesChangeInvalidatesOffScreenRowsToo() throws {
        // A file taller than the viewport. Every row the range spans must be
        // marked dirty, on screen or not: a layer-backed view keeps a drawn
        // row's pixels, so an off-screen byte change would still show its old
        // value when scrolled back to. Off-screen invalidation is deferred by
        // the display, so it costs nothing now (§13).
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: 5000))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout
        let viewport = try XCTUnwrap(hexView.enclosingScrollView?.contentView.bounds)
        let visibleRows = Set(layout.visibleRowRange(in: viewport))

        let rects = hexView.contentChangeRects(.bytes(in: 0..<5000))
        let invalidated = rows(rects, rowHeight: layout.rowHeight)
        // 5000 bytes span rows 0...312 (the last row is partial).
        XCTAssertEqual(invalidated, Set(0...((5000 - 1) / 16)), "every row the range spans")
        XCTAssertTrue(invalidated.isStrictSuperset(of: visibleRows),
                      "which is strictly more than the rows on screen")
    }

    func testHugeBytesChangeFallsBackToOneFullBoundsRect() throws {
        // Past the per-row threshold the invalidation collapses to a single
        // full-bounds rect instead of emitting a rect per row. Layer-backed
        // display still draws only the visible part of it, so fidelity is
        // unchanged (§13).
        let rows = 5000
        let (hexView, url) = try makePane([UInt8](repeating: 0, count: rows * 16))
        defer { try? FileManager.default.removeItem(at: url) }

        let rects = hexView.contentChangeRects(.bytes(in: 0..<UInt64(rows * 16)))
        XCTAssertEqual(rects.count, 1, "one rect, not \(rows)")
        XCTAssertEqual(rects[0], hexView.bounds)

        // Just under the threshold it is still one rect per row.
        let (smallView, smallURL) = try makePane([UInt8](repeating: 0, count: 4000 * 16))
        defer { try? FileManager.default.removeItem(at: smallURL) }
        let smallRects = smallView.contentChangeRects(.bytes(in: 0..<UInt64(4000 * 16)))
        XCTAssertEqual(smallRects.count, 4000)
    }

    // MARK: - Notification channels

    func testTypeASCIIUsesContentChangeNotFullRefresh() throws {
        let url = try tempFile([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        var contentChanges: [HexViewChange] = []
        var fullRefreshes = 0
        pane.onContentChanged = { contentChanges.append($0) }
        pane.onChange = { fullRefreshes += 1 }

        pane.moveCaret(to: 5)
        pane.typeASCII(0x41)  // 'A'

        XCTAssertEqual(fullRefreshes, 0, "a byte edit must never trigger a full refresh (reloadData)")
        XCTAssertEqual(contentChanges, [.bytes(in: 5..<6)])
    }

    func testTypeHexNibblesUseContentChangeNotFullRefresh() throws {
        let url = try tempFile([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        var contentChanges: [HexViewChange] = []
        var fullRefreshes = 0
        pane.onContentChanged = { contentChanges.append($0) }
        pane.onChange = { fullRefreshes += 1 }

        pane.moveCaret(to: 5)
        pane.typeHexNibble(0xA)  // high nibble
        pane.typeHexNibble(0x5)  // low nibble — byte 0xA5 at offset 5

        XCTAssertEqual(fullRefreshes, 0)
        XCTAssertEqual(contentChanges, [.bytes(in: 5..<6), .bytes(in: 5..<6)])
    }

    func testTextDecodingChangeUsesContentChangeNotFullRefresh() throws {
        let url = try tempFile([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        var contentChanges: [HexViewChange] = []
        var fullRefreshes = 0
        pane.onContentChanged = { contentChanges.append($0) }
        pane.onChange = { fullRefreshes += 1 }

        NotificationCenter.default.post(name: TextDecodingSettingsStore.didChangeNotification, object: nil)

        XCTAssertEqual(fullRefreshes, 0, "a decoding change must not repaint the whole pane")
        XCTAssertEqual(contentChanges, [.textDecoding])
    }

    func testEditInAPaneInvalidatesCompanionContent() throws {
        let urlA = try tempFile([UInt8](repeating: 0, count: 100))
        let urlB = try tempFile([UInt8](repeating: 0, count: 100))
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        paneA.companion = paneB
        paneB.companion = paneA

        var companionContent: [HexViewChange] = []
        var ownContent: [HexViewChange] = []
        paneB.onCompanionContentChanged = { companionContent.append($0) }
        paneB.onContentChanged = { ownContent.append($0) }

        paneA.moveCaret(to: 5)
        paneA.typeASCII(0x41)

        XCTAssertEqual(companionContent, [.bytes(in: 5..<6)],
                       "pane B redraws the diff background for the edited range")
        XCTAssertTrue(ownContent.isEmpty, "the companion's own content channel must not fire")
    }

    /// The undo regression: a structural edit in pane A (undo/redo/revert,
    /// length-changing insert/delete, open) must tell the companion to repaint
    /// its diff background. The diff is computed live in `hexByteStates`, so
    /// the companion only needs to redraw — but a bare `onChange` (full
    /// refresh) reaches only the active pane, and the old full-`notify()` path
    /// gave the companion just the mirrored-selection frames. Without this
    /// channel an undo would leave the companion's difference background stale
    /// until that pane happened to repaint for its own reason.
    func testUndoInAPaneInvalidatesCompanionDiff() throws {
        let urlA = try tempFile([UInt8](repeating: 0, count: 100))
        let urlB = try tempFile([UInt8](repeating: 0, count: 100))
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        paneA.companion = paneB
        paneB.companion = paneA

        var companionContent: [HexViewChange] = []
        var ownContent: [HexViewChange] = []
        paneB.onCompanionContentChanged = { companionContent.append($0) }
        paneB.onContentChanged = { ownContent.append($0) }

        paneA.moveCaret(to: 5)
        paneA.typeASCII(0x41)
        companionContent.removeAll()

        try paneA.undo()

        // Undo derives the net edit of the transaction — a single overwritten
        // byte — so the companion repaints exactly that range's diff background,
        // not the whole pane.
        XCTAssertEqual(companionContent, [.bytes(in: 5..<6)])
        XCTAssertTrue(ownContent.isEmpty, "the companion's own content channel must not fire")

        // The same rule for an undo that changes the length: the net edit is a
        // delete of the inserted span, so the notification runs from the insert
        // offset through EOF — over the larger of the two panes, so EOF-only
        // differences repaint too.
        try paneA.pasteInsert([0xFF, 0xFE])
        companionContent.removeAll()
        try paneA.undo()
        // The caret is still at 5 from the edit above, so that is where the
        // insert — and therefore the repaint — starts.
        XCTAssertEqual(companionContent, [.bytes(in: 5..<100)],
                       "undo of an insert repaints the companion from the insert through EOF")
    }

    /// `deleteBytes` and `pasteInsert` change the file length mid-file — every
    /// offset at or past the edit shifts, so the companion's diff can change
    /// anywhere; it repaints its whole visible content, like undo/redo.
    func testLengthChangingEditsInvalidateCompanionDiff() throws {
        let urlA = try tempFile([UInt8](repeating: 0, count: 100))
        let urlB = try tempFile([UInt8](repeating: 0, count: 100))
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        paneA.companion = paneB
        paneB.companion = paneA

        var companionContent: [HexViewChange] = []
        paneB.onCompanionContentChanged = { companionContent.append($0) }

        try paneA.deleteBytes(in: 8..<16)      // A: 100 → 92; B still 100
        XCTAssertEqual(companionContent, [.bytes(in: 0..<100)],
                       "a delete shifts every byte at/past 8, so the companion repaints every row")

        companionContent.removeAll()
        try paneA.pasteInsert([0xFF, 0xFE])    // A: 92 → 94
        XCTAssertEqual(companionContent, [.bytes(in: 0..<100)],
                       "an insert shifts every byte at/past the caret, so the companion repaints every row")
    }

    func testStructuralEditsStayFullRefresh() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        var contentChanges: [HexViewChange] = []
        var fullRefreshes = 0
        pane.onContentChanged = { contentChanges.append($0) }
        pane.onChange = { fullRefreshes += 1 }

        // Length-changing edits and undo replace the layout wholesale — they
        // must keep using the full-refresh channel.
        try pane.deleteBytes(in: 0..<8)
        XCTAssertEqual(fullRefreshes, 1)
        XCTAssertTrue(contentChanges.isEmpty)

        fullRefreshes = 0
        try pane.pasteInsert([0xFF, 0xFE])
        XCTAssertEqual(fullRefreshes, 1)
        XCTAssertTrue(contentChanges.isEmpty)

        fullRefreshes = 0
        try pane.undo()
        XCTAssertEqual(fullRefreshes, 1)
        XCTAssertTrue(contentChanges.isEmpty)
    }

    /// Typing past the end of the file grows it — a structural change that must
    /// fall back to a full refresh (the layout's frame height and caret row
    /// change), not a region-scoped content redraw.
    func testEditGrowingFileUsesFullRefresh() throws {
        let url = try tempFile([UInt8](repeating: 0, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        var contentChanges: [HexViewChange] = []
        var fullRefreshes = 0
        pane.onContentChanged = { contentChanges.append($0) }
        pane.onChange = { fullRefreshes += 1 }

        pane.moveCaret(to: 16)  // caret at EOF
        pane.typeASCII(0x41)    // appends a 17th byte

        XCTAssertEqual(fullRefreshes, 1, "a size-changing edit must rebuild the layout")
        XCTAssertTrue(contentChanges.isEmpty)
    }

    private func selection(_ start: UInt64, _ end: UInt64, size: UInt64) -> SelectionModel {
        SelectionModel(start: start, end: end, fileSize: size)
    }
}
