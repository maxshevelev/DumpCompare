import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §20.6 — moving a mark with the mouse: press and hold on a mark, drag, and the
/// bookmark follows the pointer row by row, autoscrolling past the visible edge
/// the way a drag selection does. One row holds one bookmark, so a mark dragged
/// onto a marked row jumps over it, and stops where it is when there is nowhere
/// left to jump.
@MainActor
final class BookmarkDragTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    // MARK: - The store's rule (§20.1: one bookmark per row)

    private func store(_ rows: [UInt64]) -> BookmarkStore {
        let store = BookmarkStore()
        for row in rows { store.add(rowContaining: row) }
        return store
    }

    func testAMoveCarriesTheNameAndReportsWhereItLanded() {
        let store = BookmarkStore()
        store.add(rowContaining: 0x10, name: "EC table")
        var changed: [UInt64] = []
        store.onChange = { changed.append($0) }

        let landed = store.move(rowContaining: 0x10, to: 0x40, lastRow: 0x100)

        XCTAssertEqual(landed, 0x40)
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x40, name: "EC table")],
                       "the mark moved and kept its name")
        XCTAssertEqual(changed, [0x10, 0x40],
                       "both rows repaint: the one it left and the one it landed on")
    }

    /// An offset inside a row moves the row's mark: the drag reports whatever
    /// offset the pointer is over (§20.1).
    func testAMoveSnapsToTheTargetRow() {
        let store = self.store([0])

        XCTAssertEqual(store.move(rowContaining: 0x8, to: 0x4B, lastRow: 0x100), 0x40)
    }

    /// Dragging down onto a marked row jumps past it — a mark sliding by
    /// another, never two marks merging into one row.
    func testAMarkedRowIsJumpedOverGoingDown() {
        let store = self.store([0x00, 0x20])

        XCTAssertEqual(store.move(rowContaining: 0x00, to: 0x20, lastRow: 0x100), 0x30)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x20, 0x30])
    }

    func testARunOfMarkedRowsIsJumpedOverWhole() {
        let store = self.store([0x00, 0x20, 0x30, 0x40])

        XCTAssertEqual(store.move(rowContaining: 0x00, to: 0x20, lastRow: 0x100), 0x50,
                       "the first free row past the block")
    }

    func testAMarkedRowIsJumpedOverGoingUp() {
        let store = self.store([0x10, 0x40])

        XCTAssertEqual(store.move(rowContaining: 0x40, to: 0x10, lastRow: 0x100), 0x00)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x00, 0x10],
                       "0x10 is taken, so the mark carries on up to the free row past it")
    }

    /// With the rows past the obstacle occupied to the end of the file there is
    /// nowhere to jump, so the mark stops just before it — as far as the pointer
    /// took it. It may neither leave the file to find room nor swallow the
    /// bookmark in its way.
    func testAMarkWithNoRoomBeyondStopsBeforeTheObstacle() {
        let store = self.store([0x00, 0x20, 0x30])

        XCTAssertEqual(store.move(rowContaining: 0x00, to: 0x20, lastRow: 0x30), 0x10)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x10, 0x20, 0x30])
    }

    /// The same going up: 0x00 is the wall, so a mark dragged onto the marked
    /// 0x10 stops on the free row before it.
    func testAMarkStopsBeforeTheObstacleGoingUp() {
        let store = self.store([0x00, 0x10, 0x30])

        XCTAssertEqual(store.move(rowContaining: 0x30, to: 0x10, lastRow: 0x100), 0x20)
        XCTAssertEqual(store.bookmarks.map(\.row), [0x00, 0x10, 0x20])
    }

    /// Nothing moves only when the obstacle leaves no room at all: 0x10 is taken,
    /// 0x00 above it is taken, and there is no row between 0x10 and the mark's own
    /// 0x20 to stop on.
    func testAMarkWithNoRoomEitherSideStaysPut() {
        let store = self.store([0x00, 0x10, 0x20])

        XCTAssertNil(store.move(rowContaining: 0x20, to: 0x10, lastRow: 0x100))
        XCTAssertEqual(store.bookmarks.map(\.row), [0x00, 0x10, 0x20])
    }

    /// The last row a mark may reach is the last row the pane draws (§9).
    func testATargetPastTheLastRowIsClamped() {
        let store = self.store([0x00])

        XCTAssertEqual(store.move(rowContaining: 0x00, to: 0x9000, lastRow: 0x70), 0x70)
    }

    func testMovingNothingAndMovingNowhereBothReportNothing() {
        let store = self.store([0x20])

        XCTAssertNil(store.move(rowContaining: 0x00, to: 0x40, lastRow: 0x100),
                     "row 0 carries no mark")
        XCTAssertNil(store.move(rowContaining: 0x20, to: 0x2F, lastRow: 0x100),
                     "0x2F is the same row the mark is already on")
    }

    // MARK: - The gesture

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    /// A pane hosting a real hex view in a real window, with a bookmark store
    /// wired the way `WindowViewModel` wires one.
    private func makePane(byteCount: Int = 4096)
        throws -> (pane: PaneViewModel, hexView: HexView, window: NSWindow, store: BookmarkStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmdrag-\(UUID().uuidString).bin")
        try Data([UInt8](repeating: 0x11, count: byteCount)).write(to: url)
        tempFiles.append(url)

        let pane = PaneViewModel()
        let store = BookmarkStore()
        pane.bookmarkStore = store
        store.onChange = { [weak pane] row in pane?.onBookmarksChanged?(row) }
        try pane.open(url: url)

        let filePane = FilePaneView(viewModel: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        filePane.translatesAutoresizingMaskIntoConstraints = false
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(filePane)
        NSLayoutConstraint.activate([
            filePane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filePane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filePane.topAnchor.constraint(equalTo: content.topAnchor),
            filePane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.layoutIfNeeded()
        let hexView = try XCTUnwrap(filePane.scrollView.documentView as? HexView)
        addTeardownBlock { @MainActor in
            pane.close()
            window.orderOut(nil)
        }
        return (pane, hexView, window, store)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Window point over the address of `row` — where its mark is drawn (§20.4).
    private func addressPoint(_ hexView: HexView, row: Int) -> NSPoint {
        let frame = hexView.hexLayout.offsetColumnFrame(row: row)
        return hexView.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    /// Window point over a hex byte of `row`, for the drags that must NOT move a
    /// mark.
    private func bytePoint(_ hexView: HexView, row: Int, column: Int = 0) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth,
                            y: CGFloat(row) * layout.rowHeight + layout.rowHeight / 2)
        return hexView.convert(local, to: nil)
    }

    func testDraggingAMarkMovesTheBookmark() throws {
        let (pane, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x20, name: "EC table")

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 2), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: 5), window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 5), window: window))

        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x50, name: "EC table")])
        XCTAssertTrue(pane.hexSelection().isEmpty,
                      "moving a mark is not selecting: the press left a caret, the drag left it alone")
    }

    /// The mark follows the pointer through every row it crosses, so a drag past
    /// several rows ends where the pointer is rather than one row along.
    func testAMarkFollowsThePointerAcrossSeveralSteps() throws {
        let (_, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x00)

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        for row in 1...4 {
            hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: row), window: window))
            XCTAssertEqual(store.bookmarks.map(\.row), [UInt64(row) * 16],
                           "the mark is on the row under the pointer")
        }
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 4), window: window))
    }

    /// End to end: the store's jump rule is what the gesture feels like.
    func testDraggingOntoAMarkedRowJumpsPastIt() throws {
        let (_, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x00, name: "moving")
        store.add(rowContaining: 0x10, name: "in the way")

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: 1), window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 1), window: window))

        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x10, name: "in the way"),
                                         Bookmark(row: 0x20, name: "moving")],
                       "the dragged mark stepped over the one in its way")
    }

    /// A press on an address that carries NO mark is the drag selection it has
    /// always been — the gesture belongs to the mark, not to the column.
    func testDraggingAnUnmarkedAddressStillSelects() throws {
        let (pane, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x200)

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: bytePoint(hexView, row: 3), window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: bytePoint(hexView, row: 3), window: window))

        XCTAssertEqual(store.bookmarks.map(\.row), [0x200], "no bookmark moved")
        XCTAssertFalse(pane.hexSelection().isEmpty, "the drag selected bytes")
    }

    /// The gesture ends with the mouse: a later drag with the button up must not
    /// still be carrying the mark.
    func testAMarkIsReleasedOnMouseUp() throws {
        let (_, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x00)

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: 1), window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 1), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: 9), window: window))

        XCTAssertEqual(store.bookmarks.map(\.row), [0x10], "the mark stayed where it was dropped")
    }

    /// §20.6: a mark dragged past the bottom edge scrolls the pane, and the
    /// autoscroll timer's ticks keep MOVING THE MARK rather than extending a
    /// selection — which is what lets a mark be dragged somewhere off screen.
    func testDraggingAMarkPastTheBottomEdgeScrollsAndKeepsMovingIt() throws {
        let (pane, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x00, name: "travelling")
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        let visibleHeight = clip.bounds.height
        XCTAssertGreaterThan(hexView.hexContentHeight, visibleHeight,
                             "the file must overflow the viewport")

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        let below = hexView.convert(CGPoint(x: hexView.hexLayout.offsetColumnFrame(row: 0).midX,
                                            y: visibleHeight + 100), to: nil)
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: below, window: window))
        let afterFirstStep = try XCTUnwrap(store.bookmarks.first).row
        for _ in 0..<10 { hexView.performDragAutoscrollTick() }
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: below, window: window))

        XCTAssertGreaterThan(clip.bounds.origin.y, 0, "the pane scrolled to follow the pointer")
        let landed = try XCTUnwrap(store.bookmarks.first)
        XCTAssertEqual(landed.name, "travelling", "still the same bookmark")
        XCTAssertGreaterThan(landed.row, afterFirstStep,
                             "the ticks kept carrying the mark down as the pane scrolled")
        XCTAssertTrue(pane.hexSelection().isEmpty,
                      "the autoscroll moved the mark, not a selection")
    }

    /// Window point over the Offset column at an exact view-coordinate `y`, for
    /// the drags that test a row boundary rather than a row.
    private func addressPoint(_ hexView: HexView, atY y: CGFloat) -> NSPoint {
        let x = hexView.hexLayout.offsetColumnFrame(row: 0).midX
        return hexView.convert(CGPoint(x: x, y: y), to: nil)
    }

    /// The reported jitter (§20.6): with a mark just jumped over another, the
    /// pointer still sits on the row it jumped over, so re-reading that row
    /// computed the jump again — in the other direction, the mark now being on
    /// the far side — and the mark flickered to and fro under a resting hand.
    /// A step answers the pointer CROSSING a row, so the jump holds.
    func testJitterAfterAJumpLeavesTheMarkWhereItLanded() throws {
        let (_, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x00, name: "moving")
        store.add(rowContaining: 0x10, name: "in the way")

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: 1), window: window))
        XCTAssertEqual(store.bookmarks.map(\.row), [0x10, 0x20], "the mark jumped the marked row")

        // A hand resting on the mouse: a few pixels of jitter within that row.
        let rowMiddle = hexView.hexLayout.rowFrame(row: 1).midY
        for dy in [0.5, -0.5, 1.0, -1.0, 0.0] as [CGFloat] {
            hexView.mouseDragged(with: try mouse(.leftMouseDragged,
                                                 at: addressPoint(hexView, atY: rowMiddle + dy),
                                                 window: window))
            XCTAssertEqual(store.bookmarks.map(\.row), [0x10, 0x20],
                           "jitter on the jumped-over row must not move anything")
        }
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 1), window: window))
    }

    /// The other half: a pointer sitting ON a row boundary must not flip between
    /// the two rows. It has to travel a couple of points into the next row before
    /// the drag counts it as being there.
    func testThePointerMustCrossARowEdgeByAFewPointsToStep() throws {
        let (_, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x00)
        let rowHeight = hexView.hexLayout.rowHeight
        // Absolute distances, not the constant itself: a test measured in the
        // value it is checking would pass with no hysteresis at all.
        XCTAssertGreaterThan(HexView.bookmarkDragHysteresis, 1)

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))

        // One point over the edge into row 1 — inside the hysteresis band.
        hexView.mouseDragged(with: try mouse(.leftMouseDragged,
                                             at: addressPoint(hexView, atY: rowHeight + 1),
                                             window: window))
        XCTAssertEqual(store.bookmarks.map(\.row), [0x00],
                       "a pointer barely past the edge is still on the row it came from")

        // Four points in: past the band, really on row 1.
        hexView.mouseDragged(with: try mouse(.leftMouseDragged,
                                             at: addressPoint(hexView, atY: rowHeight + 4),
                                             window: window))
        XCTAssertEqual(store.bookmarks.map(\.row), [0x10])

        // One point above row 1's top edge: the same band holds going up.
        hexView.mouseDragged(with: try mouse(.leftMouseDragged,
                                             at: addressPoint(hexView, atY: rowHeight - 1),
                                             window: window))
        XCTAssertEqual(store.bookmarks.map(\.row), [0x10],
                       "the band is symmetric — a step back needs the same couple of points")

        // Four points above it, and the mark comes back.
        hexView.mouseDragged(with: try mouse(.leftMouseDragged,
                                             at: addressPoint(hexView, atY: rowHeight - 4),
                                             window: window))
        XCTAssertEqual(store.bookmarks.map(\.row), [0x00])
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 1), window: window))
    }

    /// The hysteresis is per gesture, not per view: a fresh press re-reads where
    /// the pointer is, so the next drag is not measured against the last one's
    /// row.
    func testANewGestureStartsFromTheMarksOwnRow() throws {
        let (_, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x00)

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: 3), window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 3), window: window))
        XCTAssertEqual(store.bookmarks.map(\.row), [0x30])

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 3), window: window))
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: addressPoint(hexView, row: 4), window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: addressPoint(hexView, row: 4), window: window))

        XCTAssertEqual(store.bookmarks.map(\.row), [0x40], "the second drag moved one row on")
    }

    /// A pointer dragged above the first row has no row of its own: the mark
    /// lands on row 0 rather than on a negative offset.
    func testAMarkDraggedAboveTheFirstRowLandsOnRowZero() throws {
        let (_, hexView, window, store) = try makePane()
        store.add(rowContaining: 0x50)
        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 5), window: window))

        let above = hexView.convert(CGPoint(x: hexView.hexLayout.offsetColumnFrame(row: 0).midX,
                                            y: -200), to: nil)
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: above, window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: above, window: window))

        XCTAssertEqual(store.bookmarks.map(\.row), [0x00])
    }

    /// A mark cannot be dragged off the end of the file: the last row it can
    /// reach is the last row with bytes in it (§9).
    func testAMarkCannotBeDraggedPastTheLastRow() throws {
        let (_, hexView, window, store) = try makePane(byteCount: 0x40)
        store.add(rowContaining: 0x00)

        hexView.mouseDown(with: try mouse(.leftMouseDown, at: addressPoint(hexView, row: 0), window: window))
        let farBelow = hexView.convert(CGPoint(x: hexView.hexLayout.offsetColumnFrame(row: 0).midX,
                                               y: hexView.hexLayout.rowHeight * 40), to: nil)
        hexView.mouseDragged(with: try mouse(.leftMouseDragged, at: farBelow, window: window))
        hexView.mouseUp(with: try mouse(.leftMouseUp, at: farBelow, window: window))

        XCTAssertEqual(store.bookmarks.map(\.row), [0x30],
                       "0x30 is the last row a 0x40-byte file has")
    }
}
