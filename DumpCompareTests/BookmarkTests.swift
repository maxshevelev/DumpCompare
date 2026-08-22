import XCTest
@testable import DumpCompare

/// §20 Bookmarks, stages 1 and 2.
///
/// Stage 1 — "Mark a row and see it": ⌘D marks (and unmarks) the caret's row, and
/// a marked row's address stands on a purple mark in BOTH panes of a comparison.
/// Covered here: the store's row arithmetic, the mark's geometry and rendering
/// (including the right-click outline), the app's own repaint wiring, and the
/// Edit-menu item with its key.
///
/// Stage 2 — "Give it a name": the naming popover ⌘D opens on a mark it makes
/// (Return saves, Esc removes the mark again), ⇧⌘D renaming through the same
/// popover, the offset menu's Toggle and Rename items, what the store does with a
/// name, and the two places a name shows before the list exists — the mark's
/// tooltip and VoiceOver.
///
/// The bookmark list, the form, and the minimap arrows are later stages.
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

    // MARK: - The mark's geometry

    /// The tip is a blunt 120° point whatever the font size — its reach follows
    /// from the mark's height, which scales with the font — and it never crosses
    /// the gap into the hex column (§20.4).
    func testBookmarkTipIsABlunt120DegreePoint() {
        for height in [12, 16, 24, 40] as [CGFloat] {
            // A roomy gap, so the angle decides the reach rather than the clamp.
            let reach = HexView.bookmarkTipReach(height: height, gap: height * 2)
            let apex = 2 * atan2(height / 2, reach) * 180 / .pi
            XCTAssertEqual(apex, 120, accuracy: 0.01, "a mark \(height) pt tall")
        }
        // A gap too narrow for that angle clamps the reach rather than letting
        // the tip touch the hex column; the body already spends the ring's
        // padding of that gap, and a point of air is left beyond the tip.
        XCTAssertEqual(HexView.bookmarkTipReach(height: 40, gap: 6),
                       6 - HexView.mirrorContourPadding - 1, accuracy: 0.001)
        XCTAssertEqual(HexView.bookmarkTipReach(height: 40, gap: 1), 0,
                       "a gap with no room at all leaves the mark tipless, not inverted")
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

    /// The largest value `metric` takes on any pixel inside a point-space rect.
    private func maxMetric(_ hexView: HexView, in pointRect: NSRect,
                           _ metric: (NSColor) -> CGFloat) -> CGFloat {
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
        let startX = max(0, Int(floor(pointRect.minX * scale)))
        let endX = min(rep.pixelsWide - 1, Int(ceil(pointRect.maxX * scale)))
        let startY = max(0, Int(floor(pointRect.minY * scale)))
        let endY = min(rep.pixelsHigh - 1, Int(ceil(pointRect.maxY * scale)))
        guard endX >= startX, endY >= startY else { return 0 }
        var best = CGFloat(0)
        for y in startY...endY {
            for x in startX...endX {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                best = max(best, metric(c))
            }
        }
        return best
    }

    /// The strongest purpleness (min(r, b) − g) inside a point-space rect.
    /// `systemPurple` (≈ 0.69, 0.32, 0.87) reads ≈ 0.36; paper, the ink-blue
    /// address, the white bookmarked address and the accent focus ring (a blue,
    /// so min(r, b) − g < 0) all read ≤ 0, so this isolates the bookmark's own
    /// purple — fill or stroke — from everything else on the row.
    private func purpleness(_ hexView: HexView, in pointRect: NSRect) throws -> CGFloat {
        maxMetric(hexView, in: pointRect) { min($0.redComponent, $0.blueComponent) - $0.greenComponent }
    }

    /// The strongest blueness (b − r) inside a point-space rect. `inkBlue` in
    /// aqua (0.33, 0.54, 0.78) reads 0.45; the purple fill reads 0.18 and white
    /// glyphs 0, so this tells an address drawn in its own ink from one drawn in
    /// white on the mark.
    private func blueness(_ hexView: HexView, in pointRect: NSRect) throws -> CGFloat {
        maxMetric(hexView, in: pointRect) { $0.blueComponent - $0.redComponent }
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

        // The white address stays vertically centred on the mark, which is the
        // row's own height, so its middle is the row's.
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

    /// A right-click on a marked address does not bury the mark under the accent
    /// focus ring: the mark itself becomes the ring — the same shape stroked in
    /// the bookmark colour, no fill — and the address goes back to its own ink,
    /// there being no fill left to read against (§20.4). A dismissed menu
    /// restores the fill.
    func testRightClickOnAMarkedRowOutlinesTheMarkInsteadOfFramingIt() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let store = BookmarkStore()
        pane.bookmarkStore = store

        let hex = HexView()
        hex.appearance = NSAppearance(named: .aqua)
        hex.dataSource = pane
        hex.delegate = pane
        hex.reloadData()

        let layout = hex.hexLayout
        let rowFrame = layout.rowFrame(row: 1)
        let columnFrame = layout.offsetColumnFrame(row: 1)
        // Inside the fill, clear of the stroke: the mark's body is the column
        // padded outwards, so its stroke runs outside these bounds.
        let interior = columnFrame.insetBy(dx: 4, dy: 3)
        // The stroke's left edge: the padded rect's own minX, ± half the line
        // width, sampled down the whole row — the outline is dashed (§20.4), so a
        // short window could land in a gap.
        let leftEdge = NSRect(x: columnFrame.minX - HexView.mirrorContourPadding - 1,
                             y: rowFrame.minY, width: 3, height: rowFrame.height)
        let anchor = HexView.ContextMenuAnchor(offset: 16, framesByte: false)

        // `render` drives a full `draw(_:)`, so these assertions read the state
        // of the pane rather than what a repaint happened to reach.
        // A band strictly between the padded rect's left edge and the column's,
        // and clear of the column's own edge at either rendering scale: the
        // mark's body is the focus ring's rect, so purple reaches out there
        // (§20.4). Sampling right up to the column would pass either way — the
        // pixel rounding would catch the fill's edge.
        let padBand = NSRect(x: columnFrame.minX - HexView.mirrorContourPadding,
                             y: rowFrame.midY - 2, width: 0.8, height: 4)

        store.toggle(rowContaining: 16)
        XCTAssertGreaterThan(try purpleness(hex, in: interior), 0.3,
                             "with no menu up the mark is filled")
        XCTAssertGreaterThan(try purpleness(hex, in: padBand), 0.3,
                             "the mark is as wide as the right-click focus ring, padding included")
        XCTAssertLessThan(try blueness(hex, in: interior), 0.35,
                          "the address on the fill is white, not ink blue")

        hex.beginContextMenu(at: anchor)
        XCTAssertLessThan(try purpleness(hex, in: interior), 0.3,
                          "the menu turns the mark into an outline: no fill inside it")
        XCTAssertGreaterThan(try purpleness(hex, in: leftEdge), 0.3,
                             "the outline is the bookmark colour, not the accent ring")
        XCTAssertGreaterThan(try blueness(hex, in: interior), 0.35,
                             "with no fill to read against, the address keeps its ink")

        hex.endContextMenu(at: anchor)
        XCTAssertGreaterThan(try purpleness(hex, in: interior), 0.3,
                             "dismissing the menu restores the fill")
        XCTAssertLessThan(try blueness(hex, in: interior), 0.35,
                          "and the address goes back to white on it")
    }

    /// A menu opened on a *byte* of a marked row frames that byte as usual and
    /// leaves the mark filled — only the address anchor occupies the mark's rect
    /// (§20.4).
    func testRightClickOnAByteOfAMarkedRowLeavesTheMarkFilled() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let store = BookmarkStore()
        pane.bookmarkStore = store

        let hex = HexView()
        hex.appearance = NSAppearance(named: .aqua)
        hex.dataSource = pane
        hex.delegate = pane
        hex.reloadData()

        let interior = hex.hexLayout.offsetColumnFrame(row: 1).insetBy(dx: 4, dy: 3)
        store.toggle(rowContaining: 16)
        hex.beginContextMenu(at: HexView.ContextMenuAnchor(offset: 20, framesByte: true))
        XCTAssertGreaterThan(try purpleness(hex, in: interior), 0.3,
                             "a byte's menu doesn't touch the row's mark")
    }

    // MARK: - The app's own wiring

    /// A pane view hosting a real hex view in a real window, in one half of it
    /// (same pattern as OffsetContextMenuTests). The halves must not overlap:
    /// AppKit invalidates a view when an overlapping sibling is invalidated, and
    /// these tests measure which pane was asked to repaint.
    private func host(_ pane: PaneViewModel, in window: NSWindow, right: Bool) throws -> FilePaneView {
        let content = try XCTUnwrap(window.contentView)
        let filePane = FilePaneView(viewModel: pane)
        filePane.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(filePane)
        NSLayoutConstraint.activate([
            filePane.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5),
            right
                ? filePane.trailingAnchor.constraint(equalTo: content.trailingAnchor)
                : filePane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filePane.topAnchor.constraint(equalTo: content.topAnchor),
            filePane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.layoutIfNeeded()
        return filePane
    }

    /// The chain the app actually runs: the window's one store → each pane's
    /// `onBookmarksChanged` (wired in `WindowViewModel.init`) → the pane view's
    /// `redrawRow` (bound in `FilePaneView`). The rendering test above installs
    /// its own `onChange`, so without this nothing notices if a link comes
    /// loose: the mark would simply stop appearing until something else
    /// repainted the row (§20).
    func testAMarkRepaintsBothPanesThroughTheAppsOwnWiring() throws {
        let bytes = [UInt8](repeating: 0x11, count: 48)
        let urlA = try tempFile(bytes)
        let urlB = try tempFile(bytes)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let model = WindowViewModel()
        try model.pane1.open(url: urlA)
        try model.pane2.open(url: urlB)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let paneA = try host(model.pane1, in: window, right: false)
        let paneB = try host(model.pane2, in: window, right: true)
        let hexA = try XCTUnwrap(paneA.scrollView.documentView as? HexView)
        let hexB = try XCTUnwrap(paneB.scrollView.documentView as? HexView)

        XCTAssertNotNil(model.pane1.onBookmarksChanged, "pane 1's view binds the repaint")
        XCTAssertNotNil(model.pane2.onBookmarksChanged, "pane 2's view binds the repaint")

        // A pending display is drained first (a view that has never displayed is
        // dirty by definition), so what the toggle marks dirty is measurable.
        func settle() {
            window.contentView?.display()
            XCTAssertFalse(hexA.needsDisplay, "pane 1 starts clean")
            XCTAssertFalse(hexB.needsDisplay, "pane 2 starts clean")
        }

        settle()
        model.bookmarkStore.toggle(rowContaining: 20)
        XCTAssertTrue(hexA.needsDisplay, "marking a row invalidates it in pane 1")
        XCTAssertTrue(hexB.needsDisplay, "and in pane 2 — one shared list, both panes")

        // And unmarking has to repaint too, or the mark stays on screen.
        settle()
        model.bookmarkStore.toggle(rowContaining: 20)
        XCTAssertTrue(hexA.needsDisplay, "unmarking invalidates it in pane 1")
        XCTAssertTrue(hexB.needsDisplay, "unmarking invalidates it in pane 2")
    }

    // MARK: - Menu

    /// The command is enabled only when the active pane has a file: with nothing
    /// open there is no caret row to mark, so the item is greyed out.
    func testToggleBookmarkEnabledOnlyWithAFileOpen() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let editMenu = try XCTUnwrap(NSApp.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "Edit" })
        let item = try XCTUnwrap(editMenu.items.first {
            $0.action == #selector(MainViewController.toggleBookmark)
        }, "an Edit item toggling a bookmark")

        XCTAssertFalse(controller.validateMenuItem(item), "no file open → disabled")

        let url = try tempFile([UInt8](repeating: 0x00, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        XCTAssertTrue(controller.validateMenuItem(item), "a file in the active pane → enabled")
    }

    // MARK: - Names: the store (§20.2)

    /// A name is stored trimmed, and one that is nothing but whitespace is no
    /// name at all — so "  " and "" are the same bookmark, shown by address.
    func testANameIsStoredTrimmed() {
        let store = BookmarkStore()
        store.add(rowContaining: 16, name: "  boot block \n")
        XCTAssertEqual(store.bookmark(atRowContaining: 16)?.name, "boot block")
        store.rename(rowContaining: 16, to: "   ")
        XCTAssertEqual(store.bookmark(atRowContaining: 16)?.name, "",
                       "a whitespace-only name is unnamed")
    }

    /// `add` marks and names in one act, and on an already-marked row it keeps
    /// the one mark and takes the new name — the path both ⇧⌘D and the context
    /// menu's naming item use, whether the row is marked yet or not (§20.2).
    func testAddNamesAnUnmarkedRowAndRenamesAMarkedOne() {
        let store = BookmarkStore()
        let added = store.add(rowContaining: 20, name: "ME region")
        XCTAssertEqual(added, Bookmark(row: 16, name: "ME region"))
        XCTAssertEqual(store.bookmarks.count, 1)

        let again = store.add(rowContaining: 30, name: "descriptor")
        XCTAssertEqual(again, Bookmark(row: 16, name: "descriptor"))
        XCTAssertEqual(store.bookmarks.count, 1, "one row still carries one mark")
    }

    /// Renaming is for a mark that exists: an unmarked row is left alone, and the
    /// caller can tell, so "rename" never quietly creates a bookmark.
    func testRenameOnlyTouchesAMarkedRow() {
        let store = BookmarkStore()
        XCTAssertNil(store.rename(rowContaining: 16, to: "nope"))
        XCTAssertTrue(store.bookmarks.isEmpty)

        store.add(rowContaining: 16)
        XCTAssertEqual(store.rename(rowContaining: 16, to: "vendor block")?.name, "vendor block")
        XCTAssertEqual(store.bookmarks.map(\.name), ["vendor block"])
    }

    /// `remove` says whether there was a mark to remove — the context menu's item
    /// only ever removes, so nothing has to read the list first.
    func testRemoveReportsWhetherThereWasAMark() {
        let store = BookmarkStore()
        XCTAssertFalse(store.remove(rowContaining: 16))
        store.add(rowContaining: 16)
        XCTAssertTrue(store.remove(rowContaining: 16))
        XCTAssertTrue(store.bookmarks.isEmpty)
    }

    /// Naming, renaming and removing all repaint: each fires `onChange` with the
    /// row, as toggling does, or a name typed in the sheet would not show up
    /// until something else repainted the row (§20).
    func testNamingPathsFireOnChange() {
        let store = BookmarkStore()
        var fired: [UInt64] = []
        store.onChange = { fired.append($0) }
        store.add(rowContaining: 20, name: "a")     // row 16
        store.rename(rowContaining: 20, to: "b")
        store.remove(rowContaining: 20)
        XCTAssertEqual(fired, [16, 16, 16])
    }

    /// An unnamed bookmark is not nameless: it is called by where it is, so it
    /// shows its address wherever a name is shown (§20.2).
    func testDisplayNameFallsBackToTheAddress() {
        XCTAssertEqual(Bookmark(row: 0x10, name: "").displayName, "0x00000010")
        XCTAssertEqual(Bookmark(row: 0x10, name: "boot").displayName, "boot")
        XCTAssertEqual(Bookmark(row: 0x1_0000_0000, name: "").displayName, "0x100000000",
                       "an address wider than eight digits is not truncated")
    }

    /// The outline is dashed, not solid: at the focus ring's line width a closed
    /// purple loop around an address reads as a slab (§20.4). So its left edge
    /// has ink in some places and paper in others — a solid stroke would have ink
    /// all the way down.
    func testTheOutlineIsDashed() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let store = BookmarkStore()
        pane.bookmarkStore = store
        store.add(rowContaining: 16)

        let hex = HexView()
        hex.appearance = NSAppearance(named: .aqua)
        hex.dataSource = pane
        hex.delegate = pane
        hex.reloadData()
        hex.beginContextMenu(at: HexView.ContextMenuAnchor(offset: 16, framesByte: false))

        let layout = hex.hexLayout
        let rowFrame = layout.rowFrame(row: 1)
        let x = layout.offsetColumnFrame(row: 1).minX - HexView.mirrorContourPadding - 1
        // How much of the stroke's own line is inked: a dash pattern of 3 on, 2
        // off covers about three fifths of it, a solid stroke all of it. Measured
        // along the straight part, clear of the rounded corners.
        var inked = 0
        var total = 0
        var y = rowFrame.minY + HexView.mirrorContourRadius + 1
        while y < rowFrame.maxY - HexView.mirrorContourRadius - 1 {
            if try purpleness(hex, in: NSRect(x: x, y: y, width: 3, height: 0.2)) > 0.2 {
                inked += 1
            }
            total += 1
            y += 0.25
        }

        XCTAssertGreaterThan(total, 10, "enough of the edge to measure")
        let fraction = Double(inked) / Double(total)
        XCTAssertGreaterThan(fraction, 0.2, "the outline is drawn")
        XCTAssertLessThan(fraction, 0.85,
                          "and it is dashed — a solid stroke inks its whole length")
        XCTAssertEqual(HexView.bookmarkOutlineDashes.count, 2, "dash, gap")
    }

    /// The path starts halfway along an edge, never at a corner: `appendArc`
    /// leaves the path past the corner it rounds, so a path that began at the
    /// top-left vertex closed with a spur back into it — the notch that showed on
    /// the outlined mark (§20.4).
    func testTheMarkPathDoesNotCloseIntoACorner() throws {
        let body = CGRect(x: 10, y: 20, width: 60, height: 16)
        let path = HexView.bookmarkMarkPath(body: body, tipReach: 4)

        var points = [NSPoint](repeating: .zero, count: 3)
        XCTAssertEqual(path.element(at: 0, associatedPoints: &points), .moveTo)
        XCTAssertEqual(points[0].x, body.midX, accuracy: 0.01,
                       "the path opens midway along the top edge")
        XCTAssertEqual(points[0].y, body.minY, accuracy: 0.01)
        XCTAssertNotEqual(points[0].x, body.minX, "not at the top-left corner")
    }

    // MARK: - Naming: the popover itself (§20.3)

    /// The popover's own contract: Return saves what was typed, Esc backs out,
    /// and a dismissal by any other means (a click outside it) keeps what was
    /// typed — the mark is already on the row by then.
    func testThePopoverReportsReturnEscAndDismissal() throws {
        func popover(existing: String?) -> (BookmarkEditPopoverController, () -> [String]) {
            var events: [String] = []
            let controller = BookmarkEditPopoverController(
                row: 0x10, existingName: existing,
                onCommit: { events.append("commit:\($0):\($1)") },
                onCancel: { events.append("cancel") }
            )
            controller.loadViewIfNeeded()
            return (controller, { events })
        }

        let (returning, returnEvents) = popover(existing: nil)
        returning.nameField.stringValue = "ME region"
        returning.commit()
        XCTAssertEqual(returnEvents(), ["commit:16:ME region"])

        let (escaping, escEvents) = popover(existing: nil)
        escaping.nameField.stringValue = "abandoned"
        escaping.cancel()
        XCTAssertEqual(escEvents(), ["cancel"], "Esc drops the name AND the mark")

        let (clickedAway, clickEvents) = popover(existing: "old")
        clickedAway.nameField.stringValue = "new"
        clickedAway.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(clickEvents(), ["commit:16:new"],
                       "a click outside keeps the typed name")

        // A dismissal keeps what can be kept: the name, and the address only if
        // it names a row. A half-typed address does not move the bookmark.
        let (halfTyped, halfTypedEvents) = popover(existing: nil)
        halfTyped.offsetField.stringValue = "0x"
        halfTyped.nameField.stringValue = "ME region"
        halfTyped.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(halfTypedEvents(), ["commit:16:ME region"],
                       "a half-typed address leaves the bookmark on its own row, named")
    }

    /// Only the first outcome counts: the close that follows a Return or an Esc
    /// must not commit a second time.
    func testThePopoverSettlesOnce() throws {
        var events: [String] = []
        let controller = BookmarkEditPopoverController(
            row: 0x10, existingName: nil,
            onCommit: { events.append("commit:\($0):\($1)") },
            onCancel: { events.append("cancel") }
        )
        controller.loadViewIfNeeded()
        controller.cancel()
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        controller.commit()
        XCTAssertEqual(events, ["cancel"])
    }

    /// It opens ready for the keyboard: an empty name field for a new mark and
    /// the current name for an edit, the row's address in a field of its own so
    /// it can be corrected too. And nothing else: two lines, no buttons, no
    /// explanation of Return and Esc.
    func testThePopoverOpensForTheRightJob() throws {
        let creating = BookmarkEditPopoverController(row: 0x10, existingName: nil,
                                                    onCommit: { _, _ in }, onCancel: {})
        creating.loadViewIfNeeded()
        XCTAssertEqual(creating.nameField.stringValue, "")
        XCTAssertEqual(creating.nameField.placeholderString, "Name",
                       "the placeholder is the field's label, so there is no label")
        XCTAssertEqual(creating.offsetField.stringValue, "0x00000010",
                       "the address is a field now — it can be corrected here (§20.3)")
        XCTAssertTrue(creating.labelTexts.isEmpty, "no titles: two fields say it all")
        XCTAssertTrue(creating.buttons.isEmpty,
                      "a mark still being named needs no Delete: its Esc removes it")
        // The field spans the popover, so a long name has all the room there is.
        creating.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(creating.nameField.frame.width, creating.view.frame.width - 32,
                       accuracy: 0.5, "the field runs the popover's width, inside its insets")

        let editing = BookmarkEditPopoverController(row: 0x10, existingName: "ME region",
                                                   onCommit: { _, _ in }, onCancel: {})
        editing.loadViewIfNeeded()
        XCTAssertEqual(editing.nameField.stringValue, "ME region")
        XCTAssertEqual(editing.offsetField.stringValue, "0x00000010")
        XCTAssertTrue(editing.buttons.isEmpty,
                      "and without an onDelete there is still nothing to press")
    }

    /// Removing is the one act the popover's keys cannot express — Esc means
    /// "leave it as it was" — so an existing bookmark gets a Delete button
    /// (§20.3). It removes the bookmark and closes; nothing else runs.
    func testAnExistingBookmarkCanBeDeletedFromThePopover() throws {
        var events: [String] = []
        let controller = BookmarkEditPopoverController(
            row: 0x10, existingName: "ME region",
            onCommit: { events.append("commit:\($0):\($1)") },
            onCancel: { events.append("cancel") },
            onDelete: { events.append("delete") })
        controller.loadViewIfNeeded()

        let delete = try XCTUnwrap(controller.deleteButton, "an existing bookmark offers Delete")
        XCTAssertEqual(delete.title, "Delete")
        XCTAssertEqual(controller.buttons.map(\.title), ["Delete"],
                       "one button, and only that one")

        controller.deletePressed()
        XCTAssertEqual(events, ["delete"])
        controller.commit()
        XCTAssertEqual(events, ["delete"], "it has settled: a later Return does nothing")
    }

    /// The caret goes to the NAME in both jobs — the address is already right,
    /// it is there to be corrected — and an existing name arrives selected, so
    /// typing replaces it instead of appending to it.
    func testThePopoverFocusesTheNameAndPreselectsAnExistingOne() throws {
        func focused(existingName: String?) throws -> NSTextView {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let controller = BookmarkEditPopoverController(row: 0x10, existingName: existingName,
                                                          onCommit: { _, _ in }, onCancel: {})
            window.contentView = controller.view
            controller.viewDidAppear()
            addTeardownBlock { @MainActor in window.orderOut(nil) }
            return try XCTUnwrap(window.firstResponder as? NSTextView,
                                 "a field's editor must hold the focus")
        }

        let creating = try focused(existingName: nil)
        XCTAssertEqual(creating.string, "", "the caret starts in the empty Name field")

        let editing = try focused(existingName: "ME region")
        XCTAssertEqual(editing.string, "ME region")
        XCTAssertEqual(editing.selectedRange, NSRange(location: 0, length: 9),
                       "the existing name is selected, ready to be replaced")
    }

    /// The offset field is validated as it is typed, as every offset field is
    /// (§10.1): a Return on an address that names no row beeps and keeps the
    /// popover up, and the red text says which field is wrong.
    func testAnInvalidOffsetRefusesTheReturnOutLoud() throws {
        var events: [String] = []
        var beeps = 0
        let controller = BookmarkEditPopoverController(
            row: 0x10, existingName: "ME region",
            onCommit: { events.append("commit:\($0):\($1)") }, onCancel: {})
        controller.loadViewIfNeeded()
        controller.beep = { beeps += 1 }

        controller.offsetField.stringValue = "0xZZ"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                     object: controller.offsetField))
        XCTAssertEqual(controller.offsetField.textColor, .systemRed)
        XCTAssertNil(controller.editedRow)

        controller.commit()
        XCTAssertEqual(events, [], "Return does nothing while the address names no row")
        XCTAssertEqual(beeps, 1)

        controller.offsetField.stringValue = "0x40"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                     object: controller.offsetField))
        XCTAssertEqual(controller.offsetField.textColor, .labelColor, "the red clears when it parses")
        controller.commit()
        XCTAssertEqual(events, ["commit:64:ME region"], "and it commits the row that was typed")
        XCTAssertEqual(beeps, 1, "a valid Return is silent")
    }

    /// Return saves outright, on the row the address field names — rounded down
    /// to the row it is in, which is what a bookmark marks (§20.1). ⌘D, Return
    /// stays two keystrokes.
    func testReturnSavesTheRowTheAddressIsIn() throws {
        var events: [String] = []
        let controller = BookmarkEditPopoverController(
            row: 0x10, existingName: nil,
            onCommit: { events.append("commit:\($0):\($1)") }, onCancel: {})
        controller.loadViewIfNeeded()
        controller.offsetField.stringValue = "0x3333"

        _ = controller.control(controller.nameField, textView: NSTextView(),
                               doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(events, ["commit:13104:"],
                       "0x3333 is in the row at 0x3330 — 13104")
    }

    /// One row holds one bookmark (§20.1), so an address another mark already
    /// holds is as invalid as a typo — and the mark's own row always is valid.
    func testAnOffsetAnotherBookmarkHoldsIsRefused() throws {
        let taken: Set<UInt64> = [0x40]
        let controller = BookmarkEditPopoverController(
            row: 0x10, existingName: nil,
            rowIsFree: { !taken.contains($0) },
            onCommit: { _, _ in }, onCancel: {})
        controller.loadViewIfNeeded()

        controller.offsetField.stringValue = "0x44"
        XCTAssertNil(controller.editedRow, "0x40's row is already marked")

        controller.offsetField.stringValue = "0x50"
        XCTAssertEqual(controller.editedRow, 0x50)

        controller.offsetField.stringValue = "0x1F"
        XCTAssertEqual(controller.editedRow, 0x10, "its own row is always available to it")
    }


    /// The pane view anchors the popover on the mark itself, and the mark's rect
    /// is the same one the right-click focus ring uses (§20.4).
    func testThePaneViewAnchorsThePopoverOnTheMark() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let store = BookmarkStore()
        pane.bookmarkStore = store
        store.add(rowContaining: 20, name: "ME region")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let paneView = try host(pane, in: window, right: false)
        let hex = try XCTUnwrap(paneView.scrollView.documentView as? HexView)

        let controller = paneView.presentBookmarkEditPopover(
            rowContaining: 20, existingName: "ME region", rowIsFree: { _ in true },
            onCommit: { _, _ in }, onCancel: {})
        XCTAssertEqual(controller.nameField.stringValue, "ME region",
                       "the popover is loaded and filled before it is shown")

        let layout = hex.hexLayout
        XCTAssertEqual(hex.bookmarkMarkRect(forRowContaining: 20),
                       layout.offsetColumnFrame(row: 1)
                           .insetBy(dx: -HexView.mirrorContourPadding, dy: 0),
                       "the popover points at the mark, not at the pane")
    }

    // MARK: - Naming: what the commands do (§20.3)

    /// A real window with a file open in pane 1 — the commands act on the active
    /// pane and hand the naming to its view. The returned closure closes the
    /// window and removes the file.
    private func makeControllerWithFile(bytes: Int = 48) throws -> (MainViewController, () -> Void) {
        let wc = MainWindowController()
        let controller = try XCTUnwrap(wc.mainViewController)
        let url = try tempFile([UInt8](repeating: 0x11, count: bytes))
        try controller.windowModel.pane1.open(url: url)
        wc.window?.layoutIfNeeded()
        return (controller, {
            wc.close()
            try? FileManager.default.removeItem(at: url)
        })
    }

    /// Captures the naming requests a command makes, instead of showing a
    /// popover: one anchored in a window that is never on screen closes the
    /// instant it opens, and what these tests are about is the commands.
    private func captureEditing(_ controller: MainViewController)
        -> () -> [MainViewController.BookmarkEditRequest] {
        var requests: [MainViewController.BookmarkEditRequest] = []
        controller.bookmarkEditPresenter = { request in
            requests.append(request)
            return {}      // dismissing a captured request needs no popover
        }
        return { requests }
    }

    /// ⌘D marks the caret's row and immediately asks for its name: the mark is
    /// already there (visible while the name is typed), and the popover's Return
    /// writes back whatever it was given — nothing (the mark stays unnamed), a
    /// name (trimmed by the store), or a different address (the mark moves there,
    /// before it was ever named). One path, `toggleBookmark` → the request's
    /// `commit`, walked with each of the three things a Return can carry.
    func testToggleMarksTheRowAsksForItsNameAndCommitsWhatWasTyped() throws {
        let (controller, close) = try makeControllerWithFile(bytes: 256)
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.toggleBookmark()
        XCTAssertEqual(store.bookmarks.map(\.row), [16], "the mark appears before the name")
        XCTAssertEqual(requests().count, 1)
        let request = try XCTUnwrap(requests().first)
        XCTAssertEqual(request.row, 16)
        XCTAssertNil(request.existingName, "a mark just made has no name to edit — and Esc removes it")
        XCTAssertTrue(request.pane === controller.windowModel.pane1)

        request.commit(request.row, "")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: "")],
                       "Return with nothing typed keeps the mark, unnamed")

        // ⌘D, a name, Return: the mark keeps what was typed, trimmed.
        controller.windowModel.pane1.moveCaret(to: 40)
        controller.toggleBookmark()
        XCTAssertEqual(requests().count, 2, "the second ⌘D asked for a name of its own")
        let named = try XCTUnwrap(requests().last)
        named.commit(named.row, "  ME region ")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: ""),
                                         Bookmark(row: 32, name: "ME region")],
                       "the typed name is stored trimmed, on the row ⌘D marked")

        // ⌘D, correct the address, Return: the new mark moves before it is named.
        controller.windowModel.pane1.moveCaret(to: 0x50)
        controller.toggleBookmark()
        try XCTUnwrap(requests().last).commit(0x80, "vendor block")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: ""),
                                         Bookmark(row: 32, name: "ME region"),
                                         Bookmark(row: 0x80, name: "vendor block")],
                       "the mark landed on the address that was typed, not on the caret's row")
    }

    /// Esc on a popover that opened by marking a row removes the mark again: the
    /// whole act is cancelled, not just the name.
    func testEscAfterMarkingRemovesTheMark() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.toggleBookmark()
        try XCTUnwrap(requests().first).cancel()
        XCTAssertTrue(store.bookmarks.isEmpty, "Esc undoes the marking too")
    }

    /// A second ⌘D on a marked row unmarks it on the spot — nothing is asked,
    /// because there is nothing to name.
    func testTogglingAMarkedRowRemovesItAndAsksNothing() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        controller.windowModel.pane1.moveCaret(to: 20)
        store.add(rowContaining: 20, name: "ME region")

        controller.toggleBookmark()
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertTrue(requests().isEmpty, "removing a mark asks nothing")
    }

    /// Committing a different address moves the bookmark there, name and all —
    /// the keyboard's version of dragging the mark (§20.6).
    func testEditingTheAddressMovesTheBookmark() throws {
        let (controller, close) = try makeControllerWithFile(bytes: 256)
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        controller.windowModel.pane1.moveCaret(to: 20)
        store.add(rowContaining: 20, name: "ME region")

        controller.editBookmark()
        try XCTUnwrap(requests().first).commit(0x60, "ME region")

        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x60, name: "ME region")],
                       "one bookmark, on the row that was typed, still named")
    }

    /// Delete belongs to an existing mark and to nothing else: editing one hands
    /// the popover a way to remove it, and pressing that takes the mark off the
    /// row. A mark that is still being named is offered none — its Esc already
    /// does that, and two ways to undo one half-finished act is one too many.
    func testOnlyAnExistingMarksEditOffersDeleteAndItRemovesTheMark() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        controller.windowModel.pane1.moveCaret(to: 20)
        store.add(rowContaining: 20, name: "ME region")

        controller.editBookmark()
        let request = try XCTUnwrap(requests().first)
        let delete = try XCTUnwrap(request.delete, "editing an existing mark can remove it")
        delete()

        XCTAssertTrue(store.bookmarks.isEmpty, "Delete took the mark off the row")

        // The row is bare again, so ⌘D makes a new mark — which is offered no
        // Delete at all.
        controller.toggleBookmark()
        XCTAssertEqual(requests().count, 2, "⌘D asked to name the new mark")
        XCTAssertNil(try XCTUnwrap(requests().last).delete,
                     "a mark still being named has no Delete: Esc is its way out")
    }

    /// ⇧⌘D edits through the same popover: it opens with the current name, and
    /// its Esc leaves that name alone — where Esc on a new mark removes it.
    func testRenameOpensWithTheCurrentNameAndEscKeepsIt() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        controller.windowModel.pane1.moveCaret(to: 20)
        store.add(rowContaining: 20, name: "ME region")

        controller.editBookmark()
        let first = try XCTUnwrap(requests().first)
        XCTAssertEqual(first.existingName, "ME region")
        first.commit(first.row, "descriptor")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: "descriptor")])

        controller.editBookmark()
        try XCTUnwrap(requests().last).cancel()
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: "descriptor")],
                       "Esc keeps the name the bookmark had")
    }

    /// ⇧⌘D on an unmarked row does nothing at all — there is no mark to rename,
    /// and it must not create one behind the user's back.
    func testRenameDoesNothingOnAnUnmarkedRow() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let requests = captureEditing(controller)
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.editBookmark()
        XCTAssertTrue(requests().isEmpty)
        XCTAssertTrue(controller.windowModel.bookmarkStore.bookmarks.isEmpty)
    }

    /// ⌘D always applies; ⇧⌘D only where there is a mark to rename (§20.3).
    func testRenameIsEnabledOnlyOnAMarkedRow() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let toggleItem = NSMenuItem(title: "Toggle Bookmark",
                                    action: #selector(MainViewController.toggleBookmark), keyEquivalent: "d")
        let renameItem = NSMenuItem(title: "Edit Bookmark…",
                                    action: #selector(MainViewController.editBookmark), keyEquivalent: "D")
        controller.windowModel.pane1.moveCaret(to: 20)

        XCTAssertTrue(controller.validateMenuItem(toggleItem), "a file is open")
        XCTAssertFalse(controller.validateMenuItem(renameItem), "nothing to rename yet")

        controller.windowModel.bookmarkStore.add(rowContaining: 20)
        XCTAssertTrue(controller.validateMenuItem(renameItem), "the caret's row carries a mark")

        controller.windowModel.pane1.moveCaret(to: 40)
        XCTAssertFalse(controller.validateMenuItem(renameItem),
                       "the caret moved off the marked row")
    }

    /// The Edit menu's two bookmark commands and their keys.
    func testEditMenuHasBothBookmarkCommands() throws {
        let items = MainWindowController().makeEditMenu().items
        let toggle = try XCTUnwrap(items.first { $0.action == #selector(MainViewController.toggleBookmark) })
        XCTAssertEqual(toggle.title, "Toggle Bookmark")
        XCTAssertEqual(toggle.keyEquivalent, "d")
        XCTAssertEqual(toggle.keyEquivalentModifierMask, [.command])

        let rename = try XCTUnwrap(items.first { $0.action == #selector(MainViewController.editBookmark) })
        XCTAssertEqual(rename.title, "Edit Bookmark…", "the ellipsis says a dialog follows")
        // An upper-case key equivalent is how AppKit spells ⇧ — the menu shows
        // ⇧⌘D and matches shift+D, with no `.shift` in the mask (as Save As…).
        XCTAssertEqual(rename.keyEquivalent, "D")
        XCTAssertEqual(rename.keyEquivalentModifierMask, [.command])
    }

    /// ⌘D reaches the menu through an open popover, so the row can be unmarked
    /// while its name is being typed. The popover must go with the mark: a panel
    /// naming a bookmark that no longer exists is nonsense.
    func testUnmarkingTheRowClosesItsNamingPopover() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        var dismissals = 0
        controller.bookmarkEditPresenter = { _ in { dismissals += 1 } }
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.toggleBookmark()
        XCTAssertEqual(controller.editingRow, 16, "the popover is open on the new mark")

        controller.toggleBookmark()      // ⌘D again: the mark goes
        XCTAssertTrue(controller.windowModel.bookmarkStore.bookmarks.isEmpty)
        XCTAssertEqual(dismissals, 1, "and the popover goes with it")
        XCTAssertNil(controller.editingRow)
    }

    /// A change to a DIFFERENT row leaves the popover alone — it is still naming
    /// a mark that exists.
    func testAChangeElsewhereLeavesThePopoverOpen() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        var dismissals = 0
        controller.bookmarkEditPresenter = { _ in { dismissals += 1 } }
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.toggleBookmark()
        controller.windowModel.bookmarkStore.add(rowContaining: 40, name: "elsewhere")
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(controller.editingRow, 16)
    }

    /// ⌘D on another row while a popover is open opens the new one and closes the
    /// old — two panels, one of them about a row the user has moved on from, is
    /// not a state to be in.
    func testMarkingAnotherRowReplacesTheOpenPopover() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        var dismissals = 0
        controller.bookmarkEditPresenter = { _ in { dismissals += 1 } }
        controller.windowModel.pane1.moveCaret(to: 20)
        controller.toggleBookmark()

        controller.windowModel.pane1.moveCaret(to: 40)
        controller.toggleBookmark()
        XCTAssertEqual(dismissals, 1, "the first popover was closed")
        XCTAssertEqual(controller.editingRow, 32, "and the second is open on its own row")
        XCTAssertEqual(controller.windowModel.bookmarkStore.bookmarks.map(\.row), [16, 32],
                       "both marks stand: the first one was named, not abandoned")
    }

    /// Abandoning is neither saving nor cancelling: the popover just goes.
    func testAbandonRunsNeitherCallback() throws {
        var events: [String] = []
        let controller = BookmarkEditPopoverController(
            row: 0x10, existingName: nil,
            onCommit: { events.append("commit:\($0):\($1)") },
            onCancel: { events.append("cancel") }
        )
        controller.loadViewIfNeeded()
        controller.nameField.stringValue = "half typed"
        controller.abandon()
        XCTAssertEqual(events, [], "nothing to name, nothing to take back")
        controller.commit()
        XCTAssertEqual(events, [], "and it has settled: a later Return does nothing")
    }

    // MARK: - Marking with the mouse (§20.3)

    /// A double click on an address marks that row and names it, like ⌘D.
    func testDoubleClickingAnAddressMarksItsRow() throws {
        let (controller, close) = try makeControllerWithFile(bytes: 64)
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        let pane = controller.windowModel.pane1

        controller.handleOffsetDoubleClick(in: pane, rowContaining: 0x2A)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x20], "the clicked row is marked")
        let request = try XCTUnwrap(requests().first, "and named in the same popover as ⌘D's")
        XCTAssertEqual(request.row, 0x20)
        XCTAssertNil(request.existingName, "Esc takes the new mark away again")
        request.commit(request.row, "vendor block")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x20, name: "vendor block")])
    }

    /// A double click ON a mark opens it for editing — the same popover ⇧⌘D
    /// opens, with the current name — and never unmarks: the pointer covers the
    /// mark it is aimed at, so a toggle here would take an existing bookmark away
    /// on a near miss.
    func testDoubleClickingAMarkedRowOpensItForEditing() throws {
        let (controller, close) = try makeControllerWithFile(bytes: 64)
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)
        store.add(rowContaining: 0x20, name: "ME region")

        controller.handleOffsetDoubleClick(in: controller.windowModel.pane1, rowContaining: 0x2A)

        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x20, name: "ME region")],
                       "the mark and its name survive the click itself")
        let request = try XCTUnwrap(requests().first, "the mark opens for editing")
        XCTAssertEqual(request.row, 0x20)
        XCTAssertEqual(request.existingName, "ME region",
                       "an existing mark is edited, not re-made — Esc keeps it")

        request.commit(0x30, "ME region")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x30, name: "ME region")],
                       "and the popover can move it, as ⇧⌘D's can")
    }

    /// The gesture belongs to the Offset column: a double click on a byte, or on
    /// the decoded text, is not a marking gesture — those columns select.
    func testOnlyTheOffsetColumnMarksOnDoubleClick() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let paneView = try host(pane, in: window, right: false)
        let hex = try XCTUnwrap(paneView.scrollView.documentView as? HexView)
        var marked: [UInt64] = []
        paneView.onOffsetDoubleClick = { marked.append($0) }

        let layout = hex.hexLayout
        func click(at local: CGPoint, count: Int) {
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: hex.convert(local, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            hex.mouseDown(with: event)
        }

        click(at: CGPoint(x: layout.offsetColumnFrame(row: 2).midX,
                          y: layout.rowFrame(row: 2).midY), count: 1)
        XCTAssertTrue(marked.isEmpty, "one click places the caret, as before")

        click(at: CGPoint(x: layout.offsetColumnFrame(row: 2).midX,
                          y: layout.rowFrame(row: 2).midY), count: 2)
        XCTAssertEqual(marked, [0x20], "a double click on the address marks its row")

        click(at: CGPoint(x: layout.hexByteFrame(row: 1, column: 3).midX,
                          y: layout.rowFrame(row: 1).midY), count: 2)
        XCTAssertEqual(marked, [0x20], "a double click on a byte is not a marking gesture")
    }

    // MARK: - Naming: the context menu (§20.3)

    /// The offset menu carries ONE item for marking and unmarking — the same
    /// command ⌘D is — plus Rename on a row that has something to rename. The
    /// address is the ROW's: a right-click on a byte marks that byte's row, and
    /// the title is what says so (§20.1).
    func testTheContextMenuTogglesAndRenames() throws {
        let (controller, close) = try makeControllerWithFile(bytes: 64)
        defer { close() }
        let pane = controller.windowModel.pane1

        // A byte in the middle of row 0x10, so the row address has to be derived.
        let unmarked = controller.makeOffsetMenu(for: pane, offset: 0x1B).items.map(\.title)
        XCTAssertTrue(unmarked.contains("Toggle Bookmark at 0x00000010"),
                      "the row's address, not the clicked byte's: \(unmarked)")
        XCTAssertFalse(unmarked.contains("Edit Bookmark…"),
                       "nothing to rename on an unmarked row")

        controller.windowModel.bookmarkStore.add(rowContaining: 0x1B, name: "ME region")
        let marked = controller.makeOffsetMenu(for: pane, offset: 0x1B).items.map(\.title)
        XCTAssertTrue(marked.contains("Toggle Bookmark at 0x00000010"), "\(marked)")
        XCTAssertTrue(marked.contains("Edit Bookmark…"))
    }

    /// The items act on the row that was right-clicked, in the pane that was
    /// right-clicked — the `representedObject` pattern the rest of the offset
    /// menu uses (§10.2). Toggling from the menu asks for the name the same way
    /// ⌘D does.
    func testTheContextMenuItemsActOnTheClickedRow() throws {
        let (controller, close) = try makeControllerWithFile(bytes: 64)
        defer { close() }
        let pane = controller.windowModel.pane1
        let store = controller.windowModel.bookmarkStore
        let requests = captureEditing(controller)

        let toggleItem = try XCTUnwrap(controller.makeOffsetMenu(for: pane, offset: 0x2A).items
            .first { $0.action == #selector(MainViewController.toggleBookmarkAtOffset(_:)) })
        XCTAssertTrue(toggleItem.target === controller)
        controller.toggleBookmarkAtOffset(toggleItem)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x20], "the clicked byte's row is marked")

        let request = try XCTUnwrap(requests().first, "the menu's toggle names the mark it makes")
        XCTAssertEqual(request.row, 0x20)
        request.commit(request.row, "vendor block")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x20, name: "vendor block")])

        // And the same item takes it away again, with nothing to dismiss.
        controller.toggleBookmarkAtOffset(toggleItem)
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertEqual(requests().count, 1, "removing asks nothing")
    }

    // MARK: - Where a name shows (§20.2)

    /// Hovering a marked row's address shows what the bookmark is called — and
    /// only that. A row with no mark, and a mark with no name, show nothing: the
    /// address is already drawn under the pointer, so a tooltip repeating it
    /// would explain a thing to itself.
    func testTheMarkShowsItsNameAsATooltip() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let store = BookmarkStore()
        pane.bookmarkStore = store

        let hex = HexView()
        hex.dataSource = pane
        hex.delegate = pane
        hex.reloadData()

        let layout = hex.hexLayout
        func tooltip(row: Int) -> String {
            let point = NSPoint(x: layout.offsetColumnFrame(row: row).midX,
                                y: layout.rowFrame(row: row).midY)
            return hex.view(hex, stringForToolTip: 0, point: point, userData: nil)
        }

        XCTAssertNotNil(hex.bookmarkTooltipTag,
                        "the Offset column is registered for tooltips, or none of this is asked")
        XCTAssertEqual(tooltip(row: 1), "", "an unmarked row has nothing to say")
        store.add(rowContaining: 16, name: "ME region")
        XCTAssertEqual(tooltip(row: 1), "ME region")
        XCTAssertEqual(tooltip(row: 2), "", "the name belongs to its own row")
        store.rename(rowContaining: 16, to: "")
        XCTAssertEqual(tooltip(row: 1), "",
                       "an unnamed mark has nothing to add to the address it is drawn on")
    }

    /// The mark is otherwise purely visual, so the pane's accessibility value is
    /// the only place VoiceOver learns of it: whether the caret's row carries one
    /// at all, and what it is called (§15, §20.4).
    func testAccessibilityValueSaysWhetherTheCaretsRowIsMarkedAndWhatItIsCalled() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let store = BookmarkStore()
        pane.bookmarkStore = store
        let hex = HexView()
        hex.dataSource = pane
        hex.delegate = pane
        hex.reloadData()
        pane.moveCaret(to: 20)

        let plain = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertFalse(plain.contains("Bookmarked"), "an unmarked row says nothing about bookmarks")

        store.add(rowContaining: 20, name: "ME region")
        let value = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("Bookmarked row: ME region."), value)

        store.rename(rowContaining: 20, to: "")
        let unnamed = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertTrue(unnamed.contains("Bookmarked row: 0x00000010."), unnamed)

        pane.moveCaret(to: 40)      // row 32, unmarked
        let elsewhere = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertFalse(elsewhere.contains("Bookmarked"), "the mark belongs to its own row")
    }
}

private extension BookmarkEditPopoverController {
    /// The static text the popover shows — its title line and its key hint — so
    /// a test can read what it tells the user without knowing the view's shape.
    var labelTexts: [String] {
        func labels(in view: NSView) -> [String] {
            let own = (view as? NSTextField).flatMap { $0.isEditable ? nil : $0.stringValue }
            return (own.map { [$0] } ?? []) + view.subviews.flatMap(labels(in:))
        }
        return labels(in: view)
    }

    /// The buttons the popover shows — none: Return and Esc are the whole
    /// interface, so a stray OK/Cancel row would be a regression.
    var buttons: [NSButton] {
        func found(in view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(found(in:))
        }
        return found(in: view)
    }
}
