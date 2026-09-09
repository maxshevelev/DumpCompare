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

    /// The one spelling of a checksum that carries a validity bit: the value in
    /// hex, and whether the structure says it counts, in words. Shared, so the
    /// panels read it the same.
    func testTheChecksumWithValidityReadsAsOneLine() {
        XCTAssertEqual(Checksums.text(0x5C, valid: true), "0x5C (Valid)")
        XCTAssertEqual(Checksums.text(0x5C, valid: false), "0x5C (Invalid)")
        // A narrow value is padded to the field's width, not left ragged.
        XCTAssertEqual(Checksums.text(0, valid: false), "0x00 (Invalid)")
        XCTAssertEqual(Checksums.text(0x1, valid: true, digits: 4), "0x0001 (Valid)")
    }

    /// An invalid checksum whose correct value is known says what it should be
    /// — the point of showing the value at all is that a reader can write it
    /// back, so leaving it a mystery would say half of the story.
    func testAnInvalidChecksumSaysWhatItShouldBe() {
        XCTAssertEqual(
            Checksums.text(0x5C, valid: false, expected: 0x5A),
            "0x5C (Invalid), should be 0x5A"
        )
        // The should-be value is padded to the field's width the same way.
        XCTAssertEqual(
            Checksums.text(0x0C, valid: false, expected: 0x05, digits: 4),
            "0x000C (Invalid), should be 0x0005"
        )
        // A valid checksum is already what it should be, so the words never add
        // the should-be — there is nothing to correct, even when told.
        XCTAssertEqual(
            Checksums.text(0x5A, valid: true, expected: 0x5A),
            "0x5A (Valid)"
        )
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
