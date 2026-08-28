# Minimap layers — an idea, thought through

Not a plan. `MinimapView.swift` is ~2500 lines and grows with every feature that
wants a mark on the panel; the proposal is to split it into layers — dump,
bookmarks, segments, viewport — each served by its own module behind a uniform
API, with `draw()` collecting from all of them, a shared index guide keeping the
layers on one offset axis, and a model deciding which layers exist and in what
order. This document is what that idea looks like after taking it apart: which
half of it is the valuable half, where the abstraction leaks, and whether the
same move belongs in the hex panes.

The verdict up front: the idea is sound, but the valuable part is *not* `draw()`.
The drawing is already the tidiest thing in the file. What is scattered is
everything else each feature owns.

## Where the file actually hurts

Each feature carries four obligations, not one, and only the first is collected
in one place today:

| | dump | bookmarks | segments | viewport |
|---|---|---|---|---|
| **drawing** | `drawCells` / `drawOverviewRows` | `drawBookmarkMarks` | `drawSegmentStrip` | `drawViewports` |
| **damage geometry** | `overviewDamage`, `invalidateBytes` | inside `setBookmarks` | `invalidateAll` (blunt) | `viewportDamage` |
| **hit-testing** | `byteOffset`, `fileEdgeOffset` | `nearestBookmarkMark` | `segmentStripClick`, `nearestCut` | the drag grab in `mouseDown` |
| **data intake** | `setOverviewSummaries`, `updateOverviewRows` | `setBookmarks` | `setSegmentBlocks` | `setViewports` |

`draw(_:)` already reads as a list of layers — cells, strip, band, marks,
selection, dividers, in that order and for stated reasons. Working on one feature
hurts because its damage geometry, its hit-test and its intake sit four hundred
lines apart from each other and from its drawing, and because each of them
re-derives the same geometry independently.

That is also the answer to "will this reduce the scope of a change": it will, but
only if a layer owns all four obligations. A protocol with `draw()` alone would
move a hundred tidy lines and leave the mess.

## The part worth doing first: the index guide

`MinimapGeometry` — a pure value type, no AppKit view — holding the map layout,
the render mode, `topRow`, the bounds and the file sizes, and answering:
`area(forMapAt:)`, `contentArea`, `segmentStripRect`, `y(of:)`, `offset(atY:)`,
`rowRange`, `visibleRowCount`.

Today every one of those is a private method on the `NSView`, which means the
byte↔pixel mapping — the thing every layer depends on and every off-by-one bug
lives in — can only be exercised through a window and a render pass.

The precedent is in the repo already: `HexLayout.swift` is exactly this for the
hex grid, deliberately AppKit-free "so the layout has no AppKit dependency and is
unit-testable". The minimap simply never got its equivalent. That asymmetry is
worth fixing on its own merits, before any decision about layers: it is
behaviour-preserving, it leaves the existing tests untouched, and without it no
layer can be extracted as a self-contained module anyway — each one would drag a
copy of the geometry with it.

If only one thing from this document is ever built, build this.

## The layer protocol

With the geometry extracted, a layer becomes a real object. The order of the
array gives both the z-order and the hit-test priority, which is what the code
already does by hand:

```swift
protocol MinimapLayer {
    func draw(in g: MinimapGeometry, dirty: NSRect)
    func damage(in g: MinimapGeometry) -> [NSRect]?   // nil = repaint everything
    func hitTest(_ p: NSPoint, in g: MinimapGeometry) -> MinimapTarget?
    func tooltip(at p: NSPoint, in g: MinimapGeometry) -> String?
}
```

This fits bookmarks and segments honestly — they are genuinely independent
planes, and each would collapse into one file of a few hundred lines where a
change to the feature is a change in one place. Those two are the whole case for
the idea.

## Where the abstraction leaks

Four things do not fit the picture, and pretending otherwise is how a refactor
like this turns into a worse file than the one it replaced.

1. **The viewport band does not belong to a map.** Side by side it is a *single*
   rectangle drawn across *both* maps — that is the point of it, and `draw(_:)`
   says so: the band cannot belong to a per-map pass. So there are two kinds of
   layer, per-map and per-panel, or a layer that asks the geometry for every
   map's area. Either is fine; discovering it halfway through is not.

2. **The divider yields to the band.** `drawVerticalDivider(at:in:yielding:)`
   takes the viewport rects so it does not paint the seam back into the shared
   band. That is a direct dependency between two layers. Either the divider
   becomes part of the geometry (a seam the layers know not to cross) or one
   layer keeps knowing about another.

3. **`renderMode` is a second axis, perpendicular to the layers.** Detail vs
   overview branches inside *every* feature: the marks, the band's shape, the
   offset mapping, the click snapping. Layers do not remove that branch — they
   relocate it, one branch per layer instead of scattered through a 2500-line
   file. That is a genuine improvement, but the tempting fix (two sets of layers,
   one per mode) duplicates the features and should be refused.

4. **Overview is a subsystem, not a layer.** `overviewBinsAreStale`, the stand-in
   images, the settle timer, `overviewDamage`, the background binning pass — a
   few hundred lines of state and scheduling. That is a model (`OverviewStore`)
   owned by the controller, with the layer merely drawing what it is handed. Half
   of this is true already: the summaries are computed off the main thread in
   `MainViewController` and handed over through `setOverviewSummaries`.

## The same move in the hex panes?

No. `HexView` is a different shape, and the layer protocol would be a stretch
there.

In the minimap, layers are independent planes with their own z-order. In
`HexView` the painting order is nested *inside a single row*: `drawSegmentTint`,
then `drawSelectionFill`, then the byte's glyph, then `drawBookmarkMark`, then
the caret — all within `drawRow`. Those cannot be reordered and cannot be drawn
in separate passes without walking the grid several times. It is not a stack; it
is one traversal.

More to the point, `HexView` already did the valuable half of this refactor:
`HexLayout` is its index guide. What is left there is not layering but the
*non-drawing* obligations — input and keyboard navigation, drag autoscroll, and
the cross-column link contours (a few hundred lines of pure geometry) — which
can move into their own types without touching the render pass at all. That is a
separate, smaller cleanup, and it does not need this idea to justify it.

## Order of work, and how to tell it worked

1. Extract `MinimapGeometry`. Behaviour-preserving; the existing tests should not
   need editing, which is itself the check.
2. Pilot the layer protocol on **bookmarks** — the smallest and most isolated of
   the four, and the only one with no cross-map or cross-mode entanglement.
3. Stop and answer one question: did the next change to bookmarks actually fit in
   one file? If yes, move segments and the viewport. If no, an evening is lost
   rather than the whole render path.

**The tests are the hidden cost.** `MinimapTests`, `BookmarkMinimapTests`,
`SegmentTintRenderTests`, `ContentRedrawTests` and `SelectionRedrawTests` assert
against the view's internal surface — `visibleCells(forMapAt:)`,
`selection(forMapAt:)`, `viewport(forMapAt:)`, and the invalidated rectangles.
Step 1 leaves all of that alone. Step 2 onwards rewrites it, layer by layer,
which is the real argument for piloting on one feature first.

**Cost.** 6–10 hours for the geometry, 4–6 for the bookmarks pilot, 15–20 for the
remaining three layers if the pilot earns them. The geometry step stands alone
and is worth doing whatever is decided about the rest.
