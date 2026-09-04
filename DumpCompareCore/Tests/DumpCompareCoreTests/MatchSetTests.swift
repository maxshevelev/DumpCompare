import XCTest
@testable import DumpCompareCore

/// `Design/FIND_HIGHLIGHT_PLAN.md`: one scan per activated pattern is the single
/// source for the dump's greys, the find indicator, Find Next, the count, the
/// results panel and both minimap modes. This is that set: where the matches
/// are, held sparsely or as a bitmap depending on their density, and exact in
/// either — the count never truncates, because a count in the thousands is the
/// diagnosis that the pattern is too generic.
final class MatchSetTests: XCTestCase {
    private let pattern = SearchPattern(bytes: [0xDE, 0xAD, 0xBE, 0xEF], encoding: .hex)

    private func set(extent: UInt64, starts: [UInt64],
                     maxIndexBytes: Int = MatchSet.maxIndexBytes) -> MatchSet {
        var builder = MatchSetBuilder(pattern: pattern, folding: .exact, extent: extent,
                                      maxIndexBytes: maxIndexBytes)
        builder.add(starts)
        return builder.finish()
    }

    /// A set holding its starts sparsely, whatever the density — for comparing
    /// the two representations answer for answer.
    private func sparse(extent: UInt64, starts: [UInt64]) -> MatchSet {
        MatchSet(pattern: pattern, folding: .exact, extent: extent,
                 total: starts.count, storage: .sparse(starts))
    }

    private func bitmap(extent: UInt64, starts: [UInt64]) -> MatchSet {
        var map = MatchBitmap(bitCount: extent)
        for start in starts { map.set(start) }
        map.sealRanks()
        return MatchSet(pattern: pattern, folding: .exact, extent: extent,
                        total: starts.count, storage: .bitmap(map))
    }

    // MARK: - What the dump asks for

    /// The greys are drawn per row range, so the question is always "which
    /// matches overlap these bytes" — including a match that starts before them
    /// and reaches in, which is the case a row boundary creates on every screen.
    func testMatchesOverlappingARangeIncludeOneStraddlingItsStart() {
        let matches = set(extent: 0x1000, starts: [0x00, 0x0E, 0x40]).matches(intersecting: 0x10..<0x20)
        XCTAssertEqual(matches, [0x0E..<0x12],
                       "a match starting two bytes before the range reaches into it")
    }

    func testMatchesOverlappingARangeStopAtItsEnd() {
        let all = set(extent: 0x1000, starts: [0x00, 0x10, 0x20, 0x30])
        XCTAssertEqual(all.matches(intersecting: 0x10..<0x30), [0x10..<0x14, 0x20..<0x24],
                       "a match starting at the range's end belongs to the next range")
        XCTAssertEqual(all.matches(intersecting: 0x00..<0x1000).count, 4)
        XCTAssertEqual(all.matches(intersecting: 0x100..<0x200), [],
                       "a range with no matches asks for nothing")
    }

    /// A single-byte pattern has no reach, so the widening must not pull in the
    /// match that ends just before the range.
    func testASingleBytePatternDoesNotReachBackwards() {
        let single = SearchPattern(bytes: [0xFF], encoding: .hex)
        var builder = MatchSetBuilder(pattern: single, folding: .exact, extent: 0x100)
        builder.add([0x0F, 0x10])
        XCTAssertEqual(builder.finish().matches(intersecting: 0x10..<0x20), [0x10..<0x11])
    }

    // MARK: - What navigation asks for

    func testTheOrdinalsAroundACaret() {
        let all = set(extent: 0x1000, starts: [0x10, 0x20, 0x30])
        XCTAssertEqual(all.index(startingAt: 0x20), 1, "standing on a match names it")
        XCTAssertNil(all.index(startingAt: 0x21), "between matches nothing is named")
        XCTAssertEqual(all.index(atOrAfter: 0x20), 1, "Find Next from a match start finds it")
        XCTAssertEqual(all.index(atOrAfter: 0x21), 2, "Find Next moves on from inside one")
        XCTAssertNil(all.index(atOrAfter: 0x31), "past the last match there is nothing after")
        XCTAssertEqual(all.index(before: 0x30), 1, "Find Previous steps back")
        XCTAssertEqual(all.index(before: 0x31), 2, "from inside a match, back means that one")
        XCTAssertNil(all.index(before: 0x10), "before the first match there is nothing")
        XCTAssertEqual(all.range(at: 2), 0x30..<0x34)
        XCTAssertNil(all.range(at: 3))
    }

    // MARK: - The two representations must answer identically

    /// The bitmap exists to make an uncapped highlight affordable, not to change
    /// any answer: every query is checked against the sparse form over a dense,
    /// irregular set — including runs of adjacent matches, which is what a
    /// short pattern in padding produces.
    func testBitmapAndSparseAgreeOnEveryQuery() {
        let extent: UInt64 = 4096
        var starts: [UInt64] = []
        var offset: UInt64 = 3
        var step: UInt64 = 1
        while offset < extent - 8 {
            starts.append(offset)
            offset += step
            step = step % 7 + 1
        }
        let a = sparse(extent: extent, starts: starts)
        let b = bitmap(extent: extent, starts: starts)
        XCTAssertEqual(a.total, b.total)

        for offset in stride(from: UInt64(0), to: extent, by: 13) {
            XCTAssertEqual(a.index(startingAt: offset), b.index(startingAt: offset),
                           "ordinal at 0x\(String(offset, radix: 16))")
            XCTAssertEqual(a.index(atOrAfter: offset), b.index(atOrAfter: offset),
                           "next at 0x\(String(offset, radix: 16))")
            XCTAssertEqual(a.index(before: offset), b.index(before: offset),
                           "previous at 0x\(String(offset, radix: 16))")
            XCTAssertEqual(a.matches(intersecting: offset..<offset + 16),
                           b.matches(intersecting: offset..<offset + 16),
                           "row at 0x\(String(offset, radix: 16))")
        }
        for index in [0, 1, 2, starts.count / 2, starts.count - 2, starts.count - 1] {
            XCTAssertEqual(a.start(at: index), b.start(at: index), "start of match \(index)")
        }
        XCTAssertNil(b.start(at: starts.count))
    }

    /// The rank table narrows `select` to a block; a set whose matches all sit
    /// in the last block is the case that exposes an off-by-one there.
    func testSelectFindsMatchesFarIntoTheBitmap() {
        let extent: UInt64 = 40_000
        let starts: [UInt64] = [39_000, 39_500, 39_900]
        let dense = bitmap(extent: extent, starts: starts)
        XCTAssertEqual((0..<3).map { dense.start(at: $0) }, starts.map { Optional($0) })
        XCTAssertEqual(dense.index(startingAt: 39_500), 1)
        XCTAssertEqual(dense.index(before: 40_000), 2)
    }

    // MARK: - Choosing the representation

    /// The switch is at the count where a sparse list costs what the bitmap
    /// costs — `extent / 64` matches — and it is invisible from outside except
    /// as the storage case.
    func testDensityPicksTheRepresentation() {
        let sparseSet = set(extent: 6400, starts: [0x10, 0x20, 0x30])
        guard case .sparse = sparseSet.storage else {
            return XCTFail("a handful of matches stays a list, got \(sparseSet.storage)")
        }

        let denseSet = set(extent: 6400, starts: (0..<200).map { UInt64($0) * 8 })
        guard case .bitmap = denseSet.storage else {
            return XCTFail("200 matches over 6400 bytes is past extent/64, got \(denseSet.storage)")
        }
        XCTAssertEqual(denseSet.total, 200)
        XCTAssertTrue(denseSet.isHighlightable)
    }

    /// Batched delivery must not change the outcome: the scan hands over a
    /// chunk's matches at once, and the conversion can fall in the middle of a
    /// batch.
    func testBatchedDeliveryMatchesOneBigBatch() {
        let starts = (0..<300).map { UInt64($0) * 4 }
        var batched = MatchSetBuilder(pattern: pattern, folding: .exact, extent: 6400)
        for chunk in stride(from: 0, to: starts.count, by: 37) {
            batched.add(Array(starts[chunk..<min(chunk + 37, starts.count)]))
        }
        let whole = set(extent: 6400, starts: starts)
        let piecewise = batched.finish()
        XCTAssertEqual(piecewise.total, whole.total)
        XCTAssertEqual(piecewise.matches(intersecting: 0..<6400), whole.matches(intersecting: 0..<6400))
    }

    /// Past the index ceiling the positions go and the count does not: the app
    /// turns the greys off and says why, and the number it says is exact.
    func testPastTheCeilingTheCountSurvivesAlone() {
        let counted = set(extent: 1 << 20, starts: (0..<20_000).map { UInt64($0) * 8 },
                          maxIndexBytes: 1024)
        guard case .counted = counted.storage else {
            return XCTFail("a bitmap over the ceiling must not be built, got \(counted.storage)")
        }
        XCTAssertEqual(counted.total, 20_000, "the count is never truncated")
        XCTAssertFalse(counted.isHighlightable, "a partial highlight would be a lie")
        XCTAssertEqual(counted.matches(intersecting: 0..<0x1000), [])
        XCTAssertNil(counted.index(atOrAfter: 0))
        XCTAssertNil(counted.start(at: 0))
    }

    /// The listing limit is about a generic pattern, not about memory, so it is
    /// the count that decides — never the representation.
    func testListabilityFollowsTheCountAlone() {
        let limit = SearchEngine.defaultMaxResults
        XCTAssertFalse(set(extent: 0x1000, starts: []).isListable, "nothing to list")
        XCTAssertTrue(sparse(extent: 1 << 24, starts: [0x10]).isListable)
        XCTAssertTrue(bitmap(extent: 1 << 20, starts: (0..<limit).map { UInt64($0) * 8 }).isListable,
                      "exactly the limit is a complete list")
        XCTAssertFalse(bitmap(extent: 1 << 20, starts: (0..<(limit + 1)).map { UInt64($0) * 8 }).isListable,
                       "one past the limit is a count, not a list")
    }

    // MARK: - Following an overwrite

    /// An overwrite moves no byte, so only the matches touching the edited range
    /// can change. Splicing that segment is the whole update — in both
    /// representations.
    func testSplicingAnOverwrittenRange() {
        for var subject in [sparse(extent: 0x1000, starts: [0x10, 0x40, 0x80]),
                            bitmap(extent: 0x1000, starts: [0x10, 0x40, 0x80])] {
            let storage = subject.storage
            XCTAssertTrue(subject.splice([0x44], replacing: 0x3D..<0x50),
                          "\(storage) can be updated in place")
            XCTAssertEqual(subject.total, 3)
            XCTAssertEqual(subject.matches(intersecting: 0..<0x1000),
                           [0x10..<0x14, 0x44..<0x48, 0x80..<0x84],
                           "the match moved inside the rescanned window")
            XCTAssertEqual(subject.index(startingAt: 0x44), 1, "the ordinals follow")
            XCTAssertEqual(subject.index(startingAt: 0x80), 2)
        }
    }

    func testSplicingCanRemoveAndAddMatches() {
        var subject = sparse(extent: 0x1000, starts: [0x10, 0x40, 0x80])
        subject.splice([], replacing: 0x3D..<0x50)
        XCTAssertEqual(subject.total, 2)
        XCTAssertEqual(subject.matches(intersecting: 0..<0x1000), [0x10..<0x14, 0x80..<0x84])

        var grown = bitmap(extent: 0x1000, starts: [0x10])
        grown.splice([0x20, 0x24], replacing: 0x1D..<0x30)
        XCTAssertEqual(grown.total, 3)
        XCTAssertEqual(grown.index(before: 0x1000), 2)
    }

    /// A counted set cannot be patched, and says so rather than pretending: the
    /// caller rescans.
    func testACountedSetRefusesToBeSpliced() {
        var counted = MatchSet(pattern: pattern, folding: .exact, extent: 1 << 20,
                               total: 9_000, storage: .counted)
        XCTAssertFalse(counted.splice([0x10], replacing: 0..<0x100))
        XCTAssertEqual(counted.total, 9_000, "a refused splice changes nothing")
    }
    /// The two ways of naming a match must agree: the index the navigation asks
    /// for at an offset, and the offset the map asks for at that index. A dense
    /// bitmap is where a rank/select mismatch shows, and it showed as a mark
    /// one row above where its match was.
    func testTheIndexAtAnOffsetPointsAtTheMatchThere() {
        let pattern = SearchPattern(bytes: [0xFF], encoding: .hex)
        let dense = MatchSet(pattern: pattern, folding: .exact, extent: 4096,
                             starts: (0..<4096).map { $0 })
        for offset in [UInt64(0), 1, 63, 64, 65, 1000, 4095] {
            let index = dense.index(atOrAfter: offset)
            XCTAssertEqual(index.flatMap { dense.start(at: $0) }, offset,
                           "at \(offset) the index must name the match at \(offset)")
        }

        // And with gaps, where "at or after" has to skip.
        let sparse = MatchSet(pattern: pattern, folding: .exact, extent: 4096,
                              starts: [0, 100, 4000])
        XCTAssertEqual(sparse.index(atOrAfter: 1).flatMap { sparse.start(at: $0) }, 100)
        XCTAssertEqual(sparse.index(atOrAfter: 100).flatMap { sparse.start(at: $0) }, 100)
        XCTAssertEqual(sparse.index(atOrAfter: 101).flatMap { sparse.start(at: $0) }, 4000)
        XCTAssertNil(sparse.index(atOrAfter: 4001))
    }

}
