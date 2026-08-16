import DumpCompareCore
import XCTest
@testable import DumpCompare

/// § Minimap stage 1: the right-edge toolbar toggle ("sidebar.right"), the
/// fixed spacer between it and the diff navigation block, and the animated
/// show/hide of the empty vertical panel. The panel starts hidden, keeps a
/// minimum width of 80 pt and never exceeds a quarter of the screen, and its
/// width is persisted so the next show restores the user's drag.
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

        // Below the minimum the delegate clamps the divider back up to 80 pt.
        split.setPanelWidth(10, animated: false)
        window.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(panel.frame.width, MinimapSplitView.minPanelWidth,
                                    "the panel never shrinks below its minimum")

        // Above the maximum the panel stops at a quarter of the screen.
        split.setPanelWidth(10_000, animated: false)
        window.layoutIfNeeded()
        XCTAssertLessThanOrEqual(panel.frame.width, MinimapSplitView.maxPanelWidth,
                                 "the panel never grows past a quarter of the screen")

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

        // First show: drag to 200 (persisted).
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        split.setPanelWidth(200, animated: false)
        window.layoutIfNeeded()

        // Hide, then show again — the persisted width wins over the default.
        split.setPanelVisible(false, animated: false)
        window.layoutIfNeeded()
        XCTAssertLessThan(panel.frame.width, 1)

        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(panel.frame.width, 200, accuracy: 1,
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
    private func makeComparisonWindow(vertical: Bool) throws -> (MainViewController, NSWindow) {
        LayoutSettings.set(isVertical: vertical)
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 256))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 128))
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

    // MARK: - Stage 3: stripes

    /// Opens one file in single-file mode and waits for the minimap's async
    /// significance build to land.
    private func makeSingleFileWindow(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, MinimapView) {
        let url = try tempFile(bytes)
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(2.0) { !panel.maps.isEmpty && !panel.maps[0].rows.isEmpty }
        return (controller, window, panel)
    }

    func testSignificanceStripesMarkSignificantBytes() throws {
        // 3 hex rows: row 0 has a significant byte, row 1 is all fill, row 2
        // has a significant byte.
        let bytes: [UInt8] = [0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let (_, _, panel) = try makeSingleFileWindow(bytes)
        let map = try XCTUnwrap(panel.maps.first)
        XCTAssertEqual(map.fileSize, UInt64(bytes.count))
        XCTAssertEqual(map.rows.count, 3, "48 bytes = 3 hex rows → 3 stripes")
        XCTAssertEqual(map.rows[0], .significant, "row 0 holds byte 0x41")
        XCTAssertEqual(map.rows[1], .insignificant, "row 1 is all 0x00/0xFF fill")
        XCTAssertEqual(map.rows[2], .significant, "row 2 holds byte 0x42")
    }

    func testStripeCountCollapsesLargeFiles() throws {
        // More hex rows than maxRenderRows → exactly maxRenderRows stripes.
        let size = MinimapView.maxRenderRows * 16 + 100
        let bytes = [UInt8](repeating: 0x00, count: size)
        let (_, _, panel) = try makeSingleFileWindow(bytes)
        let map = try XCTUnwrap(panel.maps.first)
        XCTAssertEqual(map.rows.count, MinimapView.maxRenderRows,
                       "a file larger than the render density collapses to maxRenderRows stripes")
    }

    func testComparisonDifferenceStripesWin() throws {
        // Two files that differ everywhere → every stripe is a difference stripe.
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 64))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 64))
        let (controller, window) = try makeController()
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (split, panel) = try minimapViews(window)
        split.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        _ = pumpUntil(2.0) { panel.maps.count == 2 && !panel.maps[0].rows.isEmpty }
        // The background index needs to land before the diff stripes appear.
        _ = pumpUntil(3.0) {
            panel.maps.allSatisfy { map in !map.rows.isEmpty && map.rows.allSatisfy { $0 == .different } }
        }
        XCTAssertEqual(panel.maps.count, 2, "one map per pane")
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
}
