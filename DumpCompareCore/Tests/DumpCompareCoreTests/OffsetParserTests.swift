import XCTest
@testable import DumpCompareCore

final class OffsetParserTests: XCTestCase {
    private func parse(_ text: String) throws -> UInt64 {
        try OffsetParser.parse(text)
    }

    func testDecimal() throws {
        XCTAssertEqual(try parse("0"), 0)
        XCTAssertEqual(try parse("10"), 10)
        XCTAssertEqual(try parse("4096"), 4096)
        XCTAssertEqual(try parse("18446744073709551615"), UInt64.max)
    }

    func testHexWithPrefix() throws {
        XCTAssertEqual(try parse("0x10"), 16)
        XCTAssertEqual(try parse("0X10"), 16)
        XCTAssertEqual(try parse("0xFF"), 255)
        XCTAssertEqual(try parse("0xff"), 255)
        XCTAssertEqual(try parse("0xffffffffffffffff"), UInt64.max)
    }

    func testHexWithoutPrefixIsCaseInsensitive() throws {
        XCTAssertEqual(try parse("FF"), 255)
        XCTAssertEqual(try parse("ff"), 255)
        XCTAssertEqual(try parse("1F"), 31)
        XCTAssertEqual(try parse("beef"), 0xbeef)
    }

    func testTrimsWhitespace() throws {
        XCTAssertEqual(try parse("  0x1F  "), 31)
        XCTAssertEqual(try parse("\t4096\n"), 4096)
    }

    func testOutOfRange() {
        XCTAssertThrowsError(try parse("0x10000000000000000")) { error in
            XCTAssertEqual(error as? OffsetParser.ParseError, .outOfRange)
        }
        XCTAssertThrowsError(try parse("99999999999999999999")) { error in
            XCTAssertEqual(error as? OffsetParser.ParseError, .outOfRange)
        }
    }

    func testInvalidInput() {
        for bad in ["", "  ", "0x", "0X", "12G", "-1", "+5", "1.5", "1_000", "0x1G", "٤"] {
            XCTAssertThrowsError(try parse(bad), bad) { error in
                XCTAssertEqual(error as? OffsetParser.ParseError, .invalidInput, bad)
            }
        }
    }

    func testHexStringFormatting() {
        XCTAssertEqual(OffsetParser.hexString(0), "0")
        XCTAssertEqual(OffsetParser.hexString(255), "ff")
        XCTAssertEqual(OffsetParser.hexString(0xDEAD), "dead")
    }
}
