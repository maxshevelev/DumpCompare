# Split component — pulling the split view out of `NSSplitView`

> **Status: in progress, blocked on a layout bug.** The component is built and
> wired into all three split sites, but a layout-order issue leaves each pane's
> *content* un-stretched to the pane's frame (the "blank first panel" bug the
> user reported) and 25 app tests fail. This document is the handoff: what was
> done, the problem, the investigation so far, and the concrete next steps.
> Pick up at **Next steps**.

## Why

The app has three `NSSplitView` sites (the outer comparison split, the inner
search-results split, and the minimap split). `NSSplitView` sizes its panes from
their content and manages arranged subviews through autoresizing masks, which
translate into required-priority fixed-size constraints that fight the Auto
Layout pins the panes carry. That fight showed up as:

- a collapsed drop band ballooning the whole split (and the window) to honour a
  pane's minimum width (fixed earlier, commit `bbe1261`);
- divider-drag artifacts and the divider showing through a pane's chrome;
- and, the bug that motivated this work, **a blank region where the first panel
  should be when the second panel opens** (the pane-reuse / re-parent path).

The goal is a small, reusable split component — a Swift package, `ALSplitView` —
with native-like divider behaviour (drag, double-click, cursor, animation) that
owns pane placement directly, so the solver never sees the panes' sizes and a
resize can't feed back into the enclosing window's constraint layout. All three
sites use it; no real `NSSplitView` remains.

The user's architectural direction (governing this work): the divider should be
a **real subview** constrained/placed between the pane containers, not drawn in
`draw(_:)`. The split contains the pane containers and the divider as subviews;
the containers take whatever size the split gives them and stretch their content
to fill.

## What was done

1. **`ALSplitView` Swift package** (`ALSplitView/`, `swift-tools-version: 5.9`,
   macOS 14). One source file, `Sources/ALSplitView/ALSplitView.swift`, plus a
   test target (`Tests/ALSplitViewTests/ALSplitViewTests.swift`, 15 tests — all
   passing). Wired into the app via `project.yml` (a local package at
   `path: ALSplitView`); the app target and the test target both depend on it.
2. **Deleted the three old `NSSplitView` subclasses:**
   `ProportionalSplitView.swift`, `SearchResultsSplitView.swift`,
   `MinimapSplitView.swift`.
3. **Migrated all three sites** to `ALSplitView`:
   - outer comparison split — `ComparisonView` (`splitView`, thickness 6);
   - inner search-results split — `FilePaneView` (`searchResultsSplit`,
     thickness 1, horizontal);
   - minimap split — `MainViewController` (`minimapSplit`, thickness 1,
     vertical; panes `contentHost` `.fill` and `minimapPanel` `.fixed(width)`).
4. **New `MinimapPanelView`** and a **`ReparentPaneReproTests`** regression test
   for the pane-reuse path (single-file → comparison re-parents the first pane
   into a `ComparisonView`; the split must lay it out 50/50, not leave a blank
   region).
5. **The divider is a real, layer-backed subview** (painted with the divider
   colour), positioned by `layout()` — not drawn in `draw(_:)`. This was the
   user's explicit requirement and fixes the "divider shows through the pane
   chrome" artifact.

The package's own 15 tests pass. The app-level geometry/interaction tests do not
(see below).

## The architecture (current)

`ALSplitView` is a **plain `NSView`** (not an `NSSplitView`). It owns each
pane's placement by setting `pane.frame` / `divider.frame` **directly** in
`layout()`, derived from per-pane `PaneLayout` policies:

- `.proportional(f)` — `f` of the free axis;
- `.fixed(s)` — exactly `s` points;
- `.fill` — splits the remainder evenly with the other `.fill` panes.

`layout()` walks the panes in order, giving each its policy-derived size and the
following divider its thickness, accumulating the offset until the last pane
reaches the trailing/bottom edge. Every pane and divider spans the full cross
extent. The view is flipped (`isFlipped == true`), so in a stacked layout pane 0
is the TOP pane.

Key methods (all in `ALSplitView.swift`):

- `addPane(_:)` — appends a pane, sets `pane.translatesAutoresizingMaskIntoConstraints =
  false`, inserts a layer-backed divider subview before it (except for the first
  pane).
- `setPaneLayout(_:at:)` — sets a pane's policy and calls
  `layoutSubtreeIfNeeded()`.
- `layout()` — the core: computes `paneSizes(available:)` and sets each pane's
  and divider's frame directly. **Currently has two temporary `NSLog` debug
  lines that must be removed before this is finished**, and a
  `pane.needsLayout = true` after each pane frame set (see Root cause).
- `dividerPosition(at:)` / `setDividerPosition(_:at:)` /
  `applyDividerPosition(_:at:)` — the divider position is derived from the
  policies; `setDividerPosition` is the programmatic setter and the same code
  path a drag takes (clamps via the consumer's `clampDividerPosition`, then the
  free axis, rewrites the bordered pane's policy so the position survives the
  next layout pass, lays out, fires `onDividerMoved`).
- `hitTest(_:)` — returns `self` for points in a divider's grab area (strip plus
  `dividerHitSlop`), so a scroller sitting under the grab area can't swallow a
  divider drag and turn it into a scroll (this was the minimap-splitter click
  fix, task #21).
- `mouseDown` / `mouseDragged` / `mouseUp` — the drag is handled by the view
  itself; a double-click fires `onDividerDoubleClicked`.
- animation: `animateDividerPosition`, `animateTrailingPaneSize`, and their tick
  helpers.
- `axisAvailable()` — the bounds' axis minus all dividers, clamped ≥ 0.
- `paneSizes(available:)` — fixed panes take their size, proportional their
  fraction, `.fill` split the remainder (never negative).

The **panes carry no Auto Layout constraints of their own** (their
`translatesAutoresizingMaskIntoConstraints` is off and nothing pins their size), so the
solver never sees their sizes. That is what keeps a resize from feeding back
into the window (the "balloon").

The app-side hierarchy (comparison mode):

```
window.contentView (1200×600)
└─ ComparisonView (pinned 4 edges)
   └─ splitView (ALSplitView, vertical, thickness 6, pinned 4 edges)
      ├─ bands1 (PaneDropBandsView — the split's pane 0)
      │  └─ paneView1 (FilePaneView, pinned to bands1's 4 edges)
      │     └─ searchResultsSplit (ALSplitView, horizontal, thickness 1)
      │        ├─ scrollView (pane 0, .fill)
      │        └─ searchResultsView (pane 1, .fixed(0))
      ├─ divider0 (layer-backed NSView)
      └─ bands2 (PaneDropBandsView — the split's pane 1)
         └─ paneView2 (FilePaneView, pinned to bands2's 4 edges)
            └─ …
```

In the full app (not the tests) there is an extra outer layer:
`contentContainer → minimapSplit (ALSplitView, vertical, thickness 1) →
contentHost → ComparisonView → …`.

## The problem

The user's report: **"при открытии второй панели, на месте первой панели
образуется пустое место"** — when the second panel opens, an empty space forms
where the first panel was (the left half of the window goes blank).

The app-level tests that encode this and the surrounding geometry all fail
(25 failures across the targeted suites):

- `ComparisonResizeTests` — `testDefaultSplitIsEven` (panes 486.5 vs 483.5, not
  equal within 1 and not 597), `testStackedResizeKeepsHeightRatio` (ratio 0.5
  instead of 0.7; heights 76.0 instead of 1045.8 / 448.2).
- `DividerDragTests` — 6 of 7 fail; the dragged pane lands at ~490 instead of the
  requested position.
- `LayoutToggleTests` — both fail; panes stuck at 76.0, window height drifting to
  1293.5.
- `MinimapTests` — 24 of 30 fail, including the `Index out of range` crash (see
  below).
- `ReparentPaneReproTests` — fails (the pane-reuse path).

Passing: `ComparisonPaneTests` (9), `ContentRedrawTests` (12),
`SelectionRedrawTests` (8).

## Investigation

The decisive evidence came from temporary `NSLog` lines in `layout()` (still in
the code, to be removed). For the 1200×600 vertical comparison split:

```
DBG ALSplitView layout: bounds=(0,0,1200,600) isVertical=true available=1194 sizes=[597,597]
DBG ALSplitView pane[0] frame=(0.0, 0.0, 597.0, 600.0) class=PaneDropBandsView
DBG ALSplitView pane[1] frame=(603.0, 0.0, 597.0, 600.0) class=PaneDropBandsView
```

So **the split correctly sizes its panes (the bands) to 597 each.** But the test
reads `cv.paneView1.frame.width` (the `FilePaneView` *inside* the band) and gets
**486.5** (and 483.5 for pane 2) — the `FilePaneView` is **not filling its
band**. The band is 597 wide; the `FilePaneView` pinned to the band's four edges
is only ~486 wide. That gap is the blank region.

So the split is doing its job; the failure is one level down: **a pane's frame
is set directly by `layout()`, but the pane's internal constraint-based content
(the `FilePaneView` pinned to the band's edges) is not re-laid-out against the
new frame in the same layout cycle.**

### What was tried

1. **Constraint-based placement** (panes sized by 999-priority size constraints,
   divider pinned between them). This fed the pane sizes back into the window's
   constraint layout and **ballooned the window to 43 858 pt** (SIGILL, "window
   needs another Layout Window pass"). Abandoned.
2. **Direct frame setting** (the current approach). Eliminated the balloon
   entirely (no 43 858, no "Layout Window" lines), and the package tests pass.
   But it introduced the un-stretched-content problem above.
3. **`pane.needsLayout = true` after each pane frame set** (currently in the
   code). **Did not fix it** — the same 25 failures. `needsLayout` only marks the
   pane's own `layout()` to run; it does **not** re-run the Auto Layout solver
   for the pane's subtree, so the `FilePaneView`'s pin constraints are not
   re-solved against the new band frame.

### Root cause (hypothesis, high confidence)

AppKit's layout pass runs the constraint **solver first**, then calls
`layout()` on the marked views. In one `layoutIfNeeded()` cycle:

1. The solver runs for the window's subtree. At this point the bands' frames are
   still at their **old** values (the split's `layout()` has not run yet), so the
   solver sizes each `FilePaneView` to its band's **old** width.
2. The split's `layout()` runs and sets the bands' frames to the **new** values
   (597) directly.
3. The bands' `layout()` runs, but it does **not** re-solve the `FilePaneView`'s
   constraints (the solver already ran in step 1), so the `FilePaneView` stays at
   its stale width.

The old `ProportionalSplitView` (an `NSSplitView` subclass) did not have this
problem because `NSSplitView` arranges its Auto Layout arranged-subviews
*through* `layout()` — its `layout()` override was the mechanism that re-laid-out
the arranged subviews' content. A plain `NSView` setting subview frames directly
has no such mechanism, so the content is left stale.

## The crash

`Swift/ContiguousArrayBuffer.swift:690: Fatal error: Index out of range`
(Signal 4) appears in `MinimapTests` (e.g. `testAnEditRepaintsBothMapsRows`,
which first fails `("0") is not equal to ("2") — one rectangle per map`). This is
a **downstream consequence of the layout bug, not a separate defect**: the
minimap is not laid out to the right size (its content host is not filling the
`minimapSplit` pane), so it produces 0 rectangles, and a later step indexes into
that empty collection. Fixing the layout should make the crash disappear; do not
chase it independently.

## Next steps

1. **Force the pane's subtree to re-solve in the same cycle.** In `layout()`,
   replace `pane.needsLayout = true` with `pane.layoutSubtreeIfNeeded()` after
   setting each pane's frame. `layoutSubtreeIfNeeded()` re-runs the solver for
   the pane's subtree (re-solving the `FilePaneView`'s pins against the new band
   frame) and then calls the pane's `layout()`. Because the pane's *size* is set
   directly (not by a constraint), the solver never sees it, so this should not
   re-introduce the balloon. Verify: the package tests stay 15/15, and
   `ComparisonResizeTests` / `DividerDragTests` / `LayoutToggleTests` /
   `ReparentPaneReproTests` / `MinimapTests` pass with correct sizes and no
   balloon and no `Index out of range`.
   - **Risk to watch:** calling `layoutSubtreeIfNeeded()` on a child *during* the
     parent's `layout()` is re-entrant. If it misbehaves (infinite layout, or the
     balloon returns), the fallback is to defer the pane re-layout to the end of
     the cycle (e.g. dispatch the `layoutSubtreeIfNeeded()` calls to the next
     runloop turn, or mark the panes and let a second `layoutIfNeeded()` pass
     settle them) — but a deferred pass means the tests must call
     `layoutIfNeeded()` twice, which is ugly. Prefer the in-cycle call.
2. **If step 1 is insufficient**, consider whether the pane wrappers
   (`PaneDropBandsView`) should lay out their wrapped `FilePaneView` manually in
   their own `layout()` (frame math, like the split does) instead of pinning it
   with constraints — removing the constraint dependency entirely. This is a
   larger change and should only be reached if the solver re-run does not settle
   it.
3. **Cleanup before this is done:**
   - Remove the two temporary `NSLog("DBG ALSplitView …")` lines from `layout()`.
   - Fix the **stale comment** in `FilePaneView.swift` (~lines 318–319) that
     still references "the split's 999 pane-width constraint" — that was the old
     constraint-based approach; the split now places panes by direct frame.
     Sweep for other stale references to the 999-priority / constraint-based
     divider.
4. **Re-run and confirm:** package tests (`cd ALSplitView && swift test`, must be
   15/15) and the targeted app suites (`ComparisonResizeTests`,
   `DividerDragTests`, `LayoutToggleTests`, `ReparentPaneReproTests`,
   `ComparisonPaneTests`, `MinimapTests`, `ContentRedrawTests`,
   `SelectionRedrawTests`) — confirm the balloon AND the `Index out of range`
   crash are gone and the sizes are exact.
5. **User verifies the blank-first-panel bug is actually fixed in the running
   app** (open a file, then open a second file; the first panel must not go
   blank). **Do not commit this work as done until the user confirms.**

## Reference

- **Old working component:** `ProportionalSplitView` (commit `a905573`, now
  deleted). An `NSSplitView` subclass that overrode `layout()` *without*
  `super.layout()` in the normal case, set `arrangedSubviews`' frames directly,
  recovered a single `fraction` from `arranged[0].frame` ÷ the available axis,
  and overrode `minPossiblePositionOfDivider` → 0 and
  `maxPossiblePositionOfDivider` → (axis − dividers). Its commit note: "layout()
  is overridden (not adjustSubviews) because modern NSSplitView arranges its
  Auto Layout subviews through layout()"; "Panes keep
  translatesAutoresizingMaskIntoConstraints off to avoid the autoresizing 'width == 0'
  conflict." That note is the key to why the plain-`NSView` port lost the
  content re-layout.
- **Core file:** `ALSplitView/Sources/ALSplitView/ALSplitView.swift`.
- **App sites:** `DumpCompareApp/ComparisonView.swift` (outer split),
  `DumpCompareApp/FilePaneView.swift` (inner results split, ~lines 426–435 and
  467–484), `DumpCompareApp/MainViewController.swift` (minimap split,
  `minimapSplit` pinned to `contentContainer` ~lines 283–287; `contentHost`
  subviews pinned ~lines 587–594).
- **Pane wrapper:** `DumpCompareApp/DropBands.swift` — `PaneDropBandsView` wraps
  each `FilePaneView`, pinning it to the band's 4 edges (lines 172–177) with low
  horizontal hugging/compression resistance (lines 169–170) so a collapsed band
  can squeeze the pane.
- **Tests:** `DumpCompareTests/ComparisonResizeTests.swift` (puts the
  `ComparisonView` directly in a 1200×600 window — no minimap/contentHost layer),
  `DumpCompareTests/DividerDragTests.swift`, `DumpCompareTests/LayoutToggleTests.swift`,
  `DumpCompareTests/ReparentPaneReproTests.swift` (builds the full
  minimapSplit → contentHost hierarchy), `DumpCompareTests/MinimapTests.swift`.
- **Build/test:** package — `cd /Users/maxik/Projects/DumpCompare/ALSplitView &&
  swift test`. App — `xcodebuild test … -only-testing:…` with
  `-derivedDataPath /Users/maxik/.claude/derived-data/dumpcompare` (never Xcode's
  shared DerivedData). Targeted suites only; the user runs the full suite before
  committing.
