import XCTest
@testable import DumpCompareCore

final class FileBackedStorageTests: XCTestCase {
    /// A read is always clamped to EOF and never throws for asking too much: it
    /// returns what is there, down to nothing at all.
    func testReadsAreClampedToEOF() throws {
        let cases: [(name: String, file: [UInt8], offset: UInt64, length: Int, expected: [UInt8])] = [
            ("the whole file, asking for more than it holds",
             [0x01, 0x02, 0x03, 0x04, 0x05], 0, 10, [0x01, 0x02, 0x03, 0x04, 0x05]),
            ("from the middle, past the end",
             [0xAA, 0xBB, 0xCC], 1, 5, [0xBB, 0xCC]),
            ("the last byte",
             [0xAA, 0xBB, 0xCC], 2, 3, [0xCC]),
            ("an offset exactly at EOF",
             [0xAA, 0xBB, 0xCC], 3, 1, []),
            ("an offset far past EOF",
             [0xAA, 0xBB, 0xCC], 100, 4, []),
            ("an empty file",
             [], 0, 10, []),
            ("a zero-length read",
             [0x01], 0, 0, []),
        ]
        for testCase in cases {
            let storage = try TestSupport.makeStorage(Data(testCase.file))
            XCTAssertEqual(storage.size, UInt64(testCase.file.count), "\(testCase.name): size")
            XCTAssertEqual(try storage.read(at: testCase.offset, length: testCase.length),
                           testCase.expected, testCase.name)
        }
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

    /// Opening something that is not a readable file fails with the specific
    /// error §16 maps to its own alert, not a generic one.
    func testOpenErrors() throws {
        let cases: [(name: String, url: () throws -> URL, expected: StorageError)] = [
            ("a path with no file at it", {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("missing-\(UUID().uuidString).bin")
            }, .fileNotFound),
            ("a directory", {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dc-dir-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }, .isDirectory),
            ("a file no one may read", {
                let url = try TestSupport.makeTempFile(contents: Data([0x01]))
                try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                                     ofItemAtPath: url.path)
                XCTAssertFalse(FileManager.default.isReadableFile(atPath: url.path),
                               "the file really is unreadable")
                return url
            }, .permissionDenied),
            // A character device, not a FIFO: `open(2)` on a FIFO with no writer
            // blocks forever, which would hang the suite rather than fail it.
            ("something that is not a regular file", {
                URL(fileURLWithPath: "/dev/null")
            }, .notRegularFile),
        ]
        for testCase in cases {
            let url = try testCase.url()
            defer {
                // Give the chmod'ed fixture its permissions back so it can be
                // cleaned up; never touch a path outside the temp directory.
                if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                           ofItemAtPath: url.path)
                }
            }
            XCTAssertThrowsError(try FileBackedStorage(url: url), testCase.name) { error in
                XCTAssertEqual(error as? StorageError, testCase.expected, testCase.name)
            }
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
