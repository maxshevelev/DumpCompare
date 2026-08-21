import XCTest
@testable import DumpCompare

/// §20 Stage 1 — "Mark a row and see it": ⌘D marks (and unmarks) the caret's
/// row, and a marked row's address stands on a purple right-pointing arrow in
/// BOTH panes of a comparison. Covered here: the store's row arithmetic, the hex
/// view's rendering of a marked row in both panes, and the Edit-menu item and
/// its key. Names, the bookmark list, and the minimap are later stages.
@MainActor
final class BookmarkTests: XCTestCase {
    /// `MainWindowController()` assigns `NSApp.mainMenu`; restore it so the menu
    /// tests leave no process-wide side effect (same pattern as MainWindowMenuTests).
    private var previousMainMenu: NSMenu?

    override func setUp() {
        super.setUp()
        previousMainMenu = NSApp.mainMenu
    }

    override func tearDown() {
        NSApp.mainMenu = previousMainMenu
        previousMainMenu = nil
        super.tearDown()
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Store arithmetic

    /// A bookmark snaps to its row: any offset in a row marks that row's start,
    /// which is always a multiple of `HexLayout.bytesPerRow` (§20).
    func testRowContainingSnapsToRowStart() {
        XCTAssertEqual(BookmarkStore.row(containing: 0), 0)
        XCTAssertEqual(BookmarkStore.row(containing: 15), 0)
        XCTAssertEqual(BookmarkStore.row(containing: 16), 16)
        XCTAssertEqual(BookmarkStore.row(containing: 31), 16)
        XCTAssertEqual(BookmarkStore.row(containing: 32), 32)
        XCTAssertEqual(BookmarkStore.row(containing: 1_000_000), 1_000_000 - 1_000_000 % 16)
    }

    /// Two offsets in the same row are one bookmark: toggling the row from a
    /// second offset in it removes the mark rather than adding a second one.
    func testTwoOffsetsInOneRowAreOneBookmark() {
        let store = BookmarkStore()
        store.toggle(rowContaining: 5)      // row 0
        XCTAssertEqual(store.bookmarks.count, 1)
        store.toggle(rowContaining: 10)     // still row 0 → unmark
        XCTAssertEqual(store.bookmarks.count, 0)
    }

    /// Toggling an unmarked row adds an unnamed bookmark; toggling it again removes it.
    func testToggleAddsAndRemoves() {
        let store = BookmarkStore()
        let added = store.toggle(rowContaining: 16)
        XCTAssertEqual(added, Bookmark(row: 16, name: ""))
        XCTAssertEqual(store.bookmarks.map(\.row), [16])
        let removed = store.toggle(rowContaining: 16)
        XCTAssertNil(removed)
        XCTAssertTrue(store.bookmarks.isEmpty)
    }

    /// The list stays sorted by row regardless of the order the marks are added.
    func testBookmarksStaySortedByRow() {
        let store = BookmarkStore()
        store.toggle(rowContaining: 32)
        store.toggle(rowContaining: 0)
        store.toggle(rowContaining: 16)
        XCTAssertEqual(store.bookmarks.map(\.row), [0, 16, 32])
    }

    /// `rows(in:)` returns exactly the bookmarked rows whose start falls in the
    /// range — the per-range query the hex view asks on every draw (§20).
    func testRowsInRange() {
        let store = BookmarkStore()
        for offset in [0, 16, 32] { store.toggle(rowContaining: UInt64(offset)) }
        XCTAssertEqual(store.rows(in: 0..<32), [0, 16])
        XCTAssertEqual(store.rows(in: 16..<48), [16, 32])
        XCTAssertEqual(store.rows(in: 48..<64), [])
    }

    /// `bookmark(atRowContaining:)` finds the mark by any offset in its row.
    func testBookmarkAtRowContaining() {
        let store = BookmarkStore()
        store.toggle(rowContaining: 5)
        XCTAssertEqual(store.bookmark(atRowContaining: 10)?.row, 0)
        XCTAssertNil(store.bookmark(atRowContaining: 16))
    }

    /// `onChange` fires with the affected row's start offset, so the panes
    /// repaint just that row instead of the whole dump (§20).
    func testOnChangeFiresWithAffectedRow() {
        let store = BookmarkStore()
        var fired: [UInt64] = []
        store.onChange = { fired.append($0) }
        store.toggle(rowContaining: 5)     // mark row 0
        store.toggle(rowContaining: 40)    // mark row 32
        store.toggle(rowContaining: 40)    // unmark row 32
        XCTAssertEqual(fired, [0, 32, 32])
    }

    // MARK: - Rendering (both panes)

    /// Snapshots the view via `cacheDisplay`, which drives the real flipped
    /// `draw(_:)` path onto a bitmap (same pattern as CaretPlacementTests).
    private func render(_ view: HexView) -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("no bitmap rep")
            return NSBitmapImageRep()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The strongest purpleness (min(r, b) − g) inside a point-space rect.
    /// `systemPurple` (≈ 0.69, 0.32, 0.87) reads ≈ 0.36; paper, the ink-blue
    /// address, and the white bookmarked address all read ≤ 0, so this isolates
    /// the bookmark's purple fill and arrow from everything else on the row.
    private func purpleness(_ hexView: HexView, in pointRect: NSRect) throws -> CGFloat {
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
        let startX = max(0, Int(floor(pointRect.minX * scale)))
        let endX = min(rep.pixelsWide - 1, Int(ceil(pointRect.maxX * scale)))
        let startY = max(0, Int(floor(pointRect.minY * scale)))
        let endY = min(rep.pixelsHigh - 1, Int(ceil(pointRect.maxY * scale)))
        guard endX >= startX, endY >= startY else { return 0 }
        var maxP = CGFloat(0)
        for y in startY...endY {
            for x in startX...endX {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                maxP = max(maxP, min(c.redComponent, c.blueComponent) - c.greenComponent)
            }
        }
        return maxP
    }

    /// The vertical centre (y, in points) of the white address glyphs inside a
    /// point-space rect — the core of the glyphs is pure white on the purple
    /// fill, so this isolates the address from the mark and confirms the text
    /// sits centred on the arrow rather than merely somewhere on it.
    private func whiteTextCenterY(_ hexView: HexView, in pointRect: NSRect) throws -> CGFloat? {
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
        let startX = max(0, Int(floor(pointRect.minX * scale)))
        let endX = min(rep.pixelsWide - 1, Int(ceil(pointRect.maxX * scale)))
        let startY = max(0, Int(floor(pointRect.minY * scale)))
        let endY = min(rep.pixelsHigh - 1, Int(ceil(pointRect.maxY * scale)))
        guard endX >= startX, endY >= startY else { return nil }
        var sumY: CGFloat = 0
        var count = 0
        for y in startY...endY {
            for x in startX...endX {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.85, c.greenComponent > 0.85, c.blueComponent > 0.85 {
                    sumY += CGFloat(y)
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }
        return (sumY / CGFloat(count)) / scale
    }

    /// A marked row's address stands on a purple right-pointing arrow — and it
    /// does so in BOTH panes of a comparison, because the one shared list marks
    /// the same absolute row in each pane (§20). The redraw is driven the way
    /// the app drives it: the store's `onChange` → each pane's `redrawRow`.
    func testBookmarkedRowDrawsPurpleArrowInBothPanels() throws {
        let bytes = [UInt8](repeating: 0x11, count: 32)
        let urlA = try tempFile(bytes)
        let urlB = try tempFile(bytes)
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
        let store = BookmarkStore()
        paneA.bookmarkStore = store
        paneB.bookmarkStore = store

        let hexA = HexView()
        hexA.appearance = NSAppearance(named: .aqua)
        hexA.dataSource = paneA
        hexA.delegate = paneA
        hexA.reloadData()
        let hexB = HexView()
        hexB.appearance = NSAppearance(named: .aqua)
        hexB.dataSource = paneB
        hexB.delegate = paneB
        hexB.reloadData()

        // The app's redraw path: the store's change signal repaints the affected
        // row in each pane (FilePaneView binds this to `redrawRow`).
        store.onChange = { [weak hexA, weak hexB] row in
            hexA?.redrawRow(startingAt: row)
            hexB?.redrawRow(startingAt: row)
        }

        let layout = hexA.hexLayout
        let rowFrame = layout.rowFrame(row: 0)
        let columnFrame = layout.offsetColumnFrame(row: 0)
        // The arrow body is the offset's background; sample well inside the column.
        let bodyRect = columnFrame.insetBy(dx: 3, dy: 3)
        // The arrow's tip points right, into the gap before the hex column, at midY.
        let tipRect = NSRect(x: columnFrame.maxX + 1, y: rowFrame.midY - 2,
                             width: 3, height: 4)

        // Before the mark: the address is ink blue on paper — no purple in the
        // body or the (empty) tip.
        XCTAssertLessThan(try purpleness(hexA, in: bodyRect), 0.3, "unmarked row A has no purple offset")
        XCTAssertLessThan(try purpleness(hexB, in: bodyRect), 0.3, "unmarked row B has no purple offset")
        XCTAssertLessThan(try purpleness(hexA, in: tipRect), 0.3, "unmarked row A has no arrow tip")
        XCTAssertLessThan(try purpleness(hexB, in: tipRect), 0.3, "unmarked row B has no arrow tip")

        // Mark row 0 (any offset in it); onChange repaints the row in both panes.
        store.toggle(rowContaining: 3)

        // After the mark: both panes show the purple arrow body and its
        // right-pointing tip.
        XCTAssertGreaterThan(try purpleness(hexA, in: bodyRect), 0.3, "marked row A's address stands on the purple arrow")
        XCTAssertGreaterThan(try purpleness(hexB, in: bodyRect), 0.3, "marked row B's address stands on the purple arrow")
        XCTAssertGreaterThan(try purpleness(hexA, in: tipRect), 0.3, "marked row A's arrow points right")
        XCTAssertGreaterThan(try purpleness(hexB, in: tipRect), 0.3, "marked row B's arrow points right")

        // The white address is centred on the arrow's vertical middle (the
        // arrow spans the full row here, so that middle is the row's).
        for (hex, label) in [(hexA, "A"), (hexB, "B")] {
            let centerY = try whiteTextCenterY(hex, in: bodyRect)
            XCTAssertNotNil(centerY, "marked row \(label) draws its white address")
            XCTAssertEqual(try XCTUnwrap(centerY), rowFrame.midY, accuracy: 1.5,
                           "marked row \(label)'s address is vertically centred on the arrow")
        }

        // Unmarking clears the purple in both panes again.
        store.toggle(rowContaining: 3)
        XCTAssertLessThan(try purpleness(hexA, in: bodyRect), 0.3, "unmarked row A is purple-free again")
        XCTAssertLessThan(try purpleness(hexB, in: bodyRect), 0.3, "unmarked row B is purple-free again")
        XCTAssertLessThan(try purpleness(hexA, in: tipRect), 0.3, "unmarked row A's arrow tip is gone")
    }

    // MARK: - Menu

    /// The Edit menu carries "Add Bookmark" wired to the controller's
    /// `toggleBookmark`, bound to ⌘D — the gesture that has to cost nothing on a
    /// bench (§20).
    func testEditMenuHasAddBookmarkWithCmdD() {
        let item = MainWindowController().makeEditMenu().items.first { $0.title == "Add Bookmark" }
        XCTAssertNotNil(item, "the Edit menu should offer Add Bookmark")
        XCTAssertEqual(item?.action, #selector(MainViewController.toggleBookmark))
        XCTAssertEqual(item?.keyEquivalent, "d")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command])
    }

    /// The command is enabled only when the active pane has a file: with nothing
    /// open there is no caret row to mark, so the item is greyed out.
    func testAddBookmarkEnabledOnlyWithAFileOpen() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let editMenu = try XCTUnwrap(NSApp.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "Edit" })
        let item = try XCTUnwrap(editMenu.items.first {
            $0.action == #selector(MainViewController.toggleBookmark)
        }, "an Edit item adding a bookmark")

        XCTAssertFalse(controller.validateMenuItem(item), "no file open → disabled")

        let url = try tempFile([UInt8](repeating: 0x00, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        XCTAssertTrue(controller.validateMenuItem(item), "a file in the active pane → enabled")
    }
}
