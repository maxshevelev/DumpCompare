import XCTest
@testable import UEFIImage

/// The read window a `Parser` puts between itself and its source, and the
/// `word(at:count:)` seam it exists to serve.
///
/// The parser reads thousands of small fields, mostly forward, and the NVRAM
/// store walk asks twelve recognisers at every byte no store claimed — so
/// against the app's live storage a quarter-megabyte run of padding was
/// millions of locked round trips for bytes already in hand. What is tested
/// here is that the window answers exactly what the source would.
final class WindowedByteSourceTests: XCTestCase {
    /// A source that counts what it was asked, so "the window read once" is a
    /// fact rather than a hope.
    private final class CountingSource: ByteSource, @unchecked Sendable {
        private let bytes: [UInt8]
        private(set) var reads = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var byteCount: UInt64 { UInt64(bytes.count) }
        func bytes(in range: Range<UInt64>) -> [UInt8] {
            reads += 1
            return Array(bytes[Int(range.lowerBound)..<Int(range.upperBound)])
        }
    }

    private let image: [UInt8] = (0..<(4 * 1024)).map { UInt8($0 & 0xFF) }

    func testAWordIsTheBytesLittleEndian() {
        let reader = ImageReader(image)

        XCTAssertEqual(reader.uint8(at: 1), 1)
        XCTAssertEqual(reader.uint16(at: 1), 0x0201)
        XCTAssertEqual(reader.uint24(at: 1), 0x03_0201)
        XCTAssertEqual(reader.uint32(at: 1), 0x0403_0201)
        XCTAssertEqual(reader.uint64(at: 1), 0x0807_0605_0403_0201)
    }

    func testAFieldPastTheEndIsNil() {
        let reader = ImageReader(image)
        XCTAssertNil(reader.uint32(at: UInt64(image.count) - 3))
        XCTAssertNil(reader.uint8(at: UInt64(image.count)))
        XCTAssertNil(reader.uint64(at: .max))
    }

    func testTheWindowAnswersWhatTheSourceWould() {
        let source = CountingSource(image)
        let windowed = WindowedByteSource(source, window: 256)

        for offset in stride(from: UInt64(0), to: UInt64(image.count) - 8, by: 7) {
            XCTAssertEqual(windowed.bytes(in: offset..<(offset + 5)),
                           Array(image[Int(offset)..<(Int(offset) + 5)]),
                           "at \(offset)")
            XCTAssertEqual(windowed.word(at: offset, count: 4),
                           ImageReader(image).source.word(at: offset, count: 4),
                           "at \(offset)")
        }
    }

    /// The point of it: a run of small forward reads costs one read per
    /// window, not one per field.
    func testSmallForwardReadsCostOneReadPerWindow() {
        let source = CountingSource(image)
        let windowed = WindowedByteSource(source, window: 256)

        for offset in 0..<UInt64(200) { _ = windowed.word(at: offset, count: 4) }

        XCTAssertLessThanOrEqual(source.reads, 2,
                                 "200 fields inside one window read the source "
                                 + "\(source.reads) times")
    }

    /// A caller already reading in bulk — a scan taking its next megabyte, a
    /// free-space check walking a volume — would only evict the window, so it
    /// goes straight through.
    func testABulkReadIsNotWindowed() {
        let source = CountingSource(image)
        let windowed = WindowedByteSource(source, window: 256)

        _ = windowed.word(at: 0, count: 4)
        let before = source.reads
        XCTAssertEqual(windowed.bytes(in: 0..<2048), Array(image[0..<2048]))
        XCTAssertEqual(source.reads, before + 1, "the bulk read went to the source")
        // And the window it did not touch still answers.
        _ = windowed.word(at: 8, count: 4)
        XCTAssertEqual(source.reads, before + 1, "without re-reading for it")
    }

    /// A read the window cannot cover — one that would run past the end of the
    /// source — falls through rather than answering short.
    func testAReadPastTheEndFallsThrough() {
        let source = CountingSource(image)
        let windowed = WindowedByteSource(source, window: 256)
        let last = UInt64(image.count) - 4

        XCTAssertEqual(windowed.word(at: last, count: 4),
                       ImageReader(image).source.word(at: last, count: 4))
    }
}
