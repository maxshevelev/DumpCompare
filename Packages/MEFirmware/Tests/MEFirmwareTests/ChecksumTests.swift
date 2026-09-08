import XCTest
import Foundation
@testable import MEFirmware

final class ChecksumTests: XCTestCase {
    /// Standard check-value: CRC-32("123456789") == 0xCBF43926 (matches
    /// zlib / crccheck Crc32, so a synthetic R2 $CPD fixture validates too).
    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testCRC32EmptyIsZero() {
        XCTAssertEqual(CRC32.crc32(Data()), 0)
    }

    func testCRC32DiffersOnBitFlip() {
        XCTAssertNotEqual(CRC32.crc32(Data([0x00, 0x01, 0x02])),
                          CRC32.crc32(Data([0x00, 0x01, 0x03])))
    }
}
