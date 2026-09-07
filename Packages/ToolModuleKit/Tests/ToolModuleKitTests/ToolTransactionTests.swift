import XCTest
@testable import ToolModuleKit

/// What a transaction has to be before anything is written
/// (`ToolTransaction.validated()`).
final class ToolTransactionTests: XCTestCase {
    private func transaction(_ writes: [ToolTransaction.Write]) -> ToolTransaction {
        ToolTransaction(name: "Add Microcode", writes: writes)
    }

    private func write(_ offset: UInt64, _ count: Int, _ byte: UInt8 = 0xAA)
    -> ToolTransaction.Write {
        ToolTransaction.Write(offset: offset, bytes: [UInt8](repeating: byte, count: count))
    }

    func testWritesComeBackInOffsetOrder() throws {
        let checked = try transaction([write(0x200, 4), write(0x10, 4), write(0x100, 4)])
            .validated()

        XCTAssertEqual(checked.writes.map(\.offset), [0x10, 0x100, 0x200])
    }

    /// Writes that touch end to end are one write, so the host patches one
    /// range instead of three.
    func testWritesThatTouchBecomeOne() throws {
        let checked = try transaction([write(0x10, 4, 0x01), write(0x14, 4, 0x02)])
            .validated()

        XCTAssertEqual(checked.writes.count, 1)
        XCTAssertEqual(checked.writes.first?.offset, 0x10)
        XCTAssertEqual(checked.writes.first?.bytes,
                       [0x01, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02])
    }

    /// A FIT entry is four writes that are nowhere near each other (§9.2): the
    /// component, the entry, the header's count, its checksum. They stay four.
    func testWritesWithGapsBetweenThemStaySeparate() throws {
        let checked = try transaction([write(0xB8FC60, 0x30), write(0xE00140, 16),
                                       write(0xE00108, 3), write(0xE0010F, 1)])
            .validated()

        XCTAssertEqual(checked.writes.map(\.offset), [0xB8FC60, 0xE00108, 0xE0010F, 0xE00140])
    }

    /// Two writes over one byte means an offset was computed wrong — the exact
    /// mistake §11 of the FIT document is about — and no ordering rule should
    /// decide it quietly.
    func testTwoWritesOverTheSameByteAreRefused() {
        XCTAssertThrowsError(try transaction([write(0x10, 8), write(0x14, 8)]).validated()) {
            XCTAssertEqual($0 as? ToolTransactionError, .overlappingWrites(at: 0x14))
        }
    }

    func testAWriteOfNoBytesIsRefused() {
        let empty = ToolTransaction.Write(offset: 0x40, bytes: [])

        XCTAssertThrowsError(try transaction([empty]).validated()) {
            XCTAssertEqual($0 as? ToolTransactionError, .emptyWrite(at: 0x40))
        }
    }

    func testATransactionWithNoWritesIsRefused() {
        XCTAssertThrowsError(try transaction([]).validated()) {
            XCTAssertEqual($0 as? ToolTransactionError, .noWrites)
        }
    }

    /// The name becomes `Undo <name>`, so a blank one is not a name.
    func testATransactionWithoutANameIsRefused() {
        let unnamed = ToolTransaction(name: "  \n", writes: [write(0x10, 4)])

        XCTAssertThrowsError(try unnamed.validated()) {
            XCTAssertEqual($0 as? ToolTransactionError, .unnamed)
        }
    }

    /// What the dump has to redraw: the first byte written to the last, gaps
    /// included.
    func testTheSpanReachesFromTheFirstByteWrittenToTheLast() {
        let spread = transaction([write(0xE00140, 16), write(0xB8FC60, 0x30)])

        XCTAssertEqual(spread.span, 0xB8FC60..<0xE00150)
        XCTAssertNil(transaction([]).span)
    }
}
