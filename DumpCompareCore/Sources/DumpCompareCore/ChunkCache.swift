import Foundation

/// A bounded, thread-safe LRU cache for fixed-size byte chunks.
///
/// This is what lets very large files be opened without loading them into RAM:
/// the file is read lazily in chunks, and only the most recently used chunks are
/// kept in memory (§13 of REQUIREMENTS.md).
public final class ChunkCache: @unchecked Sendable {
    public struct Config: Sendable {
        public var chunkSize: Int
        public var byteBudget: Int

        public init(chunkSize: Int = 64 * 1024, byteBudget: Int = 32 * 1024 * 1024) {
            self.chunkSize = chunkSize
            self.byteBudget = byteBudget
        }
    }

    private final class Node {
        let index: UInt64
        var bytes: [UInt8]
        var prev: Node?
        var next: Node?

        init(index: UInt64, bytes: [UInt8]) {
            self.index = index
            self.bytes = bytes
        }
    }

    public let config: Config

    private let lock = NSLock()
    private var table: [UInt64: Node] = [:]
    private var head: Node?   // most recently used
    private var tail: Node?   // least recently used
    private var currentBytes = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Returns the cached chunk for `index`, or `nil` if absent.
    /// A hit marks the chunk as most-recently-used.
    public func chunk(_ index: UInt64) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = table[index] else { return nil }
        moveToHead(node)
        return node.bytes
    }

    /// Inserts or replaces the chunk for `index`, evicting least-recently-used
    /// chunks while over the byte budget.
    public func setChunk(_ index: UInt64, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        if let node = table[index] {
            currentBytes -= node.bytes.count
            node.bytes = bytes
            currentBytes += bytes.count
            moveToHead(node)
        } else {
            let node = Node(index: index, bytes: bytes)
            table[index] = node
            pushToHead(node)
            currentBytes += bytes.count
        }
        evictWhileOverBudget()
    }

    public func remove(_ index: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let node = table[index] else { return }
        unlink(node)
        table[index] = nil
        currentBytes -= node.bytes.count
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        table.removeAll()
        head = nil
        tail = nil
        currentBytes = 0
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return table.count
    }

    public var cachedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentBytes
    }

    // MARK: - LRU list

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        pushToHead(node)
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func pushToHead(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func evictWhileOverBudget() {
        while currentBytes > config.byteBudget, let victim = tail {
            unlink(victim)
            table[victim.index] = nil
            currentBytes -= victim.bytes.count
        }
    }
}
