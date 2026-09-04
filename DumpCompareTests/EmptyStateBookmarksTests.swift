import XCTest
@testable import DumpCompare

/// §3.1 with §20: what an empty window is for.
///
/// Bookmarks belong to the window, not to a file, so closing the last dump
/// leaves a window that still holds them. Until it showed them it looked like a
/// window with no reason to exist.
@MainActor
final class EmptyStateBookmarksTests: XCTestCase {

    // MARK: - The list

    /// With no marks there is no section: an empty list would be a heading over
    /// nothing.
    func testNoBookmarksMeansNoSection() {
        let view = EmptyStateView()

        view.setBookmarks([])

        XCTAssertFalse(view.isShowingBookmarksForTesting)
        XCTAssertTrue(view.bookmarkRowsForTesting.isEmpty)
    }

    /// A named mark shows its address and its name.
    func testANamedBookmarkShowsItsAddressAndName() {
        let view = EmptyStateView()

        view.setBookmarks([Bookmark(row: 0x7AF0, name: "header")])

        XCTAssertTrue(view.isShowingBookmarksForTesting)
        XCTAssertEqual(view.bookmarkRowsForTesting.count, 1)
        XCTAssertEqual(view.bookmarkRowsForTesting.first?.address, UInt64(0x7AF0).bareAddress)
        XCTAssertEqual(view.bookmarkRowsForTesting.first?.name, "header")
    }

    /// The list is re-sized on every rebuild by *updating* its size, not by
    /// adding another one. Activating a fresh pair each time left the old pair
    /// active too, and two different fixed heights on one scroll view is a
    /// constraint conflict on every layout pass from the second bookmark on.
    func testRebuildingTheListDoesNotStackUpSizeConstraints() throws {
        let view = EmptyStateView()

        view.setBookmarks([Bookmark(row: 0x10, name: "one")])
        XCTAssertEqual(view.bookmarkListHeightsForTesting.count, 1, "one height")
        let oneRow = try XCTUnwrap(view.bookmarkListHeightsForTesting.first)

        view.setBookmarks([Bookmark(row: 0x10, name: "one"),
                           Bookmark(row: 0x20, name: "two")])
        view.setBookmarks([Bookmark(row: 0x10, name: "one"),
                           Bookmark(row: 0x20, name: "two"),
                           Bookmark(row: 0x30, name: "three")])
        XCTAssertEqual(view.bookmarkListHeightsForTesting.count, 1,
                       "still one after two more rebuilds")
        let threeRows = try XCTUnwrap(view.bookmarkListHeightsForTesting.first)
        XCTAssertGreaterThan(threeRows, oneRow, "and it is the one that grew")
        XCTAssertEqual(view.bookmarkRowsForTesting.count, 3, "and the list is right")
    }

    /// An unnamed mark shows its address and nothing else.
    ///
    /// Everywhere a file is open, an unnamed mark is described by the bytes at
    /// it (§20.5). Here there is no file, so there are no bytes to describe it
    /// with — and inventing something would be worse than the address alone,
    /// which is what the mark is called when it has no name (§20.2).
    func testAnUnnamedBookmarkShowsOnlyItsAddress() {
        let view = EmptyStateView()

        view.setBookmarks([Bookmark(row: 0x40, name: "")])

        XCTAssertEqual(view.bookmarkRowsForTesting.first?.address, UInt64(0x40).bareAddress)
        XCTAssertEqual(view.bookmarkRowsForTesting.first?.name, "")
    }

    /// The addresses wear the bookmark colour — the same purple as the mark in
    /// the gutter and the arrow on the minimap, so the three read as one thing.
    func testTheAddressesWearTheBookmarkColour() {
        let view = EmptyStateView()

        view.setBookmarks([Bookmark(row: 0x10, name: "")])

        XCTAssertEqual(view.bookmarkAddressColorForTesting, HexTheme.bookmarkColor)
    }

    /// Setting the list again replaces it rather than adding to it.
    func testTheListIsReplacedRatherThanAppended() {
        let view = EmptyStateView()

        view.setBookmarks([Bookmark(row: 0x10, name: "a"), Bookmark(row: 0x20, name: "b")])
        view.setBookmarks([Bookmark(row: 0x30, name: "c")])

        XCTAssertEqual(view.bookmarkRowsForTesting.map(\.name), ["c"])
    }

    // MARK: - The title

    /// An empty window says how many marks it is keeping, which is the reason it
    /// is still open.
    func testTheTitleCountsTheBookmarks() throws {
        let controller = MainViewController()
        XCTAssertEqual(controller.mode, .empty, "the premise")
        XCTAssertEqual(controller.windowTitle, "Empty")

        _ = controller.windowModel.bookmarkStore.add(rowContaining: 0, name: "one")
        XCTAssertEqual(controller.windowTitle, "Empty (1 Bookmark)")

        _ = controller.windowModel.bookmarkStore.add(rowContaining: 64, name: "two")
        XCTAssertEqual(controller.windowTitle, "Empty (2 Bookmarks)")
    }

    /// A window with a file is named after the file, marks or no marks: the
    /// count is what an *empty* window has to say for itself.
    func testAWindowWithAFileIsStillNamedAfterIt() throws {
        let controller = MainViewController()
        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        controller.openFiles([url])
        _ = controller.windowModel.bookmarkStore.add(rowContaining: 0, name: "one")

        XCTAssertEqual(controller.windowTitle, url.lastPathComponent)
    }

    // MARK: - How the section reads

    /// The heading names the list and counts it, and wears the bookmark colour
    /// so it ties to the addresses under it.
    func testTheHeadingCountsAndWearsTheBookmarkColour() throws {
        let view = EmptyStateView()

        view.setBookmarks([Bookmark(row: 0, name: "one")])
        XCTAssertEqual(view.bookmarkHeadingForTesting?.stringValue, "1 Bookmark Here:")

        view.setBookmarks([Bookmark(row: 0, name: "one"), Bookmark(row: 64, name: "two")])
        XCTAssertEqual(view.bookmarkHeadingForTesting?.stringValue, "2 Bookmarks Here:")

        XCTAssertEqual(view.bookmarkHeadingForTesting?.textColor, HexTheme.bookmarkColor)
    }

    /// The heading is left-aligned with the list rather than centred over it.
    func testTheHeadingLinesUpWithTheList() throws {
        let view = EmptyStateView()

        view.setBookmarks([Bookmark(row: 0x7AF0, name: "header")])

        XCTAssertEqual(view.bookmarkHeadingForTesting?.alignment, .left)
    }
}
