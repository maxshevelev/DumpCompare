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

    /// What the bookmark is called wherever a name is shown — the list, the
    /// mark's tooltip, VoiceOver. An unnamed bookmark is not nameless: it is
    /// called by where it is, so it shows its address (§20.2). One place decides
    /// this, so every surface agrees.
    var displayName: String {
        name.isEmpty ? row.hexAddress : name
    }

    /// A name with its surrounding whitespace removed — the form every path
    /// stores, so a name typed with a stray space is the same name (§20.2), and
    /// one typed as nothing but spaces is unnamed.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
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

    /// Replaces the whole list at once, reporting nothing.
    ///
    /// Every other verb here is per row and fires `onChange(row)`, which fans
    /// out to both panes and the controller so each repaints exactly the row
    /// that moved (§19.9). Replaying a list through them would repaint a window
    /// once per mark — and the only caller is a tab being built, whose marks are
    /// copied from the tab it was torn off (`Design/TABS_PLAN.md`).
    ///
    /// That is the contract: seed a store nothing is drawing yet. Seeding a live
    /// one would leave every consumer showing the marks it had before.
    func seed(_ marks: [Bookmark]) {
        bookmarks = marks.sorted { $0.row < $1.row }
    }

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
        bookmarks.insert(added, at: insertionIndex(for: row))
        onChange?(row)
        return added
    }

    /// Marks the row containing `offset`, named or not, and returns the
    /// bookmark. An already-marked row keeps its one bookmark and takes the new
    /// name — marking twice never makes two marks on one row (§20.1), and the
    /// name given here is the one that sticks.
    @discardableResult
    func add(rowContaining offset: UInt64, name: String = "") -> Bookmark {
        let row = Self.row(containing: offset)
        let clean = Bookmark.normalized(name)
        if let index = bookmarks.firstIndex(where: { $0.row == row }) {
            bookmarks[index].name = clean
            onChange?(row)
            return bookmarks[index]
        }
        let added = Bookmark(row: row, name: clean)
        bookmarks.insert(added, at: insertionIndex(for: row))
        onChange?(row)
        return added
    }

    /// Renames the bookmark on the row containing `offset`, returning it, or nil
    /// when that row carries no bookmark — renaming is for a mark that exists,
    /// so a caller that means "mark it and call it this" uses `add` instead.
    /// An empty name unnames the bookmark: it goes back to showing its address.
    @discardableResult
    func rename(rowContaining offset: UInt64, to name: String) -> Bookmark? {
        let row = Self.row(containing: offset)
        guard let index = bookmarks.firstIndex(where: { $0.row == row }) else { return nil }
        bookmarks[index].name = Bookmark.normalized(name)
        onChange?(row)
        return bookmarks[index]
    }

    /// Removes the mark from the row containing `offset`. Returns whether there
    /// was one to remove, so a caller can tell "removed" from "nothing there"
    /// without reading the list first.
    @discardableResult
    func remove(rowContaining offset: UInt64) -> Bool {
        let row = Self.row(containing: offset)
        guard let index = bookmarks.firstIndex(where: { $0.row == row }) else { return false }
        bookmarks.remove(at: index)
        onChange?(row)
        return true
    }

    /// Applies an edit from the edit popover (§20.3): the bookmark on the row
    /// containing `from` takes `name`, and moves to the row containing `to` when
    /// that is a different row. Moved rather than removed and re-made, so it is
    /// never in the list without its name. Returns the bookmark as it now is, or
    /// nil when `from` carries none.
    ///
    /// The target row is taken as given: the popover only offers rows that are
    /// free (§20.1), which is a question about the whole list and so is asked
    /// before the edit, not during it.
    @discardableResult
    func edit(rowContaining from: UInt64, to target: UInt64, name: String) -> Bookmark? {
        let fromRow = Self.row(containing: from)
        let toRow = Self.row(containing: target)
        guard bookmarks.contains(where: { $0.row == fromRow }) else { return nil }
        guard toRow != fromRow else { return rename(rowContaining: fromRow, to: name) }
        remove(rowContaining: fromRow)
        return add(rowContaining: toRow, name: name)
    }

    /// Moves the bookmark on the row containing `from` to the row containing
    /// `to`, keeping its name, and returns the row it ended on — nil when there
    /// was nothing to move, nowhere to move it, or the move was refused.
    ///
    /// One row holds at most one bookmark (§20.1), so a target another bookmark
    /// already holds is **jumped over**: the search carries on in the direction
    /// of travel to the first free row, which is what makes dragging a mark
    /// through a marked row feel like one mark sliding past another rather than
    /// two merging. When there is no free row beyond the obstacle — occupied all
    /// the way to `lastRow` going down, or to row 0 going up — the mark instead
    /// **stops before it**, on the last free row on the way there: a mark may
    /// neither leave the file to find room nor swallow the bookmark in its way,
    /// but it should still travel as far as the pointer took it. Only when even
    /// that room is missing (the obstacle sits right next to where the mark
    /// started) does nothing move.
    ///
    /// `lastRow` comes from the view, not from a file size held here: the last
    /// row a mark may be dragged to is the last row that pane draws (§9), and
    /// only the view knows that.
    @discardableResult
    func move(rowContaining from: UInt64, to: UInt64, lastRow: UInt64) -> UInt64? {
        let fromRow = Self.row(containing: from)
        guard let index = bookmarks.firstIndex(where: { $0.row == fromRow }) else { return nil }
        let limit = Self.row(containing: lastRow)
        let target = min(Self.row(containing: to), limit)
        guard target != fromRow else { return nil }
        guard let landing = freeRow(near: target, from: fromRow, limit: limit) else { return nil }

        let moved = Bookmark(row: landing, name: bookmarks[index].name)
        bookmarks.remove(at: index)
        bookmarks.insert(moved, at: insertionIndex(for: landing))
        // Both rows changed: the one the mark left and the one it landed on.
        onChange?(fromRow)
        onChange?(landing)
        return landing
    }

    /// Where a mark travelling from `from` toward `target` can actually land:
    /// `target` itself when free; else the first free row beyond the bookmarks
    /// blocking it, in the direction of travel and within `0...limit`; else the
    /// last free row before them, on the way back toward `from`. Nil when the
    /// obstacle leaves no room at all — `from`'s own row does not count, since
    /// staying put is not moving.
    private func freeRow(near target: UInt64, from: UInt64, limit: UInt64) -> UInt64? {
        let step = UInt64(HexLayout.bytesPerRow)
        let descending = target > from
        func isFree(_ row: UInt64) -> Bool { !bookmarks.contains { $0.row == row } }

        var row = target
        while !isFree(row) {
            if descending {
                guard row + step <= limit else { return lastFreeRow(before: target, from: from) }
                row += step
            } else {
                guard row >= step else { return lastFreeRow(before: target, from: from) }
                row -= step
            }
        }
        return row
    }

    /// Walking back from `target` toward `from`, the first free row — where a
    /// mark stops when the way past the obstacle is closed.
    private func lastFreeRow(before target: UInt64, from: UInt64) -> UInt64? {
        let step = UInt64(HexLayout.bytesPerRow)
        let descending = target > from
        var row = target
        while row != from {
            row = descending ? row - step : row + step
            guard row != from else { return nil }
            if !bookmarks.contains(where: { $0.row == row }) { return row }
        }
        return nil
    }

    /// Where `row` belongs in the list, which is kept sorted by row.
    private func insertionIndex(for row: UInt64) -> Int {
        bookmarks.firstIndex { $0.row > row } ?? bookmarks.endIndex
    }

    /// The bookmarked rows in `range` (a range of offsets), for the hex view's
    /// per-row drawing.
    func rows(in range: Range<UInt64>) -> Set<UInt64> {
        Set(bookmarks.filter { range.contains($0.row) }.map(\.row))
    }
}
