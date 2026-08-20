import XCTest
@testable import DumpCompareCore

/// The piece table's arithmetic: which source segments cover a window after a
/// sequence of edits, and how many pieces that takes. Bytes and files are
/// `EditOverlayStorage`'s business; here the sources are named, not read.
final class PieceTableTests: XCTestCase {

    /// A readable rendering of a window: `b` for base bytes, `a` for added
    /// bytes, each followed by its source offsets — so a test can state the
    /// whole expected layout in one line.
    private func layout(_ table: PieceTable, _ range: Range<UInt64>? = nil) -> String {
        let window = range ?? 0..<table.size
        return table.segments(in: window).map { segment in
            let tag = segment.source == .base ? "b" : "a"
            return "\(tag)\(segment.range.lowerBound)-\(segment.range.upperBound)"
        }.joined(separator: " ")
    }

    func testAFreshTableIsOnePieceOfBase() {
        let table = PieceTable(baseSize: 100)
        XCTAssertEqual(table.size, 100)
        XCTAssertEqual(table.pieceCount, 1)
        XCTAssertEqual(layout(table), "b0-100")
        XCTAssertTrue(table.addedRanges.isEmpty)
    }

    func testAnEmptyBaseHasNoPieces() {
        let table = PieceTable(baseSize: 0)
        XCTAssertEqual(table.size, 0)
        XCTAssertEqual(table.pieceCount, 0)
        XCTAssertEqual(layout(table), "")
        XCTAssertEqual(table.segments(in: 0..<10), [])
    }

    // MARK: - Insert

    func testInsertInTheMiddleSplitsOnePieceIntoThree() {
        var table = PieceTable(baseSize: 100)
        table.insert(at: 40, addedRange: 0..<2)

        XCTAssertEqual(table.size, 102)
        XCTAssertEqual(table.pieceCount, 3)
        XCTAssertEqual(layout(table), "b0-40 a0-2 b40-100")
        XCTAssertEqual(table.addedRanges, [40..<42])
    }

    func testInsertAtTheStartAndAtTheEnd() {
        var table = PieceTable(baseSize: 10)
        table.insert(at: 0, addedRange: 0..<1)
        XCTAssertEqual(layout(table), "a0-1 b0-10")

        table.insert(at: table.size, addedRange: 1..<2)
        XCTAssertEqual(layout(table), "a0-1 b0-10 a1-2")
        XCTAssertEqual(table.size, 12)
        XCTAssertEqual(table.addedRanges, [0..<1, 11..<12])
    }

    /// An offset past the end inserts at the end rather than leaving a hole.
    func testInsertBeyondTheEndLandsAtTheEnd() {
        var table = PieceTable(baseSize: 10)
        table.insert(at: 999, addedRange: 0..<3)
        XCTAssertEqual(layout(table), "b0-10 a0-3")
        XCTAssertEqual(table.size, 13)
    }

    /// A typed run must not cost one piece per keystroke: successive inserts of
    /// consecutive added bytes at the growing offset extend one piece.
    func testATypedRunStaysOnePiece() {
        var table = PieceTable(baseSize: 1_000_000)
        for i in 0..<500 {
            table.insert(at: 100 + UInt64(i), addedRange: UInt64(i)..<UInt64(i + 1))
        }
        XCTAssertEqual(table.size, 1_000_500)
        XCTAssertEqual(table.pieceCount, 3, "base head, the whole typed run, base tail")
        XCTAssertEqual(layout(table), "b0-100 a0-500 b100-1000000")
        XCTAssertEqual(table.addedRanges, [100..<600])
    }

    /// Typing somewhere else does not extend the previous run's piece.
    func testARunBrokenByAJumpStartsANewPiece() {
        var table = PieceTable(baseSize: 100)
        table.insert(at: 10, addedRange: 0..<1)
        table.insert(at: 11, addedRange: 1..<2)   // continues the run
        XCTAssertEqual(table.pieceCount, 3)

        table.insert(at: 50, addedRange: 2..<3)   // elsewhere
        XCTAssertEqual(table.pieceCount, 5)
        XCTAssertEqual(layout(table), "b0-10 a0-2 b10-48 a2-3 b48-100")
    }

    // MARK: - Delete

    func testDeleteInsideOnePiece() {
        var table = PieceTable(baseSize: 100)
        table.delete(20..<30)

        XCTAssertEqual(table.size, 90)
        XCTAssertEqual(layout(table), "b0-20 b30-100")
    }

    func testDeleteSpanningSeveralPieces() {
        var table = PieceTable(baseSize: 100)
        table.insert(at: 50, addedRange: 0..<10)      // b0-50 a0-10 b50-100
        table.delete(45..<65)                         // through the added piece

        XCTAssertEqual(table.size, 90)
        XCTAssertEqual(layout(table), "b0-45 b55-100")
        XCTAssertTrue(table.addedRanges.isEmpty, "the added piece was consumed whole")
    }

    func testDeleteTrimsPartialPiecesAtBothEnds() {
        var table = PieceTable(baseSize: 100)
        table.insert(at: 50, addedRange: 0..<10)      // b0-50 a0-10 b50-100
        table.delete(55..<58)                         // inside the added piece

        XCTAssertEqual(layout(table), "b0-50 a0-5 a8-10 b50-100")
        XCTAssertEqual(table.addedRanges, [50..<57], "adjacent added ranges merge")
    }

    func testDeleteEverything() {
        var table = PieceTable(baseSize: 100)
        table.delete(0..<100)
        XCTAssertEqual(table.size, 0)
        XCTAssertEqual(table.pieceCount, 0)
    }

    func testDeleteClampsToTheEndAndIgnoresEmptyRanges() {
        var table = PieceTable(baseSize: 10)
        table.delete(8..<999)
        XCTAssertEqual(layout(table), "b0-8")
        table.delete(4..<4)
        XCTAssertEqual(layout(table), "b0-8")
        table.delete(20..<30)
        XCTAssertEqual(layout(table), "b0-8")
    }

    // MARK: - Replace (overwrite)

    func testReplaceKeepsTheSizeWhenLengthsMatch() {
        var table = PieceTable(baseSize: 100)
        table.replace(10..<12, with: 0..<2)

        XCTAssertEqual(table.size, 100)
        XCTAssertEqual(layout(table), "b0-10 a0-2 b12-100")
        XCTAssertEqual(table.addedRanges, [10..<12])
    }

    func testReplacePastTheEndGrowsTheTable() {
        var table = PieceTable(baseSize: 10)
        table.replace(8..<12, with: 0..<4)

        XCTAssertEqual(table.size, 12)
        XCTAssertEqual(layout(table), "b0-8 a0-4")
    }

    /// Overwriting the same byte twice leaves one added piece, not a stack of
    /// them: the second replace deletes the first's piece.
    func testRepeatedOverwriteOfTheSameByteDoesNotPileUpPieces() {
        var table = PieceTable(baseSize: 100)
        table.replace(10..<11, with: 0..<1)
        table.replace(10..<11, with: 1..<2)
        table.replace(10..<11, with: 2..<3)

        XCTAssertEqual(table.size, 100)
        XCTAssertEqual(table.pieceCount, 3)
        XCTAssertEqual(layout(table), "b0-10 a2-3 b11-100",
                       "the base byte at 10 stays replaced, the tail resumes at 11")
    }

    // MARK: - Windows

    func testSegmentsCoverOnlyTheRequestedWindow() {
        var table = PieceTable(baseSize: 100)
        table.insert(at: 50, addedRange: 0..<10)   // b0-50 a0-10 b50-100

        XCTAssertEqual(layout(table, 48..<53), "b48-50 a0-3")
        XCTAssertEqual(layout(table, 55..<62), "a5-10 b50-52")
        XCTAssertEqual(layout(table, 0..<1), "b0-1")
        XCTAssertEqual(layout(table, 109..<120), "b99-100", "clamped to the end")
        XCTAssertEqual(table.segments(in: 110..<120), [], "entirely past the end")
        XCTAssertEqual(table.segments(in: 10..<10), [])
    }

    /// A mixed edit sequence keeps the logical content consistent: reading the
    /// whole table byte by byte must agree with reading it in one window.
    func testByteWiseAndWholeWindowReadsAgree() {
        var table = PieceTable(baseSize: 40)
        table.insert(at: 10, addedRange: 0..<5)
        table.delete(2..<8)
        table.replace(20..<25, with: 5..<10)
        table.insert(at: table.size, addedRange: 10..<12)
        table.delete(0..<1)

        let whole = table.segments(in: 0..<table.size)
        var byteWise: [PieceTable.Segment] = []
        for offset in 0..<table.size {
            byteWise.append(contentsOf: table.segments(in: offset..<(offset + 1)))
        }
        // Both readings name the same source bytes in the same order.
        func flatten(_ segments: [PieceTable.Segment]) -> [(PieceTable.Source, UInt64)] {
            segments.flatMap { segment in segment.range.map { (segment.source, $0) } }
        }
        let a = flatten(whole)
        let b = flatten(byteWise)
        XCTAssertEqual(a.count, Int(table.size))
        XCTAssertEqual(a.map(\.1), b.map(\.1))
        XCTAssertEqual(a.map { $0.0 == .base }, b.map { $0.0 == .base })
    }
}
