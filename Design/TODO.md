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

---

## Later

*(nothing yet)*

---

## Someday

*(nothing yet)*

---

## Done

*(nothing yet)*
