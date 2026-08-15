import XCTest
@testable import DumpCompareCore

final class MemoryBackedStorageTests: XCTestCase {
    private func readAll(_ s: MemoryBackedStorage) throws -> [UInt8] {
        var result: [UInt8] = []
        var offset: UInt64 = 0
        while offset < s.size {
            let bytes = try s.read(at: offset, length: 64 * 1024)
            guard !bytes.isEmpty else { break }
            result.append(contentsOf: bytes)
            offset += UInt64(bytes.count)
        }
        return result
    }

    func testEmptyStorageReadsEmpty() throws {
        let s = MemoryBackedStorage()
        XCTAssertEqual(s.size, 0)
        XCTAssertEqual(try readAll(s), [])
    }

    func testInitWithBytes() throws {
        let s = MemoryBackedStorage(bytes: [0x01, 0x02, 0x03])
        XCTAssertEqual(s.size, 3)
        XCTAssertEqual(try readAll(s), [0x01, 0x02, 0x03])
    }

    func testOverwriteReadBack() throws {
        let s = MemoryBackedStorage(bytes: [0x00, 0x00, 0x00, 0x00])
        try s.overwrite(range: 1..<3, with: [0xAA, 0xBB])
        XCTAssertEqual(try readAll(s), [0x00, 0xAA, 0xBB, 0x00])
    }

    func testOverwriteBeyondEOFExtendsSize() throws {
        let s = MemoryBackedStorage(bytes: [0x00])
        try s.overwrite(range: 1..<1, with: [0x01, 0x02])
        XCTAssertEqual(s.size, 3)
        XCTAssertEqual(try readAll(s), [0x00, 0x01, 0x02])
    }

    func testOverwriteFarBeyondEOFZeroFillsGap() throws {
        let s = MemoryBackedStorage(bytes: [0x01, 0x02])
        try s.overwrite(range: 5..<5, with: [0x99])
        XCTAssertEqual(try readAll(s), [0x01, 0x02, 0x00, 0x00, 0x00, 0x99])
    }

    func testAppend() throws {
        let s = MemoryBackedStorage(bytes: [0x01])
        try s.append([0x02, 0x03])
        XCTAssertEqual(s.size, 3)
        XCTAssertEqual(try readAll(s), [0x01, 0x02, 0x03])
    }

    func testInsertShiftsOffsets() throws {
        let s = MemoryBackedStorage(bytes: [0x01, 0x02, 0x03, 0x04])
        try s.insert(at: 2, bytes: [0xFF, 0xFE])
        XCTAssertEqual(s.size, 6)
        XCTAssertEqual(try readAll(s), [0x01, 0x02, 0xFF, 0xFE, 0x03, 0x04])
    }

    func testInsertAtEOFAppends() throws {
        let s = MemoryBackedStorage(bytes: [0x01, 0x02])
        try s.insert(at: 2, bytes: [0x03])
        XCTAssertEqual(try readAll(s), [0x01, 0x02, 0x03])
    }

    func testInsertOffsetBeyondEOFIsClamped() throws {
        let s = MemoryBackedStorage(bytes: [0x01, 0x02])
        try s.insert(at: 50, bytes: [0x03])
        XCTAssertEqual(try readAll(s), [0x01, 0x02, 0x03])
    }

    func testDeleteShrinks() throws {
        let s = MemoryBackedStorage(bytes: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        try s.delete(range: 2..<4)
        XCTAssertEqual(s.size, 4)
        XCTAssertEqual(try readAll(s), [0x00, 0x01, 0x04, 0x05])
    }

    func testDeleteClampedToSize() throws {
        let s = MemoryBackedStorage(bytes: [0x00, 0x01])
        try s.delete(range: 1..<10)
        XCTAssertEqual(s.size, 1)
        XCTAssertEqual(try readAll(s), [0x00])
    }

    func testMixedOperationsPreserveContent() throws {
        let s = MemoryBackedStorage(bytes: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        try s.overwrite(range: 0..<1, with: [0x99])
        try s.insert(at: 3, bytes: [0x77, 0x78])
        try s.delete(range: 5..<8)
        try s.append([0xEE])
        XCTAssertEqual(try readAll(s), [0x99, 0x01, 0x02, 0x77, 0x78, 0x06, 0x07, 0xEE])
    }

    func testReadClampsAtEOF() throws {
        let s = MemoryBackedStorage(bytes: [0x01, 0x02, 0x03])
        XCTAssertEqual(try s.read(at: 2, length: 100), [0x03])
        XCTAssertEqual(try s.read(at: 3, length: 100), [])
        XCTAssertEqual(try s.read(at: 50, length: 2), [])
    }
}
