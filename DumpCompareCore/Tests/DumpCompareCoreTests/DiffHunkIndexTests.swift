import XCTest
@testable import DumpCompareCore

/// §10.3.1: Next/Previous Difference steps by grouped hunks, not by byte-exact
/// blocks. A hunk merges difference blocks separated by a matching run shorter
/// than the grouping distance, is bounded by differing bytes, and is derived
/// from the index without changing it (highlighting stays per byte, §8.2).
final class DiffHunkIndexTests: XCTestCase {
    /// Builds an index from two byte arrays, the way the comparison does.
    private func index(_ left: [UInt8], _ right: [UInt8]) -> DiffBlockIndex {
        DiffBlockIndex(leftSize: UInt64(left.count), rightSize: UInt64(right.count),
                       blocks: DiffEngine.blocks(left: left, right: right))
    }

    /// Two files of `count` matching bytes with single-byte differences at the
    /// given offsets — the "holey diff" shape a rewritten config region has.
    private func pair(count: Int, differingAt offsets: [Int]) -> ([UInt8], [UInt8]) {
        let left = [UInt8](repeating: 0xAA, count: count)
        var right = left
        for offset in offsets { right[offset] = 0x55 }
        return (left, right)
    }

    // MARK: - Grouping

    /// Differences within the grouping distance are one change, and the hunk it
    /// forms runs from its first differing byte to its last — never rounded out
    /// to a row, never including the matching run that follows.
    func testDifferencesCloserThanTheGapBecomeOneHunk() {
        let (left, right) = pair(count: 512, differingAt: [0x10, 0x13, 0x40])
        XCTAssertEqual(DiffHunkIndex(index: index(left, right), gap: 256).hunks, [0x10..<0x41],
                       "three differences inside the distance are one change")

        let (boundedLeft, boundedRight) = pair(count: 512, differingAt: [0x23, 0x2F])
        XCTAssertEqual(DiffHunkIndex(index: index(boundedLeft, boundedRight), gap: 256).hunks,
                       [0x23..<0x30],
                       "the hunk is bounded by its own differing bytes")
    }

    func testDifferencesFartherApartThanTheGapStaySeparateHunks() {
        let (left, right) = pair(count: 2048, differingAt: [0x100, 0x400])
        let hunks = DiffHunkIndex(index: index(left, right), gap: 256)
        XCTAssertEqual(hunks.hunks, [0x100..<0x101, 0x400..<0x401])
    }

    /// The boundary is exact: a matching run of `gap - 1` bytes is swallowed, a
    /// run of `gap` bytes separates.
    func testTheGapBoundaryIsTheMatchingRunLength() {
        let (leftMerged, rightMerged) = pair(count: 256, differingAt: [0, 16])
        XCTAssertEqual(DiffHunkIndex(index: index(leftMerged, rightMerged), gap: 16).hunks,
                       [0..<17], "a 15-byte matching run is shorter than the gap → merged")

        let (leftSplit, rightSplit) = pair(count: 256, differingAt: [0, 17])
        XCTAssertEqual(DiffHunkIndex(index: index(leftSplit, rightSplit), gap: 16).hunks,
                       [0..<1, 17..<18], "a 16-byte matching run is not shorter than the gap")
    }

    /// The reason grouping is by distance and not by the 16-byte row: row
    /// grouping would merge or split the same spacing depending on where it
    /// falls inside a row. Both pairs here are 17 bytes apart — one crosses a
    /// row boundary with a clean row between the rows of the two bytes, the
    /// other does not — and both must group the same way.
    func testGroupingDoesNotDependOnRowAlignment() {
        for start in 0..<16 {
            let (left, right) = pair(count: 512, differingAt: [start, start + 17])
            XCTAssertEqual(DiffHunkIndex(index: index(left, right), gap: 32).hunks.count, 1,
                           "17 bytes apart is inside a 32-byte gap regardless of phase (start \(start))")
            XCTAssertEqual(DiffHunkIndex(index: index(left, right), gap: 16).hunks.count, 2,
                           "17 bytes apart exceeds a 16-byte gap regardless of phase (start \(start))")
        }
    }

    /// A region where differing bytes alternate with matching ones — the case
    /// that made the command useless — collapses to a single target.
    func testAByteAlternatingRegionCollapsesToOneHunk() {
        let left = [UInt8](repeating: 0xAA, count: 4096)
        var right = left
        for offset in stride(from: 0, to: 4096, by: 2) { right[offset] = 0x55 }
        let blocks = index(left, right)
        XCTAssertGreaterThan(blocks.blocks.count, 1000, "the byte-exact index holds a block per byte")
        XCTAssertEqual(DiffHunkIndex(index: blocks, gap: 16).hunks, [0..<4095])
    }

    /// A gap of 1 (or 0) merges nothing: blocks are separated by at least one
    /// matching byte, so navigation falls back to the byte-exact blocks.
    func testAGapOfOneReproducesTheByteExactBlocks() {
        let (left, right) = pair(count: 512, differingAt: [0x10, 0x12, 0x14])
        let blocks = index(left, right)
        let hunks = DiffHunkIndex(index: blocks, gap: 1)
        XCTAssertEqual(hunks.hunks, blocks.differenceBlocks.map(\.range))
    }

    /// EOF-only bytes of the longer file are part of a difference block (§8.1),
    /// so they group like any other difference.
    func testTheEOFOnlyTailGroupsWithANearbyDifference() {
        let left = [UInt8](repeating: 0xAA, count: 300)
        var right = [UInt8](repeating: 0xAA, count: 256)
        right[250] = 0x55
        let hunks = DiffHunkIndex(index: index(left, right), gap: 256)
        XCTAssertEqual(hunks.extent, 300)
        XCTAssertEqual(hunks.hunks, [250..<300],
                       "the differing byte and the EOF-only tail are one change")
    }

    // MARK: - Navigation

    /// Forward navigation from inside a hunk — including from inside a matching
    /// run the hunk swallowed — lands on the next hunk, not on a fragment of the
    /// one the caret is in.
    func testNextDifferenceFromInsideAHunkFindsTheNextHunk() {
        let (left, right) = pair(count: 2048, differingAt: [0x10, 0x40, 0x400])
        let hunks = DiffHunkIndex(index: index(left, right), gap: 256)
        XCTAssertEqual(hunks.hunks, [0x10..<0x41, 0x400..<0x401])

        XCTAssertEqual(hunks.nextDifference(from: 0), 0x10..<0x41)
        XCTAssertEqual(hunks.nextDifference(from: 0x10), 0x400..<0x401,
                       "from the hunk's first byte the next target is the following hunk")
        XCTAssertEqual(hunks.nextDifference(from: 0x20), 0x400..<0x401,
                       "a caret inside a swallowed matching run is inside the hunk")
        XCTAssertNil(hunks.nextDifference(from: 0x400))
    }

    /// Backward navigation lands on the hunk before the one the caret sits in;
    /// its last byte (what the UI moves the caret to) is a differing byte.
    func testPreviousDifferenceSkipsTheHunkTheCaretIsIn() {
        let (left, right) = pair(count: 2048, differingAt: [0x10, 0x40, 0x400])
        let hunks = DiffHunkIndex(index: index(left, right), gap: 256)

        XCTAssertEqual(hunks.previousDifference(from: 2048), 0x400..<0x401)
        XCTAssertEqual(hunks.previousDifference(from: 0x400), 0x10..<0x41,
                       "from the last hunk's start the previous target is the earlier hunk")
        XCTAssertEqual(hunks.previousDifference(from: 0x41), 0x10..<0x41)
        XCTAssertNil(hunks.previousDifference(from: 0x10))
    }

    /// Same-block navigation is the complement of the hunks: the short matching
    /// runs a hunk swallowed are not targets, or Next Same Block would land in
    /// the middle of what Next Difference treats as one change.
    func testSameNavigationSkipsTheRunsAHunkSwallowed() {
        let (left, right) = pair(count: 2048, differingAt: [0x10, 0x40, 0x400])
        let hunks = DiffHunkIndex(index: index(left, right), gap: 256)

        XCTAssertEqual(hunks.nextSame(from: 0), 0x41..<0x400,
                       "the run between the two hunks, not the one inside the first")
        XCTAssertEqual(hunks.nextSame(from: 0x20), 0x41..<0x400)
        XCTAssertEqual(hunks.nextSame(from: 0x41), 0x401..<2048)
        XCTAssertNil(hunks.nextSame(from: 0x401), "nothing starts after the trailing run")

        XCTAssertEqual(hunks.previousSame(from: 2048), 0x401..<2048)
        XCTAssertEqual(hunks.previousSame(from: 0x400), 0x41..<0x400)
        XCTAssertEqual(hunks.previousSame(from: 0x30), 0..<0x10,
                       "the leading run is what ends before a caret inside the first hunk")
        XCTAssertNil(hunks.previousSame(from: 0))
    }

    /// A leading or trailing matching run can be shorter than the gap — nothing
    /// was merged across it, it is simply what is left at the file's edge, and
    /// it stays a target the way the block index reports it.
    func testTheFileEdgeRunsAreTargetsEvenWhenShorterThanTheGap() {
        let (left, right) = pair(count: 32, differingAt: [4, 27])
        let hunks = DiffHunkIndex(index: index(left, right), gap: 256)
        XCTAssertEqual(hunks.hunks, [4..<28])
        XCTAssertEqual(hunks.nextSame(from: 0), 28..<32)
        XCTAssertEqual(hunks.previousSame(from: 32), 28..<32)
        XCTAssertEqual(hunks.previousSame(from: 10), 0..<4)
    }

    /// Identical files: no difference targets, and the whole extent is the one
    /// matching run — reachable backward from EOF, never forward from 0 (a run
    /// starting at 0 is not strictly after offset 0), matching `DiffBlockIndex`.
    func testIdenticalFilesHaveNoHunks() {
        let left = [UInt8](repeating: 0xAA, count: 128)
        let hunks = DiffHunkIndex(index: index(left, left), gap: 256)
        XCTAssertTrue(hunks.isEmpty)
        XCTAssertNil(hunks.nextDifference(from: 0))
        XCTAssertNil(hunks.previousDifference(from: 128))
        XCTAssertNil(hunks.nextSame(from: 0))
        XCTAssertEqual(hunks.previousSame(from: 128), 0..<128)
    }

    func testEmptyFilesHaveNoTargets() {
        let hunks = DiffHunkIndex(index: index([], []), gap: 256)
        XCTAssertTrue(hunks.isEmpty)
        XCTAssertEqual(hunks.extent, 0)
        XCTAssertNil(hunks.nextDifference(from: 0))
        XCTAssertNil(hunks.previousSame(from: 0))
    }

    /// A difference that starts at offset 0 and one that runs to EOF: no leading
    /// or trailing matching run exists, and navigation must report that rather
    /// than an empty range.
    func testHunksTouchingBothFileEdgesLeaveNoMatchingRuns() {
        var left = [UInt8](repeating: 0xAA, count: 64)
        var right = left
        for offset in 0..<64 { right[offset] = 0x55 }
        left[0] = 0xAA
        right[0] = 0x55
        let hunks = DiffHunkIndex(index: index(left, right), gap: 16)
        XCTAssertEqual(hunks.hunks, [0..<64])
        XCTAssertNil(hunks.nextSame(from: 0))
        XCTAssertNil(hunks.previousSame(from: 64))
        XCTAssertNil(hunks.nextDifference(from: 0))
        XCTAssertEqual(hunks.previousDifference(from: 64), 0..<64)
    }
}
