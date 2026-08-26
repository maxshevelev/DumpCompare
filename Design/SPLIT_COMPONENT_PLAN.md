# Split component — pulling the split view out of `NSSplitView`

> **Status: done, pending the user's check in the running app.** All three
> split sites use `ALSplitView`; no real `NSSplitView` remains. The package's
> 16 tests and the app's 722 pass. The blank-first-panel bug this work started
> from is fixed — see **The bug and its root cause**, which corrects the
> hypothesis an earlier draft of this document carried. **Also found and
> fixed** covers the further defects the review and the user's checks turned
> up, and the one loose end left open.

## Why

The app had three `NSSplitView` sites (the outer comparison split, the inner
search-results split, and the minimap split). `NSSplitView` sizes its panes from
their content and manages arranged subviews through autoresizing masks, which
translate into required-priority fixed-size constraints that fight the Auto
Layout pins the panes carry. That fight showed up as:

- a collapsed drop band ballooning the whole split (and the window) to honour a
  pane's minimum width (fixed earlier, commit `bbe1261`);
- divider-drag artifacts and the divider showing through a pane's chrome;
- and, the bug that motivated this work, **a blank region where the first panel
  should be when the second panel opens** (the pane-reuse / re-parent path).

The goal was a small, reusable split component — a Swift package, `ALSplitView`
— with native-like divider behaviour (drag, double-click, cursor, animation)
that owns pane placement directly, so a resize can't feed back into the
enclosing window's constraint layout.

The user's architectural direction (governing this work): the divider is a
**real subview** placed between the pane containers, not drawn in `draw(_:)`.
The split contains the pane containers and the divider as subviews; the
containers take whatever size the split gives them and stretch their content to
fill.

## What was done

1. **`ALSplitView` Swift package** (`ALSplitView/`, `swift-tools-version: 5.9`,
   macOS 14). One source file, `Sources/ALSplitView/ALSplitView.swift`, plus a
   test target (`Tests/ALSplitViewTests/ALSplitViewTests.swift`, 16 tests).
   Wired into the app via `project.yml` (a local package at `path: ALSplitView`);
   the app target and the test target both depend on it.
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
5. **The divider is a real, layer-backed subview** positioned by `layout()` —
   not drawn in `draw(_:)`. This was the user's explicit requirement and fixes
   the "divider shows through the pane chrome" artifact.

## The architecture

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

The pane sizes are derived from the split's **own `bounds`** and nothing about
them propagates upward, which is what keeps a resize from feeding back into the
window's constraint layout (the "balloon").

Key methods (all in `ALSplitView.swift`):

- `addPane(_:)` — appends a pane, makes it frame-based (see below), inserts a
  layer-backed divider subview before it (except for the first pane).
- `setPaneLayout(_:at:)` — sets a pane's policy and lays out.
- `layout()` — computes `paneSizes(available:)`, sets each pane's and divider's
  frame, and invalidates the window's cursor rects (a layout pass does not
  re-run `resetCursorRects` on its own, so without this the resize cursor would
  keep appearing over a divider's old spot).
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

## The bug and its root cause

The user's report: **"при открытии второй панели, на месте первой панели
образуется пустое место"** — when the second panel opens, an empty space forms
where the first panel was. 25 app tests failed with it, including an
`Index out of range` crash in `MinimapTests` (a downstream consequence: a
minimap laid out at the wrong size produced zero rectangles, and a later step
indexed into the empty collection).

The symptom, from the split's own logs: for a 1200-wide vertical split the
panes (the drop bands) were correctly sized to 597 each — but the `FilePaneView`
pinned to a band's four edges measured only ~486. **The split was doing its job;
the pane's content was not stretching to the pane.**

The cause was one line in `addPane`:

```swift
pane.translatesAutoresizingMaskIntoConstraints = false
```

A view with `translatesAutoresizingMaskIntoConstraints == false` has its
geometry owned by the **layout engine**, not by its frame. The panes carried no
constraints at all, so their geometry was permanently ambiguous — and, crucially,
the frames `layout()` assigned **never reached the engine**. The `FilePaneView`'s
pins to the band's edges are solved by that engine, against the engine's idea of
the band's size, so the pane's content kept whatever stale size the engine had
last settled on. In a fresh hierarchy that size is *zero*: a correctly sized pane
holding under-sized (or empty) content — exactly the blank region the user saw.

The fix is to make a pane **frame-based** — `translatesAutoresizingMaskIntoConstraints
= true` with an empty autoresizing mask (`layout()` re-places the pane on every
pass, so there is nothing for the mask to do). AppKit then turns each frame
`layout()` sets into the pane's engine variables, and the constraints *inside*
the pane are solved against them, in the same layout pass. The dividers are
frame-based for the same reason.

This does not re-introduce the balloon. The generated frame constraints describe
a pane's size to the engine, but that size is derived from the split's own
bounds; nothing pushes outward on the split, whose size comes from the window.

### Hypotheses that were wrong or insufficient

Worth recording, because they are plausible and cost time:

1. **"Constraint-based placement"** — panes sized by 999-priority size
   constraints, divider pinned between them. This fed the pane sizes back into
   the window's constraint layout and **ballooned the window to 43 858 pt**
   (SIGILL, "window needs another Layout Window pass"). Abandoned.
2. **`pane.needsLayout = true` after each frame set.** No effect. `needsLayout`
   marks the pane's own `layout()` to run; it does not push the frame into the
   engine, which is what the pane's content is solved against.
3. **"AppKit runs the solver before `layout()`, so the pane's subtree is one
   pass behind"** — the earlier draft's root-cause hypothesis, and the reason
   `pane.layoutSubtreeIfNeeded()` looked like the fix. It is not an ordering
   problem at all: with the engine owning the pane's geometry, *no* number of
   extra passes would have helped, because the frame was never an input to any
   of them.

`testPaneContentStretchesToThePaneFrameInOnePass` (package tests) locks this in:
it builds a pane wrapping a child pinned to its four edges and asserts the child
fills the pane after a single `layoutIfNeeded()`. With
`translatesAutoresizingMaskIntoConstraints` flipped back to `false` the child
measures 0×0 and the test fails — verified.

## Also found and fixed

Everything else the review pass over the finished component turned up. §1 and
§2 are the two bugs the user hit next in the running app — both the same
mistake in two places, **AppKit clips nothing by default**; §3 and §4 are
defects found by reading the code; §5 is the leftovers the old plan's
"Cleanup" step had listed.

### 1. The column header painted over the neighbouring panes

**Symptom:** with the split working, the user reported the hex panes' column
header — "Offset", the byte indices, "Decoded text" — running past the pane's
edge and over whatever sat beside it: the other file pane, the minimap.

**Cause:** `HexColumnHeaderView` draws its labels at the grid's own x positions,
and "Decoded text" sits at the far end of a full 16-byte row — well past the
trailing edge of a pane too narrow to show a whole row (so does the rule under
the labels, drawn out to `layout.contentWidth`). **`NSView` does not clip its
drawing to its bounds.** The dump's rows never showed this because they are
inside the scroll view's clip view; this strip is pinned *outside* it (§6), and
it is the only custom-drawing view in the app in that position — `HexView` is
inside a scroll view, `MinimapView` draws within its own bounds, and the
remaining two `draw(_:)` overrides are in dialogs.

Note this is *not* a consequence of the split rewrite. It was there before and
was simply masked: a pane whose content never stretched had nothing to overflow
with.

**Fix:** an explicit clip in `HexColumnHeaderView.draw(_:)`, set in the
unshifted coordinate space before the `horizontalOffset` translate:

```swift
NSBezierPath(rect: bounds).setClip()
NSGraphicsContext.current?.cgContext.translateBy(x: -horizontalOffset, y: 0)
```

**Test:** `HexColumnHeaderTests.testHeaderLabelsDoNotPaintOutsideThePane`. The
pane is put in the left half of a window and the **whole window** is rendered —
rendering the header alone would clip the very spill the test is looking for
(see the same rule in the app's other render tests) — then the empty right half
is asserted free of the header's ink. Before the fix it failed with
`ink at x=300.0, outside a pane ending at 300.0`.

### 2. The collapsed minimap panel painted its switch over the file pane

**Symptom:** a small blue control floating in the top-right corner of a file
pane, present from launch with no file open. It is the minimap's Local ⇄
Overview switch, drawn where the minimap panel would be if it were open.

**Cause:** hiding the minimap collapses its pane to **zero width** (§19.1) — it
does not hide the view. `MinimapPanelView`'s chrome is pinned with side insets
made deliberately `breakable` (`.defaultHigh`) precisely so a zero width is
reachable without a conflict logged on every toggle. But breaking both insets
leaves `modeSwitch` with **no horizontal constraint at all**: its x is
ambiguous and it lays out at its intrinsic width. An `NSView` does not clip its
subviews, so the switch painted straight over the file pane next door.

Same family as §1, one level up: there a view drew outside its own bounds, here
a container let a *subview* sit outside them.

**Fix:** mask the panel's layer, in `MinimapPanelView.setUp()`:

```swift
wantsLayer = true
layer?.masksToBounds = true
```

A layer mask, not `setClip()` as in §1: the strip paints its own labels in
`draw(_:)`, whereas the panel hosts real controls, and only a mask constrains
those. This holds whatever the solver does with the broken insets, which is
worth more than pinning the switch down — the insets must stay breakable, and
any future chrome gets the same guarantee for free.

**Test:** `MinimapTests.testACollapsedPanelPaintsNothingOverTheNeighbouringPane`.
A collapsed panel is put beside a pane painted flat magenta, the whole
container is rendered, and every pixel over the neighbour is asserted to still
be magenta. Before the fix it failed with the panel's ink at x=389 against a
panel starting at 400.

### 3. Stale resize-cursor rects after a divider moves

`ALSplitView.resetCursorRects` derives the resize-cursor rects from the divider
grab areas, but a layout pass does not re-run `resetCursorRects` on its own. So
after every divider move — a drag, a programmatic set, an animation — the resize
cursor kept appearing over the divider's *old* spot until something else
happened to invalidate the window's cursor rects. `layout()` now ends with
`window?.invalidateCursorRects(for: self)`.

### 4. `hitTest` claimed hits for a hidden split

The `hitTest(_:)` override returns `self` for points in a divider's grab area,
so a scroller under the grab area can't swallow a divider drag. It did so
unconditionally — including when the split was hidden, quietly undoing the
refusal the default implementation would have given. It now guards on
`!isHidden` first.

### 5. Cleanup left over from the investigation

- The two `NSLog("DBG ALSplitView …")` lines in `layout()`.
- `pane.needsLayout = true` after each frame set — hypothesis 2 above, dead code
  once the real cause was found.
- A stale comment in `FilePaneView.swift` referring to "the split's 999
  pane-width constraint", from the abandoned constraint-based approach
  (hypothesis 1). Swept for other references to it; the only remaining
  `NSSplitView` mention in the app is in `ComparisonView`, where it correctly
  names the platform convention the double-click behaviour departs from.

### Still open

Not a split or header defect, and not fixed — recorded so it isn't lost: in a
pane too narrow for a full row the dump starts out **horizontally scrolled**, so
the Offset column is cut off on the left (`00`, `10`, `20` instead of
`0000000`). The caret reveal in `refresh()` nudges the clip view to the caret's
column on open; with the caret at byte 0 that scroll looks unwarranted. Awaiting
the user's call on whether to chase it.

## Reference

- **Old working component:** `ProportionalSplitView` (commit `a905573`, now
  deleted). An `NSSplitView` subclass. It did not hit this bug because
  `NSSplitView` arranges its Auto Layout arranged-subviews *through* `layout()`
  — the framework was doing the engine bookkeeping that the plain-`NSView` port
  had to take over.
- **Core file:** `ALSplitView/Sources/ALSplitView/ALSplitView.swift`.
- **App sites:** `DumpCompareApp/ComparisonView.swift` (outer split),
  `DumpCompareApp/FilePaneView.swift` (inner results split),
  `DumpCompareApp/MainViewController.swift` (minimap split).
- **Pane wrapper:** `DumpCompareApp/DropBands.swift` — `PaneDropBandsView` wraps
  each `FilePaneView`, pinning it to the band's 4 edges with low horizontal
  hugging/compression resistance so a collapsed band can squeeze the pane.
- **Tests:** `ALSplitView/Tests/ALSplitViewTests/ALSplitViewTests.swift`;
  `DumpCompareTests/ComparisonResizeTests.swift`, `DividerDragTests.swift`,
  `LayoutToggleTests.swift`, `ReparentPaneReproTests.swift`, `MinimapTests.swift`,
  `HexColumnHeaderTests.swift` (the header clip, §1 above),
  `MinimapTests.swift` (the collapsed-panel clip, §2 above).
- **Build/test:** package — `cd ALSplitView && swift test`. App — `xcodebuild
  test … -derivedDataPath "$DUMPCOMPARE_DD"` (never Xcode's shared DerivedData).
