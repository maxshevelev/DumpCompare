import Foundation

/// A maximal contiguous run of offsets where two files have the same diff
/// state (§8.1).
///
/// Comparison is strictly by absolute zero-based offset — no block matching or
/// alignment is ever performed (§8: comparison rules 1–3). The `range` is
/// half-open `[start, end)` in absolute offsets.
public struct DiffBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case same
        case different
    }

    public let kind: Kind
    public let range: Range<UInt64>

    public init(kind: Kind, range: Range<UInt64>) {
        self.kind = kind
        self.range = range
    }

    public var count: UInt64 { range.upperBound - range.lowerBound }
}

/// An immutable snapshot of the comparison between two byte streams (§8).
///
/// The blocks partition `[0, maxSize)` (the longer file's length) into
/// alternating same/different runs. Bytes only present in the longer file
/// (the shorter file is past EOF) fold into a `.different` block (§8.1).
///
/// `DiffBlockIndex` is a value type; edits produce a new index via
/// `DiffEngine.apply`, which rebuilds only the affected region. This matches
/// the incremental-invalidation lifecycle of §8.3.
public struct DiffBlockIndex: Equatable, Sendable {
    public let leftSize: UInt64
    public let rightSize: UInt64

    /// Blocks covering `[0, maxSize)`, sorted, non-overlapping, with adjacent
    /// blocks never sharing a kind.
    public let blocks: [DiffBlock]

    public init(leftSize: UInt64, rightSize: UInt64, blocks: [DiffBlock]) {
        self.leftSize = leftSize
        self.rightSize = rightSize
        self.blocks = DiffBlockIndex.coalesced(blocks)
    }

    /// The length of the longer file; the extent of the comparison.
    public var maxSize: UInt64 { max(leftSize, rightSize) }

    /// True when both files are empty.
    public var isEmpty: Bool { blocks.isEmpty }

    /// True when the comparison contains at least one `.different` block. O(1):
    /// the coalesced blocks alternate kinds, so two or more blocks guarantee a
    /// difference, and a single block is a difference only if it is one.
    public var hasDifferences: Bool {
        switch blocks.count {
        case 0: return false
        case 1: return blocks[0].kind == .different
        default: return true
        }
    }

    /// The diff state at `offset`, or `nil` at or past the longer file's EOF.
    public func state(at offset: UInt64) -> DiffBlock.Kind? {
        guard !blocks.isEmpty else { return nil }
        var lo = 0
        var hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let block = blocks[mid]
            if offset < block.range.lowerBound {
                hi = mid - 1
            } else if offset >= block.range.upperBound {
                lo = mid + 1
            } else {
                return block.kind
            }
        }
        return nil
    }

    public var differenceBlocks: [DiffBlock] { blocks.filter { $0.kind == .different } }

    /// The blocks intersecting `range`, in order — found by binary search, not by
    /// walking the index.
    ///
    /// Consumers that only care about a window (the minimap's overview computes a
    /// few rows at a time) must not flatten the whole index to get at it:
    /// building `differenceBlocks` on every keystroke was a third of the main
    /// thread on a 16 MB comparison, and the sticking that came with it.
    public func blocks(in range: Range<UInt64>) -> ArraySlice<DiffBlock> {
        guard !blocks.isEmpty, range.lowerBound < range.upperBound else { return [] }
        // The first block whose end is past the range's start.
        var lo = 0
        var hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].range.upperBound <= range.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        let first = lo
        guard first < blocks.count, blocks[first].range.lowerBound < range.upperBound else { return [] }
        // The first block that starts at or after the range's end.
        lo = first
        hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].range.lowerBound < range.upperBound { lo = mid + 1 } else { hi = mid }
        }
        return blocks[first..<lo]
    }
    public var sameBlocks: [DiffBlock] { blocks.filter { $0.kind == .same } }

    /// The first block starting strictly after `offset`.
    public func firstBlock(after offset: UInt64) -> DiffBlock? {
        guard let i = firstBlockStart(after: offset) else { return nil }
        return blocks[i]
    }

    /// The last block ending at or before `offset`.
    public func firstBlock(before offset: UInt64) -> DiffBlock? {
        guard let last = lastBlockEnd(atOrBefore: offset) else { return nil }
        return blocks[last]
    }

    /// The first different block starting strictly after `offset`.
    public func nextDifference(from offset: UInt64) -> DiffBlock? {
        guard let i = firstBlockStart(after: offset) else { return nil }
        if blocks[i].kind == .different { return blocks[i] }
        let j = i + 1
        guard j < blocks.count, blocks[j].kind == .different else { return nil }
        return blocks[j]
    }

    /// The last different block ending at or before `offset`.
    public func previousDifference(from offset: UInt64) -> DiffBlock? {
        guard let last = lastBlockEnd(atOrBefore: offset) else { return nil }
        if blocks[last].kind == .different { return blocks[last] }
        let prev = last - 1
        guard prev >= 0, blocks[prev].kind == .different else { return nil }
        return blocks[prev]
    }

    /// The first same block starting strictly after `offset`.
    public func nextSame(from offset: UInt64) -> DiffBlock? {
        guard let i = firstBlockStart(after: offset) else { return nil }
        if blocks[i].kind == .same { return blocks[i] }
        let j = i + 1
        guard j < blocks.count, blocks[j].kind == .same else { return nil }
        return blocks[j]
    }

    /// The last same block ending at or before `offset`.
    public func previousSame(from offset: UInt64) -> DiffBlock? {
        guard let last = lastBlockEnd(atOrBefore: offset) else { return nil }
        if blocks[last].kind == .same { return blocks[last] }
        let prev = last - 1
        guard prev >= 0, blocks[prev].kind == .same else { return nil }
        return blocks[prev]
    }

    // MARK: - Binary-search anchors

    /// The index of the first block starting strictly after `offset`, or nil
    /// when none does. The blocks are sorted by `lowerBound`, so this is a
    /// binary search — O(log n), not the O(n) a `first(where:)` scan costs.
    ///
    /// The navigation queries used to scan linearly: two very different large
    /// files produce a block per byte (millions of blocks), and every caret
    /// move re-queried all four — drag selection froze once indexing finished.
    private func firstBlockStart(after offset: UInt64) -> Int? {
        var lo = 0
        var hi = blocks.count  // [lo, hi) — first index with lowerBound > offset
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].range.lowerBound <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo < blocks.count ? lo : nil
    }

    /// The index of the last block ending at or before `offset`, or nil when
    /// none does. Blocks are non-overlapping and tiled, so `upperBound` is
    /// strictly increasing; a binary search lands on the first block that ends
    /// after `offset`, and the answer is the block before it.
    private func lastBlockEnd(atOrBefore offset: UInt64) -> Int? {
        var lo = 0
        var hi = blocks.count  // [lo, hi) — first index with upperBound > offset
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].range.upperBound <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let last = lo - 1
        return last >= 0 ? last : nil
    }

    /// Merges adjacent blocks that share a kind and touch, restoring the
    /// maximality invariant.
    static func coalesced(_ blocks: [DiffBlock]) -> [DiffBlock] {
        var result: [DiffBlock] = []
        for block in blocks {
            if let last = result.last, last.kind == block.kind,
               last.range.upperBound == block.range.lowerBound {
                result[result.count - 1] = DiffBlock(
                    kind: last.kind,
                    range: last.range.lowerBound..<block.range.upperBound
                )
            } else {
                result.append(block)
            }
        }
        return result
    }
}
