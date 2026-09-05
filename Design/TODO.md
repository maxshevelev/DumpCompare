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

## Technical debt

- **Two copies of the app on one Mac share everything that says which machine
  it is** — the build in `/Applications` and the one Xcode runs have the same
  bundle id, so the same container, the same `Favorites.json` and the same
  `LibraryDeviceIdentity`. Run both at once and the folder is back to one file
  with two writers, inside a single machine: the writes are serialised by the
  coordinator, but the *counters* are not — both processes increment the same
  key, so two different libraries can carry the same version and each merge
  will believe the other has seen it. Nothing loses data in ordinary use, since
  nobody runs two copies; it is a trap on a test bench, and it looks like
  patterns vanishing without a question. A cheap guard exists if it is ever
  wanted: a marker in the container saying which process holds the library, and
  a second copy that reads it works without publishing.
- **A handful of tests pass alone and fail in a full run.** Seen so far:
  `FindFlowTests.testFindCentersMatchInView` (the centred row lands 4 pt out),
  `FindHighlightTests.testEveryStepPopsTheIndicator` (the bounce does not end),
  `JoinTests.testAppendJoinsTheBytesAfterTheContent` (the open panel is not
  there). Each passes on its own and with its own suite; each has failed once
  in a whole-suite run — never the same one twice, and one of those runs took
  seven times as long as the others, which says the machine was busy. So the
  suspects are two: something a previous suite leaves in a global (4 pt is a
  fraction of a row, so an appearance setting), and tests that wait on a real
  window, a real animation or a real panel and give up too early under load.
  Both are worth finding rather than papering over with a longer timeout: a
  test that depends on what ran before it, or on how fast the Mac is, will lie
  about something else later.

---

## Done

- **Carrying the pattern favourites between machines** —
  `Design/FAVORITES_SYNC_IDEA.md` and `Design/FAVORITES_SYNC_PLAN.md`, eight
  stages on the `favorites-sync` branch. The library became a file in the app's
  container, movable to any folder a sync client watches — iCloud Drive, Google
  Drive, Dropbox — which needs no entitlement of its own. The local file is the
  truth and the folder the medium: the app never draws from a file another
  machine may be writing. **One file per machine** — each Mac writes only its
  own and reads everyone else's — because a file with two writers makes the sync
  provider the judge of who wins, and it was measured deciding silently and
  wrongly. Every publish merges each file three ways against the last state
  agreed with it, with ids, tombstones and a version vector, because a synced
  folder is not a lock and the two machines *will* write inside the window. What
  a rule must not decide — the same entry changed differently on both sides,
  edited here and deleted there, one search under two names — is asked in a
  sheet, on **both** machines, and an answer on one settles the other. Nothing in the folder that is not a
  machine's own file is touched. The whole merge is tested without a
  window or a network.
- **A library of named patterns** — `Design/PATTERN_LIBRARY_IDEA.md`, on the
  `pattern-favorites` branch. The pattern field became an `NSSearchField`
  whose menu carries both lists — **Recent Queries** and **Favorites** — where
  a favourite is a recent with a name and nothing else: one stored shape, one
  row format, one pick. A row states its pattern, its encoding and its case
  rule, because a row that hides one is lying about what picking it does; a
  pick loads all three, searches, and records nothing in the history. **Add to
  Favorites** keeps what the field describes and asks only for a name, and the
  Favorites tab in Settings edits the list — nothing unsearchable is stored, a
  new row is a draft until it has a pattern, and the order is the user's, so
  rows are dragged. Escape now belongs to the field (menu, then clear), so the
  bar closes by Done.
- **Smart Search** — the encoding as a result rather than an instruction: with
  the toggle on (the default), a pattern is looked for as hex when it reads as
  hex and then as text, ASCII through UTF-16 BE, until something is found, and
  the encoding that found it goes into the popup and the history. Where the
  user names one — picked out of the history, or chosen by hand — that is where
  the search starts, and it outranks the search already running; what worked
  replaces it afterwards. The pass, the order and the wrap live in the model
  (`SmartSearch` in the Core package), so they are tested without a window.
  Two things the dump cannot show are said on a frosted plate in the window's
  lower third: a search that came round the end of the file (a circular arrow),
  and a pass where no encoding found anything, naming what it tried.
- **Find highlighting** — `Design/FIND_HIGHLIGHT_PLAN.md`, seven stages on the
  `find-highlight` branch. One scan per activated pattern is the single source:
  Find Next became an index step (and wraps), the Find bar counts ("3 of 128"),
  every occurrence is greyed in the dump with the current one on a raised
  yellow plate, both minimap modes mark the matches, and the results panel
  reads the set instead of running its own scan — refusing to list past 1000,
  where a list stops being a tool.
- **Segments, and joining a second chip's dump** — `Design/SEGMENTS_PLAN.md` and
  `Design/JOIN_SPLIT_PLAN.md`, shipped in 0.5 (`959c7ca`…`ccba1a6`, 2026-08-22 to
  08-29). The partition model that follows the content, the tint, the strip, the
  form and writing pieces out; append or insert a file by menu or drop band, and
  a joined image named after the dump it grew from (`422c22d`).
- **Dragging panes, and a drop zone for a new tab** — `Design/PANE_DRAG_PLAN.md`,
  shipped in 0.6 (`8da3103`…`093faef`, 2026-08-29/30). Swap by drag, a strip at
  the top for opening a file in a new tab, a pane dragged to another tab or into
  a new one, and Option to copy instead of move.
- **The test-suite revision** — `Design/TEST_REVIEW.md`, finished 2026-08-22.
  965 tests audited, app suite 674 → 559 and core 291 → 203 with coverage up
  (ten tests added for behaviour nothing watched, nineteen rewritten because
  they could not fail), 60 copied helpers replaced by one file, and ~12 s of
  wall-clock waiting replaced by seams. Two production bugs found on the way:
  silent data loss on a sandboxed save (`5bbef2a`) and the minimap's divider no
  longer following the panes' (`cb8f9aa`).
