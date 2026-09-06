import XCTest
@testable import UEFIFormat

/// The one place this parser bounds-checks (`ImageReader`), which is why it is
/// worth pinning down here rather than in each of the fifty callers.
final class ImageReaderTests: XCTestCase {
    private let reader = ImageReader([UInt8](
        [0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x89, 0xFF, 0xFF]
    ))

    func testNumbersAreReadLittleEndian() {
        XCTAssertEqual(reader.uint8(at: 0), 0x78)
        XCTAssertEqual(reader.uint16(at: 0), 0x5678)
        XCTAssertEqual(reader.uint24(at: 0), 0x345678)
        XCTAssertEqual(reader.uint32(at: 0), 0x12345678)
        XCTAssertEqual(reader.uint64(at: 0), 0x89AB_CDEF_1234_5678)
    }

    func testAReadThatRunsOffTheEndIsNil() {
        XCTAssertNil(reader.uint32(at: 8))
        XCTAssertNil(reader.uint64(at: 3))
        XCTAssertNil(reader.uint8(at: 10))
        XCTAssertNil(reader.bytes(at: 9, count: 2))
        XCTAssertNil(reader.guid(at: 0))
    }

    /// The addition that overflows is not hypothetical: both terms come out of
    /// a corrupt image (§11), and unchecked it wraps into a range that passes
    /// every later test.
    func testARangeThatOverflowsIsNil() {
        XCTAssertNil(reader.range(at: .max - 2, count: 10))
        XCTAssertNil(reader.range(at: 4, count: .max))
        XCTAssertNil(reader.bytes(at: .max, count: 1))
    }

    func testARangeInsideTheImageIsGiven() {
        XCTAssertEqual(reader.range(at: 2, count: 4), 2..<6)
        XCTAssertEqual(reader.range(at: 10, count: 0), 10..<10)
        XCTAssertEqual(reader.bytes(2..<4), [0x34, 0x12])
        XCTAssertEqual(reader.bytes(4..<4), [])
    }

    func testFilledIsFalseForOneByteOutOfPlace() {
        XCTAssertTrue(reader.isFilled(8..<10, with: 0xFF))
        XCTAssertFalse(reader.isFilled(7..<10, with: 0xFF))
    }

    /// Out of bounds is "no", not "vacuously yes" — free space is decided with
    /// this, and a range past the end must never read as empty space.
    func testFilledIsFalseOutsideTheImage() {
        XCTAssertFalse(reader.isFilled(8..<12, with: 0xFF))
    }

    func testChunksCoverTheRangeInOrder() {
        var seen: [UInt8] = []
        reader.forEachChunk(of: 1..<7, size: 4) { seen += $0; return true }

        XCTAssertEqual(seen, [0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB])
    }

    /// Free space is routinely megabytes and the answer is usually decided by
    /// the first chunk, so stopping early has to actually stop.
    func testChunksStopWhenAskedTo() {
        var chunks = 0
        reader.forEachChunk(of: 0..<10, size: 2) { _ in chunks += 1; return false }

        XCTAssertEqual(chunks, 1)
    }

    func testChunksOutsideTheImageAreNone() {
        var chunks = 0
        reader.forEachChunk(of: 8..<12, size: 2) { _ in chunks += 1; return true }

        XCTAssertEqual(chunks, 0)
    }

    func testDataAndBytesReadTheSame() {
        let fromData = ImageReader(Data([0x01, 0x02, 0x03, 0x04]))
        let fromArray = ImageReader([UInt8]([0x01, 0x02, 0x03, 0x04]))

        XCTAssertEqual(fromData.count, 4)
        XCTAssertEqual(fromData.uint32(at: 0), fromArray.uint32(at: 0))
    }
}
