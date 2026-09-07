import XCTest
@testable import DumpCompareCore

final class SelectionModelTests: XCTestCase {
    /// A selection can never point outside its file, whichever initialiser built
    /// it: direction is normalised and both edges are clamped to `fileSize`.
    func testConstruction() {
        let cases: [(name: String, selection: SelectionModel,
                     start: UInt64, end: UInt64, count: UInt64, fileSize: UInt64)] = [
            ("an end past EOF is clamped to the size",
             SelectionModel(start: 2, end: 100, fileSize: 8), 2, 8, 6, 8),
            ("a length inside the file",
             SelectionModel(start: 2, length: 3, fileSize: 100), 2, 5, 3, 100),
            ("a length overshooting EOF is clamped",
             SelectionModel(start: 6, length: 100, fileSize: 8), 6, 8, 2, 8),
            ("a start past EOF collapses to a caret at EOF",
             SelectionModel(start: 50, length: 1, fileSize: 8), 8, 8, 0, 8),
            ("a backward drag is normalised",
             SelectionModel(start: 5, end: 2, fileSize: 100), 2, 5, 3, 100),
            ("an empty selection is a caret",
             SelectionModel.empty(at: 3, fileSize: 100), 3, 3, 0, 100),
            ("re-clamping to a smaller file pulls the end in",
             SelectionModel(start: 0, end: 10, fileSize: 100).clamped(to: 5), 0, 5, 5, 5),
            // length = UInt64.max must not overflow when added to start.
            ("a length of UInt64.max does not overflow",
             SelectionModel(start: 3, length: UInt64.max, fileSize: 100), 3, 100, 97, 100),
        ]
        for testCase in cases {
            let selection = testCase.selection
            XCTAssertEqual(selection.start, testCase.start, "\(testCase.name): start")
            XCTAssertEqual(selection.end, testCase.end, "\(testCase.name): end")
            XCTAssertEqual(selection.count, testCase.count, "\(testCase.name): count")
            XCTAssertEqual(selection.fileSize, testCase.fileSize, "\(testCase.name): fileSize")
            XCTAssertEqual(selection.isEmpty, testCase.count == 0, "\(testCase.name): isEmpty")
            XCTAssertNotNil(selection.blockRange,
                            "\(testCase.name): a clamped selection always yields a block range")
        }
    }
}

final class BlockRangeTests: XCTestCase {
    /// `BlockRange` validates instead of clamping — except a length, which is
    /// clamped to EOF the way the Select Block dialog needs.
    func testConstruction() {
        let cases: [(name: String, range: BlockRange?, expected: (start: UInt64, count: UInt64)?)] = [
            ("a valid start and end", BlockRange(start: 1, end: 4, fileSize: 10), (1, 3)),
            ("a length inside the file", BlockRange(start: 2, length: 5, fileSize: 100), (2, 5)),
            ("a length overshooting EOF is clamped",
             BlockRange(start: 8, length: 50, fileSize: 10), (8, 2)),
            ("an empty range is valid", BlockRange(start: 3, end: 3, fileSize: 10), (3, 0)),
            ("an end before the start is rejected", BlockRange(start: 4, end: 2, fileSize: 10), nil),
            ("an end past EOF is rejected", BlockRange(start: 2, end: 11, fileSize: 10), nil),
            ("a start past EOF is rejected", BlockRange(start: 11, end: 12, fileSize: 10), nil),
            ("a start past EOF is rejected with a length too",
             BlockRange(start: 11, length: 1, fileSize: 10), nil),
        ]
        for testCase in cases {
            guard let expected = testCase.expected else {
                XCTAssertNil(testCase.range, testCase.name)
                continue
            }
            guard let range = testCase.range else {
                XCTFail("\(testCase.name): expected a range, got nil")
                continue
            }
            XCTAssertEqual(range.start, expected.start, "\(testCase.name): start")
            XCTAssertEqual(range.end, expected.start + expected.count, "\(testCase.name): end")
            XCTAssertEqual(range.count, expected.count, "\(testCase.name): count")
            XCTAssertEqual(range.isEmpty, expected.count == 0, "\(testCase.name): isEmpty")
        }
    }
}
