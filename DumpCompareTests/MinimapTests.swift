import DumpCompareCore
import XCTest
@testable import DumpCompare

/// § Minimap: the right-edge toolbar toggle ("sidebar.right"), the fixed spacer
/// between it and the diff navigation block, the animated show/hide of the
/// vertical panel, and the maps it fills with. The panel starts hidden, stays
/// within `MinimapSplitView.minPanelWidth...maxPanelWidth` (120...240 pt)
/// through both drags and window resizes, and its width is persisted so the
/// next show restores the user's drag.
@MainActor
final class MinimapTests: XCTestCase {
    /// A throwaway defaults domain, one per test run, so the tests never read or
    /// pollute the real app's `UserDefaults.standard` (e.g. a width the user
    /// dragged while trying the app by hand).
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!
    private var savedMainMenu: NSMenu?
    private var savedLayoutIsVertical: Bool?

    override func setUp() {
        super.setUp()
        isolatedSuiteName = "MinimapTests-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: isolatedSuiteName)
        // Route the minimap's width persistence at the isolated store; restored
        // to .standard in tearDown.
        MinimapSplitView.defaults = isolatedDefaults
        // Deterministic: clear any autosaved window frame and force the layout
        // start so the window opens at a known size.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")
        // Building a MainWindowController rebuilds the app menu; keep the prior
        // menu intact for whatever other test runs after this one.
        savedMainMenu = NSApp.mainMenu
        savedLayoutIsVertical = LayoutSettings.isVertical
    }

    override func tearDown() {
        if let savedLayoutIsVertical {
            LayoutSettings.set(isVertical: savedLayoutIsVertical)
        }
        NSApp.mainMenu = savedMainMenu
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        MinimapSplitView.defaults = .standard
        isolatedDefaults = nil
        super.tearDown()
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimap-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        var result: [T] = []
        for sub in view.subviews {
            if let match = sub as? T { result.append(match) }
            result.append(contentsOf: descendants(of: sub, type))
        }
        return result
    }

    /// Pumps the main runloop until `condition` holds or the deadline passes.
    @discardableResult
    private func pumpUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// A real controller in a real window, laid out at a known size. The
    /// minimap needs no open file at stage 1, but the window gives the split
    /// real bounds so the divider pin and panel width all have room to work.
    private func makeController() throws -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.heightAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        window.layoutIfNeeded()
        return (controller, window)
    }

    /// The minimap's split host and panel inside a real window.
    private func minimapViews(_ window: NSWindow)
        throws -> (MinimapSplitView, MinimapView) {
        let split = try XCTUnwrap(descendants(of: window.contentView!, MinimapSplitView.self).first,
                                  "the minimap split host")
        let panel = try XCTUnwrap(descendants(of: window.contentView!, MinimapView.self).first,
                                  "the minimap panel")
        return (split, panel)
    }

    // MARK: - Show / hide

    func testMinimapIsHiddenOnLaunch() throws {
        let (_, window) = try makeController()
        let (split, panel) = try minimapViews(window)

        XCTAssertFalse(split.panelVisible, "the minimap starts hidden")
        window.layoutIfNeeded()
        // The hidden panel leaves only the divider (≈1 pt) exposed at the edge.
        XCTAssertLessThan(panel.frame.width, 2,
                          "a hidden panel collapses against the right edge")
    }

    func testToggleShowsMinimapAtMinimumWidth() throws {
        let (_, window) = try makeController()
        let (split, panel) = try minimapViews(window)

        split.setPanelVisible(true, animated: false)
        XCTAssertTrue(split.panelVisible, "showing flips the panel-visible flag")
        window.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(panel.frame.width, MinimapSplitView.minPanelWidth,
                                    "a shown panel keeps at least its minimum width")

        // A second toggle hides it again.
        split.togglePanel(animated: false)
        XCTAssertFalse(split.panelVisible, "toggling again hides the panel")
        window.layoutIfNeeded()
        XCTAssertLessThan(panel.frame.width, 2, "the panel collapses back to the divider")
    }

    // MARK: - Width clamp and persistence

    func testPanelWidthIsClampedAndPersisted() throws {
        let (_, window) = try makeController()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        // A width the user dragged lands verbatim (it is within the clamp).
        split.setPanelWidth(150, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.frame.width, 150, accuracy: 1,
                       "an in-range width is applied as dragged")

        // Below the minimum the delegate clamps the divider back up to 120 pt.
        split.setPanelWidth(10, animated: false)
        window.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(panel.frame.width, MinimapSplitView.minPanelWidth,
                                    "the panel never shrinks below its minimum")

        // Above the maximum the panel stops at 240 pt.
        split.setPanelWidth(10_000, animated: false)
        window.layoutIfNeeded()
        XCTAssertLessThanOrEqual(panel.frame.width, MinimapSplitView.maxPanelWidth,
                                 "the panel never grows past its maximum width")

        // The in-range drag is persisted for the next show.
        split.setPanelWidth(150, animated: false)
        _ = pumpUntil(1.0) {
            MinimapSplitView.defaults.object(forKey: MinimapSplitView.widthDefaultsKey) != nil
        }
        let stored = MinimapSplitView.defaults.object(forKey: MinimapSplitView.widthDefaultsKey) as? NSNumber
        XCTAssertNotNil(stored, "a dragged panel width is persisted")
        if let stored {
            XCTAssertEqual(CGFloat(stored.doubleValue), 150, accuracy: 1)
        }
    }

    func testRestoredWidthReappliesOnNextShow() throws {
        let (_, window) = try makeController()
        let (split, panel) = try minimapViews(window)

        // First show: drag to 150 (persisted).
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        split.setPanelWidth(150, animated: false)
        window.layoutIfNeeded()

        // Hide, then show again — the persisted width wins over the default.
        split.setPanelVisible(false, animated: false)
        window.layoutIfNeeded()
        XCTAssertLessThan(panel.frame.width, 1)

        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.frame.width, 150, accuracy: 1,
                       "the second show restores the dragged width")
    }

    // MARK: - Toolbar

    func testToolbarPinsMinimapToggleAtFarRight() {
        let wc = MainWindowController()
        defer { wc.close() }
        let toolbar = wc.window?.toolbar
        XCTAssertNotNil(toolbar, "the main window has a toolbar")
        guard let toolbar else { return }

        _ = pumpUntil(1.0) { toolbar.items.count == 4 }
        let identifiers = toolbar.items.map(\.itemIdentifier)
        XCTAssertEqual(identifiers,
                       [.flexibleSpace, .diffNavigation, .minimapSpacer, .toggleMinimap],
                       "flexible space pins the diff block right; the spacer keeps the toggle past it")

        let toggle = toolbar.items.first { $0.itemIdentifier == .toggleMinimap }
        XCTAssertNotNil(toggle?.image, "the toggle shows the sidebar-right icon")
        XCTAssertEqual(toggle?.target as? MainViewController, wc.mainViewController)
        XCTAssertEqual(toggle?.action, #selector(MainViewController.toggleMinimap),
                       "the toggle drives the controller's minimap show/hide")

        let spacer = toolbar.items.first { $0.itemIdentifier == .minimapSpacer }
        if let spacer, let spacerView = spacer.view {
            XCTAssertEqual(spacerView.frame.width, 14, accuracy: 0.5,
                           "the fixed spacer separates the diff block from the toggle")
        } else {
            XCTFail("the minimap spacer item has a fixed-width view")
        }
    }

    func testToggleMinimapFromControllerAnimatesPanel() throws {
        let (controller, window) = try makeController()
        let (split, panel) = try minimapViews(window)

        controller.toggleMinimap()
        // The real user path animates; assert the flag flips and the panel opens
        // even before the animation finishes (the divider is already moving).
        XCTAssertTrue(split.panelVisible, "the toolbar action flips the visible flag")
        _ = pumpUntil(1.0) { !panel.isHidden && panel.frame.width >= MinimapSplitView.minPanelWidth }
        XCTAssertTrue(split.panelVisible)
        XCTAssertGreaterThanOrEqual(panel.frame.width, MinimapSplitView.minPanelWidth - 1)
    }

    // MARK: - Stage 2: map layout

    /// Opens two files and applies comparison mode at the given pane
    /// arrangement (vertical = side-by-side, horizontal = stacked).
    private func makeComparisonWindow(vertical: Bool,
                                      sizes: (Int, Int) = (256, 128)) throws -> (MainViewController, NSWindow) {
        LayoutSettings.set(isVertical: vertical)
        let url1 = try tempFile([UInt8](repeating: 0x41, count: sizes.0))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: sizes.1))
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        return (controller, window)
    }

    func testSingleFileShowsOneMap() throws {
        let url = try tempFile([0x00, 0x01, 0x02])
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()

        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        guard case .single = panel.mapLayout else {
            return XCTFail("single-file mode shows a single map, got \(panel.mapLayout)")
        }
    }

    func testComparisonSideBySideSplitsPanelVertically() throws {
        let (_, window) = try makeComparisonWindow(vertical: true)
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        guard case .sideBySide = panel.mapLayout else {
            return XCTFail("side-by-side comparison splits the minimap vertically, got \(panel.mapLayout)")
        }
    }

    func testComparisonStackedSplitsPanelHorizontally() throws {
        let (_, window) = try makeComparisonWindow(vertical: false)
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        guard case .stacked(let fraction) = panel.mapLayout else {
            return XCTFail("stacked comparison splits the minimap horizontally, got \(panel.mapLayout)")
        }
        XCTAssertEqual(fraction, 0.5, accuracy: 0.001,
                       "a fresh comparison starts at a 50/50 split")
    }

    func testStackedDividerFollowsPaneDivider() throws {
        let (_, window) = try makeComparisonWindow(vertical: false)
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        let paneSplit = try XCTUnwrap(descendants(of: window.contentView!, ProportionalSplitView.self).first,
                                      "the comparison's pane split")
        let available = paneSplit.bounds.height - paneSplit.dividerThickness
        paneSplit.setPosition(available * 0.25, ofDividerAt: 0)
        window.layoutIfNeeded()

        guard case .stacked(let fraction) = panel.mapLayout else {
            return XCTFail("stacked comparison keeps a horizontal split, got \(panel.mapLayout)")
        }
        XCTAssertEqual(fraction, 0.25, accuracy: 0.001,
                       "the minimap divider mirrors the pane divider as it moves")
    }

    func testTogglingPaneLayoutFlipsMinimapSplit() throws {
        let (controller, window) = try makeComparisonWindow(vertical: true)
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        guard case .sideBySide = panel.mapLayout else {
            return XCTFail("comparison starts side-by-side, got \(panel.mapLayout)")
        }

        // View > Toggle Pane Layout: the minimap follows the new arrangement.
        controller.togglePaneLayout()
        window.layoutIfNeeded()
        guard case .stacked(let fraction) = panel.mapLayout else {
            return XCTFail("after toggling, the minimap splits horizontally, got \(panel.mapLayout)")
        }
        XCTAssertEqual(fraction, 0.5, accuracy: 0.001)
    }

    // MARK: - Byte cells

    /// Opens one file in single-file mode with the panel shown. No waiting for a
    /// build: the map pulls its cells from the pane as it draws, so
    /// `visibleCells` is meaningful the moment the panel has a size.
    private func makeSingleFileWindow(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, MinimapView) {
        let url = try tempFile(bytes)
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        return (controller, window, panel)
    }

    func testSignificanceCellsMarkSignificantBytes() throws {
        // 3 hex rows: row 0 has a significant byte, row 1 is all fill, row 2
        // has a significant byte.
        let bytes: [UInt8] = [0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let (_, _, panel) = try makeSingleFileWindow(bytes)
        let rows = panel.visibleCells(forMapAt: 0)
        XCTAssertEqual(panel.maps.first?.fileSize, UInt64(bytes.count))
        XCTAssertEqual(rows.count, 3, "48 bytes = 3 hex rows = 3 mini rows")
        XCTAssertEqual(rows[0].cells.count, 16, "a full hex row keeps 16 cells")
        XCTAssertEqual(rows[0].cells[1], .significant, "row 0 holds 0x41 at column 1")
        XCTAssertEqual(rows[0].cells.filter { $0 == .significant }.count, 1,
                       "only 0x41 is significant in row 0")
        XCTAssertTrue(rows[1].cells.allSatisfy { $0 == .insignificant },
                      "row 1 is all 0x00/0xFF fill")
        XCTAssertEqual(rows[2].cells[2], .significant, "row 2 holds 0x42 at column 2")
        XCTAssertEqual(rows[2].cells.filter { $0 == .significant }.count, 1,
                       "only 0x42 is significant in row 2")
    }

    func testPartialLastRowKeepsOnlyItsBytes() throws {
        // 3 bytes = one partial hex row → one mini row with exactly 3 cells.
        let (_, _, panel) = try makeSingleFileWindow([0x41, 0x00, 0x42])
        let rows = panel.visibleCells(forMapAt: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].cells.count, 3, "the partial row holds only its bytes")
        XCTAssertEqual(rows[0].cells[0], .significant)
        XCTAssertEqual(rows[0].cells[1], .insignificant)
        XCTAssertEqual(rows[0].cells[2], .significant)
    }

    func testModifiedCellsMarkEditedBytes() throws {
        // A freshly opened file has nothing modified; editing a byte turns its
        // cell's isModified flag on. No wait: the cells are read as they are
        // drawn, so the edit is on the map the moment it lands.
        let bytes: [UInt8] = [0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let (controller, _, panel) = try makeSingleFileWindow(bytes)
        XCTAssertFalse(try XCTUnwrap(panel.visibleCells(forMapAt: 0).first)
            .cells.contains(where: \.isModified), "no edits yet → no modified cells")

        controller.windowModel.pane1.moveCaret(to: 1)
        controller.windowModel.pane1.typeASCII(0x42)

        let row = try XCTUnwrap(panel.visibleCells(forMapAt: 0).first)
        XCTAssertEqual(row.cells[1],
                       MinimapView.CellState(isSignificant: true, isModified: true,
                                             isDifferent: false),
                       "the typed byte is significant and modified")
        XCTAssertFalse(row.cells[0].isModified, "untouched bytes stay unmodified")
    }

    func testComparisonDifferenceCellsWin() throws {
        // Two files that differ everywhere → every cell is a difference cell.
        // Difference comes from the panes' live comparison, so there is no
        // background index to wait for.
        let (_, window) = try makeComparisonWindow(vertical: true, sizes: (64, 64))
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(panel.maps.count, 2, "one map per pane")
        for index in 0..<2 {
            let rows = panel.visibleCells(forMapAt: index)
            XCTAssertEqual(rows.count, 4, "64 bytes = 4 hex rows on map \(index)")
            XCTAssertTrue(rows.allSatisfy { $0.cells.allSatisfy(\.isDifferent) },
                          "every byte of map \(index) differs from its companion")
        }
    }

    func testSelectionOverlayFollowsCaret() throws {
        let bytes = [UInt8](repeating: 0x41, count: 32)
        let (controller, _, panel) = try makeSingleFileWindow(bytes)

        // No selection yet → no overlay.
        XCTAssertNil(panel.selection(forMapAt: 0))

        controller.windowModel.pane1.moveCaret(to: 4)
        controller.windowModel.pane1.moveCaret(to: 10, extendSelection: true)
        _ = pumpUntil(1.0) { panel.selection(forMapAt: 0) == (4..<10) }
        XCTAssertEqual(panel.selection(forMapAt: 0), 4..<10)

        // Collapsing the selection back to a caret removes the overlay.
        controller.windowModel.pane1.moveCaret(to: 7)
        _ = pumpUntil(1.0) { panel.selection(forMapAt: 0) == nil }
        XCTAssertNil(panel.selection(forMapAt: 0))
    }

    // MARK: - Stage 4: viewport rectangle

    /// The hex view's clip view (scrollable region) inside the window.
    private func hexClip(_ window: NSWindow) throws -> NSClipView {
        let hexView = try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
        return try XCTUnwrap(hexView.enclosingScrollView?.contentView)
    }

    func testViewportShowsTopOfLargeFileAndFollowsScroll() throws {
        // 100k bytes = 6250 hex rows, far more than the ~600 pt window shows.
        let bytes = [UInt8](repeating: 0x41, count: 100_000)
        let (_, window, panel) = try makeSingleFileWindow(bytes)
        let clip = try hexClip(window)

        // The pane opens scrolled to the top: the visible slice starts at byte 0
        // and covers fewer rows than the whole file.
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        let initial = try XCTUnwrap(panel.viewport(forMapAt: 0))
        XCTAssertEqual(initial.lowerBound, 0, "the top of the file is visible first")
        XCTAssertLessThan(initial.upperBound, UInt64(bytes.count),
                          "a file taller than the viewport shows only a slice")

        // Scroll to the bottom: the visible slice moves to the file's tail.
        let hexView = try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
        let maxY = hexView.hexContentHeight - clip.bounds.height
        clip.setBoundsOrigin(NSPoint(x: 0, y: max(maxY, 0)))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) {
            guard let vp = panel.viewport(forMapAt: 0) else { return false }
            return vp.upperBound >= UInt64(bytes.count)
        }
        let bottom = try XCTUnwrap(panel.viewport(forMapAt: 0))
        XCTAssertEqual(bottom.upperBound, UInt64(bytes.count),
                       "scrolling to the end shows the file's last bytes")
        XCTAssertGreaterThan(bottom.lowerBound, initial.upperBound,
                             "the rectangle moved down the map")
    }

    func testComparisonTracksEachPaneIndependently() throws {
        // Pane 1 holds a file too big for the viewport; pane 2 holds 64 bytes.
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 100_000))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 64))
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        // Both panes report a viewport: pane 2's whole file is visible, pane 1
        // shows only its top.
        _ = pumpUntil(2.0) {
            panel.viewport(forMapAt: 0) != nil && panel.viewport(forMapAt: 1) != nil
        }
        let pane1Top = try XCTUnwrap(panel.viewport(forMapAt: 0))
        let pane2Top = try XCTUnwrap(panel.viewport(forMapAt: 1))
        XCTAssertEqual(pane1Top.lowerBound, 0)
        XCTAssertLessThan(pane1Top.upperBound, 100_000, "pane 1's file is taller than the viewport")
        XCTAssertEqual(pane2Top, 0..<64, "pane 2's tiny file is fully visible")

        // Scroll pane 1 to its tail; pane 2's viewport must not move.
        let hexViews = descendants(of: window.contentView!, HexView.self)
        let pane1Hex = try XCTUnwrap(hexViews.first)
        let clip1 = try XCTUnwrap(pane1Hex.enclosingScrollView?.contentView)
        clip1.setBoundsOrigin(NSPoint(x: 0, y: max(pane1Hex.hexContentHeight - clip1.bounds.height, 0)))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) {
            guard let vp = panel.viewport(forMapAt: 0) else { return false }
            return vp.upperBound >= 100_000
        }
        let pane1Bottom = try XCTUnwrap(panel.viewport(forMapAt: 0))
        XCTAssertEqual(pane1Bottom.upperBound, 100_000)
        XCTAssertEqual(panel.viewport(forMapAt: 1), 0..<64,
                       "scrolling one pane leaves the other pane's rectangle alone")
    }

    // MARK: - Viewport band geometry

    /// Side-by-side panes scroll in lockstep by absolute offset (§9), so the
    /// viewport is ONE rectangle across the whole panel — a band per map left
    /// the gutter cut out of it and read as a broken overlay.
    func testSideBySideDrawsOneViewportBandAcrossBothMaps() throws {
        let (_, window) = try makeComparisonWindow(vertical: true)
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.viewportRects().count == 1 }

        let rects = panel.viewportRects()
        XCTAssertEqual(rects.count, 1, "one band, not one per map")
        let band = try XCTUnwrap(rects.first)
        XCTAssertEqual(band.minX, 0, accuracy: 0.5, "the band starts at the panel's edge")
        XCTAssertEqual(band.width, panel.bounds.width, accuracy: 0.5,
                       "the band spans the whole panel, crossing the gutter between the maps")
        XCTAssertGreaterThan(band.height, 0)
    }

    /// The geometry above says the band spans the panel; this pins that it also
    /// *looks* unbroken. The divider between the maps is drawn after the band, so
    /// a plain 1 pt line would paint the seam straight back in — inside the
    /// band's rows the line has to yield. Rendered through the real `draw(_:)`
    /// via `cacheDisplay`, then sampled across the divider's x.
    func testTheSharedBandHasNoDividerSeamThroughIt() throws {
        let (_, window) = try makeComparisonWindow(vertical: true, sizes: (8_000, 4_000))
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.viewportRects().count == 1 }
        let band = try XCTUnwrap(panel.viewportRects().first)
        XCTAssertGreaterThan(band.height, 4, "need a few rows of band to sample")

        let rep = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds),
                                "no bitmap rep")
        panel.cacheDisplay(in: panel.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / panel.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / panel.bounds.height

        /// The luminance at a point in the view's (flipped) coordinates.
        func luminance(x: CGFloat, y: CGFloat) throws -> CGFloat {
            let px = min(max(Int(x * scaleX), 0), rep.pixelsWide - 1)
            let py = min(max(Int(y * scaleY), 0), rep.pixelsHigh - 1)
            let color = try XCTUnwrap(rep.colorAt(x: px, y: py))
            return color.usingColorSpace(.deviceRGB).map {
                0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent
            } ?? -1
        }

        // Sample the middle row of the band: on the divider's x and in the
        // gutter just beside it. Inside the band the two must match — the line
        // is not painted there.
        let midBandY = band.midY
        let onDivider = try luminance(x: panel.bounds.midX, y: midBandY)
        let besideDivider = try luminance(x: panel.bounds.midX - 3, y: midBandY)
        XCTAssertEqual(onDivider, besideDivider, accuracy: 0.02,
                       "no divider seam across the band")

        // Below the band the divider is still drawn, so the same two samples
        // must now differ — otherwise the test above would pass on a panel that
        // simply lost its divider.
        let belowBandY = min(band.maxY + 6, panel.bounds.height - 1)
        let onDividerBelow = try luminance(x: panel.bounds.midX, y: belowBandY)
        let besideDividerBelow = try luminance(x: panel.bounds.midX - 3, y: belowBandY)
        XCTAssertNotEqual(onDividerBelow, besideDividerBelow, accuracy: 0.02,
                          "outside the band the maps are still divided by a line")
    }

    /// Stacked maps sit above each other, so their bands are at different y by
    /// construction — one rectangle over both would swallow the divider.
    func testStackedKeepsABandPerMap() throws {
        let (_, window) = try makeComparisonWindow(vertical: false)
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.viewportRects().count == 2 }

        let rects = panel.viewportRects()
        XCTAssertEqual(rects.count, 2, "stacked panes keep a band each")
        // The second band sits in the lower half, below the panes' divider.
        let sorted = rects.sorted { $0.minY < $1.minY }
        XCTAssertLessThan(sorted[0].minY, panel.bounds.height / 2)
        XCTAssertGreaterThanOrEqual(sorted[1].minY, panel.bounds.height / 2 - 1)
    }

    /// The shared band is the visible rows laid out at the map's own fixed
    /// scale, offset by the window's first row — no file-size fraction is
    /// involved any more, so the band means the same thing on both maps.
    func testSharedBandMatchesTheVisibleRowsAtTheFixedScale() throws {
        let (_, window) = try makeComparisonWindow(vertical: true, sizes: (8_000, 4_000))
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.viewportRects().count == 1 }

        let visible = try XCTUnwrap(panel.viewport(forMapAt: 0))
        let paneRows = (visible.upperBound - visible.lowerBound + 15) / 16
        let band = try XCTUnwrap(panel.viewportRects().first)
        XCTAssertEqual(band.height, CGFloat(paneRows) * MinimapView.rowStep, accuracy: MinimapView.rowStep,
                       "the band is exactly the pane's rows at 4 pt each")
        XCTAssertEqual(band.minY,
                       CGFloat(visible.lowerBound / 16 - panel.topRow) * MinimapView.rowStep,
                       accuracy: 1, "and starts at the pane's first row within the window")
    }

    // MARK: - The window onto the file

    /// The rows a map can show at the fixed scale.
    private func windowRows(_ panel: MinimapView) -> UInt64 {
        UInt64(MinimapView.visibleRowCount(areaHeight: panel.bounds.height))
    }

    /// A file short enough to fit needs no window: it sits at row 0 and the band
    /// moves inside it.
    func testWindowStaysAtTheTopForAFileThatFits() throws {
        let (_, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 160))
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        XCTAssertEqual(panel.topRow, 0, "10 hex rows fit the panel many times over")
        XCTAssertGreaterThan(windowRows(panel), 10, "the panel really is taller than the file")
        _ = window
    }

    /// A file taller than the panel makes the map a window that slides with the
    /// panes: at the top of the file the window starts at row 0, at the bottom
    /// its last row is the file's last, and the band stays on the map throughout.
    func testWindowSlidesWithThePaneAndReachesTheFileEnd() throws {
        let bytes = [UInt8](repeating: 0x41, count: 100_000)   // 6250 hex rows
        let (_, window, panel) = try makeSingleFileWindow(bytes)
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        let totalRows = UInt64((bytes.count + 15) / 16)
        let rows = windowRows(panel)
        XCTAssertLessThan(rows, totalRows, "the file must not fit — that is the point")
        XCTAssertEqual(panel.topRow, 0, "at the file's start the window starts at row 0")
        XCTAssertFalse(panel.viewportRects().isEmpty, "the band is on the map")

        // Scroll the pane to the very bottom.
        let hexView = try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
        let clip = try XCTUnwrap(hexView.enclosingScrollView?.contentView)
        clip.setBoundsOrigin(NSPoint(x: 0, y: max(hexView.hexContentHeight - clip.bounds.height, 0)))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { (panel.viewport(forMapAt: 0)?.upperBound ?? 0) >= UInt64(bytes.count) }

        XCTAssertEqual(panel.topRow, totalRows - rows,
                       "at the file's end the window's last row is the file's last")
        XCTAssertFalse(panel.viewportRects().isEmpty, "the band is still on the map")

        // And somewhere in the middle the window sits somewhere in the middle.
        clip.setBoundsOrigin(NSPoint(x: 0, y: (hexView.hexContentHeight - clip.bounds.height) / 2))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.topRow > 0 && panel.topRow < totalRows - rows }
        XCTAssertGreaterThan(panel.topRow, 0)
        XCTAssertLessThan(panel.topRow, totalRows - rows)
    }

    /// Every byte gets its own cell: a mini row is one hex row, never a group of
    /// them. The file below puts a single significant byte in column `row % 16`,
    /// so an aggregating map would smear several columns into one row.
    func testEveryByteGetsItsOwnRowWithNoAggregation() throws {
        let rowCount = 400
        var bytes = [UInt8](repeating: 0x00, count: rowCount * 16)
        for row in 0..<rowCount {
            bytes[row * 16 + row % 16] = 0x41
        }
        let (_, _, panel) = try makeSingleFileWindow(bytes)
        let rows = panel.visibleCells(forMapAt: 0)
        XCTAssertEqual(UInt64(rows.count), windowRows(panel),
                       "the map shows a window of rows, not the whole file collapsed into it")
        XCTAssertLessThan(rows.count, rowCount, "the file is taller than the window")

        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.cells.count, 16, "row \(index) is one hex row")
            let significant = row.cells.enumerated().filter(\.element.isSignificant).map(\.offset)
            XCTAssertEqual(significant, [(Int(panel.topRow) + index) % 16],
                           "row \(index) keeps exactly its own byte significant")
        }
    }

    // MARK: - Dragging the viewport

    /// Synthesizes a mouse event at a point in the panel's own coordinates.
    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint,
                            in panel: MinimapView) throws -> NSEvent {
        let inWindow = panel.convert(point, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.window?.windowNumber ?? 0,
                                               context: nil, eventNumber: 0, clickCount: 1,
                                               pressure: 1),
                             "could not synthesize \(type)")
    }

    /// Grabbing the band and pulling it down scrolls the panes forward — the map
    /// is a proportional scrollbar over the whole file, so a short drag covers a
    /// lot of a big file.
    func testDraggingTheBandScrollsThePanes() throws {
        let bytes = [UInt8](repeating: 0x41, count: 100_000)
        let (_, window, panel) = try makeSingleFileWindow(bytes)
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        let start = try XCTUnwrap(panel.viewport(forMapAt: 0))
        XCTAssertEqual(start.lowerBound, 0, "the pane starts at the top of the file")
        let band = try XCTUnwrap(panel.viewportRects().first)

        panel.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: band.midX, y: band.midY),
                                             in: panel))
        panel.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                                                at: NSPoint(x: band.midX, y: band.midY + 120),
                                                in: panel))
        panel.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: band.midX, y: band.midY + 120),
                                           in: panel))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { (panel.viewport(forMapAt: 0)?.lowerBound ?? 0) > start.lowerBound }

        let moved = try XCTUnwrap(panel.viewport(forMapAt: 0))
        XCTAssertGreaterThan(moved.lowerBound, start.lowerBound,
                             "dragging the band down scrolled the pane forward")
        XCTAssertGreaterThan(panel.topRow, 0, "and the map's window followed it")
    }

    /// Dragging back up returns to the file's start rather than overshooting into
    /// negative offsets.
    func testDraggingTheBandToTheTopClampsAtTheFileStart() throws {
        let bytes = [UInt8](repeating: 0x41, count: 100_000)
        let (_, window, panel) = try makeSingleFileWindow(bytes)
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }

        // Jump into the middle by clicking off the band, then drag far above the
        // panel's top edge.
        panel.mouseDown(with: try mouseEvent(.leftMouseDown,
                                             at: NSPoint(x: panel.bounds.midX,
                                                         y: panel.bounds.height / 2),
                                             in: panel))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { (panel.viewport(forMapAt: 0)?.lowerBound ?? 0) > 0 }
        XCTAssertGreaterThan(try XCTUnwrap(panel.viewport(forMapAt: 0)).lowerBound, 0,
                             "a click off the band jumps there")

        panel.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                                               at: NSPoint(x: panel.bounds.midX, y: -400),
                                               in: panel))
        panel.mouseUp(with: try mouseEvent(.leftMouseUp,
                                          at: NSPoint(x: panel.bounds.midX, y: -400), in: panel))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0)?.lowerBound == 0 }
        XCTAssertEqual(try XCTUnwrap(panel.viewport(forMapAt: 0)).lowerBound, 0,
                       "dragging above the map clamps at the file's start")
        XCTAssertEqual(panel.topRow, 0)
    }

    // MARK: - Modified cells

    /// Modified cells come from the panes' own per-byte state, so overwriting a
    /// byte with the value it already held is not a modification — exactly as the
    /// panes' red foreground rule has it.
    func testRetypingTheSameValueLeavesTheCellUnmodified() throws {
        let (controller, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 16))
        let pane = controller.windowModel.pane1

        pane.moveCaret(to: 3)
        pane.typeASCII(0x41)   // the value it already had
        pane.moveCaret(to: 1)
        pane.typeASCII(0x42)   // a new value

        let row = try XCTUnwrap(panel.visibleCells(forMapAt: 0).first)
        XCTAssertTrue(row.cells[1].isModified, "0x42 over 0x41 is a modification")
        XCTAssertFalse(row.cells[3].isModified,
                       "0x41 over 0x41 leaves the byte as it was on disk")
    }

    /// Saving clears modified state without changing a byte. The map reads that
    /// state per repaint, but nothing else tells it to repaint, so the pane's
    /// saved-state callback is what keeps the red cells from lingering.
    func testSavingClearsModifiedCells() throws {
        let (controller, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 16))
        let pane = controller.windowModel.pane1

        pane.moveCaret(to: 1)
        pane.typeASCII(0x42)
        XCTAssertTrue(try XCTUnwrap(panel.visibleCells(forMapAt: 0).first).cells[1].isModified,
                      "the edit shows as a modified cell")

        try pane.save()
        let row = try XCTUnwrap(panel.visibleCells(forMapAt: 0).first)
        XCTAssertFalse(row.cells.contains(where: \.isModified),
                       "a saved file has no modified bytes left to paint")
        XCTAssertTrue(row.cells[1].isSignificant,
                      "the byte itself is still there — only its modified flag cleared")
    }

    // MARK: - Width clamp across a window resize

    /// `constrainMin/MaxCoordinate` govern a divider *drag* only; NSSplitView's
    /// default resize is proportional, so a wide window used to carry the panel
    /// far past its maximum (a 2600 pt window opened it to ~390 pt). The panel
    /// holds its width instead and the hex panes absorb the delta.
    func testPanelHoldsItsWidthWhenTheWindowGrows() throws {
        let (_, window) = try makeController()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        split.setPanelWidth(150, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.frame.width, 150, accuracy: 1)

        for width in [1200.0, 1800.0, 2600.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.layoutIfNeeded()
            XCTAssertLessThanOrEqual(panel.frame.width, MinimapSplitView.maxPanelWidth,
                                     "the panel never grows past its maximum at \(width) pt wide")
            XCTAssertEqual(panel.frame.width, 150, accuracy: 1,
                           "a window resize leaves the panel's width alone at \(width) pt wide")
        }
    }

    /// A show that lands before the split has any bounds must still open at the
    /// panel's own width: `setPanelWidth` cannot place a divider in a zero-width
    /// split, so the width is parked and applied by the first real layout.
    func testShowBeforeFirstLayoutOpensAtThePanelWidth() throws {
        let controller = MainViewController()
        let split = try XCTUnwrap(descendants(of: controller.view, MinimapSplitView.self).first)
        XCTAssertEqual(split.bounds.width, 0, "no layout has run yet")
        split.setPanelVisible(true, animated: false)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 600))
        window.layoutIfNeeded()

        let panel = try XCTUnwrap(descendants(of: window.contentView!, MinimapView.self).first)
        XCTAssertLessThanOrEqual(panel.frame.width, MinimapSplitView.maxPanelWidth,
                                 "not NSSplitView's default half-the-window split")
        XCTAssertGreaterThanOrEqual(panel.frame.width, MinimapSplitView.minPanelWidth - 1,
                                    "the parked width is applied by the first layout")
    }
}
