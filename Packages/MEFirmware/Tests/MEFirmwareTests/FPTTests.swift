import XCTest
import Foundation
@testable import MEFirmware

/// Builds a synthetic region with a $FPT header at a chosen offset.
enum FPTFixture {
    static func setUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data[data.startIndex + offset + shift / 8] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// A minimal FPT v2.0 header (exactly 0x20, per `FPT_Header` `MEA.py:193`) +
    /// `entries` at `anchor`. HeaderVersion 0x20 with a zero second CRC word
    /// resolves to v2.0 (upstream get_fpt).
    static func fptRegion(anchor: Int = 0, entries: [(name: String, offset: UInt32, size: UInt32, flags: UInt32)]) -> Data {
        var data = Data(repeating: 0, count: anchor + 0x20)
        data.replaceSubrange(anchor..<(anchor + 4), with: Data("$FPT".utf8))
        setUInt32(UInt32(entries.count), in: &data, at: anchor + 0x04)   // NumPartitions
        data[anchor + 0x08] = 0x20                                       // HeaderVersion
        data[anchor + 0x09] = 0x10                                       // EntryVersion
        data[anchor + 0x0A] = 0x20                                       // HeaderLength

        for entry in entries {
            let start = data.count
            data.append(Data(repeating: 0, count: 0x20))                     // fixed 0x20 row
            // Name (0x00): copy up to 4 ASCII bytes — byte-by-byte, never a
            // length-changing replaceSubrange (a short name must not shift the
            // row and move the offsets we patch next).
            for (index, byte) in entry.name.utf8.prefix(4).enumerated() {
                data[start + index] = byte
            }
            setUInt32(entry.offset, in: &data, at: start + 0x08)             // Offset
            setUInt32(entry.size, in: &data, at: start + 0x0C)               // Size
            setUInt32(entry.flags, in: &data, at: start + 0x1C)              // Flags
        }
        return data
    }
}

final class FPTParserTests: XCTestCase {
    func testDecodesV20HeaderAndEntries() throws {
        let region = FPTFixture.fptRegion(entries: [
            ("FTUE", 0x1000, 0x800, 0x01),   // Type code (bit0) = data/code
            ("rbe",  0x2000, 0x200, 0x00),
        ])

        let result = try XCTUnwrap(FPTParser.parseFirst(in: region))
        XCTAssertEqual(result.headerVersion, 0x20)
        XCTAssertEqual(result.resolvedVersion, 0x20)
        XCTAssertEqual(result.partitions.count, 2)
        XCTAssertEqual(result.partitions[0].name, "FTUE")
        XCTAssertEqual(result.partitions[0].offset, 0x1000)
        XCTAssertEqual(result.partitions[0].size, 0x800)
        XCTAssertEqual(result.partitions[0].flags, 0x01)
        XCTAssertEqual(result.partitions[1].name, "rbe")
        XCTAssertEqual(result.partitions[1].offset, 0x2000)
    }

    func testFindsFPTWhenNotAtRegionStart() throws {
        let region = FPTFixture.fptRegion(anchor: 0x40, entries: [("FTPR", 0x0, 0x1000, 0)])
        let anchor = try XCTUnwrap(FPTParser.findAnchor(in: region))
        XCTAssertEqual(anchor, 0x40)
        let result = try XCTUnwrap(FPTParser.decode(region, anchor: anchor))
        XCTAssertEqual(result.partitions[0].name, "FTPR")
        XCTAssertEqual(result.partitions[0].offset, 0x40)   // region-relative (anchor-based)
    }

    func testEmptyRegionHasNoFPT() {
        XCTAssertNil(FPTParser.parseFirst(in: Data(repeating: 0xFF, count: 64)))
    }
}
