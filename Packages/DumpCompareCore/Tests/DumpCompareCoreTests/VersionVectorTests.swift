import XCTest
@testable import DumpCompareCore

/// `Design/FAVORITES_SYNC_PLAN.md`: what tells a concurrent write from a later
/// one, which timestamps cannot — two Macs' clocks disagree by more than a sync
/// takes, and clock skew must not decide whose pattern survives.
final class VersionVectorTests: XCTestCase {
    func testAVersionDominatesOneItHasSeenEverythingOf() {
        let earlier = VersionVector(["desk": 2])
        let later = VersionVector(["desk": 3, "laptop": 1])

        XCTAssertTrue(later.dominates(earlier))
        XCTAssertFalse(earlier.dominates(later))
        XCTAssertFalse(later.isConcurrent(with: earlier), "one saw the other; nothing to merge")
    }

    /// Each wrote without seeing the other: the case the merge exists for.
    func testNeitherHavingSeenTheOtherIsConcurrent() {
        let mine = VersionVector(["desk": 3, "laptop": 1])
        let theirs = VersionVector(["desk": 2, "laptop": 2])

        XCTAssertTrue(mine.isConcurrent(with: theirs))
        XCTAssertTrue(theirs.isConcurrent(with: mine))
    }

    /// A version equal to another has seen everything it has — that is not a
    /// conflict, it is the same state.
    func testEqualVersionsAreNotConcurrent() {
        let one = VersionVector(["desk": 2])
        XCTAssertFalse(one.isConcurrent(with: VersionVector(["desk": 2])))
        XCTAssertTrue(one.dominates(VersionVector(["desk": 2])))
    }

    /// An empty version has seen nothing, and everything has seen it.
    func testAnEmptyVersionIsDominatedByEverything() {
        XCTAssertTrue(VersionVector(["desk": 1]).dominates(VersionVector()))
        XCTAssertFalse(VersionVector().dominates(VersionVector(["desk": 1])))
    }

    func testWritingCountsAndMergingTakesTheHigherCount() {
        var mine = VersionVector(["desk": 2])
        mine.increment(for: "desk")
        XCTAssertEqual(mine["desk"], 3)
        mine.increment(for: "new-machine")
        XCTAssertEqual(mine["new-machine"], 1)

        let merged = mine.merged(with: VersionVector(["desk": 1, "laptop": 5]))
        XCTAssertEqual(merged["desk"], 3)
        XCTAssertEqual(merged["laptop"], 5)
        XCTAssertEqual(merged["new-machine"], 1)
        XCTAssertTrue(merged.dominates(mine), "a merged version has seen both")
    }

    /// It is written as the plain dictionary it is, so the file stays legible.
    func testItIsStoredAsADictionary() throws {
        let encoded = try JSONEncoder().encode(VersionVector(["desk": 2]))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"{"desk":2}"#)
        XCTAssertEqual(try JSONDecoder().decode(VersionVector.self, from: encoded),
                       VersionVector(["desk": 2]))
    }
}
