import Foundation

/// A description of a single edit to one side of a comparison, used to update a
/// `DiffBlockIndex` incrementally (§8.3).
///
/// - `.overwrite` changes bytes without shifting offsets, so only the
///   overwritten region can change state.
/// - `.insert` / `.delete` shift offsets, so everything from the earliest
///   affected offset onward must be reconsidered.
public enum DiffEdit: Equatable, Sendable {
    /// `range` now holds new bytes in the edited file (offset-preserving).
    case overwrite(range: Range<UInt64>)
    /// `length` bytes were inserted at `at` in the edited file (offset-shifting).
    case insert(at: UInt64, length: UInt64)
    /// `range` was deleted in the edited file (offset-shifting).
    case delete(range: Range<UInt64>)

    /// The offset from which the comparison is no longer trustworthy.
    var earliestAffectedOffset: UInt64 {
        switch self {
        case .overwrite(let range): return range.lowerBound
        case .insert(let at, _): return at
        case .delete(let range): return range.lowerBound
        }
    }

    /// Derives the single net edit an undo/redo transaction produces, given the
    /// ops in the exact order they mutate storage (forward order for a redo;
    /// inverse ops in reversed order for an undo). `DiffEngine.apply` is
    /// self-correcting — it rescans against current bytes — so the edit only
    /// needs to cover every offset the transaction could have changed:
    /// - a length-changing transaction emits `.insert`/`.delete` from the
    ///   earliest **pre-shift** op offset, which makes `apply` rescan that
    ///   offset to EOF;
    /// - a length-preserving transaction (all overwrites, in this app — a typing
    ///   pair, a fill) emits `.overwrite` over its bounding window.
    ///
    /// Pre-shift bounds (not shifted by later inserts/deletes) are essential: an
    /// overwrite rewrites bytes in place, so a later insert that lands after the
    /// overwritten range does not move them — shifting the interval would put
    /// the window past the changed bytes.
    static func netDiffEdit(ops: [UndoOperation]) -> DiffEdit? {
        guard !ops.isEmpty else { return nil }
        var from = UInt64.max
        var maxEnd: UInt64 = 0
        var netDelta: Int64 = 0
        for op in ops {
            switch op {
            case .overwrite(let range, _, _):
                from = min(from, range.lowerBound)
                maxEnd = max(maxEnd, range.upperBound)
            case .insert(let at, let bytes):
                from = min(from, at)
                maxEnd = max(maxEnd, at + UInt64(bytes.count))
                netDelta += Int64(bytes.count)
            case .delete(let range, _):
                from = min(from, range.lowerBound)
                maxEnd = max(maxEnd, range.upperBound)
                netDelta -= Int64(range.count)
            }
        }
        if netDelta > 0 {
            return .insert(at: from, length: UInt64(netDelta))
        } else if netDelta < 0 {
            return .delete(range: from..<(from + UInt64(-netDelta)))
        } else {
            return .overwrite(range: from..<maxEnd)
        }
    }
}

/// Compares two byte streams strictly by absolute offset (§8).
///
/// All long-running work is chunked and takes a `shouldCancel`/`progress`
/// pair, so a full-file scan runs in the background without blocking the UI
/// (§8.3, §13). The synchronous engine is pure Swift and unit-testable; the
/// UI hosts it inside `DiffIndexBuilder` (an actor) during Milestone 5.
public enum DiffEngine {
    public static let defaultChunkSize = 1024 * 1024

    /// Computes the block list for two in-memory byte arrays.
    /// Convenience for tests and small inputs.
    public static func blocks(left: [UInt8], right: [UInt8]) -> [DiffBlock] {
        var builder = BlockBuilder()
        let common = min(left.count, right.count)

        var runStart: Int?
        var runKind: DiffBlock.Kind?
        func flushRun(at end: Int) {
            if let start = runStart, let kind = runKind {
                builder.appendRun(kind, range: UInt64(start)..<UInt64(end))
            }
            runStart = nil
            runKind = nil
        }
        for index in 0..<common {
            let kind: DiffBlock.Kind = left[index] == right[index] ? .same : .different
            if runKind == nil {
                runKind = kind
                runStart = index
            } else if runKind != kind {
                flushRun(at: index)
                runKind = kind
                runStart = index
            }
        }
        flushRun(at: common)

        // EOF-only bytes of the longer file fold into a different block (§8.1).
        if left.count != right.count {
            builder.appendRun(.different, range: UInt64(common)..<UInt64(max(left.count, right.count)))
        }
        return builder.finish()
    }

    /// Builds a full-file index by chunked scan, comparing both streams at the
    /// same absolute offsets. Throws `CancellationError` when `shouldCancel`
    /// returns true between chunks; reports progress in `[0, 1]`.
    public static func scan(
        left: ByteStorage,
        right: ByteStorage,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> DiffBlockIndex {
        let blocks = try scanRange(
            left: left, right: right, from: 0, to: max(left.size, right.size),
            chunkSize: chunkSize, shouldCancel: shouldCancel, progress: progress
        )
        return DiffBlockIndex(leftSize: left.size, rightSize: right.size, blocks: blocks)
    }

    /// Async variant of `scan` for use inside an actor: yields to the
    /// cooperative pool between chunks so a long build keeps the hosting actor
    /// responsive to `progress` reads and new cancellation requests (§8.3,
    /// §14.4). Same loop and result as `scan` — the shared per-chunk work lives
    /// in `appendChunk`.
    public static func scanAsync(
        left: ByteStorage,
        right: ByteStorage,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) async throws -> DiffBlockIndex {
        let blocks = try await scanRangeAsync(
            left: left, right: right, from: 0, to: max(left.size, right.size),
            chunkSize: chunkSize, shouldCancel: shouldCancel, progress: progress
        )
        return DiffBlockIndex(leftSize: left.size, rightSize: right.size, blocks: blocks)
    }

    /// Finds the first block of `kind` in `direction` from `offset`, by
    /// scanning storage. Used for on-demand navigation while a full index is
    /// still building (§10.3): the result matches `DiffBlockIndex` semantics —
    /// forward finds blocks starting strictly after `offset`, backward finds
    /// blocks ending at or before `offset`. Chunked and cancellable so a
    /// long scan never blocks the UI thread (the UI runs it off-main).
    public static func findBlock(
        kind: DiffBlock.Kind,
        direction: SearchDirection,
        from offset: UInt64,
        left: ByteStorage,
        right: ByteStorage,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false }
    ) throws -> DiffBlock? {
        let maxSize = max(left.size, right.size)
        switch direction {
        case .forward:
            guard offset < maxSize else { return nil }
            let blocks = try scanRange(
                left: left, right: right, from: offset, to: maxSize,
                chunkSize: chunkSize, shouldCancel: shouldCancel, progress: { _ in }
            )
            return blocks.first { $0.kind == kind && $0.range.lowerBound > offset }
        case .backward:
            guard maxSize > 0 else { return nil }
            let blocks = try scanRange(
                left: left, right: right, from: 0, to: maxSize,
                chunkSize: chunkSize, shouldCancel: shouldCancel, progress: { _ in }
            )
            return blocks.last { $0.kind == kind && $0.range.upperBound <= offset }
        }
    }

    /// Applies `edit` to `index`, rebuilding only what the edit invalidates
    /// (§8.3):
    /// - `.overwrite` recomputes just `[s, e)` and splices it back, keeping the
    ///   untouched bytes on both sides;
    /// - `.insert` / `.delete` drop the blocks at/after the earliest affected
    ///   offset and rescan to the new EOF.
    public static func apply(
        _ edit: DiffEdit,
        to index: DiffBlockIndex,
        left: ByteStorage,
        right: ByteStorage,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> DiffBlockIndex {
        let newMax = max(left.size, right.size)
        var builder = BlockBuilder()

        switch edit {
        case .overwrite(let range):
            let start = range.lowerBound
            let end = min(range.upperBound, newMax)

            // Bytes strictly before `start` keep their old state.
            appendPrefix(of: index, upTo: start, into: &builder)

            // If the edit lands beyond the previous comparison extent, the bytes
            // between the old and new extents are EOF-only in one file.
            if start > index.maxSize {
                builder.appendRun(.different, range: index.maxSize..<start)
            }

            // Recompute only the overwritten window.
            let middle = try scanRange(
                left: left, right: right, from: start, to: end,
                chunkSize: chunkSize, shouldCancel: shouldCancel, progress: progress
            )
            for block in middle { builder.appendRun(block.kind, range: block.range) }

            // Bytes at/after `end` keep their old state.
            for block in index.blocks {
                if block.range.lowerBound >= end {
                    builder.appendRun(block.kind, range: block.range)
                } else if block.range.upperBound > end {
                    builder.appendRun(block.kind, range: end..<block.range.upperBound)
                }
            }
            return DiffBlockIndex(leftSize: left.size, rightSize: right.size, blocks: builder.finish())

        case .insert, .delete:
            // Offset shift: everything from the earliest affected offset onward
            // is reconsidered (§8.3).
            let from = edit.earliestAffectedOffset
            appendPrefix(of: index, upTo: from, into: &builder)
            let tail = try scanRange(
                left: left, right: right, from: from, to: newMax,
                chunkSize: chunkSize, shouldCancel: shouldCancel, progress: progress
            )
            for block in tail { builder.appendRun(block.kind, range: block.range) }
            return DiffBlockIndex(leftSize: left.size, rightSize: right.size, blocks: builder.finish())
        }
    }

    /// Copies the blocks of `index` that end at or before `from` into `builder`,
    /// trimming the block that contains `from` at that offset. Everything at or
    /// after `from` is left to a fresh scan.
    private static func appendPrefix(of index: DiffBlockIndex, upTo from: UInt64, into builder: inout BlockBuilder) {
        for block in index.blocks {
            if block.range.upperBound <= from {
                builder.appendRun(block.kind, range: block.range)
            } else if block.range.lowerBound < from {
                builder.appendRun(block.kind, range: block.range.lowerBound..<from)
            } else {
                break
            }
        }
    }

    /// Scans `[from, to)` and returns the blocks, folding the EOF-only tail
    /// (bytes present in only the longer file) into a different block.
    private static func scanRange(
        left: ByteStorage,
        right: ByteStorage,
        from: UInt64,
        to: UInt64,
        chunkSize: Int,
        shouldCancel: () -> Bool,
        progress: (Double) -> Void
    ) throws -> [DiffBlock] {
        var builder = BlockBuilder()
        let common = min(left.size, right.size)
        let comparedEnd = min(to, common)
        let total = to > from ? to - from : 0

        var offset = from
        var processed: UInt64 = 0
        while offset < comparedEnd {
            if shouldCancel() { throw CancellationError() }
            let length = Int(min(UInt64(chunkSize), comparedEnd - offset))
            let n = try appendChunk(left: left, right: right, offset: offset, length: length, into: &builder)
            offset += UInt64(n)
            processed += UInt64(n)
            if total > 0 { progress(Double(processed) / Double(total)) }
        }

        let tailStart = max(from, common)
        if to > tailStart {
            builder.appendRun(.different, range: tailStart..<to)
        }
        if total > 0 { progress(1) }
        return builder.finish()
    }

    /// Compares the bytes at `[offset, offset+length)` in both storages and
    /// appends the runs to `builder`. Returns the number of bytes actually
    /// compared (a storage may return fewer than requested at EOF).
    private static func appendChunk(
        left: ByteStorage,
        right: ByteStorage,
        offset: UInt64,
        length: Int,
        into builder: inout BlockBuilder
    ) throws -> Int {
        let a = try left.read(at: offset, length: length)
        let b = try right.read(at: offset, length: length)
        let n = min(a.count, b.count)

        var runStart: Int?
        var runKind: DiffBlock.Kind?
        for j in 0..<n {
            let kind: DiffBlock.Kind = a[j] == b[j] ? .same : .different
            if runKind == nil {
                runKind = kind
                runStart = j
            } else if runKind != kind {
                builder.appendRun(runKind!, range: (offset + UInt64(runStart!))..<(offset + UInt64(j)))
                runKind = kind
                runStart = j
            }
        }
        if let kind = runKind, let start = runStart {
            builder.appendRun(kind, range: (offset + UInt64(start))..<(offset + UInt64(n)))
        }
        return n
    }

    /// Async twin of `scanRange`: same per-chunk work, but yields after each
    /// chunk so a hosting actor can service `progress` reads and new
    /// cancellation requests while a long build is in flight.
    private static func scanRangeAsync(
        left: ByteStorage,
        right: ByteStorage,
        from: UInt64,
        to: UInt64,
        chunkSize: Int,
        shouldCancel: () -> Bool,
        progress: (Double) -> Void
    ) async throws -> [DiffBlock] {
        var builder = BlockBuilder()
        let common = min(left.size, right.size)
        let comparedEnd = min(to, common)
        let total = to > from ? to - from : 0

        var offset = from
        var processed: UInt64 = 0
        while offset < comparedEnd {
            if shouldCancel() { throw CancellationError() }
            let length = Int(min(UInt64(chunkSize), comparedEnd - offset))
            let n = try appendChunk(left: left, right: right, offset: offset, length: length, into: &builder)
            offset += UInt64(n)
            processed += UInt64(n)
            if total > 0 { progress(Double(processed) / Double(total)) }
            // Let the hosting actor service `progress` reads (and new
            // cancellation requests) between chunks (§8.3, §14.4).
            await Task.yield()
        }

        let tailStart = max(from, common)
        if to > tailStart {
            builder.appendRun(.different, range: tailStart..<to)
        }
        if total > 0 { progress(1) }
        return builder.finish()
    }
}

/// Hosts a full-file diff build in the background (decision D5).
///
/// Runs on its own actor: `progress` is updated during a scan and `cancel()`
/// sets a flag the engine observes between chunks, so closing a pane or
/// changing inputs abandons the work promptly (§8.3, §14.4). `build` uses the
/// async engine scan and yields between chunks, so the UI's progress reads are
/// serviced mid-build instead of only after the scan completes.
public actor DiffIndexBuilder {
    public init() {}

    public private(set) var progress: Double = 0
    private var isCancelled = false

    public func cancel() {
        isCancelled = true
    }

    /// Prepares the builder for a new scan after a `cancel()`. Actor isolation
    /// guarantees this runs in order *after* the in-flight scan observes the
    /// cancellation and throws, so a subsequent `build` starts with a clear flag.
    public func reset() {
        isCancelled = false
        progress = 0
    }

    public func build(
        left: ByteStorage,
        right: ByteStorage,
        chunkSize: Int = DiffEngine.defaultChunkSize
    ) async throws -> DiffBlockIndex {
        // The async scan yields between chunks so the actor can service the UI's
        // `progress` reads while the build is in flight. A synchronous scan would
        // starve the actor for the whole build, leaving the progress bar frozen
        // at 0 until it finishes.
        try await DiffEngine.scanAsync(
            left: left, right: right, chunkSize: chunkSize,
            shouldCancel: { self.isCancelled },
            progress: { self.progress = $0 }
        )
    }

    public func apply(
        _ edit: DiffEdit,
        to index: DiffBlockIndex,
        left: ByteStorage,
        right: ByteStorage,
        chunkSize: Int = DiffEngine.defaultChunkSize
    ) throws -> DiffBlockIndex {
        try DiffEngine.apply(
            edit, to: index, left: left, right: right, chunkSize: chunkSize,
            shouldCancel: { self.isCancelled },
            progress: { self.progress = $0 }
        )
    }

    /// Groups an index's difference blocks into navigation hunks (§10.3.1).
    ///
    /// Lives on the actor so the pass runs off the main thread: it is linear in
    /// the block count, and a pair of files whose differing bytes alternate with
    /// matching ones holds a block per byte.
    public func hunks(for index: DiffBlockIndex, gap: UInt64) -> DiffHunkIndex {
        DiffHunkIndex(index: index, gap: gap)
    }

    /// On-demand block search while a full index is still building (§10.3).
    /// Chunked and cancellable; see `DiffEngine.findBlock`.
    public func scanForBlock(
        kind: DiffBlock.Kind,
        direction: SearchDirection,
        from offset: UInt64,
        left: ByteStorage,
        right: ByteStorage,
        chunkSize: Int = DiffEngine.defaultChunkSize
    ) throws -> DiffBlock? {
        try DiffEngine.findBlock(
            kind: kind, direction: direction, from: offset, left: left, right: right,
            chunkSize: chunkSize, shouldCancel: { self.isCancelled }
        )
    }
}

/// Accumulates maximal runs into a block list, merging a new run into the last
/// block when they share a kind and touch.
private struct BlockBuilder {
    private(set) var blocks: [DiffBlock] = []
    private var current: DiffBlock?

    mutating func appendRun(_ kind: DiffBlock.Kind, range: Range<UInt64>) {
        guard range.lowerBound < range.upperBound else { return }
        if let existing = current, existing.kind == kind, existing.range.upperBound == range.lowerBound {
            current = DiffBlock(kind: kind, range: existing.range.lowerBound..<range.upperBound)
        } else {
            if let existing = current { blocks.append(existing) }
            current = DiffBlock(kind: kind, range: range)
        }
    }

    mutating func finish() -> [DiffBlock] {
        var result = blocks
        if let existing = current {
            result.append(existing)
        }
        current = nil
        blocks = []
        return result
    }
}
