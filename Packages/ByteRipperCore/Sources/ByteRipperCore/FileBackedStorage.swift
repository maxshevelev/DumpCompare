import Foundation

/// Read-only byte storage backed by a file on disk.
///
/// Reads are served lazily through a bounded `ChunkCache` using position-
/// independent `pread(2)`, so the file is never loaded whole and the same
/// storage can be read from multiple threads safely.
public final class FileBackedStorage: ByteStorage, @unchecked Sendable {
    public let url: URL
    public let cache: ChunkCache
    public private(set) var size: UInt64

    private let fileDescriptor: Int32

    /// Opens `url` for reading, validating that it is a regular file.
    /// Throws `.fileNotFound`, `.isDirectory`, `.permissionDenied`, or
    /// `.notRegularFile` as appropriate (§4, §16 of REQUIREMENTS.md).
    public init(url: URL, cache: ChunkCache = ChunkCache()) throws {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw StorageError.fromOpenError(errno)
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            throw StorageError.readFailed
        }

        let mode = st.st_mode & S_IFMT
        if mode == S_IFDIR {
            Darwin.close(fd)
            throw StorageError.isDirectory
        }
        guard mode == S_IFREG else {
            Darwin.close(fd)
            throw StorageError.notRegularFile
        }

        self.url = url
        self.cache = cache
        self.size = UInt64(st.st_size)
        self.fileDescriptor = fd
    }

    deinit {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
        }
    }

    // MARK: - ByteStorage

    public func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard length > 0, offset < size else { return [] }
        let count = min(UInt64(length), size - offset)
        let chunkSize = UInt64(cache.config.chunkSize)

        var result = [UInt8]()
        result.reserveCapacity(Int(count))
        var remaining = count
        var position = offset

        while remaining > 0 {
            let chunkIndex = position / chunkSize
            let offsetInChunk = Int(position % chunkSize)
            let wanted = min(remaining, chunkSize - UInt64(offsetInChunk))
            let chunk = try chunkData(chunkIndex)
            let take = min(Int(wanted), chunk.count - offsetInChunk)
            guard take > 0 else { break }
            result.append(contentsOf: chunk[offsetInChunk..<(offsetInChunk + take)])
            position += UInt64(take)
            remaining -= UInt64(take)
        }
        return result
    }

    // MARK: - Internals

    private func chunkData(_ index: UInt64) throws -> [UInt8] {
        if let cached = cache.chunk(index) { return cached }

        let fileOffset = index * UInt64(cache.config.chunkSize)
        guard fileOffset < size else { return [] }
        let count = min(cache.config.chunkSize, Int(size - fileOffset))

        var buffer = [UInt8](repeating: 0, count: count)
        let readCount = try buffer.withUnsafeMutableBytes { raw -> Int in
            try preadAll(raw.baseAddress!, count: count, at: off_t(fileOffset))
        }
        let bytes = Array(buffer.prefix(readCount))
        cache.setChunk(index, bytes: bytes)
        return bytes
    }

    /// Loops `pread(2)` until `count` bytes are read or EOF, retrying on EINTR.
    private func preadAll(_ destination: UnsafeMutableRawPointer, count: Int, at offset: off_t) throws -> Int {
        var total = 0
        var cursor = destination
        while total < count {
            let n = Darwin.pread(fileDescriptor, cursor, count - total, offset + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                throw StorageError.readFailed
            }
            if n == 0 { break }
            total += n
            cursor = cursor.advanced(by: n)
        }
        return total
    }
}
