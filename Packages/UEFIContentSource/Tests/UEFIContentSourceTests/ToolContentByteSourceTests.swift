import XCTest
import ToolModuleKit
@testable import UEFIContentSource

/// A reader over bytes held in memory, which can be told to fail — the one
/// interesting thing about the adapter is what it does when a read throws.
private struct StubReader: ToolContentReader {
    let bytes: [UInt8]
    let fails: Bool

    init(_ bytes: [UInt8], fails: Bool = false) {
        self.bytes = bytes
        self.fails = fails
    }

    var size: UInt64 { UInt64(bytes.count) }

    struct Failure: Error {}

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        if fails { throw Failure() }
        let start = Int(offset)
        return Array(bytes[start..<(start + length)])
    }
}

final class ToolContentByteSourceTests: XCTestCase {
    func testByteCountIsTheReadersSize() {
        let source = ToolContentByteSource(reader: StubReader([1, 2, 3, 4]))

        XCTAssertEqual(source.byteCount, 4,
                       "the parser asks the adapter how big the file is, and the "
                       + "answer has to be the host's own size")
    }

    func testAHalfOpenRangeReadsThoseBytes() {
        let source = ToolContentByteSource(reader: StubReader([0xAA, 0xBB, 0xCC, 0xDD]))

        XCTAssertEqual(source.bytes(in: 1..<3), [0xBB, 0xCC],
                       "[1, 3) is two bytes at offset 1 — the conversion from a "
                       + "half-open range to offset and length is the whole job")
    }

    func testAFailedReadYieldsZerosOfTheRightLength() {
        let source = ToolContentByteSource(reader: StubReader([1, 2, 3, 4], fails: true))

        XCTAssertEqual(source.bytes(in: 0..<3), [0, 0, 0],
                       "a parser's bounds arithmetic counts on getting back what "
                       + "it asked for; a short array would break it further "
                       + "along than the read that actually failed")
    }
}
