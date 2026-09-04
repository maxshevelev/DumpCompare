import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11: the patterns the user keeps, and how they differ from the ones the app
/// remembers for them (`Design/PATTERN_LIBRARY_IDEA.md`).
///
/// The history is a cache — ten entries, evicted by the next search. This is a
/// list the user curates, and the tests here are about the two properties that
/// make it one: nothing is evicted, and the order is theirs.
final class FavoritePatternStoreTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FavoritePatternStore.defaults = store
        FindHistoryStore.defaults = store
    }

    override func tearDown() {
        FavoritePatternStore.defaults = .standard
        FindHistoryStore.defaults = .standard
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    private func entry(_ name: String, _ pattern: String,
                       _ encoding: SearchEncoding = .hex,
                       caseSensitive: Bool = false) -> SearchPatternEntry {
        SearchPatternEntry(name: name, pattern: pattern, encoding: encoding,
                           caseSensitive: caseSensitive)
    }

    // MARK: - A favourite is a recent with a name

    /// The two lists hold the same type, which is what lets one row renderer,
    /// one pick handler and one validation serve both (§11).
    func testARecentIsTheSameTypeWithNoName() {
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)
        let recent = try? XCTUnwrap(FindHistoryStore.mostRecent)

        XCTAssertEqual(recent?.pattern, "DE AD")
        XCTAssertEqual(recent?.name, "", "nothing typed into a field has a name")

        // And naming one makes a favourite of it, with nothing else to change.
        var kept = try? XCTUnwrap(recent)
        kept?.name = "Aptio capsule header"
        XCTAssertTrue(FavoritePatternStore.add(try XCTUnwrap(kept)))
        XCTAssertEqual(FavoritePatternStore.favorites.first?.name, "Aptio capsule header")
        XCTAssertEqual(FavoritePatternStore.favorites.first?.pattern, "DE AD")
    }

    /// A recent's stored row gains no `name` key, so a store written before
    /// favourites existed reads back unchanged.
    func testARecentWritesNoNameKey() throws {
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)
        let rows = try XCTUnwrap(store.array(forKey: FindHistoryStore.userDefaultsKey)
            as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0]["name"])
        XCTAssertEqual(rows[0]["pattern"] as? String, "DE AD")
    }

    /// A row that is not an entry — a hand-edited plist, an encoding this build
    /// no longer has — is dropped rather than crashing or emptying the list.
    func testAnUnreadableRowIsSkipped() {
        store.set([["pattern": "DE AD", "encoding": "hex"],
                   ["pattern": "no encoding here"],
                   ["encoding": "ascii"],
                   ["pattern": "boot", "encoding": "klingon"],
                   ["pattern": "root", "encoding": "ascii", "name": "Root string"]],
                  forKey: FavoritePatternStore.userDefaultsKey)

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.pattern), ["DE AD", "root"])
        XCTAssertEqual(FavoritePatternStore.favorites.last?.name, "Root string")
    }

    // MARK: - Nothing is evicted, and the order is the user's

    /// The history's cap is what a library exists to escape: twenty kept
    /// patterns stay twenty.
    func testNothingIsEvicted() {
        for index in 0..<(FindHistoryStore.limit * 2) {
            FavoritePatternStore.add(entry("pattern \(index)", "\(index)0"))
        }
        XCTAssertEqual(FavoritePatternStore.favorites.count, FindHistoryStore.limit * 2)
    }

    /// Added entries go to the end, and the list is read back in that order —
    /// no sorting rule for the user to remember, and the form reorders by
    /// dragging.
    func testTheOrderIsTheOrderItWasGiven() {
        FavoritePatternStore.add(entry("first", "11"))
        FavoritePatternStore.add(entry("second", "22"))
        FavoritePatternStore.add(entry("third", "33"))

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["first", "second", "third"])

        // And a reorder is a replacement, which is what a dragged row saves.
        let reordered = Array(FavoritePatternStore.favorites.reversed())
        FavoritePatternStore.replace(with: reordered)
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["third", "second", "first"])
    }

    /// Keeping the same search twice under two names is two answers to one
    /// question, so it is refused — and the caller is handed the entry that is
    /// already there, to offer a rename instead.
    func testTheSameSearchIsNotKeptTwice() throws {
        XCTAssertTrue(FavoritePatternStore.add(entry("ME FPT", "$FPT", .ascii)))
        XCTAssertFalse(FavoritePatternStore.add(entry("Something else", "$FPT", .ascii)),
                       "the same pattern, encoding and case rule is the same search")
        XCTAssertEqual(FavoritePatternStore.favorites.count, 1)
        XCTAssertEqual(FavoritePatternStore.existing(for: entry("x", "$FPT", .ascii))?.name,
                       "ME FPT", "and the caller can say which entry it already is")
    }

    /// The same pattern in another encoding, or under another case rule, is a
    /// different search and is kept.
    func testTheSamePatternInAnotherEncodingIsAnotherEntry() {
        FavoritePatternStore.add(entry("as bytes", "4142", .hex))
        FavoritePatternStore.add(entry("as text", "4142", .ascii))
        FavoritePatternStore.add(entry("as text, exactly", "4142", .ascii, caseSensitive: true))

        XCTAssertEqual(FavoritePatternStore.favorites.count, 3)
        XCTAssertNil(FavoritePatternStore.existing(for: entry("", "4142", .utf16LE)),
                     "and an encoding nothing was kept under matches nothing")
    }

    /// Every reader of the list is told when it changes: a window's find bar
    /// does not own the store, and neither does the form that edits it.
    func testAChangeIsAnnounced() {
        var announcements = 0
        let token = NotificationCenter.default.addObserver(
            forName: FavoritePatternStore.didChangeNotification, object: nil, queue: nil) { _ in
            announcements += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        FavoritePatternStore.add(entry("one", "11"))
        FavoritePatternStore.replace(with: [])

        XCTAssertEqual(announcements, 2)
    }

    // MARK: - What an entry can hold

    /// An entry cannot stop being searchable: what it may hold is what the
    /// parser accepts, and the parser is code. The property exists for the one
    /// way round that — a plist edited by hand — and says so.
    func testAnEntryKnowsWhetherItCanStillBeSearched() {
        XCTAssertTrue(entry("bytes", "DE AD", .hex).isUsable)
        XCTAssertTrue(entry("text", "root", .ascii).isUsable)
        XCTAssertFalse(entry("hand-edited", "DE A", .hex).isUsable,
                       "an odd hex digit is not a pattern")
        XCTAssertFalse(entry("hand-edited", "", .ascii).isUsable)
    }

    /// The folding an entry searches with is the pair the engine takes — and
    /// hex folds nothing whatever the flag says (§11).
    func testTheFoldingComesFromTheEncodingAndTheFlag() {
        XCTAssertEqual(entry("a", "41", .hex, caseSensitive: false).folding, .exact)
        XCTAssertEqual(entry("a", "41", .hex, caseSensitive: true).folding, .exact,
                       "bytes have no case")
        XCTAssertEqual(entry("a", "root", .ascii, caseSensitive: false).folding, .asciiBytes)
        XCTAssertEqual(entry("a", "root", .ascii, caseSensitive: true).folding, .exact)
        XCTAssertEqual(entry("a", "root", .utf16LE, caseSensitive: false).folding,
                       .utf16(littleEndian: true))
    }
}
