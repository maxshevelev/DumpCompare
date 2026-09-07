import XCTest
@testable import DumpCompareCore

/// §11 + `Design/FAVORITES_SYNC_PLAN.md`: what a kept search is made of, and
/// what survives being written down.
///
/// The entry gained the bookkeeping a shared library needs — an id, a place in
/// the order, a time and a machine — and none of it may change what the app
/// already does with the type.
final class SearchPatternEntryTests: XCTestCase {
    private func entry(_ name: String = "", _ pattern: String = "DE AD",
                       _ encoding: SearchEncoding = .hex,
                       caseSensitive: Bool = false) -> SearchPatternEntry {
        SearchPatternEntry(name: name, pattern: pattern, encoding: encoding,
                           caseSensitive: caseSensitive)
    }

    // MARK: - Identity

    /// Each entry gets an id of its own, and keeps it: identity by content is
    /// right for refusing duplicates and wrong the moment two machines are
    /// involved, where a rename would read as a delete plus an add.
    func testEveryEntryHasItsOwnId() {
        let one = entry("ME FPT", "$FPT", .ascii)
        let two = entry("ME FPT", "$FPT", .ascii)
        XCTAssertNotEqual(one.id, two.id, "two entries are two things, however alike")

        var renamed = one
        renamed.name = "Intel ME FPT"
        XCTAssertEqual(renamed.id, one.id, "a rename is the same entry, renamed")
    }

    /// Equality is about what an entry *says* — the same search under the same
    /// name — not about which record it is or when it was written.
    ///
    /// The history depends on it: it re-records the search already at its front
    /// on every press of ‹ ›, and compares the new list against the old to
    /// decide whether the menu needs rebuilding. With the id in the comparison
    /// that answer would always be "changed" (§11).
    func testEqualityIsAboutWhatTheEntrySaysNotWhichRecordItIs() {
        var one = entry("ME FPT", "$FPT", .ascii)
        var two = entry("ME FPT", "$FPT", .ascii)
        one.sortKey = 1
        two.sortKey = 99
        two.modifiedAt = one.modifiedAt.addingTimeInterval(3600)
        two.device = "another-mac"
        XCTAssertEqual(one, two)

        two.name = "Intel ME FPT"
        XCTAssertNotEqual(one, two, "a different name is a different thing to say")
    }

    /// The name is not part of what an entry *asks of a file*, which is what
    /// "do not keep the same search twice" is about.
    func testSameSearchIgnoresTheName() {
        XCTAssertTrue(entry("one", "$FPT", .ascii).isSameSearch(as: entry("other", "$FPT", .ascii)))
        XCTAssertFalse(entry("one", "$FPT", .ascii).isSameSearch(as: entry("one", "$FPT", .utf8)))
        XCTAssertFalse(entry("one", "$FPT", .ascii)
            .isSameSearch(as: entry("one", "$FPT", .ascii, caseSensitive: true)))
    }

    // MARK: - Persistence

    /// A favourite's row carries its bookkeeping, so its identity survives a
    /// launch — an id minted afresh on every read would be no identity at all.
    func testAFavouriteRoundTripsWithItsBookkeeping() throws {
        var kept = entry("ME FPT", "$FPT", .ascii)
        kept.sortKey = 2.5
        kept.device = "8B2C"
        let read = try XCTUnwrap(SearchPatternEntry(stored: kept.storedValue))

        XCTAssertEqual(read.id, kept.id)
        XCTAssertEqual(read.name, "ME FPT")
        XCTAssertEqual(read.pattern, "$FPT")
        XCTAssertEqual(read.encoding, .ascii)
        XCTAssertEqual(read.sortKey, 2.5)
        XCTAssertEqual(read.device, "8B2C")
        XCTAssertEqual(read.modifiedAt.timeIntervalSince1970,
                       kept.modifiedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A recent writes none of it: nothing typed into a field has a name, a
    /// place in a curated order, or anything to keep in step with another
    /// machine. The row stays exactly what it was before any of this existed.
    func testARecentWritesNoBookkeeping() {
        let row = entry("", "DE AD").recentValue
        XCTAssertEqual(Set(row.keys), ["pattern", "encoding", "caseSensitive"])
    }

    /// A row from before the bookkeeping existed reads back complete: the id is
    /// minted on the spot, which is also the migration.
    func testAnOldRowIsReadAndGivenAnId() throws {
        let legacy: [String: Any] = ["pattern": "DE AD", "encoding": "hex", "caseSensitive": false]
        let read = try XCTUnwrap(SearchPatternEntry(stored: legacy))

        XCTAssertEqual(read.pattern, "DE AD")
        XCTAssertEqual(read.encoding, .hex)
        XCTAssertEqual(read.sortKey, 0)
        XCTAssertTrue(read.device.isEmpty, "and it does not claim this Mac wrote it")
        XCTAssertNotEqual(read.id, UUID(uuid: UUID_NULL), "but it does get an id")
    }

    /// A row that is not an entry is skipped rather than crashing or wiping the
    /// list: a hand-edited plist, or an encoding this build no longer has.
    func testAnUnreadableRowIsNil() {
        XCTAssertNil(SearchPatternEntry(stored: ["encoding": "hex"]))
        XCTAssertNil(SearchPatternEntry(stored: ["pattern": "DE AD"]))
        XCTAssertNil(SearchPatternEntry(stored: ["pattern": "DE AD", "encoding": "klingon"]))
    }

    /// A garbled id or timestamp does not lose the entry — the pattern is the
    /// part that matters, and the bookkeeping is re-minted.
    func testGarbledBookkeepingDoesNotLoseTheEntry() throws {
        let row: [String: Any] = ["pattern": "DE AD", "encoding": "hex",
                                  "caseSensitive": false,
                                  "id": "not-a-uuid", "sortKey": "third",
                                  "modifiedAt": "yesterday"]
        let read = try XCTUnwrap(SearchPatternEntry(stored: row))
        XCTAssertEqual(read.pattern, "DE AD")
        XCTAssertEqual(read.sortKey, 0)
    }

    // MARK: - What the app asks of it

    func testUsabilityAndFoldingComeFromTheEncoding() {
        XCTAssertTrue(entry("", "DE AD", .hex).isUsable)
        XCTAssertFalse(entry("", "DE A", .hex).isUsable, "an odd hex digit is not a pattern")
        XCTAssertFalse(entry("", "", .ascii).isUsable)

        XCTAssertEqual(entry("", "41", .hex, caseSensitive: true).folding, .exact,
                       "bytes have no case")
        XCTAssertEqual(entry("", "root", .ascii).folding, .asciiBytes)
    }
}
