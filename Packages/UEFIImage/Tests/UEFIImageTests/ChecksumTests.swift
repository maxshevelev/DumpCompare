import XCTest
@testable import UEFIImage

/// Checksums, all of which are built so that the structure including its own
/// checksum field sums to zero (§0).
final class ChecksumTests: XCTestCase {
    private let bytes: [UInt8] = [0x10, 0x20, 0x30, 0x41]

    func testTheEightBitChecksumMakesTheSumZero() {
        let checksum = Checksums.checksum8(bytes)

        XCTAssertEqual(Checksums.sum8(bytes + [checksum]), 0)
    }

    func testTheSixteenBitChecksumMakesTheSumZero() {
        let checksum = Checksums.checksum16(bytes)

        XCTAssertEqual(checksum, 0x9EC0)
        XCTAssertEqual(Checksums.sum16(bytes + [0xC0, 0x9E]), 0)
    }

    /// An FV header length that is odd cannot be summed in 16-bit words, and
    /// the length is the thing worth reporting — not a checksum rounded to fit.
    func testAnOddLengthHasNoSixteenBitSum() {
        XCTAssertNil(Checksums.sum16([0x01, 0x02, 0x03]))
        XCTAssertNil(Checksums.checksum16([0x01]))
    }

    /// The body of an FFS file can be megabytes, so the sum reads in chunks —
    /// and has to come out the same as summing it all at once.
    func testTheChunkedByteSumMatchesTheDirectOne() {
        let long = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let reader = ImageReader(long)

        XCTAssertEqual(Checksums.sum8(of: reader.all, in: reader), Checksums.sum8(long))
    }

    func testTheChunkedSumsRefuseARangeOutsideTheImage() {
        let reader = ImageReader([UInt8]([1, 2, 3, 4]))

        XCTAssertNil(Checksums.sum8(of: 0..<5, in: reader))
        XCTAssertNil(Checksums.sum32(of: 0..<8, in: reader))
    }

    /// Intel microcode checks out when every dword of it sums to zero (§7.1).
    func testTheDwordSumIsLittleEndianAndCancels() {
        let reader = ImageReader([UInt8]([0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]))

        XCTAssertEqual(Checksums.sum32(of: 0..<4, in: reader), 1)
        XCTAssertEqual(Checksums.sum32(of: 0..<8, in: reader), 0)
    }

    func testTheDwordSumNeedsWholeWords() {
        let reader = ImageReader([UInt8]([1, 2, 3, 4, 5, 6]))

        XCTAssertNil(Checksums.sum32(of: 0..<6, in: reader))
    }

    func testAligningUp() {
        XCTAssertEqual(alignUp(0x11, to: 8), 0x18)
        XCTAssertEqual(alignUp(0x18, to: 8), 0x18)
        XCTAssertEqual(alignUp(0, to: 8), 0)
        XCTAssertNil(alignUp(1, to: 0))
    }

    /// The value being aligned is usually `offset + size`, both read out of a
    /// corrupt image — so the alignment itself can be what overflows.
    func testAligningPastTheEndOfTheNumberIsNil() {
        XCTAssertNil(alignUp(.max - 2, to: 8))
    }
}
