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
        // In the gap between group cells.
        XCTAssertNil(l.hitTest(point: CGPoint(x: 108, y: 0), rowCount: 10))
        // Beyond the last row.
        XCTAssertNil(l.hitTest(point: CGPoint(x: 200, y: 170), rowCount: 1))
        // Negative coordinates.
        XCTAssertNil(l.hitTest(point: CGPoint(x: -1, y: 0), rowCount: 10))
    }
}
