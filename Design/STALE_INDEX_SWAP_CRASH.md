# Handoff — stale comparison index on file replacement, and the toolbar swap crash it exposes

> Status: **the user's bug is fixed; a separate, pre-existing AppKit crash is
> blocked.** This document is a handoff for the next session. Read
> `REQUIREMENTS.md` §10.3 (diff navigation) and the badge work already committed
> as `92923b8` for background.

## The task

The user reported (in Russian): after loading two **identical** files into panes
that previously held **different** files, the panes and the local minimap show no
differences, but the Prev/Next Difference **buttons still reflect the old files**
and jump the caret across **phantom diff blocks**, and the minimap **overview**
still shows the old orange blocks.

Root cause (confirmed): replacing a file in an already-open pane leaves the mode
at `.comparison`, so `MainViewController.refreshMode()` early-returns and never
calls `apply(mode:)` — the one path that restarts the comparison. And
`PaneViewModel.open(url:)` / `openUntitled()` did **not** fire
`onFullInvalidation` (only `revert()` did). So the pre-built `DiffBlockIndex`
was never rebuilt and kept the previous files' differences.

Two independent diff readers disagree when the index is stale:
- **Panes + local minimap** read difference state per byte from the **live**
  comparison → correctly show "no differences".
- **Minimap overview + diff navigation** read the **pre-built** `DiffBlockIndex`
  → show the old (phantom) blocks.

## What was done (uncommitted)

Three files changed. **Do not commit until the user says "push".**

### 1. `DumpCompareApp/PaneViewModel.swift` — the actual bug fix

Fire `onFullInvalidation?()` on wholesale storage replacement, the same way
`revert()` already does. In comparison mode this callback is wired to
`comparisonCoordinator.rebuild()`; in single-file mode to minimap invalidation;
nil otherwise.

- `open(url:)` — added after `startWatching(url)`, before `notify()`:
  ```swift
  // Opening a new file replaces the storage wholesale, like a revert —
  // the comparison must re-read, even when the mode is unchanged (both
  // panes already open), which is the one path that skips `apply(mode:)`.
  onFullInvalidation?()
  ```
- `openUntitled()` — added after `changeWatcher = nil`, before `notify()`:
  ```swift
  // A new document replaces the storage wholesale, like a revert — the
  // comparison must re-read even when the mode is unchanged.
  onFullInvalidation?()
  ```

This is correct and addresses the user's bug. `ComparisonCoordinator`'s
`provider` closure reads the two current `byteStorage`s fresh, so the rebuild
picks up the new files. `unwireComparison()` nils out the callback, so it is
safe in all modes.

### 2. `DumpCompareTests/ToolbarValidationTests.swift` — regression test

`testReplacingFilesInOpenPanesRebuildsTheComparison`: open two different files →
arrows appear → replace both with identical files (the way File > Open does when
both panes are open, mode unchanged) → the badge must replace the stale arrows.
This is the test that **exposed the swap crash** (see below).

### 3. `DumpCompareApp/MainViewController.swift` — swap fix (NOT working yet)

`applyDiffNavigationToolbarItem()` was rewritten several times trying to stop the
crash. **Current state on disk is the "insert-first, then remove" variant** (see
"Fix attempts" below). It does **not** fix the full-suite crash. This file's
change is the part that is still unresolved.

## The blocked problem: the toolbar swap crash

When the comparison transitions from "has differences" (arrows shown) to "no
differences" (badge shown) — i.e. the **swap** — the test process crashes with:

```
*** Assertion failure in -[NSToolbar _itemAtIndex:], NSToolbar.m:1432
💣 Program crashed: Signal 11
```

`xcodebuild` then restarts the run (which is why the final summary shows only the
remaining ~24 tests, all passing, yet the overall result is `** TEST FAILED **`).

### What is known

- **Deterministic in the full suite** (crashed 4/4 full runs), but **never** in
  isolation: running `ToolbarValidationTests` alone (or just the crashing test)
  passes 5/5, repeatedly.
- The crash is in `testReplacingFilesInOpenPanesRebuildsTheComparison` — the
  **only** test that performs the arrows→badge **swap**. The other toolbar tests
  either insert the badge directly (badge test) or keep/remove the arrows without
  the other present, so they never exercise remove+insert of the two items.
- `testTheDifferenceBlockIsOnlyInTheToolbarInComparisonMode` (removes the arrows
  group, **no** insert) **passes** in the full run. So removing the group alone
  is safe.
- The badge test (inserts the badge, **no** prior arrows) **passes**. So
  inserting the badge alone is safe.
- The crash lands **right after an Auto Layout pass** (the log is flooded with
  `DropTargetView.width == 0` constraint warnings from `layoutIfNeeded`); the
  assertion fires immediately after such a pass.
- The swap code is new in `92923b8` (the badge commit, currently HEAD). Before
  that the toolbar only ever inserted/removed the single arrows group on mode
  change — no swap existed. So this is a **pre-existing latent bug** in the badge
  feature, now exposed by the new regression test. It is **not** caused by the
  `onFullInvalidation` change per se — that change merely triggers the (correct)
  rebuild, whose index transition drives the swap.

### Fix attempts (all failed to stop the full-suite crash)

All were tested: class run passes, full suite still crashes the same way.

1. **Original (committed `92923b8`):** single `for` loop — `removeItem(at:)` the
   non-wanted item, then `insertItem(at:)` the wanted one, in the same pass.
2. **Deferral:** remove in one run-loop turn, defer the insert to the next turn
   via `DispatchQueue.main.async { self?.applyDiffNavigationToolbarItem() }`.
3. **Insert-first:** `insertItem` the wanted item first, then `removeItem` the
   other, in the same pass (current state on disk).

Conclusion so far: **the order/timing of the remove and insert does not matter.**
The crash is not about the mutation order. It is something about the swap
happening in the full-suite state (accumulated over ~700 preceding test cases).

### Leading hypotheses (unconfirmed)

- A **pending deferred block from a previous test** (each test calls
  `syncDiffNavigationToolbarItem()`, which queues a `DispatchQueue.main.async`)
  runs during this test's `pumpUntil`, mutating a previous window's toolbar while
  it is being torn down. Each test's `MainViewController` is created fresh by
  `makeWindow()` and closed in `defer`, but if it (or its window) is not
  deallocated before the next test, a stale block could fire on a half-closed
  toolbar. This would explain the state-dependence (only after many tests).
- `toolbar.items` (public) and NSToolbar's internal item list **diverge** after a
  mutation, so an index computed from `toolbar.items` is out of bounds for the
  internal `_itemAtIndex:`. Would explain why the index is always "valid" from our
  side yet the assertion still fires.
- The swap mutation lands while AppKit is mid-layout-pass; the deferral
  (`DispatchQueue.main.async`) does not guarantee a safe window.

### Most promising next step (recommended)

**Stop swapping toolbar items. Use ONE item whose content changes.** Replace the
separate `.diffNavigation` group and `.filesIdentical` badge with a single
custom-view toolbar item (e.g. `.diffStatus`) that is inserted once on entering
comparison mode and removed once on leaving; its **view** toggles between the two
nav buttons and the green badge. The toolbar's item list then never mutates
during the swap, which sidesteps `-[NSToolbar _itemAtIndex:]` entirely.

Cost: the arrows currently rely on `NSToolbarItemGroup` + `validateToolbarItem`
for enable/disable. A custom-view item means managing the two buttons'
`isEnabled` manually (drive it from the existing `diffNavigationState` in
`refreshDiffNavigation()`). Files: `MainWindowController.swift` (item builders,
delegate, allowed/default identifiers) and `MainViewController.swift`
(`applyDiffNavigationToolbarItem`, `showsIdenticalBadge`, `refreshDiffNavigation`,
and the `validateToolbarItem`/action routing). The two committed badge tests and
the new regression test should keep passing with the same observable toolbar
identifiers if the single item reuses `.diffNavigation`/`.filesIdentical`
semantics — or the tests need updating to the new identifier.

Alternative (smaller, unverified): confirm the "stale deferred block" hypothesis
by making `syncDiffNavigationToolbarItem()`'s deferred block capture the window
and bail if it is no longer the key/visible window, or by invalidating pending
blocks when a window closes. Cheaper, but only worth it if the single-item
refactor is deemed too invasive.

## Verification commands (dedicated DerivedData, scheme `DumpCompare`)

```bash
# Class (fast; catches compile errors + swap logic)
xcodebuild -project /Users/maxik/Projects/DumpCompare/DumpCompare.xcodeproj \
  -scheme DumpCompare -derivedDataPath /Users/maxik/.claude/derived-data/dumpcompare \
  -destination 'platform=macOS' \
  test -only-testing:DumpCompareTests/ToolbarValidationTests

# Full suite (the crash only reproduces here)
xcodebuild -project /Users/maxik/Projects/DumpCompare/DumpCompare.xcodeproj \
  -scheme DumpCompare -derivedDataPath /Users/maxik/.claude/derived-data/dumpcompare \
  -destination 'platform=macOS' test
```

The wrapper exit code is unreliable — grep the log for `** TEST SUCCEEDED **` /
`** TEST FAILED **` and `Program crashed`. Core tests are a **separate** Swift
package: `cd DumpCompareCore && swift test --filter <Class>` (not in the app
scheme).

## Decision needed from the user

The user's bug is fixed and its regression test is written. The remaining
blocker is the **pre-existing** swap crash, which needs either the single-item
refactor (robust, larger) or a cheaper targeted fix (unverified). Confirm which
direction before continuing, and note the full suite must be green before any
commit (the user runs it before "push").
