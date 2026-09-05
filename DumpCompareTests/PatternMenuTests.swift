import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11: the Find bar's pattern menu — the two lists, their commands, and what
/// picking a row does (`Design/PATTERN_LIBRARY_IDEA.md`).
///
/// Against a bare `FindBarView` in a window rather than the whole controller:
/// what a pick *finds* is the controller's business and tested through it, and
/// what a pick *is* — pattern, encoding, case rule, and a search — is the bar's.
@MainActor
final class PatternMenuTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var favoritesFile: URL!
    private var bar: FindBarView!
    private var window: NSWindow!
    private var searched: [FindBarView.Request] = []

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FindBarView.defaults = store
        FindHistoryStore.defaults = store
        FavoritePatternStore.defaults = store
        favoritesFile = isolatedFavoritesFile(for: self)

        bar = FindBarView()
        bar.onSearch = { [weak self] request, _ in self?.searched.append(request) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 60),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = bar
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
    }

    override func tearDown() {
        searched = []
        window = nil
        bar = nil
        FindBarView.defaults = .standard
        FindHistoryStore.defaults = .standard
        FavoritePatternStore.defaults = .standard
        discardIsolatedFavoritesFile(favoritesFile)
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    // MARK: - Reading the menu

    private var rows: [String] { bar.patternMenuRowsForTests }

    private func menu() throws -> NSMenu { try XCTUnwrap(bar.patternMenuForTests) }

    /// The titles in order, with separators marked, so a test can assert what
    /// is fenced off from what.
    private func shape() throws -> [String] {
        try menu().items.map { $0.isSeparatorItem ? "───" : ($0.attributedTitle?.string ?? $0.title) }
    }

    private func favorite(_ name: String, _ pattern: String,
                          _ encoding: SearchEncoding = .hex,
                          caseSensitive: Bool = false) {
        FavoritePatternStore.add(SearchPatternEntry(name: name, pattern: pattern,
                                                    encoding: encoding,
                                                    caseSensitive: caseSensitive))
    }

    // MARK: - The structure

    /// Recents first with their own commands, favourites after with theirs, and
    /// separators fencing each list off from the commands about it.
    func testTheMenuIsTwoListsEachWithItsOwnCommands() throws {
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)
        favorite("ME FPT", "$FPT", .ascii)
        bar.prepareForShow()

        XCTAssertEqual(try shape(), [
            "Recent Queries",
            "\"DE AD\"  Hex bytes",
            "───",
            "Add to Favorites",
            "Clear Recents",
            "───",
            "Favorites",
            "ME FPT: \"$FPT\"  ASCII, ignore case",
            "───",
            "Manage Favorites…",
        ])
    }

    /// The headers carry their icons — `NSMenuItem.sectionHeader(title:)` takes
    /// only a title, so they are built by hand — and are not pickable.
    func testTheHeadersCarryIconsAndAreNotPickable() throws {
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)
        favorite("ME FPT", "$FPT", .ascii)
        bar.prepareForShow()

        let headers = try menu().items.filter { $0.action == nil && !$0.isSeparatorItem }
        XCTAssertEqual(headers.map { $0.attributedTitle?.string },
                       ["Recent Queries", "Favorites"])
        XCTAssertTrue(headers.allSatisfy { !$0.isEnabled }, "a header is not a row to pick")
        XCTAssertTrue(headers.allSatisfy { $0.image != nil }, "and it carries its icon")
    }

    /// An empty list is no list: its header, its rows and the command that only
    /// makes sense with rows in it are all absent. What stays is the pair of
    /// commands that work on nothing — keeping what is in the field, and
    /// opening the form.
    func testEmptyListsShowNoHeaderAndNoClear() throws {
        bar.prepareForShow()

        XCTAssertEqual(try shape(), ["Add to Favorites", "───", "Manage Favorites…"])
    }

    // MARK: - The row format

    /// A favourite is `Name: "pattern"  flags`; a recent is the same row
    /// without the name, because nothing typed into a field has one. The case
    /// rule is stated either way — and never for hex, where bytes have no case.
    func testARowStatesEverythingItSearchesWith() throws {
        FindHistoryStore.record(pattern: "boot", encoding: .ascii, caseSensitive: true)
        favorite("Windows loader", "windows", .utf16LE)
        favorite("Capsule header", "5A A5 F0 0F", .hex, caseSensitive: true)
        bar.prepareForShow()

        XCTAssertTrue(rows.contains("\"boot\"  ASCII, match case"))
        XCTAssertTrue(rows.contains("Windows loader: \"windows\"  UTF-16 LE, ignore case"))
        XCTAssertTrue(rows.contains("Capsule header: \"5A A5 F0 0F\"  Hex bytes"),
                      "hex says nothing about case, whatever the flag holds: \\(rows)")
    }

    /// A pattern its own encoding cannot read can only have been hand-edited
    /// into the store — `DE A` is not hex. The row is marked and stays
    /// pickable: the pick puts the text in the field, and what happens then is
    /// what would happen to that text typed by hand (§11).
    ///
    /// Which is two different things, and both are right. With the chosen
    /// encoding as the search, the bar reports the pattern as invalid. With
    /// Smart Search on, `DE A` is a perfectly good ASCII pattern and is
    /// searched as one — the entry's hex is simply the first encoding the pass
    /// skips.
    func testAnUnusableRowIsMarkedAndStillPickable() throws {
        favorite("Hand-edited", "DE A", .hex)
        bar.prepareForShow()

        let row = try XCTUnwrap(try menu().items.first {
            ($0.attributedTitle?.string ?? "").hasPrefix("Hand-edited")
        })
        XCTAssertNotNil(row.image, "the row is marked")
        XCTAssertNotNil(row.action, "and it can still be picked")

        // Smart Search on (the default): the text is searched as text.
        XCTAssertTrue(bar.smartSearchOnForTests, "the premise")
        XCTAssertTrue(bar.pickPatternRowForTests(startingWith: "Hand-edited"))
        XCTAssertEqual(bar.patternTextForTests, "DE A", "the text goes in as it stands")
        XCTAssertEqual(searched.count, 1, "and Smart Search has something to look for")
        XCTAssertEqual(bar.countTextForTests, "", "so there is nothing to complain about")

        // The chosen encoding as the search: now hex is the search, and hex
        // cannot read it.
        searched = []
        bar.smartButton.performClick(nil)
        XCTAssertTrue(bar.pickPatternRowForTests(startingWith: "Hand-edited"))
        XCTAssertEqual(bar.countTextForTests, "Invalid pattern",
                       "which the bar says where the count goes")
        XCTAssertTrue(searched.isEmpty, "and nothing was searched")
    }

    // MARK: - What a pick does

    /// A pick loads all three — pattern, encoding, case rule — and runs the
    /// search: a row is chosen deliberately, and the Return that would follow
    /// it never means anything else.
    func testAPickLoadsAllThreeAndSearches() throws {
        favorite("Windows loader", "windows", .utf16LE, caseSensitive: true)
        bar.prepareForShow()

        XCTAssertTrue(bar.pickPatternRowForTests(startingWith: "Windows loader"))

        XCTAssertEqual(bar.patternTextForTests, "windows")
        XCTAssertEqual(bar.encodingForTests, .utf16LE)
        XCTAssertTrue(bar.isCaseSensitive, "the case rule comes with it")
        XCTAssertEqual(bar.preferredEncodingForTests, .utf16LE,
                       "and it is where a Smart Search starts (§11)")
        XCTAssertEqual(searched.count, 1, "the pick searched")
    }

    /// And it records nothing: the history is what was *typed*, and spending
    /// its ten slots on things already kept elsewhere is the problem the
    /// favourites exist to solve.
    func testAPickRecordsNothingInTheHistory() throws {
        favorite("ME FPT", "$FPT", .ascii)
        bar.prepareForShow()
        XCTAssertTrue(FindHistoryStore.recent.isEmpty, "the premise")

        XCTAssertTrue(bar.pickPatternRowForTests(startingWith: "ME FPT"))

        XCTAssertTrue(FindHistoryStore.recent.isEmpty,
                      "a picked row is not a typed search")
    }

    // MARK: - The commands

    /// **Add to Favorites** hands the owner what the field describes — the
    /// pattern, the encoding the popup names (after a Smart Search, the one
    /// that *worked*), and the case rule. Asking for a name belongs to a
    /// window, not to a bar.
    func testAddToFavoritesHandsOverWhatTheFieldDescribes() throws {
        bar.prepareForShow()
        var offered: SearchPatternEntry?
        bar.onAddToFavorites = { offered = $0 }
        bar.setPatternForTests("windows")
        bar.setEncodingForTests(.utf16LE)

        XCTAssertTrue(bar.pickCommandForTests("Add to Favorites"))

        XCTAssertEqual(offered?.pattern, "windows")
        XCTAssertEqual(offered?.encoding, .utf16LE)
        XCTAssertEqual(offered?.name, "", "the name is the sheet's to ask for")
    }

    /// **Clear Recents** empties the history and nothing else — the favourites
    /// are a separate list — and the menu loses the section with it.
    func testClearRecentsEmptiesOnlyTheHistory() throws {
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)
        favorite("ME FPT", "$FPT", .ascii)
        bar.prepareForShow()
        XCTAssertTrue(rows.contains("\"DE AD\"  Hex bytes"), "the premise")

        XCTAssertTrue(bar.pickCommandForTests("Clear Recents"))

        XCTAssertTrue(FindHistoryStore.recent.isEmpty)
        XCTAssertEqual(FavoritePatternStore.favorites.count, 1, "the favourites stay")
        XCTAssertFalse(try shape().contains("Recent Queries"), "and the section goes")
        XCTAssertTrue(try shape().contains("Favorites"))
    }

    /// With an empty field there is nothing to keep, so the command is dimmed
    /// rather than absent — the same reading the stepper gives at zero matches
    /// (§11). Asked at menu-open time, because the field's text moves with
    /// every keystroke and the menu is a template built far less often.
    func testAddToFavoritesIsDeadOnAnEmptyField() throws {
        bar.prepareForShow()
        let item = try XCTUnwrap(try menu().items.first { $0.title == "Add to Favorites" })

        bar.setPatternForTests("   ")
        XCTAssertFalse(bar.validateMenuItem(item), "whitespace is not a pattern")

        bar.setPatternForTests("DE AD")
        XCTAssertTrue(bar.validateMenuItem(item))

        // And the commands that work on nothing are unaffected.
        let manage = try XCTUnwrap(try menu().items.first { $0.title == "Manage Favorites…" })
        bar.setPatternForTests("")
        XCTAssertTrue(bar.validateMenuItem(manage))
    }

    func testManageFavoritesAsksTheOwnerToOpenTheForm() throws {
        bar.prepareForShow()
        var opened = 0
        bar.onManageFavorites = { opened += 1 }

        XCTAssertTrue(bar.pickCommandForTests("Manage Favorites…"))

        XCTAssertEqual(opened, 1)
    }

    /// The menu follows the list it shows: a favourite added anywhere in the
    /// app reaches every bar's menu, because the store announces itself.
    func testTheMenuFollowsTheStore() throws {
        bar.prepareForShow()
        XCTAssertFalse(rows.contains { $0.hasPrefix("Late arrival") })

        favorite("Late arrival", "$FPT", .ascii)

        XCTAssertTrue(rows.contains { $0.hasPrefix("Late arrival") },
                      "the store's announcement rebuilt the menu: \\(rows)")
    }
}
