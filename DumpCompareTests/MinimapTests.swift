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
        removeTempFiles()
        MainViewController.overviewProgressDelay = .milliseconds(80)
        MainViewController.overviewProgressMinimumVisible = .milliseconds(300)
        if let savedLayoutIsVertical {
            LayoutSettings.set(isVertical: savedLayoutIsVertical)
        }
        NSApp.mainMenu = savedMainMenu
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        MinimapSplitView.defaults = .standard
        isolatedDefaults = nil
        super.tearDown()
    }

    /// Every file this class writes, deleted in `tearDown`: the test host is
    /// sandboxed, so these land in the app's own container and stay there — a
    /// few thousand of them had piled up before this was added.
    private var tempFiles: [URL] = []

    private func removeTempFiles() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimap-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        tempFiles.append(url)
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
                       [.flexibleSpace, .diffNavigation, .space, .toggleMinimap],
                       "flexible space pins the diff block right; a system space keeps the toggle past it")

        let toggle = toolbar.items.first { $0.itemIdentifier == .toggleMinimap }
        XCTAssertNotNil(toggle?.image, "the toggle shows the sidebar-right icon")
        XCTAssertEqual(toggle?.target as? MainViewController, wc.mainViewController)
        XCTAssertEqual(toggle?.action, #selector(MainViewController.toggleMinimap),
                       "the toggle drives the controller's minimap show/hide")

        XCTAssertNil(toolbar.items.first { $0.view != nil },
                     "no item carries a custom view: a view-backed spacer would be drawn "
                     + "inside the toggle's own background platter")
    }

    /// The toggle's button and the background capsule behind it must be the
    /// same size — the icon sits centred in a button sized for it, not pushed
    /// against the edge of a capsule stretched to swallow a neighbour (§19.1).
    func testTheMinimapToggleIsAsWideAsItsIcon() {
        let wc = MainWindowController()
        defer { wc.close() }
        guard let window = wc.window else { return XCTFail("the controller has a window") }
        window.makeKeyAndOrderFront(nil)
        _ = pumpUntil(1.5) { window.toolbar?.items.count == 4 }
        window.layoutIfNeeded()
        guard let root = window.contentView?.superview else { return XCTFail("no theme frame") }

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants(of:))
        }
        let views = descendants(of: root)
        let icon = wc.minimapToggleItem?.image
        let buttons = views.compactMap { $0 as? NSButton }
        guard let toggle = buttons.first(where: { $0.image === icon }) else {
            return XCTFail("the toolbar shows a button carrying the toggle's icon")
        }
        XCTAssertEqual(toggle.frame.width, toggle.intrinsicContentSize.width, accuracy: 1,
                       "the button is exactly as wide as it wants to be")

        // The capsule is a private view class, so match it by geometry: the
        // ancestor-level view that sits behind the button. If AppKit stops
        // drawing platters the check simply finds nothing.
        let buttonInRoot = toggle.convert(toggle.bounds, to: root)
        for platter in views where String(describing: type(of: platter)).contains("Platter") {
            let platterInRoot = platter.convert(platter.bounds, to: root)
            guard platterInRoot.intersects(buttonInRoot) else { continue }
            XCTAssertEqual(platterInRoot.width, buttonInRoot.width, accuracy: 2,
                           "the capsule behind the toggle is no wider than the button")
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
        // These tests exercise the detail window; a pair large enough to need one
        // opens in overview (§19.4), so pin detail the way the header switch does.
        controller.setMinimapRenderModeForTesting(.detail)
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
        // Most tests here exercise the detail window, and a file large enough to
        // need one opens in overview (§19.4) — so pin detail, the way a user's
        // click on the header switch would.
        controller.setMinimapRenderModeForTesting(.detail)
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
        // A 100 KB pair opens in overview (§19.4); this test is about the detail
        // window's per-pane maps.
        controller.setMinimapRenderModeForTesting(.detail)
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

        // Scroll pane 1 to the tail of the longer file. Scrolling is
        // synchronized over that file's extent (§9), so pane 2 follows past its
        // own 64 bytes and ends up showing nothing at all — the short file's
        // tail is empty.
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
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 1)?.isEmpty ?? true }
        XCTAssertTrue(panel.viewport(forMapAt: 1)?.isEmpty ?? true,
                      "the short pane scrolled along and has no bytes left to show")
        XCTAssertTrue(panel.visibleCells(forMapAt: 1).isEmpty,
                      "so its map draws nothing at this window position")
        XCTAssertFalse(panel.visibleCells(forMapAt: 0).isEmpty,
                       "while the long file's map still has content there")
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
                       "the band is exactly the pane's rows at one row-step each")
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

    /// A click on the map means the byte drawn under it, whether or not a
    /// viewport band happens to be there. The band comes from the panes' reported
    /// visible range, so it can be missing while the map is already drawing
    /// cells — and the click used to be dropped entirely in that state.
    func testAClickLandsEvenWithNoViewportBandOnTheMap() throws {
        let bytes = [UInt8](repeating: 0x41, count: 100_000)
        let (controller, window, panel) = try makeSingleFileWindow(bytes)
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        controller.windowModel.pane1.moveCaret(to: 0)
        // A pane reporting no visible range: no band, but the same cells.
        panel.setViewports([nil])
        XCTAssertTrue(panel.viewportRects().isEmpty, "no band to grab in this state")

        let point = NSPoint(x: panel.bounds.midX, y: panel.bounds.midY)
        let target = try XCTUnwrap(panel.byteOffset(at: point), "the map draws a byte there")
        XCTAssertGreaterThan(target.offset, 0, "and it is not the byte the caret already sits on")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: panel.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        panel.mouseDown(with: event)

        XCTAssertEqual(controller.windowModel.pane1.caretOffset, target.offset,
                       "the click moved the caret to the byte it landed on")
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

    // MARK: - Clicking places the caret (§19.7)

    /// A click away from the band means the byte drawn at that point: the caret
    /// moves there — row from y, column from x — and the pane centres on it.
    func testClickingTheMapMovesTheCaretToThatByte() throws {
        let bytes = [UInt8](repeating: 0x41, count: 100_000)
        let (controller, window, panel) = try makeSingleFileWindow(bytes)
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        let pane = controller.windowModel.pane1
        XCTAssertEqual(pane.hexSelection().start, 0, "the caret starts at the top")

        // A point well below the band, on the third byte column.
        let band = try XCTUnwrap(panel.viewportRects().first)
        let point = NSPoint(x: panel.bounds.midX, y: band.maxY + 40)
        let expected = try XCTUnwrap(panel.byteOffset(at: point))
        XCTAssertEqual(expected.mapIndex, 0)
        XCTAssertGreaterThan(expected.offset, 0, "the point is past the file's first byte")

        panel.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: panel))
        panel.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: panel))
        window.layoutIfNeeded()

        XCTAssertEqual(pane.hexSelection().start, expected.offset,
                       "the caret lands on the byte that was drawn under the cursor")
        // Centred: the byte sits near the middle of the pane's visible range.
        _ = pumpUntil(2.0) {
            guard let visible = panel.viewport(forMapAt: 0) else { return false }
            return visible.contains(expected.offset)
        }
        let visible = try XCTUnwrap(panel.viewport(forMapAt: 0))
        XCTAssertTrue(visible.contains(expected.offset), "the pane scrolled to it")
        let middle = visible.lowerBound + (visible.upperBound - visible.lowerBound) / 2
        let rowsOff = abs(Int64(expected.offset / 16) - Int64(middle / 16))
        XCTAssertLessThan(rowsOff, 3, "and centred it rather than putting it at an edge")
    }

    /// The byte under a point comes from the *window* mapping: row from the
    /// vertical position within the window, column from the horizontal one.
    func testByteOffsetAtPointMapsRowAndColumn() throws {
        let bytes = [UInt8](repeating: 0x41, count: 100 * 16)
        let (_, _, panel) = try makeSingleFileWindow(bytes)
        let area = NSRect(x: 0, y: 0, width: panel.bounds.width, height: panel.bounds.height)

        // Row 0, first column: the very top-left of the content.
        let first = try XCTUnwrap(panel.byteOffset(at: NSPoint(x: MinimapView.contentPadding + 1,
                                                              y: 1)))
        XCTAssertEqual(first.offset, 0, "the top-left cell is byte 0")

        // Five rows down stays in the same column.
        let down = try XCTUnwrap(panel.byteOffset(at: NSPoint(x: MinimapView.contentPadding + 1,
                                                             y: 5 * MinimapView.rowStep + 1)))
        XCTAssertEqual(down.offset, 5 * 16, "five rows down is five hex rows on")

        // The far right of the content is the row's last column.
        let right = try XCTUnwrap(panel.byteOffset(at: NSPoint(x: area.maxX - MinimapView.contentPadding - 1,
                                                              y: 1)))
        XCTAssertEqual(right.offset, 15, "the rightmost cell of row 0 is byte 15")
    }

    /// Grabbing the band is a scroll gesture, so it must not disturb the caret.
    func testDraggingTheBandLeavesTheCaretAlone() throws {
        let bytes = [UInt8](repeating: 0x41, count: 100_000)
        let (controller, window, panel) = try makeSingleFileWindow(bytes)
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        let pane = controller.windowModel.pane1
        pane.moveCaret(to: 64)
        let band = try XCTUnwrap(panel.viewportRects().first)

        panel.mouseDown(with: try mouseEvent(.leftMouseDown,
                                            at: NSPoint(x: band.midX, y: band.midY), in: panel))
        panel.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                                               at: NSPoint(x: band.midX, y: band.midY + 100),
                                               in: panel))
        panel.mouseUp(with: try mouseEvent(.leftMouseUp,
                                          at: NSPoint(x: band.midX, y: band.midY + 100), in: panel))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { (panel.viewport(forMapAt: 0)?.lowerBound ?? 0) > 0 }

        XCTAssertGreaterThan(try XCTUnwrap(panel.viewport(forMapAt: 0)).lowerBound, 0,
                             "the drag scrolled the pane")
        XCTAssertEqual(pane.hexSelection().start, 64, "and left the caret where it was")
    }

    /// In comparison mode a click on the second map targets the second pane and
    /// makes it active, so the caret it moved is the one the keyboard acts on.
    func testClickingTheSecondMapActivatesThatPane() throws {
        let (controller, window) = try makeComparisonWindow(vertical: true, sizes: (8_000, 8_000))
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.viewportRects().count == 1 }
        XCTAssertEqual(controller.windowModel.activePaneIndex, 0, "pane 1 starts active")

        // A point on the right-hand map, below the band.
        let band = try XCTUnwrap(panel.viewportRects().first)
        let point = NSPoint(x: panel.bounds.width * 0.75, y: band.maxY + 40)
        let target = try XCTUnwrap(panel.byteOffset(at: point))
        XCTAssertEqual(target.mapIndex, 1, "the point is on the second map")

        panel.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: panel))
        panel.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: panel))
        window.layoutIfNeeded()

        XCTAssertEqual(controller.windowModel.activePaneIndex, 1,
                       "clicking the second map activates its pane")
        XCTAssertEqual(controller.windowModel.pane2.hexSelection().start, target.offset,
                       "and moves that pane's caret")
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, 0,
                       "the other pane's caret is untouched")
    }

    // MARK: - Band height (§19.6)

    /// The band is exactly the rows it stands for — there is no minimum height
    /// padding it out any more.
    func testBandIsExactlyTheVisibleRowsTall() throws {
        let (_, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 100_000))
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }
        let visible = try XCTUnwrap(panel.viewport(forMapAt: 0))
        let rows = (visible.upperBound - visible.lowerBound + 15) / 16
        let band = try XCTUnwrap(panel.viewportRects().first)
        XCTAssertEqual(band.height, CGFloat(rows) * MinimapView.rowStep, accuracy: 0.51,
                       "no minimum-height clamp inflates the band")
    }

    // MARK: - View menu (§19.1)

    /// The toggle is reachable from the View menu with a key equivalent, and the
    /// item names the action it will perform rather than the current state.
    func testViewMenuCarriesTheMinimapToggle() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let viewMenu = try XCTUnwrap(NSApp.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "View" }, "the View menu")
        let item = try XCTUnwrap(viewMenu.items.first {
            $0.action == #selector(MainViewController.toggleMinimap)
        }, "a View item toggling the minimap")

        XCTAssertEqual(item.keyEquivalent, "M")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command],
                       "Command+Shift+M — Command+M is Minimize in the Window menu")

        // Hidden: the item offers to show it.
        XCTAssertTrue(controller.validateMenuItem(item), "always available")
        XCTAssertEqual(item.title, "Show Minimap")

        // Shown: the item offers to hide it.
        controller.toggleMinimap()
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Hide Minimap")
    }


    // MARK: - Accessibility (§19.8)

    /// The panel announces itself and what the panes are showing, and stays one
    /// element rather than exposing thousands of byte cells.
    func testMinimapAnnouncesWhatThePanesAreShowing() throws {
        let (_, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 100_000))
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }

        XCTAssertTrue(panel.isAccessibilityElement(), "reachable by VoiceOver")
        XCTAssertEqual(panel.accessibilityRole(), .group)
        XCTAssertEqual(panel.accessibilityRoleDescription(), "minimap")
        XCTAssertEqual(panel.accessibilityLabel(), "Minimap")
        XCTAssertNotNil(panel.accessibilityHelp(), "the pointer gestures need describing")

        let visible = try XCTUnwrap(panel.viewport(forMapAt: 0))
        let value = try XCTUnwrap(panel.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("0x" + String(visible.lowerBound, radix: 16).uppercased()),
                      "the value names the first visible offset: \(value)")
        XCTAssertTrue(value.contains("100000 bytes"), "and the file's size: \(value)")
        XCTAssertTrue(value.hasPrefix("Pane showing"), "singular for one file: \(value)")
    }

    /// Comparison speaks of both panes and both file sizes.
    func testMinimapValueCoversBothPanes() throws {
        let (_, window) = try makeComparisonWindow(vertical: true, sizes: (8_000, 4_000))
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { panel.viewport(forMapAt: 0) != nil }

        let value = try XCTUnwrap(panel.accessibilityValue() as? String)
        XCTAssertTrue(value.hasPrefix("Panes showing"), "plural for a comparison: \(value)")
        XCTAssertTrue(value.contains("8000 and 4000 bytes"),
                      "both sizes, since the two files differ: \(value)")
    }

    /// A minimap the user has turned off must not be announced: hiding collapses
    /// the panel to zero width instead of removing it from the hierarchy.
    func testHiddenPanelIsNotAnAccessibilityElement() throws {
        let (_, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 64))
        XCTAssertTrue(panel.isAccessibilityElement(), "shown: announced")

        let (split, _) = try minimapViews(window)
        split.setPanelVisible(false, animated: false)
        window.layoutIfNeeded()
        XCTAssertFalse(panel.isAccessibilityElement(), "hidden: not announced")
    }

    /// With nothing open there is nothing to describe.
    func testMinimapValueWithNoFileOpen() throws {
        let (_, window) = try makeController()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.accessibilityValue() as? String, "No file open.")
    }


    // MARK: - The short file's tail is empty (§9)

    /// With files of different lengths both panes scroll over the longer file, so
    /// the shorter pane ends up past its own EOF. What it must show there is
    /// nothing at all — no bytes, no offsets, no EOF hatch: the hatch marks the
    /// end on the last partial row, and repeating it for thousands of rows would
    /// be noise. Rendered through the real `draw(_:)` and checked for uniformity.
    func testShortFileTailRendersEmpty() throws {
        let (_, window) = try makeComparisonWindow(vertical: true, sizes: (8_000, 64))
        window.layoutIfNeeded()
        let hexViews = descendants(of: window.contentView!, HexView.self)
        XCTAssertEqual(hexViews.count, 2, "two panes")
        let longHex = hexViews[0], shortHex = hexViews[1]

        // Both documents span the longer file, so the short pane can be scrolled
        // past its 64 bytes at all.
        XCTAssertEqual(shortHex.hexContentHeight, longHex.hexContentHeight, accuracy: 0.5,
                       "the panes share one scrollable extent")

        let clip = try XCTUnwrap(longHex.enclosingScrollView?.contentView)
        clip.setBoundsOrigin(NSPoint(x: 0, y: max(longHex.hexContentHeight - clip.bounds.height, 0)))
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { shortHex.visibleByteRange().isEmpty }

        XCTAssertTrue(shortHex.visibleByteRange().isEmpty,
                      "the short pane is scrolled past its own end")
        XCTAssertFalse(longHex.visibleByteRange().isEmpty,
                       "while the long pane still has bytes on screen")

        /// Whether every pixel of the view's visible rect is the same colour.
        func isUniform(_ view: HexView) throws -> Bool {
            let rect = try XCTUnwrap(view.enclosingScrollView?.documentVisibleRect)
            guard rect.width > 1, rect.height > 1 else { return true }
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: rep)
            let first = rep.colorAt(x: 0, y: 0)
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                    if rep.colorAt(x: x, y: y) != first { return false }
                }
            }
            return true
        }

        XCTAssertTrue(try isUniform(shortHex),
                      "the short file's tail is blank — nothing is drawn past its end")
        XCTAssertFalse(try isUniform(longHex),
                       "the long file's rows are still drawn, so the check can fail")
    }


    // MARK: - Overview mode (§19.4)

    /// A file with a 0xFF-padded half and a content half, big enough that the
    /// detail window could only ever show a sliver of it.
    private func makeOverviewWindow(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, MinimapView) {
        let (controller, window, panel) = try makeSingleFileWindow(bytes)
        controller.setMinimapRenderModeForTesting(.overview)
        window.layoutIfNeeded()
        _ = pumpUntil(3.0) { (panel.overviewSummaries.first?.rowCount ?? 0) > 0 }
        return (controller, window, panel)
    }

    /// The overview shades each cell by how much real content its slice holds, so
    /// erased padding and programmed regions separate — the thing a boolean
    /// "any significant byte" aggregation could not show on a large dump.
    /// The overview picture for `bytes` binned into `rowCount` pixel rows, taken
    /// from the binning pass itself so the row count is exact rather than
    /// whatever the test window happens to give the panel.
    private func overviewPicture(bytes: [UInt8], rowCount: Int,
                                 differences: [Range<UInt64>] = [])
        -> (density: [UInt8], modified: [UInt16], different: [UInt16])? {
        let source = MainViewController.OverviewSource(
            storage: MemoryBackedStorage(bytes: bytes), saved: nil,
            size: UInt64(bytes.count), edited: [], isUntitled: true,
            differences: differences
        )
        return MainViewController.overviewRows(source: source, extent: UInt64(bytes.count),
                                               rowCount: rowCount, rows: 0...(rowCount - 1))
    }

    /// A file smaller than the panel's pixel rows: every row stands for a
    /// fraction of a byte, so the picture must be that byte across the row's
    /// full width. Slicing the row per cell gave every cell but the last an
    /// empty byte range — the whole file collapsed into a stripe down the right
    /// edge, with the rest of the panel a pale field (§19.4.2).
    func testATinyFilesOverviewFillsTheRowWidth() throws {
        let columns = Int(MinimapView.bytesPerRow)
        let bytes = (0..<399).map { UInt8(0x41 + ($0 % 26)) }   // all significant
        let rowCount = 1560                                     // a full-height panel
        let picture = try XCTUnwrap(overviewPicture(bytes: bytes, rowCount: rowCount))

        var inkPerColumn = [Int](repeating: 0, count: columns)
        var blankRows = 0
        for row in 0..<rowCount {
            var inked = 0
            for column in 0..<columns where picture.density[row * columns + column] > 0 {
                inkPerColumn[column] += 1
                inked += 1
            }
            if inked == 0 { blankRows += 1 }
        }
        XCTAssertEqual(blankRows, 0, "a dense file leaves no row of the picture empty")
        XCTAssertEqual(inkPerColumn.first, inkPerColumn.last,
                       "the ink spreads across the row instead of collecting at its right edge")
        XCTAssertEqual(Set(inkPerColumn).count, 1, "every column carries the same picture here")
    }

    /// The stretch must not simply paint everything: a small file's erased half
    /// stays pale and only its content half takes ink, and a one-byte difference
    /// marks the row it owns across the full width (at this scale one byte *is*
    /// the row).
    func testATinyFileKeepsFillAndContentApart() throws {
        let columns = Int(MinimapView.bytesPerRow)
        let bytes = [UInt8](repeating: 0xFF, count: 200)
            + (0..<199).map { UInt8(0x41 + ($0 % 26)) }
        let rowCount = 1560
        let boundary = 200 * rowCount / bytes.count
        let picture = try XCTUnwrap(overviewPicture(bytes: bytes, rowCount: rowCount,
                                                    differences: [210..<211]))

        func inked(_ row: Int) -> Bool {
            (0..<columns).contains { picture.density[row * columns + $0] > 0 }
        }
        XCTAssertFalse((0..<(boundary - 1)).contains(where: inked),
                       "the erased half stays pale")
        XCTAssertTrue(((boundary + 1)..<rowCount).allSatisfy(inked),
                      "the content half takes ink")

        let marked = picture.different.enumerated().filter { $0.element != 0 }
        XCTAssertEqual(marked.count, 1, "one differing byte marks one row of the picture")
        XCTAssertEqual(marked.first?.element, UInt16.max,
                       "and marks it across the width, not as a single cell at column 0")
    }

    /// A row that covers fewer bytes than it has cells, but more than one: the
    /// bytes divide the row's width between them (~15 bytes per row is what a
    /// few-KB dump gives a full-height panel).
    func testARowThinnerThanItsCellsDividesItsWidth() throws {
        let columns = Int(MinimapView.bytesPerRow)
        // 15 bytes per row, and only the first byte of each row is significant.
        let rowCount = 20
        var bytes = [UInt8](repeating: 0x00, count: rowCount * 15)
        for row in 0..<rowCount { bytes[row * 15] = 0x41 }
        let picture = try XCTUnwrap(overviewPicture(bytes: bytes, rowCount: rowCount))

        for row in 0..<rowCount {
            let inked = (0..<columns).filter { picture.density[row * columns + $0] > 0 }
            XCTAssertEqual(inked, [0],
                           "the significant byte inks the left of the row, row \(row)")
        }
    }

    func testOverviewShadesPaddingAndContentDifferently() throws {
        // 256 KB: first half erased flash (0xFF), second half content.
        let half = 128 * 1024
        var bytes = [UInt8](repeating: 0xFF, count: half)
        bytes += (0..<half).map { UInt8(0x41 + ($0 % 26)) }
        let (_, _, panel) = try makeOverviewWindow(bytes)

        let summary = try XCTUnwrap(panel.overviewSummaries.first)
        XCTAssertEqual(summary.extent, UInt64(bytes.count))
        XCTAssertGreaterThan(summary.rowCount, 100, "the panel bins the file into pixel rows")
        XCTAssertEqual(summary.density.count, summary.rowCount * 16)

        func rowDensity(_ row: Int) -> Int {
            (0..<16).map { Int(summary.density[row * 16 + $0]) }.reduce(0, +)
        }
        // A row well inside the erased half carries nothing; one inside the
        // content half is saturated.
        let paddingRow = summary.rowCount / 4
        let contentRow = summary.rowCount * 3 / 4
        XCTAssertEqual(rowDensity(paddingRow), 0, "0xFF padding reads as empty")
        XCTAssertGreaterThan(rowDensity(contentRow), 16 * 200, "content reads as dense")
    }

    /// Which mode a file opens in comes from the file itself (§19.4): a dump goes
    /// to the whole-file overview, a few hundred bytes to the per-byte detail
    /// window. Nothing is remembered, so however the panel was left, the next
    /// file decides again.
    func testTheModeIsChosenFromTheFileSize() throws {
        let smallURL = try tempFile([UInt8](repeating: 0x41, count: 399))
        let bigURL = try tempFile([UInt8](repeating: 0x41, count: 256 * 1024))
        let (controller, window) = try makeController()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        try controller.windowModel.pane1.open(url: bigURL)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.renderMode, .overview, "a dump opens in overview")

        try controller.windowModel.pane1.open(url: smallURL)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.renderMode, .detail,
                       "and a small file opens in detail, however the panel was left")
    }

    /// The size rule decides on its own account, not just where the overview
    /// would magnify: a couple of kilobytes is a file the overview *could*
    /// compress, and detail is still the better view of it (§19.4).
    func testAFileTheOverviewCouldCompressStillOpensInDetail() throws {
        let bytes = [UInt8](repeating: 0x41, count: 2 * 1024)
        XCTAssertLessThanOrEqual(UInt64(bytes.count), MinimapView.detailPreferredMaxSize)
        let url = try tempFile(bytes)
        let (controller, window) = try makeController()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()

        XCTAssertTrue(panel.overviewIsInformative(),
                      "2 KB over this panel's rows is still a compression, so the "
                      + "availability gate is not what decides here")
        XCTAssertEqual(panel.renderMode, .detail, "the size rule picks detail")
    }

    /// A choice by hand holds while the file does, and nothing is remembered
    /// beyond it: the next file decides for itself again (§19.4). The screenshot
    /// that started this was a 399-byte file opening in overview, because a toggle
    /// made for some earlier dump had been persisted.
    func testAModeChoiceHoldsForTheFileAndIsNotRemembered() throws {
        let (controller, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 256 * 1024))
        controller.setMinimapRenderModeForTesting(.overview)
        controller.toggleMinimapOverview()
        XCTAssertEqual(panel.renderMode, .detail, "the toggle switches to detail")

        // Another dump: the size decides again, the earlier choice is gone.
        let url = try tempFile([UInt8](repeating: 0x42, count: 512 * 1024))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.renderMode, .overview, "the new file's size decides")
    }

    /// Overview is not offered for a file it could only magnify: below one byte
    /// per pixel row it stretches each byte over several rows and says less than
    /// the detail window, which shows such a file whole (§19.4). The switch's
    /// Overview half and the menu item are both disabled, and the command does
    /// nothing.
    func testOverviewIsNotOfferedForAFileItWouldMagnify() throws {
        let (controller, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 399))
        let chrome = try XCTUnwrap(descendants(of: window.contentView!, MinimapPanelView.self).first)
        XCTAssertFalse(panel.overviewIsInformative(),
                       "399 bytes over a panel's worth of pixel rows is magnification")
        XCTAssertFalse(chrome.modeSwitch.isEnabled(forSegment: 1),
                       "the Overview half of the switch is greyed out")
        let item = NSMenuItem(title: "Minimap Overview",
                              action: #selector(MainViewController.toggleMinimapOverview),
                              keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item), "and so is the menu item")

        controller.toggleMinimapOverview()
        XCTAssertEqual(panel.renderMode, .detail, "the command cannot enter it either")
    }

    /// And it is offered for a dump, which it compresses.
    func testOverviewIsOfferedForADumpItCompresses() throws {
        let (controller, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 256 * 1024))
        let chrome = try XCTUnwrap(descendants(of: window.contentView!, MinimapPanelView.self).first)
        XCTAssertTrue(panel.overviewIsInformative())
        XCTAssertTrue(chrome.modeSwitch.isEnabled(forSegment: 1))
        let item = NSMenuItem(title: "Minimap Overview",
                              action: #selector(MainViewController.toggleMinimapOverview),
                              keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    /// The offer follows the *file's* size too, not just the panel's height: an
    /// insert can carry a file across the line where the overview stops
    /// magnifying it, and a delete can carry it back (§19.4).
    func testAnEditThatChangesTheFileSizeUpdatesTheOffer() throws {
        let (controller, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 400))
        let chrome = try XCTUnwrap(descendants(of: window.contentView!, MinimapPanelView.self).first)
        XCTAssertFalse(chrome.modeSwitch.isEnabled(forSegment: 1), "400 bytes would be magnified")

        try controller.windowModel.pane1.pasteInsert([UInt8](repeating: 0x42, count: 64 * 1024))
        window.layoutIfNeeded()
        XCTAssertTrue(panel.overviewIsInformative())
        XCTAssertTrue(chrome.modeSwitch.isEnabled(forSegment: 1),
                      "a file grown to 64 KB is worth an overview")

        // And back: cut it down again, from overview this time.
        controller.setMinimapRenderModeForTesting(.overview)
        try controller.windowModel.pane1.deleteBytes(in: 0..<(64 * 1024))
        window.layoutIfNeeded()
        XCTAssertFalse(chrome.modeSwitch.isEnabled(forSegment: 1),
                       "shrunk back, the overview has nothing to compress")
        XCTAssertEqual(panel.renderMode, .detail, "so the map leaves it")
    }

    /// A panel grown tall enough to magnify the file it is showing must not stay
    /// in overview: the map leaves it, so the panel is never parked in a view its
    /// own switch refuses to offer (§19.4). The file is sized from the panel's own
    /// row counts, so the test does not depend on the chrome's exact height.
    func testGrowingThePanelPastTheFileLeavesOverview() throws {
        let (controller, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 256 * 1024))
        let shortRows = panel.overviewRowCount()
        window.setContentSize(NSSize(width: 800, height: 1100))
        window.layoutIfNeeded()
        let tallRows = panel.overviewRowCount()
        XCTAssertGreaterThan(tallRows, shortRows, "the taller window bins more rows")

        // A file the short panel compresses and the tall one would magnify.
        let size = (shortRows + tallRows) / 2
        let url = try tempFile([UInt8](repeating: 0x41, count: size))
        window.setContentSize(NSSize(width: 800, height: 600))
        window.layoutIfNeeded()
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertEqual(panel.renderMode, .overview, "the short panel still compresses it")

        window.setContentSize(NSSize(width: 800, height: 1100))
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(1.0) { panel.renderMode == .detail },
                      "grown past the file, the map leaves overview")
    }

    /// Differences come from the comparison index rather than from re-reading
    /// both files, and land on the rows that cover them.
    func testOverviewMarksDifferencesFromTheIndex() throws {
        let size = 256 * 1024
        let a = [UInt8](repeating: 0x41, count: size)
        var b = a
        // Differ over the middle eighth of the file.
        for i in (size / 2)..<(size * 5 / 8) { b[i] = 0x42 }
        let url1 = try tempFile(a), url2 = try tempFile(b)
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        _ = pumpUntil(5.0) {
            guard let summary = panel.overviewSummaries.first, summary.rowCount > 0 else { return false }
            return summary.different.contains { $0 != 0 }
        }
        let summary = try XCTUnwrap(panel.overviewSummaries.first)
        let marked = summary.different.enumerated().filter { $0.element != 0 }.map(\.offset)
        XCTAssertFalse(marked.isEmpty, "the differing region is marked")
        let firstMarked = try XCTUnwrap(marked.min())
        let lastMarked = try XCTUnwrap(marked.max())
        let rows = Double(summary.rowCount)
        XCTAssertEqual(Double(firstMarked) / rows, 0.5, accuracy: 0.02,
                       "marks start where the region does")
        XCTAssertEqual(Double(lastMarked) / rows, 0.625, accuracy: 0.02,
                       "and end where it ends")
        XCTAssertTrue(summary.modified.allSatisfy { $0 == 0 }, "nothing was edited")
    }

    /// A typed byte marks its cell, without a whole-file comparison.
    func testOverviewMarksAModifiedByte() throws {
        let (controller, _, panel) = try makeOverviewWindow([UInt8](repeating: 0x41, count: 256 * 1024))
        XCTAssertTrue(try XCTUnwrap(panel.overviewSummaries.first).modified.allSatisfy { $0 == 0 })

        let offset: UInt64 = 200 * 1024
        controller.windowModel.pane1.moveCaret(to: offset)
        controller.windowModel.pane1.typeASCII(0x5A)
        _ = pumpUntil(3.0) {
            panel.overviewSummaries.first?.modified.contains { $0 != 0 } ?? false
        }
        let summary = try XCTUnwrap(panel.overviewSummaries.first)
        let marked = summary.modified.enumerated().filter { $0.element != 0 }.map(\.offset)
        XCTAssertEqual(marked.count, 1, "one cell, not a smear")
        let row = try XCTUnwrap(marked.first)
        XCTAssertEqual(Double(row) / Double(summary.rowCount),
                       Double(offset) / Double(256 * 1024), accuracy: 0.01,
                       "on the row that covers the edited byte")
    }

    /// A visible page is a fraction of a pixel on a dump, so in overview the band
    /// gets a floor and reads as a position marker.
    func testOverviewViewportBandHasAPixelFloor() throws {
        let (_, _, panel) = try makeOverviewWindow([UInt8](repeating: 0x41, count: 256 * 1024))
        _ = pumpUntil(2.0) { !panel.viewportRects().isEmpty }
        let band = try XCTUnwrap(panel.viewportRects().first)
        // A page of this file measures a shade over one pixel, so the floor is
        // not what decides the height here — but the band must never fall below
        // it, which is the guarantee that keeps it findable on a real dump.
        XCTAssertGreaterThanOrEqual(band.height, 2 * panel.overviewRowHeight)
        XCTAssertLessThan(band.height, 5, "and it stays a marker, not a slab")
        XCTAssertEqual(band.minY, 0, accuracy: panel.overviewRowHeight,
                       "sitting at the top while the pane is at the file's start")
    }

    /// Clicking the overview means the byte at that height, so the caret lands
    /// proportionally into the file — the map is the whole of it.
    func testClickingTheOverviewJumpsProportionally() throws {
        let size = 256 * 1024
        let (controller, window, panel) = try makeOverviewWindow([UInt8](repeating: 0x41, count: size))
        let target = try XCTUnwrap(panel.byteOffset(at: NSPoint(x: panel.bounds.midX,
                                                               y: panel.bounds.height * 0.75)))
        XCTAssertEqual(Double(target.offset) / Double(size), 0.75, accuracy: 0.02,
                       "three quarters down the map is three quarters into the file")

        panel.mouseDown(with: try mouseEvent(.leftMouseDown,
                                            at: NSPoint(x: panel.bounds.midX,
                                                        y: panel.bounds.height * 0.75),
                                            in: panel))
        panel.mouseUp(with: try mouseEvent(.leftMouseUp,
                                          at: NSPoint(x: panel.bounds.midX,
                                                      y: panel.bounds.height * 0.75),
                                          in: panel))
        window.layoutIfNeeded()
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, target.offset,
                       "and the caret goes there")
    }

    /// The View menu carries the mode as a checked item — both modes are a
    /// minimap, so the check reads as "which one".
    func testViewMenuChecksTheOverviewMode() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)
        let viewMenu = try XCTUnwrap(NSApp.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "View" })
        let item = try XCTUnwrap(viewMenu.items.first {
            $0.action == #selector(MainViewController.toggleMinimapOverview)
        }, "a View item switching the minimap's mode")
        XCTAssertEqual(item.keyEquivalent, "m")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])

        controller.setMinimapRenderModeForTesting(.detail)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)

        controller.setMinimapRenderModeForTesting(.overview)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
    }

    /// The stand-in must draw the picture in the same colour as the exact pass,
    /// channel for channel. Comparing a long file against a much shorter one
    /// makes the long map's tail one solid column of differences, which is where
    /// any difference in how the translucent fill is composited shows: two ways
    /// of getting it wrong were a single flattened pass per pixel (too pale,
    /// alpha 0.35 where the exact pass reaches 0.58 by drawing events two pixels
    /// tall) and compositing in a generic colour space rather than the window's
    /// (too saturated). Both were visible to the eye during a resize (§19.9).
    func testTheStandInMatchesTheExactColourOfASolidDifferenceColumn() throws {
        let long = (0..<(512 * 1024)).map { UInt8(0x20 + ($0 % 90)) }
        let short = [UInt8](long[0..<(32 * 1024)])
        let url1 = try tempFile(long), url2 = try tempFile(short)
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        LayoutSettings.set(isVertical: true)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(10.0) {
            panel.overviewSummaries.first?.rowCount == panel.overviewRowCount()
                && (panel.overviewSummaries.first?.different.contains { $0 != 0 } ?? false)
        }, "the exact picture with its difference column arrives")

        /// The mean colour across the long map's tail — the solid column.
        func columnColour() throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            var samples: [NSColor] = []
            for step in 0..<12 {
                let y = panel.bounds.height * (0.45 + 0.04 * CGFloat(step))
                samples += try sampleRowColours(panel, y: y,
                                                from: MinimapView.contentPadding + 2,
                                                to: panel.bounds.width * 0.45)
            }
            XCTAssertGreaterThan(samples.count, 100, "enough pixels to judge")
            let n = CGFloat(samples.count)
            return (samples.reduce(0) { $0 + $1.redComponent } / n,
                    samples.reduce(0) { $0 + $1.greenComponent } / n,
                    samples.reduce(0) { $0 + $1.blueComponent } / n)
        }
        let exact = try columnColour()
        XCTAssertGreaterThan(exact.r - exact.b, 0.1,
                             "the tail really is a solid orange difference: \(exact)")

        // Resize so the stand-in takes over, and measure the same column.
        var frame = window.frame
        frame.size.height += 40
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
        XCTAssertNotEqual(panel.overviewSummaries.first?.rowCount, panel.overviewRowCount(),
                          "the summary is stale, so the stand-in is what draws")
        let stretched = try columnColour()
        XCTAssertEqual(stretched.r, exact.r, accuracy: 0.01, "red: \(stretched) vs \(exact)")
        XCTAssertEqual(stretched.g, exact.g, accuracy: 0.01, "green: \(stretched) vs \(exact)")
        XCTAssertEqual(stretched.b, exact.b, accuracy: 0.01, "blue: \(stretched) vs \(exact)")
    }

    /// The shorter file's tail is empty in overview, the way it already is in
    /// detail (§9). The comparison index spans the *union* of the two files, so
    /// every byte past the shorter file's end is a difference in it — painted as
    /// one, the shorter map's tail came out solid diff instead of blank.
    func testOverviewLeavesTheShortFilesTailEmpty() throws {
        // Identical content where both files have bytes: the only "differences"
        // are the ones the missing tail creates.
        let long = (0..<(256 * 1024)).map { UInt8(0x20 + ($0 % 90)) }
        let short = [UInt8](long[0..<(128 * 1024)])
        let url1 = try tempFile(long), url2 = try tempFile(short)
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        LayoutSettings.set(isVertical: true)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(10.0) {
            (panel.overviewSummaries.last?.rowCount ?? 0) == panel.overviewRowCount()
        }, "the overview arrives")

        // The shorter file is the second map; its summary must claim nothing
        // beyond its own half of the extent.
        let summary = try XCTUnwrap(panel.overviewSummaries.last)
        let ownRows = summary.rowCount / 2
        for row in (ownRows + 1)..<summary.rowCount {
            XCTAssertEqual(summary.different[row], 0, "row \(row) is past the file's end")
            XCTAssertEqual(summary.modified[row], 0, "row \(row) is past the file's end")
        }
        // The longer file's own map keeps those differences: past the shorter
        // file's end it holds bytes the other file does not have, which is a
        // difference on *its* map — the same asymmetry the panes show.
        let longSummary = try XCTUnwrap(panel.overviewSummaries.first)
        XCTAssertTrue(longSummary.different[(ownRows + 2)...].contains { $0 != 0 },
                      "the longer file's tail differs, because the other file ends")

        // Pixels: the shorter map's tail carries no orange, while the longer
        // map's tail at the same height does.
        let tail = try sampleRowColours(panel, y: panel.bounds.height * 0.85,
                                        from: panel.bounds.width * 0.55,
                                        to: panel.bounds.width - MinimapView.contentPadding - 2)
        XCTAssertGreaterThan(tail.count, 20, "enough pixels to judge")
        let longTail = try sampleRowColours(panel, y: panel.bounds.height * 0.85,
                                            from: MinimapView.contentPadding + 2,
                                            to: panel.bounds.width * 0.45)
        let shortMax = tail.map(orangeness).max() ?? 0
        let longMax = longTail.map(orangeness).max() ?? 0
        XCTAssertLessThan(shortMax, 0.02,
                          "the short file's tail is blank, not a difference: \(shortMax)")
        XCTAssertGreaterThan(longMax, 0.05,
                             "while the longer file's tail is marked as one: \(longMax)")
    }

    // MARK: - Overview tone and overlays (§19.4.2, §19.6)

    /// The shading stays inside the tonal band the dump itself occupies: a slice
    /// of pure padding is drawn muted rather than left blank, and a full slice
    /// stops well short of solid ink. Black-on-white read nothing like the dump.
    func testOverviewToneStaysInTheDumpsRange() {
        XCTAssertEqual(MinimapView.overviewTone(density: 0), MinimapView.overviewMinTone,
                       accuracy: 0.001, "padding inside the file is muted, not blank")
        XCTAssertEqual(MinimapView.overviewTone(density: 255), MinimapView.overviewMaxTone,
                       accuracy: 0.001, "a full slice stops short of solid ink")
        XCTAssertLessThan(MinimapView.overviewMaxTone, 0.7, "never near-black")
        XCTAssertGreaterThan(MinimapView.overviewMinTone, 0.0, "never bare paper")
        // Monotonic, and a sparse slice separates from an empty one.
        let steps = (0...255).map { MinimapView.overviewTone(density: UInt8($0)) }
        XCTAssertEqual(steps, steps.sorted(), "tone rises with density")
        XCTAssertGreaterThan(MinimapView.overviewTone(density: 20) - MinimapView.overviewMinTone,
                            0.03, "a sparse slice is distinguishable from empty")
    }

    /// The same line as `sampleRow`, as colours rather than brightness. Needed
    /// where the thing being told apart is a *hue*: the difference fill is a
    /// translucent orange, whose brightness over white paper is within a few
    /// percent of the paper's own.
    private func sampleRowColours(_ panel: MinimapView, y: CGFloat,
                                  from: CGFloat, to: CGFloat) throws -> [NSColor] {
        let rep = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / panel.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / panel.bounds.height
        let py = min(max(Int(y * scaleY), 0), rep.pixelsHigh - 1)
        let first = max(0, Int((from * scaleX).rounded(.down)))
        let last = min(rep.pixelsWide - 1, Int((to * scaleX).rounded(.up)))
        guard last >= first else { return [] }
        return (first...last).compactMap { rep.colorAt(x: $0, y: py)?.usingColorSpace(.deviceRGB) }
    }

    /// How orange a sample is compared with the panel's paper — the difference
    /// fill's giveaway, since it is orange over paper.
    private func orangeness(_ colour: NSColor) -> CGFloat {
        colour.redComponent - colour.blueComponent
    }

    /// Samples a horizontal line of the rendered panel inside one map's content.
    /// Every *device* pixel of the line, not every point: a seam between two
    /// cells is one pixel wide, so sampling by points steps straight over it —
    /// which is how the first version of this test passed against the bug it was
    /// written for.
    private func sampleRow(_ panel: MinimapView, y: CGFloat,
                           from: CGFloat, to: CGFloat) throws -> [CGFloat] {
        let rep = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / panel.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / panel.bounds.height
        let py = min(max(Int(y * scaleY), 0), rep.pixelsHigh - 1)
        let firstPixel = max(0, Int((from * scaleX).rounded(.down)))
        let lastPixel = min(rep.pixelsWide - 1, Int((to * scaleX).rounded(.up)))
        guard lastPixel >= firstPixel else { return [] }
        return (firstPixel...lastPixel).compactMap { px -> CGFloat? in
            guard let colour = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return nil }
            return colour.brightnessComponent
        }
    }

    /// A solid region must render solid. The cells are snapped to the pixel grid
    /// in absolute coordinates and each measured to the next boundary; a shared
    /// width, or snapping relative to the content, left hairline gaps that read as
    /// vertical stripes — and only on the second map, whose content starts after a
    /// fractional gutter.
    func testOverviewRendersASolidRegionWithoutStripes() throws {
        // Every byte is content, so every cell of every row is fully dense.
        let bytes = (0..<(256 * 1024)).map { UInt8(0x20 + ($0 % 90)) }
        let url1 = try tempFile(bytes), url2 = try tempFile(bytes)
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        LayoutSettings.set(isVertical: true)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        // A width whose sixteenth is not a whole number of pixels — the case that
        // produced the stripes.
        split.setPanelWidth(203, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(10.0) { (panel.overviewSummaries.last?.rowCount ?? 0) > 0 }

        // Sample across the *second* map, away from the viewport marker's rows.
        let y = panel.bounds.height * 0.6
        let start = panel.bounds.width * 0.55
        let end = panel.bounds.width - MinimapView.contentPadding - 2
        let samples = try sampleRow(panel, y: y, from: start, to: end)
        XCTAssertGreaterThan(samples.count, 20, "enough pixels to judge")
        let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
        // Measured: 0.0 with pixel-snapped absolute edges and per-column widths;
        // 0.037 with edges snapped relative to the content (the second map's
        // fractional origin puts every boundary mid-pixel, and two half-covered
        // fills of one colour compose lighter than one solid fill); 0.257 with a
        // single shared width, which leaves real gaps. A loose threshold passed
        // all three, so it is pinned just above zero.
        XCTAssertLessThan(spread, 0.01, "a solid region has no seams: spread \(spread)")
    }

    /// The overview marks the viewport with a chevron in each margin and draws
    /// nothing across the content: on a dump every row of the picture counts, and
    /// a band spanning the panel costs one.
    func testOverviewViewportDoesNotCoverContent() throws {
        let bytes = (0..<(256 * 1024)).map { UInt8(0x20 + ($0 % 90)) }
        let (_, _, panel) = try makeOverviewWindow(bytes)
        _ = pumpUntil(3.0) { !panel.viewportRects().isEmpty }
        let band = try XCTUnwrap(panel.viewportRects().first)

        // Inside the content, the band's own rows look like every other row.
        // The marker never reaches the content: its apex stops
        // `overviewMarkerInset` short of the content edge, so a sample from just
        // inside the padding carries nothing but the map.
        let left = MinimapView.contentPadding + 2
        let right = panel.bounds.width * 0.4
        let onBand = try sampleRow(panel, y: band.midY, from: left, to: right)
        let elsewhere = try sampleRow(panel, y: band.midY + 20, from: left, to: right)
        let onBandMean = onBand.reduce(0, +) / CGFloat(max(1, onBand.count))
        let elsewhereMean = elsewhere.reduce(0, +) / CGFloat(max(1, elsewhere.count))
        XCTAssertEqual(onBandMean, elsewhereMean, accuracy: 0.05,
                       "the content under the viewport is not dimmed by a band")

        // The margin at that height carries the marker instead, up to
        // `overviewMarkerInset` before the content edge. The marker is the
        // band's edge grey, dark against the light paper.
        let markerEnd = MinimapView.contentPadding - MinimapView.overviewMarkerInset - 1
        let margin = try sampleRow(panel, y: band.midY, from: 0, to: markerEnd)
        let cleanMargin = try sampleRow(panel, y: band.midY + 20, from: 0, to: markerEnd)
        let marginMin = margin.min() ?? 1
        let cleanMin = cleanMargin.min() ?? 1
        XCTAssertLessThan(marginMin, cleanMin - 0.1,
                          "a chevron is drawn in the margin at the viewport's height")
        // The arrow stops short of the map: the sliver between its apex and the
        // content edge stays paper, so the marker points at the map without
        // touching it. Sampled one point short of the content edge — the edge
        // itself is the first cell of the map, whose grey is as dark as ink.
        let gap = try sampleRow(panel, y: band.midY,
                                from: MinimapView.contentPadding - 1,
                                to: MinimapView.contentPadding - 1)
        let gapMin = gap.min() ?? 0
        XCTAssertGreaterThan(gapMin, cleanMin - 0.1,
                             "the apex leaves a gap before the map's edge")
    }

    /// A small file projects its viewport onto the overview as a band taller
    /// than `overviewBandTallHeight`, so it is drawn as a real rectangle like
    /// the detail band: the rows under it are dimmed by the translucent fill,
    /// and no chevron stands in the margin at that height.
    func testOverviewDrawsTallViewportBandAsARectangle() throws {
        let (_, _, panel) = try makeOverviewWindow([UInt8](repeating: 0x41, count: 16 * 1024))
        _ = pumpUntil(3.0) { !panel.viewportRects().isEmpty }
        let band = try XCTUnwrap(panel.viewportRects().first)
        XCTAssertGreaterThan(band.height, MinimapView.overviewBandTallHeight,
                             "a 16 KB file's visible page reads as a tall band")

        // The band dims the content under it, like the detail band.
        let left = MinimapView.contentPadding + 2
        let right = panel.bounds.width * 0.4
        let onBand = try sampleRow(panel, y: band.midY, from: left, to: right)
        let elsewhere = try sampleRow(panel, y: band.midY + 40, from: left, to: right)
        let onBandMean = onBand.reduce(0, +) / CGFloat(max(1, onBand.count))
        let elsewhereMean = elsewhere.reduce(0, +) / CGFloat(max(1, elsewhere.count))
        XCTAssertLessThan(onBandMean, elsewhereMean - 0.02,
                          "the tall band is a translucent rectangle over the cells")

        // And no chevron stands in the margin at that height: the margin carries
        // only the same translucent fill over paper, which a full-strength
        // chevron would be far darker than.
        let margin = try sampleRowColours(panel, y: band.midY, from: 0,
                                          to: MinimapView.contentPadding - 1)
        let marginMin = margin.map { $0.brightnessComponent }.min() ?? 1
        XCTAssertGreaterThan(marginMin, 0.6,
                             "the tall band replaced the chevrons in the margin")
    }

    /// The rectangle/chevron split is sticky: a band whose height falls between
    /// the two edges keeps whichever look it already has, so a scroll hovering
    /// on the boundary does not flip between rectangle and chevrons every frame.
    /// The band's height is a fraction of the file's extent, so the viewport can
    /// be driven directly to a height on either side of the hysteresis zone.
    func testOverviewViewportStyleIsStickyAcrossTheHysteresisZone() throws {
        let (_, _, panel) = try makeOverviewWindow([UInt8](repeating: 0x41, count: 64 * 1024))
        let extent = try XCTUnwrap(panel.overviewSummaries.first?.extent)
        let totalHeight = CGFloat(panel.overviewRowCount()) * panel.overviewRowHeight
        XCTAssertGreaterThan(totalHeight, MinimapView.overviewBandTallHeight,
                             "precondition: the map has room for a band above the zone")

        // How many bytes a viewport must show for its band to stand `height` pt
        // tall: y(of:) scales a fraction of the extent over the whole map, so
        // height = viewportBytes / extent * totalHeight.
        func bytes(forHeight height: CGFloat) -> UInt64 {
            UInt64(CGFloat(extent) * height / totalHeight)
        }

        func band(forViewport viewport: Range<UInt64>) -> NSRect {
            panel.setViewports([viewport])
            return panel.viewportRects().first ?? .zero
        }

        /// Whether `band` reads as a rectangle over the content: the rows under
        /// it are dimmed relative to a reference row below it. A sliver drawn as
        /// chevrons leaves the content untouched.
        func drawsAsRectangle(_ band: NSRect) throws -> Bool {
            let left = MinimapView.contentPadding + 2
            let right = panel.bounds.width * 0.4
            let onBand = try sampleRow(panel, y: band.midY, from: left, to: right)
            let reference = try sampleRow(panel, y: band.midY + 40, from: left, to: right)
            let onMean = onBand.reduce(0, +) / CGFloat(max(1, onBand.count))
            let referenceMean = reference.reduce(0, +) / CGFloat(max(1, reference.count))
            return onMean < referenceMean - 0.02
        }

        // A fresh panel starts with the sliver look. Drive the band far above
        // the upper edge: it becomes a rectangle.
        let tall = band(forViewport: 0..<bytes(forHeight: 6))
        XCTAssertGreaterThan(tall.height, MinimapView.overviewBandTallHeight,
                             "precondition: a 6 pt band sits above the hysteresis zone")
        XCTAssertTrue(try drawsAsRectangle(tall), "a band above the zone is a rectangle")

        // Waver back down into the zone: the rectangle sticks.
        let midDown = band(forViewport: 0..<bytes(forHeight: 4.5))
        XCTAssertGreaterThan(midDown.height, MinimapView.overviewBandShortHeight)
        XCTAssertLessThan(midDown.height, MinimapView.overviewBandTallHeight,
                          "precondition: a 4.5 pt band sits inside the hysteresis zone")
        XCTAssertTrue(try drawsAsRectangle(midDown),
                      "a band entering the zone from above keeps the rectangle")

        // Drop below the lower edge: it flips to chevrons.
        let short = band(forViewport: 0..<bytes(forHeight: 3))
        XCTAssertLessThan(short.height, MinimapView.overviewBandShortHeight,
                          "precondition: a 3 pt band sits below the hysteresis zone")
        XCTAssertFalse(try drawsAsRectangle(short), "a band below the zone is chevrons")

        // And climbing back into the zone from below keeps the chevrons.
        let midUp = band(forViewport: 0..<bytes(forHeight: 4.5))
        XCTAssertGreaterThan(midUp.height, MinimapView.overviewBandShortHeight)
        XCTAssertLessThan(midUp.height, MinimapView.overviewBandTallHeight,
                          "precondition: a 4.5 pt band sits inside the hysteresis zone")
        XCTAssertFalse(try drawsAsRectangle(midUp),
                       "a band entering the zone from below keeps the chevrons")
    }


    // TEMPORARY performance probe on the real dumps.
    // MARK: - Repainting (§19.9)

    /// Counting significant bytes eight at a time must agree with counting them
    /// one at a time — for every byte value, at every alignment. The word trick
    /// is what makes the overview arrive in a fraction of a second instead of
    /// seconds; a wrong count would mis-shade whole regions of a dump.
    func testSignificantByteCountMatchesAByteAtATimeCount() {
        var bytes: [UInt8] = []
        for value in UInt8.min...UInt8.max {
            bytes += [0x00, value, 0xFF, value, value, 0xFF, 0x00, 0x00, value]
        }
        bytes += (0..<4096).map { _ in UInt8.random(in: .min ... .max) }
        bytes.withUnsafeBufferPointer { buffer in
            for from in 0..<17 {
                for length in [0, 1, 7, 8, 9, 15, 16, 437, bytes.count - from]
                where from + length <= bytes.count {
                    let naive = bytes[from..<(from + length)]
                        .filter { $0 != 0x00 && $0 != 0xFF }.count
                    XCTAssertEqual(
                        MainViewController.significantByteCount(buffer, from: from,
                                                               to: from + length),
                        naive, "over bytes [\(from), \(from + length))")
                }
            }
        }
    }

    /// A scroll must not repaint the maps. In overview the whole dump is on
    /// screen — ~19 000 cells — and all a scroll changes is a 7 pt chevron in
    /// each margin, so only those boxes are invalidated. Repainting the panel
    /// instead cost 54 ms per wheel tick, which is what made scrolling lag.
    func testOverviewScrollRepaintsOnlyTheViewportMarkers() throws {
        let (_, _, panel) = try makeOverviewWindow([UInt8](repeating: 0x41, count: 1024 * 1024))
        panel.setViewports([0..<560])
        panel.displayIfNeeded()
        let before = try XCTUnwrap(panel.viewportRects().first)

        panel.setViewports([600_000..<600_560])
        let after = try XCTUnwrap(panel.viewportRects().first)
        XCTAssertNotEqual(before.midY, after.midY, "the band has to have moved")

        let rects = try XCTUnwrap(panel.lastRepaintRequest,
                                  "a scroll asked for a full repaint of the panel")
        let damaged = rects.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertLessThan(damaged, panel.bounds.width * panel.bounds.height * 0.05,
                          "a scroll costs a sliver of the panel, not the whole picture")
        // Both the box the chevron left and the one it moved to are repainted —
        // the first is what erases it, so a stale chevron cannot stay behind.
        for band in [before, after] {
            for x in [band.minX + 1, band.maxX - 1] {
                XCTAssertTrue(rects.contains { $0.contains(NSPoint(x: x, y: band.midY)) },
                              "the chevron's own box at y=\(band.midY), x=\(x)")
            }
        }
    }

    /// An edit repaints the rows it changed, not the picture: the summary is
    /// diffed row by row against the one on screen.
    func testAnEditRepaintsOnlyTheOverviewRowsItChanged() throws {
        let (controller, _, panel) =
            try makeOverviewWindow([UInt8](repeating: 0x41, count: 1024 * 1024))
        panel.displayIfNeeded()

        controller.windowModel.pane1.moveCaret(to: 500_000)
        controller.windowModel.pane1.typeASCII(0x5A)
        XCTAssertTrue(pumpUntil(3.0) {
            panel.overviewSummaries.first?.modified.contains { $0 != 0 } ?? false
        }, "the edit reached the overview")

        let rects = try XCTUnwrap(panel.lastRepaintRequest,
                                  "one byte asked for a full repaint of the panel")
        XCTAssertFalse(rects.isEmpty, "the row it changed is repainted")
        let height = rects.reduce(0) { $0 + $1.height }
        XCTAssertLessThan(height, panel.bounds.height * 0.05,
                          "a byte dirties its own rows, not a thousand of them")
        let row = try XCTUnwrap(panel.overviewSummaries.first?.modified
            .enumerated().first { $0.element != 0 }?.offset)
        let y = CGFloat(row) * panel.overviewRowHeight
        XCTAssertTrue(rects.contains { $0.minY <= y + 1 && $0.maxY >= y },
                      "and it is the marked row that is repainted")
    }

    /// An edit has to show on the map when it happens. The map pulls its cells
    /// from the pane as it draws, so nothing appeared until something else
    /// happened to repaint it — a scroll or a resize (§19.9).
    func testAnEditRepaintsTheDetailRowsItChanged() throws {
        let (controller, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 2048))
        panel.displayIfNeeded()
        XCTAssertEqual(panel.renderMode, .detail, "the premise: a short file opens in detail")

        let offset: UInt64 = 16 * 5 + 3          // row 5
        controller.windowModel.pane1.moveCaret(to: offset)
        panel.displayIfNeeded()
        controller.windowModel.pane1.typeASCII(0x5A)

        let rects = try XCTUnwrap(panel.lastRepaintRequest, "the edit asked for a repaint")
        XCTAssertFalse(rects.isEmpty)
        let y = panel.bounds.minY + CGFloat(5) * MinimapView.rowStep
        XCTAssertTrue(rects.contains { $0.minY <= y + 1 && $0.maxY >= y + MinimapView.rowStep - 1 },
                      "the row holding the edited byte is repainted")
        let height = rects.reduce(0) { $0 + $1.height }
        XCTAssertLessThan(height, panel.bounds.height * 0.5,
                          "and it is a row, not the whole map")
    }

    /// Undo and redo change the same cells an edit does, so they must repaint
    /// them too — the caret alone moving is not enough (§19.9).
    func testUndoAndRedoRepaintTheDetailRowsTheyChange() throws {
        let (controller, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 2048))
        panel.displayIfNeeded()
        let pane = controller.windowModel.pane1
        pane.moveCaret(to: 16 * 7)
        pane.typeASCII(0x5A)
        panel.displayIfNeeded()

        try pane.undo()
        let undoRects = try XCTUnwrap(panel.lastRepaintRequest, "undo asked for a repaint")
        let y = panel.bounds.minY + CGFloat(7) * MinimapView.rowStep
        XCTAssertTrue(undoRects.contains { $0.minY <= y + 1 && $0.maxY >= y + MinimapView.rowStep - 1 },
                      "the row the undo restored is repainted")

        panel.displayIfNeeded()
        try pane.redo()
        let redoRects = try XCTUnwrap(panel.lastRepaintRequest, "redo asked for a repaint")
        XCTAssertTrue(redoRects.contains { $0.minY <= y + 1 && $0.maxY >= y + MinimapView.rowStep - 1 },
                      "and so is the row the redo changed back")
    }

    /// A save leaves every byte where it was and still changes the map: the red
    /// cells clear, because the on-disk reference moved (§19).
    func testASaveRepaintsTheMap() throws {
        let (controller, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 2048))
        panel.displayIfNeeded()
        let pane = controller.windowModel.pane1
        pane.typeASCII(0x5A)
        panel.displayIfNeeded()
        let before = panel.repaintRequests

        try pane.save()
        XCTAssertGreaterThan(panel.repaintRequests, before,
                             "the save asked the map to repaint its cells")
    }

    /// In comparison mode an edit in one file changes the difference state the
    /// *other* map paints at that offset, so both repaint (§9).
    func testAnEditRepaintsBothMapsRows() throws {
        let (controller, window) = try makeComparisonWindow(vertical: true, sizes: (2048, 2048))
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        controller.setMinimapRenderModeForTesting(.detail)
        panel.displayIfNeeded()

        controller.windowModel.pane1.moveCaret(to: 16 * 4)
        panel.displayIfNeeded()
        controller.windowModel.pane1.typeASCII(0x5A)

        let rects = try XCTUnwrap(panel.lastRepaintRequest)
        let y = panel.bounds.minY + CGFloat(4) * MinimapView.rowStep
        let onRow = rects.filter { $0.minY <= y + 1 && $0.maxY >= y + MinimapView.rowStep - 1 }
        XCTAssertEqual(onRow.count, 2, "one rectangle per map, both on the edited row")
        XCTAssertNotEqual(onRow[0].minX, onRow[1].minX, "and they are the two side-by-side maps")
    }

    /// A typed byte lands in one row of a thousand, so it must not send the
    /// overview back over the whole file: the rows it falls in are recomputed and
    /// the rest of the picture is left alone (§19.9).
    func testAnEditPatchesTheOverviewInsteadOfRebuildingIt() throws {
        let (controller, _, panel) =
            try makeOverviewWindow([UInt8](repeating: 0x41, count: 1024 * 1024))
        panel.displayIfNeeded()
        let rebuildsBefore = controller.overviewRebuilds
        let patchesBefore = controller.overviewPatches

        controller.windowModel.pane1.moveCaret(to: 500_000)
        controller.windowModel.pane1.typeASCII(0x00)

        XCTAssertEqual(controller.overviewPatches, patchesBefore + 1,
                       "the edit patched its rows, synchronously")
        XCTAssertTrue(panel.overviewSummaries.first?.modified.contains { $0 != 0 } ?? false,
                      "and the mark is on the picture at once, with no waiting")
        XCTAssertEqual(controller.overviewRebuilds, rebuildsBefore,
                       "no full pass over the file")
        // A debounced rebuild would arrive a little later; nothing may schedule one.
        _ = pumpUntil(1.0) { controller.overviewRebuilds > rebuildsBefore }
        XCTAssertEqual(controller.overviewRebuilds, rebuildsBefore,
                       "and none is queued behind it either")
    }

    /// The patch has to produce exactly what a full pass would: same density,
    /// same marks. Otherwise editing would slowly drift the picture away from the
    /// file it describes.
    func testAPatchedOverviewMatchesAFullRebuild() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 256 * 1024)
        bytes += (0..<(256 * 1024)).map { UInt8(0x41 + ($0 % 26)) }
        let (controller, _, panel) = try makeOverviewWindow(bytes)
        panel.displayIfNeeded()

        controller.windowModel.pane1.moveCaret(to: 100_000)
        controller.windowModel.pane1.typeASCII(0x42)   // content inside erased padding
        let patched = try XCTUnwrap(panel.overviewSummaries.first)

        let published = controller.overviewRebuildsCompleted
        controller.rebuildOverviewForTesting()
        XCTAssertTrue(pumpUntil(5.0) { controller.overviewRebuildsCompleted > published },
                      "the full pass published its picture")
        let rebuilt = try XCTUnwrap(panel.overviewSummaries.first)
        XCTAssertEqual(patched, rebuilt, "the patched picture is the picture a full pass builds")
    }

    /// The other half of the same question: overview mode paints a precomputed
    /// picture, so an edit reaches it only through a rebuild. That path exists —
    /// but the difference marks come from the comparison index, which is updated
    /// in the background, so the check runs the whole way: type a byte that
    /// creates a difference and wait for both maps to show it (§19.4.2).
    func testAnEditReachesTheOverviewsDifferenceMarks() throws {
        let content = (0..<8192).map { UInt8(0x41 + ($0 % 26)) }
        let url1 = try tempFile(content)
        let url2 = try tempFile(content)
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        controller.setMinimapRenderModeForTesting(.overview)

        XCTAssertTrue(pumpUntil(3.0) { panel.overviewSummaries.count == 2 },
                      "both maps have a picture")
        XCTAssertTrue(panel.overviewSummaries.allSatisfy { $0.different.allSatisfy { $0 == 0 } },
                      "the premise: the two files are the same, so nothing is marked")

        controller.windowModel.pane1.moveCaret(to: 4096)
        controller.windowModel.pane1.typeASCII(0x00)

        XCTAssertTrue(pumpUntil(5.0) {
            panel.overviewSummaries.allSatisfy { $0.different.contains { $0 != 0 } }
        }, "the new difference reaches both maps without a scroll or a resize")
        XCTAssertTrue(pumpUntil(5.0) {
            panel.overviewSummaries.first?.modified.contains { $0 != 0 } ?? false
        }, "and so does the edited byte's own red mark")
    }

    /// The same rule in detail mode: while the window stays put, a scroll moves
    /// only the band, so the cells outside it keep their pixels.
    func testDetailScrollRepaintsOnlyTheBandWhileTheWindowStaysPut() throws {
        let (_, _, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 2048))
        XCTAssertTrue(panel.detailWindowFitsWholeFile(),
                      "the premise: a file this short leaves the window at row 0")
        panel.setViewports([0..<560])
        panel.displayIfNeeded()
        let before = try XCTUnwrap(panel.viewportRects().first)

        panel.setViewports([1024..<1584])
        let rects = try XCTUnwrap(panel.lastRepaintRequest,
                                  "the window did not move, so this was not a full repaint")
        let after = try XCTUnwrap(panel.viewportRects().first)
        let damaged = rects.reduce(0) { $0 + $1.height }
        XCTAssertLessThan(damaged, before.height + after.height + 8,
                          "only the band it left and the band it moved to")
        for band in [before, after] {
            XCTAssertTrue(rects.contains { $0.minY <= band.midY && $0.maxY >= band.midY },
                          "the band's own rows at y=\(band.midY)")
        }
    }

    // MARK: - Panel chrome: header switch, status bar, alignment (§19.2)

    /// The panel's paper brightness, resolved in the appearance it draws in, so a
    /// test can say "this pixel is not background" in either theme.
    private func paperBrightness(_ panel: MinimapView) -> CGFloat {
        var value: CGFloat = 1
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            value = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
        }
        return value
    }

    private func panelChrome(_ window: NSWindow) throws -> MinimapPanelView {
        try XCTUnwrap(descendants(of: window.contentView!, MinimapPanelView.self).first,
                      "the minimap panel's chrome")
    }

    /// The map has to start and end where the dump does: that is what the header
    /// and the status bar are for (§19.2).
    func testTheMapLinesUpWithTheDumpBesideIt() throws {
        let (_, window, panel) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 4096))
        let pane = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first)
        let dump = pane.scrollView

        // Compared as rectangles in window coordinates: converting a rect keeps
        // the edges straight whatever each view's own flippedness is.
        let map = panel.convert(panel.bounds, to: nil)
        let bytes = dump.convert(dump.bounds, to: nil)
        XCTAssertEqual(map.maxY, bytes.maxY, accuracy: 1, "the map starts where the bytes do")
        XCTAssertEqual(map.minY, bytes.minY, accuracy: 1, "and ends where they do")
    }

    /// Stacked panes put one dump above the other and the panel's two maps cover
    /// both, so the map area spans from the upper dump's top to the lower dump's
    /// bottom. Aligning to one pane's dump would squeeze both maps into half the
    /// panel.
    func testTheMapsSpanBothDumpsWhenThePanesAreStacked() throws {
        let (_, window) = try makeComparisonWindow(vertical: false, sizes: (8_000, 8_000))
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        let panes = descendants(of: window.contentView!, FilePaneView.self)
        XCTAssertEqual(panes.count, 2, "two panes, one above the other")
        let dumps = panes.map { $0.scrollView.convert($0.scrollView.bounds, to: nil) }
        let upper = try XCTUnwrap(dumps.max(by: { $0.maxY < $1.maxY }))
        let lower = try XCTUnwrap(dumps.min(by: { $0.minY < $1.minY }))
        XCTAssertGreaterThan(upper.minY, lower.minY, "the fixture really is stacked")

        let map = panel.convert(panel.bounds, to: nil)
        XCTAssertEqual(map.maxY, upper.maxY, accuracy: 1, "the maps start at the upper dump")
        XCTAssertEqual(map.minY, lower.minY, accuracy: 1, "and end at the lower one")
    }

    /// Any frame change gets the stand-in, not just one that re-bins the file:
    /// dragging the panel's width redraws the same rows at a new width, which is
    /// as expensive as a height change and just as visible (§19.9).
    func testAWidthDragUsesTheStandInUntilItSettles() throws {
        let (_, window, panel) = try makeOverviewWindow([UInt8](repeating: 0x41, count: 1024 * 1024))
        let (split, _) = try minimapViews(window)
        panel.displayIfNeeded()
        let rows = panel.overviewRowCount()
        let drawnBefore = panel.standInDraws

        split.setPanelWidth(180, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.overviewRowCount(), rows, "a width change does not re-bin the file")
        panel.displayIfNeeded()
        XCTAssertGreaterThan(panel.standInDraws, drawnBefore,
                             "the drag is drawn by stretching, not cell by cell")

        // Once the drag settles the exact picture comes back on its own.
        let drawnWhileDragging = panel.standInDraws
        XCTAssertTrue(pumpUntil(2.0) {
            panel.displayIfNeeded()
            return panel.standInDraws == drawnWhileDragging && panel.needsDisplay == false
        }, "the exact repaint happens after the frame stops moving")
        panel.displayIfNeeded()
        XCTAssertEqual(panel.standInDraws, drawnWhileDragging,
                       "and no stand-in is drawn once it has settled")
    }

    /// The chrome has to survive the map's own repaint. AppKit hands the map a
    /// dirty rect covering the whole panel — 49 pt above its own top — and an
    /// `NSView` does not clip its drawing by default, so the map's background
    /// fill painted over the header and took the mode switch with it. Rendered
    /// through the *panel*, not the header: rendering the header alone hides
    /// exactly this bug, which is how it survived a first round of tests.
    func testTheMapDoesNotPaintOverTheChrome() throws {
        let (_, window, _) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 4096))
        let chrome = try panelChrome(window)
        let control = chrome.modeSwitch
        XCTAssertGreaterThan(control.bounds.width, 40, "the switch has room to draw in")

        let rep = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
        chrome.cacheDisplay(in: chrome.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / chrome.bounds.height
        /// A point of the panel, sampled in the rendered bitmap. The panel is
        /// unflipped and the bitmap is top-down.
        func sample(_ point: NSPoint) throws -> NSColor {
            let x = Int(point.x * scale)
            let y = Int((chrome.bounds.height - point.y) * scale)
            return try XCTUnwrap(rep.colorAt(x: min(max(x, 0), rep.pixelsWide - 1),
                                             y: min(max(y, 0), rep.pixelsHigh - 1)))
        }
        func distance(_ a: NSColor, _ b: NSColor) throws -> CGFloat {
            let x = try XCTUnwrap(a.usingColorSpace(.deviceRGB))
            let y = try XCTUnwrap(b.usingColorSpace(.deviceRGB))
            return abs(x.redComponent - y.redComponent) + abs(x.greenComponent - y.greenComponent)
                + abs(x.blueComponent - y.blueComponent) + abs(x.alphaComponent - y.alphaComponent)
        }

        // Inside the switch's selected half, above its label; and the header's
        // own margin beside it, which the switch never covers.
        let inside = control.convert(NSPoint(x: control.bounds.width * 0.25,
                                             y: control.bounds.height * 0.25), to: chrome)
        let beside = NSPoint(x: 3, y: inside.y)
        XCTAssertGreaterThan(try distance(try sample(inside), try sample(beside)), 0.1,
                             "the switch is still there after the map has drawn")
    }

    /// The status bar is below the map, so the same unclipped fill hid it. The
    /// progress bar has to survive the map's paint too.
    func testTheMapDoesNotPaintOverTheStatusBar() throws {
        let (_, window, _) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 4096))
        let chrome = try panelChrome(window)
        chrome.setRebuildProgress(0.5)
        window.layoutIfNeeded()
        let bar = chrome.progressBar
        XCTAssertFalse(bar.isHidden)
        XCTAssertGreaterThan(bar.bounds.width, 20, "the bar has room to draw in")

        let rep = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
        chrome.cacheDisplay(in: chrome.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / chrome.bounds.height
        func sample(_ point: NSPoint) throws -> NSColor {
            let x = Int(point.x * scale)
            let y = Int((chrome.bounds.height - point.y) * scale)
            return try XCTUnwrap(rep.colorAt(x: min(max(x, 0), rep.pixelsWide - 1),
                                             y: min(max(y, 0), rep.pixelsHigh - 1)))
        }
        func distance(_ a: NSColor, _ b: NSColor) throws -> CGFloat {
            let x = try XCTUnwrap(a.usingColorSpace(.deviceRGB))
            let y = try XCTUnwrap(b.usingColorSpace(.deviceRGB))
            return abs(x.redComponent - y.redComponent) + abs(x.greenComponent - y.greenComponent)
                + abs(x.blueComponent - y.blueComponent) + abs(x.alphaComponent - y.alphaComponent)
        }

        // The filled part of the bar, against the status bar's own background
        // just above it.
        let inside = bar.convert(NSPoint(x: bar.bounds.width * 0.2, y: bar.bounds.midY), to: chrome)
        let above = NSPoint(x: inside.x, y: bar.convert(bar.bounds, to: chrome).maxY + 4)
        XCTAssertGreaterThan(try distance(try sample(inside), try sample(above)), 0.1,
                             "the progress bar is still there after the map has drawn")
    }

    /// A rebuild reports its progress in the status bar and then clears it.
    ///
    /// The reveal policy is pinned rather than raced: with the real thresholds a
    /// pass over a test-sized dump finishes inside the 80 ms delay and the bar is
    /// deliberately never shown (§19.9), and a fixture big enough to outlive the
    /// delay would make this test depend on how fast the machine is.
    func testARebuildReportsItsProgressInTheStatusBar() throws {
        MainViewController.overviewProgressDelay = .zero
        MainViewController.overviewProgressMinimumVisible = .milliseconds(1500)
        let (_, window, panel) = try makeOverviewWindow(
            [UInt8](repeating: 0x41, count: 256 * 1024))
        let chrome = try panelChrome(window)

        // Ask for a fresh pass, the way a resize does.
        panel.onOverviewRowCountChanged?()
        XCTAssertTrue(pumpUntil(5.0) { !chrome.progressBar.isHidden },
                      "the rebuild reports itself")
        XCTAssertGreaterThan(chrome.progressBar.doubleValue, 0)
        XCTAssertFalse(chrome.progressLabel.isHidden, "with its caption")
        XCTAssertTrue(pumpUntil(10.0) { chrome.progressBar.isHidden },
                      "and the bar goes away when the pass is over")
    }

    /// The status bar is empty while nothing is being rebuilt.
    func testTheStatusBarIsEmptyWhileIdle() throws {
        let (_, window, _) = try makeSingleFileWindow([UInt8](repeating: 0x41, count: 4096))
        let chrome = try panelChrome(window)
        XCTAssertTrue(chrome.progressBar.isHidden)
        XCTAssertTrue(chrome.progressLabel.isHidden)
        chrome.setRebuildProgress(0.5)
        XCTAssertFalse(chrome.progressBar.isHidden)
        XCTAssertEqual(chrome.progressBar.doubleValue, 0.5, accuracy: 0.001)
        chrome.setRebuildProgress(nil)
        XCTAssertTrue(chrome.progressBar.isHidden)
        XCTAssertTrue(chrome.progressLabel.isHidden)
    }

    /// The switch in the header is the mode control the menu item duplicates
    /// (§15), so the two have to agree in both directions.
    func testTheHeaderSwitchChangesTheModeAndFollowsTheMenu() throws {
        let (controller, window, panel) = try makeSingleFileWindow(
            [UInt8](repeating: 0x41, count: 4096))
        let chrome = try panelChrome(window)
        XCTAssertEqual(panel.renderMode, .detail, "the fixture starts local")
        XCTAssertEqual(chrome.modeSwitch.selectedSegment, 0)

        let control = chrome.modeSwitch
        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(panel.renderMode, .overview, "the switch drives the map")

        controller.toggleMinimapOverview()
        XCTAssertEqual(panel.renderMode, .detail)
        XCTAssertEqual(chrome.modeSwitch.selectedSegment, 0,
                       "the menu item moves the switch with it")
    }

    /// A resize re-bins the file, so the summary in hand is for the wrong height
    /// until the background pass catches up. Until then the known picture is
    /// stretched over the new height rather than leaving the map short (§19.9).
    ///
    /// The fixture is deliberately lopsided — erased flash over real content —
    /// because a stretch has an orientation: `NSImage.draw` ignores a flipped
    /// view unless told not to, and the first version of this drew the file
    /// upside down until the exact pass replaced it.
    func testAResizeStretchesTheOverviewKeepingItTheRightWayUp() throws {
        let half = 512 * 1024
        var bytes = [UInt8](repeating: 0xFF, count: half)
        bytes += (0..<half).map { UInt8(0x20 + ($0 % 90)) }
        let (_, window, panel) = try makeOverviewWindow(bytes)
        let rowsBefore = try XCTUnwrap(panel.overviewSummaries.first?.rowCount)

        // Grow the panel's height without letting the debounced rebuild run.
        var frame = window.frame
        frame.size.height += 240
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
        XCTAssertNotEqual(panel.overviewRowCount(), rowsBefore, "the bins changed")
        XCTAssertEqual(panel.overviewSummaries.first?.rowCount, rowsBefore,
                       "and the summary has not caught up yet")

        let paper = paperBrightness(panel)
        let inset = MinimapView.contentPadding + 2
        let right = panel.bounds.width - MinimapView.contentPadding - 2
        func inkiness(atY y: CGFloat) throws -> CGFloat {
            let samples = try sampleRow(panel, y: y, from: inset, to: right)
            XCTAssertGreaterThan(samples.count, 20, "enough pixels to judge")
            return samples.map { abs($0 - paper) }.reduce(0, +) / CGFloat(samples.count)
        }
        // The bottom of the map must be drawn at all — the point of the stand-in.
        let bottom = try inkiness(atY: panel.bounds.maxY - 3)
        XCTAssertGreaterThan(bottom, 0.05,
                             "the map is drawn all the way down, not left blank")
        // And the content half has to be the bottom half, as in the file.
        let top = try inkiness(atY: panel.bounds.minY + 3)
        XCTAssertGreaterThan(bottom, top * 2,
                             "the erased half belongs at the top: top \(top), bottom \(bottom)")

        // Once the exact pass lands, the map is back to one row per pixel.
        XCTAssertTrue(pumpUntil(10.0) {
            panel.overviewSummaries.first?.rowCount == panel.overviewRowCount()
        }, "the exact picture arrives after the stand-in")
        let exactTop = try inkiness(atY: panel.bounds.minY + 3)
        let exactBottom = try inkiness(atY: panel.bounds.maxY - 3)
        XCTAssertGreaterThan(exactBottom, exactTop * 2,
                             "and the exact picture agrees on which half is which")
    }

    /// An edit that changes the longest file's length invalidates the overview's
    /// bins — every row covers a different slice of the file now. The picture is
    /// kept and stretched until the background pass replaces it, rather than
    /// dropped: dropping it blanked the panel on every inserted byte, and in a
    /// comparison it blanked only for inserts (a delete leaves the companion the
    /// longest, so the extent, and the bins, are unchanged), which made the
    /// blink look like a bug in insert mode (§19.9).
    func testAnInsertKeepsTheOverviewPictureWhileItIsRecomputed() throws {
        // Erased first half, content second half — so which half is which is
        // visible in the drawing, stretched or exact.
        let size = 512 * 1024
        var bytes = [UInt8](repeating: 0xFF, count: size)
        for i in (size / 2)..<size { bytes[i] = UInt8(i % 251) }
        let (controller, window, panel) = try makeOverviewWindow(bytes)
        let summaryBefore = try XCTUnwrap(panel.overviewSummaries.first)
        XCTAssertGreaterThan(summaryBefore.rowCount, 0)
        XCTAssertFalse(panel.overviewBinsAreStale)

        // Insert one byte: the file grows, so the bins no longer match it.
        controller.windowModel.pane1.isInsertMode = true
        controller.windowModel.pane1.moveCaret(to: 1000)
        controller.windowModel.pane1.typeASCII(0x5A)

        XCTAssertTrue(panel.overviewBinsAreStale, "the bins are known to be out of date")
        XCTAssertEqual(panel.overviewSummaries.first?.rowCount, summaryBefore.rowCount,
                       "and the picture is still there to draw")

        // It is drawn, not left blank, and it still says the content is in the
        // bottom half.
        let paper = paperBrightness(panel)
        let inset = MinimapView.contentPadding + 2
        let right = panel.bounds.width - MinimapView.contentPadding - 2
        func inkiness(atY y: CGFloat) throws -> CGFloat {
            let samples = try sampleRow(panel, y: y, from: inset, to: right)
            XCTAssertGreaterThan(samples.count, 20, "enough pixels to judge")
            return samples.map { abs($0 - paper) }.reduce(0, +) / CGFloat(samples.count)
        }
        let bottom = try inkiness(atY: panel.bounds.maxY - 3)
        let top = try inkiness(atY: panel.bounds.minY + 3)
        XCTAssertGreaterThan(bottom, 0.05, "the map is still drawn, not blanked")
        XCTAssertGreaterThan(bottom, top * 2, "top \(top), bottom \(bottom)")

        // And the background pass replaces it, clearing the stale mark.
        XCTAssertTrue(pumpUntil(10.0) { !panel.overviewBinsAreStale },
                      "the exact picture arrives and the bins are current again")
        XCTAssertEqual(panel.overviewSummaries.first?.rowCount, panel.overviewRowCount())
        _ = window
    }

}
