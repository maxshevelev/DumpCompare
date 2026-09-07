import Foundation

/// An editable byte buffer held entirely in memory (File > New File documents).
///
/// Nothing is written to disk until the document layer saves it — the buffer
/// lets the user build up data before choosing a location. All state is guarded
/// by a lock, so reads and mutations may come from any thread, the same contract
/// as the file-backed storages.
public final class MemoryBackedStorage: EditableByteStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8]

    public init(bytes: [UInt8] = []) {
        self.data = bytes
    }

    public var size: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return UInt64(data.count)
    }

    public func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard length > 0, offset < UInt64(data.count) else { return [] }
        let start = Int(offset)
        let count = min(length, data.count - start)
        return Array(data[start..<(start + count)])
    }

    public func overwrite(range: Range<UInt64>, with bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let start = Int(range.lowerBound)
        let end = start + bytes.count
        if end > data.count {
            // Writing past EOF zero-fills the gap, then lays the bytes over it —
            // the same shape EditOverlayStorage produces.
            data.append(contentsOf: [UInt8](repeating: 0, count: end - data.count))
        }
        data.replaceSubrange(start..<start + bytes.count, with: bytes)
    }

    public func insert(at offset: UInt64, bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.insert(contentsOf: bytes, at: min(Int(offset), data.count))
    }

    public func delete(range: Range<UInt64>) throws {
        lock.lock()
        defer { lock.unlock() }
        let start = min(Int(range.lowerBound), data.count)
        let end = min(Int(range.upperBound), data.count)
        guard end > start else { return }
        data.removeSubrange(start..<end)
    }

    public func append(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(contentsOf: bytes)
    }
}
