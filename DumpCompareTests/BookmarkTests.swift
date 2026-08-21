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
/// Stage 2 — "Give it a name": ⇧⌘D and the offset context menu's add / name /
/// rename / remove items, what the store does with a name, and the two places a
/// name shows before the list exists — the mark's tooltip and VoiceOver.
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

    // MARK: - Names: the sheet (§20.2)

    /// The name sheet reports what was typed, trimmed by the store on the way in.
    /// Its title tells adding from renaming, and a rename opens with the current
    /// name in the field, ready to be replaced.
    func testTheNameSheetSubmitsWhatWasTyped() {
        var captured: String?
        let adding = BookmarkNameSheetController(row: 0x10, existingName: nil) { captured = $0 }
        _ = adding.view
        XCTAssertEqual(adding.titleText, "Add Bookmark")
        XCTAssertEqual(adding.nameField.stringValue, "", "a new bookmark opens with an empty field")
        XCTAssertTrue(try! XCTUnwrap(adding.messageText).contains("0x00000010"),
                      "the sheet says which row it is naming")
        adding.nameField.stringValue = "boot block"
        // `handleSubmit` is the submit path minus `dismiss`, which needs a real
        // presentation (the pattern SelectBlockSheetTests uses).
        adding.handleSubmit()
        XCTAssertEqual(captured, "boot block")

        let renaming = BookmarkNameSheetController(row: 0x10, existingName: "boot block") { captured = $0 }
        _ = renaming.view
        XCTAssertEqual(renaming.titleText, "Rename Bookmark")
        XCTAssertEqual(renaming.nameField.stringValue, "boot block",
                       "a rename opens with the name it is changing")
        renaming.nameField.stringValue = ""
        renaming.handleSubmit()
        XCTAssertEqual(captured, "", "an empty name is allowed: the bookmark shows its address")
    }

    /// The name field selects its whole text on focus — the initial value is a
    /// suggestion to replace, unlike an offset field's "0x" prefix, which the
    /// caret must land after (§10, §20.2).
    func testTheNameFieldSelectsItsTextOnFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let sheet = BookmarkNameSheetController(row: 0x10, existingName: "boot block") { _ in }
        window.contentView = sheet.view
        window.makeFirstResponder(sheet.nameField)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 10),
                       "typing replaces the suggested name")
    }

    /// ⇧⌘D names the caret's row: Edit ▸ Name Bookmark…, enabled with a file open.
    func testEditMenuHasNameBookmarkWithShiftCmdD() throws {
        let item = try XCTUnwrap(MainWindowController().makeEditMenu().items
            .first { $0.action == #selector(MainViewController.nameBookmark) })
        XCTAssertEqual(item.title, "Name Bookmark…", "the ellipsis says a dialog follows")
        // An upper-case key equivalent is how AppKit spells ⇧ — the menu shows
        // ⇧⌘D and matches shift+D, with no `.shift` in the mask (as Save As…).
        XCTAssertEqual(item.keyEquivalent, "D")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    }

    func testNameBookmarkEnabledOnlyWithAFileOpen() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let item = NSMenuItem(title: "Name Bookmark…",
                              action: #selector(MainViewController.nameBookmark), keyEquivalent: "D")
        XCTAssertFalse(controller.validateMenuItem(item), "no file open → disabled")
        let url = try tempFile([UInt8](repeating: 0x00, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    // MARK: - Names: the context menu (§20.3)

    /// The offset context menu offers what the clicked row does not have yet: an
    /// unmarked row gets Add and Add with Name…, a marked one Rename… and Remove.
    /// The address in the title is the ROW's — right-clicking a byte marks its
    /// row, and the title is what says so (§20.1).
    func testTheContextMenuOffersTheRightBookmarkItems() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let url = try tempFile([UInt8](repeating: 0x11, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = controller.windowModel.pane1
        try pane.open(url: url)

        // A byte in the middle of row 0x10, so the row address has to be derived.
        let unmarked = controller.makeOffsetMenu(for: pane, offset: 0x1B).items.map(\.title)
        XCTAssertTrue(unmarked.contains("Add Bookmark at 0x00000010"),
                      "the row's address, not the clicked byte's: \(unmarked)")
        XCTAssertTrue(unmarked.contains("Add Bookmark with Name…"))
        XCTAssertFalse(unmarked.contains("Remove Bookmark"))

        controller.windowModel.bookmarkStore.add(rowContaining: 0x1B, name: "ME region")
        let marked = controller.makeOffsetMenu(for: pane, offset: 0x1B).items.map(\.title)
        XCTAssertTrue(marked.contains("Rename Bookmark at 0x00000010…"), "\(marked)")
        XCTAssertTrue(marked.contains("Remove Bookmark"))
        XCTAssertFalse(marked.contains("Add Bookmark at 0x00000010"),
                       "a marked row is not offered a second mark")
    }

    /// The items act on the row that was right-clicked, in the pane that was
    /// right-clicked — the `representedObject` pattern the rest of the offset
    /// menu uses (§10.2). Add and Remove need no dialog, so they are driven here
    /// end to end.
    func testTheContextMenuItemsActOnTheClickedRow() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let url = try tempFile([UInt8](repeating: 0x11, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = controller.windowModel.pane1
        try pane.open(url: url)
        let store = controller.windowModel.bookmarkStore

        let addItem = try XCTUnwrap(controller.makeOffsetMenu(for: pane, offset: 0x2A).items
            .first { $0.action == #selector(MainViewController.addBookmarkAtOffset(_:)) })
        XCTAssertTrue(addItem.target === controller)
        controller.addBookmarkAtOffset(addItem)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x20], "the clicked byte's row is marked")

        let removeItem = try XCTUnwrap(controller.makeOffsetMenu(for: pane, offset: 0x2A).items
            .first { $0.action == #selector(MainViewController.removeBookmarkAtOffset(_:)) })
        controller.removeBookmarkAtOffset(removeItem)
        XCTAssertTrue(store.bookmarks.isEmpty)
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
