import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11: the Favorites tab — where kept patterns are edited, removed and put in
/// the order the Find bar's menu lists them in.
///
/// The tab applies live, like every other one in that window, so each test is
/// "do the thing, read the store back".
@MainActor
final class FavoritePatternsSettingsTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var favoritesFile: URL!
    private var tab: FavoritePatternsSettingsViewController!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FavoritePatternStore.defaults = store
        favoritesFile = isolatedFavoritesFile(for: self)
    }

    override func tearDown() {
        tab = nil
        FavoritePatternStore.defaults = .standard
        discardIsolatedFavoritesFile(favoritesFile)
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    /// Builds the tab over whatever the store holds. Called after the entries
    /// are in place, the way opening the window reads them.
    private func openTab() {
        tab = FavoritePatternsSettingsViewController()
        _ = tab.view  // loadView builds the table
    }

    private func keep(_ name: String, _ pattern: String,
                      _ encoding: SearchEncoding = .hex, caseSensitive: Bool = false) {
        FavoritePatternStore.add(SearchPatternEntry(name: name, pattern: pattern,
                                                    encoding: encoding,
                                                    caseSensitive: caseSensitive))
    }

    private var stored: [SearchPatternEntry] { FavoritePatternStore.favorites }

    // MARK: - What it shows

    func testItShowsTheKeptPatternsInOrder() throws {
        keep("ME FPT", "$FPT", .ascii)
        keep("Capsule header", "5A A5 F0 0F")
        openTab()

        XCTAssertEqual(tab.rows.map(\.name), ["ME FPT", "Capsule header"])
        XCTAssertEqual(tab.table.numberOfRows, 2)
        XCTAssertEqual(tab.fieldForTests(row: 0, name: true)?.stringValue, "ME FPT")
        XCTAssertEqual(tab.fieldForTests(row: 1, name: false)?.stringValue, "5A A5 F0 0F")
        XCTAssertEqual(tab.encodingPopupForTests(row: 0)?.titleOfSelectedItem, "ASCII")
    }

    /// Hex is byte-exact whatever the flag holds, so there is nothing to tick —
    /// the same reason the bar's own toggle leaves the bar (§11).
    func testTheCaseBoxIsDeadForHexAndLiveForText() throws {
        keep("bytes", "DE AD", .hex)
        keep("text", "root", .ascii, caseSensitive: true)
        openTab()

        XCTAssertEqual(tab.caseCheckboxForTests(row: 0)?.isEnabled, false)
        XCTAssertEqual(tab.caseCheckboxForTests(row: 1)?.isEnabled, true)
        XCTAssertEqual(tab.caseCheckboxForTests(row: 1)?.state, .on)
    }

    // MARK: - Editing

    func testRenamingWritesThrough() throws {
        keep("ME FTP", "$FPT", .ascii)
        openTab()

        tab.typeForTests("  ME FPT ", row: 0, name: true)

        XCTAssertEqual(stored.map(\.name), ["ME FPT"], "trimmed, and stored at once")
    }

    func testEditingThePatternWritesThrough() throws {
        keep("Capsule header", "5A A5", .hex)
        openTab()

        tab.typeForTests("5A A5 F0 0F", row: 0, name: false)

        XCTAssertEqual(stored.first?.pattern, "5A A5 F0 0F")
        XCTAssertTrue(tab.messageForTests.isEmpty)
    }

    /// The commit goes through the same parse the Find bar makes, so a pattern
    /// that cannot be searched cannot be stored: the cell goes back to what it
    /// held and the tab says why (§11).
    func testAnUnsearchablePatternIsRefusedAndTheCellGoesBack() throws {
        keep("Capsule header", "5A A5", .hex)
        openTab()

        tab.typeForTests("DE A", row: 0, name: false)

        XCTAssertEqual(stored.first?.pattern, "5A A5", "the store did not move")
        XCTAssertEqual(tab.fieldForTests(row: 0, name: false)?.stringValue, "5A A5",
                       "nor did the cell")
        XCTAssertTrue(tab.messageForTests.contains("hex"), tab.messageForTests)
    }

    func testChangingTheEncodingWritesThrough() throws {
        keep("Windows loader", "windows", .ascii)
        openTab()

        tab.pickEncodingForTests(.utf16LE, row: 0)

        XCTAssertEqual(stored.first?.encoding, .utf16LE)
        XCTAssertEqual(stored.first?.pattern, "windows", "the pattern is untouched")
    }

    /// An encoding its pattern cannot survive is refused too — `DE A` is a fine
    /// ASCII pattern and is not hex, so the entry is not allowed to become
    /// unsearchable behind the user's back.
    func testAnEncodingThePatternCannotSurviveIsRefused() throws {
        keep("Hand-typed", "DE A", .ascii)
        openTab()

        tab.pickEncodingForTests(.hex, row: 0)

        XCTAssertEqual(stored.first?.encoding, .ascii, "the store did not move")
        XCTAssertEqual(tab.encodingPopupForTests(row: 0)?.titleOfSelectedItem, "ASCII",
                       "nor did the popup")
        XCTAssertFalse(tab.messageForTests.isEmpty)
    }

    func testTickingMatchCaseWritesThrough() throws {
        keep("Root string", "root", .ascii)
        openTab()

        tab.setCaseForTests(true, row: 0)

        XCTAssertEqual(stored.first?.caseSensitive, true)
    }

    // MARK: - Adding and removing

    /// `+` puts a row in the table, not in the store: an entry with no pattern
    /// is not a search, and a curated list should not gain a row that searches
    /// for nothing. It becomes an entry the moment it has a pattern.
    func testANewRowIsADraftUntilItHasAPattern() throws {
        openTab()

        tab.addButton.performClick(nil)

        XCTAssertEqual(tab.rows.count, 1, "the row is on screen")
        XCTAssertTrue(stored.isEmpty, "and nowhere else")

        tab.typeForTests("Capsule header", row: 0, name: true)
        XCTAssertTrue(stored.isEmpty, "a name alone is still not a search")

        tab.typeForTests("5A A5", row: 0, name: false)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.name, "Capsule header")
        XCTAssertEqual(stored.first?.pattern, "5A A5")
        XCTAssertEqual(stored.first?.encoding, .hex, "hex is where a new row starts")
    }

    /// Two empty rows would be indistinguishable, and the store holds neither.
    func testOnlyOneDraftAtATime() {
        openTab()

        tab.addButton.performClick(nil)
        tab.addButton.performClick(nil)

        XCTAssertEqual(tab.rows.count, 1)
    }

    func testRemovingTheSelectedRow() throws {
        keep("ME FPT", "$FPT", .ascii)
        keep("Capsule header", "5A A5")
        openTab()

        tab.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tab.removeButton.performClick(nil)

        XCTAssertEqual(stored.map(\.name), ["Capsule header"])
    }

    /// Nothing selected, nothing to remove — the button says so before it is
    /// pressed.
    func testRemoveIsDeadWithoutASelection() {
        keep("ME FPT", "$FPT", .ascii)
        openTab()

        XCTAssertFalse(tab.removeButton.isEnabled)
        tab.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(tab.removeButton.isEnabled)
    }

    // MARK: - A syncing library must not take the row away

    /// A library that syncs announces itself often — every publish, every
    /// arrival, every time the app comes forward. An announcement that carries
    /// no change must leave the table alone: rebuilding it drops the selection
    /// and ends the edit in progress, which is what made a published library
    /// impossible to edit on the other Mac.
    func testAnAnnouncementThatChangesNothingKeepsTheSelection() {
        keep("first", "11")
        keep("second", "22")
        openTab()
        tab.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        NotificationCenter.default.post(name: FavoritePatternStore.didChangeNotification,
                                        object: nil)
        tab.reload()

        XCTAssertEqual(tab.table.selectedRow, 1, "the row the user picked is still theirs")
    }

    /// And one that carries a change does show it.
    func testAChangeIsShown() {
        keep("first", "11")
        openTab()
        XCTAssertEqual(tab.rows.map(\.name), ["first"], "the premise")

        keep("arrived from another Mac", "22")

        XCTAssertEqual(tab.rows.map(\.name), ["first", "arrived from another Mac"])
        XCTAssertEqual(tab.table.numberOfRows, 2)
    }

    /// A rename that arrives while the user is typing waits for them to finish:
    /// the word is not taken out from under them mid-edit.
    func testAChangeArrivingMidEditIsAppliedWhenTheEditEnds() throws {
        keep("first", "11")
        keep("second", "22")
        openTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(tab.view)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        let field = try XCTUnwrap(tab.fieldForTests(row: 0, name: true))
        XCTAssertTrue(window.makeFirstResponder(field), "the premise: the cell takes focus")
        XCTAssertNotNil(field.currentEditor(), "and is being typed into")

        keep("arrived mid-edit", "33")
        XCTAssertEqual(tab.table.numberOfRows, 2, "the table waited")

        tab.typeForTests("renamed here", row: 0, name: true)

        XCTAssertEqual(tab.rows.map(\.name), ["renamed here", "second", "arrived mid-edit"])
    }

    // MARK: - The order is the user's

    /// The menu lists favourites in the order the store holds them, so a
    /// dragged row is a stored order (§11).
    func testDraggingARowStoresTheNewOrder() {
        keep("first", "11")
        keep("second", "22")
        keep("third", "33")
        openTab()

        // The last row into the gap above the first.
        tab.dropForTests(from: 2, above: 0)

        XCTAssertEqual(stored.map(\.name), ["third", "first", "second"])
        XCTAssertEqual(tab.rows.map(\.name), ["third", "first", "second"])

        // And downwards: the drop index was read before the row left, so the
        // gap it names has shifted.
        tab.dropForTests(from: 0, above: 2)
        XCTAssertEqual(stored.map(\.name), ["first", "third", "second"])
    }

    // MARK: - Not the only writer

    /// A pattern kept from a Find bar while the tab is open shows up: the store
    /// announces itself, and the table is not the only writer (§11).
    func testAPatternKeptElsewhereAppears() {
        openTab()
        XCTAssertTrue(tab.rows.isEmpty)

        keep("Late arrival", "$FPT", .ascii)

        XCTAssertEqual(tab.rows.map(\.name), ["Late arrival"])
    }

    /// But not over a half-filled row: re-reading the store would take a draft
    /// away under the user's hands.
    func testADraftSurvivesSomeoneElsesChange() {
        openTab()
        tab.addButton.performClick(nil)
        tab.typeForTests("Being typed", row: 0, name: true)

        keep("Late arrival", "$FPT", .ascii)

        XCTAssertEqual(tab.rows.map(\.name), ["Being typed"],
                       "the draft is still there and still the row being edited")
    }
}
