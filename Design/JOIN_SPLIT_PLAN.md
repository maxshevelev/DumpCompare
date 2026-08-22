# Join — bringing a second chip's dump into a pane

> The mechanism this stands on is `SEGMENTS_PLAN.md`: a dump as the pieces it is
> made of. Segments are the base feature and are useful without any of this;
> joining is how a *file* becomes a piece, and "split the file" is that plan's
> **Save All as Separate Files**. This document is the two-chip workflow and the
> part of it that is only about bringing another file in.

## Why

On plenty of boards the BIOS region is physically two SPI flash chips. The bench
workflow is:

1. read chip 1 and chip 2 — two files with whatever long technical names the
   programmer gave them;
2. **join** them into one image, in the right order;
3. save that image, and hand it to the tools that expect a whole BIOS — an ME
   region update, a BIOS parameter editor, a donor comparison;
4. come back with the processed image and **split** it at the same boundary;
5. flash each half back to its own chip.

Steps 2 and 4 are the ones DumpCompare cannot do today, and they are the reason
the whole round trip currently happens in `dd` and a notebook page of offsets.
Everything between them — comparing, searching, patching — the app already does
better than the alternatives.

## What it adds

Two commands, plus the drop bands that make them a gesture.

- **File ▸ Append File…** — the chosen file's bytes go after the pane's content.
- **File ▸ Insert File at Start…** — they go before it.

Both also sit in the pane's own menu (right-click the pane header), acting on that
pane rather than the active one, beside the file-scoped commands already there
(Save, Save As, Revert, Show in Finder, Close). Both are enabled only when the
pane holds a file — with nothing open, the command is Open.

Two commands rather than one with a start/end choice in a dialog: the gesture is
common and should not stop to ask which end.

## The joined document is not the file it came from

**Decision: a join detaches the pane from its file.** The pane ends up holding a
document with no URL: dirty, never saved, and ⌘S opens a save panel rather than
writing 16 MB over the 8 MB dump it was opened from. Both source files stay untouched on disk. This
is the whole point — the joined image has a different internal structure from
either half, and an accidental ⌘S in an 8 MB dump's window is exactly the kind of
mistake that costs a re-read of the chip.

Three consequences, all of them deliberate:

- **The join is not undoable.** ⌘Z would have to re-attach the document to the
  file it left, which is not a state the model has. So a join is a
  document-level act like Open or New File: the undo stack is empty after it,
  and edits made afterwards undo as usual.
- **A dirty pane is warned about, with two buttons: Cancel and the operation.**
  Every dialog this feature adds has that shape — *Cancel* and *Append*, *Cancel*
  and *Insert*, *Cancel* and *Replace* — and none of them offers to save on the
  user's behalf. Deciding what to do with unsaved bytes is the user's business,
  and Cancel puts them back exactly where they were to do it: ⌘S is one keystroke
  away, and so is Save As.

  What the alert must still say is what the action means, because there is a real
  ambiguity to settle: the join takes **the content the pane shows, edits
  included**, and the file on disk keeps its saved bytes. Nothing typed is lost —
  but a patch that never reached `W25Q…bin` still has not reached it, and after
  the join no document is attached to that file to save it from. So the alert
  names the file, says the edits travel into the joined image while the file
  keeps its own, and offers Cancel.

  An **untitled** dirty pane gets no alert at all: there is no saved state to
  diverge from, and its content is carried like any other.

### Naming: the joined document is Untitled, and that is the honest answer

There is nothing to derive a name from. A dump straight off a programmer is
called something like `W25Q128FV_20260821_1a2b3c4d.bin` — chip model, date,
checksum — and neither half's name says anything about the pair. Deriving
`W25Q128FV_20260821_1a2b3c4d-joined.bin` would be a long name that is now also
wrong: the chip and the checksum in it describe half of what the file holds.

So the joined document is **Untitled**, like any document the app made rather
than opened, and the user names it when they save it — which in this workflow
happens immediately, because the whole point is to hand the image to another
tool. The save panel pre-fills what an untitled document always pre-fills.

**No name is derived from the sources, in any case.** An earlier draft proposed
the common stem when the two file names differed only by a trailing segment label
or digit — `bios_S0.bin` + `bios_S1.bin` → `bios.bin` — on the grounds that join
and Save All should be inverses. That rule is dropped, for three reasons worth
recording so it is not re-invented:

- **It can lie.** The order of the pieces is the *user's* — which command was
  invoked, or which band the file was dropped on — and nothing about the names
  constrains it. Joining `bios_S1.bin` and then `bios_S0.bin` produces content
  that is not `bios.bin`, and the panel would still have proposed `bios.bin`.
- **The round trip does not need it.** Writing the pieces out names them from the
  base name and their labels (`base_S0.bin`, `base_S1.bin`), so the inverse is
  exact whatever the joined document was called. The rule was buying something
  already paid for.
- **It almost never fires.** A dump off a programmer is
  `W25Q128FV_20260821_1a2b3c4d.bin`; two of those share no stem. The only case it
  served was re-joining files DumpCompare itself wrote — where the user knows the
  name they gave them.

So the save panel offers what an untitled document always offers, and the user
types the name. Order comes from the command, never from a file name.

### Where "what am I looking at" actually lives

An Untitled header says nothing about the two dumps behind it, and with names
that long it could not say much anyway. Two places carry it instead:

- **The join bookmark** keeps the second file's name (below), which is the
  durable record of which half came from which chip — exactly the thing you must
  not guess at flashing time. A long technical name costs nothing there.
- **A transient status-bar line** right after the join names both sources and the
  total size, the way the app already reports "No match found." and then yields
  the stats back (§14).

## The seam is a cut

A join creates a **cut** and names the pieces either side of it: the content the
pane already held keeps the name of the file it was opened from — remembered even
after the document detaches — and the joined bytes take the name of the file they
came from. Two joins in a row therefore leave three pieces with the right offsets,
which is exactly what a bookmark at the seam could not do: bookmarks are absolute
by decision (§20.1) and an insert at the start moves the first seam. Everything
else about cuts — that they follow the content, how they are drawn, how they are
edited and written out — is `SEGMENTS_PLAN.md`.

Two consequences worth stating here:

- **A join needs no new chrome.** The tint, the strip and the status-bar
  readout all come from the segments feature; a join just adds a cut.
- **Row alignment stops mattering.** A cut is a byte offset, so a join whose
  boundary is not a multiple of 16 is simply a boundary — the cut line steps
  through the row, per that plan. Which is not a corner case: a dump's size need
  not be a multiple of 16, and any insert of a length that is not moves every
  later cut off the grid.

## Dropping a file to join it

Today a drag over a pane already offers two targets in single-file mode —
**Replace Current File** and **Open as Second File** — split along the current
pane arrangement (§4.3). Joining adds two more, so the geometry has to be
deliberate rather than "two more strips somewhere".

**Single-file mode.** The existing axis split stays: half the window is about
*this* file, half is about a second file. The "this file" half is then divided
into three horizontal bands:

```
┌─────────────────────────┬──────────────────────┐
│  Insert at Start        │                      │
├─────────────────────────┤   Open as            │
│  Replace Current File   │   Second File        │
├─────────────────────────┤                      │
│  Append at End          │                      │
└─────────────────────────┴──────────────────────┘
        (side-by-side arrangement shown)
```

The two join bands are strips at the top and bottom, sized 25 % of the half's
height each and clamped to 48…120 pt so they stay hittable in a short window and
do not swallow the middle in a tall one. In the stacked arrangement the same
three bands divide the top half — worth looking at on screen, because the
"Append at End" strip then sits directly above the "Open as Second File" target
and the two need to read as separate things.

**Comparison mode.** Each pane takes the three bands (insert / replace / append)
and there is no second-file target — both panes are occupied.

Feedback follows the existing drop targets: the band under the pointer highlights
and shows its title; the others stay quiet. A drop outside any band, or a drag
that leaves the window, changes nothing.

Rules that fall out:
- With an **empty pane** there is nothing to join to: the whole pane stays the
  single "Open" target it is today.
- **Several files dropped** on a join band: the first is used and the rest are
  ignored with the standard notification (§4.1 rule 3). Joining a list in one
  gesture is a plausible feature and deliberately not this one.
- Directories and packages are refused as they are now (§4).
- Dropping the file that is **already open in the pane** onto a join band is
  allowed and doubles the content — two identical chips are a real case.

## Splitting is a segments operation

Once the pane is partitioned, "split the file" is **Save All as Separate Files**
in the Segments form — the directory picker, the base name, the `_S0`/`_S1`
suffixes, the temp-and-rename atomicity and the overwrite confirmation are all
specified there. Nothing in this feature needs to add a split command of its own,
and the round trip generalises from two chips to however many without another
line of code.

What the workflow adds is only the expectation that it survives a restart: after
step 3 above the image is an ordinary file and its partition is gone, because
segments are session-scoped like bookmarks. So the boundary has to be re-entered
once — **Add Cut at Caret** after a ⌘G to the offset — before the pieces can be
written. That is the same limitation bookmarks have, it has the same answer (a
project file, TODO), and it is worth writing down rather than discovering.

## Edge cases

| case | behaviour |
|---|---|
| Pane empty | Join commands disabled; the drop area stays a single "Open" target |
| Pane holds an untitled document | Join allowed — content is content, and the result is untitled either way |
| Source file is read-only | Join allowed — it never writes to the source |
| Joining a 0-byte file | Refused with a message; no bookmark, no dirty state |
| Joining a file into itself | Allowed, doubles the content |
| Joining a 1 GB file | Chunked, progress, cancellable; memory bounded by the add-buffer budget (§13) |
| Pane was dirty before the join | A warning naming the file, with Cancel and the operation's own verb; the action carries the edits into the joined image and leaves the file's saved bytes alone |
| Pane was dirty and untitled | No warning — nothing on disk to diverge from |
| Bookmarks made before an insert at start | Left where they are: a mark is an absolute offset (§20.1) and nothing shifts it — the seam is a segment precisely so that it is not subject to this |
| Two joins in a row (append, then insert at start) | Three segments, all with the right offsets; the split sheet offers three files |
| Comparison mode | A join changes one pane's length; the comparison re-indexes and the shorter file's tail reads as an EOF difference (§9) — no special case |
| Caret and selection on an insert at start | Both shift by the inserted length, so they stay on the bytes they were on |

## Implementation plan

This assumes `SEGMENTS_PLAN.md` stages 1–2 are in (a store that follows the
content, and cuts you can see). What is left is bringing a file in.

**Stage 0 — spec (1 h).** §21 in `Design/REQUIREMENTS.md`: the two commands, the
detached document and its Untitled identity, the cut a join creates, the drop
bands (§4.3 amended).

**Stage 1 — the model (3–4 h).** `BinaryDocument.join(contentsOf:at:)`: streams
the source in chunks into the overlay so a 1 GB file is not read into memory, one
transaction, and detaches the URL. Core tests: join at 0 and at EOF, an empty
source, a source larger than the add-buffer budget, the content correct at the
seam, the document reporting itself never-saved.

**Stage 2 — commands (3–4 h).** `PaneViewModel.join(url:at:)`: the dirty-pane
warning (Cancel and the operation's own verb), the caret and selection shift on an
insert, the cut and the two segment names, the transient status line naming the
pieces. The two File-menu items and their pane-menu twins, with menu validation.
App tests including both answers to the warning and the two-joins-in-a-row case.

**Stage 3 — drop bands (4–5 h).** The three bands inside the pane's half of the
drop overlay, their labels and highlight, hit-testing at the clamped sizes, and
the comparison-mode case. Tests: which band a point maps to at several pane
heights, that a band maps to the right command, that an empty pane offers only
Open, and that extra files are ignored with a notification.

**Stage 4 — polish (2–3 h).** "Open the pieces in the two panes" after a
Save All; progress for large joins; README and release notes.

Total ≈ 13–17 hours on top of the segments feature, and the stages stand alone:
after 1–2 the round trip works from the menus, 3 makes it a gesture.

## Where this sits among the three

- **Bookmarks** (§20, built): points the user chose, absolute, the window's.
- **Segments** (`SEGMENTS_PLAN.md`, the base of this): the partition, following
  the content, the pane's. A join adds a cut to it.
- **Zones** (`ZONES_IDEA.md`, an idea): sparse named intervals, possibly nested,
  what a parser would produce. Independent of both; would share drawing
  machinery, not the model.

## Decisions taken

- **Two commands, not one with a dialog.** Insert at Start and Append at End are
  separate items, so the common gesture never stops to ask which end.
- **Segments are the base feature, not part of this one.** They are useful on
  their own — cutting and writing out pieces of a dump needs no second file — and
  building them first means join is a small layer rather than a feature carrying
  a model it half-needs. It also means split is not a command here at all.
- **Bookmarks never shift**, and the seam is therefore not a bookmark: it is a
  segment, which does follow the content. Two objects, two rules, and the second
  join is the case that proves both.
- **Persistent bookmarks are out of scope**, and probably not the right shape
  anyway: the thing that wants saving is a *project* — the marks, the pane
  arrangement, what was open, maybe the comparison — and that is worth doing when
  the need is real rather than inventing half of it here. Until then the split
  sheet's offset field is what carries a boundary across a restart, which is why
  it is typable and not a bookmark picker alone.
- **Two buttons everywhere in this feature: Cancel and the action.** No dialog it
  adds offers to save for the user — Cancel returns the pane untouched, and what
  to do with unsaved bytes is decided there. The action button carries the
  operation's own verb (Append, Insert, Replace) rather than a generic Continue.

  This is a rule for the dialogs this feature adds. The prompts that **destroy**
  unsaved work are left as they are: closing a dirty file and replacing a dirty
  pane's file still offer Save / Don't Save / Cancel (§3.6, §4.1 rule 4), because
  there the document is going away and macOS offers Save at exactly that moment.
  The difference is real: a join keeps every byte the pane holds, so there is
  nothing to save *from*, only a decision whether to go on.
