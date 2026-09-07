import Foundation

/// Read-only access to a stream of bytes.
///
/// Reads are synchronous and thread-safe: a bounded chunk cache keeps small,
/// visible-region reads fast, while long-running consumers (full-file diff,
/// search, save) run in background tasks and read in bounded chunks.
///
/// - `size` is the total number of bytes.
/// - `read(at:length:)` returns up to `length` bytes at `offset`, clamped to EOF
///   (it never throws for a request past the end; it returns fewer/empty bytes).
public protocol ByteStorage: Sendable {
    var size: UInt64 { get }
    func read(at offset: UInt64, length: Int) throws -> [UInt8]
}

/// Mutable byte storage. All mutations record enough history for the document
/// layer to build undo/redo and dirty state on top.
public protocol EditableByteStorage: ByteStorage {
    /// Overwrites `bytes` starting at `range.lowerBound` (the range supplies the
    /// start offset; exactly `bytes.count` bytes are written). Extends the file
    /// past EOF when needed. Never shifts existing offsets.
    func overwrite(range: Range<UInt64>, with bytes: [UInt8]) throws

    /// Inserts `bytes` at `offset`, shifting subsequent offsets.
    func insert(at offset: UInt64, bytes: [UInt8]) throws

    /// Removes `range` of bytes, shifting subsequent offsets.
    func delete(range: Range<UInt64>) throws

    /// Appends `bytes` at the current end of the file.
    func append(_ bytes: [UInt8]) throws
}
