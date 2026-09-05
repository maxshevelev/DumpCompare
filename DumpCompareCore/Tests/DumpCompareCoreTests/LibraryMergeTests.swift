import XCTest
@testable import DumpCompareCore

/// `Design/FAVORITES_SYNC_PLAN.md`: the merge, which is the feature.
///
/// A shared file is not a lock — two machines write inside the sync window, and
/// what comes back has to be reconciled without losing anything and without
/// asking about everything. These tests are the plan's table of cases: what is
/// decided silently, and the three things that must never be.
final class LibraryMergeTests: XCTestCase {
    private let mac = "desk-mac"
    private let laptop = "laptop"

    private func entry(_ name: String, _ pattern: String, id: UUID = UUID(),
                       sortKey: Double = 1024, device: String = "desk-mac",
                       at seconds: TimeInterval = 0) -> SearchPatternEntry {
        SearchPatternEntry(id: id, name: name, pattern: pattern, encoding: .hex,
                           sortKey: sortKey,
                           modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
                           device: device)
    }

    /// A library as one machine holds it, having written it `writes` times.
    private func library(_ entries: [SearchPatternEntry],
                         tombstones: [PatternLibrary.Tombstone] = [],
                         vector: [String: Int]) -> PatternLibrary {
        PatternLibrary(entries: entries, tombstones: tombstones, vector: VersionVector(vector))
    }

    // MARK: - Not every difference is a merge

    /// The ordinary case: one machine wrote, the other reads it later. Nothing
    /// is concurrent, so the version that has seen more simply wins — no
    /// three-way anything, and no questions.
    func testAVersionThatHasSeenEverythingSimplyWins() {
        let mine = library([entry("ME FPT", "$FPT")], vector: [mac: 1])
        let theirs = library([entry("ME FPT", "$FPT"), entry("Capsule", "5A A5")],
                             vector: [mac: 1, laptop: 1])

        let outcome = LibraryMerge.merge(base: mine, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertEqual(outcome.library.entries.map(\.name), ["ME FPT", "Capsule"])
    }

    /// And the other way round: a file that adds nothing this machine has not
    /// seen leaves the local list exactly as it is.
    func testAStaleFileChangesNothing() {
        let theirs = library([entry("ME FPT", "$FPT")], vector: [mac: 1])
        let mine = library([entry("ME FPT", "$FPT"), entry("Capsule", "5A A5")],
                           vector: [mac: 2])

        let outcome = LibraryMerge.merge(base: theirs, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertEqual(outcome.library.entries.map(\.name), ["ME FPT", "Capsule"])
    }

    // MARK: - Concurrent, and decidable

    /// Twelve patterns here and three there should make fifteen: the case that
    /// actually happens, and it needs no question.
    func testConcurrentAdditionsAreBothKept() {
        let shared = entry("ME FPT", "$FPT")
        let base = library([shared], vector: [mac: 1])
        let mine = library([shared, entry("mine", "11")], vector: [mac: 2])
        let theirs = library([shared, entry("theirs", "22", device: "laptop")],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertEqual(Set(outcome.library.entries.map(\.name)), ["ME FPT", "mine", "theirs"])
        XCTAssertEqual(outcome.library.vector[mac], 2, "and the merged version has seen both")
        XCTAssertEqual(outcome.library.vector["laptop"], 1)
    }

    /// One side changed an entry and the other did not: that side's value is
    /// the answer, and nobody is asked.
    func testOnlyOneSideChangedIt() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 2])
        let theirs = library([entry("Intel ME FPT", "$FPT", id: id, device: "laptop")],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertEqual(outcome.library.entries.map(\.name), ["Intel ME FPT"])
    }

    /// Both sides made the same change — a merge with nothing to reconcile.
    func testBothSidesChangedItTheSameWay() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let renamed = entry("Intel ME FPT", "$FPT", id: id)
        let mine = library([renamed], vector: [mac: 2])
        let theirs = library([renamed], vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertEqual(outcome.library.entries.map(\.name), ["Intel ME FPT"])
    }

    /// A deletion with a tombstone propagates: the entry goes, silently, and
    /// the tombstone travels so the next machine hears about it too.
    func testADeletionTravels() {
        let id = UUID()
        let doomed = entry("mistake", "11", id: id)
        let base = library([doomed], vector: [mac: 1])
        let mine = library([doomed], vector: [mac: 1])
        let theirs = library([], tombstones: [PatternLibrary.Tombstone(id: id, device: laptop)],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertTrue(outcome.library.entries.isEmpty)
        XCTAssertEqual(outcome.library.tombstones.map(\.id), [id], "and the news travels on")
    }

    /// Absence without a tombstone is not a deletion. A line deleted from the
    /// file by hand comes back — the safe way round, since the alternative
    /// loses patterns to a text editor.
    func testALineRemovedByHandIsNotADeletion() {
        let id = UUID()
        let kept = entry("ME FPT", "$FPT", id: id)
        let base = library([kept], vector: [mac: 1])
        let mine = library([kept], vector: [mac: 2])
        let theirs = library([], vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertEqual(outcome.library.entries.map(\.name), ["ME FPT"])
        XCTAssertTrue(outcome.isResolved)
    }

    /// The file's order leads, so one machine's reordering is not undone by the
    /// other's, and entries only this machine has are appended after it.
    func testTheFilesOrderLeadsAndLocalEntriesFollow() {
        let a = UUID(), b = UUID()
        let base = library([entry("a", "11", id: a, sortKey: 1024),
                            entry("b", "22", id: b, sortKey: 2048)], vector: [mac: 1])
        let mine = library([entry("a", "11", id: a, sortKey: 1024),
                            entry("b", "22", id: b, sortKey: 2048),
                            entry("mine", "33", sortKey: 3072)], vector: [mac: 2])
        // They dragged b above a.
        let theirs = library([entry("a", "11", id: a, sortKey: 1024),
                              entry("b", "22", id: b, sortKey: 512)],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertEqual(outcome.library.ordered.map(\.name), ["b", "a", "mine"])
    }

    /// Both sides kept the same search under the same name, without knowing:
    /// one entry, chosen the same way on both machines so they do not each keep
    /// the other's.
    func testTheSameSearchAddedTwiceBecomesOneEntry() {
        let base = library([], vector: [mac: 1])
        let mine = library([entry("Capsule", "5A A5", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)],
                           vector: [mac: 2])
        let theirs = library([entry("Capsule", "5A A5", id: UUID(uuidString: "FF000000-0000-0000-0000-000000000002")!, device: "laptop")],
                             vector: [mac: 1, "laptop": 1])

        let ourView = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)
        let theirView = LibraryMerge.merge(base: base, ours: theirs, theirs: mine)

        XCTAssertTrue(ourView.isResolved)
        XCTAssertEqual(ourView.library.entries.count, 1)
        XCTAssertEqual(ourView.library.entries.map(\.id), theirView.library.entries.map(\.id),
                       "both machines must land on the same entry")
    }

    // MARK: - The three questions

    /// The same entry, changed differently on both sides. Nothing is decided,
    /// and this machine's version is what the app goes on showing meanwhile.
    func testBothChangedItDifferentlyIsAQuestion() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([entry("Intel ME FPT", "$FPT", id: id)], vector: [mac: 2])
        let theirs = library([entry("ME region table", "$FPT", id: id, device: "laptop")],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertEqual(outcome.conflicts.count, 1)
        guard case let .bothEdited(ours, theirs) = outcome.conflicts[0] else {
            return XCTFail("expected bothEdited, got \(outcome.conflicts[0])")
        }
        XCTAssertEqual(ours.name, "Intel ME FPT")
        XCTAssertEqual(theirs.name, "ME region table")
        XCTAssertEqual(outcome.library.entries.map(\.name), ["Intel ME FPT"],
                       "and something true is shown until it is answered")
    }

    /// Edited here, deleted there: the case where a rule either loses an edit
    /// or resurrects something deliberately removed.
    func testEditedHereAndDeletedThereIsAQuestion() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([entry("Intel ME FPT", "$FPT", id: id)], vector: [mac: 2])
        let theirs = library([], tombstones: [PatternLibrary.Tombstone(id: id, device: laptop)],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertEqual(outcome.conflicts.count, 1)
        guard case let .editedAndDeleted(entry, deletedBy, deletedHere) = outcome.conflicts[0] else {
            return XCTFail("expected editedAndDeleted, got \(outcome.conflicts[0])")
        }
        XCTAssertEqual(entry.name, "Intel ME FPT")
        XCTAssertEqual(deletedBy, laptop, "the sheet says who deleted it")
        XCTAssertFalse(deletedHere, "the edit is this machine's side")
    }

    /// And the same question from the other side: **the machine that deleted it
    /// asks too.**
    ///
    /// It used to keep its deletion silently — and silence is not neutral here.
    /// A machine that decides without asking folds the other's counters into
    /// its own, counters that cover the other machine's version are how an
    /// answer travels, and so the deletion arrived over there as somebody's
    /// answer and took the edit with it a few seconds after the question had
    /// been raised.
    func testDeletedHereAndEditedThereIsAQuestionToo() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([], tombstones: [PatternLibrary.Tombstone(id: id, device: mac)],
                           vector: [mac: 2])
        let theirs = library([entry("ME region table", "$FPT", id: id)],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertEqual(outcome.conflicts.count, 1)
        guard case let .editedAndDeleted(entry, deletedBy, deletedHere) = outcome.conflicts[0] else {
            return XCTFail("expected editedAndDeleted, got \(outcome.conflicts[0])")
        }
        XCTAssertEqual(entry.name, "ME region table", "the row shows the version at stake")
        XCTAssertEqual(deletedBy, mac)
        XCTAssertTrue(deletedHere, "the deletion is this machine's side")
        XCTAssertTrue(outcome.library.entries.isEmpty,
                      "and the deletion is what it says meanwhile")
    }

    /// Answering it either way, from the side that deleted.
    func testAnsweringFromTheSideThatDeleted() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([], tombstones: [PatternLibrary.Tombstone(id: id, device: mac)],
                           vector: [mac: 2])
        let theirs = library([entry("ME region table", "$FPT", id: id)],
                             vector: [mac: 1, "laptop": 1])
        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        let kept = LibraryMerge.resolve(outcome, with: [id: .keepTheirs])
        XCTAssertEqual(kept.entries.map(\.name), ["ME region table"],
                       "keeping their version takes the deletion back")
        XCTAssertTrue(kept.tombstones.isEmpty, "and the tombstone with it")

        let deleted = LibraryMerge.resolve(outcome, with: [id: .keepOurs])
        XCTAssertTrue(deleted.entries.isEmpty, "keeping the deletion leaves it deleted")
        XCTAssertEqual(deleted.tombstones.map(\.id), [id], "with the tombstone still there")
    }

    /// An entry kept against a deletion stays kept — the note that started it
    /// does not come back from the machine that still holds it.
    ///
    /// That machine's file goes on carrying the tombstone, and once the answer
    /// has been applied the base holds no entry to reason from: "we changed it
    /// since the base" cannot be said about something the base does not have.
    /// So where the base is silent, the later of the two events wins, and
    /// answering stamps the entry as changed now.
    func testAnEntryKeptAgainstADeletionIsNotDeletedAgain() {
        let id = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        var kept = entry("Intel ME FPT", "$FPT", id: id)
        kept.modifiedAt = deletedAt.addingTimeInterval(60)     // answered afterwards
        let mine = library([kept], vector: [mac: 3])
        let theirs = library([], tombstones: [PatternLibrary.Tombstone(id: id, deletedAt: deletedAt,
                                                                       device: laptop)],
                             vector: [mac: 1, "laptop": 2])

        let outcome = LibraryMerge.merge(base: nil, ours: mine, theirs: theirs,
                                         assumeConcurrent: true)

        XCTAssertTrue(outcome.conflicts.isEmpty, "the user answered this already")
        XCTAssertEqual(outcome.library.entries.map(\.name), ["Intel ME FPT"])
        XCTAssertTrue(outcome.library.tombstones.isEmpty, "and the note goes with it")
    }

    /// The same rule from the other side, and it has to be the same rule: two
    /// machines applying different ones would settle differently and hand the
    /// results to each other for ever.
    func testTheMachineHoldingTheNoteTakesTheRevivalBack() {
        let id = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        var revived = entry("Intel ME FPT", "$FPT", id: id)
        revived.modifiedAt = deletedAt.addingTimeInterval(60)
        let mine = library([], tombstones: [PatternLibrary.Tombstone(id: id, deletedAt: deletedAt,
                                                                     device: mac)],
                           vector: [mac: 2])
        let theirs = library([revived], vector: [mac: 1, "laptop": 3])

        let outcome = LibraryMerge.merge(base: nil, ours: mine, theirs: theirs,
                                         assumeConcurrent: true)

        XCTAssertTrue(outcome.conflicts.isEmpty)
        XCTAssertEqual(outcome.library.entries.map(\.name), ["Intel ME FPT"])
    }

    /// And a deletion nobody has answered still stands: an entry last touched
    /// *before* the note is what the note is about.
    func testAnUntouchedEntryStaysDeleted() {
        let id = UUID()
        var stale = entry("ME FPT", "$FPT", id: id)
        stale.modifiedAt = Date(timeIntervalSince1970: 1_000)
        let mine = library([stale], vector: [mac: 1])
        let theirs = library([], tombstones: [PatternLibrary.Tombstone(
            id: id, deletedAt: Date(timeIntervalSince1970: 2_000), device: laptop)],
                             vector: ["laptop": 2])

        let outcome = LibraryMerge.merge(base: nil, ours: mine, theirs: theirs,
                                         assumeConcurrent: true)

        XCTAssertTrue(outcome.conflicts.isEmpty)
        XCTAssertTrue(outcome.library.entries.isEmpty, "the deletion travels")
    }

    /// One search, two names: §11 keeps a search once, and which name it
    /// carries is not the app's to choose.
    func testTheSameSearchUnderTwoNamesIsAQuestion() {
        let base = library([], vector: [mac: 1])
        let mine = library([entry("Capsule header", "5A A5")], vector: [mac: 2])
        let theirs = library([entry("Aptio capsule", "5A A5", device: "laptop")],
                             vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        XCTAssertEqual(outcome.conflicts.count, 1)
        guard case let .sameSearchTwoNames(ours, theirs) = outcome.conflicts[0] else {
            return XCTFail("expected sameSearchTwoNames, got \(outcome.conflicts[0])")
        }
        XCTAssertEqual(ours.name, "Capsule header")
        XCTAssertEqual(theirs.name, "Aptio capsule")
        XCTAssertEqual(outcome.library.entries.count, 1, "one search, one entry")
    }

    // MARK: - Answering

    func testKeepingTheirsTakesTheirVersion() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([entry("Intel ME FPT", "$FPT", id: id)], vector: [mac: 2])
        let theirs = library([entry("ME region table", "$FPT", id: id, device: "laptop")],
                             vector: [mac: 1, "laptop": 1])
        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        let resolved = LibraryMerge.resolve(outcome, with: [id: .keepTheirs])

        XCTAssertEqual(resolved.entries.map(\.name), ["ME region table"])
    }

    func testKeepingOursLeavesTheMergedLibraryAsItIs() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([entry("Intel ME FPT", "$FPT", id: id)], vector: [mac: 2])
        let theirs = library([entry("ME region table", "$FPT", id: id, device: "laptop")],
                             vector: [mac: 1, "laptop": 1])
        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        let resolved = LibraryMerge.resolve(outcome, with: [id: .keepOurs])

        XCTAssertEqual(resolved.entries.map(\.name), ["Intel ME FPT"])
    }

    /// Answering "they were right to delete it" records the deletion properly,
    /// so it does not come back on the next merge.
    func testAcceptingADeletionLeavesATombstone() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([entry("Intel ME FPT", "$FPT", id: id)], vector: [mac: 2])
        let theirs = library([], tombstones: [PatternLibrary.Tombstone(id: id, device: laptop)],
                             vector: [mac: 1, "laptop": 1])
        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        let resolved = LibraryMerge.resolve(outcome, with: [id: .keepTheirs])

        XCTAssertTrue(resolved.entries.isEmpty)
        XCTAssertEqual(resolved.tombstones.map(\.id), [id])
    }

    /// And keeping ours takes the tombstone away, or the next merge would
    /// delete what the user just chose to keep.
    func testKeepingAnEditedEntryDropsTheirTombstone() {
        let id = UUID()
        let base = library([entry("ME FPT", "$FPT", id: id)], vector: [mac: 1])
        let mine = library([entry("Intel ME FPT", "$FPT", id: id)], vector: [mac: 2])
        let theirs = library([], tombstones: [PatternLibrary.Tombstone(id: id, device: laptop)],
                             vector: [mac: 1, "laptop": 1])
        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        let resolved = LibraryMerge.resolve(outcome, with: [id: .keepOurs])

        XCTAssertEqual(resolved.entries.map(\.name), ["Intel ME FPT"])
        XCTAssertTrue(resolved.tombstones.isEmpty)
    }

    /// Two genuinely different searches can both stay, which is the one place
    /// "keep both" means anything.
    func testKeepingBothNames() {
        let base = library([], vector: [mac: 1])
        let mine = library([entry("Capsule header", "5A A5")], vector: [mac: 2])
        let theirs = library([entry("Aptio capsule", "5A A5", device: "laptop")],
                             vector: [mac: 1, "laptop": 1])
        let outcome = LibraryMerge.merge(base: base, ours: mine, theirs: theirs)

        let resolved = LibraryMerge.resolve(outcome, with: [outcome.conflicts[0].id: .keepBoth])

        XCTAssertEqual(Set(resolved.entries.map(\.name)), ["Capsule header", "Aptio capsule"])
    }

    // MARK: - Tombstones do not pile up

    /// A deletion is remembered long enough for a machine that was away to hear
    /// about it, and no longer — a file that grows forever is a bug too.
    func testOldTombstonesArePruned() {
        let recent = PatternLibrary.Tombstone(id: UUID(), deletedAt: Date(), device: "desk-mac")
        let ancient = PatternLibrary.Tombstone(
            id: UUID(),
            deletedAt: Date(timeIntervalSinceNow: -LibraryMerge.tombstoneLifetime - 60),
            device: "desk-mac")
        let mine = library([], tombstones: [recent, ancient], vector: [mac: 2])
        let theirs = library([], vector: [mac: 1, "laptop": 1])

        let outcome = LibraryMerge.merge(base: nil, ours: mine, theirs: theirs)

        XCTAssertEqual(outcome.library.tombstones.map(\.id), [recent.id])
    }

    /// An entry that is here and a note saying it was deleted cannot both be
    /// true. The keeping won — and a note left behind would delete it again on
    /// the next merge, which is a pattern that disappears a minute after the
    /// user chose to keep it.
    func testATombstoneForAnEntryThatSurvivedIsDropped() {
        let id = UUID()
        let kept = entry("ME FPT", "$FPT", id: id)
        let mine = library([kept], tombstones: [PatternLibrary.Tombstone(id: id, device: laptop)],
                           vector: [mac: 2])
        let theirs = library([kept], vector: [mac: 2])

        let outcome = LibraryMerge.merge(base: nil, ours: mine, theirs: theirs)

        XCTAssertEqual(outcome.library.entries.map(\.name), ["ME FPT"])
        XCTAssertTrue(outcome.library.tombstones.isEmpty,
                      "the note contradicts the entry beside it")
    }

    // MARK: - No common past

    /// The first time this machine sees the file there is no base: everything
    /// either side has is kept, which is the adoption case (§11's "merge" answer
    /// when pointing at a file that already holds patterns).
    func testWithNoBaseEverythingIsKept() {
        let mine = library([entry("mine", "11")], vector: [mac: 3])
        let theirs = library([entry("theirs", "22", device: "laptop")], vector: ["laptop": 4])

        let outcome = LibraryMerge.merge(base: nil, ours: mine, theirs: theirs)

        XCTAssertTrue(outcome.isResolved)
        XCTAssertEqual(Set(outcome.library.entries.map(\.name)), ["mine", "theirs"])
    }
}
