import XCTest
@testable import DumpCompareCore

final class ClipboardCodecTests: XCTestCase {
    // MARK: - Raw bytes roundtrip

    func testRawBytesRoundtrip() {
        let samples: [[UInt8]] = [[], [0x00], [0xFF], [0x00, 0x7F, 0x80, 0xFF]]
        for bytes in samples {
            let data = ClipboardCodec.data(from: bytes)
            XCTAssertEqual(ClipboardCodec.bytes(from: data), bytes)
        }
        for data in [Data(), Data([0x00]), Data([0xDE, 0xAD, 0xBE, 0xEF])] {
            let bytes = ClipboardCodec.bytes(from: data)
            XCTAssertEqual(ClipboardCodec.data(from: bytes), data)
        }
    }

    // MARK: - Hex text

    func testHexTextFormatting() {
        XCTAssertEqual(ClipboardCodec.hexText(from: [0xDE, 0xAD, 0xBE, 0xEF]), "DEADBEEF")
        XCTAssertEqual(ClipboardCodec.hexText(from: [0x00, 0x01, 0x0A, 0x0F]), "00010A0F")
        XCTAssertEqual(ClipboardCodec.hexText(from: []), "")
    }

    func testHexTextRoundtrip() throws {
        let samples: [[UInt8]] = [
            [0x00], [0xFF], [0xDE, 0xAD, 0xBE, 0xEF], [0x00, 0x7F, 0x80, 0xFF],
        ]
        for bytes in samples {
            let text = ClipboardCodec.hexText(from: bytes)
            XCTAssertEqual(try ClipboardCodec.bytes(fromHexText: text), bytes)
        }
    }

    func testParseHexText() throws {
        XCTAssertEqual(try ClipboardCodec.bytes(fromHexText: "DE AD BE EF"), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try ClipboardCodec.bytes(fromHexText: "deadbeef"), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try ClipboardCodec.bytes(fromHexText: "0xDE 0xAD"), [0xDE, 0xAD])
        XCTAssertEqual(try ClipboardCodec.bytes(fromHexText: "  00  ff  "), [0x00, 0xFF])
    }

    func testRejectInvalidHexText() {
        let bad = ["", " ", "hello", "DEADBEE", "0x", "12G", "DE AD BE E", "0xDE0xAD", "-1", "1.5"]
        for text in bad {
            XCTAssertThrowsError(try ClipboardCodec.bytes(fromHexText: text), text) { error in
                XCTAssertEqual(error as? ClipboardCodec.CodecError, .invalidHexText, text)
            }
        }
    }
}
