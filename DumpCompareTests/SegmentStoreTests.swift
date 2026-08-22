import Foundation
import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Unit tests for the pane's segment partition (§21, Stage 1). The store is
/// AppKit-free and byte-free but lives in the app target, so it is tested here,
/// in the app suite, the way `BookmarkStore` is. Nothing is drawn and no
/// command exists yet — these exercise the partition's arithmetic and its
/// snapshot/restore, which is what makes undo able to bring a swallowed cut
/// back.
@MainActor
final class SegmentStoreTests: XCTestCase {

    // MARK: - The fresh partition

    func testAFreshFileIsOnePieceNamedAfterIt() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        XCTAssertEqual(store.segments.count, 1)
        XCTAssertEqual(store.segments[0].index, 0)
        XCTAssertEqual(store.segments[0].range, 0..<16)
        XCTAssertEqual(store.segments[0].name, "dump.bin")
    }

    // MARK: - Cuts

    func testACutMakesTwoPiecesAndRenumbersThem() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        XCTAssertTrue(store.addCut(at: 8))

        XCTAssertEqual(store.segments.count, 2)
        // The earlier piece keeps its name; the new (later) piece is unnamed.
        XCTAssertEqual(store.segments[0].index, 0)
        XCTAssertEqual(store.segments[0].range, 0..<8)
        XCTAssertEqual(store.segments[0].name, "dump.bin")
        XCTAssertEqual(store.segments[1].index, 1)
        XCTAssertEqual(store.segments[1].range, 8..<16)
        XCTAssertEqual(store.segments[1].name, "")
    }

    func testACutAtZeroOrEOFIsRefused() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        XCTAssertFalse(store.addCut(at: 0), "a cut at the file start is refused")
        XCTAssertFalse(store.addCut(at: 16), "a cut at EOF is refused")
        // A duplicate cut is refused too: every piece must stay non-empty.
        XCTAssertTrue(store.addCut(at: 8))
        XCTAssertFalse(store.addCut(at: 8))
        XCTAssertEqual(store.segments.count, 2)
    }

    func testRemovingACutMergesIntoTheEarlierPieceAndKeepsItsName() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        store.rename(1, to: "second")

        XCTAssertTrue(store.removeCut(at: 8))
        XCTAssertEqual(store.segments.count, 1)
        // The merged piece is the earlier one: it keeps its own name, not the
        // later piece's.
        XCTAssertEqual(store.segments[0].range, 0..<16)
        XCTAssertEqual(store.segments[0].name, "dump.bin")
        // Removing a cut that was never there is a no-op.
        XCTAssertFalse(store.removeCut(at: 8))
    }

    func testTwoCutsAddedInEitherOrderGiveTheSamePartition() {
        let forward = SegmentStore(size: 16, name: "dump.bin")
        forward.addCut(at: 4)
        forward.addCut(at: 8)

        let backward = SegmentStore(size: 16, name: "dump.bin")
        backward.addCut(at: 8)
        backward.addCut(at: 4)

        XCTAssertEqual(forward.cuts, backward.cuts)
        XCTAssertEqual(forward.segments, backward.segments)
        XCTAssertEqual(forward.segments.map(\.range), [0..<4, 4..<8, 8..<16])
    }

    // MARK: - Following the content (§21.2)

    func testAnInsertBeforeACutMovesIt() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)

        store.apply(.insert(at: 2, length: 4), newSize: 20)
        // The cut is strictly after the insert, so it shifts by +4.
        XCTAssertEqual(store.cuts, [12])
        XCTAssertEqual(store.segments[0].range, 0..<12)
        XCTAssertEqual(store.segments[1].range, 12..<20)
    }

    func testAnInsertAtACutJoinsThePieceThatStartsThere() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)

        store.apply(.insert(at: 8, length: 4), newSize: 20)
        // A cut exactly at the insert stays: the new bytes join the piece that
        // *starts* there, so the cut does not move.
        XCTAssertEqual(store.cuts, [8])
        XCTAssertEqual(store.segments[0].range, 0..<8)
        XCTAssertEqual(store.segments[1].range, 8..<20)
    }

    func testOverwritingNeverMovesACut() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)

        // In-file overwrite: offsets are preserved, the cut stays put.
        store.apply(.overwrite(range: 2..<6), newSize: 16)
        XCTAssertEqual(store.cuts, [8])
        XCTAssertEqual(store.segments[0].range, 0..<8)
        XCTAssertEqual(store.segments[1].range, 8..<16)

        // An overwrite that grows the file (a paste past EOF) moves no cut
        // either; the later piece simply extends.
        store.apply(.overwrite(range: 14..<20), newSize: 20)
        XCTAssertEqual(store.cuts, [8])
        XCTAssertEqual(store.segments[1].range, 8..<20)
    }

    func testADeleteThatSwallowsACutMergesThePieces() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        store.rename(1, to: "second")

        // The deletion spans the cut at 8: the two pieces it separated merge
        // into the one that starts before the deletion, which keeps its name.
        store.apply(.delete(range: 4..<12), newSize: 8)
        XCTAssertEqual(store.segments.count, 1)
        XCTAssertEqual(store.segments[0].range, 0..<8)
        XCTAssertEqual(store.segments[0].name, "dump.bin")
    }

    func testADeleteThatEmptiesAPieceRemovesIt() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        store.rename(1, to: "second")

        // Deleting the whole later piece drops it with its name; the earlier
        // piece stands alone and the list renumbers.
        store.apply(.delete(range: 8..<16), newSize: 8)
        XCTAssertEqual(store.segments.count, 1)
        XCTAssertEqual(store.segments[0].range, 0..<8)
        XCTAssertEqual(store.segments[0].name, "dump.bin")
    }

    // MARK: - Undo by snapshot

    func testUndoRestoresTheCutsADeleteRemoved() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        store.rename(1, to: "second")

        // The snapshot is what makes undo possible: the cut's offset and name
        // are not in the delete edit, so only a saved partition can bring them
        // back.
        let snapshot = store.snapshot()
        store.apply(.delete(range: 4..<12), newSize: 8)
        XCTAssertEqual(store.segments.count, 1, "the delete swallowed the cut")

        store.restore(snapshot)
        XCTAssertEqual(store.segments.count, 2)
        XCTAssertEqual(store.cuts, [8])
        XCTAssertEqual(store.segments[0].range, 0..<8)
        XCTAssertEqual(store.segments[1].range, 8..<16)
        XCTAssertEqual(store.segments[1].name, "second")
    }

    // MARK: - Containment

    func testSegmentContainingIsHalfOpenAtBothEnds() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)

        // A cut belongs to the piece that *starts* there: [0, 8) is index 0,
        // [8, 16) is index 1.
        XCTAssertEqual(store.segment(containing: 0)?.index, 0)
        XCTAssertEqual(store.segment(containing: 7)?.index, 0)
        XCTAssertEqual(store.segment(containing: 8)?.index, 1)
        XCTAssertEqual(store.segment(containing: 15)?.index, 1)
        // Past the end of the file there is no piece.
        XCTAssertNil(store.segment(containing: 16))
    }
}
