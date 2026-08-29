# Dragging panes, and a drop zone for a new tab

> Stands on `TABS_PLAN.md`. Everything here is a *gesture* over machinery that
> already exists: swapping two panes, tearing one off into a tab, and moving one
> into another tab are all model operations with commands and tests already.
> What is new is reaching them with the mouse — and that the app has never begun
> a dragging session in its life.

## Why

Three things are awkward today, and all three are shaped like a drag:

- **Opening a dump in a new tab** means opening it into the current window and
  then tearing the pane off, or making the tab first and dropping into it. Both
  are two steps for what the hand wants to do in one.
- **Moving a pane to another tab** is a menu command (`Open in New Tab`) or a
  dialog answer (`Move to This Tab`). Both work; neither is what a hand reaches
  for when the pane is right there and the tab is an inch away.
- **Swapping the two panes** is `View ▸ Swap Panels`, which is a fine command and
  a poor gesture: the panes are side by side and the obvious act is to pick one
  up and put it on the other.

## What the codebase brings, and what it does not

The receiving half is well developed. `DropTargetView` is the visual (a milky
plate, flooded accent-blue on hover, caption on frosted glass), `DropZoneView`
and `PaneDropBandsView` own the drop handling, and `DropBandLayout` is a pure,
view-free type that decides which band a point falls in — tested at several
heights without a window.

The initiating half does not exist. **The app has never created an
`NSDraggingSession`.** Every drag it handles today either comes from Finder
(`registerForDraggedTypes([.fileURL, .fileNames])`) or is a mouse track inside
one view — the bookmark drag in `HexView` is `mouseDown`/`mouseDragged` with a
hysteresis, and never touches a pasteboard. So the pane drag is genuinely new
machinery, and it is worth building on the simplest case first.

## One drag, three destinations

A pane is picked up by its header. Where it lands decides what happens, and each
of the three already has a tested implementation behind it:

| Dropped on | Means | Existing operation |
| --- | --- | --- |
| the other pane of the same window | **swap** | `WindowViewModel.swapPanes()` |
| a pane of another tab | **move into that slot** | `movePaneHere(from:at:into:)` |
| the New Tab strip | **tear off into a new tab** | `releasePane(at:)` + `adoptPane(_:bookmarks:)` |
| anywhere else | nothing, the pane animates back | — |

That the drag adds no new model operations is the point. It is a second way to
reach the same four verbs, not a second implementation of them.

## What travels on the pasteboard

Not the bytes, and not a file URL: a pane is not a file, and a URL would invite
every other app to accept the drag. A private type — `dev.maxik.DumpCompare.pane`
— carrying the dragged pane's identifier, which makes the drag meaningless
outside this process and refused by Finder for free.

The identifier resolves through `OpenDocumentRegistry`, which already answers
"which window holds this file?" by walking the live controllers and asking each
one. "Which window holds this pane?" is the same question in the same shape, and
gets the same answer: **nothing is stored**, so a pane that has been closed or
moved mid-drag is simply not found, and the drop does nothing.

`PaneViewModel` gains a stable identity for this. It is the object's own, not the
document's — the pane is what moves, and it keeps its identity across a move for
the same reason it keeps its undo history.

## The New Tab strip

**The system tab bar cannot be a drop target.** It is AppKit's own view inside
the title bar, and nothing public exposes its empty area, the gaps between tabs,
or the + button. `NSWindowTabGroup` is `windows`, `selectedWindow` and
`isTabBarVisible`; there is no view and no frame to aim at.

**A titlebar accessory was tried, and does not work.** A
`NSTitlebarAccessoryViewController` with the default `.bottom` attribute is a
full-width view of ours, and the documentation places it "under the titlebar",
which sounded like under the tab bar. It is not: AppKit puts it **above** the tab
bar, between the bar and the toolbar, where the pointer cannot reach it without
crossing the bar.

It failed a second time on its own merits, and that failure is the more useful
one to record. Showing a `.bottom` accessory moves the content down, which made
a loop out of aiming at it: leaving the panes hid the strip, the content rose,
the pointer was over a pane again, the strip came back, the content dropped, the
pointer was out again. **Anything that changes the layout in response to where
the pointer is will do this.**

So the strip lies across the top of the content, under the tab bar, overlaying
it rather than displacing it. It costs the top band something — `Insert at Start`
starts lower and is shorter — and that is the price of the only position
available.

**Its visibility follows the drag session, not one overlay.** It is raised when a
drag enters any destination in the window and taken down only when the drag
*ends* — never when the pointer merely leaves an overlay, because leaving is
exactly what aiming at the strip looks like from below. Hiding it then takes the
target away at the moment it is being reached for, which is the quieter half of
the same loop and is a bug with or without an accessory.

**The trap the position brings** is recorded in `PaneDropBandsView` already:
**AppKit resolves a drop destination by frame among registered views**, not
through `hitTest:`, and the comment notes this once caused a dropped file to be
silently discarded. The strip must be the frontmost registered view over the
points it covers, and the overlays underneath must inset their bands by its
height so the two never disagree about who owns a point. `DropBandLayout` gains a
top inset for that, and the controller *measures* it rather than assuming it: the
strip spans the content's width, but in a stacked comparison only the upper pane
is under it.

**Not taken, and worth its own turn later:** `NSWindowTab.accessoryView` is a
view of ours *inside a tab*, so a tab can itself be a drop target — "drop this
file on that tab and open it there". That is a different feature from the strip
and carries its own cost (the accessory takes room in every tab, always), so it
is recorded rather than folded in.

## Picking a pane up

The header is not free. `PaneHeaderView` already answers a double-click (fit the
pane to its content width, §3.3) and a right-click (the pane's File menu), and
its `hitTest` deliberately routes every click to the bar itself except the close
button's. A drag has to coexist with all of that, so it starts only after the
pointer has moved a threshold from where the mouse went down — the same shape as
`HexView.bookmarkDragHysteresis`, and for the same reason: a gesture that begins
on the first stray pixel steals the clicks that were meant for something else.

The drag image is the header's own snapshot, so what the hand carries is what it
picked up.

## Settled by experiment

**The tab bar spring-loads.** Hovering an inactive tab during a drag switches the
window to it without releasing the mouse — confirmed with a file drag from
Finder on the current build, which is a fair proxy: spring-loading is the bar's
decision and does not depend on what is being dragged.

This is what makes "drag a pane into another tab" reachable at all. Tabs are
windows and only the front one is visible, so without it there would be nowhere
to drop, and the feature would have shrunk to moving panes between separate
side-by-side windows.

## A drop that lands nowhere

The pane animates back and nothing happens. Dropping outside every window does
**not** make a new window: an accidental drop onto the desktop would otherwise
produce a window nobody asked for, and the deliberate version of that act already
has a name — the New Tab strip, and `Move Tab to New Window` in the Window menu
for the tab itself.

## Edge cases

- **Dropping a pane on itself** — nothing.
- **A window with one pane.** Swap has no partner, but the tear-off and the move
  are both meaningful, so the drag is still offered; the source window is left
  empty, which is what closing its last pane does too.
- **Displacing a dirty pane** goes through `confirmReplaceDirtyPane`, the prompt
  every other replacement already uses.
- **The source window closing mid-drag** resolves to no pane, and the drop does
  nothing — a property of the registry storing nothing rather than a check.
- **Bookmarks** follow the rules `TABS_PLAN.md` already set: copied into a new
  tab (which has none), adopted from the receiving window on a move (which has
  its own).

## What is testable, and how

A dragging session is not unit-testable, so the decisions are pulled out of it —
the pattern `DropBandLayout` and `OpenPlacement` already set in this codebase.

- **`DropBandLayout` with a top inset** — pure, and covers the strip's share of
  the pane.
- **The drop's meaning** as a pure function of *what* is on the pasteboard, *which*
  window it landed in and *which* pane: swap, move, tear off, or nothing. Every
  branch testable with no views at all.
- **The registry's pane lookup**, beside the file lookup it already has.
- The four operations underneath are already covered by `TearOffTests` and
  `MultiWindowTests`.

What is left for the hands: that the session starts, that the image looks right,
and that the strip highlights.

## Implementation plan

**1. Identity and meaning, no UI.** `PaneViewModel` gains an identifier, the
registry gains the pane lookup beside its file lookup, `DropBandLayout` gains the
top inset, and the drop-meaning function is written and tested. Nothing on screen
changes.

**2. Swap by drag, inside one window.** The whole session mechanism — the
threshold on the header, the pasteboard item, the drag image, the pane overlay
learning to show a single *Swap* plate for a pane drag instead of its three file
bands — on the one destination that never leaves the window.

**3. The New Tab strip, for files.** Feature 1 whole: the strip, the inset bands
below it, and a file dropped on it opening in a new tab. Independent of the pane
drag, and shippable on its own.

**4. The strip and the other tabs, for panes.** The strip accepts a pane (tear
off), and a pane dropped on another tab's pane moves into that slot. This is the
step spring-loading makes possible, and it is last because it is the only one
that needs two windows to test by hand.

## Decisions taken

- The system tab bar cannot host a drop zone; the strip lives at the top of our
  own content, full width, and takes its height off the pane bands.
- The drag carries a private pasteboard type and a pane identifier, resolved
  through the registry, which stores nothing.
- A pane dropped on the other pane of its own window swaps; on a pane of another
  tab, moves into that slot; on the strip, tears off into a new tab.
- A drop that lands nowhere returns the pane and does nothing.
- The drag begins only past a movement threshold, so the header keeps its
  double-click and its context menu.
