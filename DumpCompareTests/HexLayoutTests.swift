import CoreGraphics
import XCTest
@testable import DumpCompare

/// Geometry tests for the pure hex-grid layout (no AppKit). Uses
/// charWidth 8, rowHeight 17, default padding.
final class HexLayoutTests: XCTestCase {
    private func makeLayout() -> HexLayout {
        HexLayout(charWidth: 8, rowHeight: 17)
    }

    // MARK: - Derived metrics

    func testDerivedMetrics() {
        let l = makeLayout()
        XCTAssertEqual(l.hexByteWidth, 16)           // 2 chars
        XCTAssertEqual(l.hexByteGap, 8)              // 1 char
        XCTAssertEqual(l.groupWidth, 184)            // 8×16 + 7×8
        XCTAssertEqual(l.betweenGroupsGap, 16)       // 2 chars
        XCTAssertEqual(l.offsetColumnWidth, 64)      // 8 chars
        XCTAssertEqual(l.asciiColumnWidth, 128)      // 16 chars
        XCTAssertEqual(l.gapAfterOffset, 16)
        XCTAssertEqual(l.gapBeforeAscii, 16)
        XCTAssertEqual(l.contentWidth, 632)
    }

    func testOffsetColumnCharsClampedToMinimum() {
        let l = HexLayout(charWidth: 8, rowHeight: 17, offsetColumnChars: 2)
        XCTAssertEqual(l.offsetColumnChars, 8)
    }

    // MARK: - Word size (§6)

    func testWordSizeMetrics() {
        // Word of 2: 4 words per group, 3 word gaps.
        let w2 = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 2)
        XCTAssertEqual(w2.wordSize, 2)
        XCTAssertEqual(w2.wordsPerGroup, 4)
        XCTAssertEqual(w2.wordWidth, 32)
        XCTAssertEqual(w2.groupWidth, 152)   // 8×16 + 3×8
        XCTAssertEqual(w2.contentWidth, 568)

        // Word of 4: 2 words per group, 1 word gap.
        let w4 = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 4)
        XCTAssertEqual(w4.wordsPerGroup, 2)
        XCTAssertEqual(w4.wordWidth, 64)
        XCTAssertEqual(w4.groupWidth, 136)   // 8×16 + 1×8
        XCTAssertEqual(w4.contentWidth, 536)

        // Word of 8: one word fills a whole group — no word gap.
        let w8 = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 8)
        XCTAssertEqual(w8.wordsPerGroup, 1)
        XCTAssertEqual(w8.wordWidth, 128)
        XCTAssertEqual(w8.groupWidth, 128)   // 8×16
        XCTAssertEqual(w8.contentWidth, 520)
    }

    func testWordSizeInvalidFallsBackToOne() {
        XCTAssertEqual(HexLayout(charWidth: 8, rowHeight: 17, wordSize: 3).wordSize, 1)
        XCTAssertEqual(HexLayout(charWidth: 8, rowHeight: 17, wordSize: 16).wordSize, 1)
        XCTAssertEqual(HexLayout(charWidth: 8, rowHeight: 17, wordSize: 0).wordSize, 1)
    }

    func testWordSizeGroupsBytesWithinAWord() {
        let w4 = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 4)
        // Bytes of one word are packed: no gap between them.
        XCTAssertEqual(w4.hexByteX(column: 1), w4.hexByteX(column: 0) + w4.hexByteWidth)
        XCTAssertEqual(w4.hexByteX(column: 3), w4.hexByteX(column: 0) + 3 * w4.hexByteWidth)
        // A word starts after its predecessor plus the word gap.
        XCTAssertEqual(w4.hexByteX(column: 4), w4.hexByteX(column: 3) + w4.hexByteWidth + w4.hexByteGap)
        // Same packing inside the group's second word.
        XCTAssertEqual(w4.hexByteX(column: 7), w4.hexByteX(column: 4) + 3 * w4.hexByteWidth)
        // The two 8-byte groups are still separated by betweenGroupsGap.
        XCTAssertEqual(w4.hexByteX(column: 8), w4.hexByteX(column: 0) + w4.groupWidth + w4.betweenGroupsGap)
    }

    func testWordSizeHitTestTracksPackedWords() {
        let w4 = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 4)
        let byte3 = CGPoint(x: w4.hexByteX(column: 3), y: 0)
        XCTAssertEqual(w4.hitTest(point: byte3, rowCount: 10), HexLayout.Hit(row: 0, column: .hex(3)))
        // Inside the gap between words → the following word's first byte.
        let gap = CGPoint(x: w4.hexByteX(column: 3) + w4.hexByteWidth + w4.hexByteGap / 2, y: 0)
        XCTAssertEqual(w4.hitTest(point: gap, rowCount: 10), HexLayout.Hit(row: 0, column: .hex(4)))

        let w8 = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 8)
        let last = CGPoint(x: w8.hexByteX(column: 15), y: 0)
        XCTAssertEqual(w8.hitTest(point: last, rowCount: 10), HexLayout.Hit(row: 0, column: .hex(15)))
    }

    func testWordSizeKeepsRowsAndOffsets() {
        // Word grouping is display-only: rows and offsets are unchanged.
        let w4 = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 4)
        XCTAssertEqual(w4.rowCount(fileSize: 16), 2)
        XCTAssertEqual(w4.byteOffset(row: 1, column: 0), 16)
        XCTAssertEqual(w4.rowColumn(of: 19).row, 1)
        XCTAssertEqual(w4.rowColumn(of: 19).column, 3)
    }

    // MARK: - Rows

    func testRowCount() {
        let l = makeLayout()
        XCTAssertEqual(l.rowCount(fileSize: 0), 1)    // empty → 1 placeholder row
        XCTAssertEqual(l.rowCount(fileSize: 1), 1)
        XCTAssertEqual(l.rowCount(fileSize: 15), 1)
        XCTAssertEqual(l.rowCount(fileSize: 16), 2)   // extra row so caret at EOF is reachable
        XCTAssertEqual(l.rowCount(fileSize: 17), 2)
        XCTAssertEqual(l.rowCount(fileSize: 32), 3)
    }

    func testByteOffsetAndRowColumnRoundTrip() {
        let l = makeLayout()
        XCTAssertEqual(l.byteOffset(row: 1, column: 3), 19)
        let (row, column) = l.rowColumn(of: 19)
        XCTAssertEqual(row, 1)
        XCTAssertEqual(column, 3)
        XCTAssertEqual(l.byteOffset(row: 5, column: 15), 95)
        XCTAssertEqual(l.byteOffset(row: 0, column: 0), 0)
    }

    func testTotalHeight() {
        let l = makeLayout()
        XCTAssertEqual(l.totalHeight(fileSize: 0), 17)
        XCTAssertEqual(l.totalHeight(fileSize: 16), 34)
    }

    // MARK: - Column geometry

    func testHexByteX() {
        let l = makeLayout()
        XCTAssertEqual(l.hexByteX(column: 0), 92)     // leftPadding + offset + gap
        XCTAssertEqual(l.hexByteX(column: 7), 260)
        XCTAssertEqual(l.hexByteX(column: 8), 292)    // second group after betweenGroupsGap
        XCTAssertEqual(l.hexByteX(column: 15), 460)   // 92 + 1×200 + 7×24
        // Adjacent cells are contiguous: cell 7 ends where cell 8 begins within its own group.
        XCTAssertEqual(l.hexByteX(column: 0) + l.hexByteWidth + l.hexByteGap, l.hexByteX(column: 1))
    }

    func testAsciiX() {
        let l = makeLayout()
        XCTAssertEqual(l.asciiX(column: 0), 492)
        XCTAssertEqual(l.asciiX(column: 15), 612)
        // Last ASCII char ends exactly at contentWidth - rightPadding.
        XCTAssertEqual(l.asciiX(column: 15) + l.charWidth, l.contentWidth - l.rightPadding)
    }

    func testCaretX() {
        let l = makeLayout()
        let frame = l.hexByteFrame(row: 0, column: 2)
        XCTAssertEqual(l.caretX(row: 0, column: 2, nibble: 0), frame.minX)
        XCTAssertEqual(l.caretX(row: 0, column: 2, nibble: 1), frame.minX + l.charWidth)
    }

    // MARK: - Virtualization

    func testVisibleRowRange() {
        let l = makeLayout()
        // Whole first row.
        XCTAssertEqual(l.visibleRowRange(in: CGRect(x: 0, y: 0, width: 600, height: 17)), 0..<1)
        // Row spanning two partial rows.
        XCTAssertEqual(l.visibleRowRange(in: CGRect(x: 0, y: 16, width: 600, height: 34)), 0..<3)
        // Aligned to a row boundary.
        XCTAssertEqual(l.visibleRowRange(in: CGRect(x: 0, y: 17, width: 600, height: 17)), 1..<2)
        // Zero height → nothing.
        XCTAssertEqual(l.visibleRowRange(in: .zero), 0..<0)
    }

    func testRowFrame() {
        let l = makeLayout()
        XCTAssertEqual(l.rowFrame(row: 2), CGRect(x: 0, y: 34, width: 632, height: 17))
    }

    // MARK: - Hit testing

    func testHitTestHexCells() {
        let l = makeLayout()
        XCTAssertEqual(l.hitTest(point: CGPoint(x: 92, y: 0), rowCount: 10), HexLayout.Hit(row: 0, column: .hex(0)))
        XCTAssertEqual(l.hitTest(point: CGPoint(x: 300, y: 17), rowCount: 10), HexLayout.Hit(row: 1, column: .hex(8)))
        XCTAssertEqual(l.hitTest(point: CGPoint(x: 468, y: 0), rowCount: 10), HexLayout.Hit(row: 0, column: .hex(15)))
    }

    func testHitTestAsciiAndOffset() {
        let l = makeLayout()
        // ASCII column at char 5 → byte 5.
        XCTAssertEqual(l.hitTest(point: CGPoint(x: 492 + 5 * 8, y: 0), rowCount: 10), HexLayout.Hit(row: 0, column: .ascii(5)))
        // Offset column.
        XCTAssertEqual(l.hitTest(point: CGPoint(x: 20, y: 0), rowCount: 10), HexLayout.Hit(row: 0, column: .offset))
    }

    func testHitTestMisses() {
        let l = makeLayout()
        // Beyond the row's content (right padding).
        XCTAssertNil(l.hitTest(point: CGPoint(x: 700, y: 0), rowCount: 10))
        // Beyond the last row.
        XCTAssertNil(l.hitTest(point: CGPoint(x: 200, y: 170), rowCount: 1))
        // Negative coordinates.
        XCTAssertNil(l.hitTest(point: CGPoint(x: -1, y: 0), rowCount: 10))
    }

    /// A click in a gap never falls dead: between words it lands on the
    /// following word, between the two 8-byte groups on the next group's first
    /// byte, and past the last hex byte on the row's last byte (§6).
    func testHitTestGapMapsToNextWord() {
        let l = makeLayout()
        // Gap between byte 0 and byte 1 → byte 1.
        let wordGap = CGPoint(x: l.hexByteX(column: 0) + l.hexByteWidth + l.hexByteGap / 2, y: 0)
        XCTAssertEqual(l.hitTest(point: wordGap, rowCount: 10), HexLayout.Hit(row: 0, column: .hex(1)))
        // Between-groups gap → first byte of the second group.
        let betweenGap = CGPoint(x: l.hexByteX(column: 7) + l.hexByteWidth + l.betweenGroupsGap / 2, y: 0)
        XCTAssertEqual(l.hitTest(point: betweenGap, rowCount: 10), HexLayout.Hit(row: 0, column: .hex(8)))
        // Gap before the ASCII column → last byte.
        let trailingGap = CGPoint(x: l.hexByteX(column: 15) + l.hexByteWidth + l.hexByteGap / 2, y: 0)
        XCTAssertEqual(l.hitTest(point: trailingGap, rowCount: 10), HexLayout.Hit(row: 0, column: .hex(15)))
    }
}
