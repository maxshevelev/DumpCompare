import Foundation

/// The overview's byte↔cell mapping (§19.4.2): which row, and which of that
/// row's 16 cells, a byte offset falls in when `rowCount` pixel rows cover
/// `extent` bytes.
///
/// Pure arithmetic, shared rather than repeated: the density picture, the
/// modified and difference bits, and the search's match bits must land on the
/// same cells, or the map would contradict itself. (It is also the first piece
/// of the `MinimapGeometry` that `MINIMAP_LAYERS_IDEA.md` argues for.)
struct OverviewBinning {
    /// The extent the rows are binned over — the longest open file (§9).
    let extent: UInt64
    let rowCount: Int

    static let columns = Int(MinimapView.bytesPerRow)

    /// The first byte of a row's slice of the file. `row == rowCount` gives the
    /// extent, so a row's slice is `start(ofRow:)..<start(ofRow: row + 1)`.
    func start(ofRow row: Int) -> UInt64 {
        guard rowCount > 0 else { return 0 }
        return extent * UInt64(row) / UInt64(rowCount)
    }

    /// The cells one byte of a row's slice occupies, when the slice is thinner
    /// than the row's 16 cells: the byte is stretched over the cells it covers,
    /// so `index` 0 of a one-byte slice fills the row.
    ///
    /// A row covers fewer bytes than it has cells whenever the file is smaller
    /// than 16 bytes per pixel row — under ~25 KB on a full-height panel — and
    /// covers a *fraction* of a byte once the file is smaller than the panel has
    /// rows. Slicing per cell there gave every cell but the last an empty byte
    /// range: the picture came out a pale field with the whole file collapsed
    /// into a stripe down its right edge (§19.4.2).
    func stretchedColumns(forByteAt index: UInt64, ofSpan span: UInt64) -> ClosedRange<Int> {
        let columns = Self.columns
        let effective = max(span, 1)
        let clamped = min(index, effective - 1)
        let first = Int(clamped * UInt64(columns) / effective)
        let last = Int((clamped + 1) * UInt64(columns) / effective) - 1
        return first...max(first, min(columns - 1, last))
    }

    /// The row a byte offset falls in and the cells it occupies there, or nil
    /// when the offset is past the extent or its row is outside `rows`.
    func cells(of offset: UInt64, within rows: ClosedRange<Int>)
        -> (row: Int, columns: ClosedRange<Int>)? {
        let columns = Self.columns
        guard rowCount > 0, extent > 0, offset < extent else { return nil }
        let row = Int(offset * UInt64(rowCount) / extent)
        guard rows.contains(row) else { return nil }
        let rowStart = start(ofRow: row)
        let span = start(ofRow: row + 1) - rowStart
        guard span >= UInt64(columns) else {
            let index = offset > rowStart ? offset - rowStart : 0
            return (row, stretchedColumns(forByteAt: index, ofSpan: span))
        }
        let column = Int(min(UInt64(columns - 1), (offset - rowStart) * UInt64(columns) / span))
        return (row, column...column)
    }

    /// Sets the bit of every cell a byte range touches, for the rows in `rows`.
    /// `bits` holds one `UInt16` per row of `rows`, indexed from its start —
    /// the shape `OverviewSummary`'s `modified` and `different` masks use, and
    /// the shape the match overlay uses.
    ///
    /// A range spanning whole rows fills them, so a difference or a run of
    /// matches reads as a band rather than as two end marks.
    func mark(_ range: Range<UInt64>, rows: ClosedRange<Int>, into bits: inout [UInt16]) {
        let columns = Self.columns
        let lower = max(range.lowerBound, start(ofRow: rows.lowerBound))
        let upper = min(range.upperBound, min(start(ofRow: rows.upperBound + 1), extent))
        guard lower < upper,
              let first = cells(of: lower, within: rows),
              let last = cells(of: upper - 1, within: rows) else { return }
        func set(_ row: Int, _ columnRange: ClosedRange<Int>) {
            let index = row - rows.lowerBound
            guard bits.indices.contains(index) else { return }
            for column in columnRange { bits[index] |= UInt16(1) << UInt16(column) }
        }
        if first.row == last.row {
            let from = min(first.columns.lowerBound, last.columns.lowerBound)
            let to = max(first.columns.upperBound, last.columns.upperBound)
            set(first.row, from...to)
            return
        }
        set(first.row, first.columns.lowerBound...(columns - 1))
        if last.row > first.row + 1 {
            for row in (first.row + 1)..<last.row {
                let index = row - rows.lowerBound
                if bits.indices.contains(index) { bits[index] = .max }
            }
        }
        set(last.row, 0...last.columns.upperBound)
    }
}
