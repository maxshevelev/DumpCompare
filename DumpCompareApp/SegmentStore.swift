import Foundation
import DumpCompareCore

/// One piece of the pane's content: a contiguous, non-overlapping stretch that,
/// with its neighbours, covers the whole file (§21). A segmentation is a
/// *partition* — an ordered list of cut offsets — so gaps and overlaps are
/// impossible by construction rather than by validation. N pieces are N−1 cuts.
///
/// The label is positional (S0, S1, … in file order) and renumbers whenever a
/// cut is added or removed; the name is the user's and survives renumbering.
struct Segment: Equatable {
    /// Positional label: S0, S1, … in file order. Derived, never stored.
    let index: Int
    /// The piece's half-open byte range `[start, end)`.
    let range: Range<UInt64>
    /// A name for the piece; empty means "no name" (still shown as S<i>, never
    /// blank). Survives renumbering.
    var name: String
}

/// The pane's segment partition: an ordered list of cut offsets with a name for
/// each piece. One instance per `PaneViewModel`, beside `document` — segments
/// describe one file's make-up, not the window's (the opposite of bookmarks,
/// §20, which are the window's and never move under an edit).
///
/// The store keeps **cuts, not ranges**: a partition is its boundaries, so
/// `segments` derives the ranges and the labels. A cut travels with the content
/// (§21.2) — an insert or a delete moves the cuts after it — the opposite rule
/// to a bookmark, a mark the user chose and that must stay put.
///
/// `@MainActor`-confined (UI on MainActor) but AppKit-free and byte-free, so the
/// arithmetic is unit-testable in the app suite.
@MainActor
final class SegmentStore {
    /// A value copy of the partition, for the undo/redo snapshot stack. Cheap:
    /// a handful of numbers and short strings, no bytes.
    struct Snapshot: Equatable {
        var contentSize: UInt64
        var cuts: [UInt64]
        var names: [String]
    }

    /// The file's current size in bytes.
    private(set) var contentSize: UInt64
    /// The cut offsets, kept sorted, each strictly inside `(0, contentSize)`.
    private(set) var cuts: [UInt64] = []
    /// One name per piece; `count == cuts.count + 1`.
    private(set) var names: [String]

    /// Fired after any change with the offset range whose drawing changed, so a
    /// consumer repaints exactly what moved (wired to the view in Stage 2).
    var onChange: ((Range<UInt64>) -> Void)?

    /// One piece — the whole file — named `name`.
    init(size: UInt64, name: String) {
        self.contentSize = size
        self.names = [name]
    }

    // MARK: - Derived view

    /// The pieces in file order, with derived indices and ranges.
    var segments: [Segment] {
        let bounds = Self.bounds(cuts: cuts, contentSize: contentSize)
        return (0..<names.count).map { i in
            Segment(index: i, range: bounds[i]..<bounds[i + 1], name: names[i])
        }
    }

    /// The piece containing `offset` (half-open at both ends: a cut belongs to
    /// the piece that *starts* there), or nil past the end of the file.
    func segment(containing offset: UInt64) -> Segment? {
        guard offset < contentSize else { return nil }
        let index = cuts.filter { $0 <= offset }.count
        let start = index == 0 ? 0 : cuts[index - 1]
        let end = index < cuts.count ? cuts[index] : contentSize
        return Segment(index: index, range: start..<end, name: names[index])
    }

    // MARK: - Editing the partition

    /// Adds a cut at `offset`, splitting the piece that contains it. The earlier
    /// piece keeps its name; the new piece starts unnamed. Refused — and `false`
    /// returned — when `offset` is 0, at EOF, or already a cut: every piece must
    /// be non-empty (§21 edge cases).
    @discardableResult
    func addCut(at offset: UInt64) -> Bool {
        guard offset > 0, offset < contentSize, !cuts.contains(offset) else { return false }
        cuts.append(offset)
        cuts.sort()
        // The cut splits the piece at `index`; the new (later) piece is unnamed.
        let index = cuts.firstIndex(of: offset)!
        names.insert("", at: index + 1)
        onChange?(0..<contentSize)
        return true
    }

    /// Removes the cut at `offset`, merging the two pieces it separated into the
    /// earlier one, which keeps its name. The bytes are untouched — removing a
    /// cut changes how the file is read, not the file. Returns whether there was
    /// a cut there to remove.
    @discardableResult
    func removeCut(at offset: UInt64) -> Bool {
        guard let index = cuts.firstIndex(of: offset) else { return false }
        cuts.remove(at: index)
        // Drop the later piece's name; the earlier piece keeps its own.
        names.remove(at: index + 1)
        onChange?(0..<contentSize)
        return true
    }

    /// Moves the cut at `from` to `offset`, keeping the names of the pieces on
    /// either side (only the boundary travels). Returns the new offset, or nil
    /// when there was no cut at `from` or the move was refused (0, EOF, or onto
    /// another cut).
    @discardableResult
    func moveCut(from: UInt64, to offset: UInt64) -> UInt64? {
        guard offset > 0, offset < contentSize, !cuts.contains(offset),
              cuts.contains(from), from != offset else { return nil }
        // The move is one logical change; suppress the intermediate notification
        // so consumers see a single update for the whole move.
        let suppress = onChange
        onChange = nil
        defer { onChange = suppress }
        removeCut(at: from)
        addCut(at: offset)
        onChange?(0..<contentSize)
        return offset
    }

    /// Renames the piece at `index`. An empty name unnames it (it goes back to
    /// showing its label). Out-of-range indices are ignored.
    func rename(_ index: Int, to name: String) {
        guard names.indices.contains(index) else { return }
        names[index] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onChange?(0..<contentSize)
    }

    // MARK: - Following the content (§21.2)

    /// Applies the net edit a transaction produced, moving the cuts with the
    /// content. Called from `PaneViewModel` with the same `DiffEdit` the
    /// comparison index and the minimap consume (§8.3), and `newSize` the file's
    /// size after the edit.
    ///
    /// - `.overwrite` changes bytes without shifting offsets: nothing moves (the
    ///   size may have grown, e.g. a paste past EOF).
    /// - `.insert(at:length:)` shifts the cuts strictly after `at` by `+length`;
    ///   a cut exactly at `at` stays, so the inserted bytes join the piece that
    ///   *starts* there.
    /// - `.delete(range:)` drops the cuts the deletion removes (their pieces
    ///   merge into the one that starts before the deletion, keeping its name),
    ///   shifts the cuts after it by `−length`, and drops any piece left empty.
    func apply(_ edit: DiffEdit, newSize: UInt64) {
        switch edit {
        case .overwrite:
            // Offsets are preserved; only the size may have grown. Every cut is
            // still < newSize, so they stay where they are.
            contentSize = newSize

        case .insert(let at, let length):
            for i in cuts.indices where cuts[i] > at {
                cuts[i] += length
            }
            contentSize = newSize
            onChange?(0..<newSize)

        case .delete(let range):
            applyDelete(range, newSize: newSize)
        }
    }

    /// The delete half of `apply`: recompute the cuts and the names of the
    /// pieces that survive removing `[lo, hi)`.
    ///
    /// A cut's fate is decided by where it sits relative to the deletion
    /// (§21.2): at or before `lo` it stays put; strictly inside `(lo, hi)` it is
    /// swallowed — the two pieces it separated merge into the one that starts
    /// before the deletion, which keeps its name; at or after `hi` it shifts
    /// left by the deleted length. A piece left with no bytes is dropped with
    /// its name, and the labels renumber.
    private func applyDelete(_ range: Range<UInt64>, newSize: UInt64) {
        let lo = range.lowerBound
        let hi = range.upperBound
        let length = hi - lo
        guard length > 0 else { return }

        // The old piece boundaries, [0, cuts…, contentSize].
        let bounds = Self.bounds(cuts: cuts, contentSize: contentSize)

        // The surviving pieces, in order: each is the run of old pieces whose
        // bytes survive, and the name it keeps is the first of those pieces
        // that opens before the deletion — the "one that starts before the
        // deletion" the merged run is named for.
        var newCuts: [UInt64] = []
        var newNames: [String] = []

        var i = 0
        while i < names.count {
            let s = bounds[i]
            // The run of consecutive pieces the deletion swallows the seams
            // between: it starts at piece `i` and extends over every piece that
            // ends strictly inside the deletion (its cut is swallowed).
            var j = i
            while j + 1 < bounds.count, bounds[j + 1] < hi, bounds[j + 1] > lo {
                j += 1
            }
            let e = bounds[j + 1]
            // The run's surviving bytes, in new-file coordinates: the part
            // before `lo` (unchanged) and the part from `hi` on (shifted left).
            let prefixEnd = min(e, lo)
            let suffixStart = max(s, hi)
            let hasPrefix = s < prefixEnd
            let hasSuffix = suffixStart < e
            guard hasPrefix || hasSuffix else { i = j + 1; continue }   // emptied: dropped

            // The run opens where its earliest surviving byte lands.
            let newStart = hasPrefix ? s : suffixStart - length
            // The name it keeps: the first piece in the run that opens before
            // the deletion (a run that begins inside the deletion keeps the
            // name of the piece that opens at its shifted start).
            let nameIndex = (0...j).first { bounds[$0] < lo } ?? j
            newNames.append(names[nameIndex])
            if newStart > 0 { newCuts.append(newStart) }
            i = j + 1
        }

        cuts = newCuts
        names = newNames
        contentSize = newSize
        onChange?(0..<newSize)
    }

    // MARK: - Reset & snapshots

    /// Resets to one piece — the whole file — named `name`. Called on open,
    /// close, and revert.
    func reset(size: UInt64, name: String) {
        contentSize = size
        cuts = []
        names = [name]
        onChange?(0..<size)
    }

    /// A value copy of the partition, for the undo snapshot stack.
    func snapshot() -> Snapshot {
        Snapshot(contentSize: contentSize, cuts: cuts, names: names)
    }

    /// Restores a snapshot taken by `snapshot()`.
    func restore(_ snapshot: Snapshot) {
        contentSize = snapshot.contentSize
        cuts = snapshot.cuts
        names = snapshot.names
        onChange?(0..<contentSize)
    }

    // MARK: - Internals

    /// The piece boundaries for a cut list: `[0, cuts…, contentSize]`.
    private static func bounds(cuts: [UInt64], contentSize: UInt64) -> [UInt64] {
        var result = [UInt64](arrayLiteral: 0)
        result.append(contentsOf: cuts)
        result.append(contentSize)
        return result
    }
}
