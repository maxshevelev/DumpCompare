# Zones — an idea, thought through

Not a plan. A zone is a named interval of a dump — a start and an end — living
beside bookmarks, which mark points. This document is what the idea looks like
after taking it apart: where it is strong, the three questions that decide
everything else, what it would cost, and which slice of it is worth building
first if it is ever built.

## What the idea buys

Five uses, in the order I would rank their value.

1. **A map of a dump instead of a wall of hex.** A flash image has structure — an
   Intel flash descriptor, an ME region, GbE, the BIOS region, and inside it
   firmware volumes. A zone tree drawn beside the offset column turns "16 MB of
   bytes" into "here is where ME ends". This is the use that would change how the
   app feels, and it is also the one that needs a parser to be worth much (the
   plugin idea) — a hand-made zone map is a note to yourself; a parsed one is a
   map.
2. **Export and import a region.** "Save this zone to a file" and "replace this
   zone from a file" are the two operations a bench actually performs on a
   region: pull the ME region out to run a tool over it, put the donor's back in.
   Today that is `dd` with offsets counted by hand — the same reason join and
   split are worth building.
3. **Join and split, generalised.** A join creates two zones instead of one
   bookmark, and split becomes "write each zone to its own file" — for two zones
   or for twelve. The zone boundary is a better home for the split point than a
   bookmark's name, because it *is* a boundary rather than a point that happens
   to be remembered.
4. **A document assembled from several files** — zones mapped onto files, with
   the references kept. This is the most powerful item on the list and the one
   that does not belong with the others (see below).
5. **Somewhere to hang per-region facts.** Checksums, "this region differs from
   the donor", "this region is all `0xFF`". Speculative, but the structure would
   be there.

## The split in the idea: annotation vs composition

Uses 1–3 and 5 treat a zone as **annotation over content**: a named range you can
see and act on. That is cheap, orthogonal to everything else, and sits exactly
where bookmarks sit — a per-something store of offsets, drawn in the gutter and
the minimap, with commands that read the range.

Use 4 is not that. "The pane consists of pieces assembled from different files
with the references kept" makes the **document a composition**: a piece table
whose pieces have several base files rather than one. That changes storage, not
presentation, and it drags in a train of questions the others do not raise — what
happens when a referenced file changes on disk, what Save means (write the
composition back to its pieces, or flatten it?), whether the composition itself
is a document you can save (it is a project file, §TODO), what a comparison of two
compositions means.

**These are two features that share a word.** The annotation one is a feature;
the composition one is an architecture. If both are wanted, the annotation one
comes first and stands alone — and it makes the composition one easier to
specify later, because by then the vocabulary exists.

Worth noticing, though: composition would make join nearly free (no 16 MB
materialised, instant) and would make split "write each piece back where it came
from". The `JOIN_SPLIT_PLAN.md` round trip would collapse into two commands over
one model. That is an argument for keeping the join/split plan's model boundary
clean, not for waiting.

## Segments are not zones: a partition, not a sparse set

The join/split work needs a **partition**: pieces that are contiguous, do not
overlap, and cover the file completely, so that N pieces are N−1 cuts and the
whole thing is an ordered list of boundaries with names. Nothing can be missing
and nothing can double up, *by construction* rather than by validation, and every
file has at least one piece — itself.

Zones are a **sparse set**: named intervals that may sit anywhere, leave gaps
between them, and nest. That is what a parser produces (the BIOS region contains
volumes contain files) and what a hand-made annotation is.

The two are different structures, not one with a flag, and the operations tell
them apart: "write one file per piece" makes sense only over a partition, because
gaps would silently vanish; "here is the ME region" makes sense only as a sparse
interval, because the rest of the file is not a region of anything. They coexist
cheaply — zones nest inside segments and neither has to agree with the other — and
they would share the drawing machinery, not the model: the partition reads as a
ribbon along the map's edge (`JOIN_SPLIT_PLAN.md`), the zones as brackets in a
gutter.

Which leaves three objects, with three rules, answering three questions:

| | bookmarks | segments | zones |
|---|---|---|---|
| what it is | a point | a partition | sparse named intervals |
| whose | the window's | the pane's | the pane's |
| under an edit | never moves | follows the content | follows the content |
| made by | the user | a join (later: a cut) | a parser, or the user |
| answers | "come back here" | "what is this image made of" | "what is this part of the image" |

## The three questions that decide everything

### 1. Do zones follow edits, or are they absolute?

Bookmarks were just settled: absolute, and nothing shifts them. For a *point*
that is defensible — a mark is an address you care about. For a *span* the
pressure is much stronger the other way: a zone's end is what makes it a zone,
and "save this zone to a file" must export the right bytes. One inserted byte
before a zone and every zone after it is silently wrong, which for an export is
not an annoyance but a corrupted output.

Three answers, and the choice has to be made before anything is drawn:

- **Absolute, like bookmarks.** Consistent, trivial, and honest only if the spec
  says out loud that a length-changing edit invalidates the map.
- **Absolute plus a warning.** A length-changing edit while zones exist offers to
  drop the map or shift it. Cheap, and it never lies. Probably the right first
  answer.
- **Anchored** — offsets shift with insertions and deletions before or inside
  them. The honest model for spans, and real work: every edit path has to
  maintain it, undo has to restore it, and a delete that straddles a boundary
  has to decide what happens to the zone (shrink, or die).

In a dump workflow, length-changing edits are the exception — you patch bytes in
place; insert mode exists for the odd case. So absolute-plus-warning looked like
a fair reading of the work.

**Then the join case settled it: anchored.** Two joins in a row are ordinary —
append B to A, then insert C at the start — and the second one moves the first
seam. A mark cannot survive that and should not try (bookmarks are absolute by
decision, §20.1, because a mark is an address the user chose); a zone must,
because it is the edge of a stretch of content and content moves. So the two
objects have *opposite* update rules, which is the strongest argument yet that
they are two objects and not one with an extra end.

Anchoring is also cheaper than it looked from here. The document already computes
a **net edit** for every transaction, and the comparison index and the minimap
both consume it (§8.3). Zones update from the same description, in one place,
and undo restores them with everything else. That is why `JOIN_SPLIT_PLAN.md`
now carries the model — segments created by joins — rather than a bookmark at the
seam: the small end of this idea has a user already.

### 2. Whose are they — the window's, or the pane's?

Bookmarks are the window's, because comparison is by absolute offset and a mark
means the same height in both panes (§20). Zones are not like that: a parsed
region map describes *this file's* structure, and the other pane holds a
different file whose ME region starts somewhere else. A zone map shared between
two dumps would be wrong exactly when it mattered.

So: **zones belong to a pane**, and that is a real difference from bookmarks, not
an inconsistency. It follows that the two panes can show two maps, that swapping
panes swaps the maps, and that closing a file drops its map. It also means zones
are *not* "bookmarks with two ends" — a tempting unification that would have to
break either the bookmarks' window scope or the zones' per-file meaning.

### 3. Can zones overlap?

Parsers produce **trees**: the BIOS region contains volumes contain files. So
nesting is required. Partial overlap (two zones crossing without one containing
the other) is what no parser produces and what no gutter can draw legibly —
forbid it, and the rendering problem becomes tractable: indent by depth.

## What it costs on screen

This is the part I would want to see before writing any of it.

- **The gutter.** Brackets go left of the offset column, which means the grid
  moves right and the window's fitted width grows (§3.1 launch width, Window ▸
  Zoom). Budget: one level ≈ 8 pt. Three levels of nesting is 24 pt of dump
  width gone. The gutter should exist only when the pane has zones, and deeper
  levels should live in the list rather than the gutter.
- **The minimap margin is already full.** It carries the viewport marker and the
  bookmark arrows in 10 pt (§19.4.3, §19.6). A zone bracket is a third thing in
  the same strip. Either the margin widens for zones, or zones get the *other*
  margin (the map has two), or the bracket draws over the map's edge rather than
  beside it. Each of those is a legible answer; none is free.
- **A third list.** Bookmarks live in the Go To form (§20.5). Zones need their
  own list with a tree, and the honest place for it is a sidebar rather than a
  modal — which is the first thing in this app that would want one.

## The slice worth building first

If zones happen, this is the smallest version that is useful on its own:

- A zone is a per-pane named half-open range; zones nest but never partially
  overlap; **offsets follow the content** — a length-changing edit moves the
  zones after it and resizes the one it happened inside, from the document's net
  edit. (`JOIN_SPLIT_PLAN.md` builds exactly this much.)
- **Create from the selection** (the gesture already exists — select a block,
  name it) and from a join.
- **Save Zone to File…** and **Replace Zone from File…**, the latter requiring
  the file to match the zone's length in v1 (a length mismatch is a structural
  edit and wants its own dialog).
- One level of brackets in the gutter, and a zone list with the tree.
- No composition, no plugins, no per-zone facts.

Rough cost: 20–30 hours, most of it in the gutter, the list and the edit rules —
the model itself is small. Composition is a comparable amount again; a parser
plugin is its own project, and the interesting half of that is the plugin
boundary, not the parsing.

## What I would not do

- **Do not fold bookmarks into zones.** A zero-length zone is not a bookmark:
  bookmarks are row-granular and window-wide by decision, zones byte-granular
  and per-pane by necessity. Two concepts, two stores, one word each.
- **Do not build the *whole* of zones to serve join/split** — but the model does
  belong there. Join/split needs named ranges that follow the content, and it
  needs them for correctness, not polish (a bookmark at the seam is wrong after
  the second join). So that plan carries the store and nothing visible: no
  gutter, no minimap bracket, no tree. The chrome waits for this document's
  screen budget to be settled, and inherits a model with tests and a user.
- **Do not start with the parser.** The map is the payoff, but a parser that
  produces zones is only worth writing once zones can be seen, edited and
  exported by hand. Otherwise the first thing to debug is two new things at once.
