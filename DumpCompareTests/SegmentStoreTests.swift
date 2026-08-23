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

    // MARK: - The positional label

    /// The label is built in one place — `S<index>` — and the instance and the
    /// index-only forms agree, so the form's label column, the status bar, the
    /// menu titles, the saved file names and the Save All preview all read the
    /// same shape (§21.4).
    func testTheLabelIsBuiltInOnePlace() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        store.addCut(at: 12)

        // Three pieces: the labels are S0, S1, S2 — the one shape every site
        // that names a piece reads.
        XCTAssertEqual(store.segments.map(\.label), ["S0", "S1", "S2"])
        // A site that has only the index (the Save All preview) formats it the
        // same way as a site that has the piece.
        for segment in store.segments {
            XCTAssertEqual(segment.label, Segment.label(for: segment.index))
        }
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

    // MARK: - Invalidation (§21.3)

    /// A cut repaints from the cut to the end, not the whole file: the pieces
    /// before it keep their colour and label, so their rows are untouched. The
    /// new piece and every later one renumber, so everything from the cut on
    /// moves.
    func testACutInvalidatesFromItselfToEnd() {
        let store = SegmentStore(size: 32, name: "dump.bin")
        var fired: [Range<UInt64>] = []
        store.onChange = { fired.append($0) }

        store.addCut(at: 8)

        XCTAssertEqual(fired, [8..<32], "a cut repaints from the cut to the end, not from 0")
    }

    /// Removing a cut is the same rule in reverse: the merged piece and every
    /// later one change colour, so the repaint runs from the removed cut on.
    func testRemovingACutInvalidatesFromItselfToEnd() {
        let store = SegmentStore(size: 32, name: "dump.bin")
        store.addCut(at: 8)
        store.addCut(at: 16)

        var fired: [Range<UInt64>] = []
        store.onChange = { fired.append($0) }

        store.removeCut(at: 8)

        XCTAssertEqual(fired, [8..<32], "a removal repaints from the removed cut to the end")
    }

    /// A rename changes no drawing — the tint is by position, not name, and the
    /// status bar reads the label and range — so it fires no invalidation at all.
    func testARenameInvalidatesNothing() {
        let store = SegmentStore(size: 32, name: "dump.bin")
        store.addCut(at: 8)

        var fired = 0
        store.onChange = { _ in fired += 1 }

        store.rename(1, to: "second")

        XCTAssertEqual(fired, 0, "a name is not a drawing")
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

    /// Restoring a snapshot whose pieces match the store's is a no-op — no
    /// invalidation — even when the size differs: the tints depend only on the
    /// piece boundaries, so an undo that moved no cut (a length edit in a file
    /// with no cuts) leaves them where they were, and the content edit's own
    /// repaint already covers the bytes.
    func testRestoringTheSamePiecesInvalidatesNothing() {
        let store = SegmentStore(size: 100, name: "dump.bin")
        let snapshot = store.snapshot()

        // The size changes (an insert's undo) but the single piece's start does
        // not, so the boundaries are untouched.
        store.apply(.insert(at: 5, length: 2), newSize: 102)

        var fired = 0
        store.onChange = { _ in fired += 1 }

        store.restore(snapshot)

        XCTAssertEqual(fired, 0, "same pieces, different size: no repaint")
        XCTAssertEqual(store.contentSize, 100, "the size is restored")
    }

    /// Restoring a snapshot whose pieces differ does fire the invalidation —
    /// the undo of a cut is a repaint, unlike the undo of a length edit.
    func testRestoringDifferentPiecesInvalidates() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        let snapshot = store.snapshot()
        store.removeCut(at: 8)

        var fired = 0
        store.onChange = { _ in fired += 1 }

        store.restore(snapshot)

        XCTAssertEqual(fired, 1, "different pieces: the tints repaint")
        XCTAssertEqual(store.cuts, [8])
    }

    // MARK: - The snapshot is a frozen view (copy-on-write)

    /// A snapshot keeps the boundaries it was taken on, even after the store
    /// moves on: two pieces read from one `Segmentation` rest on the same
    /// partition, so a view held across a mutation (a popover left open, a page
    /// mid-paint) cannot split across two boundaries (§21.3). The store's copy
    /// and the snapshot share `pieces`'s buffer until one is written, so the
    /// snapshot stays on the old buffer while the store moves to a new one.
    func testASnapshotIsAFrozenViewIndependentOfTheStore() {
        let store = SegmentStore(size: 32, name: "dump.bin")
        store.addCut(at: 8)
        let before = store.snapshot()
        XCTAssertEqual(before.segments.map(\.range), [0..<8, 8..<32])

        // The store moves on: a new cut, then a delete that swallows the first.
        store.addCut(at: 16)
        store.apply(.delete(range: 0..<8), newSize: 24)

        // The store's current partition has changed…
        XCTAssertNotEqual(store.segments.map(\.range), [0..<8, 8..<32])
        // …but the snapshot still holds the boundaries it was taken on.
        XCTAssertEqual(before.segments.map(\.range), [0..<8, 8..<32])
        XCTAssertEqual(before.segments[1].name, "")
    }

    /// `current` is a value copy, not a live handle: reading it, then mutating
    /// the store, leaves the read value on the old partition. This is what lets
    /// a paint job grab `current` once and draw the whole page from it.
    func testCurrentIsAValueCopyNotALiveHandle() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        let view = store.current
        XCTAssertEqual(view.pieces.map(\.start), [0])

        store.addCut(at: 8)

        // The view is frozen on the pre-cut partition; the store has moved on.
        XCTAssertEqual(view.pieces.map(\.start), [0])
        XCTAssertEqual(store.current.pieces.map(\.start), [0, 8])
    }

    // MARK: - Moving a cut (§21.2)

    /// A cut may only move within the interval it currently bounds — strictly
    /// between the neighbouring cuts (or the file's end) — so it never jumps
    /// over another cut. The piece it opened keeps its name, which travels with
    /// the boundary.
    func testMoveCutIsConfinedToItsOwnInterval() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 4)
        store.addCut(at: 8)
        // Three pieces: [0,4) [4,8) [8,16). Name the middle piece.
        store.rename(1, to: "middle")

        // The cut at 4 bounds (0, 8): it may move to 6, inside that interval.
        XCTAssertEqual(store.moveCut(from: 4, to: 6), 6)
        XCTAssertEqual(store.cuts, [6, 8])
        // The piece that opened at 4 (now 6) keeps its name.
        XCTAssertEqual(store.segments[1].name, "middle")

        // Landing on the neighbouring cut at 8 is refused…
        XCTAssertNil(store.moveCut(from: 6, to: 8), "a cut cannot land on another cut")
        // …and jumping past it (to 10, in the next interval) is refused too.
        XCTAssertNil(store.moveCut(from: 6, to: 10), "a cut cannot jump over another cut")
        XCTAssertEqual(store.cuts, [6, 8], "a refused move leaves the cut where it was")
    }

    /// A cut at the file's end bounds (the previous cut, EOF): it may move up to
    /// just before EOF, but not onto it or before the file start.
    func testMoveCutTowardTheBoundsStopsShortOfThem() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        // The cut at 8 bounds (0, 16): it may move to 12…
        XCTAssertEqual(store.moveCut(from: 8, to: 12), 12)
        XCTAssertEqual(store.cuts, [12])
        // …but not onto EOF…
        XCTAssertNil(store.moveCut(from: 12, to: 16), "a cut cannot land on EOF")
        // …nor before the file start.
        XCTAssertNil(store.moveCut(from: 12, to: 0), "a cut cannot land on the file start")
        XCTAssertEqual(store.cuts, [12])
    }

    // MARK: - Removing a piece (§21.3)

    /// Removing a piece that is not S0 merges its bytes into the piece above,
    /// which keeps its name; the removed piece is simply dropped.
    func testRemovingAPieceMergesIntoThePieceAbove() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 4)
        store.addCut(at: 8)
        // Three pieces: [0,4) [4,8) [8,16).
        store.rename(0, to: "first")
        store.rename(1, to: "middle")

        // Remove the middle piece (index 1): the piece above absorbs it.
        XCTAssertTrue(store.removePiece(at: 1))
        XCTAssertEqual(store.cuts, [8])
        XCTAssertEqual(store.segments.map(\.range), [0..<8, 8..<16])
        // The absorbing piece keeps its own name, not the removed piece's.
        XCTAssertEqual(store.segments[0].name, "first")
    }

    /// Removing S0 reopens the piece below at the file start: what was S1
    /// becomes S0, keeping its own name.
    func testRemovingS0PromotesThePieceBelow() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        store.addCut(at: 8)
        // Two pieces: [0,8) [8,16).
        store.rename(1, to: "second")

        XCTAssertTrue(store.removePiece(at: 0))
        XCTAssertEqual(store.cuts, [])
        XCTAssertEqual(store.segments.count, 1)
        XCTAssertEqual(store.segments[0].range, 0..<16)
        // The promoted piece (what was S1) keeps its name.
        XCTAssertEqual(store.segments[0].name, "second")
    }

    /// Removing a piece is refused when there is only one piece — there is no
    /// neighbour to merge into — and when the index is out of range.
    func testRemovingTheOnlyPieceOrAnOutOfRangeIndexIsRefused() {
        let store = SegmentStore(size: 16, name: "dump.bin")
        XCTAssertFalse(store.removePiece(at: 0), "a single piece has no neighbour to merge into")
        XCTAssertEqual(store.segments.count, 1)

        store.addCut(at: 8)
        XCTAssertFalse(store.removePiece(at: 5), "no piece at index 5")
        XCTAssertFalse(store.removePiece(at: -1), "no piece at index -1")
        XCTAssertEqual(store.cuts, [8], "a refused removal leaves the partition whole")
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
