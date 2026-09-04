import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11: the Find bar's results button is a toggle over the **active** pane's
/// list, and in comparison mode each pane has its own.
///
/// So it is a reading of that pane, not a memory of the last press: with the
/// bar open, switching to a pane whose list is up must show the button on —
/// otherwise it offers to "show" what is already on screen, and pressing it
/// closes the list instead.
@MainActor
final class SearchResultsToggleTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FindHistoryStore.defaults = store
        FindBarView.defaults = store
        FilePaneView.defaults = store
    }

    override func tearDown() {
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        FilePaneView.defaults = .standard
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Two panes holding the same bytes, so one pattern occurs in both.
    private func makeComparison() throws -> (MainViewController, NSWindow) {
        let bytes: [UInt8] = Array(repeating: 0xAB, count: 512)
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: try tempFile(bytes))
        try controller.windowModel.pane2.open(url: try tempFile(bytes))
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        addTeardownBlock { [weak controller] in
            controller?.windowModel.pane1.close()
            controller?.windowModel.pane2.close()
        }
        return (controller, window)
    }

    private func paneViews(_ window: NSWindow) throws -> [FilePaneView] {
        let panes = descendants(of: try XCTUnwrap(window.contentView), FilePaneView.self)
        XCTAssertEqual(panes.count, 2, "the premise: two panes")
        return panes
    }

    private func bar(_ window: NSWindow) throws -> FindBarView {
        try descendant(FindBarView.self, of: try XCTUnwrap(window.contentView))
    }

    private func resultsButton(_ window: NSWindow) throws -> NSButton {
        try XCTUnwrap(descendants(of: try bar(window), NSButton.self)
            .first { $0.accessibilityLabel() == "Search Results" })
    }

    /// Activates a pane the way a click on its dump does: focus is what drives
    /// activation (§3.3).
    private func activate(_ pane: FilePaneView, in window: NSWindow) throws {
        let hexView = try XCTUnwrap(descendants(of: pane, HexView.self).first)
        window.makeFirstResponder(hexView)
    }

    /// Opens the active pane's results panel through the bar's own button.
    private func openResults(_ pattern: String, in window: NSWindow) throws {
        let bar = try bar(window)
        bar.setPatternForTests(pattern)
        try resultsButton(window).performClick(nil)
    }

    // MARK: - The reading

    /// The bug: with the bar open, moving to the pane whose list is up left the
    /// button reading "off" — it described the pane that had been active when
    /// it was last pressed.
    func testTheButtonFollowsTheActivePanesPanel() throws {
        let (controller, window) = try makeComparison()
        let panes = try paneViews(window)
        controller.findPattern()

        // Pane 2 gets a list; pane 1 has none.
        try activate(panes[1], in: window)
        XCTAssertEqual(controller.windowModel.activePaneIndex, 1, "the premise")
        try openResults("AB", in: window)
        XCTAssertTrue(pumpUntil(5) { panes[1].searchResultsPanelVisible },
                      "the button must open the active pane's panel")
        XCTAssertFalse(panes[0].searchResultsPanelVisible, "and only that pane's")
        XCTAssertTrue(try bar(window).resultsShownForTests)

        // Over to the pane without one: nothing is on screen to hide.
        try activate(panes[0], in: window)
        XCTAssertEqual(controller.windowModel.activePaneIndex, 0)
        XCTAssertFalse(try bar(window).resultsShownForTests,
                       "the button describes the pane in front, which has no list")

        // And back: the list is up, so the button reads as on again.
        try activate(panes[1], in: window)
        XCTAssertTrue(try bar(window).resultsShownForTests,
                      "this is the bug: a list on screen must read as on")
    }

    /// A panel closing itself is not a statement about the other pane: the
    /// button is re-read, not turned off.
    func testClosingOnePanelLeavesTheOthersReadingAlone() throws {
        let (controller, window) = try makeComparison()
        let panes = try paneViews(window)
        controller.findPattern()

        for index in [0, 1] {
            try activate(panes[index], in: window)
            try openResults("AB", in: window)
            XCTAssertTrue(pumpUntil(5) { panes[index].searchResultsPanelVisible })
        }
        XCTAssertTrue(try bar(window).resultsShownForTests, "pane 2 is active, with a list")

        // Pane 1's panel closes by its own control while pane 2 is active.
        panes[0].hideSearchResults()

        XCTAssertTrue(try bar(window).resultsShownForTests,
                      "pane 2's list is still up, so the button stays on")
    }
}
