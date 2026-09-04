import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11: what the Find bar says about a search. The states are the point — a
/// count in the thousands is the app telling the user the pattern is too
/// generic — so they are decided in a value and asserted without a window
/// (`Design/FIND_HIGHLIGHT_PLAN.md`).
final class FindCountTests: XCTestCase {
    private let pattern = SearchPattern(bytes: [0xAA], encoding: .hex)

    private func set(total: Int, extent: UInt64 = 1 << 20,
                     storage: MatchSet.Storage? = nil) -> MatchSet {
        MatchSet(pattern: pattern, folding: .exact, extent: extent, total: total,
                 storage: storage ?? .sparse((0..<total).map { UInt64($0) * 8 }))
    }

    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value))!
    }

    /// No session, no statement: the bar stays quiet until a search has been run.
    func testNoSessionReadsAsNothing() {
        XCTAssertNil(FindCount.reading(of: nil, current: nil))
    }

    func testTheOrdinalAndTheTotal() {
        let reading = try? XCTUnwrap(FindCount.reading(of: set(total: 128), current: 2))
        XCTAssertEqual(reading?.text, "3 of 128", "the ordinal is 1-based, as the user counts")
        XCTAssertNil(reading?.warning)
    }

    /// Before the first step there is a count but no position — the state the
    /// bar is in while nothing has been stepped to yet.
    func testATotalWithoutAPosition() {
        XCTAssertEqual(FindCount.reading(of: set(total: 12), current: nil)?.text, "12")
    }

    /// A pattern that occurs nowhere is a standing statement, not a number.
    func testNothingFoundSaysSo() {
        let reading = FindCount.reading(of: set(total: 0, storage: .sparse([])), current: nil)
        XCTAssertEqual(reading?.text, "Not found")
        XCTAssertEqual(reading?.hasMatches, false)
        XCTAssertNil(reading?.warning, "an empty result explains itself")
    }

    /// Six figures are read, not glanced at, so they are grouped.
    func testLargeCountsAreGrouped() {
        XCTAssertEqual(FindCount.reading(of: set(total: 4812), current: 2)?.text,
                       "3 of \(grouped(4812))")
    }

    /// Past the listing limit the count stays exact — it is the diagnosis — and
    /// the reason the panel will not list them travels with it.
    func testPastTheListingLimitTheReasonTravelsWithTheCount() {
        let limit = SearchEngine.defaultMaxResults
        XCTAssertNil(FindCount.reading(of: set(total: limit), current: 0)?.warning,
                     "exactly the limit still lists")
        XCTAssertEqual(FindCount.reading(of: set(total: limit + 1), current: 0)?.warning,
                       "Too many matches to list. Refine the pattern.")
    }

    /// When the positions were never kept, the greys are the loss worth naming
    /// — and the sentence says what still holds, so the user is not left
    /// guessing whether the search worked.
    func testACountedSetWarnsAboutTheHighlightingInstead() {
        let counted = MatchSet(pattern: pattern, folding: .exact, extent: 1 << 30,
                               total: 2_481_903, storage: .counted)
        let reading = FindCount.reading(of: counted, current: nil)
        XCTAssertEqual(reading?.text, grouped(2_481_903))
        XCTAssertEqual(reading?.warning,
                       "Too many matches to highlight — navigation and the map still cover all of them.")
    }
    /// A half-built index has no count to report: the number would climb while
    /// the user read it, and "3 of 4 812" would quietly mean "of 4 812 so
    /// far". What says the work is still running is the status bar's own
    /// operation (§11).
    func testAnIndexStillBeingBuiltHasNoReading() {
        let pattern = SearchPattern(bytes: [0xAA], encoding: .hex)
        let partial = MatchSet(pattern: pattern, folding: .exact, extent: 1024,
                               starts: [0, 8, 16], indexedUpTo: 32)
        XCTAssertFalse(partial.isComplete, "the premise")
        XCTAssertNil(FindCount.reading(of: partial, current: 0))

        let whole = MatchSet(pattern: pattern, folding: .exact, extent: 1024,
                             starts: [0, 8, 16])
        let reading = try? XCTUnwrap(FindCount.reading(of: whole, current: 0))
        XCTAssertEqual(reading?.total, 3, "the finished index reports, and reports exactly")
        XCTAssertEqual(reading?.text, "1 of 3")
    }

}
