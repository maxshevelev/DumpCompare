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
    public var sameBlocks: [DiffBlock] { blocks.filter { $0.kind == .same } }

    /// The first block starting strictly after `offset`.
    public func firstBlock(after offset: UInt64) -> DiffBlock? {
        blocks.first { $0.range.lowerBound > offset }
    }

    /// The last block ending at or before `offset`.
    public func firstBlock(before offset: UInt64) -> DiffBlock? {
        blocks.last { $0.range.upperBound <= offset }
    }

    /// The first different block starting strictly after `offset`.
    public func nextDifference(from offset: UInt64) -> DiffBlock? {
        blocks.first { $0.kind == .different && $0.range.lowerBound > offset }
    }

    /// The last different block ending at or before `offset`.
    public func previousDifference(from offset: UInt64) -> DiffBlock? {
        blocks.last { $0.kind == .different && $0.range.upperBound <= offset }
    }

    /// The first same block starting strictly after `offset`.
    public func nextSame(from offset: UInt64) -> DiffBlock? {
        blocks.first { $0.kind == .same && $0.range.lowerBound > offset }
    }

    /// The last same block ending at or before `offset`.
    public func previousSame(from offset: UInt64) -> DiffBlock? {
        blocks.last { $0.kind == .same && $0.range.upperBound <= offset }
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
