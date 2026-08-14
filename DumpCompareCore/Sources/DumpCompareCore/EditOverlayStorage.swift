import Foundation

/// An editable byte stream layered over a read-only base (decision D3).
///
/// - Overwrites and appends-at-EOF are recorded in a sparse `OverlayRangeMap`.
///   They never shift offsets, stay cheap, and can be saved by patching the
///   original file in place.
/// - Any length-changing edit (`insert`/`delete`) re-creates the base as a
///   temporary file holding the current content (copy-on-write), then marks the
///   storage as requiring a full rewrite on save.
///
/// Thread safety: all state is guarded by a lock; reads and mutations may come
/// from any thread.
public final class EditOverlayStorage: EditableByteStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var base: any ByteStorage
    private var overlay = OverlayRangeMap()
    private var logicalSize: UInt64
    private var didLengthChange = false
    private let cache: ChunkCache
    private let tempStore: TemporaryFileStore

    /// The file this storage was opened from, when the base is file-backed.
    /// Used by `StorageSaver` to decide whether patching in place is safe: the
    /// on-disk bytes at untouched offsets still match the base only when saving
    /// to the very file the base reads from.
    public private(set) var originalURL: URL?

    public init(
        base: any ByteStorage,
        cache: ChunkCache = ChunkCache(),
        tempStore: TemporaryFileStore = TemporaryFileStore()
    ) {
        self.base = base
        self.cache = cache
        self.tempStore = tempStore
        self.logicalSize = base.size
        self.originalURL = (base as? FileBackedStorage)?.url
    }

    deinit {
        tempStore.removeAll()
    }

    // MARK: - ByteStorage

    public var size: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return logicalSize
    }

    public func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return try readLocked(at: offset, length: length)
    }

    // MARK: - EditableByteStorage

    public func overwrite(range: Range<UInt64>, with bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        try overwriteLocked(bytes, at: range.lowerBound)
    }

    public func append(_ bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        try overwriteLocked(bytes, at: logicalSize)
    }

    public func insert(at offset: UInt64, bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let insertOffset = min(offset, logicalSize)
        let newURL = try tempStore.createTempURL()
        try writeToNewBase(newURL) { writer in
            try writeRange(to: writer, start: 0, length: insertOffset)
            try writeBytes(bytes, to: writer)
            try writeRange(to: writer, start: insertOffset, length: logicalSize - insertOffset)
        }
        didLengthChange = true
    }

    public func delete(range: Range<UInt64>) throws {
        lock.lock()
        defer { lock.unlock() }
        let start = min(range.lowerBound, logicalSize)
        let end = min(range.upperBound, logicalSize)
        guard end > start else { return }
        let newURL = try tempStore.createTempURL()
        try writeToNewBase(newURL) { writer in
            try writeRange(to: writer, start: 0, length: start)
            try writeRange(to: writer, start: end, length: logicalSize - end)
        }
        didLengthChange = true
    }

    // MARK: - Save support

    /// Updates the file this storage's content is assumed to match. Called by
    /// the document layer after a Save As: the target now holds the current
    /// content, so later overwrite-only saves to it may patch in place.
    public func rebaseOriginalURL(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        originalURL = url
    }

    /// True when the overlay contains only overwrites (no offset-shifting edit),
    /// so saving can patch the original file in place.
    public var canPatchInPlace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didLengthChange
    }

    /// True when the storage holds any unsaved edit.
    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didLengthChange || !overlay.isEmpty
    }

    /// Ranges that differ from the base (in absolute, non-shifted coordinates).
    public var changedRanges: [Range<UInt64>] {
        lock.lock()
        defer { lock.unlock() }
        return overlay.changedRanges
    }

    // MARK: - Internals

    private func overwriteLocked(_ bytes: [UInt8], at offset: UInt64) throws {
        guard !bytes.isEmpty else { return }
        overlay.write(bytes, at: offset)
        let end = offset + UInt64(bytes.count)
        if end > logicalSize { logicalSize = end }
    }

    private func readLocked(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard length > 0, offset < logicalSize else { return [] }
        let count = min(UInt64(length), logicalSize - offset)
        var result = [UInt8](repeating: 0, count: Int(count))

        // Base bytes (may be fewer than `count` when the overlay extends past EOF).
        let baseBytes = try base.read(at: offset, length: Int(count))
        let copied = min(baseBytes.count, result.count)
        result[0..<copied] = baseBytes[0..<copied]

        // Overlay bytes spliced over the base.
        let window = offset..<(offset + count)
        for entry in overlay.entriesIntersecting(window) {
            let lo = max(entry.range.lowerBound, window.lowerBound)
            let hi = min(entry.range.upperBound, window.upperBound)
            guard hi > lo else { continue }
            let src = Int(lo - entry.range.lowerBound)
            let dst = Int(lo - offset)
            let n = Int(hi - lo)
            result[dst..<(dst + n)] = entry.bytes[src..<(src + n)]
        }
        return result
    }

    /// Writes the current content into `url` (copy-on-write materialization) and
    /// swaps the base, resetting the overlay.
    private func writeToNewBase(_ url: URL, body: (FileHandle) throws -> Void) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StorageError.writeFailed
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try body(handle)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // A ChunkCache is keyed by chunk index only, so one instance can never
        // serve two different files — sharing it across successive materialized
        // bases would serve stale chunks after the swap. Each materialized base
        // gets a fresh cache with the same budget; the old base is released.
        base = try FileBackedStorage(url: url, cache: ChunkCache(config: cache.config))
        overlay = OverlayRangeMap()
        logicalSize = base.size
    }

    private func writeRange(to handle: FileHandle, start: UInt64, length: UInt64) throws {
        guard length > 0 else { return }
        var remaining = length
        var position = start
        while remaining > 0 {
            let step = min(remaining, 1024 * 1024)
            let bytes = try readLocked(at: position, length: Int(step))
            guard !bytes.isEmpty else { break }
            try handle.write(contentsOf: Data(bytes))
            position += UInt64(bytes.count)
            remaining -= UInt64(bytes.count)
        }
    }

    private func writeBytes(_ bytes: [UInt8], to handle: FileHandle) throws {
        guard !bytes.isEmpty else { return }
        try handle.write(contentsOf: Data(bytes))
    }
}
