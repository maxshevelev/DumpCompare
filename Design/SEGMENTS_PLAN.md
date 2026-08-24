# Segments — a dump as the pieces it is made of

## What a segment is

A **partition** of the pane's content: pieces that are contiguous, never overlap,
and cover the file completely. N pieces are N−1 **cuts**, so the model is an
ordered list of cut offsets with a name each, and gaps or overlaps are impossible
by construction rather than by validation.

Every open file has at least one segment — itself. Adding a cut makes two;
removing a cut merges two back into one. Nothing about a segment changes the
bytes: a partition is a way of *reading* a file, and every operation that writes
is explicit about it.

This is deliberately not the same object as either of its neighbours:

| | bookmarks (§20) | segments | zones (`ZONES_IDEA.md`) |
|---|---|---|---|
| what it is | a point | a partition | sparse named intervals |
| whose | the window's | the pane's | the pane's |
| under an edit | never moves | follows the content | follows the content |
| made by | the user | the user, or a join | a parser, or the user |
| answers | "come back here" | "what is this image made of" | "what is this part of it" |

Segments are the pane's, not the window's: they describe one file's make-up, and
the other pane holds a different file. Swapping panes swaps them; closing a file
drops them.

**They follow the content.** An insert or a delete moves the cuts after it and
resizes the piece it happened inside; a delete that swallows a cut merges the two
pieces it separated; a delete that empties a piece removes it. The plumbing
exists: the document already computes a net edit per transaction, which the
comparison index and the minimap consume (§8.3), and the segment list updates
from the same description in one place, with undo restoring it alongside.

This is the opposite rule to bookmarks, and that is the point — a mark is an
address the user chose and must stay put; a cut is the edge of a stretch of
content and must travel with it. The case that proves it: append B to A, then
insert C at the start, and the first seam moves.

## Labels and descriptions

A segment has a **label** and an optional **description**.

- The label is positional: **S0, S1, S2 …** in file order, renumbered whenever a
  cut is added or removed. Zero-based, like every other offset in the app (§10).
  Every segment always has one, so nothing is ever nameless.
- The description is optional and survives renumbering. A join fills it with the
  name of the file the bytes came from
  (`W25Q128FV_20260821_1a2b3c4d.bin`) — the record of which piece belongs to
  which chip, and the reason the field exists at all. By hand it is whatever the
  user finds useful: "ME region", "донор", "before the patch".

So a row reads `S1 · 0x400000 · 8 MB · W25Q…bin`, and a segment with no
description is still `S1`, never blank. Two segments may carry the same
description — it describes, it does not identify; the label identifies.

## Seeing them

Three places, in the order they earn their keep.

**1. A pale tint behind the bytes.** Each piece fills its own rows with a muted,
desaturated background — **solid, and edge to edge**: from the row's left edge,
across the Offset column, through the gaps between the two 8-byte groups and
before the decoded-text column, out to the row's right edge. The gaps are what
makes it read as one continuous stretch rather than a row of tinted cells, and
they are also what keeps the tint visible under a difference, because the orange
fill paints byte cells only (§8.2) and leaves the gaps alone.

- **The Offset column is tinted too.** The band runs the full width of the row,
  so the column takes the colour of the piece beside it. The addresses, the
  bookmark's mark and the right-click ring (§20.4) are drawn on top of the tint,
  so the column stays legible and the mark is never swallowed by the fill.
- **A mid-row cut is drawn exactly**, byte by byte: the bytes before it keep the
  earlier piece's colour, the bytes after it take the next one's, and the step is
  visible inside the row where it belongs. The boundary passes through the middle
  of the gap between the two bytes it separates, and the two fills meet there —
  no uncoloured slit between them. This is the whole reason a fill beats a line —
  a boundary is not obliged to land on the row grid, and nothing has to be
  rounded, dashed or apologised for. (A file whose size is not a multiple of 16,
  or any insert of a length that is not, puts every later cut off the grid.)
- **Past EOF there is no tint**: no bytes, no piece. The hatching (§6) stands as
  it does today.
- **The layering, bottom to top** (an addition to §6's stack): segment tint,
  then the Offset column's addresses and the bookmark's mark, then the difference
  fill, the selection fill, and the text — modified bytes red, muted
  `0x00`/`0xFF` grey, the caret over everything. The bookmark's mark sits above
  the tint, so a mark on a tinted row is never swallowed by it. Selection and
  difference cover the tint, which is correct: what a byte *is* outranks which
  piece it belongs to, and the piece is still readable in the gaps and in the
  rows either side.
- **The palette** is a small set of **pastels** — light green, light pink, pale
  blue, pale yellow, lavender, peach — cycled by label, in the spirit of how
  Fusion 360 tints components: enough colour to tell one piece from the next,
  never enough to draw the eye. Six is plenty; a dump will not have more pieces
  than that in practice, and if it does the palette repeats, which is harmless
  because what has to be distinguishable is **neighbours**, not every pair.

  Four rules it has to satisfy, and each is a test rather than an opinion:

  1. **Background weight.** Barely off the paper: the tint sits under text, so its
     contrast with the paper is small and its contrast with the *ink* is what must
     survive — including the muted `0x00`/`0xFF` at 40 % alpha (§6), which is most
     of a dump.
  2. **Adjacent contrast.** Consecutive entries must be plainly different from
     each other, since that is what draws the boundary. Measured, not eyeballed:
     a minimum channel distance between neighbouring entries in the cycle.
  3. **No conflict with the states drawn over it.** An orange difference and the
     accent selection must still read as themselves on every tint, and no tint may
     be mistakable for either — so nothing in the orange band, nothing at the
     accent's saturation, and nothing close to the bookmark purple.
  4. **Two sets, one order.** A light-theme set and a dark-theme set of the same
     hues at the other end of the lightness range, resolved the way the rest of
     `HexTheme` resolves colours, so S1 is "the pink one" in both themes.

**2. A colour strip beside the minimap.** When the pane has two or more pieces,
the panel grows a **4 pt vertical strip to the right of each map**, separated from
it by a narrow gap, painted with the same colours in the same order as the dump's
tint. The gap is what makes it a legend rather than part of the picture, and using
the same colours is what makes it a legend at all: the block that says S1 on the
map is the colour S1's rows are tinted in.

It replaces the earlier idea of squeezing a ribbon into the existing margins,
which was cramped — the viewport's chevrons already take both edges and the
bookmark arrows the outer one (§19.4.3, §19.6). A strip outside the map with a gap
costs 6 pt of panel width and touches none of that geometry. One piece, no strip.

The strip carries the right-click menu (below), and one left-click gesture:
**clicking on a boundary puts the caret there.** Within 4 pt of a cut — the same
reach a click near a bookmark's arrow already snaps by (§19.6.1) — the click
resolves to the cut's **exact offset** rather than to the row the pixel means, and
the pane reveals it centred like any other minimap click (§19.7). The nearer cut
wins when two are within reach.

That is the gesture worth having on an overview of a 16 MB image, where one row is
kilobytes and a boundary is the one offset you cannot afford to land near instead
of on. Everywhere else the strip is inert: a click in the middle of a block does
nothing at all, so a stray click cannot move the caret or drop the selection. The
hover text says which of the two it is under the pointer — the piece in the middle
of a block, the boundary near a cut (`S0 │ S1 — 0x400000`), so the target
announces itself.

**3. The caret's segment in the status bar.** `S1: 0002E6-400000 (255 KB)` — the
label, the piece's half-open range in bare hex (no `0x` prefix), and its size,
rounded to a whole value of its abbreviation. Every address in the bar — the
caret's offset and the piece's bounds — is zero-padded to the width of the
file's largest address (the last piece's exclusive end, which can be the file's
own size), so they read as aligned columns. No new chrome, present whether or
not the minimap is open, and it answers the question that comes up while
scrolling — *which piece am I in?* Shown only when the pane has two or more
pieces: `S0` beside a whole file is noise, and the readout appearing at all is
itself the signal that this dump is partitioned.

**No click-to-select.** Selecting a whole piece is a rare act and a stray click
should not do it: selection stays a menu item. The one thing a plain click does is
land the caret on a boundary, as above — a 4 pt target that has to be aimed at,
which is the opposite of a gesture you trip over.

**No dragging a cut.** The gesture exists (bookmark marks drag, §20.6) and would
be cheap to reuse, and it is still the wrong answer here: the segmentation is the
thing the two-chip round trip depends on, and a boundary that can be nudged by a
slipped mouse is a boundary you have to re-check every time. Cuts move by typing
an offset, which is deliberate by construction — and a cut may only move within
the interval it currently bounds, strictly between its neighbouring cuts (or the
file's end). It can never jump over another cut, so the partition's structure is
preserved: the piece it opened keeps its name, and the name travels with the
boundary. A typed offset past a neighbouring cut is refused, not wrapped.

## Acting on them

**A right-click menu on the strip**, on the block under the pointer:

- **Save Segment…** — writes just those bytes to a file.
- **Replace Segment from File…** — replaces those bytes with a file's content.
- **Select Segment** — selects the piece's whole range, deliberately and only
  when asked — the full region, not a caret at its start.
- **Edit…** — opens the piece's own popover (name and start offset), anchored to
  the block under the pointer — the same editor the form's row uses, not the form
  with the table of all segments.
- **Merge** — merges the piece into a neighbour that keeps its name. The bytes
  are untouched: merging a piece is a change to how the file is read, not to the
  file. (Deleting the *bytes* of a piece is Delete Bytes on a selection, §7.2,
  and says so.) The item names the piece and its neighbour — *Merge S1 into S0*.

Right-clicking a tinted row offers the same piece menu as the strip, plus the
segment pair described below.

**And in the dump's own context menu.** The offset context menu (§10.2) already
carries the address-scoped commands — Copy offset, Select block from here, the
bookmark pair — and the segment pair belongs with them, **set off in its own
block between separators** so the partition commands read as a group distinct
from the selection and bookmark commands. It is the same block whether the menu
was opened on a byte or on the Offset column's address, and it carries two
commands:

- **Split Here** — opens the same offset-and-description popover Add Cut… opens
  (stage 2), **pre-filled with the address the menu was opened on**: right-click
  an address and it is that row's start; right-click a byte and it is that byte.
  Both are honestly "here", and neither rounds. The popover is the one editor
  that creates and edits a cut, as one popover does for a bookmark (§20.3).
- **Merge** — merges the piece the caret (or the right-clicked position) sits
  in into a neighbour that keeps its name. It acts on a *position inside a
  segment*, not on a cut point. It is enabled whenever the pane has more than
  one piece — including **S0**, which is merged by re-opening the piece below at
  the file start, so what was S1 becomes S0. The menu item names the piece and
  the neighbour it merges into — *Merge S1 into S0*, not a bare *Merge* — in the
  Edit menu, the offset context menu and the form's row menu alike.

## The Segments form

Where the partition is edited and written out — a modal window, presented like
the Go To form (§10.1):

```
┌ Segments ─────────────────────────────────────────────────────┐
│  S0   00000000   4 MB    MX25L3206E_…bin                      │
│  S1   00400000   8 MB    W25Q128FV_…bin                       │
│  S2   00C00000   4 MB                                         │
│                                                               │
│ ─────────────────────────────────────────────────────────────  │
│  +   −                                                        │
│                                                               │
│                   [ Save All as Separate Files… ]  [ Close ]  │
└───────────────────────────────────────────────────────────────┘
```

- Four columns: label, start offset, size, name. Ordered by offset, always.
- **No editable cells.** The bookmark list learned this the hard way (§20.5): a
  field inside a table row is edited by a click on an already-selected row, which
  collides with the double click that activates it. So editing is a popover with
  two fields — **name** and **start offset**, the offset validated as it is typed
  like every offset field in the app (§10.1) — opened by a double click on the
  row or from the row's context menu. Moving a cut is typing a number in that
  popover.
- **Split Segment Here** splits the segment the caret is in, at the caret's
  exact byte — no rounding, ever, because the export reads these offsets.
  **Merge** merges the selected piece into a neighbour that keeps its name
  (merging S0 reopens the piece below at the file start, so what was S1 becomes
  S0).
- **Save Segment…** writes the selected one; **Save All as Separate Files…**
  writes every one in a single act — which is what "split the file" *is* once
  segments exist.
- Return goes to the selected segment's start; ⌫ merges the selected piece. The
  form follows the store, so a join or an edit made elsewhere shows up in it.

### Writing segments out

Both write commands share the mechanics, and they are the same ones the split
half of `JOIN_SPLIT_PLAN.md` specified:

- **A directory, not a save panel**, for the multi-file case: a save panel grants
  access to the one file the user named, and writing N files next to it would be
  denied in the sandbox. The directory is chosen with an open panel in directory
  mode, which grants what is needed. A single **Save Segment…** is one file and
  uses the ordinary save panel.
- **A base name**, pre-filled from the document's name, and the suffix is the
  piece's own label before the extension: `bios.bin` → `bios_S0.bin`,
  `bios_S1.bin`, `bios_S2.bin`. Nothing to map and nothing to guess — the name of
  the file on disk is the name of the piece on screen, so a folder of parts can be
  read back against the form without counting. It is also what makes the round trip
  exact: whatever the joined document was called, the pieces written out of it are
  named from the base name and their labels, so nothing depends on guessing a name
  from the sources (`JOIN_SPLIT_PLAN.md` drops that guess for good).
- **All or nothing**: each part goes to a temporary name in the target directory,
  is fsynced, and they are renamed into place together; a failure removes the
  temporaries and reports, publishing nothing half-written. (§5.2's lesson, and
  the bug behind commit `5bbef2a`.) The exception is a single **Save Segment…**:
  the save panel grants the one file it names, not the folder around it, so the
  sibling temp cannot be created. With one part there is nothing to keep atomic
  against, so it is written straight into the file the user chose — the same
  fallback the single-file Save As takes. Not atomic, but the only option the
  sandbox permits; a multi-part write has no such fallback.
- Existing files are named in **one** confirmation before anything is written.
- Unsaved edits are included — the content written is what the pane shows.
- A large write runs as a background operation with progress and a cancel button
  (§14.4).

### Replacing a segment from a file

The inverse, and the one operation that changes bytes. v1 requires the file to
**match the segment's length**: a region swap is what a bench does (put the
donor's ME region in), and a length mismatch is a structural edit that shifts
everything after it. A mismatch is refused with the two sizes named; making it an
insert-and-shift is a later decision, not a silent one.

## Edge cases

| case | behaviour |
|---|---|
| A file with no cuts | One piece and nothing drawn: no tint, no strip, no status-bar readout |
| A cut asked for at 0 or EOF | Refused, in the popover and in Split Here alike: every piece must be non-empty |
| Cut not row-aligned | Normal: the line steps inside the row, and the exact offset is in the tooltip and the form |
| A file whose size is not a multiple of 16 | Normal: the last row is partial and the last segment ends mid-row |
| An insert of 3 bytes before a cut | The cut moves by 3 and is now mid-row — expected, not an error |
| An insert or delete inside a segment | The segment resizes; the cuts after it move; undo restores the list |
| A delete that swallows a cut | The two pieces it separated merge |
| A delete that empties a segment | It is removed; the list renumbers |
| Undo of any of the above | The list is restored with the edit, from the same net edit the comparison consumes |
| Closing the file | The segments go with it; nothing is persisted (a project file would change that, TODO) |
| Comparison mode | Each pane has its own partition, its own tint colours, its own strip and its own form contents |
| Replace Segment from File with a size mismatch | Refused, both sizes named |
| Save All with one segment | Disabled — with a single piece there is nothing to separate, so it is a plain save |
| Click on the strip's middle | Nothing: caret, selection and scroll position unchanged |
| Click within 4 pt of a cut | The caret lands on the cut's exact offset, centred; the nearer cut wins |
| Click near the strip's top or bottom end | Nothing — the file's start and end are not cuts |

## The shape of the code

Before the stages, the pieces they build, so the stages can name them.

**`Segment` and `SegmentStore`** (app target, `@MainActor`, AppKit-free and
byte-free, like `BookmarkStore`):

```swift
struct Segment: Equatable {
    let index: Int          // positional label: S0, S1, …
    let range: Range<UInt64>
    var name: String        // empty means "no name", never shown blank
    var label: String { "S\(index)" }   // the one place the "S" is built
}

@MainActor final class SegmentStore {
    private(set) var contentSize: UInt64
    private(set) var cuts: [UInt64]     // sorted, strictly inside (0, contentSize)
    private(set) var names: [String]    // count == cuts.count + 1

    var onChange: ((Range<UInt64>) -> Void)?   // the offsets whose drawing changed

    var segments: [Segment] { get }
    func segment(containing offset: UInt64) -> Segment?
    @discardableResult func addCut(at offset: UInt64) -> Bool
    @discardableResult func removeCut(at offset: UInt64) -> Bool
    @discardableResult func removePiece(at index: Int) -> Bool   // S0 reopens the piece below at 0
    @discardableResult func moveCut(from: UInt64, to offset: UInt64) -> UInt64?
    func rename(_ index: Int, to name: String)
    func apply(_ edit: DiffEdit, newSize: UInt64)
    func reset(size: UInt64, name: String)     // one piece: the whole file

    func snapshot() -> Snapshot
    func restore(_ snapshot: Snapshot)
}
```

The store keeps **cuts, not ranges**: a partition is its boundaries, so gaps and
overlaps cannot be represented, let alone validated. `segments` derives the
ranges, and `index` is derived too — which is why a label renumbers and a name
does not.

**Where it lives.** One store per `PaneViewModel`, beside `document`: segments
describe one file's make-up (§20's bookmarks are the window's for the opposite
reason). `reset` on open, close and revert.

**Following the content.** `apply(_:newSize:)` takes the same `DiffEdit` the
comparison index and the minimap already consume (§8.3), called from the one place
`PaneViewModel` already computes it:

- **overwrite** — nothing moves.
- **insert(at:length:)** — cuts strictly greater than `at` shift by `+length`; a
  cut exactly at `at` stays, so inserted bytes join the piece that *starts* there.
- **delete(range:)** — cuts inside the range are removed, merging their pieces
  into the one that starts before the deletion, which keeps its name; cuts after
  it shift by `−length`; a piece left empty is removed with its name.

**Undo** restores by snapshot, not by inverse edit: a delete that swallowed a cut
cannot be undone from the edit alone, because the cut's offset and name are not in
it. `PaneViewModel` keeps a stack of snapshots parallel to the document's undo
stack — pushed with each recorded transaction, popped and restored on undo, with
the same lifecycle rules the document's own stack has (cleared on open and revert,
the redo side dropped on a divergent edit). This mirrors how the caret and the
selection are already restored (§7.5), one level up.

## Stages

Six, each ending with the app working and something usable on its own, and each
carrying its own slice of §21 rather than deferring the spec to the end — the way
the rest of this project has been built.

### Stage 1 — The model

**Delivers:** a partition that exists, is correct under editing, and survives
undo. Nothing on screen.

- `Segment`, `SegmentStore` as above; one per `PaneViewModel`, reset on open,
  close and revert.
- `apply(_:newSize:)` wired to the place `PaneViewModel` already derives the net
  edit, and the snapshot stack for undo/redo.
- Tests (app suite, the store is AppKit-free but lives in the app target):
  - `testAFreshFileIsOnePieceNamedAfterIt`
  - `testACutMakesTwoPiecesAndRenumbersThem`
  - `testACutAtZeroOrEOFIsRefused`
  - `testRemovingACutMergesIntoTheEarlierPieceAndKeepsItsName`
  - `testAnInsertBeforeACutMovesIt` / `testAnInsertAtACutJoinsThePieceThatStartsThere`
  - `testADeleteThatSwallowsACutMergesThePieces`
  - `testADeleteThatEmptiesAPieceRemovesIt`
  - `testOverwritingNeverMovesACut`
  - `testUndoRestoresTheCutsADeleteRemoved` — the case that decides snapshots
    over inverse edits
  - `testTwoCutsAddedInEitherOrderGiveTheSamePartition`
  - `testSegmentContainingIsHalfOpenAtBothEnds`
- Spec: §21.1 (what a segment is) and §21.2 (the model, the following rule, the
  undo rule), with the §20.1 contrast — a mark never moves, a cut always does —
  stated where a reader will meet it.

**Done when** the store is correct under every edit path the app has, and undo
puts it back. Nothing is drawn and no command exists yet.

### Stage 2 — Cuts you can make and see

**Delivers:** ⌥⌘K cuts at the caret, the pieces are tinted in the dump, and the
status bar says which piece the caret is in.

- Commands: **Edit ▸ Add Cut…**, which opens a popover with an **offset** and a
  **description** — the offset pre-filled with the caret's and validated as it is
  typed (§10.1), refusing 0, EOF and an offset another cut already holds. The
  popover is centred in the pane, not anchored to the caret: it is a dialog
  pre-filled with a number, not a pointer at a byte (Split Here, below, is the
  one that anchors to a byte). And **Merge**, which names the piece the caret
  sits in and the neighbour it merges into — *Merge S1 into S0*, not a bare
  *Merge* — enabled whenever the pane has more than one piece (it acts on the
  piece the caret sits in, so it is never "disabled on the first piece" —
  merging S0 reopens the piece below at the file start). No key equivalents:
  both are deliberate acts
  reached from a menu, and the fast path is the one below.
- **Split Here** in the dump's own context menu, on the byte or the address that
  was right-clicked: it opens the same offset-and-description popover Add Cut…
  opens, pre-filled with the address the menu was opened on. This is how a cut
  normally gets made; Add Cut… is for an offset you know as a number rather than
  as a position.
- The segment pair (**Split Here**, **Merge**) sits in the context menu
  as its own block between separators, distinct from the selection and bookmark
  commands, and is the same block whether the menu was opened on a byte or on the
  Offset column's address.
- The popover is the *same* editor that changes an existing cut (stage 3), so one
  panel creates and edits, as one popover does for a bookmark (§20.3).
- `HexViewDataSource.hexSegmentSpans(in:)` answering, for a drawn row range, the
  pieces it touches with their byte ranges and colour indices — asked once per
  range like `hexBookmarkedRows(in:)`, resolved by binary search over `cuts`.
- `HexTheme.segmentTints`: six pastels, resolved per theme, cycled by label.
- `HexView.drawRow` fills the tint **before** everything else it draws: edge to
  edge, the Offset column included, gaps included, a mid-row boundary passing
  through the middle of the gap between the two bytes it separates (the two fills
  meet, no uncoloured slit), and stopping at EOF. The Offset column's addresses
  and the bookmark's mark are drawn on top of the tint.
- Invalidation: `SegmentStore.onChange` → only the rows the changed offsets touch,
  through the existing content-change channel (§13).
- The status bar's segment readout, shown only with two or more pieces.
- Tests:
  - a render test reading the tint in the gap between the two hex groups and in
    the gap before the decoded text — the gaps are the rule, not a side effect;
  - `testTheOffsetColumnIsTinted`, sampling inside it — the band is edge to edge;
  - `testTheMidRowBoundaryLeavesNoPaperSlit` — a cut at byte 5, walking the pixels
    across the gap between bytes 4 and 5, none of them paper; the two fills meet
    at the mid-gap;
  - `testTheBookmarkTipIsDrawnOverTheTint` — a mark on a tinted row keeps its tip
    above the fill;
  - `testADifferenceStillReadsOrangeOverTheTint` and
    `testTheTintShowsThroughADifferencesGaps`;
  - `testASelectionCoversTheTint`;
  - `testTheTintStopsAtEOF`;
  - `testMutedFillBytesStayLegibleOnEveryTint` in both themes — a contrast
    measurement, not a look;
  - `testNeighbouringTintsAreDistinguishable` — a minimum channel distance between
    consecutive entries, in both themes, which is what draws the boundary;
  - `testNoTintIsMistakableForADifferenceOrASelection` — distance from the orange
    fill, the accent and the bookmark purple;
  - the popover's commit making a cut at a typed offset, and its refusals (0,
    EOF, an offset already cut) beeping rather than committing;
  - **Split Here** opening the Add Cut popover pre-filled with the clicked
    address — on a byte and on the Offset column's address alike — anchored to
    that byte, while **Add Cut…** presents the same popover centred in the pane,
    not anchored to the caret;
  - the menu items and their validation, the segment pair set off between
    separators, and **Merge** naming the piece and its neighbour (the
    caret's piece in the Edit menu, the right-clicked byte's in the offset menu);
    a redraw test asserting a cut invalidates its own rows and not the document;
  - `testTheStatusBarNamesTheCaretsPiece` as one block `S1: <start>-<end>
    (length)`, bare hex, and its single-piece silence.
- Spec: §21.3 (the tint, the gaps, the mid-row split, the Offset column's tint,
  the status-bar readout) and the §6 addition to the layering stack.

**Done when** a dump can be cut where you right-click it or at an offset you
type, uncut again, and the pieces are visible while scrolling — under differences
and selections. No form, no strip, no writing out.

### Stage 3 — The Segments form

**Delivers:** the place the partition is read and edited — modal, like Go To.

- `SegmentsFormController`: a **modal window, presented like the Go To form**
  (§10.1) — no new UI pattern, no window bookkeeping, and the same proven
  plumbing. It follows the store through `onChange` exactly as the Go To form
  follows the bookmark store (§20.5), so nothing is duplicated while it is open.

  Modality costs nothing here because nothing in the form needs the dump to move
  underneath it: a cut is made by typing an offset in the popover, not by aiming
  at a row.
- The table: label, start (hex), size, name; ordered by offset; **no editable
  cells** — §20.5's lesson, a field in a row is edited by a click on an
  already-selected row and collides with the double click that activates it.
- The row editor: the popover from stage 2 — **offset** and **description**, the
  offset validated as it is typed (§10.1) and the description opened with the
  piece's current name (so editing a named piece does not open blank), Return
  committing, Esc restoring — opened by a double click on the row or from the
  row's context menu. One panel makes a cut and changes one; moving a cut is
  typing a number in it, deliberately, since cuts do not drag.
- **A `+`/`−` footer under the table**, the way Apple's own tables do it (the
  Target Dependencies pane in Xcode is the reference): a hairline, then two
  borderless small buttons at the left, the same size so `−` does not read as
  a smaller, disabled button — the system `plus`/`minus` symbols, borderless,
  each drawn at its natural size into the same square bitmap (the glyphs have
  different bounding boxes, and a borderless image button sizes to that box) —
  `plus` opens the Add Cut popover, anchored to the
  button itself, with the offset field **empty** (just the `0x` prefix) and the
  caret on it: from the form there is no caret to start from, the offset is the
  thing to be filled in, and an unfilled offset makes no segment. `minus`
  merges the selected **piece** into a neighbour that keeps its name. `−` is
  disabled only when the pane is a single piece (no neighbour to merge into);
  it is enabled on **S0** too, which is merged by re-opening the piece below at
  the file start (what was S1 becomes S0). Icon-only, so both carry a tooltip
  and an accessibility label; `−`'s tooltip and label name the selected piece
  and its neighbour — *Merge S1 into S0* — following the selection. A wider gap
  separates the footer
  from the button row than the table from the footer: the footer is the list's
  own controls, the button row the dialog's.
- **The row's context menu** carries what acts on one piece: *Save Segment…*,
  *Replace Segment from File…*, *Edit…*, *Merge* — the same menu the
  strip beside the map offers (§21.3), so one shape in both places. *Merge*
  names the piece and its neighbour, the way the other menus' items do.
- The dialog's own button row holds only what acts on the whole partition:
  **Merge All** at the left — every cut at once, back to one piece named for
  the file, and it asks before acting — then **Save All as Separate Files…**
  (available only when the dump is partitioned into more than one piece — with
  a single piece there is nothing to separate) and **Close** at the right.
- Keys: ⌥⌘S opens the form (⌘S is Save, ⇧⌘S is Save As, so the form takes the
  Option variant); Return goes to the selected piece's start; ⌫ is `−`.
- Tests: the table's contents against a partitioned pane; the popover's commit
  moving a cut and changing a description, and the description opening with the
  piece's current name; `+` opening the popover with an empty `0x` offset, the
  caret on it, and no segment made while it is unfilled; `−` and `+` borderless
  and the same size, so `−` does not read as a smaller, disabled button,
  disabled on a single-piece pane and enabled on every piece once partitioned
  (S0 included, removing S0 renumbers the piece below to S0); **Save All**
  disabled on a single-piece pane and enabled once partitioned; the wider gap
  between
  the footer and the button row than between the table and the footer;
  **Merge All** asking first and, once confirmed, leaving one piece named for
  the file; the row menu's items, their targets and the piece each carries, and
  Merge naming the piece and its neighbour; the form following a cut made
  elsewhere in the app; Return navigating. (The popover's own validation is
  stage 2's, tested once.)
- Spec: §21.4.

**Done when** the partition can be built, renamed and rearranged entirely from
the form, and the form never disagrees with the dump.

### Stage 4 — Writing pieces out

**Delivers:** the operation the whole feature exists for — a dump written out as
its pieces.

- `SegmentWriter` in `DumpCompareCore`: chunked, cancellable, and **all or
  nothing** — each part to a temporary name in the target directory, fsynced, all
  renamed into place at the end; a failure removes the temporaries and publishes
  nothing (§5.2, and the lesson behind `5bbef2a`).
- **Save All as Separate Files…**: a directory chosen with an open panel in
  directory mode (a save panel grants access to one file and this writes N — the
  sandbox would refuse the rest), a base name taken from the document
  (`bios_S0.bin`, `bios_S1.bin`, …), and a preview listing what will be written:
  `S0 → bios_S0.bin (4 MB)`.
- **Save Segment…** — from the row's context menu or the strip's, never a button:
  it acts on one piece, and the form's button row is for the whole partition. The
  ordinary save panel, one file, pre-filled with `<name>_S<i>.bin`; the panel's
  own replace confirmation covers the overwrite, so no separate one. The save
  panel grants the file, not its folder, so the sibling temp cannot be created;
  with a single part the write falls back to writing straight into the chosen
  file (§21.5).
- One overwrite confirmation, before anything is written: the same dialog that
  previews the parts also names the files that would be replaced (a section that
  appears only when a target exists). A cancel writes nothing.
- Progress and cancel in the status bar for a large write (§14.4).
- Tests: core tests for the writer (the bytes of each part, the atomicity — a
  forced failure on the last part leaves nothing behind and no temporaries — a
  cancel mid-write, a single-piece write, and the single-part fallback into a
  file whose directory is not writable); app tests for the preview's mapping,
  the confirmation's inputs, and that the written content includes unsaved edits.
- Spec: §21.5.

**Done when** a partitioned 16 MB image can be written out as its pieces, and a
failure leaves the directory as it was.

### Stage 5 — The colour strip beside the minimap

**Delivers:** the whole partition at a glance, and the menu that acts on a piece.

- `MinimapView` gains a 4 pt strip to the right of each map, with a narrow gap
  between them, present only when that pane has two or more pieces — a layout
  change of 6 pt per map, touching none of the marker geometry in the margins.
- The strip is painted from the **same** `HexTheme.segmentTints` in the same
  order as the dump, which is what makes it a legend rather than decoration.
- Hover text: `S1 — 0x400000…0xC00000, 8 MB · W25Q…bin`.
- A right-click menu on the block: **Save Segment…**, **Replace Segment from
  File…**, **Select Segment**, **Edit…**, **Merge**.
- A left-click within 4 pt of a cut moves the caret to that cut's exact offset and
  reveals it centred, reusing the snapping the bookmark marks already have
  (`snappedOffset`, §19.6.1) with the cut list as the second source of targets.
  Anywhere else on the strip a click does nothing.
- Tests: the panel's layout with one piece and with three; a render test finding
  the block boundaries at the right heights and the same colours the dump used;
  the gap actually being a gap (nothing painted in it); the hover text in both its
  forms (a piece, and a boundary near a cut); each menu item's target and the piece
  it carries; `testAClickNearACutLandsOnItsExactOffset` with the control that the
  pixel's own row would have given a different answer — the whole point of the
  snap; `testTheNearerCutWins` with two cuts genuinely both in reach;
  `testAClickInTheMiddleOfABlockChangesNothing` (caret, selection and scroll);
  `testAClickAtTheStripsEndsChangesNothing`.
- Spec: §19.4.4 (the strip and its gap) and the rest of §21.3.

**Done when** the partition is legible beside the map in both minimap modes, a
boundary can be reached by clicking it, and every operation on a piece is one
right-click away.

**Done** (2026-08-23): the strip, its gap, the hover text, the right-click menu,
and the click-snap are all in; 11 tests green. §19.4.4 added to the requirements.

### Stage 6 — Replace a piece from a file

**Delivers:** the inverse of Save Segment — the donor-region swap.

- `PaneViewModel.replaceSegment(_:withContentsOf:)`: streams the file in chunks
  into one transaction so undo takes the whole swap back, and requires the file to
  **match the piece's length** — a mismatch is refused with both sizes named,
  because making it an insert-and-shift is a decision, not a default.
- The command from the strip's menu and the form's row menu.
- Tests: the bytes after a swap, one undo restoring them, the refusal message's
  two sizes, and that a swap does not move any cut (the length is unchanged).
- Spec: §21.6.

**Done when** a region can be pulled out, processed and put back without counting
an offset by hand.

### Cost per stage

| stage | | hours |
|---|---|---|
| 1 | the model | 4–5 |
| 2 | cuts you can make and see | 4–5 |
| 3 | the Segments form | 5–6 |
| 4 | writing pieces out | 5–6 |
| 5 | the colour strip beside the map | 4–5 |
| 6 | replace a piece from a file | 2–3 |
| | **total** | **24–30** |

### Order and independence

Stage 1 is the floor; 2 is the smallest thing worth shipping (a dump you can cut
and see the cuts in) and everything after it is additive. 3 before 4, because the
form is where a write is invoked from. 5 and 6 are independent of each other and
of 4 — the strip needs the store and nothing else, and the swap needs only the
edit path. Join (`JOIN_SPLIT_PLAN.md`) needs 1 and 2, and reaches "split" through
4.

### Risks and things to watch

- **Contrast is the whole risk of the tint**, in three directions at once: the
  ink over it (muted `0x00`/`0xFF` at 40 % alpha, which is most of a dump), the
  states drawn on top of it (an orange difference, the accent selection), and the
  neighbouring tint across a boundary. Stage 2's render tests measure all three
  rather than describe them, and the palette is chosen against a real 16 MB pair
  with differences in it — not against a mock-up.

- **`apply` is on the hot path.** It runs for every typed byte in insert mode.
  Cuts are a handful of numbers, so the arithmetic is nothing — but the snapshot
  push must not copy anything expensive, and the repaint it asks for must stay two
  rows, not the document.
- **Labels renumber, file names do not.** `bios_S1.bin` records the label a piece
  had *when it was written*; add a cut before it later and the piece on screen is
  S2 while the file on disk still says S1. That is inherent to positional labels
  and not worth fighting — but the preview should be read as "what is being
  written now", and the form's own copy of a written-out set is not a claim about
  the files in that folder.

## Verification

- `swift test` in `DumpCompareCore` covers `SegmentWriter` only; the store and
  everything visible live in the app suite, as `BookmarkStore` does.
- Manual, once stages 1–4 are in: open an 8 MB dump, cut it at 0x400000, check the
  rule in the offset column and the readout in the status bar; type a byte before
  the cut in insert mode and watch the cut move by one; undo and watch it come
  back; open the form, rename both pieces, move the cut by typing; Save All and
  check the two files' sizes and bytes; delete a range spanning the cut and watch
  the pieces merge; undo.
- After stage 5: the strip on a three-piece 16 MB image in both minimap modes,
  in light and dark, with a bookmark and a difference beside it — the crowding
  test, not the correctness one.
