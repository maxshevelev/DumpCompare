# View / interactor pair — a technical design proposal

Sketches from discussion, written down for review. This is the *mechanics* half:
ownership, protocol shapes, assembly, lifecycle and teardown, with the
alternatives weighed. The question of whether the scheme suits an AppKit app at
all is the other half, in `VIEW_INTERACTOR_IDEA.md`; nothing here proposes a
change to this codebase, and the code below is illustrative, not staged work.

The scheme being made concrete: **one view, one interactor, one surface** — an
inseparable pair that knows nothing of each other's implementation and talks
through protocols in both directions.

- **View / view controller** — UI elements, layout, lifecycle, actions.
- **Interactor** — fills the view with data, answers user actions, talks to the
  models, asks the coordinator to navigate. Pure logic: no view, no AppKit
  import.

## Ownership

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

The view owns the interactor as an optional `Actions`; the interactor holds the
view weakly as a `DisplayOutput`. No cycle, and the pair is deallocated together
by whatever owns the view — which on macOS is always something concrete:
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

### Optional or not

`Actions` optional is the sketch. The alternative — non-optional, injected in
`init` — removes the `?` from every call site and makes "a view always has an
interactor" a compile-time invariant. `NSViewController`'s init ordering permits
it (`init(actions:)` then `super.init(nibName: nil, bundle: nil)`).

Recommendation: non-optional where the builder assembles the pair, which is
everywhere in production; optional only if some surface must be constructible
unwired. The cost of optional is not the `?` — it is that "unwired" becomes a
state every method has to tolerate, and that state has no meaning in a shipped
app.

## The two protocols, and the third question

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

The third question is **menu and toolbar validation**, and it is the one place the
two-protocol shape is not obviously enough. On macOS `validateMenuItem(_:)` is
answered by the *responder* — the view controller — and it is called for every
item on every menu open: dozens of synchronous calls in a burst.

Three ways to answer it:

| approach | shape | verdict |
|---|---|---|
| query the interactor | `Actions` grows `canRevert`, `canJoin`, … | breaks "actions are actions", and puts a burst of synchronous calls across the boundary |
| a third protocol | `Queries`, held by the view | honest, but doubles the surface's protocol count and still crosses the boundary per item |
| **validate from the last rendered state** | the view keeps the `State` it was last given and reads it | recommended |

The third works because the state is already crossing the boundary for display,
and enablement is a projection of the same facts. It makes validation
synchronous, allocation-free and impossible to get out of step with what is on
screen — a menu item cannot claim something the view is not showing. The cost is
that `State` grows a few `canX` members, and that the view holds a value: not
logic, and not a second source of truth, since it is only ever written by
`render`.

```swift
struct SearchResultsState {
    var rows: [Row] = []
    var isSearching = false
    var isTruncated = false
    /// Enablement, projected from the same facts the rows come from.
    var canClearResults = false
}
```

## Assembly

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

- **Return the concrete type, not `NSViewController`.** Callers routinely need
  more than the base class: `preferredContentSize` for a popover, the view to
  install into a split, `title` for a window. Erasing it means casting it back.
- **Tests want both halves.** Either a second entry point returning the pair, or —
  better — no special support at all: both sides take their collaborators through
  protocols, so a test constructs the interactor with a fake display, or the view
  with fake actions, and never calls the builder. The builder is a production
  convenience, not a test seam.

## Lifecycle: who speaks first

`loadView()` runs lazily, on first access to `view`. So `buildController` can
hand back a controller whose subviews do not exist yet, and an interactor that
renders immediately would be talking to nothing.

The view announces readiness — which is consistent with the view owning
lifecycle:

```swift
override func viewDidLoad() {
    super.viewDidLoad()
    actions.viewIsReady()          // → interactor renders the first state
}
```

The alternative is for the view to buffer the last state and apply it in
`viewDidLoad`. That works too, and it is strictly more forgiving; it also means
every view carries buffering logic for a case the first approach makes
impossible. Recommendation: the announcement.

On macOS there is a second readiness worth naming: `viewWillAppear` /
`viewDidAppear` fire for embedded children as well as presented ones (that is
what containment buys), so a surface that should only work while visible has a
place to start and stop — a live search, a watcher, an animation.

## Teardown

The pair dies with whatever owned the view. Rules that make that safe rather than
merely likely:

- **The interactor cancels its own work.** `deinit { task?.cancel() }`, plus an
  explicit stop for surfaces that can be hidden without being deallocated.
- **Every completion checks the display.** `guard let display else { return }` —
  after teardown, a background result has nowhere to go and that is correct.
- **No `unowned`.** The whole point of `weak` here is that the view can go first;
  `unowned` would trade a nil check for a crash.

## Ownership alternatives, weighed

| model | pro | con |
|---|---|---|
| **View owns interactor** (proposed) | pair dies together; matches how macOS already owns view controllers; no third party to keep in step | the interactor cannot outlive its surface — see below |
| Coordinator owns both | the pair can outlive presentation; one place to look for lifetimes | the coordinator becomes an ownership registry, duplicating what windows and tabs already do on macOS |
| Interactor owns view | logic-first reading | fights the platform: `contentViewController` and `addChild` retain the controller, so it gets two owners |
| A box returned by the builder | symmetric | ceremony; something must own the box, and that is the previous question again |

The proposed model is the right one for AppKit, for the reason in the first row:
window/tab/popover ownership of view controllers is already the platform's
mechanism, and hanging the interactor off the view inherits it for free.

### The carve-out this model forces

"The interactor cannot outlive its surface" is not hypothetical here. In this
codebase:

- `SegmentsForm` closes itself the moment a Save All starts —
  `if saveAll?() == true { closeForm() }` — while the background write keeps
  running, because the task and its progress live on the window's controller, not
  on the form.
- A Search All outlives the find bar for the same reason: the bar can be
  dismissed and the scan goes on feeding the results panel.

Under a view-owned interactor, work owned by a closing surface's interactor would
die with it. So the rule the model forces: **anything that must outlive a surface
does not belong to that surface's interactor.** It belongs to a service in the
model tier that the interactor starts and observes — which is the same conclusion
the 1:1 pairing reaches for cross-surface work, arrived at from the memory model
instead.

That is a real demand, not a footnote: it means the file writer, the searcher and
the diff indexer are *services*, and interactors are thin things that ask them
for work and render what comes back. `ComparisonCoordinator` is already exactly
that shape.

## Worked sketch: the results panel

The surface that is closest to this today — it is already a view controller that
owns its content and nothing else.

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
  `appended(rows:)` on `DisplayOutput` beside `render(_:)`. **This is the first
  thing to decide before writing any of it.**
- **The panel reads bytes lazily per visible row** — the excerpt for row N is
  fetched when row N draws. That is a pull, and it cannot come through
  `render(_:)` without materialising every excerpt. Either `State` carries a
  closure (a pull channel dressed as data) or the view keeps a reference to a
  read-only byte source. Neither is a violation — the view holds no domain logic
  either way — but the second is honest and the first is not.

## Open questions for the next round

1. Push versus pull in `DisplayOutput`, given streaming and virtualized rows —
   the two problems the sketch above ran into immediately.
2. Whether `State` carries enablement, or validation gets its own channel.
3. Non-optional `Actions` (recommended) versus optional.
4. What the service tier looks like once long-running work is moved out of
   surfaces: one service per capability (search, write, index), or fewer.
5. Whether the coordinator is one object or two — window-level presentation and
   app-level windows/tabs are not obviously the same idea.
