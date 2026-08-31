# View, interactor, coordinator in an AppKit app

Reasoning, not a plan. Nothing here proposes a change to this codebase; the
codebase appears only as evidence, because it is a real AppKit app of a real size
and it is what the argument can be tested against.

The mechanics — ownership, protocol shapes, assembly, lifecycle, teardown — are
the other half, in `VIEW_INTERACTOR_PROPOSAL.md`.

The scheme under discussion, brought from iOS work where it has earned its keep:

- **View / view controller** — UI only: composing components, layout, colours,
  fonts, gestures, drawing. No handling of user actions beyond a complex view's
  own internals, and no presenting of other views.
- **Interactor** — the logic behind the UI: user actions, preparing what the view
  shows, deciding what happens next. Knows nothing about how the view is built,
  and reaches it through a protocol.
- **Coordinator** — navigation and presentation: transitions, navigation chrome,
  presenting child views.

The pairing is the unit: **one view, one interactor, one user-facing surface**,
inseparable — and knowing nothing of each other's implementation, talking through
protocols in both directions, so either side can be replaced by a mock.

Held together by four rules: the view forwards every action and decides nothing;
the interactor fills the view with data, reacts to actions, talks to the models,
and asks the coordinator for navigation; the interactor decides about presentation
while the coordinator performs it; and the interactor never holds a view nor
imports AppKit — where an action is tied to a component, an opaque **context
object** rides along, meaningful only to the layer that presents.

Models are outside the scheme. It exists to untangle views with several jobs
mixed into them; models go on as they were, and the interactor is what talks to
them.

## The verdict, up front

The three roles do not fare equally on this platform.

- **View / interactor is a strong fit** — and a stronger fit on macOS than on
  iOS, for a reason that is structural rather than stylistic (below).
- **Of the interactor's two jobs, only one is needed here.** Handling actions:
  yes. Preparing data for display: mostly already solved, by AppKit-free models
  that hand out domain snapshots and views that format them. So an interactor in
  an app shaped like this one is a *flow* object, not a presenter.
- **Coordinator is the weak fit**, because on macOS there is barely any
  navigation to coordinate. The role survives if it is renamed to what it
  actually does here — present anchored and modal UI, and own windows and tabs —
  and if it is allowed to be two objects rather than one.
- **One pair per surface is the right unit, and it prices the scheme.** Sixteen
  pairs here, six of them settings panes with a `UserDefaults` key behind them.
  It also forces shared logic *down* into models rather than sideways between
  interactors, which is a demand on the model tier more than on the UI.
- **The no-AppKit law is right, and needs admitted carve-outs.** Drag-and-drop,
  the pasteboard and modality are places where the domain genuinely is
  AppKit-shaped, and pretending otherwise buys a translation layer whose only job
  is restating `NSDragOperation`.

## Why the problem is worse on macOS than on iOS

This is the strongest argument *for* the scheme, and it is easy to miss.

On iOS the navigation stack imposes decomposition. A screen is a unit, a screen
is a view controller, and pushing one is the seam. Even a lazy app ends up with
its logic distributed across screens, because the framework's central metaphor is
one-screen-at-a-time.

macOS has no such pressure. A window holds many long-lived surfaces at once —
here: two panes, a minimap, a find bar, a results panel, a tab bar, a status bar
— and *none of them is a screen*. There is no push, no current screen, nothing
that says "this belongs somewhere else". So the window's controller becomes the
place where everything that concerns more than one surface goes, and there is no
framework metaphor pushing back.

The result, measured in this app: `MainViewController.swift` is **5484 lines**
with **61 stored instance properties**. Of those properties, 17 are one
subsystem's (the minimap's overview: debounce and pass tasks, awaiting-index
rows, rebuild and patch counters, progress reveal/hide tasks, per-map viewports)
and 11 are one in-flight flow or another (`findTask`, `findOperation`,
`searchAllGeneration`, `searchAllPane`, `segmentWriteTask`,
`segmentWriteOperation`, `openEditing`, `openGoToForm`, `openSegmentsForm`).

Two other numbers matter for judging the scheme, and they cut the other way from
what one might expect:

- **Action handling is not the problem.** 63 `@objc` actions, 516 lines between
  them, median 4 lines. They are already thin adapters. Whatever a scheme buys
  here, it is not "get the action handling out of the view controller".
- **The model tier is already AppKit-free.** `PaneViewModel` imports `Foundation`
  and the core package and contains one `NS` symbol in 1877 lines (an observer
  token); so do `WindowViewModel`, `SegmentStore`, `BookmarkStore`,
  `ComparisonCoordinator`, `BackgroundOperation`. All of the AppKit is in the view
  controller. So the no-AppKit law is affordable — the ground an interactor would
  stand on is clean already.

## Role by role

### View controller: fits, with one caveat

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
which window is key) move into the logic layer where they cannot be reasoned
about.

The caveat: **AppKit views are smart by design.** `NSTableView` owns selection
and column state, `NSSplitView` owns divider geometry, `NSTextView` owns an
undo manager and a field editor. "The view has no logic" can only ever mean "no
*domain* logic" — which is a weaker rule than it sounds and has to be restated
per component. In this app the honest split for a pane's results panel turned out
to be: content and what a row means belong to the panel; height, divider and
stored preference belong to the surface hosting it. Nothing in the scheme's
wording predicts where that line falls.

### Interactor: the strong fit, doing one job rather than two

The scheme gives the interactor two jobs. In an app of this shape only the first
is real.

**Handling actions and owning flows** — this is what the file above needs. A flow
is a short-lived transaction with a conversation in the middle: choose a file,
warn about unsaved bytes, run a background write, report an error. Those are
exactly the ~2000 lines and 11 properties that have no other home today.

**Preparing data for display** — largely unnecessary here, because the model
already does it in domain terms and the view formats. `PaneStatus` is the shape:
name, size, caret offset, selection length, dirty, read-only, undo/redo, insert
mode, the caret's piece. No strings, no formatting — one of its own comments
reads "the caret's offset, raw — the view renders it as bare hex". Inserting an
interactor on that path would add a hop that translates domain facts into the
same domain facts.

There is one exception worth naming because it does not look like a flow: a
**subsystem** — the minimap's overview, 1290 lines and 17 properties of tasks,
debounces, progress and generation counters. Nothing about it begins with a
click, yet it is squarely "logic that prepares what the view shows". If the
scheme has no name for it, it stays in the view controller forever as "drawing
support".

And there is a precedent in this app for what an interactor looks like when it
works. `ComparisonCoordinator` — misleadingly named — takes its inputs through a
closure rather than a reference to the controller, publishes results through
callbacks, owns a lifecycle and a generation counter, is `@MainActor`, imports no
AppKit, and its tests construct it rather than a window. It is an interactor that
nobody called one, and it is the least troublesome object in the window layer.

### Coordinator: the weak fit

Three quarters of what this role does on iOS does not exist here.

There is no navigation stack and no current screen. What *looks* like navigation
on macOS mostly belongs to the system: one line,
`NSWindow.allowsAutomaticWindowTabbing = true`, is what gives ⌘T, ⌃Tab, ⌘1…⌘9,
dragging a tab out into its own window, dragging one back in, and the Window
menu's Show Tab Bar / Move Tab to New Window / Merge All Windows. A coordinator
cannot own any of that; it can only answer it.

What remains is real but small: sheets, popovers, the settings window, new
windows and tabs, and "which window already has this file open". And it divides
along a seam the scheme does not anticipate:

- **window-level** — sheets, popovers, forms, alerts. Needs the window, and must
  behave when there is none (a controller under test).
- **app-level** — windows, tabs, and which window holds what. This is a genuinely
  different scope: in this app it is `OpenDocumentRegistry`, which answers a
  question no window can — a file is open exactly once in the app.

One protocol over both is forcing it. And a role with little to do is a role that
drifts: the failure mode is a coordinator that starts deciding *whether* to
present rather than *how*, which is the second rule broken and a second interactor
with windows in it.

The mechanics of what is left also constrain the interactor. A popover opens
relative to a rect in a view; a sheet belongs to a window. So either the
interactor emits a request value the coordinator resolves — as
`BookmarkEditRequest` does here, carrying what to edit and what to do about it,
and deliberately not the anchor — or, when only the view knows where the thing
is, a context object rides from view through interactor to coordinator as an
opaque token. Both are needed; with only the first, "anchor this popover on the
row that was clicked" cannot be expressed without the interactor learning what a
row is.

## Where the platform argues back

Six costs, each specific to AppKit rather than to the scheme.

**1. The responder chain is already a routing mechanism, and a good one.** AppKit
delivers a command to the right window and the right focused component for free.
An `Actions` protocol per view partly duplicates that, and can fight it: once
actions must be forwarded explicitly, "whatever is focused handles this" stops
being free and turns into plumbing that carries the subject by hand. The
mitigation is a rule — every `Actions` call names its subject, "append to *this*
pane" — but the rule exists because the framework's own answer was given up.

**2. Target/action, delegate and data source are the native idiom.** AppKit views
expect to be driven that way, and a strict `Actions` boundary adds a hop to every
callback: delegate method → Actions → interactor → protocol → view. For
data-source-heavy UI the hop is per-row-ish. Which forces a carve-out: a
virtualized view has to *pull*. `HexView` asks for the byte state of the rows it
is about to draw; pushing a formatted row model per row would be a rewrite and a
regression on a 16 MB dump. The boundary survives — the view holds no domain
logic — but the direction inverts, and the scheme's wording ("the interactor
prepares what the view shows") is the wrong way round for this case.

**3. Modality is synchronous in the platform's grain.** `runModal` returns a
answer inline, and flow code reads as straight-line prose because of it. A
pure-logic interactor can keep that (it holds no AppKit and still asks a question
through a port) — or go async with `beginSheetModal`, at which point every flow
becomes continuations and re-entrancy becomes a class of bug that did not exist.
Both are defensible; mixing them is not, and the choice has to be made once for
the whole app rather than per flow.

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
is a surface, which exists whether or not anyone names it — and it settles it in a
way I got wrong earlier in this document, where I proposed grouping by feature
instead. That was a different scheme smuggled in: a feature cuts across surfaces,
so grouping by feature breaks the pairing.

Counted honestly against this app, one pair per surface gives roughly **sixteen**:
thirteen view controllers exist already (the window's content, the results panel,
the segments and bookmarks forms, the two popovers, six settings panes), and four
surfaces are currently plain views that would become pairs — the file pane, the
find bar, the minimap panel, the empty state. Not the forty a per-component
reading would give, and not the six a per-feature one would.

The cost lands in two places. **Six of the sixteen are settings panes** whose
interactor would read and write one `UserDefaults` key: a protocol, a mock and a
test file each, for a checkbox. And the pairing is *inseparable*, so a surface
cannot opt out — the ceremony is uniform by construction, which is the rule's
strength for consistency and its weakness for cost.

The more interesting consequence is where cross-surface work goes. Save All
Segments starts in the segments form, writes bytes owned by a pane, reports
progress in that pane's status bar, and asks a question in an alert. Under 1:1 no
interactor may reach into another, so the shared part has to go **down** into the
models and services rather than sideways between peers. That is a better answer
than the "one object for all the flows" I floated earlier, and it is a real
demand on the design: the model tier grows to hold what today lives in one
controller because it belonged to no single surface.

**6. Validation is a query, and it runs in bursts.** `NSMenuItemValidation` and
`NSToolbarItemValidation` are protocols on the *responder*, so the view
controller must answer them — for every item, on every menu open. Dozens of
synchronous calls in a burst, 63 selectors in one switch here. Asking interactors
per item is the obvious move and the wrong one; the workable direction is
inverted, with each interactor keeping a cheap state snapshot the view pulls. So
the interactor→view channel is really two channels — pushed updates and a pulled
snapshot — which the scheme describes as one.

## Testing: the measurable difference

This is the strongest argument for the scheme, and it is the one that can be
measured rather than argued.

Pure logic gets unit tests. Logic living inside a view controller gets tests that
have to stand up the UI to reach it — and on macOS that is worse than on iOS:
modal panels block the runloop, an offscreen window makes a popover close the
instant it opens (a comment in this codebase says exactly that, next to the seam
invented to work around it), and menu commands and drag sessions are not
straightforwardly drivable at all.

One nuance against the strong form of the claim: it is not that *only* UI tests
are possible. On macOS you can build the controller in-process and drive it
directly, without XCUITest, and this app does — all 969 of its tests are that
kind. So the choice is not "unit tests or screen-scraping"; it is "unit tests or
in-process view tests". What the second costs, in this suite:

| | pure logic (`DumpCompareCore`) | view-bound (app suite) |
|---|---|---|
| tests | 264 | 969 |
| wall clock | **3.1 s** | **~100 s** |
| per test | ~12 ms | ~103 ms |

Nine times slower per test, and the slowness is the least of it. The suite also
carries, purely to neutralise the UI:

- **33 of 79 test files build an `NSWindow`** — a window, a content view
  controller, and a layout pass, to ask a question about a flow.
- **226 explicit layout calls** and **170 runloop pumps**: a view-bound test has
  to make the layout happen and then wait for the main actor to settle before it
  can assert.
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
from. A fake *interactor* makes a view's test deterministic (no real data, no
async settling), but it does not make it cheap: the view still needs a window, a
layout pass and a runloop, because that is what an AppKit view is. So the win is
asymmetric — most of it is on the interactor's side of the protocol.

The honest counterweight: unit tests of an interactor also test less. A
view-bound test that clicks Find All and reads the header count checks the wiring
too — that the button is connected, that the panel is in the hierarchy, that the
layout gives it a height. Split the layers and that coverage does not move to the
interactor's tests; it has to be kept somewhere else, or it is lost. In this suite
several tests are exactly of that kind, and they are among the ones that have
caught real regressions.

## What tips the balance

Worth noting against my own earlier reading: those twelve closures are the
**coordinator's** protocol, not the interactor's. Six are typed in AppKit —
`((NSOpenPanel) -> URL?)`, `((NSAlert) -> NSApplication.ModalResponse)` — so an
interactor could not hold them. Under the law they would have to be restated in
the domain's words (`chooseFileToJoin() -> URL?`,
`confirmJoin(named:verb:dirty:) -> Bool`), which is a real conversion cost and
also a real gain: the tests currently build an `NSAlert` and read its buttons to
answer a question the flow asked in domain terms to begin with.

**There is no framework binding story to displace.** On iOS this scheme has to
argue against SwiftUI, `@Observable`, Combine. In AppKit there is nothing modern
to compete with: Cocoa Bindings are KVO-era and legacy. An explicit
interactor→view protocol fills a hole rather than duplicating a framework
feature. (Which is also the argument for *not* introducing Combine here just for
this: it would be a third way of saying "something changed", beside the closures
and the async work already in use.)

**Longevity.** A macOS tool like this accumulates features for years — this one
is at twenty-five numbered sections of requirements — and role boundaries are
worth more the longer the code lives. The counterweight is that the same
longevity means an unhelpful abstraction also survives for years.

## The questions that would actually decide it

1. Synchronous ports or async ones, for modality — chosen once, for everything.
2. What shape the validation snapshot takes, given it is read in bursts and must
   stay readable end to end.
3. Whether the coordinator is one object or two, and whether the app-level one is
   the same idea at all.
4. Whether the surfaces that are plain views today are worth promoting to pairs
   one at a time, given the pairing cannot be partial within a surface.
5. Which AppKit vocabularies get an admitted translation layer, and which stay in
   the view layer untranslated.

## What this document does not claim

That any of this should be built. The measurements are here to size the argument,
not to schedule it. In particular: the model tier being AppKit-free says the law
is *affordable*, not that it is *warranted*; and the 5484 lines say the problem is
real, not that this scheme is the only answer to it — the same lines would also
yield to plain decomposition into extensions and one or two subsystem objects,
with none of the ceremony and none of the boundaries.
