import XCTest
@testable import DumpCompareCore

final class SelectionModelTests: XCTestCase {
    func testEndBasedClampedToSize() {
        let s = SelectionModel(start: 2, end: 100, fileSize: 8)
        XCTAssertEqual(s.start, 2)
        XCTAssertEqual(s.end, 8)
        XCTAssertEqual(s.count, 6)
        XCTAssertFalse(s.isEmpty)
    }

    func testLengthBased() {
        let s = SelectionModel(start: 2, length: 3, fileSize: 100)
        XCTAssertEqual(s.start, 2)
        XCTAssertEqual(s.end, 5)
        XCTAssertEqual(s.count, 3)
    }

    func testLengthOvershootClamped() {
        let s = SelectionModel(start: 6, length: 100, fileSize: 8)
        XCTAssertEqual(s.end, 8)
        XCTAssertEqual(s.count, 2)
    }

    func testStartPastEOFClampedToCaret() {
        let s = SelectionModel(start: 50, length: 1, fileSize: 8)
        XCTAssertEqual(s.start, 8)
        XCTAssertEqual(s.end, 8)
        XCTAssertTrue(s.isEmpty)
    }

    func testDirectionNormalized() {
        let s = SelectionModel(start: 5, end: 2, fileSize: 100)
        XCTAssertEqual(s.start, 2)
        XCTAssertEqual(s.end, 5)
    }

    func testEmptySelection() {
        let s = SelectionModel.empty(at: 3, fileSize: 100)
        XCTAssertEqual(s.start, 3)
        XCTAssertEqual(s.end, 3)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.count, 0)
        XCTAssertNotNil(s.blockRange)
    }

    func testClampedToSmallerFileKeepsSelectionInBounds() {
        let s = SelectionModel(start: 0, end: 10, fileSize: 100)
        let shrunk = s.clamped(to: 5)
        XCTAssertEqual(shrunk.fileSize, 5)
        XCTAssertEqual(shrunk.end, 5)
    }

    func testBlockRangeOverflowSafeLength() {
        // length = UInt64.max must not overflow when added to start.
        let s = SelectionModel(start: 3, length: UInt64.max, fileSize: 100)
        XCTAssertEqual(s.end, 100)
        XCTAssertEqual(s.count, 97)
    }
}

final class BlockRangeTests: XCTestCase {
    func testValidStartEnd() {
        XCTAssertEqual(BlockRange(start: 1, end: 4, fileSize: 10)?.count, 3)
        XCTAssertTrue(BlockRange(start: 1, end: 4, fileSize: 10)?.isEmpty == false)
    }

    func testLengthBased() {
        let r = BlockRange(start: 2, length: 5, fileSize: 100)
        XCTAssertEqual(r?.start, 2)
        XCTAssertEqual(r?.end, 7)
    }

    func testLengthOvershootClampsToEOF() {
        XCTAssertEqual(BlockRange(start: 8, length: 50, fileSize: 10)?.end, 10)
        XCTAssertEqual(BlockRange(start: 8, length: 50, fileSize: 10)?.count, 2)
    }

    func testEmptyRangeIsValid() {
        let r = BlockRange(start: 3, end: 3, fileSize: 10)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.count, 0)
        XCTAssertTrue(r?.isEmpty == true)
    }

    func testInvalidRangesRejected() {
        XCTAssertNil(BlockRange(start: 4, end: 2, fileSize: 10))       // end < start
        XCTAssertNil(BlockRange(start: 2, end: 11, fileSize: 10))       // end > size
        XCTAssertNil(BlockRange(start: 11, end: 12, fileSize: 10))      // start > size
        XCTAssertNil(BlockRange(start: 11, length: 1, fileSize: 10))    // start > size
    }
}
