import Foundation

/// A bookmark marks a row of the hex dump, not a byte (§20): `row` is always a
/// multiple of `HexLayout.bytesPerRow`. The two places a bookmark has to be
/// visible — the Offset column and a minimap row — are row-granular by
/// construction, so byte precision would live only in the model and be
/// invisible exactly where it is meant to be seen. It also removes the "two
/// bookmarks in one row" ambiguity from the drawing.
struct Bookmark: Equatable {
    /// The row's start offset, always a multiple of `HexLayout.bytesPerRow`.
    let row: UInt64
    /// A name for the bookmark; empty means "show the address".
    var name: String
}

/// The window's bookmark list. One instance lives on the `WindowViewModel`,
/// reached by both panes and (later) the minimap — that is what makes the list
/// shared rather than merged: comparison is by absolute offset (§8), so a
/// bookmark is an offset, not "an offset in file A", and it marks the same
/// height in both panes of a comparison.
///
/// Bookmarks are session-only: they live as long as the window, not the file.
/// They are absolute addresses — an insert or a delete shifts the bytes, not
/// the bookmark (§8) — and a bookmark past the end of a file stays in the list
/// and is simply not drawn where the file does not reach (§9).
///
/// `MainActor`-confined (UI on MainActor) but AppKit-free and byte-free, so the
/// arithmetic is unit-testable in the app suite.
@MainActor
final class BookmarkStore {
    /// The bookmarks, kept sorted by `row`.
    private(set) var bookmarks: [Bookmark] = []

    /// Fired after any change with the affected row's start offset, so the
    /// consumers — the panes' affected rows, the minimap's margin, an open
    /// form's table — can repaint exactly what moved. The row, not a bare
    /// signal: a toggle touches one row, and the panes redraw just it instead
    /// of every visible row of a 16 MB dump.
    var onChange: ((UInt64) -> Void)?

    /// The row containing `offset`: the offset rounded down to a multiple of
    /// `HexLayout.bytesPerRow`.
    static func row(containing offset: UInt64) -> UInt64 {
        offset - offset % UInt64(HexLayout.bytesPerRow)
    }

    /// The bookmark on the row containing `offset`, if any.
    func bookmark(atRowContaining offset: UInt64) -> Bookmark? {
        let row = Self.row(containing: offset)
        return bookmarks.first { $0.row == row }
    }

    /// Toggles the mark on the row containing `offset`: adds an unnamed
    /// bookmark when the row is unmarked, removes it when it is marked. Returns
    /// the bookmark when the row is marked after the call, `nil` when the
    /// toggle removed it.
    @discardableResult
    func toggle(rowContaining offset: UInt64) -> Bookmark? {
        let row = Self.row(containing: offset)
        if let index = bookmarks.firstIndex(where: { $0.row == row }) {
            bookmarks.remove(at: index)
            onChange?(row)
            return nil
        }
        let added = Bookmark(row: row, name: "")
        // Insert keeping the list sorted by row.
        let index = bookmarks.firstIndex { $0.row > row } ?? bookmarks.endIndex
        bookmarks.insert(added, at: index)
        onChange?(row)
        return added
    }

    /// The bookmarked rows in `range` (a range of offsets), for the hex view's
    /// per-row drawing.
    func rows(in range: Range<UInt64>) -> Set<UInt64> {
        Set(bookmarks.filter { range.contains($0.row) }.map(\.row))
    }
}
