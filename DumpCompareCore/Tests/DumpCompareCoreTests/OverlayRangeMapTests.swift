import XCTest
@testable import DumpCompareCore

final class OverlayRangeMapTests: XCTestCase {
    func testEmptyWriteIsNoop() {
        var map = OverlayRangeMap()
        map.write([], at: 0)
        XCTAssertTrue(map.isEmpty)
    }

    func testSeparateWritesStaySeparate() {
        var map = OverlayRangeMap()
        map.write([1, 2, 3], at: 0)
        map.write([4, 5], at: 5)
        XCTAssertEqual(map.changedRanges, [0..<3, 5..<7])
        XCTAssertEqual(map.totalByteCount, 5)
    }

    func testAdjacentWritesMerge() {
        var map = OverlayRangeMap()
        map.write([1, 2, 3, 4], at: 0)
        map.write([5, 6], at: 4)
        XCTAssertEqual(map.changedRanges, [0..<6])
        XCTAssertEqual(map.entries.first?.bytes, [1, 2, 3, 4, 5, 6])
    }

    func testOverlappingWriteSplices() {
        var map = OverlayRangeMap()
        map.write([0xAA, 0xAA, 0xAA, 0xAA], at: 0)
        map.write([0xBB, 0xCC], at: 1)
        XCTAssertEqual(map.entries.first?.bytes, [0xAA, 0xBB, 0xCC, 0xAA])
        XCTAssertEqual(map.changedRanges, [0..<4])
    }

    func testGapIsPreservedAroundOverlappingWrite() {
        var map = OverlayRangeMap()
        map.write([1, 2, 3, 4], at: 0)
        map.write([7, 8], at: 10)
        // Writing one byte at 8 must create [8, 9) without connecting the two
        // entries with garbage; the untouched bytes [4, 8) and [9, 10) stay gaps.
        map.write([9], at: 8)
        XCTAssertEqual(map.changedRanges, [0..<4, 8..<9, 10..<12])
    }

    func testWriteSpanningTwoEntries() {
        var map = OverlayRangeMap()
        map.write([1, 2, 3, 4], at: 0)
        map.write([5, 6], at: 10)
        // Span [2, 12) replaces both entries plus the gap, but the overlay
        // bytes [0, 2) = [1, 2] survive and merge into one contiguous entry.
        let spanning: [UInt8] = Array(repeating: 0xFF, count: 10)
        map.write(spanning, at: 2)
        XCTAssertEqual(map.changedRanges, [0..<12])
        XCTAssertEqual(map.entries.first?.bytes, [1, 2] + spanning)
    }

    func testIntersecting() {
        var map = OverlayRangeMap()
        map.write([1, 2, 3, 4], at: 0)
        map.write([5, 6], at: 6)
        let entries = map.entriesIntersecting(2..<7)
        XCTAssertEqual(entries.count, 2)
        // (1, 5) touches only the first entry; (4, 6) would be the exact gap.
        XCTAssertEqual(map.entriesIntersecting(1..<5).count, 1)
        XCTAssertEqual(map.entriesIntersecting(100..<110).count, 0)
    }

    func testPartialOverlapSplitsEntry() {
        var map = OverlayRangeMap()
        map.write([1, 2, 3, 4, 5, 6], at: 0)
        map.write([9, 9], at: 2)
        // Overwritten [2, 4); the untouched pieces [0, 2) and [4, 6) survive.
        XCTAssertEqual(map.entries.first?.bytes, [1, 2, 9, 9, 5, 6])
        XCTAssertEqual(map.changedRanges, [0..<6])
    }
}
