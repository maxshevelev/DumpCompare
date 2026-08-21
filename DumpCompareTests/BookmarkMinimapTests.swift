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
                       "0x00000400", "an unnamed bookmark is its address")

        store.rename(rowContaining: 0x400, to: "EC table")
        XCTAssertEqual(panel.view(panel, stringForToolTip: 0, point: centre(of: box), userData: nil),
                       "0x00000400: EC table",
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
                       "0x00000800: NVRAM")
    }

    private func centre(of rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
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
