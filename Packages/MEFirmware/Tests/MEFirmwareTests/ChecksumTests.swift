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

    // MARK: EFS / FITC real-byte vectors

    /// `crc32IV0Raw` over the EFS System Page Header span (Unknown0 …
    /// DictRevision, bytes [0x00:0x0C]) of the real CSME 15.0.30 EFS region
    /// (1.bin @0x267000) equals the stored 0xF4D864F7 — python `reg0` ground
    /// truth, which is upstream's `~Crc32.calc(span, initvalue=0) & mask`.
    func testCRC32IV0RawEFSSystemHeaderVector() {
        let span = Data([0x01, 0x00, 0x0A, 0x00, 0x01, 0x00,
                         0x00, 0x00, 0x02, 0x0A, 0x04, 0x01])
        XCTAssertEqual(CRC32.crc32IV0Raw(span), 0xF4D8_64F7)
    }

    /// Standard `crc32` over the FITC header CRC span — bytes [0x00:0x04] +
    /// zeroed HeaderChecksum + [0x08:0x0C] of the real CSME 15.0.30 FITC region
    /// (1.bin @0x1F2000) equals its stored HeaderChecksum 0x6856049C (python
    /// `zlib.crc32` ground truth for the rev-1 header).
    func testCRC32FITCHeaderSpanVector() {
        let span = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                         0x00, 0x00, 0x7B, 0x2B, 0x00, 0x00])
        XCTAssertEqual(CRC32.crc32(span), 0x6856_049C)
    }
}
