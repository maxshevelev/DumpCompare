# View, interactor, coordinator in an AppKit app

Reasoning and a technical design, not a plan. Two halves: whether this division
of roles suits an AppKit app, and — if it does — how the pair would actually be
built. Nothing here proposes a change to this codebase; the codebase appears as
evidence, because it is a real AppKit app of a real size and it is what the
argument can be tested against.

## The scheme

Brought from iOS work, where it has earned its keep:

- **View** — UI only: composing components, layout, colours, fonts, gestures,
  drawing, lifecycle, and receiving actions. No handling of user actions beyond a
  complex view's own internals, and no presenting of other views.
- **Interactor** — the logic behind the UI: filling the view's elements with data,
  answering user actions, talking to the data models, asking the coordinator to
  build and place things.
- **Coordinator** — lifetime and composition: it creates and destroys views,
  decides how long they live, installs them into the hierarchy, and wires
  surfaces to each other.

**"View" here means the layer, not the class.** A surface's UI half may be an
`NSView` or an `NSViewController` — that is an implementation choice made per
surface, and this document says "the view" for the UI part of a surface either
way. Where the distinction actually matters (presentation contracts are written in
terms of `NSViewController`; the responder chain includes both) it is called out
explicitly.

The pairing is the unit: **one view, one interactor, one user-facing surface**,
inseparable — and knowing nothing of each other's implementation, talking through
protocols in both directions, so either side can be replaced by a mock.

Five rules hold it together:

1. The view forwards every action and decides nothing.
2. The interactor fills the view with data, answers actions, talks to the models,
   and asks the coordinator to build, place or dismiss things.
3. **The data flow is one cycle.** View → UI events → interactor → data updates →
   view, and nothing else: no delegates back, no closures back, and no asking the
   view about its own state.
4. **The interactor decides about presentation; the coordinator performs it.** The
   rule most often lost — a coordinator that decides *when* to present is a second
   interactor with windows in it.
5. **The interactor never holds a view and never imports AppKit.** It is pure
   logic. Where an action is tied to a component, an opaque **context object**
   rides along: meaningful to the layer that presents, passed through the
   interactor as a black box it never looks inside.

Models are outside the scheme. It exists to untangle views with several jobs mixed
into them; models go on as they were, and the interactor is what talks to them.

## What the scheme is for

Before the platform: the reason to want any of this. **5484 lines in one class is
an architectural failure, not a size.** Everything is interleaved — a feature's
state, its flow, its layout and its menu validation sit hundreds of lines apart —
so orienting in it is expensive for a person, and expensive for a large-context
model too: the whole file has to be carried to change one corner of it, and
nothing in it announces where a concern begins or ends.

What is wanted is a concept that *bounds* the complexity of any one piece and
organises the code as self-contained, semantically complete elements of a
hierarchy, each with a stated role and stated interfaces to the others. The rest
of this document is an argument about whether these three roles are that concept
on this platform, and what they cost.

## The verdict, up front

The three roles do not fare equally on this platform.

- **View / interactor is a strong fit** — and a stronger fit on macOS than on iOS,
  for a structural reason rather than a stylistic one (below).
- **Of the interactor's two jobs, only one is needed here.** Answering actions:
  yes. Preparing data for display: mostly already solved, by AppKit-free models
  that hand out domain snapshots and views that format them. So an interactor in
  an app shaped like this one is a *flow* object, not a presenter.
- **Coordinator is not the weak fit — it is the role with the most work here.**
  Defined as *navigation*, it looked nearly empty on macOS, which is where I had
  it wrong. Defined as *lifetime and composition* — who builds a surface, how long
  it lives, where it is installed, what it is wired to — it is the role this app
  is missing most, and a large share of the 5484 lines is that role's work with
  nowhere to live. Whether it is one object or several is a technical question on
  this platform; the role itself is unambiguous.
- **One pair per surface is the right unit, and it prices the scheme.** Sixteen
  pairs here, six of them settings panes with a `UserDefaults` key behind them. It
  also forces shared logic *down* into models and services rather than sideways
  between interactors, which is a demand on the model tier more than on the UI.
- **The no-AppKit law is right, and needs admitted carve-outs.** Drag-and-drop,
  the pasteboard and modality are places where the domain genuinely is
  AppKit-shaped, and pretending otherwise buys a translation layer whose only job
  is restating `NSDragOperation`.

## Why the problem is worse on macOS than on iOS

This is the strongest argument *for* the scheme, and it is easy to miss.

On iOS the navigation stack imposes decomposition. A screen is a unit, a screen is
a view controller, and pushing one is the seam. Even a lazy app ends up with its
logic distributed across screens, because the framework's central metaphor is
one-screen-at-a-time.

macOS has no such pressure. A window holds many long-lived surfaces at once —
here: two panes, a minimap, a find bar, a results panel, a tab bar, a status bar —
and *none of them is a screen*. There is no push, no current screen, nothing that
says "this belongs somewhere else". So the window's controller becomes the place
where everything that concerns more than one surface goes, and no framework
metaphor pushes back.

The result, measured in this app: `MainViewController.swift` is **5484 lines** with
**61 stored instance properties**. Of those properties, 17 are one subsystem's
(the minimap's overview: debounce and pass tasks, awaiting-index rows, rebuild and
patch counters, progress reveal/hide tasks, per-map viewports) and 11 are one
in-flight flow or another (`findTask`, `findOperation`, `searchAllGeneration`,
`searchAllPane`, `segmentWriteTask`, `segmentWriteOperation`, `openEditing`,
`openGoToForm`, `openSegmentsForm`).

Two other numbers matter for judging the scheme, and they cut the other way from
what one might expect:

- **Action handling is not the problem.** 63 `@objc` actions, 516 lines between
  them, median 4 lines. They are already thin adapters. Whatever the scheme buys
  here, it is not "get the action handling out of the view controller".
- **The model tier is already AppKit-free.** `PaneViewModel` imports `Foundation`
  and the core package and contains one `NS` symbol in 1877 lines (an observer
  token); so do `WindowViewModel`, `SegmentStore`, `BookmarkStore`,
  `ComparisonCoordinator`, `BackgroundOperation`. All of the AppKit is in the view
  controller. So rule 5 is affordable — the ground an interactor would stand on is
  clean already.

## Role by role

### View: fits, with one caveat

"UI only" is a clean rule here, and the view controller keeps a job the iOS
version of this scheme does not name: it is the **responder-chain adapter**. On
macOS most actions do not start in a view. They start in the menu bar or the
toolbar, addressed to nobody in particular, and `NSApp` walks the key window's
first responder, its superviews, the view controllers, the window, the window
controller, itself, and finally the app delegate. `NSViewController` is a
first-class action receiver on this platform.

That is not a leak in the scheme — it is the macOS shape of "the view forwards
actions". It does mean the interactor must stay *out* of the responder chain: it
is called, never messaged, or first-responder semantics (which pane is focused,
which window is key) move into the logic layer, where they cannot be reasoned
about.

It also means every `Actions` call carries its subject — *append a file to this
pane*, not *to whatever is active*. The pane menu already works that way, pinning
its pane in `representedObject` so a right-click acts on the header it was opened
from rather than on the active pane.

The caveat: **AppKit views are smart by design.** `NSTableView` owns selection and
column state, `NSSplitView` owns divider geometry, `NSTextView` owns an undo
manager and a field editor. "The view has no logic" can only ever mean "no
*domain* logic" — a weaker rule than it sounds, and one that has to be restated
per component. In this app the honest split for a pane's results panel turned out
to be: content and what a row means belong to the panel; height, divider and
stored preference belong to the surface hosting it. Nothing in the scheme's
wording predicts where that line falls.

### Interactor: the strong fit, doing one job rather than two

The scheme gives the interactor two jobs. In an app of this shape only the first
is real.

**Answering actions and owning flows** — this is what the file above needs. A flow
is a short-lived transaction with a conversation in the middle: choose a file,
warn about unsaved bytes, run a background write, report an error. Those are
exactly the ~2000 lines and 11 properties that have no other home today.

**Preparing data for display** — largely unnecessary here, because the model
already does it in domain terms and the view formats. `PaneStatus` is the shape:
name, size, caret offset, selection length, dirty, read-only, undo/redo, insert
mode, the caret's piece. No strings, no formatting — one of its own comments reads
"the caret's offset, raw — the view renders it as bare hex". Inserting an
interactor on that path would add a hop that translates domain facts into the same
domain facts.

There is one exception worth naming because it does not look like a flow: a
**subsystem** — the minimap's overview, 1290 lines and 17 properties of tasks,
debounces, progress and generation counters. Nothing about it begins with a click,
yet it is squarely "logic that prepares what the view shows". If the scheme has no
name for it, it stays in the view controller forever as "drawing support".

And there is a precedent in this app for what an interactor looks like when it
works. `ComparisonCoordinator` — misleadingly named — takes its inputs through a
closure rather than a reference to the controller, publishes results through
callbacks, owns a lifecycle and a generation counter, is `@MainActor`, imports no
AppKit, and its tests construct it rather than a window. It is an interactor that
nobody called one, and it is the least troublesome object in the window layer.

### Coordinator: the role this app is missing

The view/interactor pair contains nothing that **creates** a view, **destroys** it,
decides **how long** it lives, **installs** it into a hierarchy of subviews and
controllers, or **wires** one surface to another. That work exists in every app;
the coordinator is where it goes.

Stated that way the role is unambiguous, and my earlier reading of it — navigation
— was too narrow, which made it look almost empty on a platform with no navigation
stack. What is actually true is the opposite. Look at what is coordinator work in
this app today, all of it inside `MainViewController`:

- `paneView(for:)` builds a pane's view and caches it per model; two call sites
  drop it again — creation and destruction.
- `apply(mode:)` and `wireComparison()` / `unwireComparison()` install panes into
  the empty, single-file or comparison arrangement and connect them to each other
  and to the minimap — composition and wiring, ~500 lines.
- `releasePane(at:)` / `adoptPane(_:bookmarks:)` move a pane between windows on a
  tear-off — lifetime across two coordinators' territory.
- `makeSiblingTab`, `openFilesInNewTab`, `movePaneToNewTab` — new surfaces.
- `addChild` for the results panel; the four `…Presenter` closures for popovers,
  forms and sheets.
- `OpenDocumentRegistry` — which window holds which file, the one question no
  single window can answer.

None of that is navigation, and all of it is lifetime and composition. It is also
the part of the file with no name for what it does, which is why it accreted there.

The platform does constrain *how* it is built, not *whether*:

- **Some of it is the system's.** `NSWindow.allowsAutomaticWindowTabbing = true`
  gives ⌘T, ⌃Tab, ⌘1…⌘9, dragging a tab out into its own window and back, and the
  Window menu's Show Tab Bar / Move Tab to New Window / Merge All Windows. The
  coordinator does not own those gestures; it answers them — a tab the system
  created still needs its content built and wired by us.
- **It splits by scope.** Window-level: sheets, popovers, forms, alerts, the
  arrangement of panes inside one window. App-level: windows, tabs, and which
  window holds what. These are different lifetimes with different owners, and one
  protocol over both would be forcing it. That is a technical division of one
  role, not two roles.
- **Presentations are anchored.** A popover opens relative to a rect in a view; a
  sheet belongs to a window. So the interactor emits a request value the
  coordinator resolves — `BookmarkEditRequest` does exactly this today, carrying
  what to edit and what to do about it, and deliberately not the anchor — and when
  only the view knows where the thing is, an opaque context object rides from view
  through interactor to coordinator. The interactor never learns what a row is.

The failure mode to watch is still rule 4: a coordinator that decides *whether* to
present rather than *how* is a second interactor with windows in it.

## Where the platform argues back

Six costs, each specific to AppKit rather than to the scheme.

**1. The responder chain is already a routing mechanism, and a good one.** AppKit
delivers a command to the right window and the right focused component for free.
An `Actions` protocol per view partly duplicates that, and can fight it: once
actions must be forwarded explicitly, "whatever is focused handles this" stops
being free and turns into plumbing that carries the subject by hand. The
mitigation is the subject rule above — which exists because the framework's own
answer was given up.

**2. Target/action, delegate and data source are the native idiom.** AppKit views
expect to be driven that way, and a strict `Actions` boundary adds a hop to every
callback: delegate method → Actions → interactor → update → view. For
data-source-heavy UI that hop is per-row-ish, and the single-cycle rule has to
answer for it: `NSTableView` and `HexView` *pull*. Either the visible range becomes
an event and the interactor pushes rows for it, or a read-only data-source port is
admitted as a documented exception — the two options are laid out under the
mechanics. Neither is free, and on a 16 MB dump the difference is measurable rather
than theoretical.

**3. Modality is synchronous in the platform's grain.** `runModal` returns an
answer inline, and flow code reads as straight-line prose because of it. A
pure-logic interactor can keep that (it holds no AppKit and still asks its
question through a port) — or go async with `beginSheetModal`, at which point every
flow becomes continuations and re-entrancy becomes a class of bug that did not
exist. Both are defensible; mixing them is not, and the choice has to be made once
for the whole app rather than per flow.

**4. The no-AppKit law needs admitted carve-outs.** Some domains here genuinely
are AppKit-shaped: drag-and-drop (`NSDragOperation`, pasteboard types, drag
sessions), the pasteboard's contents, services, printing. This app has one happy
example — the rule that decides what a drop means is a pure function over its own
enums, and only its *result* is mapped to `NSDragOperation` at the edge — but that
worked because the rule is twenty lines. A richer drag interaction would grow a
translation layer whose only job is restating framework vocabulary. That cost
should be admitted in advance, not discovered.

**5. Scope: the 1:1 rule answers this, and the answer costs.** Left open, an
interactor's scope is the scheme's worst ambiguity on macOS: on iOS the screen
bounds it, and here nothing does. One interactor per pairing settles it — the unit
is a surface, which exists whether or not anyone names it.

Counted against this app, one pair per surface gives roughly **sixteen**: thirteen
view controllers exist already (the window's content, the results panel, the
segments and bookmarks forms, the two popovers, six settings panes), and four
surfaces are currently plain views that would become pairs — the file pane, the
find bar, the minimap panel, the empty state. Not the forty a per-component
reading would give, and not the six a per-feature grouping would — and per-feature
would anyway be a different scheme, since a feature cuts across surfaces and so
breaks the pairing.

The cost lands in two places. **Six of the sixteen are settings panes** whose
interactor would read and write one `UserDefaults` key: a protocol, a mock and a
test file each, for a checkbox. And the pairing is *inseparable*, so a surface
cannot opt out — the ceremony is uniform by construction, which is the rule's
strength for consistency and its weakness for cost.

**6. Validation is a query, and it runs in bursts.** `NSMenuItemValidation` and
`NSToolbarItemValidation` are protocols on the *responder*, so the view controller
must answer them — for every item, on every menu open. Dozens of synchronous calls
in a burst, 63 selectors in one switch here. Asking interactors per item is the
obvious move and the wrong one; the workable direction is inverted, and the
mechanics section below proposes what to do instead.

## Testing: the measurable difference

This is the strongest argument for the scheme, and the one that can be measured
rather than argued.

Pure logic gets unit tests. Logic living inside a view controller gets tests that
have to stand up the UI to reach it — and on macOS that is worse than on iOS:
modal panels block the runloop, an offscreen window makes a popover close the
instant it opens (a comment in this codebase says exactly that, next to the seam
invented to work around it), and menu commands and drag sessions are not
straightforwardly drivable at all.

One nuance against the strong form of the claim: it is not that *only* UI tests are
possible. On macOS you can build the controller in-process and drive it directly,
without XCUITest, and this app does — all 969 of its tests are that kind. So the
choice is not "unit tests or screen-scraping"; it is "unit tests or in-process view
tests". What the second costs, in this suite:

| | pure logic (`DumpCompareCore`) | view-bound (app suite) |
|---|---|---|
| tests | 264 | 969 |
| wall clock | **3.1 s** | **~100 s** |
| per test | ~12 ms | ~103 ms |

Nine times slower per test, and the slowness is the least of it. The suite also
carries, purely to neutralise the UI:

- **33 of 79 test files build an `NSWindow`** — a window, a content view
  controller and a layout pass, to ask a question about a flow.
- **226 explicit layout calls** and **170 runloop pumps**: a view-bound test has to
  make the layout happen and then wait for the main actor to settle before it can
  assert.
- **83 walks of the view tree** (`descendants(of:_:)`) to reach a subview the
  controller does not hand out.
- **24 test-only hooks in production code** — the twelve panel/confirm/present
  closures, an `isRunningTests` flag, a static modal responder, swappable
  `UserDefaults`, and a handful of `…ForTesting` accessors. Every one of them is a
  line in the app that exists because a test could not otherwise get in.

None of that is bad engineering; it is the correct response to the constraint. It
is also precisely the bill an AppKit-free interactor would stop paying. And the
direction of causation is worth noticing: those twelve closures were not designed
as a boundary — they were *discovered*, one at a time, by tests that needed a flow
without a modal. A seam found by tests is a seam.

Mocking cuts both ways in the scheme, but not equally here. A fake view lets an
interactor be tested with no AppKit at all — that is where the 3.1 s column comes
from. A fake *interactor* makes a view's test deterministic (no real data, no async
settling), but it does not make it cheap: the view still needs a window, a layout
pass and a runloop, because that is what an AppKit view is. So the win is
asymmetric — most of it is on the interactor's side of the protocol.

The honest counterweight: unit tests of an interactor also test less. A view-bound
test that clicks Find All and reads the header count checks the wiring too — that
the button is connected, that the panel is in the hierarchy, that the layout gives
it a height. Split the layers and that coverage does not move to the interactor's
tests; it has to be kept somewhere else, or it is lost. In this suite several tests
are exactly of that kind, and they are among the ones that have caught real
regressions.

## What tips the balance

**The seams already exist, but on the coordinator's side.** The twelve injected
closures are the **coordinator's** protocol, not the interactor's, and six are
typed in AppKit:

```swift
var joinOpenPanel:        ((NSOpenPanel) -> URL?)?
var joinConfirm:          ((NSAlert) -> NSApplication.ModalResponse)?
var segmentDirectoryPanel:((NSOpenPanel) -> URL?)?
var segmentSavePanel:     ((NSSavePanel) -> URL?)?
var segmentOpenPanel:     ((NSOpenPanel) -> URL?)?
var segmentWriteConfirm:  ((NSAlert) -> NSApplication.ModalResponse)?
```

An interactor cannot hold any of these. Under rule 5 they would have to be
restated in the domain's own words —

```swift
protocol JoinPresenting {
    func chooseFileToJoin() -> URL?
    func confirmJoin(named: String, verb: String, dirty: Bool) -> Bool
}
```

— which is a real conversion cost and also a real gain: the tests currently build
an `NSAlert` and read its buttons to answer a question the flow asked in domain
terms to begin with. The same line sorts the other AppKit these flows reach for:
`NSAlert` (17 uses) and the panels are the coordinator's, `NSSound.beep()` and
Show in Finder are presentation, `NSPasteboard` is a port — behind a protocol the
interactor may hold, or left in the view layer, but not imported.

**There is no framework binding story to displace.** On iOS this scheme has to
argue against SwiftUI, `@Observable`, Combine. In AppKit there is nothing modern to
compete with: Cocoa Bindings are KVO-era and legacy. An explicit interactor→view
protocol fills a hole rather than duplicating a framework feature. (Which is also
the argument for *not* introducing Combine here just for this: it would be a third
way of saying "something changed", beside the closures and the async work already
in use.)

**Longevity.** A macOS tool like this accumulates features for years — this one is
at twenty-five numbered sections of requirements — and role boundaries are worth
more the longer the code lives. The counterweight is that the same longevity means
an unhelpful abstraction also survives for years.

## The model layer, outside the scheme

Measured, the tier is already what rule 5 needs: `Foundation` and the core package,
no AppKit. `PaneStatus` is the shape of what it hands out — domain facts, no
formatting — so the display path for panes needs no interactor inserted into it:
the model answers, the view formats.

Which makes one name wrong. `PaneViewModel` owns the document, the undo history,
the segments and the pane's own state, and answers the hex view as a data source.
It is a data model; `PaneModel` (or `PaneDataModel`, if the suffix is the house
convention) says so. The property that holds the window's one is already called
`windowModel` in 136 places, so half the codebase reads it as a model already. The
rename is mechanical and wide — 80 references across 7 app files, 124 across 39
test files — and it would want doing before any `SearchInteractor` exists beside a
file called `PaneViewModel`, inviting exactly the wrong guess about which holds the
logic.

## Mechanics: how the pair would be built

### One cycle, and what it forbids

```
    View ──── UI events ────▶ Interactor ──── data updates ────▶ View
```

Two channels, one direction each. The structure of the events and of the updates
is the design work of a surface: it has to cover what the surface does, and it has
to be shaped so the updates are cheap enough for the traffic they carry.

What the rule forbids is everything that would make a second, informal path:
delegates back from the interactor, closures handed across, and — the easy one to
get wrong — **asking the view about its own state**. `DisplayOutput` has no
getters. If the interactor needs to know whether a scan is running, it is the
interactor's fact, not the view's; the view knows it only because it was told.

Two consequences worth naming, because they cut against things written elsewhere
in this document:

**Validation from the last rendered state does not break the cycle.** The view
keeps the `State` it was pushed and answers `validateMenuItem` from it locally.
Nothing is pulled across the boundary — the state is already on the view's side,
and enablement is a projection of it. That is what makes it the right answer
rather than a convenient one.

**Virtualized views are the real friction.** `NSTableView` asks for row N when row
N draws; `HexView` asks for the byte state of the rows it is about to paint. Both
are pulls by construction, and the honest options are:

1. **Push the visible window.** The scroll becomes a UI event ("visible range
   changed"), the interactor answers with the rows for that range, and the cycle is
   intact. Costs a round trip per scroll and makes the interactor hold the visible
   window — which it arguably should, since it is what decides what is worth
   preparing.
2. **Admit a read-only data-source port**, held by the view, that reads *model*
   data — not view state, not a back-channel to the interactor. Cheaper and closer
   to how AppKit wants to be driven, at the price of one documented exception to
   the single cycle.

This is the first thing to decide, because the whole shape of `DisplayOutput`
follows from it, and because a 16 MB dump makes the wrong answer measurable.

### Ownership

```
window / parent VC / popover ──strong──▶  View (NSViewController)
                                            │
                                     strong │  (any Actions)?
                                            ▼
                                         Interactor
                                            │
                                       weak │  (any DisplayOutput)?
                                            ▼
                                          View
```

The view owns the interactor as an `Actions`; the interactor holds the view weakly
as a `DisplayOutput`. No cycle, and the pair is deallocated together by whatever
owns the view — which on macOS is always something concrete:
`window.contentViewController`, `parent.addChild(_:)`,
`popover.contentViewController`, or the presenter during a sheet.

Three mechanical requirements this implies:

1. **`DisplayOutput` must be class-bound** (`: AnyObject`). A weak reference to an
   existential of a non-class protocol does not compile.
2. **Both sides are `@MainActor`** in an app where all UI is. `weak` and
   `@MainActor` compose fine; the interactor's background work hops out and back
   explicitly.
3. **A nil display is a no-op, never a crash.** After teardown, in-flight work
   resolves against a nil weak reference; the interactor must be written so that
   is simply nothing happening.

**Optional or not.** Optional `Actions` is the sketch. The alternative —
non-optional, injected in `init` — removes the `?` from every call site and makes
"a view always has an interactor" a compile-time invariant;
`NSViewController`'s init ordering permits it. Recommendation: non-optional where
the builder assembles the pair, which is everywhere in production. The cost of
optional is not the `?` — it is that "unwired" becomes a state every method has to
tolerate, and that state has no meaning in a shipped app.

### The two protocols, and validation as the third question

```swift
@MainActor
protocol SearchResultsActions: AnyObject {
    func viewIsReady()
    func rowChosen(at index: Int)
    func closeRequested()
}

@MainActor
protocol SearchResultsDisplay: AnyObject {
    func render(_ state: SearchResultsState)
}
```

Menu and toolbar validation is where two protocols are not obviously enough, for
the reason in cost 6 above. Three ways to answer it:

| approach | shape | verdict |
|---|---|---|
| query the interactor | `Actions` grows `canRevert`, `canJoin`, … | breaks "actions are actions", and puts a burst of synchronous calls across the boundary |
| a third protocol | `Queries`, held by the view | honest, but doubles the surface's protocol count and still crosses the boundary per item |
| **validate from the last rendered state** | the view keeps the `State` it was last given and reads it | recommended |

The third works because the state is already crossing the boundary for display,
and enablement is a projection of the same facts. It makes validation synchronous,
allocation-free and impossible to get out of step with what is on screen — a menu
item cannot claim something the view is not showing. The cost is that `State` grows
a few `canX` members and the view holds a value: not logic, and not a second source
of truth, since it is only ever written by `render`.

```swift
struct SearchResultsState {
    var rows: [Row] = []
    var isSearching = false
    var isTruncated = false
    /// Enablement, projected from the same facts the rows come from.
    var canClearResults = false
}
```

### Assembly

```swift
enum SearchResultsSurface {
    @MainActor
    static func buildController(pane: PaneModel) -> SearchResultsViewController {
        let interactor = SearchResultsInteractor(pane: pane)
        let controller = SearchResultsViewController(actions: interactor)
        interactor.display = controller
        return controller
    }
}
```

Two notes specific to AppKit:

- **Return the concrete type, not `NSViewController`.** Callers routinely need more
  than the base class: `preferredContentSize` for a popover, the view to install
  into a split, `title` for a window. Erasing it means casting it back.
- **Tests want both halves**, and need no special support: both sides take their
  collaborators through protocols, so a test constructs the interactor with a fake
  display, or the view with fake actions, and never calls the builder. The builder
  is a production convenience, not a test seam.

### Lifecycle: who speaks first

`loadView()` runs lazily, on first access to `view`. So `buildController` can hand
back a controller whose subviews do not exist yet, and an interactor that renders
immediately would be talking to nothing. The view announces readiness — consistent
with the view owning lifecycle:

```swift
override func viewDidLoad() {
    super.viewDidLoad()
    actions.viewIsReady()          // → interactor renders the first state
}
```

The alternative is for the view to buffer the last state and apply it in
`viewDidLoad`. That works and is strictly more forgiving; it also means every view
carries buffering logic for a case the first approach makes impossible.

On macOS there is a second readiness worth naming: `viewWillAppear` /
`viewDidAppear` fire for embedded children as well as presented ones (that is what
containment buys), so a surface that should only work while visible has a place to
start and stop — a live search, a watcher, an animation.

### Teardown

- **The interactor cancels its own work.** `deinit { task?.cancel() }`, plus an
  explicit stop for surfaces that can be hidden without being deallocated.
- **Every completion checks the display.** `guard let display else { return }` —
  after teardown a background result has nowhere to go, and that is correct.
- **No `unowned`.** The point of `weak` here is that the view can go first;
  `unowned` would trade a nil check for a crash.

### Ownership alternatives, weighed

| model | pro | con |
|---|---|---|
| **View owns interactor** (proposed) | pair dies together; matches how macOS already owns view controllers; no third party to keep in step | the interactor cannot outlive its surface — see below |
| Coordinator owns both | the pair can outlive presentation; one place to look for lifetimes | the coordinator becomes an ownership registry, duplicating what windows and tabs already do on macOS |
| Interactor owns view | logic-first reading | fights the platform: `contentViewController` and `addChild` retain the controller, so it gets two owners |
| A box returned by the builder | symmetric | ceremony; something must own the box, which is the previous question again |

The proposed model is the right one for AppKit, for the reason in the first row:
window/tab/popover ownership of view controllers is already the platform's
mechanism, and hanging the interactor off the view inherits it for free.

### The carve-out this forces: work that outlives a surface

"The interactor cannot outlive its surface" is not hypothetical here:

- `SegmentsForm` closes itself the moment a Save All starts —
  `if saveAll?() == true { closeForm() }` — while the background write keeps
  running, because the task and its progress live on the window's controller, not
  on the form.
- A Search All outlives the find bar for the same reason: the bar can be dismissed
  and the scan goes on feeding the results panel.

Under a view-owned interactor, work owned by a closing surface's interactor would
die with it. So: **anything that must outlive a surface does not belong to that
surface's interactor.** It belongs to a service in the model tier that the
interactor starts and observes.

The same conclusion arrives from the 1:1 rule, by a different road: no interactor
may reach into another, so work that spans surfaces — Save All Segments starts in a
form, writes a pane's bytes, reports in that pane's status bar, asks in an alert —
must go *down* rather than sideways. Both roads say the file writer, the searcher
and the diff indexer are **services**, and interactors are thin things that ask
them for work and render what comes back. `ComparisonCoordinator` is already
exactly that shape. It also means the growth lands in the model tier, not in the
UI layer.

### A surface does not know how it is presented

The find bar is at the top of the window because that is what was decided, not
because it is part of the window's controller. As a piece of UI it is
self-contained: a pattern field, an encoding choice, a case toggle, next/previous,
Find All, a close button. It could be a strip at the top, a strip at the bottom, a
sidebar, a popover, or a window of its own, and none of that is its business.

Which is the practical test of the scheme on this platform: a surface knows its own
protocols and nothing about its placement. The coordinator installs it — as a
subview, as a child controller, as a popover's content — and the surface is
unchanged by which. In this app that is nearly true of the find bar already and not
at all true of its *effects*: the search runs on the window's controller, so the
bar is wired to one arrangement by the code that answers it, not by the code that
draws it.

Which raises the question of who receives what a surface reports. A find bar acts
on whichever pane is focused, so it cannot be wired to one collaborator forever.
Two shapes:

- **An abstract port the coordinator supplies** — `FindTarget`, re-pointed when
  focus moves. The flow stays traceable: one named collaborator at a time, and the
  coordinator is the only thing that knows which.
- **Notifications the interested components subscribe to.** More decoupled, and it
  scales to several receivers — but it is also the shape the single-cycle rule
  distrusts, because "who reacted to this" stops being answerable by reading the
  code.

The first is more consistent with the rest of the scheme; the second is what
"notify whoever is subscribed" asks for. Worth settling deliberately, because it
decides how traceable the app's control flow is — and the answer may well differ
between a surface with one natural receiver (a results panel and its pane) and one
with many (a settings pane whose change touches every open window).

### Worked sketch: the results panel

The surface closest to this today — already a view controller that owns its content
and nothing else.

```swift
@MainActor
final class SearchResultsInteractor: SearchResultsActions {
    weak var display: (any SearchResultsDisplay)?

    private let pane: PaneModel
    private let searcher: SearchService          // outlives this surface
    private var state = SearchResultsState()

    init(pane: PaneModel, searcher: SearchService) { … }

    func viewIsReady() { display?.render(state) }

    func rowChosen(at index: Int) {
        guard let match = state.rows[safe: index]?.range else { return }
        pane.select(range: match)                // model, not view
    }

    func closeRequested() {
        searcher.cancel(for: pane)
        state = SearchResultsState()
        display?.render(state)
    }

    // Fed by the service, not by a view.
    private func matchesArrived(_ matches: [Range<UInt64>]) {
        state.rows.append(contentsOf: matches.map(Row.init))
        state.canClearResults = !state.rows.isEmpty
        display?.render(state)
    }
}
```

What the view keeps: the table, the header, the ×, the constraints, and the last
`State`. What it does not keep: what a row means, when the panel is empty, whether
a scan is running.

Two things this sketch makes visible that the prose did not:

- **`render(_:)` per streamed batch is wrong at this granularity.** A Search All
  streams up to a thousand matches; re-rendering the whole state per batch would
  undo the `insertRows` optimisation the panel has today, which exists precisely
  because `reloadData()` per match re-read every visible row's bytes. So a
  streaming surface needs either a diff in the state or an explicit
  `appended(rows:)` on `DisplayOutput` beside `render(_:)`.
- **The panel reads bytes lazily per visible row** — the excerpt for row N is
  fetched when row N draws. That is a pull, and it cannot come through `render(_:)`
  without materialising every excerpt. Either `State` carries a closure (a pull
  channel dressed as data) or the view keeps a reference to a read-only byte
  source. Neither violates the boundary; the second is honest and the first is not.

## The questions that would decide it

1. **Push versus pull** for virtualized rows and streamed batches — the visible
   range as an event, or an admitted read-only data-source port. Everything about
   `DisplayOutput`'s shape follows from this one.
2. Synchronous ports or async ones, for modality — chosen once, for everything.
3. How a surface's reports reach their receivers: an abstract port the coordinator
   re-points, or subscriptions.
4. How the coordinator divides by scope — window-level and app-level are different
   lifetimes; whether they share any protocol at all.
5. Whether the surfaces that are plain views today are worth promoting to pairs one
   at a time, given the pairing cannot be partial within a surface.
6. What the service tier looks like once long-running work moves out of surfaces:
   one service per capability (search, write, index), or fewer.
7. Which AppKit vocabularies get an admitted translation layer, and which stay in
   the view layer untranslated.

## What this document does not claim

That any of this should be built. The measurements size the argument; they do not
schedule it. In particular: the model tier being AppKit-free says rule 5 is
*affordable*, not that it is *warranted*; and the 5484 lines say the problem is
real, not that this scheme is the only answer to it — the same lines would also
yield to plain decomposition into extensions and one or two subsystem objects, with
none of the ceremony and none of the boundaries.
