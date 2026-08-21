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
        // The stroke's left edge: the padded rect's own minX, ± half the line width.
        let leftEdge = NSRect(x: columnFrame.minX - HexView.mirrorContourPadding - 1,
                             y: rowFrame.midY - 2, width: 3, height: 4)
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

    /// The mark is otherwise purely visual, so the pane's accessibility value
    /// says whether the caret's row carries one (§15, §20.4).
    func testAccessibilityValueSaysWhetherTheCaretsRowIsBookmarked() throws {
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

        store.toggle(rowContaining: 20)
        let marked = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertTrue(marked.contains("Bookmarked row"), "a marked row says so: \(marked)")

        pane.moveCaret(to: 40)      // row 32, unmarked
        let elsewhere = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertFalse(elsewhere.contains("Bookmarked"), "the mark belongs to its own row")
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

    /// ⌘D's own link: the command marks the row containing the active pane's
    /// caret in the window's shared store, and marks it again to remove (§20.3).
    func testToggleBookmarkMarksTheActivePanesCaretRow() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let url = try tempFile([UInt8](repeating: 0x00, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.toggleBookmark()
        XCTAssertEqual(controller.windowModel.bookmarkStore.bookmarks.map(\.row), [16],
                       "the command marks the caret's row in the window's shared store")
        controller.toggleBookmark()
        XCTAssertTrue(controller.windowModel.bookmarkStore.bookmarks.isEmpty,
                      "the same command removes it")
    }

    // MARK: - Menu

    /// The Edit menu carries "Toggle Bookmark" wired to the controller's
    /// `toggleBookmark`, bound to ⌘D — the gesture that has to cost nothing on a
    /// bench (§20). The title says Toggle because the one command both marks and
    /// unmarks, whatever the caret's row currently is (§20.3).
    func testEditMenuHasToggleBookmarkWithCmdD() {
        let item = MainWindowController().makeEditMenu().items.first { $0.title == "Toggle Bookmark" }
        XCTAssertNotNil(item, "the Edit menu should offer Toggle Bookmark")
        XCTAssertEqual(item?.action, #selector(MainViewController.toggleBookmark))
        XCTAssertEqual(item?.keyEquivalent, "d")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command])
    }

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

    // MARK: - Naming: the popover itself (§20.3)

    /// The popover's own contract: Return saves what was typed, Esc backs out,
    /// and a dismissal by any other means (a click outside it) keeps what was
    /// typed — the mark is already on the row by then.
    func testThePopoverReportsReturnEscAndDismissal() throws {
        func popover(existing: String?) -> (BookmarkNamePopoverController, () -> [String]) {
            var events: [String] = []
            let controller = BookmarkNamePopoverController(
                row: 0x10, existingName: existing,
                onCommit: { events.append("commit:\($0)") },
                onCancel: { events.append("cancel") }
            )
            controller.loadViewIfNeeded()
            return (controller, { events })
        }

        let (returning, returnEvents) = popover(existing: nil)
        returning.nameField.stringValue = "ME region"
        returning.commit()
        XCTAssertEqual(returnEvents(), ["commit:ME region"])

        let (escaping, escEvents) = popover(existing: nil)
        escaping.nameField.stringValue = "abandoned"
        escaping.cancel()
        XCTAssertEqual(escEvents(), ["cancel"], "Esc drops the name AND the mark")

        let (clickedAway, clickEvents) = popover(existing: "old")
        clickedAway.nameField.stringValue = "new"
        clickedAway.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(clickEvents(), ["commit:new"],
                       "a click outside keeps the typed name")
    }

    /// Only the first outcome counts: the close that follows a Return or an Esc
    /// must not commit a second time.
    func testThePopoverSettlesOnce() throws {
        var events: [String] = []
        let controller = BookmarkNamePopoverController(
            row: 0x10, existingName: nil,
            onCommit: { events.append("commit:\($0)") },
            onCancel: { events.append("cancel") }
        )
        controller.loadViewIfNeeded()
        controller.cancel()
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        controller.commit()
        XCTAssertEqual(events, ["cancel"])
    }

    /// It opens ready for the keyboard: an empty field for a new mark and the
    /// current name for a rename, with the row's address in the title — which is
    /// what an unnamed bookmark will be called. And nothing else: two lines, no
    /// buttons, no explanation of Return and Esc.
    func testThePopoverOpensForTheRightJob() throws {
        let creating = BookmarkNamePopoverController(row: 0x10, existingName: nil,
                                                    onCommit: { _ in }, onCancel: {})
        creating.loadViewIfNeeded()
        XCTAssertEqual(creating.nameField.stringValue, "")
        XCTAssertEqual(creating.nameField.placeholderString, "Name",
                       "the placeholder is the field's label, so there is no label")
        XCTAssertEqual(creating.labelTexts, ["Bookmark at 0x00000010"],
                       "one line of text: which row this is")
        XCTAssertTrue(creating.buttons.isEmpty, "the keyboard finishes the job")
        // The field spans the popover, so a long name has all the room there is.
        creating.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(creating.nameField.frame.width, creating.view.frame.width - 32,
                       accuracy: 0.5, "the field runs the popover's width, inside its insets")

        let renaming = BookmarkNamePopoverController(row: 0x10, existingName: "ME region",
                                                    onCommit: { _ in }, onCancel: {})
        renaming.loadViewIfNeeded()
        XCTAssertEqual(renaming.nameField.stringValue, "ME region")
        XCTAssertEqual(renaming.labelTexts, ["Bookmark at 0x00000010"])
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

        let controller = paneView.presentBookmarkNamePopover(
            rowContaining: 20, existingName: "ME region", onCommit: { _ in }, onCancel: {})
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
    private func captureNaming(_ controller: MainViewController)
        -> () -> [MainViewController.BookmarkNamingRequest] {
        var requests: [MainViewController.BookmarkNamingRequest] = []
        controller.bookmarkNamingPresenter = { requests.append($0) }
        return { requests }
    }

    /// ⌘D marks the caret's row and immediately asks for its name: the mark is
    /// already there (visible while the name is typed), and Return with nothing
    /// typed leaves it unnamed — the ⌘D, Return gesture.
    func testToggleMarksTheRowAndAsksForItsName() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureNaming(controller)
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.toggleBookmark()
        XCTAssertEqual(store.bookmarks.map(\.row), [16], "the mark appears before the name")
        XCTAssertEqual(requests().count, 1)
        let request = try XCTUnwrap(requests().first)
        XCTAssertEqual(request.row, 16)
        XCTAssertNil(request.existingName, "a mark just made has no name to edit — and Esc removes it")
        XCTAssertTrue(request.pane === controller.windowModel.pane1)

        request.commit("")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: "")],
                       "Return with nothing typed keeps the mark, unnamed")
    }

    /// ⌘D, a name, Return: the mark keeps what was typed, trimmed by the store.
    func testCommittingANameNamesTheMark() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureNaming(controller)
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.toggleBookmark()
        try XCTUnwrap(requests().first).commit("  ME region ")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: "ME region")])
    }

    /// Esc on a popover that opened by marking a row removes the mark again: the
    /// whole act is cancelled, not just the name.
    func testEscAfterMarkingRemovesTheMark() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureNaming(controller)
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
        let requests = captureNaming(controller)
        controller.windowModel.pane1.moveCaret(to: 20)
        store.add(rowContaining: 20, name: "ME region")

        controller.toggleBookmark()
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertTrue(requests().isEmpty, "removing a mark asks nothing")
    }

    /// ⇧⌘D renames through the same popover: it opens with the current name, and
    /// its Esc leaves that name alone — where Esc on a new mark removes it.
    func testRenameOpensWithTheCurrentNameAndEscKeepsIt() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let store = controller.windowModel.bookmarkStore
        let requests = captureNaming(controller)
        controller.windowModel.pane1.moveCaret(to: 20)
        store.add(rowContaining: 20, name: "ME region")

        controller.renameBookmark()
        let first = try XCTUnwrap(requests().first)
        XCTAssertEqual(first.existingName, "ME region")
        first.commit("descriptor")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: "descriptor")])

        controller.renameBookmark()
        try XCTUnwrap(requests().last).cancel()
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 16, name: "descriptor")],
                       "Esc keeps the name the bookmark had")
    }

    /// ⇧⌘D on an unmarked row does nothing at all — there is no mark to rename,
    /// and it must not create one behind the user's back.
    func testRenameDoesNothingOnAnUnmarkedRow() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let requests = captureNaming(controller)
        controller.windowModel.pane1.moveCaret(to: 20)

        controller.renameBookmark()
        XCTAssertTrue(requests().isEmpty)
        XCTAssertTrue(controller.windowModel.bookmarkStore.bookmarks.isEmpty)
    }

    /// ⌘D always applies; ⇧⌘D only where there is a mark to rename (§20.3).
    func testRenameIsEnabledOnlyOnAMarkedRow() throws {
        let (controller, close) = try makeControllerWithFile()
        defer { close() }
        let toggleItem = NSMenuItem(title: "Toggle Bookmark",
                                    action: #selector(MainViewController.toggleBookmark), keyEquivalent: "d")
        let renameItem = NSMenuItem(title: "Rename Bookmark…",
                                    action: #selector(MainViewController.renameBookmark), keyEquivalent: "D")
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

        let rename = try XCTUnwrap(items.first { $0.action == #selector(MainViewController.renameBookmark) })
        XCTAssertEqual(rename.title, "Rename Bookmark…", "the ellipsis says a dialog follows")
        // An upper-case key equivalent is how AppKit spells ⇧ — the menu shows
        // ⇧⌘D and matches shift+D, with no `.shift` in the mask (as Save As…).
        XCTAssertEqual(rename.keyEquivalent, "D")
        XCTAssertEqual(rename.keyEquivalentModifierMask, [.command])
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
        XCTAssertFalse(unmarked.contains("Rename Bookmark…"),
                       "nothing to rename on an unmarked row")

        controller.windowModel.bookmarkStore.add(rowContaining: 0x1B, name: "ME region")
        let marked = controller.makeOffsetMenu(for: pane, offset: 0x1B).items.map(\.title)
        XCTAssertTrue(marked.contains("Toggle Bookmark at 0x00000010"), "\(marked)")
        XCTAssertTrue(marked.contains("Rename Bookmark…"))
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
        let requests = captureNaming(controller)

        let toggleItem = try XCTUnwrap(controller.makeOffsetMenu(for: pane, offset: 0x2A).items
            .first { $0.action == #selector(MainViewController.toggleBookmarkAtOffset(_:)) })
        XCTAssertTrue(toggleItem.target === controller)
        controller.toggleBookmarkAtOffset(toggleItem)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x20], "the clicked byte's row is marked")

        let request = try XCTUnwrap(requests().first, "the menu's toggle names the mark it makes")
        XCTAssertEqual(request.row, 0x20)
        request.commit("vendor block")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x20, name: "vendor block")])

        // And the same item takes it away again, with nothing to dismiss.
        controller.toggleBookmarkAtOffset(toggleItem)
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertEqual(requests().count, 1, "removing asks nothing")
    }

    // MARK: - Where a name shows (§20.2)

    /// Hovering a marked row's address shows what the bookmark is called;
    /// unmarked rows show nothing, because an address needs no explaining. This
    /// is the only place in the dump a name is visible before the list exists.
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
        XCTAssertEqual(tooltip(row: 1), "0x00000010",
                       "an unnamed mark is called by where it is")
    }

    /// VoiceOver reads the name too, not just that the row is marked (§15).
    func testAccessibilityValueCarriesTheName() throws {
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

        store.add(rowContaining: 20, name: "ME region")
        let value = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("Bookmarked row: ME region."), value)

        store.rename(rowContaining: 20, to: "")
        let unnamed = try XCTUnwrap(hex.accessibilityValue() as? String)
        XCTAssertTrue(unnamed.contains("Bookmarked row: 0x00000010."), unnamed)
    }
}

private extension BookmarkNamePopoverController {
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
