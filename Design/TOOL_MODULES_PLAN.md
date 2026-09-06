# Tool modules — implementation plan

A **tool-module** is a self-contained instrument for working on a dump: it reads
the open file, shows its own UI in a panel on the left of the window, marks
named **zones** in the dump, and can write back. One tool-module is active per
tab at a time, chosen from the **Tools** menu.

This document is the infrastructure: the API the two sides agree on, the host
that runs it, and what the first tool-modules will stand on. The first real
instrument is a **FIT table editor** (`Design/UEFI/FIT_TABLE_FORMAT.md`); it is
not built here.

**In scope.** The `ToolModuleKit` package, the shared UEFI domain model as its
own package, the registry and the Tools menu, the left panel, the zone map and
its drawing, the edit transaction, and the file import/export seam.

**Not in scope.** Any real parsing (a separate branch per tool-module),
user-made zones, editable zones (`Design/TODO.md`), runtime-loadable plugins,
per-module settings, and restoring the active tool-module across a launch.

## Decisions taken

Settled before writing this, and the reasoning belongs with each.

| | decision |
|---|---|
| **Packaging** | one SPM package per tool-module, in this repository, linked statically and listed in `project.yml`. No bundle loading at runtime: every module ships with the app, so a loader would buy nothing and cost signing, versioning and a failure mode per launch. |
| **UI** | the tool-module vends its own `NSViewController`, with a pure logic target underneath it in the same package. The controller is thin; what can be decided without a window is decided in the pure target and tested by `swift test`. |
| **Dependencies** | a tool-module depends on `ToolModuleKit` and on domain packages (`UEFIFormat`). It depends on neither `DumpCompareApp` nor `DumpCompareCore` — making `DumpCompareCore` a public API is a price with no return. |
| **Zones** | defined by the tool-module only. Read-only for the user: shown and navigated, never created or edited. The tool-module publishes a **slice** — what it wants seen — not its tree. |
| **Zone lifetime** | zones live with the session. Nothing else authors them, so closing the tool-module takes the map with it. |
| **Zone anchoring** | none. After an edit the map is rebuilt by re-reading, not shifted by `DiffEdit` — which removes the anchoring machinery `Design/ZONES_IDEA.md` budgeted for. |
| **Zone kind** | a `kind` field is reserved and unused. The uses for it — protected by Boot Guard, padding, empty slot, editable — are real but wait for a tool-module that has something to say. |
| **Size changes** | the host does not police them. A tool-module that must not change the file's size (FIT: §9.2 step 8) enforces that itself. The app's own rule holds for everyone: overwrite by default, warn on a shift. |
| **Applicability** | the host treats every tool-module as applicable to every file. "There is no FIT here" is a sentence the tool-module says in its own panel, not a greyed-out menu item that explains nothing. |
| **Settings** | none, and no reserved namespace. Adding one later is cheaper than carrying an unused hook. |
| **Restore** | the active tool-module does not survive a relaunch. The app restores no session state today. |

## The packages

**`ToolModuleKit`** — the whole of what the two sides agree on. Small, and the
only thing both the app and every tool-module import. Imports AppKit, because a
session vends a view controller; every value type in it is AppKit-free, so a
pure logic target can depend on it without dragging a window in.

**`UEFIFormat`** — the domain model of a UEFI image: the tree of
`Design/UEFI/UEFI_IMAGE_FORMAT.md`, both parsing passes, and the FIT table of
`Design/UEFI/FIT_TABLE_FORMAT.md`. **Not a tool-module** — no UI, not in the
Tools menu. Several tool-modules stand on it: one showing the structure with
export and body replacement, one working the FIT table. Pure Swift, no AppKit,
no dependency on `DumpCompareCore` or `ToolModuleKit`: it takes bytes through
its own minimal reader protocol, so it runs in `swift test` over fixture files.

Two things belong to it rather than to the tool-modules that use it:

- **The second pass.** `addressDiff` is computed from the Volume Top File, so
  FIT cannot be found without the tree. Parsing the table therefore lives here;
  what the FIT tool-module owns is the *editing* — where a microcode may be
  placed, the ordering by type, the header count, the checksum, the validator.
- **The checksum cascade.** Replacing a node's body pulls a chain upwards: the
  FFS file header's checksum8, the volume's `UsedSpace` and Apple CRC32, and
  the FIT if it points inside. Left to the tool-modules, the second one
  reimplements it differently. The library answers "after this replacement,
  write these fields with these values".

**`Modules/<Name>`** — one package per tool-module, two targets: `<Name>` (pure)
and `<Name>UI` (the view controller and the `ToolModule` conformance).

## The API

```swift
// ToolModuleKit

public protocol ToolModule {
    static var identifier: String { get }        // "dev.maxik.tool.fit"
    static var title: String { get }             // the Tools menu item
    static var preferredPanelWidth: CGFloat { get }
    @MainActor static func makeSession(host: any ToolHost) -> any ToolSession
}

@MainActor public protocol ToolSession: AnyObject {
    var viewController: NSViewController { get }
    func start()
    func contentChanged(_ change: ToolContentChange)
    func stop()
}

public enum ToolContentChange: Equatable {
    case edited(Range<UInt64>, sizeDelta: Int64)   // from the pane's DiffEdit
    case reloaded                                   // revert, external change, join
}
```

The host, as one pane sees it:

```swift
@MainActor public protocol ToolHost: AnyObject {
    var fileName: String { get }
    var contentSize: UInt64 { get }
    var isReadOnly: Bool { get }

    /// A small read on the main actor — a header, a table.
    func read(_ range: Range<UInt64>) throws -> [UInt8]

    /// An immutable view of the whole content, readable from any thread:
    /// what a parse of a 16 MiB image runs over. Taking one copies no bytes.
    func snapshot() throws -> any ToolContentReader

    /// One undo step, whatever it touches.
    func apply(_ transaction: ToolTransaction) throws

    /// What the dump should show. Replaces the previous map entirely.
    func publish(_ zones: ZoneMap)

    func reveal(_ range: Range<UInt64>, select: Bool)

    func requestFile(kinds: [String]) async -> ToolFile?
    func exportFile(_ bytes: [UInt8], suggestedName: String) async -> Bool

    func beginProgress(_ title: String) -> any ToolProgress
}

public protocol ToolContentReader: Sendable {
    var size: UInt64 { get }
    func read(at offset: UInt64, length: Int) throws -> [UInt8]
}
```

`snapshot()` is `EditOverlayStorage.contentSnapshot(scratch:)`, which already
exists for Duplicate (§23): immutable, `Sendable`, and free to take. It reads
the document *including unsaved edits*, which is the point — the panel must
show what the dump shows, not what the disk holds.

```swift
public struct ToolTransaction {
    public var name: String            // "Add Microcode" — the Undo menu's title
    public var writes: [Write]         // non-contiguous, applied as one step
    public struct Write { public var offset: UInt64; public var bytes: [UInt8] }
}

public struct Zone: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var range: Range<UInt64>    // half-open, as everywhere
    public var kind: ZoneKind          // reserved
}

/// The published map: the zones, and which one is in focus.
public struct ZoneMap: Equatable, Sendable {
    public var zones: [Zone]
    public var focus: Zone.ID?
    /// What the dump can actually draw: clamped to the file, empty and
    /// duplicate zones dropped, ordered outermost first. Overlap is untouched —
    /// zones nest.
    public func normalized(contentSize: UInt64) -> ZoneMap
}
```

Both value types carry the little logic there is, and both are checked before
anything reaches the file: `ToolTransaction.validated()` sorts the writes,
merges the ones that touch, and refuses a transaction that writes over its own
bytes — which is what a mis-computed offset looks like, the mistake §11 of the
FIT document is a post-mortem of.

Overwrite is the only write in v1, which is not a restriction on tool-modules so
much as the shape their work has: adding a FIT entry is four non-adjacent
overwrites (the component, the entry, the header count, the checksum) that must
land together or not at all. Insertion and deletion arrive with the first
tool-module that needs them, under the app's existing shift warning.

## The panel

The window's top-level split gains a third pane on the left:

```
[ tool panel ] │ [ content: pane(s) ] │ [ minimap ]
   .fixed              .fill               .fixed
```

`ALSplitView` already takes any number of panes with a layout each, and
`minimapSplit` becomes `panelSplit` with the tool panel at index 0. What the
minimap's side of this has and the tool panel needs written for the leading
edge:

- **Show and hide grow the window**, so the content area keeps its width — the
  minimap grows the window rightwards and leaves the left edge; the tool panel
  moves the left edge and leaves the right. `animateTrailingPaneSize` is
  trailing-only, so the leading side drives `animateDividerPosition(at: 0)`.
- **Width per tool-module**, from `preferredPanelWidth`, user-resizable and
  persisted under the module's identifier. A FIT table wants ~450 pt where the
  minimap is happy at 120–240; one shared width would be wrong for both.
- **The header names the file** the session is bound to.

Activation, from Tools ▸ ⟨module⟩ or Tools ▸ None: one session per tab, the
previous one stopped before the next starts. The panel closes with the session.

## Zones on screen

The published map is *what the dump draws* — the tool-module's own list, tree
and diagnostics are its panel's business and the host never sees them.

Drawing follows the segment tint's shape exactly: a `hexZoneSpans(in:)` on the
data source, resolved per row. It is drawn as an **outlined region** rather than
another tint — the byte cell's layering is full (§6: segment tint, match fill,
difference fill, selection fill, find indicator) and a sixth fill would fight
the five below it. The contour machinery exists: `drawContours` already outlines
the mirrored selection across rows and columns. The focused zone is stroked at
full strength and the rest faintly — a map of a dozen regions all drawn as
loudly as each other is a cage over the bytes. The names stay in the panel: a
label floating over the dump is a placement problem (which row, which side, what
happens when two zones start on one row) for something the list beside it
already answers.

Navigation is `reveal(_:select:)`, which the pane already does for bookmarks and
search results.

## Lifecycle

| when | what happens |
|---|---|
| an edit lands in the bound pane | `contentChanged(.edited(range, sizeDelta:))`, debounced; the tool-module decides whether to re-read |
| undo / redo | the same, as an edit |
| revert, external change, join | `contentChanged(.reloaded)` |
| the file is saved | nothing — the content did not change |
| the bound file closes | `stop()`, the session ends, the panel closes |
| the two panes are swapped | nothing: same window, same pane |
| the bound pane is moved into another tab | `stop()`. The session belongs to the window, the way bookmarks do (§20) — the destination keeps whatever it had open |
| the bound pane is torn off into a new tab | the module is activated again for it there, and parses afresh. The new tab starts with nothing, which is why the tear-off copies the window's bookmarks too |
| the bound pane is copied (Option-drag) | nothing: the original stays where it is, and the copy arrives with no module |
| the tab closes | `stop()` |
| the app quits | `stop()`; nothing is persisted |

A session is bound to the pane it was opened for. Clicking the other pane does
not re-target it: what the panel's header names is where its writes go, and a
map that re-parsed under a click would be a map you cannot trust.

But it is bound to the pane and **owned by the window** — one at a time per tab
was the rule from the start, which puts a session on the same side of the line
as bookmarks rather than as the document. So a pane carries its edits, its undo
history and its segments wherever it goes, and leaves the tool panel behind it,
exactly as it leaves the window's marks behind. The one exception is the one
bookmarks already make: a tear-off lands in a tab that has nothing, so there is
nothing to conflict with and the module opens again on the other side.

## Threading

`ToolSession` is `@MainActor`, like every other controller here. Parsing is not:
a tool-module takes a `snapshot()`, hands it to a detached task, and returns to
the main actor with a result. `beginProgress` puts the operation in the pane's
status bar, where the comparison build and the overview rebuild already report
(§14.4), so a long parse looks like every other long job in this app rather than
inventing a second place to watch.

## What is testable, and how

Three levels, and the point of the split is that only the third needs a window.

- **`UEFIFormat`, by `swift test`** over fixture images: a small hand-built
  image with a volume, a file, a section and a FIT; the diagnostic cases from
  the documents (an entry pointing at `FF FF FF FF`, a stale header checksum,
  types out of order, a zero size).
- **A tool-module's pure target, by `swift test`**: what it would publish and
  what it would write, as values, with a fake reader underneath.
- **The host, in the app suite**: the registry and the menu, one session at a
  time, the panel's width and its show/hide, a transaction landing as one undo
  step, a published map reaching `hexZoneSpans`, and every row of the lifecycle
  table above. A **test tool-module** inside the test target carries these —
  the seam gets proved without a real parser, and a failure means the seam.

`Scripts/run-tests.sh` knows one package today; it learns to walk them all.

## Stages

Each stage builds, tests and is committable on its own.

1. **`ToolModuleKit`** — the protocols and value types above, the package, and
   the project wiring. Nothing uses it yet.
2. **The registry and the Tools menu** — a static ordered list, menu items with
   a radio check and a None, validation through the responder chain like every
   other command here. Nothing opens yet.
3. **The panel** — the third pane in the top-level split, show/hide with the
   window growing leftwards, width per module, the header. Driven by a test
   tool-module with an empty view.
4. **The session** — activation, binding to a pane, `start`/`stop`, the whole
   lifecycle table, `read`, `snapshot`, `reveal`, progress.
5. **Zones** — publication, `hexZoneSpans`, the contour and the focused zone,
   navigation.
6. **Edits** — `ToolTransaction` as one named undo step, the named Undo title,
   read-only refusal, and the dump refreshing under the panel.
7. **Files** — `requestFile` and `exportFile` through the host's panels, with
   the security scope staying on the app's side.
8. **`UEFIFormat`** — the package, the first pass, the second pass, FIT. Its own
   branch's worth of work, and the first thing that makes a tool-module worth
   opening.

## Open questions

- **Does a click on a zone in the dump reach the tool-module?** Selecting the
  row in its panel would be the obvious answer, and the API for it is one
  method. Left out of v1 because nothing yet has a panel to select in.
- **Two tool-modules wanting the same parse.** The structure browser and the FIT
  editor would each parse the same image, twice, if both could be open — they
  cannot, one at a time per tab, so this is only a question if that rule ever
  relaxes.
- **Where a tool-module's diagnostics go.** Its own panel for now. If every
  tool-module ends up growing the same warnings list, that is a shared view in
  `ToolModuleKit`, not a host feature.
