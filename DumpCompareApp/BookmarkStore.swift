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
        name.isEmpty ? Self.addressLabel(row) : name
    }

    /// A row address as the dialogs write one: `0x` and at least eight upper-case
    /// hex digits (§10).
    static func addressLabel(_ row: UInt64) -> String {
        "0x" + String(row, radix: 16, uppercase: true).leftPadded(to: 8, with: "0")
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
