import XCTest
@testable import DumpCompareCore

final class OffsetParserTests: XCTestCase {
    private func parse(_ text: String) throws -> UInt64 {
        try OffsetParser.parse(text)
    }

    /// Every form the Go To field accepts, and every way it can be refused.
    /// A bare hex string with no prefix is the interesting one: `10` is decimal
    /// ten, but `1F` and `beef` are hex, in either case.
    func testParse() {
        enum Expected {
            case value(UInt64)
            case error(OffsetParser.ParseError)
        }
        let cases: [(input: String, expected: Expected)] = [
            // Decimal.
            ("0", .value(0)),
            ("10", .value(10)),
            ("4096", .value(4096)),
            ("18446744073709551615", .value(UInt64.max)),
            // Hex with a prefix, either case, prefix and digits alike.
            ("0x10", .value(16)),
            ("0X10", .value(16)),
            ("0xFF", .value(255)),
            ("0xff", .value(255)),
            ("0xffffffffffffffff", .value(UInt64.max)),
            // Hex without a prefix.
            ("FF", .value(255)),
            ("ff", .value(255)),
            ("1F", .value(31)),
            ("beef", .value(0xbeef)),
            // Surrounding whitespace is trimmed.
            ("  0x1F  ", .value(31)),
            ("\t4096\n", .value(4096)),
            // One digit too many, in either base.
            ("0x10000000000000000", .error(.outOfRange)),
            ("99999999999999999999", .error(.outOfRange)),
            // Not a number at all.
            ("", .error(.invalidInput)),
            ("  ", .error(.invalidInput)),
            ("0x", .error(.invalidInput)),
            ("0X", .error(.invalidInput)),
            ("12G", .error(.invalidInput)),
            ("-1", .error(.invalidInput)),
            ("+5", .error(.invalidInput)),
            ("1.5", .error(.invalidInput)),
            ("1_000", .error(.invalidInput)),
            ("0x1G", .error(.invalidInput)),
            ("٤", .error(.invalidInput)),
        ]
        for testCase in cases {
            switch testCase.expected {
            case .value(let expected):
                XCTAssertEqual(try? parse(testCase.input), expected, "\"\(testCase.input)\"")
            case .error(let expected):
                XCTAssertThrowsError(try parse(testCase.input), "\"\(testCase.input)\"") { error in
                    XCTAssertEqual(error as? OffsetParser.ParseError, expected,
                                   "\"\(testCase.input)\"")
                }
            }
        }
    }

    func testHexStringFormatting() {
        XCTAssertEqual(OffsetParser.hexString(0), "0")
        XCTAssertEqual(OffsetParser.hexString(255), "ff")
        XCTAssertEqual(OffsetParser.hexString(0xDEAD), "dead")
    }
}
