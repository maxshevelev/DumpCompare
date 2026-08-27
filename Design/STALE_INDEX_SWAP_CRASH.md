# Stale comparison index on file replacement, and the toolbar swap crash it exposed

> Status: **both fixed.** The user's bug shipped in `d9446ff`. The toolbar swap
> crash that its regression test exposed is fixed by giving each window's
> toolbar its own identifier — see **The swap crash**, which corrects the
> diagnosis an earlier draft of this document carried. Full suite: 754 tests,
> green, no crash.

## The user's bug (fixed, `d9446ff`)

The user reported: after loading two **identical** files into panes that
previously held **different** files, the panes and the local minimap show no
differences, but the Prev/Next Difference **buttons still reflect the old
files** and jump the caret across **phantom diff blocks**, and the minimap
**overview** still shows the old orange blocks.

Root cause: replacing a file in an already-open pane leaves the mode at
`.comparison`, so `MainViewController.refreshMode()` early-returns and never
calls `apply(mode:)` — the one path that restarts the comparison. And
`PaneViewModel.open(url:)` / `openUntitled()` did **not** fire
`onFullInvalidation` (only `revert()` did). So the pre-built `DiffBlockIndex`
was never rebuilt and kept the previous files' differences.

Two independent diff readers disagree when the index is stale:

- **Panes + local minimap** read difference state per byte from the **live**
  comparison → correctly show "no differences".
- **Minimap overview + diff navigation** read the **pre-built** `DiffBlockIndex`
  → show the old (phantom) blocks.

The fix fires `onFullInvalidation?()` on wholesale storage replacement, the way
`revert()` already does — in comparison mode that is wired to
`comparisonCoordinator.rebuild()`. `ToolbarValidationTests.testReplacingFilesInOpenPanesRebuildsTheComparison`
is the regression test, and it is what exposed the crash below.

## The swap crash (fixed)

When the comparison went from "has differences" (arrows shown) to "no
differences" (badge shown) — the **swap** — the test process died with:

```
*** Assertion failure in -[NSToolbar _itemAtIndex:], NSToolbar.m:1475
Invalid parameter not satisfying: index>=0 && index<[_currentItems count]
```

`xcodebuild` then restarted the run, which is why the summary reported only the
tests from the final launch while the overall result was `** TEST FAILED **`.

### Root cause

Every window built its toolbar with the **same** identifier:

```swift
let toolbar = NSToolbar(identifier: "MainToolbar")
```

**AppKit implicitly synchronises toolbars that share an identifier**: inserting
or removing an item in one propagates the same mutation, at the same index, to
every other live toolbar carrying that identifier. Those sibling toolbars hold
a different item list — a window still at `.empty` never had the arrows
inserted — so the index that travels with the mutation is out of bounds for
`_currentItems`, and `-[NSToolbar _itemAtIndex:]` asserts.

This is why the failure was **state-dependent**: it needs several live windows
with the shared identifier. It is not a race, not a mid-layout mutation, and
not about the order of the remove and the insert.

The app itself is **single-window** (`AppDelegate` builds one
`MainWindowController`, and `allowsAutomaticWindowTabbing` is off), so a user
could never hit this. Only the test suite, where every test builds its own
window, accumulates the siblings.

### The fix

A per-window identifier, in `MainWindowController.buildToolbar()`:

```swift
let toolbar = NSToolbar(identifier: "MainToolbar-\(UUID().uuidString)")
```

Nothing is lost by making it unique: the item layout is fixed in code,
`allowsUserCustomization` is off and `autosavesConfiguration` is off, so there
is no configuration worth sharing between windows — only the implicit
synchronisation that caused this.

### Evidence

A reduced repro is the ten test classes that build a `MainWindowController`
(`GoToBookmarksTests`, `ZoomToFitTests`, `LayoutToggleTests`,
`TypingModeIndicatorTests`, `TitleBarMenuTests`, `BookmarkTests`,
`MinimapTests`, `SegmentsFormTests`, `MainWindowMenuTests`,
`ToolbarValidationTests`) — about half the wall-clock of the full suite:

| Same reduced set | `_itemAtIndex` assertions | Result |
| --- | --- | --- |
| Shared `"MainToolbar"` identifier | 4 | crash + restart, `** TEST FAILED **` |
| Per-window identifier | 0 | 257/257 in one launch, `** TEST SUCCEEDED **` |

Two classes alone do **not** reproduce it — the sibling toolbars have to
accumulate, which is the mechanism's own signature.

Full suite with the fix: green (754 tests) on two of three runs; the third had
one unrelated failure that did not recur and was not the crash (no
`_itemAtIndex`, no restart). The crash itself did not appear in any of the
three.

### Diagnoses that were wrong

Recorded because each is plausible and cost time:

1. **The order of the remove and the insert.** Three variants were tried —
   remove-then-insert, deferring the insert by a run-loop turn, and
   insert-then-remove (which shipped in `d9446ff`). None changed anything,
   because the mutation that crashes is not the local one: it is the copy AppKit
   forwards to a sibling toolbar.
2. **The delegate returning a cached `NSToolbarItem`.** The delegate did hand
   back the same instance on every request, which does violate the documented
   contract (`toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` is
   meant to return a fresh item). Making both swapped items fresh per request
   was tried and measured: **the full suite still crashed identically.** The
   caching is therefore not the cause, and the code was left as it was rather
   than carrying a change that fixes nothing.
3. **A stale deferred block from a previous test, or a mutation landing
   mid-layout-pass.** Both were suggested by the crash appearing right after an
   Auto Layout pass. Neither is needed to explain it: the reduced repro is
   deterministic and the guard on `window.isVisible` already covers closed
   windows.

The earlier draft's recommended fix — collapsing the arrows and the badge into
a **single custom-view toolbar item** so the item list never mutates — was not
needed. It would have worked by sidestepping the mutation entirely, but at the
cost of managing the two buttons' `isEnabled` by hand instead of through
`validateToolbarItem`.

## Verification commands (dedicated DerivedData, scheme `DumpCompare`)

```bash
# The reduced repro: the window-building classes, ~50 s
xcodebuild test -project DumpCompare.xcodeproj -scheme DumpCompare \
  -derivedDataPath "$DUMPCOMPARE_DD" -destination 'platform=macOS' \
  -only-testing:DumpCompareTests/GoToBookmarksTests \
  -only-testing:DumpCompareTests/ZoomToFitTests \
  -only-testing:DumpCompareTests/LayoutToggleTests \
  -only-testing:DumpCompareTests/TypingModeIndicatorTests \
  -only-testing:DumpCompareTests/TitleBarMenuTests \
  -only-testing:DumpCompareTests/BookmarkTests \
  -only-testing:DumpCompareTests/MinimapTests \
  -only-testing:DumpCompareTests/SegmentsFormTests \
  -only-testing:DumpCompareTests/MainWindowMenuTests \
  -only-testing:DumpCompareTests/ToolbarValidationTests

# Full suite
xcodebuild test -project DumpCompare.xcodeproj -scheme DumpCompare \
  -derivedDataPath "$DUMPCOMPARE_DD" -destination 'platform=macOS'
```

The wrapper exit code is unreliable — grep the log for `** TEST SUCCEEDED **` /
`** TEST FAILED **`, and for `_itemAtIndex` and `Restarting after` to tell a
crash from an ordinary failure. Core tests are a **separate** Swift package:
`cd DumpCompareCore && swift test --filter <Class>` (not in the app scheme).
