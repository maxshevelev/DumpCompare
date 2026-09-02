# Find highlighting — every occurrence in the dump and on the map

> The feature's name in the notebook was **"Highlight search matches in the
> dump"** (`TODO.md`, Next). This plan is that entry grown up: the dump *and* the
> minimap, two states instead of one — Apple's own pair — and a match count in
> the Find bar.
>
> Stands on machinery that already exists: `SearchEngine.findAllStream` scans a
> file streaming matches in order, with progress and cancellation; the Find bar
> owns the pattern; the Search Results panel already grows a row at a time; the
> minimap already paints per-byte state in one mode and a per-row picture in the
> other. Nothing here invents a search.

## The two states, and their names

The platform already has this pair, and it is worth using its vocabulary rather
than inventing ours:

- **Match highlight** — *every* occurrence of the current pattern, in
  `NSColor.unemphasizedSelectedTextBackgroundColor`. Measured in this SDK:
  opaque grey, `0.86` in light and `0.27` in dark. It is literally the colour the
  platform uses for a selection in a view without focus, which is exactly the
  statement being made: *this is a match, but not the one you are standing on*.
  It is the grey behind the other `Button`s in Xcode.
- **Find indicator** — the *current* match, in `NSColor.findHighlightColor`. This
  is `NSTextView.showFindIndicator(for:)`'s yellow, and the reason the current
  match in Xcode looks the way it does. Measured: pure `1.00 1.00 0.00`, opaque,
  **the same in both appearances** — Apple's documentation says to use it with
  black text, and that constraint is real (see *Ink over the indicator*).

**The relief is drawn, and its outline is not ours.** The bubble's shape comes
from the *mirrored selection's* contour builder (§3.3) — the same padding away
from the glyphs, the same corner radius, one staircase around a match that
crosses rows. One algorithm, two users. It carries no border: a soft shadow
below and to the right is what says "raised", and a dark rim around yellow reads
as a box drawn on the text. Both columns, both states.

**Why not the SDK's own indicator.** `NSTextView.showFindIndicator(for:)` draws
exactly this bubble — it is what TextEdit and Xcode get for free — but it takes
a *text range* in an `NSTextView`'s storage, so a custom hex view cannot ask for
it, and it flashes and dies where we need a state that holds until the next Find
Next.

**Why not Core Animation for the hop.** `CASpringAnimation` on a layer's
`transform.scale` and shadow properties is the platform's own way to animate
this — but it animates a *layer*, and a sublayer composites **above** its view's
own drawing. The bubble has to sit under the bytes it highlights, so it belongs
in `draw(_:)`, and a layer would cover them. What is taken from the platform is
its frame clock: `NSView.displayLink(target:selector:)` (macOS 14) drives the
hop, not a `Timer`.

The hop itself is one idea — height — with three consequences: the plate grows
about its own centre (never moving off the bytes it marks), and its shadow grows
wider, softer and deeper. Half a second, one clear jump and a small second one.
A quarter of a second was tried and reads as a redraw glitch rather than as
movement.

The shadow is drawn from the plate's own geometry — concentric strokes of the
same outline — rather than with `NSShadow`, and that is a correctness decision:
an `NSShadow` offset is interpreted in whatever space the current graphics
context is in, and this view is painted through more than one, which had the
shadow falling downward in a render test while falling upward on screen.

## One scan is the source of everything

Activating a search means scanning the whole file, so the scan's result — not a
per-view approximation of it — is what everything reads:

| Consumer | Reads |
| --- | --- |
| the dump's greys | the matches intersecting the rows being drawn |
| the find indicator | the current index into the set |
| Find Next / Previous | a step in the set — **no rescan per press** |
| the count in the Find bar | the set's total |
| the Search Results panel | the set itself, row by row |
| the minimap, both modes | the set, and the per-row bits derived from it |

This is the decision that shapes the rest, and it replaces an earlier draft of
this plan that had the dump rescanning its own visible window as it drew. That
would have been cheap and self-invalidating, but it bought nothing: **the scan
happens anyway**, and one source removes every way for the four answers above to
disagree with each other. Two consequences worth naming:

- **Find Next stops being a search.** Today every press scans the file from the
  caret (§11). With the set in hand it is an index step — instant, and it makes
  "3 of 128" and wrapping possible at all.
- **`Find All` stops being a search too.** It becomes the button that *shows the
  results panel*, because the results already exist. It should read as a toggle
  (checked while the panel is open) and be disabled when there is nothing to
  list. The panel's own × keeps closing the panel; what it must no longer do is
  cancel a scan that the highlighting also depends on.

### Two limits, and they mean different things

A large match count raises two separate questions, and conflating them produces
the wrong design.

**The one that matters is about meaning, not memory.** Thousands of matches is a
statement about the *pattern*: nobody walks four thousand occurrences, so a count
in the thousands almost always means the pattern is too generic and wants another
byte or two. The limit exists to say that — not to protect the app.

But it applies to **enumeration**, not to the picture, because the two behave in
opposite ways as the count grows:

- **A picture is self-limiting.** Four thousand greys in the dump and on the map
  read as *"it is everywhere"*, which is the correct answer to a pattern that is
  everywhere; the user sees a grey field and refines. And thousands is a
  legitimate reading: a signature every 0x1000 in a 16 MB dump is 4096
  occurrences, and the greys and the map are precisely the instrument that shows
  that structure. The value of the picture grows with the count.
- **A list is not self-limiting.** Four thousand rows look exactly like forty
  until you scroll to the end, so a list that long impersonates a tool. It must
  name the number and refuse.

So: **the count is always exact and always shown**, because it is the diagnosis —
`>1000` is not a diagnosis, since 1001 and 3 000 000 call for different actions.
Highlighting, navigation and the map keep working at any count. The **results
panel stops listing past 1000** — the cap §11 and `SearchEngine.defaultMaxResults`
already name, so the number needs no fresh defence; what changes is what happens
at it. Instead of "showing the first 1000 of many" the panel shows one line:

> **4 812 matches — too many to list. Refine the pattern.**

The same sentence is the tooltip on a small warning glyph beside the count. No
scolding and no modal: the bar states the number, the panel explains the refusal,
and the picture keeps answering the question the count cannot.

**The other limit is technical, and second-order.** Highlighting needs the whole
set, and for a single-byte pattern that is millions of entries. The set is match
*starts* (every match has the pattern's length), so the representation follows
the density:

| Matches | Representation | Cost |
| --- | --- | --- |
| up to `size / 64` | sorted `[UInt64]` starts | 8 bytes each |
| above that | a bitmap of starts + per-block rank | `size / 8` + 0.1 % |

The crossover is where the two cost the same, and the bitmap is exact at *any*
count: a 16 MB dump costs 2 MB, a 32 MB dump 4 MB, whatever the pattern. For the
dumps this app is for — kilobytes to tens of megabytes — the technical limit is
therefore never reached, and no honesty is spent. Only past roughly a quarter of a
gigabyte does the bitmap itself grow inconvenient; there, and only there,
highlighting turns off with its reason stated while the count and the map stay
exact (both are O(1) and O(rows) in memory, never O(matches)).

The bitmap costs one piece of real machinery: a per-block popcount prefix table,
so `ordinal(of: offset)` — the "3" in "3 of 4 812" — stays O(1) instead of a walk.
That is ~100 lines of pure, unit-testable logic, and it is the price of never
truncating.

**One delivery cost worth naming.** `findAllStream` yields one match at a time
into the main actor, which is right for a table that grows a row at a time and
wrong at a million matches. The scan must deliver in batches (a chunk's matches at
once); the stream's per-match shape stays for the panel.

### Latency, from §11's own measurements

The scan streams in file order, so the first match after the caret arrives before
the scan ends: pressing Find Next does not wait for the total. §11 measured a
16 MB dump at ~3 ms exact and ~50 ms for case-insensitive UTF-16, which puts a
1 GB image at roughly 0.2 s and 3 s respectively — with progress in the pane's
status bar and cancellation, exactly as a search has today. While the scan runs
the count carries an ellipsis and the greys fill in behind it.

## Keeping the set true across edits

A stored set can go stale where a per-draw scan could not, and the existing
`DiffEdit` plumbing already distinguishes the two cases that matter:

- **`.overwrite(range)`** — no byte moves. Only matches touching that range can
  appear or vanish, so rescan `range` widened by `patternLength - 1` either side
  and splice that segment of the set. Bounded work, exact result.
- **`.insert` / `.delete`** — every offset after the change moves, so the set is
  rebuilt by a background rescan, debounced the way the overview's picture
  already is (§19.9). Until it lands the old set is dropped rather than shown
  shifted: a grey in the wrong place is worse than no grey.

## Layering, and ink over the indicator

§6's stack, bottom to top, gains two entries:

```
segment tint  →  match highlight  →  difference fill  →  selection fill
              →  find indicator   →  glyphs  →  caret
```

- **Match highlight below the difference fill.** The grey is opaque, so it covers
  the segment tint — §6 already rules that a state outranks which piece a byte
  belongs to. It must *not* cover the difference: telling two dumps apart is what
  the app is for, so orange wins over grey. A match hidden under a difference is
  still reachable — Find Next brings the indicator to it, and the map marks it.
- **Find indicator above the selection.** Find Next selects the match it lands on
  (§11) and should keep doing so — the found bytes are what the user then copies,
  replaces or measures — so the two ranges coincide and the yellow wins for that
  range. Elsewhere the selection is untouched and blue.
- **Ink over the indicator.** The yellow is the same in dark mode as in light, so
  `labelColor` on it is white-on-yellow — unreadable. Over the indicator the ink
  is forced: significant bytes **black**, and the `0x00`/`0xFF` muting dropped
  (40 % label on yellow is a smear). A **modified** byte keeps its red: it is
  data-integrity information, red on yellow still reads as red, and losing it
  would mean the app stopped showing an unsaved edit because the caret happened
  to be there. This wants a palette test, like `SegmentPaletteTests`.

## The count in the Find bar

The bar is one horizontal `NSStackView`: `Find | pattern | encoding | Aa | ‹ › |
Find All | Done`. The count goes **between `Aa` and `‹ ›`** — after the query it
describes, before the stepper that walks it, which is where the platform's own
find bar puts it.

One label, `secondaryLabelColor`, `monospacedDigitSystemFont` so the digits do
not shuffle the bar's controls as the count climbs, with a fixed minimum width
sized from the template `"8888 of 8888"` — the same trick the results panel uses
for its columns (§11) — so a growing number never nudges `‹ ›` sideways. The
pattern field is the only control that yields width, and it already is.

Its states, and nothing else:

| When | Shows |
| --- | --- |
| bar just opened, nothing searched yet | *(empty — the bar stays quiet)* |
| a set, nothing stepped to yet | `128` |
| standing on a match | `3 of 128` |
| pattern occurs nowhere | `Not found` |
| past the listing limit | `3 of 4 812` + a warning glyph |
| past the technical limit (huge images only) | `2 481 903` + the glyph |

- **Nothing appears while the scan runs.** An earlier draft had the count climb
  behind an ellipsis; publishing a set in pieces would mean copying it per
  batch, and the scan's progress and its × already live in the pane's status
  bar (§14.4). So the label speaks when the set lands — 3 ms on a 16 MB dump.
- **`Not found`** replaces today's transient "No matches after the cursor." for
  the case where there are none at all — a persistent statement instead of a
  message that fades while the field still holds the pattern that failed.
  Grouping separators come from a `NumberFormatter`, so six-digit counts stay
  readable.
- The **warning glyph** (`exclamationmark.triangle`, quiet tint) appears past
  either limit, carrying the sentence that names the consequence: *"Too many
  matches to list. Refine the pattern."* past 1000, and *"Too many matches to
  highlight — navigation and the map still cover all of them."* in the rare
  technical case. The reason belongs next to the count, which is the thing that
  proves the matches exist; in a transient message it would leave the absent rows
  or greys unexplained a minute later.
- `‹ ›` and `Find All` are **disabled at zero**. They are enabled today whenever
  the field parses, which was right when each press was its own scan.
- The label is the accessibility statement too: VoiceOver reads "3 of 128" from
  it, and `Not found` needs no separate announcement.

**Wrapping — settled: it wraps.** With the whole set in hand, Find Next at the
last match returns to the first, which is what every find bar on the platform
does. §11 forbids it today and requires the direction to be named in the message
instead — a rule that existed *because* the scan was directional and could not
know whether anything lay behind the caret. That reason is gone, so the rule goes
with it: the count says what happened (`128 of 128` → `1 of 128`), the directional
"No matches after the cursor." message is deleted, and `Not found` is the only
thing left to say when a pattern occurs nowhere. §11 is amended in Stage 2, where
the wrap lands, rather than in the drawing stages.

The one case that still needs a word: a **single** match, where Find Next wraps
onto the match it is already standing on. It must not look inert — the count
already reads `1 of 1`, so the find indicator is redrawn (the same range, a fresh
draw) and the view re-centres it, which is what the user asked for by pressing.

## The minimap

A match is a **byte state**, like a difference — not an annotation like a
bookmark. So it is drawn in the map's content, not in the margin: §19.4.3's rule
that nothing is drawn over the content governs marks the *user* placed, while
difference and modification have always been painted in the cells themselves.

- **Detail mode** pulls its window's cells per repaint. `CellState` gains
  `isMatch` / `isCurrentMatch`, answered from the set by binary search over the
  window's range — the same source the dump reads, so the map cannot disagree
  with the dump beside it (§19.4.1).
- **Overview mode** takes a `MatchOverlay` beside the existing `OverviewSummary`:
  extent, row count, and a bit per column per row — the same shape as `modified`
  and `different`, so the stretch rule for a file smaller than one byte per row
  comes along for free (§19.4.2). It is filled *by the scan* rather than by a
  second pass, costs `2 bytes × rowCount` (≈ 4 KB for any file), and survives the
  budget. It is a separate value from the summary because its lifetime differs:
  the summary is invalidated by bytes, the overlay by the pattern, and a new
  search must not trigger a density rebuild.
- The current match also gets a **margin marker** in the overview: at a row per
  13 KB the yellow cell is one pixel tall and easy to miss, and the margin arrow
  is the shape the panel already uses for "the thing you are looking at is here"
  (§19.6, §19.4.3). Yellow is free in that margin — grey is the viewport, purple
  is a bookmark.

## The results panel, and what it refuses

Two changes, in opposite directions.

**It stops scanning.** The set already exists, so `Find All` becomes the button
that shows the panel — a toggle, checked while the panel is open, and the panel's
× no longer cancels a scan the highlighting depends on.

**It stops pretending.** Past 1000 matches it lists nothing and shows the count
with the reason (above). Below 1000 it is backed by the set directly rather than
by its own copy, and since `NSTableView` asks only for the rows it shows and the
excerpts are already read from live content at draw time, that is a smaller
implementation than today's streaming append.

What retires with this: the header state that distinguishes "filled the cap
exactly" from "had more than the cap" (§11), and the one-past-the-cap scan that
exists to make that distinction exact. The count answers both.

## The shape of it in code

```swift
/// Every match of one pattern in one pane. Pure: offsets and counts, no AppKit,
/// no storage — built by the scan, read by the dump, the map, the bar and the
/// panel.
struct MatchSet: Equatable {
    let pattern: SearchPattern
    let folding: CaseFolding
    let patternLength: Int
    /// Exact at any count, and the only number the bar shows.
    private(set) var total: Int
    /// Where the matches are. Sparse below `size / 64` of them, a bitmap of
    /// starts with a per-block rank table above it, absent only for an image
    /// too large for either (see *Two limits*).
    private(set) var storage: Storage   // .sparse([UInt64]) | .bitmap(...) | .counted
    /// A bit per column per overview row — the map's picture of the set. Filled
    /// by the scan, so it survives even `.counted`.
    private(set) var rowBits: [UInt16]
    var currentIndex: Int?

    var isHighlightable: Bool           // false only for `.counted`
    var isListable: Bool { total <= SearchEngine.defaultMaxResults }

    func matches(intersecting range: Range<UInt64>) -> [Range<UInt64>]
    func start(at index: Int) -> UInt64?
    func index(atOrAfter offset: UInt64) -> Int?
    func index(before offset: UInt64) -> Int?
    /// The "3" in "3 of 4 812" — O(1) in both representations.
    func ordinal(of offset: UInt64) -> Int?
    mutating func splice(_ starts: [UInt64], replacing range: Range<UInt64>)
}
```

It lives on `PaneViewModel` — one per pane, for the pane that was searched. The
other pane shows nothing: greys in a file that was never searched would be a
plain lie in comparison mode. (Highlighting one pattern in both panes — "where
else does this signature appear" — is a defensible *different* feature.)

Lifetime: built when a pattern is searched from the bar; `currentIndex` follows
Find Next/Previous and a click in the results panel; dropped when the pattern
changes, when the bar closes with no results panel open, on Escape, and when the
pane's file is replaced or closed. The panel deliberately outlives the bar (§11),
and while it is open the set and its greys stay — the panel's rows and the dump
must not disagree about what was searched.

## What is testable, and how

- **Pure, no window:** `MatchSet` — `matches(intersecting:)` at range edges, the
  ordinal lookups either side of a caret, `splice` after an overwrite, the budget
  boundary (`total` exact while `starts` is empty), `rowBits` including the
  sub-byte stretch regime.
- **Pure:** the scan's products for a known file and pattern, including hex
  exactness, ASCII folding and UTF-16 folding by code unit at an odd offset — the
  existing `SearchEngineTests` extended, since the scan is `findAllStream` and
  not a new matcher.
- **Model → view, with a window:** the states a row paints and their order (as
  the segment tint's layering is asserted today); the forced ink over the
  indicator; the palette rules against the six segment tints, the orange
  difference and the purple bookmark, as in `SegmentPaletteTests`.
- **The bar:** each row of the state table above, driven through the existing
  `FindFlowTests` seams; that `‹ ›` and `Find All` are disabled at zero; that the
  label's width does not move `‹ ›` between `1 of 9` and `128 of 4096`.
- **The map:** detail cells carry the flags; the overlay's bits for a known
  pattern; a new pattern invalidates the overlay and *not* the density picture.
- **Edits:** an overwrite inside a match drops it and finds the new one; an
  insert drops the set and rebuilds it; the rebuilt set agrees with a fresh scan.

## Stages

**All seven are built** (branch `find-highlight`). Each ended with the app
working and useful; what each one actually settled is in its commit.

1. **`MatchSet` and the scan that fills it** (5–7 h). The pure type with both
   representations and the rank table behind `ordinal(of:)`, the scan wiring (one
   `findAllStream` per activated pattern, batched delivery, cancellable), the row
   bits. Nothing visible yet; everything stands on it.
2. **Navigation off the set** (3–4 h). Find Next/Previous become index steps,
   with the scanning fallback for the rare set that is only counted. Wrapping
   lands here, and §11's directional "no match" rule is deleted with it.
3. **The count in the bar** (3–4 h). The label, its six states, the disabled
   stepper at zero, the over-budget glyph. **Shippable alone**, and worth it
   alone.
4. **Greys in the dump** (4–5 h). The fill in both columns, the layering rule,
   §6 amended.
5. **The find indicator** (3–4 h). The relief shape, the forced ink, following
   the current index, §11 amended.
6. **The map** (4–6 h). `CellState` flags in detail, `MatchOverlay` in overview,
   the current match's margin marker, §19.4.1/§19.4.2/§19.4.3 amended.
7. **The panel off the set** (2–3 h). `Find All` becomes the panel's toggle, the
   table reads the set, and past 1000 the panel shows the count and the reason
   instead of rows — the old cap header and its one-past-the-cap scan retire.

**Cost: 24–33 hours.** Stages 1–3 are a self-contained improvement (10–13 h) that
makes search instant and counted without drawing anything new; 4–7 are the
picture.

## What the build changed about this plan

Three things turned out differently, and the code and §11 follow the code:

- **No partial sets.** The scan runs to completion before anything moves, and
  the count appears when the set lands. Publishing a set in pieces would have
  meant copying it per batch, and a press of Find Next has always waited for a
  scan.
- **The shadow under the find indicator is drawn from the plate's own
  geometry**, not with `NSShadow`, whose offset is interpreted in whatever
  coordinate space the current graphics context is in — and this view is painted
  through more than one, which had the shadow falling downward in a render test
  while falling upward on screen.
- **The overview marks matches with ink strokes**, not with the dump's grey: a
  row there is kilobytes of aggregated content drawn as a grey tone, so a grey
  mark cannot be told from content. The current match is a yellow plate in a
  thin ink frame.

## Decisions taken

1. **One scan per activated pattern is the single source** for greys, indicator,
   navigation, count, panel and map. `Find All` becomes "show the panel".
2. **Two limits, with different jobs.** The count is always exact. Past **1000**
   the results panel lists nothing and says why — the limit is about a generic
   pattern, not about memory — while highlighting, navigation and the map keep
   working at any count. Storage switches from a sparse list to a bitmap at
   `size / 64` matches, so for a dump of tens of megabytes nothing degrades
   whatever the pattern; only past ~256 MB does highlighting turn off with its
   reason stated.
3. **Find Next wraps**, and §11's directional "no match" message goes away.
4. **One pane — the one that was searched.**
5. **Find Next keeps selecting the match**, and the indicator wins over the
   selection fill for that range.
6. **A modified byte keeps its red ink inside the yellow indicator**; everything
   else goes black there.
7. **The set dies with the pattern, the bar, or Escape** — including while a
   results panel is open, which keeps its rows without a session behind them.
   (The plan first had it survive behind an open panel; closing the bar reads as
   "finished searching", and greys after that claim otherwise.)

Nothing here is open. The first thing Stage 1 should produce is `MatchSet` with
its tests; the first thing Stage 2 changes in the spec is §11's navigation rule.
