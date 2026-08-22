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

    /// Reads every byte of a storage.
    static func readAll(_ storage: any ByteStorage) throws -> [UInt8] {
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

/// A deterministic `RandomNumberGenerator` for the property tests: a failing
/// case can be replayed by pasting back the seed its failure message prints.
/// One LCG step (the constants the alignment test used inline) plus a
/// splitmix64 finalizer, because `random(in:)` leans on the low bits an LCG
/// leaves weak.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Minimal in-memory `ByteStorage` for engine tests (diff/search).
struct ArrayStorage: ByteStorage {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var size: UInt64 { UInt64(bytes.count) }

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard length > 0, offset < size else { return [] }
        let start = Int(offset)
        let end = min(start + length, bytes.count)
        return Array(bytes[start..<end])
    }
}

/// A storage that parks its reader inside one chosen `read` until the test lets
/// it through, and reports when it has parked. Everything the test does in
/// between happens provably mid-scan: the reader is suspended inside a read, so
/// it cannot cover another chunk, report more progress or yield another match.
/// This is the seam the diff and search tests use in place of a sleep.
final class GatedStorage: ByteStorage, @unchecked Sendable {
    let size: UInt64
    private let byte: UInt8
    /// Which read (1-based) to park in. Read *n* is chunk *n*, so parking in the
    /// second one means exactly one chunk's progress has been recorded.
    private let parkAtRead: Int
    private let lock = NSLock()
    private var reads = 0
    private let gate = DispatchSemaphore(value: 0)
    private let parked = DispatchSemaphore(value: 0)

    init(size: UInt64, byte: UInt8, parkAtRead: Int) {
        self.size = size
        self.byte = byte
        self.parkAtRead = parkAtRead
    }

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        lock.lock()
        reads += 1
        let nth = reads
        lock.unlock()
        if nth == parkAtRead {
            parked.signal()
            gate.wait()
        }
        guard length > 0, offset < size else { return [] }
        return [UInt8](repeating: byte, count: Int(min(UInt64(length), size - offset)))
    }

    /// Suspends until the reader has parked. Waits on a plain queue, so no
    /// cooperative thread is blocked while the scan runs.
    func awaitPark() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.parked.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        gate.signal()
    }
}
