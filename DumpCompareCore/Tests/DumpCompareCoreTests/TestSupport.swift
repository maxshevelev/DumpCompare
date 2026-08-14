import Foundation
@testable import DumpCompareCore

/// Shared helpers for storage tests.
enum TestSupport {
    /// Creates a temporary file with `contents` and returns its URL.
    static func makeTempFile(contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DumpCompareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("data.bin")
        try contents.write(to: url)
        return url
    }

    /// Reads a whole file from disk.
    static func readAll(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Opens a file-backed storage over a temp file.
    static func makeStorage(_ data: Data, cache: ChunkCache = ChunkCache()) throws -> FileBackedStorage {
        let url = try makeTempFile(contents: data)
        return try FileBackedStorage(url: url, cache: cache)
    }

    /// Reads every byte of an editable storage.
    static func readAll(_ storage: EditOverlayStorage) throws -> [UInt8] {
        var result: [UInt8] = []
        var offset: UInt64 = 0
        while offset < storage.size {
            let bytes = try storage.read(at: offset, length: 64 * 1024)
            guard !bytes.isEmpty else { break }
            result.append(contentsOf: bytes)
            offset += UInt64(bytes.count)
        }
        return result
    }
}
