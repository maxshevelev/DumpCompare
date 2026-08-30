import XCTest
@testable import DumpCompare

/// Tearing a pane off into its own tab (`Design/TABS_PLAN.md`).
///
/// The command *moves* the document rather than opening its file a second time.
/// Opening the URL again would put two live documents over one file — two dirty
/// states, two watchers, a piece table whose base moves under it when the other
/// saves — which is exactly what §4.1 rule 6 exists to prevent, and it would
/// leave the unsaved edits, the undo history and the segments behind. Moving the
/// pane object takes all of it along by construction.
@MainActor
final class TearOffTests: XCTestCase {

    /// Opens two files into `controller` and returns them in pane order.
    private func openComparison(in controller: MainViewController) throws -> (URL, URL) {
        let a = try tempFile([UInt8](repeating: 0xA0, count: 64))
        let b = try tempFile([UInt8](repeating: 0xB0, count: 64))
        controller.openFiles([a, b])
        XCTAssertEqual(controller.mode, .comparison, "the premise: two panes open")
        return (a, b)
    }

    // MARK: - The move

    /// The pane arrives in the new tab as the same object, so everything it owns
    /// arrives with it — and the window it left keeps the other file, on its own.
    func testTearingAPaneOffMovesItWholeAndLeavesTheOtherBehind() throws {
        let source = MainViewController()
        let destination = MainViewController()
        source.makeSiblingTab = { destination }
        let (a, b) = try openComparison(in: source)

        let moved = source.windowModel.pane2
        source.openPaneInNewTab(paneMenuItem(for: moved, in: source))

        XCTAssertIdentical(destination.windowModel.pane1, moved,
                           "the same pane object, not a fresh one over the same file")
        XCTAssertEqual(destination.windowModel.pane1.status.fileName, b.lastPathComponent)
        XCTAssertEqual(destination.mode, .singleFile)

        XCTAssertEqual(source.mode, .singleFile, "the comparison is over")
        XCTAssertEqual(source.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertFalse(source.windowModel.pane2.isOpen, "the second pane is free again")
    }

    /// Unsaved edits travel: the document is moved, never re-read from disk.
    /// Re-opening the file would silently discard them.
    func testUnsavedEditsTravelWithTheMovedPane() throws {
        let source = MainViewController()
        let destination = MainViewController()
        source.makeSiblingTab = { destination }
        _ = try openComparison(in: source)

        let moved = source.windowModel.pane2
        try moved.pasteWrite([0xFF, 0xFE])
        XCTAssertTrue(moved.status.isDirty, "the premise: the pane has unsaved changes")

        source.openPaneInNewTab(paneMenuItem(for: moved, in: source))

        XCTAssertTrue(destination.windowModel.pane1.status.isDirty,
                      "the edits came along; the file was not re-read")
    }

    /// Tearing off pane 1 promotes pane 2 in its place — the §3.5 rule that
    /// closing a pane already follows.
    func testTearingOffTheFirstPanePromotesTheSecond() throws {
        let source = MainViewController()
        let destination = MainViewController()
        source.makeSiblingTab = { destination }
        let (a, b) = try openComparison(in: source)

        source.openPaneInNewTab(paneMenuItem(for: source.windowModel.pane1, in: source))

        XCTAssertEqual(destination.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertEqual(source.windowModel.pane1.status.fileName, b.lastPathComponent,
                       "the pane that stayed is now the first one")
    }

    // MARK: - The bookmarks

    /// The marks are copied, not shared and not dropped: they were made against
    /// absolute offsets, and those mean the same thing in the file that just
    /// moved. From then on the two lists are independent.
    func testTheBookmarksAreCopiedAndThenDiverge() throws {
        let source = MainViewController()
        let destination = MainViewController()
        source.makeSiblingTab = { destination }
        _ = try openComparison(in: source)
        _ = source.windowModel.bookmarkStore.add(rowContaining: 0, name: "header")
        _ = source.windowModel.bookmarkStore.add(rowContaining: 32, name: "table")

        source.openPaneInNewTab(paneMenuItem(for: source.windowModel.pane2, in: source))

        XCTAssertEqual(destination.windowModel.bookmarkStore.bookmarks.map(\.name),
                       ["header", "table"], "the list came along")
        XCTAssertEqual(source.windowModel.bookmarkStore.bookmarks.count, 2,
                       "and stayed behind as well")
        XCTAssertNotIdentical(source.windowModel.bookmarkStore,
                              destination.windowModel.bookmarkStore,
                              "two stores, not one shared between two windows")

        _ = destination.windowModel.bookmarkStore.add(rowContaining: 48, name: "added later")

        XCTAssertEqual(destination.windowModel.bookmarkStore.bookmarks.count, 3)
        XCTAssertEqual(source.windowModel.bookmarkStore.bookmarks.count, 2,
                       "a mark made in one window must not appear in the other")
    }

    /// The moved pane reads the receiving window's list, not the one it left.
    func testTheMovedPaneUsesItsNewWindowsBookmarks() throws {
        let source = MainViewController()
        let destination = MainViewController()
        source.makeSiblingTab = { destination }
        _ = try openComparison(in: source)

        let moved = source.windowModel.pane2
        source.openPaneInNewTab(paneMenuItem(for: moved, in: source))

        XCTAssertIdentical(moved.bookmarkStore, destination.windowModel.bookmarkStore)
    }

    /// Seeding replaces the list and sorts it by row, the invariant every other
    /// verb maintains.
    func testSeedingSortsByRow() {
        let store = BookmarkStore()
        store.seed([Bookmark(row: 64, name: "late"), Bookmark(row: 0, name: "early")])

        XCTAssertEqual(store.bookmarks.map(\.row), [0, 64])
    }

    // MARK: - When the command is offered

    /// Only a comparison has a pane to spare. In single-file mode the command
    /// would move the window's only document out and leave an empty window
    /// behind, which separates nothing.
    func testOpenInNewTabIsOfferedOnlyInAComparison() throws {
        let controller = MainViewController()
        controller.makeSiblingTab = { MainViewController() }

        let a = try tempFile([UInt8](repeating: 0xA0, count: 64))
        controller.openFiles([a])
        XCTAssertFalse(controller.validateMenuItem(paneMenuItem(for: controller.windowModel.pane1,
                                                               in: controller)),
                       "single file: nothing to separate")

        let b = try tempFile([UInt8](repeating: 0xB0, count: 64))
        controller.openFiles([b])
        XCTAssertTrue(controller.validateMenuItem(paneMenuItem(for: controller.windowModel.pane2,
                                                              in: controller)))
    }

    /// With no window to put a tab beside, the command is not offered at all.
    func testOpenInNewTabIsNotOfferedWithoutSomewhereToPutIt() throws {
        let controller = MainViewController()
        _ = try openComparison(in: controller)

        XCTAssertFalse(controller.validateMenuItem(paneMenuItem(for: controller.windowModel.pane2,
                                                               in: controller)))
    }

    // MARK: - Closing

    /// ⌘W steps down — pane, then tab, then window — and ⇧⌘W is the whole window
    /// at once. Both live in the File menu; neither carries a target.
    func testCloseAndCloseWindowCarryTheirKeys() throws {
        let items = MainMenu.makeFileMenu().items
        let close = try XCTUnwrap(items.first { $0.title == "Close" })
        let closeWindow = try XCTUnwrap(items.first { $0.title == "Close Window" })

        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(closeWindow.keyEquivalent, "W", "⇧⌘W — the capital is the shift")
        XCTAssertEqual(close.action, #selector(MainViewController.closeDocument))
        XCTAssertEqual(closeWindow.action, #selector(MainViewController.closeWindow(_:)))
    }

    // MARK: - Helpers

    /// The pane menu's item for Open in New Tab, carrying `pane` the way the
    /// header's own menu does.
    private func paneMenuItem(for pane: PaneViewModel, in controller: MainViewController) -> NSMenuItem {
        let item = NSMenuItem(title: "Open in New Tab",
                              action: #selector(MainViewController.openPaneInNewTab(_:)),
                              keyEquivalent: "")
        item.representedObject = pane
        return item
    }
}
