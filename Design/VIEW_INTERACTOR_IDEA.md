# View, interactor, coordinator — an idea, thought through

Not a plan. The proposal is a division of roles brought from iOS work, where it
has earned its keep:

- **View / view controller** — UI only: composing components, layout, colours,
  fonts, gestures, drawing. No handling of user actions beyond a complex view's
  own internals, and no presenting of other views.
- **Interactor** — the logic behind the UI: user actions, preparing what the view
  shows, deciding what happens next. Knows nothing about how the view is built;
  reaches it through a protocol.
- **Coordinator** — navigation and presentation: transitions, navigation chrome,
  presenting child views.

With three rules holding it together:

1. The view forwards every action to an `Actions` protocol and decides nothing.
2. **The interactor decides about navigation; the coordinator performs it.** The
   rule most often lost — a coordinator that decides *when* to present is a
   second interactor with windows in it.
3. **The interactor never holds a view, and never imports AppKit.** It is pure
   logic. Where an action is tied to a component, a **context object** travels
   with it: opaque to the interactor, meaningful to the layer that presents. The
   interactor passes it through as a black box and never looks inside.

The third is a law rather than a guideline, and it is the one this codebase can be
measured against.

This document is what that scheme looks like after taking it apart against *this*
codebase and against AppKit: which parts are already here under other names,
where the platform pushes back, and what it costs.

The verdict up front: the roles are right and two of the three already exist here
in embryo. What needs adapting is not the boundaries but the *directions* — on
macOS actions arrive from the menu bar rather than from the view, validation has
to be pulled rather than asked, and the coordinator's subject is barely
navigation at all. And the whole thing has to be sized for an app whose entire
UI layer is 25k lines: six interactors, not forty.

## What is actually in the 5484 lines

`MainViewController.swift` is the file this is about.

| lines | what | role it belongs to |
|---|---|---|
| ~730 | `loadView`, `viewDidLoad`, `apply(mode:)`, `wireComparison`, `paneView(for:)`, content and strip layout | view |
| ~1290 | minimap: the panel, overview, its data, the segment strip's legend | interactor (a subsystem, below) |
| ~2000 | open, save/revert, join, duplicate, new file, segments, writing pieces out, bookmarks, search, closing | interactor |
| ~480 | the pane's context menus, toolbar and menu validation | view, answering from a snapshot |
| ~500 | panes, tabs, drag-and-drop meaning and performance | coordinator (app-level) + interactor |
| ~200 | alerts, sheets, popovers, forms | coordinator (window-level) |

The state says the same thing more precisely, and it is the number to watch:
**61 stored instance properties**, of which

- **17 are minimap and overview** — `overviewDebounceTask`, `overviewPassTask`,
  `overviewRowsAwaitingIndex`, `overviewRebuilds`, `overviewPatches`,
  `overviewProgress`, `overviewProgressReveal`, `minimapViewports` and the rest;
- **11 are one in-flight flow or another** — `findTask`, `findOperation`,
  `searchAllGeneration`, `searchAllPane`, `segmentWriteTask`,
  `segmentWriteOperation`, `openEditing`, `openGoToForm`, `openSegmentsForm`;
- the rest are view handles, the window model, diff-navigation flags and config.

Action *handling*, by contrast, is not the problem: 63 `@objc` actions, 516 lines
between them, median 4. They are already adapters. What is massive is what they
call.

## What already plays these roles here

| role | what plays it today | what is missing |
|---|---|---|
| interactor | `ComparisonCoordinator` — provider closure in, callbacks out, its own lifecycle and state, `@MainActor`, no view in sight, tests construct it directly | the name, and the other flows |
| coordinator (window) | `bookmarkEditPresenter`, `cutEditPresenter`, `goToFormPresenter`, `segmentsFormPresenter`, `joinConfirm`, `segmentWriteConfirm`, the panel seams | one object instead of twelve closures |
| coordinator (app) | `AppDelegate`, `OpenDocumentRegistry`, `makeSiblingTab` | a boundary; today it is spread through the window controller |
| pure rules | `HexLayout`, `DropBandLayout`, `OpenPlacement`, `PaneDrop.outcome`, `DuplicateName`, `PaneName` | nothing — this tier works |

`BookmarkEditRequest` is worth looking at closely, because it is the
interactor→coordinator hand-off already written: a value carrying *what* to edit
(`pane`, `row`, `existingName`) plus `commit` / `cancel` / `delete`, given to a
presenter that returns how to dismiss what it opened. Note what it does **not**
carry: the popover's anchor. The presenter finds that from the pane's view. That
is exactly the right split, and it was arrived at by need rather than by design —
the seam exists so tests can drive the command without a popover that closes the
instant it opens in an offscreen window.

The twelve injected closures are the other half of that: they exist because a
flow had to be drivable without a panel or a modal, which means the boundary was
*discovered* rather than designed. But they are the **coordinator's** protocol,
not the interactor's, and six of them break the third rule outright:

```swift
var joinOpenPanel:        ((NSOpenPanel) -> URL?)?
var joinConfirm:          ((NSAlert) -> NSApplication.ModalResponse)?
var segmentDirectoryPanel:((NSOpenPanel) -> URL?)?
var segmentSavePanel:     ((NSSavePanel) -> URL?)?
var segmentOpenPanel:     ((NSOpenPanel) -> URL?)?
var segmentWriteConfirm:  ((NSAlert) -> NSApplication.ModalResponse)?
```

An interactor cannot hold any of these: the types are AppKit. They have to be
re-stated in the domain's own words before an interactor can own the flow —

```swift
protocol JoinPresenting {
    func chooseFileToJoin() -> URL?
    func confirmJoin(named: String, verb: String, dirty: Bool) -> Bool
}
```

— which is worth doing on its own merits: the tests currently build an `NSAlert`
and read its buttons to answer a question the flow asked in domain terms in the
first place. The controller keeps the panels and the alerts; what crosses the
boundary is a URL and a yes.

The same applies to the AppKit services these flows reach for today, and each has
an obvious side of the line: `NSAlert` (17 uses) and the panels go to the
coordinator, `NSSound.beep()` is presentation, `NSWorkspace` (Show in Finder) is
presentation, and `NSPasteboard` is a system port — either behind a protocol the
interactor can hold, or left in the view layer, but not imported.

## Where AppKit pushes back

### Actions arrive through the responder chain, not from the view

On iOS an action starts in a view. Here most of them start in the **menu bar or
the toolbar**, sent to no particular target: `NSApp` walks the key window's
first responder, its superviews, the view controllers, the window, the window
controller, itself, then the app delegate. `MainViewController` is a first-class
action receiver on this platform, not a wiring accident.

So the scheme gains a second, equal door: the view controller receives menu and
toolbar commands and forwards them into the same `Actions`. It is the
responder-chain adapter, and that is a role, not a leak.

The consequence is a rule: **the interactor must not be in the responder chain.**
It is called, never messaged. Putting it there would move first-responder
semantics — which pane is focused, which window is key — into the logic layer,
where they cannot be reasoned about.

### First responder is view-layer state, so actions carry their subject

"Which pane is active" is decided by focus: `focusHexView()` → `onFocus` →
`onActivate`, and focus stays the single source of truth (§3.3). An interactor
needs to act on a pane but must not own focus.

Therefore every `Actions` call carries its subject — *append a file to this
pane*, not *append a file to whatever is active*. The pane menu already works
this way, pinning its pane in `representedObject` so a right-click acts on the
header it was opened from rather than on the active pane. The same rule, applied
to the whole boundary.

### Validation wants a snapshot, not a question

`NSMenuItemValidation` and `NSToolbarItemValidation` are protocols on the
*responder*, so the view controller has to answer them — and it is asked on
**every menu open, for every item**: dozens of synchronous calls in a burst, 63
selectors in one switch here.

Asking the interactors per item is the obvious move and the wrong one. The right
direction is inverted: each interactor keeps a small **state snapshot** (a value:
`canRevert`, `canJoin`, `hasSelection`, …), updated when its state changes, and
validation reads it. Cheap, synchronous, and it keeps enablement readable end to
end — which is why `validateMenuItem` should stay one switch rather than become a
registry of per-feature validators.

So the interactor→view channel is two channels: **pushed updates** (protocol
calls, "the results changed") and a **pulled snapshot** (what is possible right
now).

### Presentations are anchored and per-window, so the coordinator splits in two

A popover opens relative to a rect in a view (`show(relativeTo:of:)`); a sheet
belongs to a window (`beginSheet`). An interactor cannot know a rect and must not
hold a view — rule three. Two mechanisms, and both are needed:

- The interactor emits a **request value** and the coordinator resolves it into a
  presentation, finding the anchor itself. That is `BookmarkEditRequest` today:
  it carries `pane`, `row`, `existingName` and what to do about them, and
  deliberately not the anchor.
- When only the view knows where the thing is — a clicked row, a mark on the
  minimap, a byte in the dump — a **context object** rides along from the view,
  through the interactor, to the coordinator. The interactor takes it as an
  opaque token and hands it back with the request; the coordinator is the only
  side that knows it holds a rect and a view. This keeps "anchor the popover on
  the row that was clicked" possible without the interactor learning what a row
  is, and it is the piece that makes rule three survive contact with popovers.

And "navigation" barely exists here. There is no stack and no current screen: a
window shows two panes, a minimap, a find bar, a results panel and a tab bar at
once, all long-lived. What looks like navigation mostly belongs to the *system* —
`allowsAutomaticWindowTabbing` is what gives ⌘T, ⌃Tab, dragging a tab out into
its own window, and the Window menu's Merge All Windows. A coordinator cannot own
those; it can only answer them.

So the role divides along a real seam:

- **window coordinator** — sheets, popovers, forms, the alerts. Needs the window,
  and must behave when there is none (a controller built in a test).
- **app coordinator** — windows, tabs, and which window holds which file. This is
  where `OpenDocumentRegistry` already lives, and it answers a question no window
  can: a file is open once in the app (§4.1 rule 6).

One protocol over both would be forcing it. The split is the point; the names are
a choice.

### Modality: pick synchronous or async once

Today the confirmations are synchronous `runModal` with a test seam, and a good
deal of flow logic reads as straight-line code because of it. An interactor that
`await`s a decision reads better still — but `await` plus `runModal` is a
re-entrancy trap, so going async means `beginSheetModal` throughout and rewriting
the flows as continuations. Both are defensible; mixing them is not. This is a
decision to take before the first interactor, not during.

### Data-source views pull; they are not handed view models

`HexView` is virtualized: it asks for the byte state of the rows it is about to
draw (`HexViewDataSource`, `hexByteStates`). A strict reading of "the interactor
prepares what the view shows" would push a formatted row model per row — a
rewrite, and a regression on a 16 MB dump.

The carve-out: for a data-source view, the interactor (or the model beneath it)
supplies a **pull interface**, not pushed data. The boundary is unchanged — the
view still holds no logic — only the direction is. `PaneViewModel` is already
that interface.

### One notification idiom, not three

Combine would be a third way to say "something changed" beside the closures
(`onEdit`, `onIndexChanged`, `onHeaderChanged`) and the async work already here,
and then every update carries the question of which of the three it travels by.
The interactor→view channel has many members, which is precisely the case a
protocol serves. Keep one idiom.

### A subsystem is an interactor whose actions are not user actions

The minimap's overview is 1290 lines and 17 properties of tasks, debounces,
progress and generation counters. It is not a user-action flow — nothing about it
starts with a click — but it is exactly "logic that prepares what the view
shows", so the interactor is its home. Worth naming explicitly, or it gets left
in the view controller as "drawing support" forever.

## The model layer, which this scheme does not touch

The three roles exist to untangle smart views — views with several jobs mixed
into them. Models are not part of that and go on as they are; the interactor is
what talks to them.

`PaneViewModel` is one, and it is in better shape than its name: it imports
`Foundation` and `DumpCompareCore` and nothing else, and the only `NS` symbol in
1877 lines is an `NSObjectProtocol` observer token. So does the rest of the
tier — `WindowViewModel`, `SegmentStore`, `BookmarkStore`, `ComparisonCoordinator`,
`BackgroundOperation`: all Foundation. **Rule three is already affordable here**,
because the layer an interactor would stand on is AppKit-free today. All of the
AppKit is in the view controller, which is exactly the file this is about.

`PaneStatus` is the shape to notice: a value of domain facts — name, size, caret
offset, dirty, read-only, undo/redo, insert mode, the caret's piece — and no
formatting. "The caret's offset, raw — the view renders it as bare hex" is a
comment in it. That is a model handing out a snapshot, not a view model preparing
strings, and it means the display path for panes needs no interactor inserted
into it: the model answers, the view formats.

**The name is wrong, then.** `PaneViewModel` is a leftover of an MVVM framing the
code does not follow: it owns the document, the undo history, the segments and
the pane's own state, and it answers the hex view as a data source. `PaneModel`
(or `PaneDataModel`, if the suffix is the house convention) says what it is. The
property that holds the window's one is already called `windowModel` in 136
places, so half the codebase reads it as a model already.

The rename is mechanical and wide: 80 references across 7 app files and 124
across 39 test files. Worth doing as its own commit, before any interactor exists
to be confused with it — a file called `PaneViewModel` sitting next to a
`SearchInteractor` invites exactly the wrong guess about which one holds the
logic.

## What it costs, and the shape that keeps it affordable

Eleven features × (view + `Actions` + interactor + coordinator protocol) is
around forty new types for an app whose UI layer is 25k lines. At that size the
scheme costs more than it saves. What keeps it honest:

- **Interactors by feature group, not by screen**: documents, editing, search,
  segments, bookmarks, minimap. Six.
- **Two coordinators for the whole app**, not one per feature.
- **`Actions` protocols only where a view actually talks to an interactor.** A
  three-line action that toggles a setting does not need a protocol to travel
  through.
- Flows that need each other need each other's *answers*, not their
  *conversations*. If most of them need conversations, one `DocumentFlows` is
  more honest than six interactors calling each other.

## The pilot: search

It is already in position. The results panel is a controller that owns its
content, its own composition, and nothing else (`SearchResultsViewController`).
Two things are missing, and both are named:

1. **`SearchInteractor`** takes `findTask`, `findOperation`,
   `searchAllGeneration`, `searchAllPane`, and the decisions — start, supersede,
   cancel, show the panel, hide it. Note what it must *not* take: the panel's
   height, its divider and the stored preference, which are the pane's
   arrangement of its own chrome.
2. **`SearchResultsActions`** replaces the panel's two closures, so the panel
   stops knowing who listens.

The coordinator barely appears in this pilot, because the panel is embedded —
which is the argument for going first here. The View↔Interactor boundary gets
tested on its own, and the coordinator gets its real test later on bookmarks and
segments, where the popovers and sheets are.

If `SearchInteractor` reads better than what it replaced and its tests stop
needing a window, the pattern is earned. If it needs six back-channel methods
into the view, it is not — and stopping after one is the whole reason to start
with one.

## Order of work, and how to tell it worked

1. **Minimap out first**, before any of this: 1290 lines and 17 properties, and
   it is not an interactor question so much as a subsystem with a bad address.
   The rest is then decided from a file half the size. This is
   `MINIMAP_LAYERS_IDEA.md`'s first step seen from here.
2. **Decide the two questions above** — synchronous or async modality, and the
   snapshot shape for validation — on paper.
3. **The search pilot**, in the two commits above.
4. **Then decide, once**, whether the remaining flows follow as separate
   interactors or as one object. Not before.

The measures, in order:

- **stored properties on `MainViewController`** — 61 today. Line count is not the
  metric: eleven 500-line files reaching into each other are worse than one big
  file.
- **how many tests need an `NSWindow`.** Today the suite builds windows to drive
  flows and injects twelve closures to stub the UI. An interactor's test should
  need neither.
- opening `MainViewController.swift` stops being how you change a feature that is
  not about the window.

## Anti-goals

Not a type per role per screen. Not Combine for its own sake. Not an interactor
for a flow with no state that asks the user nothing — `duplicateDocument()` is
three lines and should stay three lines. And not a coordinator that decides: the
moment it chooses *whether* to present rather than *how*, the scheme has lost the
rule that makes it worth having.
