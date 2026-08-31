# View and interactor — an idea, thought through

Not a plan. `MainViewController.swift` is 5484 lines, and the proposal is to stop
keeping logic and action handling in it: the view controller builds and shapes
views, and an interactor per feature owns the flow behind each command. This
document is what that idea looks like after taking it apart — what is actually in
those lines, which part an interactor is the right answer for, where the
abstraction leaks, and what the repo already does that this should look like.

The verdict up front: the idea is sound for one of the three things tangled in
that file, and the target is **not** action handling. The actions are already
thin — 63 of them, 516 lines all told, median 4 lines each. Nothing needs to be
lifted out of them, because there is almost nothing in them. The mass is in the
flows they call, in one whole subsystem that moved in and never left, and in view
construction; and those three want three different exits.

## What is actually in the 5484 lines

| lines | what | where it wants to go |
|---|---|---|
| ~730 | `loadView`, `viewDidLoad`, `apply(mode:)`, `wireComparison`, `paneView(for:)`, content/strip layout | stays — this *is* the view controller |
| ~1290 | minimap: the panel, overview, its data, the segment strip's legend | its own object; not an interactor question |
| ~2000 | feature flows: open, save/revert, join, duplicate, new file, segments, writing pieces out, bookmarks, search, closing | the interactor's real subject |
| ~480 | the pane's context menus, toolbar and menu validation | stays, deliberately (below) |
| ~500 | panes, tabs, drag-and-drop meaning and performance | mostly stays: it shapes windows |
| ~200 | alerts, dialogs, test seams | becomes the presenter boundary |

The same split shows in the state, which is the number that matters more than the
line count: **61 stored instance properties**, of which

- **17 are minimap and overview** — `overviewDebounceTask`, `overviewPassTask`,
  `overviewRowsAwaitingIndex`, `overviewRebuilds`, `overviewPatches`,
  `overviewProgress`, `overviewProgressReveal`, `minimapViewports`, and the rest.
  That is not a view controller's state. It is a subsystem's, and
  `MINIMAP_LAYERS_IDEA.md` says the same thing from the other side: overview is
  "a stateful subsystem (a model the controller owns) rather than a layer".
- **11 are one in-flight flow or another** — `findTask`, `findOperation`,
  `searchAllGeneration`, `segmentWriteTask`, `segmentWriteOperation`,
  `openEditing`, `openGoToForm`, `openSegmentsForm`. Each belongs to exactly one
  feature and is touched by nothing else.
- the rest are view handles, the window model, the diff-navigation flags and
  configuration.

## Why extensions alone plateau

Splitting the file into extensions in one folder is cheap, reversible and worth
doing regardless — it is what the rest of this cleanup did. But it stops at a
wall: **an extension cannot hold stored state.** All 61 properties stay on the
class, so `MainViewController+Minimap.swift` still reaches into seventeen
properties declared a thousand lines away, and every `private` that crosses the
new file boundary has to widen to `internal` — the compiler stops saying "only
this file touches this".

That is the honest argument for an interactor rather than more extensions: a
flow with its own state should own that state. It is also the argument for not
doing it everywhere — a flow with no state gains nothing but a hop.

## The precedent is in the repo already

Two tiers of this already exist here, and they work.

**Pure rules**, AppKit-free and tested without a window: `HexLayout`,
`DropBandLayout`, `OpenPlacement`, `PaneDrop.outcome`, `DuplicateName`,
`PaneName`. Whenever a decision could be stated as a function of values, it was
moved out, and those are the tests that never break for the wrong reason.

**One coordinator**: `ComparisonCoordinator`. Look at its shape —

- inputs arrive through a closure (`provider: () -> (left:right:)?`) rather than
  a reference to the controller, so it cannot reach for anything else;
- results leave through callbacks (`onIndexChanged`, `onOperation`);
- it owns a lifecycle (`start`/`record`/`rebuild`/`stop`/`cancelBuild`) and the
  state that lifecycle needs, including a generation counter;
- it is `@MainActor`, and it knows nothing about any view;
- its tests construct it, not a window.

That is an interactor that was never called one. Whatever this idea produces
should look like `ComparisonCoordinator`, not like a new architecture.

**What is missing is the middle tier**: the flows. A flow is not a pure rule —
it asks the user things, opens panels, runs background work, reports errors — and
it is not a coordinator of one long-lived index either. It is a short-lived
transaction with a UI conversation in the middle of it.

## The boundary has already been discovered by the tests

The file has **13 injected closures**: `joinOpenPanel`, `joinConfirm`,
`segmentDirectoryPanel`, `segmentSavePanel`, `segmentOpenPanel`,
`segmentWriteConfirm`, `segmentWriteRunner`, `bookmarkEditPresenter`,
`cutEditPresenter`, `goToFormPresenter`, `segmentsFormPresenter`,
`makeSiblingTab`, plus the static `modalResponder`.

They exist because the test suite needed to drive a flow without a panel or a
modal. Which is to say: **the interactor's protocol is already written, one
function at a time, by the tests.** Giving those twelve members a name is most of
the design work, and the fact that they were discovered rather than invented is
the strongest evidence that the seam is real:

```swift
@MainActor
protocol FlowUI {
    func chooseFile(_ configure: (NSOpenPanel) -> Void) -> URL?
    func chooseDirectory(message: String) -> URL?
    func chooseSaveLocation(named: String) -> URL?
    func confirm(_ alert: NSAlert) -> NSApplication.ModalResponse
    func presentError(_ title: String, _ error: Error, url: URL?)
    func present(form: ...)
    func reveal(offset: UInt64, in pane: PaneViewModel)
    func refreshMode()
}
```

The real controller implements it with panels and sheets; the tests implement it
with canned answers, and stop injecting twelve closures one at a time.

## Where the abstraction leaks

**Flows call each other.** A close can contain a save; a join contains the
dirty-pane prompt; a drop contains the already-open resolution; Save All
Segments contains a directory choice *and* an overwrite confirmation. A graph of
interactors phoning each other is worse than the one class they came from. The
test to apply: if flow A needs flow B, does it need B's *decision* (fine — pass
the answer in) or B's *conversation* (a smell)? If it turns out that most of them
need each other's conversations, then **one `DocumentFlows` object is more honest
than five that call each other**, and this idea shrinks to "move the flows out of
the view controller", which is still worth doing.

**`refreshMode()` is the universal back-channel.** Almost every flow ends by
asking the window to re-shape itself, because opening, closing, joining and
duplicating all change how many panes there are. That is legitimate — but it must
be one narrow method on the UI protocol, not a `MainViewController` reference. The
moment a flow holds the controller, this is finished and the file just moved.

**Menu validation should not be split.** `validateMenuItem` is one switch over 63
selectors, and it reads state from every feature. Distributing it — a registry of
per-feature validators, a chain — is the tempting move and the wrong one: it
turns one readable list of enablement rules into a lookup, and enablement is
exactly the kind of thing that should be readable end to end. It stays in the
controller and asks the interactors when it needs to.

**The test-mode statics become homeless.** `isRunningTests`, `modalResponder`,
`lastAlertTitle`, `minimapDefaults`, `overviewProgressDelay` — window-scoped
hooks that live on the class today. Decide where they go *before* moving code,
not while.

**Undo must not gain a second home.** Flows record their steps through
`PaneViewModel` onto the document's undo history. An interactor that starts
knowing how to undo its own work is a second mechanism, and there is a reason
§22.2's join is one transaction.

## Order of work, and how to tell it worked

1. **Minimap out first.** ~1290 lines and 17 of the 61 properties, and it is not
   an interactor question at all — it is a subsystem with a bad address. Doing
   this first also means the interactor decision is taken with a file half the
   size, which is a better place to take it from. This is `MINIMAP_LAYERS_IDEA`'s
   first step seen from here.
2. **Then one flow, chosen to be the hardest fair test**: writing pieces out
   (§21.5) — 490 lines, four of the thirteen seams, its own task and operation
   state, a confirmation and a background write. If `SegmentWriteFlow` reads
   better than what it replaced and its tests get shorter, the pattern is earned.
   If it needs six back-channel methods, it is not, and stopping after one is the
   whole point of choosing this one first.
3. **Then decide, once, whether the rest follow** as separate flows or as one
   `DocumentFlows`. Not before: this is the question the pilot exists to answer.
4. Menus, validation and view construction stay. So does the drag-and-drop
   meaning, which is about windows and panes, not about documents.

The measures worth watching, in order:

- **stored properties on `MainViewController`** — 61 today. Line count is not the
  metric: eleven 500-line files that all reach into each other are worse than one
  5484-line file.
- **a flow's test constructs the flow**, not a controller in a window.
- opening `MainViewController.swift` stops being how you change a feature that is
  not about the window.

**Anti-goal.** Not MVVM-C, not a protocol per class, and not an interactor for
flows that have no state and ask the user nothing — `duplicateDocument()` is
three lines and should stay three lines.
