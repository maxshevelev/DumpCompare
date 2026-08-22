import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §19.4.3 / §20 — bookmarks in the minimap: a purple arrow in each map's
/// margin, level with the row it marks, in both render modes. One list serves
/// both maps (a bookmark is an absolute offset, §8), so a mark lands at the same
/// height on each — and no mark is drawn where a file does not reach (§9).
@MainActor
final class BookmarkMinimapTests: XCTestCase {
    private var tempFiles: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmmap-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        tempFiles.append(url)
        return url
    }

    private func pumpUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// A controller in a real window with the minimap panel shown, and the files
    /// given open. `sizes.1 == nil` opens a single file.
    private func makeWindow(sizes: (Int, Int?), vertical: Bool = true)
        throws -> (MainViewController, MinimapView) {
        LayoutSettings.set(isVertical: vertical)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.heightAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        window.layoutIfNeeded()
        windows.append(window)

        try controller.windowModel.pane1.open(url: try tempFile([UInt8](repeating: 0x41, count: sizes.0)))
        if let second = sizes.1 {
            try controller.windowModel.pane2.open(url: try tempFile([UInt8](repeating: 0x42, count: second)))
            controller.apply(mode: .comparison)
        } else {
            controller.apply(mode: .singleFile)
        }
        let content = try XCTUnwrap(window.contentView)
        let split = try XCTUnwrap(descendants(of: content, MinimapSplitView.self).first)
        let panel = try XCTUnwrap(descendants(of: content, MinimapView.self).first)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        controller.setMinimapRenderModeForTesting(.detail)
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
        }
        return (controller, panel)
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: $0, type) }
    }

    /// How purple a pixel is: purple has red and blue well above green, which no
    /// other ink in the panel does (the viewport's grey is flat, the difference
    /// orange is red-dominant, the modified red has no blue).
    private func purpleness(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return -1 }
        return min(rgb.redComponent, rgb.blueComponent) - rgb.greenComponent
    }

    /// The most purple pixel inside `rect` of the panel, as rendered.
    private func maxPurpleness(_ panel: MinimapView, in rect: NSRect) throws -> CGFloat {
        let rep = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / panel.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / panel.bounds.height
        let clipped = rect.intersection(panel.bounds)
        guard !clipped.isEmpty else { return -1 }
        var best: CGFloat = -1
        for x in stride(from: clipped.minX, to: clipped.maxX, by: 0.5) {
            for y in stride(from: clipped.minY, to: clipped.maxY, by: 0.5) {
                let px = min(max(Int(x * scaleX), 0), rep.pixelsWide - 1)
                let py = min(max(Int(y * scaleY), 0), rep.pixelsHigh - 1)
                guard let color = rep.colorAt(x: px, y: py) else { continue }
                best = max(best, purpleness(color))
            }
        }
        return best
    }

    // MARK: - The mark itself

    /// A marked row puts purple in the margin at that row's height, and nowhere
    /// else on the map — the marks live outside the content, so no byte is
    /// covered (§19.4.3).
    func testAMarkedRowIsMarkedInTheMargin() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x400, name: "EC table")
        panel.display()

        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x400, forMapAt: 0),
                                "the row is inside the detail window")
        XCTAssertGreaterThan(try maxPurpleness(panel, in: box), 0.2,
                             "the mark is drawn, in the bookmark colour")

        // Nothing purple in the content the mark points at, nor in the margin a
        // few marks' heights away.
        let content = NSRect(x: box.maxX + 2, y: box.minY - 4,
                             width: panel.bounds.width - box.maxX - 4, height: box.height + 8)
        XCTAssertLessThan(try maxPurpleness(panel, in: content), 0.05,
                          "the mark stays out of the map's content")
        let elsewhere = NSRect(x: box.minX, y: box.maxY + 3 * box.height,
                               width: box.width, height: box.height)
        XCTAssertLessThan(try maxPurpleness(panel, in: elsewhere), 0.05,
                          "and only the marked row is marked")
    }

    /// Removing the bookmark takes the arrow away again.
    func testRemovingTheBookmarkRemovesTheMark() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        let store = controller.windowModel.bookmarkStore
        store.add(rowContaining: 0x400)
        panel.display()
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x400, forMapAt: 0))
        XCTAssertGreaterThan(try maxPurpleness(panel, in: box), 0.2)

        store.remove(rowContaining: 0x400)
        panel.display()

        XCTAssertTrue(panel.bookmarks.isEmpty, "the panel was told")
        XCTAssertLessThan(try maxPurpleness(panel, in: box), 0.05, "and the arrow is gone")
    }

    /// The overview marks the same rows — the mode changes the scale, not what
    /// is marked (§19.4).
    func testTheOverviewMarksTheRowToo() throws {
        let (controller, panel) = try makeWindow(sizes: (0x40000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x30000)
        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertTrue(pumpUntil(2.0) { panel.renderMode == .overview && !panel.overviewSummaries.isEmpty },
                      "the overview needs its summaries before it draws rows")
        panel.display()

        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x30000, forMapAt: 0),
                                "the overview shows the whole file, so every row is on it")
        XCTAssertGreaterThan(box.midY, panel.bounds.midY,
                             "0x30000 of 0x40000 is in the map's lower half")
        XCTAssertGreaterThan(try maxPurpleness(panel, in: box), 0.2)
    }

    // MARK: - Two maps

    /// One list, one height: a bookmark is an absolute offset (§8), so the mark
    /// sits at the same height on both maps of a comparison.
    func testAMarkSitsAtTheSameHeightOnBothMaps() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, 0x4000))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x800)
        panel.display()

        let first = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x800, forMapAt: 0))
        let second = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x800, forMapAt: 1))
        XCTAssertEqual(first.midY, second.midY, accuracy: 0.5,
                       "the same absolute row is the same height on both maps")
        XCTAssertNotEqual(first.minX, second.minX,
                          "and each map marks it in its own margin")
        XCTAssertGreaterThan(try maxPurpleness(panel, in: first), 0.2)
        XCTAssertGreaterThan(try maxPurpleness(panel, in: second), 0.2)
    }

    /// §9: a row past the shorter file's end is not marked on its map — there is
    /// no such row there — while the longer file's map still marks it.
    func testNoMarkPastAShorterFilesEnd() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, 0x400))
        // Inside the detail window, past the short file's 0x400 bytes.
        controller.windowModel.bookmarkStore.add(rowContaining: 0x600)
        panel.display()

        XCTAssertNotNil(panel.bookmarkMarkRect(row: 0x600, forMapAt: 0),
                        "the long file reaches that row")
        XCTAssertNil(panel.bookmarkMarkRect(row: 0x600, forMapAt: 1),
                     "the short file does not, so nothing is marked on its map")
        let shortMargin = NSRect(x: panel.bounds.midX, y: 0,
                                 width: panel.bounds.width / 2, height: panel.bounds.height)
        XCTAssertLessThan(try maxPurpleness(panel, in: shortMargin), 0.05,
                          "and no purple anywhere on the short file's half")
    }

    // MARK: - The shape (§19.6)

    /// Both margin markers are the same shape — an equilateral triangle pointing
    /// at the map — because both say the same kind of thing about a position. The
    /// bookmark's is the smaller of the two: they can share a margin, and the
    /// viewport is the one the eye should find first.
    func testBothMarkersAreEquilateralTrianglesAndTheBookmarkIsSmaller() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x400)
        panel.display()

        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x400, forMapAt: 0))
        XCTAssertEqual(box.height, MinimapView.bookmarkMarkSide, accuracy: 0.01,
                       "the triangle's base is its height in the margin")
        XCTAssertEqual(box.width, MinimapView.bookmarkMarkSide * sqrt(3) / 2, accuracy: 0.01,
                       "and it reaches an equilateral triangle's height across it")
        XCTAssertLessThan(MinimapView.bookmarkMarkSide, MinimapView.viewportMarkerSide,
                          "a bookmark's mark is the smaller one")
        XCTAssertLessThanOrEqual(
            MinimapView.marginMarkerReach(side: MinimapView.viewportMarkerSide)
                + MinimapView.overviewMarkerInset,
            MinimapView.contentPadding,
            "the bigger marker still fits the margin it points across")
    }

    /// Both markers point at the same line — the content's edge, less the inset —
    /// so a mark and the viewport read as the same kind of arrow at two sizes.
    func testBothMarkersApexOnTheSameLine() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x400)
        panel.display()

        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x400, forMapAt: 0))
        XCTAssertEqual(box.maxX, MinimapView.contentPadding - MinimapView.overviewMarkerInset,
                       accuracy: 0.01,
                       "the apex stops the same distance short of the content as the viewport's")
    }

    // MARK: - Hovering a mark (§19.4.3)

    /// A mark carries no text, so hovering it says which row it marks — and what
    /// the bookmark is called, when it is called anything.
    func testHoveringAMarkNamesIt() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        let store = controller.windowModel.bookmarkStore
        store.add(rowContaining: 0x400)
        panel.display()
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x400, forMapAt: 0))

        XCTAssertEqual(panel.view(panel, stringForToolTip: 0, point: centre(of: box), userData: nil),
                       "00000400", "an unnamed bookmark is its address")

        store.rename(rowContaining: 0x400, to: "EC table")
        XCTAssertEqual(panel.view(panel, stringForToolTip: 0, point: centre(of: box), userData: nil),
                       "00000400: EC table",
                       "a named one says offset: name")
    }

    /// Anywhere that is not a mark says nothing, which shows no tooltip at all.
    func testHoveringElsewhereSaysNothing() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x400)
        panel.display()
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x400, forMapAt: 0))

        let inTheMap = NSPoint(x: panel.bounds.midX, y: box.midY)
        XCTAssertEqual(panel.view(panel, stringForToolTip: 0, point: inTheMap, userData: nil), "",
                       "the map's own content is not a mark")
        let belowIt = NSPoint(x: box.midX, y: box.maxY + 3 * box.height)
        XCTAssertEqual(panel.view(panel, stringForToolTip: 0, point: belowIt, userData: nil), "",
                       "and an unmarked row's margin is not either")
    }

    /// The tooltip answers from the pointer's position, so the mark on the second
    /// map of a comparison — in its own margin, on the other side — is found too.
    func testHoveringAMarkOnTheSecondMapNamesItToo() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, 0x4000))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x800, name: "NVRAM")
        panel.display()
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x800, forMapAt: 1))

        XCTAssertEqual(panel.view(panel, stringForToolTip: 0, point: centre(of: box), userData: nil),
                       "00000800: NVRAM")
    }

    private func centre(of rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - Clicking near a mark (§19.6)

    /// A click near a mark means that bookmark's row. On a full-dump overview a
    /// row is kilobytes, so without this the pointer can be dead on the arrow and
    /// still resolve to an offset a dozen rows off.
    func testAClickNearAMarkLandsOnTheBookmark() throws {
        let (controller, panel) = try makeWindow(sizes: (0x40000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x30000)
        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertTrue(pumpUntil(2.0) { panel.renderMode == .overview && !panel.overviewSummaries.isEmpty })
        panel.display()
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x30000, forMapAt: 0))

        let onTheMark = NSPoint(x: box.midX, y: box.midY)
        XCTAssertEqual(panel.snappedOffset(at: onTheMark)?.offset, 0x30000)

        // Three points below its centre — inside the snap distance.
        let near = NSPoint(x: box.midX, y: box.midY + 3)
        XCTAssertEqual(panel.snappedOffset(at: near)?.offset, 0x30000,
                       "a click a few points off still means the bookmark")
        XCTAssertNotEqual(panel.byteOffset(at: near)?.offset, 0x30000,
                          "and without snapping it would not — or this proves nothing")
    }

    /// Twenty points away it means what it landed on, as any other click does.
    func testAClickWellAwayFromAMarkIsNotSnapped() throws {
        let (controller, panel) = try makeWindow(sizes: (0x40000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x30000)
        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertTrue(pumpUntil(2.0) { panel.renderMode == .overview && !panel.overviewSummaries.isEmpty })
        panel.display()
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x30000, forMapAt: 0))

        let away = NSPoint(x: box.midX, y: box.midY + 20)
        XCTAssertEqual(panel.snappedOffset(at: away)?.offset, panel.byteOffset(at: away)?.offset,
                       "out of range, a click is the byte under it")
    }

    /// With two marks in range the nearer one wins.
    func testTheNearerMarkWins() throws {
        let (controller, panel) = try makeWindow(sizes: (0x40000, nil))
        let store = controller.windowModel.bookmarkStore
        store.add(rowContaining: 0x20000)
        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertTrue(pumpUntil(2.0) { panel.renderMode == .overview && !panel.overviewSummaries.isEmpty })
        // Close enough that a click between the two marks is inside BOTH snap
        // boxes — otherwise the tie-break never runs and this test passes with
        // the comparison in `nearestBookmarkMark` deleted.
        store.add(rowContaining: 0x20800)
        panel.display()

        let first = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x20000, forMapAt: 0))
        let second = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x20800, forMapAt: 0))
        let gap = abs(second.midY - first.midY)
        let reach = MinimapView.bookmarkMarkSide / 2 + MinimapView.bookmarkSnapDistance
        XCTAssertGreaterThan(gap, 1, "premise: the two marks are drawn at different heights")
        XCTAssertLessThan(gap / 2, reach, "premise: a point between them is in range of both marks")

        // A point just off the midpoint, on each side in turn: the nearer mark
        // is the one that answers.
        let middle = (first.midY + second.midY) / 2
        let towardsFirst = NSPoint(x: first.midX, y: middle + (first.midY - middle) * 0.4)
        let towardsSecond = NSPoint(x: second.midX, y: middle + (second.midY - middle) * 0.4)
        XCTAssertEqual(panel.snappedOffset(at: towardsFirst)?.offset, 0x20000,
                       "nearer to the upper mark, the upper bookmark wins")
        XCTAssertEqual(panel.snappedOffset(at: towardsSecond)?.offset, 0x20800,
                       "nearer to the lower mark, the lower bookmark wins")
    }

    /// A click on the panel goes through the snap: clicking a mark asks the pane
    /// for the bookmark's row, not for whatever byte the arrow happens to sit on.
    func testClickingAMarkSelectsTheBookmarksRow() throws {
        let (controller, panel) = try makeWindow(sizes: (0x40000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x30000)
        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertTrue(pumpUntil(2.0) { panel.renderMode == .overview && !panel.overviewSummaries.isEmpty })
        panel.display()
        var selected: [(Int, UInt64)] = []
        panel.onSelectOffset = { selected.append(($0, $1)) }
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x30000, forMapAt: 0))

        let point = panel.convert(NSPoint(x: box.midX, y: box.midY + 2), to: nil)
        panel.mouseDown(with: try XCTUnwrap(
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                               timestamp: 0, windowNumber: panel.window?.windowNumber ?? 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))

        XCTAssertEqual(selected.map(\.1), [0x30000])
    }

    /// Dragging the band is a scrollbar gesture and never snaps: a drag that
    /// passes a mark must not jump to it.
    func testDraggingTheBandDoesNotSnap() throws {
        let (controller, panel) = try makeWindow(sizes: (0x40000, nil))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x30000)
        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertTrue(pumpUntil(2.0) { panel.renderMode == .overview && !panel.overviewSummaries.isEmpty })
        panel.display()
        var selected: [UInt64] = []
        var scrolled: [UInt64] = []
        panel.onSelectOffset = { selected.append($1) }
        panel.onScrollToOffset = { scrolled.append($0) }
        let band = try XCTUnwrap(panel.viewportRects().first)
        let box = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x30000, forMapAt: 0))

        func event(_ type: NSEvent.EventType, _ y: CGFloat) throws -> NSEvent {
            let point = panel.convert(NSPoint(x: panel.bounds.midX, y: y), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                    timestamp: 0,
                                                    windowNumber: panel.window?.windowNumber ?? 0,
                                                    context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        }

        panel.mouseDown(with: try event(.leftMouseDown, band.midY))
        panel.mouseDragged(with: try event(.leftMouseDragged, box.midY))
        panel.mouseUp(with: try event(.leftMouseUp, box.midY))

        XCTAssertTrue(selected.isEmpty, "grabbing the band never moves the caret")
        XCTAssertFalse(scrolled.isEmpty, "it scrolls")
        XCTAssertFalse(scrolled.contains(0x30000),
                       "and it does not jump to the bookmark it dragged past")
    }

    // MARK: - Repainting (§19.9)

    /// A bookmark changes nothing about the file's picture, so only the margins
    /// it is drawn in are repainted — a full-dump overview must not be redrawn to
    /// add one arrow.
    func testAMarkRepaintsOnlyTheMargins() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        panel.display()
        let before = panel.repaintRequests

        controller.windowModel.bookmarkStore.add(rowContaining: 0x400)

        XCTAssertGreaterThan(panel.repaintRequests, before, "the panel was asked to repaint")
        let rects = try XCTUnwrap(panel.lastRepaintRequest,
                                  "a nil request means the WHOLE panel — too much for one mark")
        XCTAssertEqual(rects.count, 1, "one map, one margin")
        let strip = try XCTUnwrap(rects.first)
        XCTAssertLessThanOrEqual(strip.width, MinimapView.contentPadding,
                                 "the strip is the margin, not the map")
        XCTAssertEqual(strip.height, panel.bounds.height, accuracy: 0.5,
                       "its whole height, since any row can be marked")
    }

    /// A name change moves no arrow, so it asks for no repaint — though the mark
    /// it names does read out the new name (see the hover tests).
    func testARenameDoesNotRepaint() throws {
        let (controller, panel) = try makeWindow(sizes: (0x4000, nil))
        let store = controller.windowModel.bookmarkStore
        store.add(rowContaining: 0x400)
        panel.display()
        let before = panel.repaintRequests

        store.rename(rowContaining: 0x400, to: "EC table")

        XCTAssertEqual(panel.repaintRequests, before,
                       "the same rows are the same picture in the margin")
    }
}
