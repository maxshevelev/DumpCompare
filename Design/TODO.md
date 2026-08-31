# TODO — ideas waiting for their turn

A notebook, not a tracker. Anything worth building but not worth interrupting the
current branch for goes here, with enough written down that picking it up later
does not mean re-deciding it from scratch.

**How to use it.** Three buckets by intent — *Next*, *Later*, *Someday* — and an
entry moves between them freely; a bucket is a decision about order, not a
promise. An entry that gets built moves to **Done** with the commit or the branch
that did it, so the next reader can see where the reasoning ended up. An entry
that turns out to be wrong is deleted with a line saying why, in Done.

Each entry says **what**, **why**, and enough **how** to start: the shape of the
solution, what it touches, and what it would cost. Rough hours, not estimates to
be held to — they are there to tell a half-day from a week.

---

## Next

### Segments — a dump as the pieces it is made of

**What.** A partition of a pane's content: contiguous named pieces covering the
file, cut where the user says. A cut line between rows in the offset column, a
pale tint behind the bytes of each piece — gaps included, the Offset column left
alone — a colour strip beside the minimap that reads as its legend, the caret's
piece in the status bar, and a form where the partition is edited and written out:
one file per piece, or one piece to a file.

**Why.** It is the model the two-chip round trip needs (see below), but it stands
on its own: "write these 4 MB out", "put the donor's region back", "where does
this half end" are bench operations that today need `dd` and hand-counted
offsets. And it is the honest shape for the thing a join produces — a bookmark at
a seam is wrong after the second join, because a mark is an address and a seam is
the edge of content that moves.

**How.** `Design/SEGMENTS_PLAN.md`, six stages. Model first (it follows the
content, updated from the net edit the comparison index already consumes), then
the tint and the status bar, then the form, then writing out, then the strip,
then replacing a piece from a file. No dragging of cuts and no click-to-select in
the margin — deliberately, because the segmentation is what the round trip depends
on and a slipped mouse must not be able to move it.

**Cost.** 24–30 hours over six stages, each ending with the app working: the
model, cuts you can make and see, the form, writing pieces out, the ribbon,
replacing a piece from a file. Stages 1–2 are useful alone.

### Join a second chip's dump into a pane

**What.** Append or insert a whole file into a pane — from the File menu, the
pane's own menu, or by dropping it on a band at the pane's top or bottom edge —
and split a pane's content back into two files at a chosen offset. A join marks
the boundary with a bookmark; a split writes `name_1.bin` and `name_2.bin`.

**Why.** On many boards the BIOS region is two SPI flash chips, so the bench
workflow is: read both, join them in the right order, hand the whole image to the
tools that expect one (an ME region update, a BIOS parameter editor, a donor
comparison), then split it back at the same boundary and flash each half. Steps
one and four are the only part of that round trip DumpCompare cannot do, and they
are why it currently happens in `dd` with the offsets written on paper.

**How.** **`Design/JOIN_SPLIT_PLAN.md`**, a layer on the segments feature above —
a join is how a file becomes a piece, and "split the file" is that feature's Save
All as Separate Files, so this plan adds no split command at all. The joined document
detaches from its source file (so ⌘S can never overwrite an 8 MB dump with a
16 MB image) while keeping the file-backed base, so joining two 1 GB images does
not mean 2 GB of RAM; it is Untitled, because a dump off a programmer is called
`W25Q128FV_20260821_1a2b3c4d.bin` and half of that name would be a lie about the
joined file — what the halves were is kept in the join bookmark instead; the split
sheet takes an offset — a bookmark fills it in, but it stays typable, because
bookmarks live only as long as the window and the round trip through external
tools can include a restart; and both output files are written to temporaries and
renamed together, so a failure publishes neither.

**Cost.** 13–17 hours on top of the segments feature — the model, the commands,
the drop bands, polish. The design decisions are settled (they are listed
at the end of the plan): two commands rather than one with a dialog, bookmarks
never shift, and a dirty pane gets one warning with Cancel and Continue.

### Instant hover callouts, the way Xcode shows them

**What.** A small floating capsule — text on a rounded background with a shadow —
that appears the moment the pointer reaches something worth naming and vanishes
the moment it leaves. First use: a bookmark's mark in the minimap margin, which
today shows `offset: name` as a system tooltip (§19.4.3). Second: a marked row's
address in the dump, which shows the bookmark's name the same way (§20.3).

**Why.** The system tooltip is the wrong instrument for a mark you sweep the
pointer across. It waits a second or two before appearing, and the delay is not
adjustable — there is no public API for it, and `NSToolTipManager` is private. On
a map where a dozen marks sit within a few hundred points, "point at each in turn
to see what it is" is exactly the gesture, and a delay per mark makes it unusable.
A callout that tracks the pointer turns the margin into something you can read.

**How.** Nothing in AppKit does this — Xcode's callouts are Xcode's own. Two
shapes are available:

1. **An overlay view in the window** — the capsule added over the content, above
   everything else. No extra window, so no ordering, no focus, no multi-screen
   edges; the cost is that it cannot leave the window, which for the minimap's
   margin is fine (the callout opens inward).
2. **A borderless `NSPanel`**, which is what Xcode uses. Needed only if a callout
   must overhang the window's edge, and it brings back the window bookkeeping.

Start with the overlay. The mechanics are the same either way: an `NSTrackingArea`
over the strip that holds the marks (`mouseEntered` / `mouseMoved` /
`mouseExited`), rebuilt in `updateTrackingAreas`, plus explicit hiding for every
event after which the callout would be lying — a scroll, a render-mode switch, the
bookmark list changing, a mark being dragged, the window going inactive. That last
list is where this kind of thing usually breaks, so it is where the tests go.

Worth making the capsule reusable from the start (one small view class, a
`show(text:near:)` / `hide()` pair), because the dump's marks want the same
treatment and the difference navigation may later.

**Touches.** `MinimapView` (tracking + what is under the pointer — it already
answers that for the tooltip, `bookmark(atMarkPoint:)`), `HexView` for the second
use, one new view class, and the §19.4.3 / §20.3 spec lines that currently say
"tooltip".

**Cost.** 3–5 hours for the minimap alone, with tests and spec; 1–2 more to make
it reusable and move the dump's name tooltip onto it. The risk is all in the
hiding rules, not in the drawing.

**Not urgent because** both places already say what the mark is; this is the
difference between information you can get and information you can sweep.

### Highlight search matches in the dump

**What.** Show *every* occurrence of the current search pattern in the hex dump —
a background behind the matching bytes, in both the hex and the decoded-text
columns — not just the one match Find Next moved to. Cleared when the Find bar
closes or the pattern changes.

**Why.** Today a search says "here is one match" and, through Search All, "here
is a list of them" (§11). Neither says *what the neighbourhood looks like*, which
is the question on a dump: a signature that repeats every 0x1000 bytes, a padding
run broken in one place, a table of pointers where one entry differs. Seeing the
matches where the bytes are turns a search from navigation into a reading of the
file's shape.

**How.** The dump is virtualized and pulls its byte states per visible row range
(`hexByteStates`), which suggests the cheap shape: **search the visible window as
it draws**, rather than keeping a global index. A window is a few hundred bytes,
the pattern is short, and the scan is the same `SearchEngine` code the Find bar
uses — no index to invalidate on an edit, and nothing to keep in step with a
scroll. Matches crossing the window's edges need the window widened by the
pattern's length either side.

The alternative is to reuse Search All's ranges when it has run, which gives the
count for free but has to be invalidated on every edit and only covers a search
that was run *as* Search All. Probably both, eventually: the visible-window scan
as the mechanism, the Search All list as the thing that answers "how many".

Colour: AppKit has a semantic `NSColor.findHighlightColor`, which is what the rest
of the platform highlights a search hit with — worth using rather than inventing a
yellow. It must layer with what §6 already draws: difference is a background,
modified is red ink, selection is a background, the caret is a bar. A match is
also a background, so the layering question is real and belongs in the spec before
the code: probably match *under* selection (a selected match still reads as
selected) and *over* difference, since a match is what the user just asked about.

**Touches.** `HexView.drawRow` and its state plumbing, `PaneViewModel` (the byte
states it answers with), the Find bar for "what is the current pattern", §6 for the
layering rule and §11 for the search behaviour.

**Cost.** 4–6 hours: the drawing is small, the layering rule and its render tests
are most of it, and the visible-window scan wants a test that a match straddling
the window's edge is still highlighted.

### Navigation history — back and forward through the file

**What.** A stack of the places the caret has been *sent*, and two commands to
walk it: Back and Forward. Every jump the app makes on the user's behalf — a typed
offset (§10.1), a bookmark, a difference (§10.3), a search result, a click on the
minimap — records where it came from, so returning is one keystroke instead of
remembering an address.

**Why.** Reading a dump is a series of excursions: you are looking at the EC table,
a difference three megabytes away catches your eye, you go and look — and then you
want *back*, exactly back, not "roughly where I was". Bookmarks answer the planned
version of this (a place worth returning to more than once); history answers the
unplanned one, which is most of them.

**How.** A small pure model — `NavigationHistory`: a back stack, a forward stack, a
cap (50 is plenty), and the rule that walking the history does not itself record
anything. AppKit-free and byte-free, so it is unit-testable the way `BookmarkStore`
is.

The interesting decision is **what counts as a jump**, and the answer that keeps
this honest is *only what already goes through one place*: `MainViewController`'s
`goTo(offset:)` and the other explicit reveals (diff navigation, a search result,
a minimap click). Arrow keys and scrolling must not record — a history that fills
up as the caret walks a row at a time is a history nobody can use. If that turns
out to be too strict in practice, the next rule to try is "record when the new
position is more than a screenful from the last recorded one", not "record
everything and coalesce".

It lives on `WindowViewModel`, not on a pane: a jump moves *both* panes of a
comparison (§10.1), so the position it records is one absolute offset, and Back
puts both panes back.

Commands and keys: **Back** and **Forward**, probably in a Navigate menu with the
diff-navigation commands. Xcode uses ⌃⌘← / ⌃⌘→ for exactly this, Safari ⌘[ / ⌘];
one has to be picked, and the arrows read better next to the diff navigation's own
⌥⌘←/→. Disabled when the stack is empty, like every other navigation command.

**Touches.** `WindowViewModel` (the history), `MainViewController` (recording at
the jump, the two commands, menu validation), `MainWindowController` (the menu),
and §10 for a new subsection.

**Cost.** 4–6 hours. The model and its tests are quick; the judgement is all in
what records and what does not, and that is where the tests should be pointed —
a jump records, an arrow key does not, walking back does not record, a new jump
clears the forward stack.

---

## Later

### Dragging panes, and a drop zone for a new tab

**What.** Three gestures over machinery tabs already built: drop a file on a
strip at the top of the window to open it in a new tab, drag a pane by its
header onto the other pane to swap them, and drag it onto another tab (the tab
bar spring-loads, so hovering one switches to it mid-drag) to move it there.

**Why.** Each of the three exists as a command and none of them is what the hand
reaches for: opening a dump in a new tab is two steps, moving a pane is a menu
item or a dialog answer, and swapping two panes that are side by side is
`View ▸ Swap Panels`.

**How.** Taken apart in **`Design/PANE_DRAG_PLAN.md`**. The short version: the
drag adds no model operations — swap, move and tear-off are all implemented and
tested already — so it is a second way to reach four verbs, not a second
implementation of them. What is genuinely new is that the app has never begun an
`NSDraggingSession`: every drag it handles today is a Finder file drop or a mouse
track inside one view. The system tab bar cannot host a drop zone, so the New Tab
strip lives at the top of our own content and takes its height off the pane
bands, with `DropBandLayout` gaining a top inset so the two never disagree about
who owns a point — AppKit picks a drop destination by frame among registered
views, which has silently eaten a dropped file here once before.

**Cost.** Four steps: identity and the pure drop-meaning function; swap by drag
(which builds the whole session mechanism on the case that never leaves the
window); the strip for files, shippable alone; then the strip and other tabs for
panes.

### Split the minimap into layers

**What.** `MinimapView.swift` is ~2500 lines and grows with every feature that
wants a mark on the panel. Break it into layers — dump, bookmarks, segments,
viewport — each a module owning its own drawing, damage geometry, hit-testing and
data intake behind one protocol, over a shared index guide that keeps them on a
single offset axis. `draw()` collects from the layers in order, and that order is
both the z-order and the hit-test priority.

**Why.** Working on one minimap feature today means navigating the whole file:
its drawing, its dirty rectangles, its click handling and its setter sit hundreds
of lines apart, and each re-derives the same byte↔pixel geometry. The goal is to
make a change to one feature a change in one file.

**How.** Taken apart in **`Design/MINIMAP_LAYERS_IDEA.md`** — not a plan. The
short version: the valuable half is *not* `draw()`, which is already the tidiest
part of the file. It is (a) extracting `MinimapGeometry` as a pure, AppKit-free
value type — the minimap's missing equivalent of `HexLayout`, and the reason its
byte↔pixel mapping can only be tested through a window today — and (b) giving
each layer all four of its obligations, not just the drawing. Four things leak:
the viewport band spans both maps rather than belonging to one, the divider
yields to the band, `renderMode` is an axis perpendicular to the layers, and
overview is a stateful subsystem (a model the controller owns) rather than a
layer. The same move does **not** belong in `HexView` — its painting order is
nested inside a single row traversal, and it already has its index guide.

**Order.** Geometry first (behaviour-preserving, tests untouched), then a pilot on
bookmarks alone, then a decision. The render tests assert against the view's
internal surface, so everything past step 1 rewrites them layer by layer — which
is the argument for piloting on one feature.

**Cost.** 6–10 hours for the geometry, 4–6 for the pilot, 15–20 for the rest if
the pilot earns them. The geometry step stands alone and is worth doing whatever
is decided about the rest.

---

## Someday

### View, interactor, coordinator — reasoning, not an entry

**Not a task, and deliberately in Someday rather than Next.**
`Design/VIEW_INTERACTOR_PROPOSAL.md` weighs a division of roles — view /
interactor / coordinator, one pair per surface, the interactor pure logic with no
AppKit — for applicability to an AppKit app, with this one as the evidence, and
then sets out how the pair would be built: ownership (the view owns the
interactor, which holds the view weakly), the `Actions` / `DisplayOutput` pair,
validation from the last rendered state, assembly, lifecycle and teardown.

It reaches verdicts per role — view and interactor fit, and fit better on macOS
than on iOS; coordinator barely applies, because the system owns tabs and there is
no navigation stack — and it counts what the current shape costs: 5484 lines and
61 properties in one controller, 33 of 79 test files standing up an `NSWindow`,
264 pure-logic tests in 3.1 s against 969 view-bound ones in ~100 s.

It proposes nothing. If it is ever acted on, the questions it ends with are what
would have to be decided first.

### Zones — named intervals of a dump

**What.** A zone is a named half-open range, living beside bookmarks: they mark
points, zones mark stretches. Drawn as brackets in a gutter beside the offset
column and on the minimap, listed in a tree, exportable to a file and
replaceable from one. Later, possibly: a document assembled from zones mapped
onto several files, and zone maps produced by a parser plugin.

**Why.** A flash image has structure — descriptor, ME, GbE, BIOS region,
firmware volumes inside it — and the app currently shows none of it. A zone map
turns 16 MB of hex into something with landmarks, and "save this zone" /
"replace this zone from a file" are the two operations a bench performs on a
region that today need `dd` and hand-counted offsets.

**How.** Thought through in **`Design/ZONES_IDEA.md`** — not a plan, a taken-apart
idea. The short version: the concept splits into *annotation* (a named range you
see and act on: cheap, orthogonal, useful alone) and *composition* (the pane
assembled from pieces of several files: an architecture, not a feature), and only
the first should be built first. Two of the three deciding questions are answered
already: zones belong to the pane (unlike bookmarks, because a parsed map
describes *this* file), and they **follow the content** — the join/split case
settled that, and `JOIN_SPLIT_PLAN.md` therefore builds the model as segments.
What is left for this entry is the chrome and the screen budget: the gutter, the
minimap bracket, the tree. The screen budget is the part to look at before
writing anything: the gutter takes width from the grid, and the minimap's 10 pt
margin already holds the viewport marker and the bookmark arrows.

**Cost.** 20–30 hours for the visible half if the segment model already exists;
composition is that again, a parser plugin is its own project.

### A project file

**What.** Save a session rather than a file: the bookmarks, which files were
open in which pane, the pane arrangement, maybe the comparison and the word
size — reopened as one thing.

**Why.** Bookmarks are session-only today (§20.1), which is right as far as it
goes, but the two-chip round trip (`JOIN_SPLIT_PLAN.md`) shows where it runs out:
the boundary offset matters across a restart, and so does "these two dumps belong
together". Persisting bookmarks alone would answer half of that and invent a
format for the other half later.

**How.** Not designed. The question to answer first is whether a project is a
file the user saves deliberately or a window state the app restores by itself —
and that decides nearly everything else. Worth doing when the need is real, not
before.

---

## Done

- **The test-suite revision** — `Design/TEST_REVIEW.md`, finished 2026-08-22.
  965 tests audited, app suite 674 → 559 and core 291 → 203 with coverage up
  (ten tests added for behaviour nothing watched, nineteen rewritten because
  they could not fail), 60 copied helpers replaced by one file, and ~12 s of
  wall-clock waiting replaced by seams. Two production bugs found on the way:
  silent data loss on a sandboxed save (`5bbef2a`) and the minimap's divider no
  longer following the panes' (`cb8f9aa`).
