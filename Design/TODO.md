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

### Finish the test-suite revision

**What.** The remaining work from `Design/TEST_REVIEW.md` §3: about 60 merges,
the table-driven consolidation of the core suite (87 tests into ~25, and the two
storage suites into one conformance suite that covers both implementations), 12
rewrites of tests that still cannot fail, and the seams that would replace ~10 s
of sleeps. (§3.4, the shared test helpers, is done.)

**Why.** The first pass is done and the suite is green and honest (674 → 633 app
tests, three tests that had never run now running). What is left is not urgent —
nothing on the list is a hole in coverage — but it is the difference between a
suite that is correct and one that is cheap to add to.

**How.** The report carries the per-item lists and the order. Two entries there
need a decision rather than work: whether `DiffEngine.findBlock` and
`SearchEngine.findAll` are dead code to delete or library API to keep (§3.7).

**Cost.** 10–14 hours all told, splittable — every item in §3 stands alone.

---

## Later

*(nothing yet)*

---

## Someday

*(nothing yet)*

---

## Done

*(nothing yet)*
