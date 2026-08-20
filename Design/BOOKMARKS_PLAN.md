# Go To / Bookmarks: one form, marked rows, shared by both files

## Context

A 16 MB dump has a handful of places worth coming back to — the start of an EC
table, a region a donor differs in, the byte a patch went into. Today the only
way back is remembering the offset and typing it into Go To Position (⌘G). A
bookmark is that offset with a name on it, and a way to see and reach it.

Comparison is by absolute offset (§8), so a bookmark is an offset, not "an offset
in file A": one list serves both panes and marks the same height in both, which
is the whole point of it in a comparison. It is also why the two features are one
surface: ⌘G already moves *both* carets in a comparison (§10.1), so "go to this
address" and "go to this bookmark" are the same operation with two ways of naming
the destination.

## Decisions

- **A bookmark marks a row, not a byte** — the offset rounded down to a multiple
  of 16. The two places a bookmark has to be visible are row-granular by
  construction: the Offset column carries one address per row, and a local
  minimap row *is* one hex row. Byte precision would live only in the model and
  in the list, and be invisible exactly where it is meant to be seen. It also
  removes the "two bookmarks in one row" ambiguity from the drawing.
- **Colour: `systemPurple`.** The SDK has no semantic colour for bookmarks —
  AppKit's semantic set is label/text/control/selection/link/findHighlight/
  separator/grid — and Apple's own apps disagree with each other (Safari uses the
  accent, Xcode a blue-grey flag, Preview and Books red). The app's palette is
  otherwise spoken for: red is modified bytes and the insert caret, orange is a
  difference, the accent is the caret and the mirror frames, ink blue is the
  addresses. Purple is free, tells itself apart from all of them at a glance in
  both themes, and takes white text on the inverted address. Green would read as
  "matches", which a bookmark says nothing about.
- **Go To and the bookmark list are one modal form**, presented centred over the
  window (`presentAsModalWindow`, the AppKit shape of a form sheet) rather than a
  sheet dropping from the title bar: it carries a field, a combo box and a table,
  which is more than a sheet's usual one-question shape.
- **One-shot, not detachable.** A jump dismisses the form. Making it detachable
  was considered and dropped: a non-modal navigator has to be kept in step with
  files closing and modes changing, has to hand first responder back to the hex
  view after every jump, and has to make sure a second invocation focuses the
  torn-off window instead of opening a copy. None of that is worth it for a list
  that is consulted in bursts.
- **Session only.** Bookmarks live as long as the window. Persisting them raises
  a question this feature should not answer — the list is shared by two files
  with two identities (§4.2) — and belongs to project support later. The
  *recently typed offsets* do persist, mirroring the find history.
- **No Next/Previous Bookmark commands.** The form is the navigation. A click on
  or near a bookmark's arrow in the minimap snaps to it, which is what makes the
  two-pixel mark in the overview reachable.
- **Absolute addresses: bookmarks do not follow edits.** An insert or a delete
  shifts the bytes, not the bookmark. The app's premise is absolute offsets with
  no alignment tricks (§8); four inserted bytes in a 16 MB dump leave every
  bookmark pointing at the same row, which is all a navigation mark needs.
  Following the content would need an anchor model that drifts over repeated
  edits. A bookmark past the end of both files stays in the list — an address is
  an address — and is simply not drawn where a file does not reach.

## Design

### 1. The model — `BookmarkStore`

```swift
struct Bookmark: Equatable {
    let row: UInt64        // always a multiple of HexLayout.bytesPerRow
    var name: String       // empty means "show the address"
}

@MainActor final class BookmarkStore {
    private(set) var bookmarks: [Bookmark]        // sorted by row
    var onChange: (() -> Void)?

    static func row(containing offset: UInt64) -> UInt64   // offset - offset % 16
    func bookmark(atRowContaining offset: UInt64) -> Bookmark?
    @discardableResult func toggle(rowContaining offset: UInt64) -> Bookmark?
    func add(rowContaining offset: UInt64, name: String)
    func rename(row: UInt64, to name: String)
    func remove(row: UInt64)
    /// The rows in a window, for the hex view's per-row drawing.
    func rows(in range: Range<UInt64>) -> Set<UInt64>
}
```

One instance on `WindowViewModel`, reached by both panes and by the minimap —
that is what makes the list shared rather than merged. `onChange` drives three
repaints: each pane's affected rows, the minimap's margin, and the open form's
table.

### 2. The Offset column

`HexView.drawRow` draws the address with `HexTheme.inkBlue` today. A bookmarked
row instead gets:

- the address inverted: a rounded rect over `layout.offsetColumnFrame(row:)`,
  inset a point, filled `HexTheme.bookmarkColor` (purple), with the address drawn
  over it in a resolved white;
- a small solid triangle pointing right in the `leftPadding` strip before the
  column, same colour — the arrow the eye catches when scanning the gutter rather
  than reading addresses.

The data source gains one question, asked once per drawn row range:

```swift
func hexBookmarkedRows(in range: Range<UInt64>) -> Set<UInt64>
```

A set per range rather than a call per row, the same shape as `hexByteStates`.

Both panes draw it, because both read the same store. In a comparison the shorter
file's pane has no such row to draw (§9).

### 3. The minimap

`MinimapView.bookmarkRows: [UInt64]`, set by the controller from the store. Drawn
as triangles in the map's **left padding**, outside the content area, so a mark
never covers data:

- **local**: a map row is one hex row, so the arrow lands exactly;
- **overview**: a map row is kilobytes, so the arrow marks the row the bookmark
  falls in; several bookmarks can collapse into one arrow, which is acceptable at
  that scale. Two pixels tall, like the other event marks, and purple keeps it
  apart from the modified red hairline and the difference orange.

**Click snapping.** The click path asks for a snapped offset:

```swift
func snappedOffset(at point: NSPoint) -> (mapIndex: Int, offset: UInt64)?
```

If a bookmark's arrow is drawn within `bookmarkSnapDistance` (4 pt) of the click,
the nearest such bookmark's row wins; otherwise the offset under the pointer, as
now. Dragging the viewport is untouched — snapping a continuous scroll would
fight the drag.

### 4. The form — `GoToBookmarksController`

Presented with `presentAsModalWindow`, centred over the window, window-modal.
Return and Escape work through buttons carrying `keyEquivalent` `"\r"` and
`"\u{1B}"`, the way the existing sheet family does it.

```
┌─ Go To ─────────────────────────────────────────┐
│ Offset: [ 0x7AF000              ▾ ]  ( Go To )   │
│                                                  │
│ ┌ Bookmarks ────────────────────────────────────┐│
│ │ 0x00000000   Reset vector                     ││
│ │ 0x0007AF00   EC table                         ││
│ │ 0x00F00000   NVRAM region                     ││
│ └───────────────────────────────────────────────┘│
│                                        ( Cancel )│
└──────────────────────────────────────────────────┘
```

- **Focus starts in the offset field.** The fast path is unchanged: ⌘G, type,
  Return. The explicit **Go To** button names the action rather than leaving it to
  be guessed from Return.
- **Return follows the focus.** Field focused → go to the typed offset. Table
  focused with a row selected → go to that bookmark. Table focused with nothing
  selected → nothing happens. No jump is ever a coin flip.
- **A double click on a row** jumps too, so the mouse needs no detour.
- **Escape is two-level**: while a name is being edited it cancels the edit; at
  rest it closes the form. Editing a name and pressing Escape must not throw away
  the window.
- **The list is where bookmarks are managed**: `⌫` removes the selection, a
  double click on a *name* edits it in place. Nothing about bookmarks lives in
  two places.
- **Recently typed offsets** hang off the field as a combo box: the last 10,
  persisted, in a `GoToHistoryStore` shaped exactly like the existing
  `FindHistoryStore` (same limit, same swappable defaults domain so tests do not
  pollute the user's own history).
- **Empty state**: the table says what a bookmark is and that ⌘D makes one.
- **A jump dismisses the form**, and behaves exactly as ⌘G does today: in a
  comparison both panes move (§10.1), an offset past EOF alerts and lands at the
  end, and the row is revealed centred.

Two ways in: **⌘G** opens it with the field focused, **⌥⌘B** with the table
focused. A toolbar button belongs here too, but the toolbar's composition (and
this item's icon — `bookmark` is the obvious candidate) is a separate question,
deliberately left for when the toolbar is filled out as a whole.

### 5. Making and naming a bookmark

- **⌘D** — *Add Bookmark* — marks the caret's row immediately, unnamed. No
  dialog: on a bench this is the gesture that has to cost nothing. Pressed again
  on a bookmarked row it removes it.
- **⇧⌘D** — *Add Bookmark…* — the same, but a small sheet asks for the name
  first, pre-filled with the row's address. The ellipsis carries its usual Mac
  meaning: a dialog follows.
- **Right-click** on an address, and on a byte (which resolves to its row),
  offers *Add Bookmark*, *Add Bookmark…*, *Remove Bookmark* and *Rename
  Bookmark…*, with the row address in the title so it is clear what is marked.
  The offset column's context menu already exists (§10.2) and already knows the
  row.

## Spec

A new **§20 Bookmarks** carrying the decisions above, plus the cross-references
that make them findable from the places they touch:

- §6 (the hex grid): the Offset column shows a bookmarked row inverted, with an
  arrow in the gutter.
- §10.1 (Go To Position): the dialog becomes Go To / Bookmarks, and what Return
  does in it.
- §10.2 (context menus): the address and byte menus offer add/remove/rename.
- §10.3's shortcut list: ⌘D, ⇧⌘D, ⌥⌘B.
- §19.4 / §19.6 (the minimap): bookmark arrows in the margin of both modes, and
  a click near one snapping to it.

## Stages

Five stages, each of which ends with the app working and something new that can
be used on its own. None of them leaves a half-wired feature behind, and each
carries its own slice of §20 rather than deferring the spec to the end — that is
how the rest of this project has been built.

### Stage 1 — Mark a row and see it

**Delivers:** ⌘D marks the caret's row and marks it again to unmark; the row's
address shows inverted in purple with an arrow in the gutter, in *both* panes of
a comparison.

- `Bookmark`, `BookmarkStore` (row snapping, toggle, ordering, `rows(in:)`), one
  instance on `WindowViewModel`, `onChange` repainting the affected rows.
- `HexTheme.bookmarkColor`; the Offset column's inverted address and gutter arrow
  in `HexView.drawRow`; `hexBookmarkedRows(in:)` on `HexViewDataSource`.
- Edit ▸ Add Bookmark (⌘D) as a toggle, with menu validation.
- Tests: the store's arithmetic (two offsets in one row are one bookmark, the
  ordering, toggling); a render test reading purple in the Offset column and the
  arrow in the gutter, in both panes; a menu test for the item and its key.
- Spec: §20 with the model and the marking rules, plus the §6 cross-reference.

**Done when** a row can be marked and unmarked from the keyboard and both panes
show it. No names, no list, no minimap.

### Stage 2 — Give it a name

**Delivers:** names, and every way of making or changing a bookmark that does not
need the form.

- ⇧⌘D — *Add Bookmark…* — with a small name sheet, pre-filled with the row's
  address, on the existing `SheetViewController` base.
- The Offset column's and the byte's context menus: *Add Bookmark*, *Add
  Bookmark…*, *Remove Bookmark*, *Rename Bookmark…*, each carrying the row
  address in its title; the byte's items resolve to the byte's row.
- `BookmarkStore.rename`; an empty name renders as the address wherever a name is
  shown.
- Tests: the sheet's submit path; the context menu's titles and targets for both
  anchors; renaming through the store.
- Spec: §20's naming rules, the §10.2 cross-reference.

**Done when** a bookmark can be created named, renamed and removed without the
form existing.

### Stage 3 — The Go To / Bookmarks form

**Delivers:** the merged navigation surface, and with it the only part of the
feature that replaces something that exists today.

- `GoToBookmarksController` presented with `presentAsModalWindow`: the offset
  field with its recents combo and the **Go To** button, the bookmarks table
  below.
- `GoToHistoryStore` — last 10 typed offsets, persisted, shaped exactly like
  `FindHistoryStore` including the swappable defaults domain.
- Return follows the focus (field → typed offset, table with a selection → that
  bookmark, table without one → nothing); double click jumps; `⌫` removes; a
  double click on a name edits it in place; Escape cancels a name edit first and
  closes the form second.
- Entry points: ⌘G (field focused) and ⌥⌘B (table focused). A jump dismisses the
  form and behaves as ⌘G does today: both carets in a comparison (§10.1), an
  offset past EOF alerts and lands at the end, the row revealed centred.
- The old `GoToSheetController` goes; its behaviour is now this form's field.
- Tests: the focus rules for Return (all three cases); the recents store's limit
  and persistence; jumping from the table moves both panes; the past-EOF path
  still alerts; a name edit's Escape does not close the form.
- Spec: §10.1 rewritten around the merged form, §20's list rules, §10.3's
  shortcut list.

**Done when** ⌘G still goes to a typed offset in three keystrokes, and the same
window lists the bookmarks and jumps to them.

### Stage 4 — Arrows in the minimap

**Delivers:** bookmarks visible in both minimap modes, so a marked region can be
found without opening anything.

- `MinimapView.bookmarkRows`, fed from the store by the controller; triangles in
  the map's left padding, outside the content area, in both modes; two pixels
  tall in the overview, exact in local.
- Repaint on `onChange`, bounded to the margin strip.
- Tests: a render test for the arrow's position in each mode; the shared list
  putting an arrow at the same height on both maps; nothing drawn past a shorter
  file's end (§9).
- Spec: the §19.4 cross-reference.

**Done when** marking a row puts an arrow on both maps and removing it takes the
arrow away.

### Stage 5 — Click near an arrow to land on it

**Delivers:** the two-pixel overview arrow becomes a target you can hit.

- `MinimapView.snappedOffset(at:)` — the nearest bookmark whose arrow is drawn
  within `bookmarkSnapDistance` (4 pt) of the click wins; otherwise the offset
  under the pointer, as now. The click path uses it; dragging the viewport does
  not.
- Tests: a click 3 pt from an arrow lands exactly on the bookmark's row, a click
  20 pt away lands where it was aimed, and a drag is unaffected.
- Spec: the §19.6 cross-reference.

**Done when** clicking an arrow in the overview of a 16 MB file lands on the
bookmark's row rather than a few rows off.

### Order and independence

Stages 1 and 2 are the feature's spine and must go in order. Stage 3 depends on 1
(it lists what the store holds) but not on 2. Stages 4 and 5 depend only on 1,
and 5 only makes sense after 4. Nothing after stage 1 changes anything the
earlier stages established, so the work can stop after any of them and leave the
app coherent.

## Verification

- `swift test` in `DumpCompareCore` is untouched: the store holds no bytes and
  lives in the app target. The app suite carries the rest.
- Manual: bookmark a row in one pane of a comparison and check the other pane's
  gutter marks the same height; ⌘D twice removes it; ⇧⌘D names it; the arrow
  shows in both minimap modes; a click on the arrow in the overview lands exactly
  on the bookmark rather than a few rows off; ⌘G still goes to a typed offset in
  three keystrokes; the recents combo remembers across a relaunch while the
  bookmarks do not.
