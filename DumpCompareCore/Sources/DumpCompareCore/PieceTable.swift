import Foundation

/// The logical content of an edited file as a list of pieces, each naming a
/// range of one of two immutable sources (see `Design/PIECE_TABLE_PLAN.md`).
///
/// This is the arithmetic only — no bytes, no I/O, no locks. `EditOverlayStorage`
/// owns the two sources (the file the document was opened from, and an
/// append-only buffer of bytes the user typed or pasted) and asks the table which
/// source segments cover a window it has been asked to read.
///
/// Editing a piece list is O(pieces), never O(bytes): an insert splits one piece
/// and adds another, a delete drops or trims a few. That is the whole point —
/// the previous design rewrote the entire file into a temp file per edit, which
/// cost the same 25 ms per typed byte whether the byte landed at the start of an
/// 8 MB dump or at its end.
struct PieceTable: Equatable {
    /// Which immutable source a piece reads from.
    enum Source: Equatable {
        /// The storage the document was opened from.
        case base
        /// The append-only buffer of bytes added by editing.
        case added
    }

    struct Piece: Equatable {
        var source: Source
        /// Offset within the source.
        var start: UInt64
        var length: UInt64

        var end: UInt64 { start + length }
    }

    /// A slice of one source, in that source's own coordinates.
    struct Segment: Equatable {
        var source: Source
        var range: Range<UInt64>
    }

    private(set) var pieces: [Piece] = []
    /// Prefix sums: `starts[i]` is the logical offset piece `i` begins at, and
    /// the last element is the total size. Rebuilt on every mutation, which is
    /// what keeps `segments(in:)` a binary search rather than a walk.
    private var starts: [UInt64] = [0]

    /// A table holding one piece: the whole base, unedited.
    init(baseSize: UInt64) {
        if baseSize > 0 {
            pieces = [Piece(source: .base, start: 0, length: baseSize)]
        }
        rebuildStarts()
    }

    var size: UInt64 { starts.last ?? 0 }
    var pieceCount: Int { pieces.count }

    // MARK: - Reading

    /// The source segments covering `range`, in logical order. Clamped to the
    /// table's size; an empty or out-of-range window yields nothing.
    func segments(in range: Range<UInt64>) -> [Segment] {
        let lower = min(range.lowerBound, size)
        let upper = min(range.upperBound, size)
        guard lower < upper else { return [] }

        var result: [Segment] = []
        var index = pieceIndex(containing: lower)
        var position = lower
        while position < upper, index < pieces.count {
            let piece = pieces[index]
            let pieceStart = starts[index]
            let offsetInPiece = position - pieceStart
            let take = min(piece.length - offsetInPiece, upper - position)
            if take > 0 {
                let from = piece.start + offsetInPiece
                result.append(Segment(source: piece.source, range: from..<(from + take)))
                position += take
            }
            index += 1
        }
        return result
    }

    /// The logical ranges backed by the added buffer, merged where adjacent.
    ///
    /// While no length-changing edit has happened, a logical offset is still the
    /// original file's offset, so these are exactly the ranges an in-place save
    /// has to patch (§5.2). After a shift they are no longer file offsets, which
    /// is why the storage stops offering the in-place path at all.
    var addedRanges: [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        for (index, piece) in pieces.enumerated() where piece.source == .added {
            let range = starts[index]..<(starts[index] + piece.length)
            if let last = result.last, last.upperBound == range.lowerBound {
                result[result.count - 1] = last.lowerBound..<range.upperBound
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - Editing

    /// Inserts a slice of the added buffer at `offset`, shifting what follows.
    ///
    /// A run of typing lands as one piece, not one per keystroke: when the new
    /// bytes continue the added piece that ends exactly at `offset`, that piece
    /// simply grows.
    mutating func insert(at offset: UInt64, addedRange: Range<UInt64>) {
        guard !addedRange.isEmpty else { return }
        let at = min(offset, size)

        if let index = pieceEnding(at: at),
           pieces[index].source == .added,
           pieces[index].end == addedRange.lowerBound {
            pieces[index].length += UInt64(addedRange.count)
            rebuildStarts()
            return
        }

        let piece = Piece(source: .added, start: addedRange.lowerBound,
                          length: UInt64(addedRange.count))
        splitPiece(at: at)
        pieces.insert(piece, at: insertionIndex(for: at))
        rebuildStarts()
    }

    /// Removes `range`, shifting what follows left.
    mutating func delete(_ range: Range<UInt64>) {
        let lower = min(range.lowerBound, size)
        let upper = min(range.upperBound, size)
        guard lower < upper else { return }
        splitPiece(at: lower)
        splitPiece(at: upper)
        let first = insertionIndex(for: lower)
        let last = insertionIndex(for: upper)
        pieces.removeSubrange(first..<last)
        rebuildStarts()
    }

    /// Replaces `range` with a slice of the added buffer — an overwrite. The
    /// lengths need not match: a longer replacement grows the file, which is how
    /// a write past EOF extends it.
    mutating func replace(_ range: Range<UInt64>, with addedRange: Range<UInt64>) {
        delete(range)
        insert(at: range.lowerBound, addedRange: addedRange)
    }

    // MARK: - Internals

    private mutating func rebuildStarts() {
        starts = [0]
        starts.reserveCapacity(pieces.count + 1)
        var total: UInt64 = 0
        for piece in pieces {
            total += piece.length
            starts.append(total)
        }
    }

    /// The index of the piece containing `offset` (the last piece for `offset`
    /// at the very end), by binary search over the prefix sums.
    private func pieceIndex(containing offset: UInt64) -> Int {
        guard !pieces.isEmpty else { return 0 }
        var low = 0
        var high = pieces.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The index a piece starting at `offset` would take — `pieces.count` at the
    /// end. Valid only on a boundary, so callers split first.
    private func insertionIndex(for offset: UInt64) -> Int {
        if offset >= size { return pieces.count }
        var low = 0
        var high = pieces.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The index of the piece that ends exactly at `offset`, if any.
    private func pieceEnding(at offset: UInt64) -> Int? {
        guard offset > 0, offset <= size else { return nil }
        let index = insertionIndex(for: offset) - 1
        guard index >= 0, index < pieces.count, starts[index + 1] == offset else { return nil }
        return index
    }

    /// Splits the piece straddling `offset` into two, so `offset` becomes a
    /// piece boundary. A no-op when it already is one.
    private mutating func splitPiece(at offset: UInt64) {
        guard offset > 0, offset < size else { return }
        let index = pieceIndex(containing: offset)
        let pieceStart = starts[index]
        guard offset > pieceStart else { return }   // already a boundary
        let piece = pieces[index]
        let head = offset - pieceStart
        pieces[index] = Piece(source: piece.source, start: piece.start, length: head)
        pieces.insert(Piece(source: piece.source,
                            start: piece.start + head,
                            length: piece.length - head),
                      at: index + 1)
        rebuildStarts()
    }
}
