# Segmented Undo for Typing: byte → byte-batch with fast rollback (Variant B)

## Context

Undoing keyboard-entered bytes is currently **byte-by-byte**: each completed byte is
its own undo transaction. Undoing a large amount of typed input (fast typing, key
auto-repeat) takes one Cmd+Z press per byte — slow and tedious.

The agreed solution:

1. **A series** is a run of completed bytes entered in a single input region (hex or
   ASCII), **not broken** by:
   - a pause longer than a threshold (~0.7 s), **or**
   - a deterministic breaker: user caret movement (arrow keys/click), input-region
     change (hex↔ASCII), any other mutating command (Delete, Backspace, Fill,
     Paste), select/find/select-all, undo/redo.
   Auto-advancing the caret while typing (`advanceAfterByte`) does **not** break a series.
2. **Rollback by Variant B** (a "coalescing window"):
   - the first Cmd+Z removes the **last byte** of the series (fix a typo);
   - a second Cmd+Z **within a window (~0.5 s)** removes the **rest of the series in one step**;
   - a second Cmd+Z **after a pause** removes one more byte from the remaining series.
   - An accidental rollback of a large series is no problem: one Cmd+Shift+Z restores it
     (redo is symmetric — a step removed by one press is restored by one press).
3. Thresholds are **typed constants** (not user settings). They can be moved into
   Settings later using the same mechanism as `ComparisonSettings`.

**Why not "the whole series in one Cmd+Z" (Variant A):** it loses character-by-character
correction of a typo at the end of the series. Variant B gives both behaviors: a byte
on the first press, a batch on a fast second press.

Key fact from the code: every completed byte **already records its own transaction**
(hex type-pair is one transaction via `beginEditGroup`/`endEditGroup`). A series needs
**no new recording mechanism** — only a shared series identifier on history steps and a
"step layer" in `UndoHistory`, so one undo gesture can remove N transactions (a batch)
and redo symmetrically restores them.

## Data model

### `UndoHistory` — move to "steps" (one undo gesture = one step)

The history is currently flat (`history: [UndoTransaction]` + `cursor`). Batches and
redo symmetry need a step layer:

```swift
public final class UndoHistory: @unchecked Sendable {
    /// One undo gesture: a transaction (a normal edit or one entered byte)
    /// or a batch of transactions (the rest of a series removed by one fast press).
    /// `seriesID` links the steps of one typing series; nil is outside a series.
    private struct Step {
        var transactions: [UndoTransaction]   // in recording order (first..last)
        var seriesID: UInt64?
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private var savedTransactionIndex = 0     // dirty control: transaction count
    private var undoTransactionCount = 0

    // Fast-rollback state:
    private var lastUndoWasSeriesByte = false
    private var lastUndoSeriesID: UInt64?
}
```

Public API changes:

- `record(_ ops:selectionBefore:selectionAfter:seriesID: UInt64? = nil)` + the caret
  form `record(_:caretBefore:caretAfter:fileSize:seriesID:)`. All existing callers pass
  no `seriesID` → nil, behavior unchanged.
- `undo(batch: Bool = false) -> [UndoTransaction]?` — removes **one step**; if
  `batch == true` and the last undo removed a series byte (`lastUndoWasSeriesByte`)
  and the top is the same series (`seriesID` matches) → removes **all steps of the
  series as one batch**. Returns the removed transactions **in recording order**.
- `redo() -> [UndoTransaction]?` — removes one step from the redo stack; if it is a
  batch (`transactions.count > 1`), **unfolds** it back into individual byte steps on
  the undo stack (the series structure is restored, byte-by-byte rollback available again).
- `noteSelectionAfterOnLast`, `markSaved`, `reset`, `canUndo`, `canRedo`, `isDirty`,
  `undoDepth` — as today. `isDirty` = `undoTransactionCount != savedTransactionIndex`
  (counted in transactions, not steps — unfolding a batch on redo does not break dirty control).

Logic:

```swift
func undo(batch: Bool = false) -> [UndoTransaction]? {
    guard let last = undoSteps.popLast() else { return nil }
    var collected = [last]
    if batch, let sid = last.seriesID, sid == lastUndoSeriesID, lastUndoWasSeriesByte {
        while let next = undoSteps.last, next.seriesID == sid {
            undoSteps.removeLast()
            collected.append(next)
        }
    }
    let ordered = collected.reversed().flatMap(\.transactions)   // recording order
    undoTransactionCount -= ordered.count
    redoSteps.append(Step(transactions: ordered, seriesID: last.seriesID))
    lastUndoWasSeriesByte = (collected.count == 1 && last.seriesID != nil)
    lastUndoSeriesID = last.seriesID
    return ordered
}

func redo() -> [UndoTransaction]? {
    guard let step = redoSteps.popLast() else { return nil }
    for txn in step.transactions {
        undoSteps.append(Step(transactions: [txn], seriesID: step.seriesID))
    }
    undoTransactionCount += step.transactions.count
    lastUndoWasSeriesByte = false
    lastUndoSeriesID = nil
    return step.transactions
}
```

`record` also resets `lastUndoWasSeriesByte`/`lastUndoSeriesID` (a new edit breaks the
"fast window").

Caret on a batch undo comes from the **first** transaction (in recording order)
`selectionBefore` = the start of the series; on redo from the **last** transaction
`selectionAfter` = the end of the series. Per-byte `selectionBefore`/`After` are already
correct (recorded through the same path as today; `noteSelectionAfterEdit` via
`notifyAfterEdit` captures the actual selection — for selection consumption this is the
remainder).

### `BinaryDocument`

- `private var currentSeriesID: UInt64?`
- `public func beginSeries(_ id: UInt64)` → `currentSeriesID = id`; `public func endSeries()` → `currentSeriesID = nil`.
- `record(...)` (lines 253–265) and `endEditGroup()` (lines 218–230) pass `currentSeriesID`
  into `undoHistory.record(seriesID:)`.
- `undo(batch: Bool = false) throws -> DiffEdit?` (today lines 139–147): get
  `[UndoTransaction]` from `undoHistory.undo(batch:)`, apply inverses in reverse order
  across all transactions (`txns.reversed()` × `ops.reversed()`),
  `selection = txns.first.selectionBefore.clamped(to: storage.size)`, return
  `DiffEdit.netDiffEdit(ops: all inverses)`. `nil` on empty history.
- `redo() throws -> DiffEdit?` (today lines 153–159): apply ops forward across all
  transactions, `selection = txns.last.selectionAfter.clamped(...)`, `netDiffEdit(ops:)`.

The public `BinaryDocument.undo()/redo()` API (`DiffEdit?`) **does not change** — only the
internal `undoHistory` call.

### `PaneViewModel`

New constants/injection (pattern like `MinimapSplitView.defaults`):

```swift
/// Time injection (tests substitute it).
static var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
/// Pause between bytes after which a series breaks.
static let seriesBreakThreshold: TimeInterval = 0.7
/// Window in which a repeated undo removes the rest of the series in one step.
static let fastUndoWindow: TimeInterval = 0.5
```

New state: `typingSeriesOpen: Bool`, `seriesCounter: UInt64`, `lastTypingTime: TimeInterval`,
`lastTypingMode: HexInputRegion?`, `lastUndoTime: TimeInterval?`.

**Series start** — new `ensureTypingSeries(mode: HexInputRegion)`, called at the start of
each completed byte:
- hex: the `nibble == 0` branch of `typeHexNibble` (after `prepareForTyping()`, before
  `beginTypingGroup()`);
- ascii: the start of `typeASCII`.
- If `!typingSeriesOpen || clock() - lastTypingTime > seriesBreakThreshold || lastTypingMode != mode`
  → close the old one (`doc.endSeries()`), `seriesCounter += 1`, `doc.beginSeries(seriesCounter)`,
  `typingSeriesOpen = true`. Update `lastTypingMode`.
- `lastTypingTime = clock()` updated after each entered nibble/character (the interval to
  the next byte is measured from the last event). A type-pair (two nibbles) does not break:
  the check runs only at the start of a byte (`nibble == 0`), not between nibbles.

**Series break** — new `breakTypingSeries()` = `endTypingGroup()` (close the half-byte) +
`doc.endSeries()` + `typingSeriesOpen = false`. Called from:
- `deleteForward` (504), `deleteBackward` (523), `fillSelection` (544), `deleteBytes` (552),
  and at the start of `pasteWrite` and `pasteInsert` (today they call
  `endTypingGroup()`/`resetEditingState()` — replace/supplement with `breakTypingSeries()`
  **before** recording their own transaction);
- `resetEditingState()` (328–334) — covers undo/redo, selectAll, setSelection, select(range:).

**Caret movement and region change** (movement — `moveCaret(to:)` 620, click/drag;
region — `setInputRegion` 338): close **only the series** (`doc.endSeries(); typingSeriesOpen = false`),
do not touch the nibble group (keep current behavior). `advanceAfterByte` does not touch the series.

**Undo/redo with the fast window** (670–698):

```swift
func undo() throws -> Bool {
    guard let doc = document else { return false }
    resetEditingState()                       // close half-byte + series
    let now = Self.clock()
    let fast = lastUndoTime.map { now - $0 < Self.fastUndoWindow } ?? false
    lastUndoTime = now
    let edit = try doc.undo(batch: fast)
    if let edit { onEdit?(edit); notifyCompanionContentChanged(edit) }
    notify()
    return edit != nil
}

func redo() throws -> Bool {
    guard let doc = document else { return false }
    resetEditingState()
    lastUndoTime = nil                        // redo does not inherit the fast window
    let edit = try doc.redo()
    if let edit { onEdit?(edit); notifyCompanionContentChanged(edit) }
    notify()
    return edit != nil
}
```

`doc.undo(batch: fast)` — `UndoHistory` itself decides whether to batch (fast && the last
undo was a series byte && the top is the same series). Cmd+Z auto-repeat behavior: first
press — a byte, second (fast) — the rest of the series, then one transaction each (after
the batch `lastUndoWasSeriesByte == false`).

## Tests

**Update existing `UndoHistoryTests.swift`** (undo/redo now return `[UndoTransaction]`):
- `history.undo()?.ops.count` → `history.undo()?.count`; `history.undo()?.ops` →
  `history.undo()?[0].ops`; `undone?.caretBefore` → `undone?[0].caretBefore`;
  for a grouped transaction `history.undo()?[0].ops.count, 3`.

**New core tests (`UndoHistoryTests.swift`):**
1. First undo of a series is one byte: `record(t1, t2, t3, seriesID: 1)`; `undo(batch: false)` → `[t3]`.
2. Fast second undo removes the rest of the series: `undo(batch: true)` → `[t2, t1]`
   (recording order), `canUndo == false`.
3. Undo after a pause is again one byte: `undo(batch: false)` twice in a row → `[t3]`, then `[t2]`.
4. A batch does not cross a series boundary: `s1(seriesID: 1)`, `s2(seriesID: 2)`;
   `undo(batch:false)→[s2]`; `undo(batch:true)→[s1]` (no batch).
5. A batch does not apply after a non-series undo: `t1(nil)`, `t2(seriesID:1)`;
   `undo(false)→[t2]`; `undo(true)→[t1]`.
6. A new record clears the fast state: undo a series byte → `record` → `undo(batch:true)`
   removes only the new step.
7. Redo of a batch restores the byte-by-byte structure: after `undo(batch:true)`, `redo()`
   returns everything; the next `undo(batch:false)` removes the last byte (the series is byte-by-byte again).
8. Dirty control across a batch: series, `markSaved()`, `undo(batch:true)` → `isDirty`; `redo()` → `!isDirty`.

**New core tests (`BinaryDocumentTests.swift`):**
1. `beginSeries(1)` + three `overwrite`s + `endSeries()`; `undo(batch:false)` → last byte
   removed, caret at its place; `undo(batch:true)` → rest of the series, caret at the start (0).
2. Same scenario with a selection (selection consumption): batch undo restores the full
   selection, redo the state after the last byte.

**New app tests (`PaneViewModelTests.swift`)** — via `PaneViewModel.clock` (substitute + time control):
1. `typeASCII` ×3 in a row (intervals < threshold) → `undo()` → byte 3; `undo()` fast → rest
   of the series, caret 0; `redo()` → everything restored.
2. `typeASCII` ×3; `undo()`; `clock += 1`; `undo()` → byte 2 (no batch).
3. A pause between inputs breaks the series: `typeASCII`; `clock += 1`; `typeASCII` → 2 series
   (undo removes only the second; a fast second undo removes only its remainder).
4. Caret movement breaks the series: `typeASCII`; `moveCaret(to:)`; `typeASCII` → 2 series.
5. Region change breaks the series: hex input; `setInputRegion(.ascii)`; ascii input → 2 series.
6. Auto-repeat input (intervals 30–90 ms) — one series.
7. A fast undo after two **separate** edits does not batch (different series/nil).

**Check existing tests with multiple undos in a row:** `testUndoRestoresTheSelectionTypingWasConsuming`
(two undos + redo) — expected stable (the second undo removes a one-byte remainder — same
result), but run all `PaneViewModelTests`/`BinaryDocumentTests` and substitute `clock` where needed.

## Implementation order

1. **`UndoHistory.swift`** — Step layer, `seriesID`, `undo(batch:)`, `redo()`, transaction-based
   dirty. Update `UndoHistoryTests`.
2. **`BinaryDocument.swift`** — `beginSeries`/`endSeries`/`currentSeriesID`, pass `seriesID` in
   `record`/`endEditGroup`, `undo(batch:)/redo()` across all transactions. Update `BinaryDocumentTests`.
3. **`PaneViewModel.swift`** — `clock`, thresholds, `ensureTypingSeries`/`breakTypingSeries`,
   breakers (delete/fill/paste/resetEditingState/moveCaret/setInputRegion), undo/redo with the
   fast window. Update/add `PaneViewModelTests`.
4. Run the affected tests.

## Verification

- Targeted runs (fresh `-derivedDataPath` in `$CLAUDE_JOB_DIR/tmp`, log to a file):
  - core: `cd DumpCompareCore && swift test` (or targeted via `--filter`).
  - app: `xcodebuild test -scheme DumpCompare -destination 'platform=macOS' -derivedDataPath ... -only-testing:DumpCompareTests/UndoHistoryTests`
    and similarly `BinaryDocumentTests`, `PaneViewModelTests`, `SelectionRedrawTests`, `ContentRedrawTests`.
- Full run — the user before committing (project rule).
- If xcodebuild rewrote the shared xcscheme —
  `git checkout -- DumpCompare.xcodeproj/xcshareddata/xcschemes/DumpCompare.xcscheme`.
- Manual check: (1) quickly type 20+ bytes → Cmd+Z removes the last byte, a fast second Cmd+Z —
  the whole series; after a pause — again a byte; (2) hold Cmd+Z — byte, batch, then one each;
  (3) Cmd+Shift+Z restores everything a batch removed with one press; (4) arrow/click/hex↔ASCII
  between bytes break the series; (5) the diff background in the companion updates in one batch
  step (net DiffEdit).

## What stays the same (deliberately)

- Undo/redo of other operations (fill, delete, paste, insert) — one transaction each, no series.
- `BinaryDocument.undo()/redo()` public API (`DiffEdit?`) does not change.
- The nibble group (`beginEditGroup`/`endEditGroup`) — as is.
