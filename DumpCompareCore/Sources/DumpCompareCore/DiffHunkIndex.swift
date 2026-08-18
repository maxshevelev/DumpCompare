import Foundation

/// Difference *hunks* — the unit Next/Previous Difference steps through
/// (§10.3.1).
///
/// `DiffBlockIndex` is byte-exact: where differing bytes alternate with
/// matching ones (a rewritten NVRAM region, a config area with a few flipped
/// bits) it holds a block per byte, and stepping through those blocks costs one
/// keypress per byte. A hunk merges difference blocks separated by a matching
/// run shorter than `gap`, so one press lands on the next *significant* change.
///
/// The merge is by distance only, never on the 16-byte row grid: row grouping
/// would make the effective threshold depend on where the differing bytes fall
/// inside a row — diffs at 0x00 and 0x1F (30 matching bytes between them) share
/// two adjacent rows and would merge, while diffs at 0x0F and 0x20 (16 matching
/// bytes) are split by a clean row and would not. Distance is phase-independent:
/// the same spacing always groups the same way.
///
/// A hunk's bounds are the first and last *differing* byte it covers. The
/// matching runs it swallowed sit inside it, so navigation never lands on a byte
/// that isn't a difference.
///
/// This is a navigation layer only. Highlighting stays per byte, and the block
/// index keeps its byte-exact semantics (§8.1) — the hunks are derived from it.
public struct DiffHunkIndex: Equatable, Sendable {
    /// The shortest matching run that still separates two hunks: a run of
    /// `gap - 1` bytes or fewer is swallowed. `gap <= 1` merges nothing (blocks
    /// always have at least one matching byte between them), which reproduces
    /// byte-exact block navigation.
    public let gap: UInt64
    /// The comparison's extent — the longer file's length (§8.1).
    public let extent: UInt64
    /// The merged difference hunks: sorted, non-overlapping, each bounded by
    /// differing bytes, separated by matching runs of at least `gap` bytes.
    public let hunks: [Range<UInt64>]

    /// Groups an index's difference blocks. One linear pass over the blocks.
    public init(index: DiffBlockIndex, gap: UInt64) {
        var merged: [Range<UInt64>] = []
        for block in index.blocks where block.kind == .different {
            if let last = merged.last, block.range.lowerBound - last.upperBound < gap {
                merged[merged.count - 1] = last.lowerBound..<block.range.upperBound
            } else {
                merged.append(block.range)
            }
        }
        self.init(hunks: merged, gap: gap, extent: index.maxSize)
    }

    /// Direct form, for tests and callers that already hold merged hunks.
    public init(hunks: [Range<UInt64>], gap: UInt64, extent: UInt64) {
        self.hunks = hunks
        self.gap = gap
        self.extent = extent
    }

    public var isEmpty: Bool { hunks.isEmpty }

    // MARK: - Navigation (§10.3.1)

    /// The first hunk starting strictly after `offset`. A caret inside a hunk —
    /// including inside a matching run the hunk swallowed — therefore lands on
    /// the *next* hunk rather than on a fragment of the current one.
    public func nextDifference(from offset: UInt64) -> Range<UInt64>? {
        guard let i = firstHunkStart(after: offset) else { return nil }
        return hunks[i]
    }

    /// The last hunk ending at or before `offset`.
    public func previousDifference(from offset: UInt64) -> Range<UInt64>? {
        guard let i = lastHunkEnd(atOrBefore: offset) else { return nil }
        return hunks[i]
    }

    /// The first matching run starting strictly after `offset`.
    ///
    /// The runs that count are the ones *between* hunks (and the file's leading
    /// and trailing runs) — the short runs a hunk swallowed are inside a
    /// difference and are not navigation targets, or Next Same Block would land
    /// in the middle of what Next Difference treats as one change.
    public func nextSame(from offset: UInt64) -> Range<UInt64>? {
        // Every candidate run starts where a hunk ends; the leading run starts
        // at 0, which is never strictly after `offset`.
        guard let i = firstHunkEnd(after: offset) else { return nil }
        return matchingRun(afterHunkAt: i)
    }

    /// The last matching run ending at or before `offset`.
    public func previousSame(from offset: UInt64) -> Range<UInt64>? {
        guard !hunks.isEmpty else {
            // No differences at all: the extent is one matching run.
            return extent > 0 && extent <= offset ? 0..<extent : nil
        }
        // The trailing run is the only one that ends at the extent, so it wins
        // whenever the caret sits at or past EOF.
        if let last = hunks.last, last.upperBound < extent, extent <= offset {
            return last.upperBound..<extent
        }
        // Otherwise the answer is the run in front of the last hunk that starts
        // at or before `offset`: that run ends at the hunk's start, and every
        // later run ends after `offset`.
        guard let i = lastHunkStart(atOrBefore: offset) else { return nil }
        return matchingRun(afterHunkAt: i - 1)
    }

    /// The matching run between hunk `i` and hunk `i + 1`; `i == -1` asks for
    /// the run before the first hunk and `i == hunks.count - 1` for the one
    /// after the last. Nil when the hunks touch (or reach the extent) there.
    ///
    /// The leading and trailing runs can be shorter than `gap` — nothing was
    /// merged across them, they are simply what is left over at the file's
    /// edges, exactly as `DiffBlockIndex` reports them.
    private func matchingRun(afterHunkAt i: Int) -> Range<UInt64>? {
        let start = i < 0 ? 0 : hunks[i].upperBound
        let end = i + 1 < hunks.count ? hunks[i + 1].lowerBound : extent
        return start < end ? start..<end : nil
    }

    // MARK: - Binary-search anchors

    /// The index of the first hunk with `lowerBound > offset`.
    private func firstHunkStart(after offset: UInt64) -> Int? {
        var lo = 0
        var hi = hunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if hunks[mid].lowerBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < hunks.count ? lo : nil
    }

    /// The index of the last hunk with `lowerBound <= offset`.
    private func lastHunkStart(atOrBefore offset: UInt64) -> Int? {
        guard let first = firstHunkStart(after: offset) else {
            return hunks.isEmpty ? nil : hunks.count - 1
        }
        return first > 0 ? first - 1 : nil
    }

    /// The index of the first hunk with `upperBound > offset`.
    private func firstHunkEnd(after offset: UInt64) -> Int? {
        var lo = 0
        var hi = hunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if hunks[mid].upperBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < hunks.count ? lo : nil
    }

    /// The index of the last hunk with `upperBound <= offset`.
    private func lastHunkEnd(atOrBefore offset: UInt64) -> Int? {
        guard let first = firstHunkEnd(after: offset) else {
            return hunks.isEmpty ? nil : hunks.count - 1
        }
        return first > 0 ? first - 1 : nil
    }
}
