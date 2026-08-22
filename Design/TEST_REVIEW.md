# Test suite review — August 2026

A full audit of all 965 tests (674 app, 291 core) against the production code
they exercise, and the first pass of changes that came out of it. Written to be
read once and then used as a work list: **§1** is what changed, **§2** what the
audit found, **§3** what is left and in what order, **§4** the rules worth
keeping for new tests.

The headline, before the details: the suite is in better shape than "a lot of
tests written one bug fix at a time" suggests. Of 965 tests, **about 80 % earned
a plain KEEP** — a real rule, stated absolutely, that fails when the rule breaks.
What the audit found was not bloat but a specific, nameable minority: tests that
restate the implementation, mirror images of symmetric functions, and a handful
guarding code the app no longer calls.

---

## 1. What changed (commit `2058948`)

| | before | after |
|---|---|---|
| App tests | 674 | 633 |
| Core tests | 291 declared / 291 run | 281 / 281 |
| Test-body time (app) | 67.1 s | 66.4 s |

**Three tests had never run once.** `testForwardProgressNeverExceedsOne`,
`testBackwardProgressMeasuresTheSearchedSpan` and
`testCaseInsensitiveFoldingIsByteLevel` were written inside `Flag` — a plain
helper class at the bottom of `SearchEngineTests.swift`, not the `XCTestCase` —
so XCTest never discovered them. One brace. Backward search progress, the bug one
of them documents ("it opened at 91 % for a caret at 10 %"), had no live coverage
at all. They pass now that they run.

**54 tests deleted**, each because another test already fails for the same cause:

- *Strict subsets.* `testEditMenuHasToggleBookmarkWithCmdD` asserts a subset of
  `testEditMenuHasBothBookmarkCommands`; `testClickingHexDumpActivatesThatPane`
  performs the first click of `testClickingOtherDumpSwitchesActivation`.
- *Mirror images of a symmetric function.* Every branch of
  `HexView.changedSelectionRects` treats `old` and `new` alike, so
  "growing" ↔ "shrinking" pairs cannot fail apart. Same for the two halves of a
  nibble threshold, and for `caretX` at nibble 0 vs 1.
- *Tests of dead code.* `DiffEngine.findBlock` and `DiffIndexBuilder.scanForBlock`
  have no caller: `ComparisonCoordinator.findBlock` navigates the hunk index and
  its comment says it deliberately does **not** scan while building — the exact
  use case the dead function's own comment claims. Four of its five tests went;
  the differential one stays until the code's fate is decided (§3).
  `PaneViewModel.find` was deleted outright with its three tests — the Find bar
  calls `SearchEngine` itself, off the main thread, with cancellation and
  progress.
- *Assertions about Swift rather than DumpCompare.* `testContextMenuOffsetIsNilByDefault`
  asserted the default of an uninitialised `UInt64?`. `testCoreModuleLoads` was
  `XCTAssertTrue(true)`.
- *Over-specified UI trivia with no rule behind it.* An arbitrary 46 pt ceiling
  on the gap between a field and a table; two reads of the same private colour
  constant twelve lines apart.

**Seven tests rewritten** because they could not fail — the category worth
knowing about, because a green test that cannot fail is worse than no test:

| test | why it could not fail |
|---|---|
| `testMutedTextIsDimmer` | `isEqual` between a dynamic `NSColor(name:)` and a semantic one is *always* false, so it passed for a "muted" colour identical to the ink. Now resolves both in a pinned appearance and compares alpha — the dimension the dimming actually uses. |
| `testAnEmptyListKeepsRoomForItsMessage` | expectation was `minVisibleRows * rowStep + 2`, the production expression: a floor of 0 passed, leaving the empty state unreadable. Now three rows, written out, plus "the message fits". |
| `testTheListStopsGrowingAtTenRowsAndScrolls` | read the cap from `maxVisibleRows`. Now the spec's literal 10. |
| `testResetRestoresDefaults` | compared the getters to `defaultRowHeightScale` — a default of 3.0 would pass and triple every row. Now `""` and `0.8`. |
| `testFillRequiresSelection` | asserted only the disabled state, so a permanently greyed-out Fill passed. Now both states. |
| `testCaretX`, `testDeadZoneMidlines` | expectations were `hexByteFrame().minX`, `hexByteX + charWidth/2`… — the implementation restated. Now absolute x. |
| `testTheNearerMarkWins` | the two marks were ~15 pt apart while the snap box reaches 7.5 pt, so each click had one mark in range and the tie-break never ran. Now clicks *between* two marks 0x800 apart. |

Each rewrite was verified by breaking the behaviour it protects and watching that
one test fail: `minVisibleRows` set to 0, the muted alpha to 1.0, the
`distance < best.distance` comparison deleted.

**One test added.** `testTheMapsGeometryIsWhatTheSpecSays` pins the minimap's
scale and marker sizes absolutely (2 pt cells, 1 pt gaps, 10 pt margins, a 7 pt
mark inside a 9 pt marker). Every other minimap test expresses itself *through*
those constants, so all of them would stay green if the numbers changed.

**Documentation caught up with the code.** The invalidation citations pointed at
"§3.3", which is *comparison mode*; the rule lives in §13. Three spec lines the
tests had already outgrown now describe the app: no separate Paste Write item
(⌘V is the system paste), the empty state's borderless icon, the header's filled
document glyph instead of a trailing `*`.

---

## 2. What the audit found, by category

Seven audits, one per cluster, each judging every test against the same
questions: is it obsolete, can it fail, does another test already fail for this
cause, would merging it keep one cause per failure, and is there a rule behind
it at all.

**The good news is specific, not general.** The strongest parts of the suite are
the differential tests — the word-at-a-time diff scan checked against an
independent byte-at-a-time reference across every alignment and eleven chunk
sizes; the patched overview summary compared with a full rebuild; the piece
table's windowed reads compared with byte-at-a-time reads. Those are the tests
that would catch a real regression nobody predicted, and there are more of them
than I expected. The pixel-render tests are also mostly honest: they sample real
drawn output with a negative control beside it (a mark's purple against the
unmarked row, the band's colour against the divider below it).

**The recurring defect has one shape:** the expected value is computed by the
same expression as the value under test. It appeared in every cluster —
`labelFrames()` (a test-only second implementation) asserted against the
formula it is built from; the search-results panel height asserted against a
re-typed copy of `applySearchResultsHeight`'s own clamp; a marker's box height
asserted to equal the constant that defines it. It is an easy defect to write
while fixing a bug (you have the formula in front of you) and it is invisible
afterwards, because the test is green and specific-looking.

**The second recurring shape is a test whose fixture does not reach its rule.**
`testHeaderDoubleClickIsANoOpInStackedMode` never enters the stacked-mode guard —
at a window width of 800 the pane already fits, so it bails at the same early
return as the test above it. `testBareCaretMoveInvalidatesCaretRowsAndNeighbours`
claims the rows between two carets are not repainted, with the carets two rows
apart, where the mandatory ±1 expansion fills the gap anyway. These pass, look
like coverage, and prove something weaker than their name.

**Timing.** The suite is fast (66 s for 633 app tests) but it spends ~10 s of that
waiting on wall clocks, and two tests are races by construction rather than slow:
one writes 2 GiB to make a search slow enough to observe, another asserts a
background task got some work done inside 20 ms. Both have a seam available
(`SearchEngine.find` already takes a `chunkSize`; the stream can be pulled with an
explicit iterator) — the fixture is doing work a seam should do.

**Isolation.** `FindFlowTests` carefully redirects two `UserDefaults` domains and
then writes the developer's real `SearchResultsPanelHeight` on almost every
Search All, because `FilePaneView` has no swappable `defaults` (three other
classes in the app do). Several window tests write the layout flag by hand and
never restore it. Nothing fails today; the order the tests happen to run in is
carrying it.

---

## 3. What is left, in the order I would do it

The audits produced exact per-test verdicts; this section is the work list they
imply, largest value first. Everything here is *additive* to what is already
committed — the suite is green and honest as it stands.

### 3.1 Merges — about 60 pairs, mechanical (2–3 h)

Pairs that share a fixture and assert two arms of one rule: the menu-facet
triples (titles / targets / key equivalents of one built menu, each rebuilding a
`MainWindowController` and leaking a window), the mirror-contour geometry
quartet in `ActivePaneTests`, the OpenPlacement rules split one switch case per
test, the bookmark popover's commit closures, the storage-lifecycle glyph states.
Each merge is "move one assertion, delete one test, name the survivor for the
rule". The rule to hold: a merged test must still point at **one** cause when it
fails — where it would not, leave the pair alone.

### 3.2 Table-driven consolidation in core — 87 tests → ~25 (3–4 h)

The core suite's redundancy is not duplication, it is *shape*: dozens of tests
that differ only in input and expected output. `DiffEngine.blocks` construction
(7), `applyOverwrite` (4), `netDiffEdit` (8), `collapse` (5+), `OffsetParser` (6),
`SelectionModel`/`BlockRange` construction (12), `ChunkCache` map operations (5),
`FileBackedStorage` read clamping (6), `PieceTable` insert positions and deletes
(6). One test per group over a table of labelled cases loses nothing and makes
the boundary cases (0, 1, chunk edge, EOF, overflow) visible as a set instead of
scattered across a file.

**The one with real coverage upside:** `EditOverlayStorageTests` and
`MemoryBackedStorageTests` are the same suite typed twice — ten pairs identical
down to a shared comment. They are both testing the `EditableByteStorage`
contract. One conformance suite parameterised over the two implementations
*gains* coverage in both directions: the overlay's zero-fill-past-EOF branch is
currently untested (only Memory has that test), and `testDeleteAll` /
`testEmptyFileOperations` exist only for the overlay.

### 3.3 Rewrites still outstanding — 12 tests (2 h)

The rest of the "cannot fail" list: `HexColumnHeaderTests`' two `labelFrames()`
tests (assert absolute x, or the clip observer that actually sets
`horizontalOffset`), the four search-results panel-height tests (assert the
clamp's fraction absolutely, or stop mirroring the arithmetic and assert only
"never taller than the pane allows"), `HeaderFitWidthTests`' stacked-mode test
(use a window narrower than the grid so the guard is reached),
`MinimapTests.testOverviewViewportBandHasAPixelFloor` (drive a sub-pixel
viewport), `testOverviewToneStaysInTheDumpsRange` (drop the two identities, keep
monotonicity and the bounds), the two `BookmarkMinimapTests` marker-geometry
tests (assert the box against itself: `width == height·√3/2`), and
`ComparisonPaneTests.testSelectionsAreIndependent` (its two mirror assertions
restate `hexMirroredSelection`).

Two more worth doing while there: seed the RNG in the three property tests
(`testBlocksInAWindowAgreesWithTheWholeIndex`, `testRandomFilesMatchTheReference`,
`testMatchesAPlainArrayOverARandomEditSequence`) so a failure can be replayed —
`TextDecoderTests` already shows the pattern with an explicit LCG. And make
`ComparisonResizeTests.testStackedResizeKeepsHeightRatio` drive the real divider
drag, after which `ProportionalSplitView.setPosition` — a method whose docstring
says "used by tests" — can go.

### 3.4 Shared test helpers — 1 file, ~250 lines removed (1–2 h)

`tempFile(_:)` is copied into **32** test classes, `descendants(of:_:)` into 12,
`pumpUntil` into 6, the synthetic `mouse(_:at:window:)` into 6. Several copies
never delete their files (the host is sandboxed, so they accumulate in its
container). A draft `TestSupport.swift` exists in the job's scratch directory
with all four as an `XCTestCase` extension plus `addTeardownBlock` cleanup.

**The catch, learned the hard way:** a private method with the same signature as
a method on an `XCTestCase` extension is an *illegal override*, not a shadow. The
extension therefore cannot land incrementally — it has to arrive in the same
commit that deletes all 32 copies. Mechanical, but all at once.

### 3.5 Seams instead of sleeps (2 h)

- `PaneViewModel`'s own-write suppression window is a hard-coded 1.0 s read from
  `Date()`, so `testOwnSaveDoesNotTriggerExternalChange` sleeps 1.2 s
  unconditionally. The class already owns an injectable `static var clock` for
  the typing-series tests; routing the window through it makes the test instant.
- `FilePaneView.operationDebounce` (0.3 s) is private, so two tests hard-code
  0.5 s waits that must stay in sync with it by hand.
- `FileChangeWatcher`'s 0.4 s debounce is a literal on a private queue; its
  three tests cost ~3.5 s. An injectable interval would pay for itself.
- `DiffNavigationTests` waits 0.5 s twice on *negative* conditions where
  `MainViewController.diffNavigationState` already answers synchronously.
- Give `FilePaneView` the swappable `defaults` that `FindBarView`,
  `FindHistoryStore` and `MinimapSplitView` already have, and the suite stops
  writing the developer's real panel-height preference.

### 3.6 Coverage gaps worth a new test (2–3 h)

Where adding is worth more than removing. In rough order of what would hurt:

- **`BinaryDocument.cancelEditGroup()`** — called in production
  (`PaneViewModel`), tested nowhere. Its contract is subtle (revert pending ops
  in reverse, record no transaction, restore the group's start selection); a bug
  leaves a half-typed insert in the file with nothing on the undo stack.
- **`StorageSaver.rewriteDirectly`** — the sandbox fallback the shipping app
  actually uses for Save As is never reached by a test.
- **Save after Save As** must still patch in place: `rebaseOriginalURL` is never
  exercised.
- **`changedRanges` after an offset shift** — "one inserted byte marks the whole
  tail", the rule the minimap depends on; only overwrites are covered.
- **Concurrency.** Four storage types document "reads and mutations may come from
  any thread" and the app really does hand storage to background diff/search
  tasks while the main actor edits. There is not one concurrent test. A
  read-while-insert stress test over `EditOverlayStorage` is cheap.
- **`StorageError` for EACCES and a non-regular file** — §16 maps them to
  distinct alerts; only `.fileNotFound` and `.isDirectory` are tested.
- **ISO-8859-1's own behaviour** — nothing asserts that it leaves 0x80–0x9F as
  placeholders where cp1252 shows €/œ/™, the one difference that makes the menu
  item worth having.
- **A second Search All superseding the first** (§11) — the
  `searchAllGeneration` machinery, the most intricate logic in the search path,
  is untested.

### 3.7 Decisions only you can make

- **`DiffEngine.findBlock` / `DiffIndexBuilder.scanForBlock`**: delete, or restore
  a caller? Right now it is dead *and* half-tested, which is the worst of the
  three. I kept one differential test as its guard.
- **`SearchEngine.findAll`** (non-streaming) has no production caller either, but
  sixteen tests hang off it and they specify `scanAll` deterministically, which
  the stream tests cannot do as crisply. Keep as library API, or re-point the
  tests at `findAllStream` and retire it?
- **`BlockRange`** is built in one place inside the package and used nowhere else.
  Is it still the intended representation for the Go To / Select Block dialogs?
- **The one-third clamp on the results panel height** — product rule or
  implementation detail? The answer decides whether its test should pin the
  fraction or stop asserting arithmetic.
- **The overwrite caret's 2 pt bar and 2 pt overhang** are pinned to the pixel by
  three assertions. Defend, or free to restyle?

---

## 4. Rules worth keeping for new tests

Distilled from what the audit kept and what it threw away.

1. **Write the expected value, do not compute it.** If the expectation is the
   production expression, the test asserts `x == x`. `XCTAssertEqual(l.caretX(…),
   140)` catches what `XCTAssertEqual(l.caretX(…), frame.minX)` cannot. Where an
   absolute is genuinely fragile (system font metrics), assert a *relation* that
   is not the formula — "wider on both sides", "never reaches the hex column".
2. **Break it once.** After writing a test, break the behaviour it protects and
   watch *that* test fail. Every rewrite in §1 was verified this way, and two of
   them were written twice because the first version stayed green.
3. **Make sure the fixture reaches the rule.** Assert the premise: "the file is
   taller than the viewport", "both marks are in range of this click", "the pane
   is narrower than its grid". A fixture that bails early is a test that passes
   for the wrong reason.
4. **One cause per failure.** Merge two arms of one rule; do not merge two rules.
   The question is what a red test tells you at 2 a.m.
5. **Prefer a seam to a sleep, and a counter to a clock.** The cost tests in
   `EditOverlayStorageCostTests` are the model: they count temp files and pieces,
   never milliseconds, and they are exactly as strict on a loaded machine.
6. **A differential test beats a literal when the rule is an algorithm.** Compare
   the fast path against a slow independent implementation, and seed the RNG so a
   failure can be replayed.
7. **Cite the spec section that actually contains the rule** — and when the spec
   turns out to be stale, fix the spec in the same commit.
