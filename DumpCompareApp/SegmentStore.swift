import Foundation
import DumpCompareCore

/// One piece of the pane's content: a contiguous, non-overlapping stretch that,
/// with its neighbours, covers the whole file (§21). A segmentation is a
/// *partition* — an ordered list of pieces — so gaps and overlaps are impossible
/// by construction rather than by validation.
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
    let name: String

    /// Built only by the partition that owns it: a `Segment` is a piece of one
    /// specific `Segmentation`, so it cannot be fabricated with boundaries no
    /// partition actually holds.
    fileprivate init(index: Int, range: Range<UInt64>, name: String) {
        self.index = index
        self.range = range
        self.name = name
    }
}

/// One piece as the partition stores it: where it opens and what it is called.
/// The partition is an ordered list of these; a piece's end is the next piece's
/// start (or the file's end for the last), so the list *is* the partition and
/// there is no second array to keep in step with it.
struct Piece: Equatable {
    /// The piece's opening offset. `pieces[0].start == 0`; the rest are the cuts.
    var start: UInt64
    /// The user's name for the piece; empty means "no name".
    var name: String
}

/// The pane's segment partition: the file's size and its pieces, an immutable,
/// self-consistent value. This is the unit of "a view of the partition at one
/// instant" — a snapshot taken for undo is one of these, and `store.current` is
/// one of these — so two pieces read from the same `Segmentation` rest on the
/// same boundaries by construction.
///
/// `pieces` is a Swift array, so a copy of a `Segmentation` shares its buffer
/// until one side mutates it (copy-on-write): `store.current` and every
/// outstanding snapshot are O(1) value copies, and the one real copy happens on
/// the rare write, and only while a snapshot is still held.
///
/// One instance per `PaneViewModel`, beside `document` — segments describe one
/// file's make-up, not the window's (the opposite of bookmarks, §20, which are
/// the window's and never move under an edit). A cut travels with the content
/// (§21.2) — an insert or a delete moves the pieces after it — the opposite
/// rule to a bookmark, a mark the user chose and that must stay put.
struct Segmentation: Equatable {
    /// The file's current size in bytes.
    var contentSize: UInt64
    /// The pieces in file order. `pieces[0].start == 0`; the list is never empty
    /// (a file is always at least the whole-file piece) and sorted by start.
    var pieces: [Piece]

    init(contentSize: UInt64, pieces: [Piece]) {
        self.contentSize = contentSize
        self.pieces = pieces
    }

    // MARK: - Derived view

    /// The cut offsets — every piece start except the first. A cut is a piece's
    /// opening, so this is the partition's boundaries with the file start
    /// dropped.
    var cuts: [UInt64] { pieces.dropFirst().map(\.start) }

    /// The pieces in file order, with derived indices and ranges.
    var segments: [Segment] {
        let ends = pieces.dropFirst().map(\.start) + [contentSize]
        return pieces.enumerated().map { i, piece in
            Segment(index: i, range: piece.start..<ends[i], name: piece.name)
        }
    }

    /// The piece containing `offset` (half-open at both ends: a cut belongs to
    /// the piece that *starts* there), or nil past the end of the file.
    func segment(containing offset: UInt64) -> Segment? {
        guard let index = pieceIndex(containing: offset) else { return nil }
        let end = index + 1 < pieces.count ? pieces[index + 1].start : contentSize
        return Segment(index: index, range: pieces[index].start..<end, name: pieces[index].name)
    }

    /// The index of the piece whose range contains `offset` (the last piece that
    /// opens at or before it), or nil past the end of the file.
    func pieceIndex(containing offset: UInt64) -> Int? {
        guard offset < contentSize else { return nil }
        for i in pieces.indices.reversed() where pieces[i].start <= offset {
            return i
        }
        return nil
    }

    // MARK: - Editing the partition

    /// Adds a cut at `offset`, splitting the piece that contains it. The earlier
    /// piece keeps its name; the new piece starts unnamed. Returns the offset
    /// range whose drawing changed (from the cut to the end), or nil when
    /// refused: `offset` at 0, at EOF, or already a cut — every piece must stay
    /// non-empty (§21 edge cases).
    @discardableResult
    mutating func addCut(at offset: UInt64) -> Range<UInt64>? {
        guard offset > 0, offset < contentSize,
              !pieces.contains(where: { $0.start == offset }),
              let index = pieceIndex(containing: offset) else { return nil }
        // The cut opens a new piece at `offset`; the later piece renumbers.
        pieces.insert(Piece(start: offset, name: ""), at: index + 1)
        return offset..<contentSize
    }

    /// Removes the cut at `offset`, merging the two pieces it separated into the
    /// earlier one, which keeps its name. The bytes are untouched — removing a
    /// cut changes how the file is read, not the file. Returns the offset range
    /// whose drawing changed (from the removed cut to the end), or nil when there
    /// was no cut there.
    @discardableResult
    mutating func removeCut(at offset: UInt64) -> Range<UInt64>? {
        guard let index = pieces.firstIndex(where: { $0.start == offset }), index > 0
        else { return nil }
        pieces.remove(at: index)
        return offset..<contentSize
    }

    /// Removes the piece at `index`, merging its bytes into a neighbour and
    /// keeping that neighbour's name (§21.3): the piece above absorbs it when
    /// `index` is not 0; the piece below absorbs it when it is 0, reopening at
    /// the file start and renumbering to S0 — what was S1 becomes S0. Returns
    /// the offset range whose drawing changed (from the removed piece's start to
    /// the end), or nil when there is only one piece — no neighbour to merge
    /// into.
    @discardableResult
    mutating func removePiece(at index: Int) -> Range<UInt64>? {
        guard pieces.count > 1, pieces.indices.contains(index) else { return nil }
        let removedStart = pieces[index].start
        if index == 0 {
            // The piece below absorbs S0 and takes its place: it reopens at 0
            // and keeps its own name, so what was S1 is now S0.
            pieces[1].start = 0
            pieces.removeFirst()
        } else {
            // The piece above absorbs it and keeps its name; the removed piece
            // is simply dropped from the partition.
            pieces.remove(at: index)
        }
        return removedStart..<contentSize
    }

    /// Moves the cut at `from` to `offset`, sliding the boundary between the two
    /// pieces it separates (§21.2). The cut may only move within the interval it
    /// currently bounds — strictly between the neighbouring cuts (or the file's
    /// end) — so it never jumps over another cut: the partition's structure is
    /// preserved, and the piece that opened at `from` keeps its name, which
    /// travels with the boundary. Returns the whole file's range (the colour of
    /// every piece at and after `from` can change), or nil when there was no cut
    /// at `from` or the move was refused (onto a neighbouring cut, or past one).
    @discardableResult
    mutating func moveCut(from: UInt64, to offset: UInt64) -> Range<UInt64>? {
        guard from != offset,
              let i = pieces.firstIndex(where: { $0.start == from }), i >= 1
        else { return nil }
        // The cut at `from` opens piece `i`; the interval it bounds is
        // (the previous cut, the next cut or the file's end). Moving inside it
        // keeps the pieces sorted and non-empty, and drops no name.
        let lower = pieces[i - 1].start
        let upper = i + 1 < pieces.count ? pieces[i + 1].start : contentSize
        guard offset > lower, offset < upper else { return nil }
        pieces[i].start = offset
        return 0..<contentSize
    }

    /// Renames the piece at `index`. An empty name unnames it (it goes back to
    /// showing its label). Out-of-range indices are ignored. A name never
    /// changes the tint — the colour is by position, not name — so there is no
    /// drawing to repaint.
    mutating func rename(_ index: Int, to name: String) {
        guard pieces.indices.contains(index) else { return }
        pieces[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies the net edit a transaction produced, moving the pieces with the
    /// content (§21.2). Returns the offset range whose drawing changed, or nil
    /// when no piece boundary moved — the content edit repaints the bytes on its
    /// own, so the partition only has to repaint when a cut actually shifted.
    ///
    /// - `.overwrite` changes bytes without shifting offsets: nothing moves (the
    ///   size may have grown, e.g. a paste past EOF).
    /// - `.insert(at:length:)` shifts the pieces strictly after `at` by
    ///   `+length`; a piece exactly at `at` stays, so the inserted bytes join
    ///   the piece that *starts* there.
    /// - `.delete(range:)` drops the pieces the deletion empties, merges the
    ///   pieces it swallows the seams between (into the one that starts before
    ///   the deletion, keeping its name), and shifts the rest left.
    @discardableResult
    mutating func apply(_ edit: DiffEdit, newSize: UInt64) -> Range<UInt64>? {
        switch edit {
        case .overwrite:
            // Offsets are preserved; only the size may have grown. Every piece
            // start is still < newSize, so they stay where they are.
            contentSize = newSize
            return nil

        case .insert(let at, let length):
            // Only the pieces strictly after `at` shift; when none do (a file
            // with no cut past the insert) the boundaries are untouched, so the
            // content edit's own repaint is enough and nothing is returned.
            var moved = false
            for i in pieces.indices where pieces[i].start > at {
                pieces[i].start += length
                moved = true
            }
            contentSize = newSize
            return moved ? 0..<newSize : nil

        case .delete(let range):
            return applyDelete(range, newSize: newSize)
        }
    }

    /// The delete half of `apply`: recompute the pieces that survive removing
    /// `[lo, hi)`.
    ///
    /// A piece's fate is decided by where it sits relative to the deletion
    /// (§21.2): a seam strictly inside `(lo, hi)` is swallowed — the pieces on
    /// either side merge into the one that starts before the deletion, which
    /// keeps its name; a piece left with no bytes is dropped with its name, and
    /// the labels renumber. The surviving pieces are rebuilt in order, each
    /// opening where its earliest surviving byte lands.
    private mutating func applyDelete(_ range: Range<UInt64>, newSize: UInt64) -> Range<UInt64>? {
        let lo = range.lowerBound
        let hi = range.upperBound
        let length = hi - lo
        guard length > 0 else { return nil }

        // The old piece boundaries, [pieces.map(\.start) + [contentSize]].
        let bounds = pieces.map(\.start) + [contentSize]
        // The starts before the delete, to tell afterwards whether any boundary
        // actually moved (a delete that leaves every cut where it was repaints
        // nothing — the content edit already covers the bytes).
        let oldStarts = pieces.map(\.start)

        var newPieces: [Piece] = []

        var i = 0
        while i < pieces.count {
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
            newPieces.append(Piece(start: newStart, name: pieces[nameIndex].name))
            i = j + 1
        }

        // A file is always at least the whole-file piece, even when the delete
        // emptied it: keep the partition non-empty.
        if newPieces.isEmpty {
            newPieces = [Piece(start: 0, name: pieces[0].name)]
        }
        pieces = newPieces
        contentSize = newSize
        // Repaint only when a boundary moved: a delete in a file with no cuts
        // (or one past every cut) leaves the starts where they were, so the
        // content edit's own repaint is enough.
        return newPieces.map(\.start) == oldStarts ? nil : 0..<newSize
    }

    // MARK: - Reset

    /// Resets to one piece — the whole file — named `name`.
    mutating func reset(size: UInt64, name: String) {
        contentSize = size
        pieces = [Piece(start: 0, name: name)]
    }
}

/// The pane's segment partition, held mutably. The store owns a `current`
/// `Segmentation` and edits it in place; a snapshot is a value copy of it (the
/// undo/redo stack is a stack of these), so a snapshot and `current` share
/// `pieces`'s buffer until one is written — copy-on-write makes the read path
/// O(1) and the copy land on the rare write.
///
/// `@MainActor`-confined (UI on MainActor) but AppKit-free and byte-free, so the
/// arithmetic is unit-testable in the app suite.
@MainActor
final class SegmentStore {
    /// The undo/redo snapshot is the partition value itself.
    typealias Snapshot = Segmentation

    /// The partition as it stands now. A read is an O(1) value copy: it shares
    /// `pieces`'s buffer with any outstanding snapshot until one is written.
    private(set) var current: Segmentation

    /// Fired after any change with the offset range whose drawing changed, so a
    /// consumer repaints exactly what moved (§21.3 invalidation).
    var onChange: ((Range<UInt64>) -> Void)?

    /// One piece — the whole file — named `name`.
    init(size: UInt64, name: String) {
        current = Segmentation(contentSize: size, pieces: [Piece(start: 0, name: name)])
    }

    // MARK: - Reading the current partition

    /// The file's current size in bytes.
    var contentSize: UInt64 { current.contentSize }
    /// The cut offsets (every piece start except the first).
    var cuts: [UInt64] { current.cuts }
    /// The pieces in file order, with derived indices and ranges.
    var segments: [Segment] { current.segments }
    /// The piece containing `offset`, or nil past the end of the file.
    func segment(containing offset: UInt64) -> Segment? { current.segment(containing: offset) }

    // MARK: - Editing the partition

    /// Adds a cut at `offset`, splitting the piece that contains it. Refused —
    /// and `false` returned — when `offset` is 0, at EOF, or already a cut:
    /// every piece must stay non-empty (§21 edge cases).
    @discardableResult
    func addCut(at offset: UInt64) -> Bool {
        guard let range = current.addCut(at: offset) else { return false }
        onChange?(range)
        return true
    }

    /// Removes the cut at `offset`, merging the two pieces it separated into the
    /// earlier one, which keeps its name. Returns whether there was a cut there
    /// to remove.
    @discardableResult
    func removeCut(at offset: UInt64) -> Bool {
        guard let range = current.removeCut(at: offset) else { return false }
        onChange?(range)
        return true
    }

    /// Removes the piece at `index`, merging its bytes into a neighbour and
    /// keeping that neighbour's name (§21.3). Returns whether there was a piece
    /// to remove (refused when there is only one piece — no neighbour to merge
    /// into).
    @discardableResult
    func removePiece(at index: Int) -> Bool {
        guard let range = current.removePiece(at: index) else { return false }
        onChange?(range)
        return true
    }

    /// Moves the cut at `from` to `offset`, sliding the boundary between the two
    /// pieces it separates. The cut may only move within the interval it
    /// currently bounds, so it never jumps over another cut and the piece that
    /// opened at `from` keeps its name (§21.2). Returns the new offset, or nil
    /// when there was no cut at `from` or the move was refused (onto a
    /// neighbouring cut, or past one).
    @discardableResult
    func moveCut(from: UInt64, to offset: UInt64) -> UInt64? {
        guard let range = current.moveCut(from: from, to: offset) else { return nil }
        onChange?(range)
        return offset
    }

    /// Renames the piece at `index`. A name never changes the tint — the colour
    /// is by position, not name — and the status bar reads the label and range,
    /// not the name, so there is no drawing to repaint and no `onChange` to fire.
    func rename(_ index: Int, to name: String) {
        current.rename(index, to: name)
    }

    /// Applies the net edit a transaction produced, moving the pieces with the
    /// content (§21.2). Called from `PaneViewModel` with the same `DiffEdit` the
    /// comparison index and the minimap consume (§8.3), and `newSize` the file's
    /// size after the edit.
    func apply(_ edit: DiffEdit, newSize: UInt64) {
        if let range = current.apply(edit, newSize: newSize) {
            onChange?(range)
        }
    }

    // MARK: - Reset & snapshots

    /// Resets to one piece — the whole file — named `name`. Called on open,
    /// close, and revert.
    func reset(size: UInt64, name: String) {
        current.reset(size: size, name: name)
        onChange?(0..<size)
    }

    /// A value copy of the partition, for the undo snapshot stack. O(1): it
    /// shares `pieces`'s buffer with `current` until one is written.
    func snapshot() -> Snapshot { current }

    /// Restores a snapshot taken by `snapshot()` — always, including the size —
    /// but invalidates only when the snapshot's pieces differ from the ones the
    /// store already holds. The tints depend only on the piece boundaries, so an
    /// undo that moved no cut (even one that changed the size) leaves them where
    /// they were, and repainting would only duplicate the content edit's own
    /// redraw.
    func restore(_ snapshot: Snapshot) {
        let piecesChanged = current.pieces != snapshot.pieces
        current = snapshot
        guard piecesChanged else { return }
        onChange?(0..<contentSize)
    }
}
