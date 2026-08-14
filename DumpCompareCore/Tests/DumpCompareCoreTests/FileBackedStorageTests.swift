import XCTest
@testable import DumpCompareCore

final class FileBackedStorageTests: XCTestCase {
    func testSizeAndFullRead() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let storage = try TestSupport.makeStorage(data)
        XCTAssertEqual(storage.size, 5)
        XCTAssertEqual(try storage.read(at: 0, length: 10), [0x01, 0x02, 0x03, 0x04, 0x05])
    }

    func testReadClampsAtEOF() throws {
        let storage = try TestSupport.makeStorage(Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(try storage.read(at: 1, length: 5), [0xBB, 0xCC])
        XCTAssertEqual(try storage.read(at: 2, length: 3), [0xCC])
        XCTAssertEqual(try storage.read(at: 3, length: 1), [])
        XCTAssertEqual(try storage.read(at: 100, length: 4), [])
    }

    func testReadAcrossChunkBoundaries() throws {
        let cache = ChunkCache(config: .init(chunkSize: 4, byteBudget: 1024))
        var data = Data()
        for i in 0..<50 { data.append(UInt8(i)) }
        let storage = try TestSupport.makeStorage(data, cache: cache)

        XCTAssertEqual(try storage.read(at: 0, length: 50), Array(data))
        XCTAssertEqual(try storage.read(at: 3, length: 10), Array(data[3..<13]))
        XCTAssertEqual(try storage.read(at: 49, length: 5), [49])
        XCTAssertEqual(try storage.read(at: 15, length: 1), [15])
    }

    func testEmptyFile() throws {
        let storage = try TestSupport.makeStorage(Data())
        XCTAssertEqual(storage.size, 0)
        XCTAssertEqual(try storage.read(at: 0, length: 10), [])
    }

    func testZeroLengthReadReturnsEmpty() throws {
        let storage = try TestSupport.makeStorage(Data([0x01]))
        XCTAssertEqual(try storage.read(at: 0, length: 0), [])
    }

    func testMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).bin")
        XCTAssertThrowsError(try FileBackedStorage(url: url)) { error in
            XCTAssertEqual(error as? StorageError, .fileNotFound)
        }
    }

    func testDirectoryThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileBackedStorage(url: dir)) { error in
            XCTAssertEqual(error as? StorageError, .isDirectory)
        }
    }

    func testReadsPreserveContentAcrossRepeatedAccess() throws {
        var data = Data()
        for i in 0..<1000 { data.append(UInt8(truncatingIfNeeded: i)) }
        let cache = ChunkCache(config: .init(chunkSize: 64, byteBudget: 128))
        let storage = try TestSupport.makeStorage(data, cache: cache)
        // Read many overlapping windows; all must match the source.
        for start in stride(from: 0, to: 1000, by: 13) {
            let bytes = try storage.read(at: UInt64(start), length: 40)
            XCTAssertEqual(bytes, Array(data[start..<min(start + 40, 1000)]))
        }
    }

    func testLargeSparseFileReadsChunksWithBoundedMemory() throws {
        // A 1 GiB sparse file (no disk blocks allocated) must open instantly and
        // read correctly at arbitrary offsets while the cache stays far below
        // the file size — the "no full-RAM loading" requirement (§13).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-large-\(UUID().uuidString).bin")
        let fd = Darwin.open(url.path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        let giga: off_t = 1 << 30
        XCTAssertEqual(Darwin.ftruncate(fd, giga), 0)

        let cache = ChunkCache(config: .init(chunkSize: 64 * 1024, byteBudget: 1024 * 1024))
        let storage = try FileBackedStorage(url: url, cache: cache)
        XCTAssertEqual(storage.size, UInt64(giga))

        // Scattered offsets spanning many chunk indices (including the last byte).
        let probes: [UInt64] = [0, 64 * 1024 - 1, 64 * 1024, 1_000_000, UInt64(giga) - 1]
        for offset in probes {
            let bytes = try storage.read(at: offset, length: 8)
            XCTAssertEqual(bytes, [UInt8](repeating: 0, count: bytes.count))
        }
        XCTAssertLessThanOrEqual(cache.cachedByteCount, 1024 * 1024)
    }
}
