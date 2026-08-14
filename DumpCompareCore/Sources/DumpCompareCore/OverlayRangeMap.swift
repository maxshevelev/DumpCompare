import Foundation

/// A sparse, coalesced map of overwritten byte ranges over an immutable base.
///
/// Entries are kept in ascending order, non-overlapping, and adjacent entries are
/// merged. The map only ever grows in place: ranges never shift, because any
/// length-changing edit re-creates the base (see `EditOverlayStorage`).
struct OverlayRangeMap {
    private(set) var entries: [(range: Range<UInt64>, bytes: [UInt8])] = []

    var isEmpty: Bool { entries.isEmpty }

    var changedRanges: [Range<UInt64>] { entries.map { $0.range } }

    var totalByteCount: Int { entries.reduce(0) { $0 + $1.bytes.count } }

    /// Overwrites `bytes` starting at `offset`, replacing whatever the overlay
    /// previously covered across that span and merging adjacent entries.
    mutating func write(_ bytes: [UInt8], at offset: UInt64) {
        guard !bytes.isEmpty else { return }
        let newRange = offset ..< (offset + UInt64(bytes.count))

        var kept: [(range: Range<UInt64>, bytes: [UInt8])] = []
        var affected: [(range: Range<UInt64>, bytes: [UInt8])] = []
        for entry in entries {
            // Touching counts as affected so adjacent entries merge.
            if entry.range.lowerBound <= newRange.upperBound,
               entry.range.upperBound >= newRange.lowerBound {
                affected.append(entry)
            } else {
                kept.append(entry)
            }
        }

        var result: [(range: Range<UInt64>, bytes: [UInt8])] = []
        for entry in affected {
            // Left side surviving the new write.
            let leftEnd = min(entry.range.upperBound, newRange.lowerBound)
            if leftEnd > entry.range.lowerBound {
                let n = Int(leftEnd - entry.range.lowerBound)
                result.append((entry.range.lowerBound..<leftEnd, Array(entry.bytes.prefix(n))))
            }
            // Right side surviving the new write.
            let rightStart = max(entry.range.lowerBound, newRange.upperBound)
            if rightStart < entry.range.upperBound {
                let start = Int(rightStart - entry.range.lowerBound)
                result.append((rightStart..<entry.range.upperBound, Array(entry.bytes.suffix(from: start))))
            }
        }
        result.append((newRange, bytes))
        result.append(contentsOf: kept)

        entries = Self.merged(result)
    }

    /// Returns the overlay entries that intersect `range` (partial overlaps included).
    func entriesIntersecting(_ range: Range<UInt64>) -> [(range: Range<UInt64>, bytes: [UInt8])] {
        entries.filter { $0.range.lowerBound < range.upperBound && $0.range.upperBound > range.lowerBound }
    }

    /// Sorts by lower bound and merges adjacent entries back into one.
    private static func merged(
        _ input: [(range: Range<UInt64>, bytes: [UInt8])]
    ) -> [(range: Range<UInt64>, bytes: [UInt8])] {
        var out: [(range: Range<UInt64>, bytes: [UInt8])] = []
        for entry in input.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = out.last, last.range.upperBound == entry.range.lowerBound {
                out[out.count - 1].bytes += entry.bytes
                out[out.count - 1].range = last.range.lowerBound..<entry.range.upperBound
            } else {
                out.append(entry)
            }
        }
        return out
    }
}
