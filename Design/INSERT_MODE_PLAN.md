# Insert mode: Edit-menu toggle, byte insertion, red caret

## Context

The app is an overwrite-only hex editor: typing replaces the byte under the caret.
The user wants an optional **Insert mode**: a boolean (checked) item in the Edit menu,
defaulting to **off (Overwrite)** at every launch (not persisted). When on:

- typing (hex digits and ASCII) **inserts** the completed byte at the caret, shifting the
  entire tail of the file right by one (the file grows);
- the caret becomes a **red vertical line at the byte boundary** (classic insert caret),
  instead of the blue nibble bar of overwrite mode.

The good news: the whole insert machinery already exists and is battle-tested —
`pasteInsert` uses it. This feature is wiring, not new storage:

- `ByteStorage.insert(at:bytes:)` — implemented by `MemoryBackedStorage` and `EditOverlayStorage`
  (the runtime storage; it rewrites base+overlay to a new temp file, i.e. **O(n) per inserted byte**).
- `BinaryDocument.insert(at:bytes:)` records an `UndoOperation.insert(at:bytes:)`;
  `inverted` turns it into a `.delete`, and `applyForward` replays it on redo — so undo/redo
  of inserts works with zero new code.
- `DiffEdit.insert(at:length:)` and `MainViewController.repaintMinimap(after:)` handle insert
  (case `.insert, .delete` at MainViewController.swift:1099).
- `UndoHistory` steps/series (`seriesID`, `undo(batch:)`, `redo()`) work on any transaction,
  so an insert typing series gets the same segmented undo as overwrite typing.

Per the plan workflow, exploration confirmed: the Edit menu is built programmatically in
`MainWindowController.makeEditMenu()`, commands target `MainViewController`, and menu state is
kept in sync via `MainViewController.validateMenuItem` (the `Minimap Overview` checkmark is the
template). Caret drawing is `HexView.drawCaret` using `HexTheme.caretColor`
(`NSColor.controlAccentColor`).

## Decisions (from the user)

- **Caret in insert mode**: a thin red vertical line at the byte boundary (not just a color swap).
- **Persistence**: never persisted — the app always launches in Overwrite mode.
- **First-type warning**: the **first** insert-mode keystroke after a file is opened shows a
  warning "analogous to Paste Insert" (a destructive confirm, "Insert"/"Cancel"); Cancel swallows
  the keystroke. Shown **once per opened file** — toggling the mode off/on within the same file
  does not re-warn; the flag resets when a new file is opened (`open`, `openUntitled`, `close`).
  The pane has no way to present alerts (typing arrives via `HexView.keyDown` →
  `PaneViewModel.typeHexNibble`/`typeASCII`), so the controller injects a confirm closure.
- **Hex byte entry (insert mode)**: the byte is inserted on the **first** digit — `0xA` inserts a
  new byte at the caret with the high nibble set and the **low nibble empty** (`digit << 4`), and the
  tail shifts right immediately. The caret stays on the new byte; the **second** digit fills the low
  nibble **in place** (an overwrite, no new insertion) and advances. The two nibbles coalesce into
  **one undo step** via the existing edit-group mechanism (the group mixes `.insert` + `.overwrite`
  ops freely — `pendingGroupOps` collects both, `endEditGroup` records them as one transaction, and
  `inverted`/`applyForward` replay them). The empty low nibble is drawn as a **placeholder slot**
  (dim `_`) in the low-nibble cell while the byte is half-typed.

## Changes

### 1. Menu item — `DumpCompareApp/MainWindowController.swift`
In `makeEditMenu()`, add after `Delete Bytes…` (line 292):
```swift
editMenu.addItem(withTitle: "Insert Mode",
                 action: #selector(MainViewController.toggleInsertMode),
                 keyEquivalent: "")
```

### 2. Mode state + toggle — `DumpCompareApp/MainViewController.swift`
- Stored `var insertMode = false` (session-global; both panes stay in sync).
- `@objc func toggleInsertMode(_ sender: Any?)`: flips `insertMode`, sets `pane.isInsertMode` on both
  panes, and (idempotently) injects the **one-time warning** closure into each pane, presenting a
  Paste-Insert-style destructive confirm via the existing `confirmAlert` (line 2532; runs Cancel in
  tests). The closure captures the pane weakly to avoid a retain cycle, and reads `pane.caretOffset`
  at call time:
  ```swift
  @objc func toggleInsertMode(_ sender: Any?) {
      insertMode.toggle()
      for pane in [windowModel.pane1, windowModel.pane2] {
          pane.isInsertMode = insertMode
          pane.confirmInsertModeWarning = { [weak self, weak pane] in
              guard let self, let pane else { return true }
              let offset = pane.caretOffset
              let response = self.confirmAlert(
                  title: "Insert?",
                  message: "Inserting at offset \(String(format: "0x%X", offset)) shifts every byte from here on — the file structure may be affected.",
                  confirmTitle: "Insert",
                  destructive: true
              )
              return response == .alertFirstButtonReturn
          }
      }
  }
  ```
  (Wiring here — rather than at pane creation — means the callback is guaranteed to exist before any
  insert-mode keystroke, and it's mode-independent.)
- In `validateMenuItem` (line 2758), add a case mirroring `toggleMinimapOverview`:
  ```swift
  case #selector(toggleInsertMode):
      menuItem.state = insertMode ? .on : .off
      return true
  ```

### 3. Pane-level mode + typing — `DumpCompareApp/PaneViewModel.swift`
- `var isInsertMode = false { didSet { if document != nil { notify(selectionChangedOnly: true) } } }`
  — the `didSet` repaints the caret rows so the caret instantly changes color/shape.
- Data source: `var hexInsertMode: Bool { isInsertMode }` (add to the `HexViewDataSource` conformance).
- **One-time warning**: `var confirmInsertModeWarning: (() -> Bool)?` (controller-injected presenter,
  nil under pure unit tests → type without asking) and `private var hasWarnedInsertShift = false`,
  reset in `open(url:)` (line 216), `openUntitled()` (239), and `close()` (255). A small guard is
  called at the **top** of `typeHexNibble` and `typeASCII` (before any series/nibble/doc work, so a
  cancelled warning leaves the document completely untouched):
  ```swift
  private func confirmFirstInsertModeEdit() -> Bool {
      guard isInsertMode, !hasWarnedInsertShift,
            let confirm = confirmInsertModeWarning else { return true }
      guard confirm() else { return false }   // user cancelled → swallow the keystroke
      hasWarnedInsertShift = true
      return true
  }
  ```
  In `typeHexNibble` (line 490): `guard let doc = document, (0...15).contains(digit), confirmFirstInsertModeEdit() else { return }`.
  In `typeASCII` (line 522): `guard let doc = document, confirmFirstInsertModeEdit() else { return }`.
- **`typeHexNibble`** — branch on `isInsertMode`. `offset = typingOffset(doc)` = selection start;
  `prepareForTyping` is **skipped** in insert mode (typing inserts before the caret, it never consumes
  a selection). The two nibbles coalesce into one undo step with the existing `beginTypingGroup` /
  `endTypingGroup` pair — the group collects the `.insert` and `.overwrite` ops and records them as one
  transaction, so a byte typed in insert mode undoes as a unit, exactly like overwrite mode:
  - high nibble (`nibble == 0`): `ensureTypingSeries(mode:)`; `beginTypingGroup()`;
    `try? doc.insert(at: offset, bytes: [UInt8(digit) << 4])` (byte inserted, low nibble empty=0, tail
    shifts right); `nibble = 1`; touch `lastTypingTime`; **no advance** — the caret stays on the new
    byte so the next digit fills it; `onEdit?(.insert(at: offset, length: 1))`;
    `notifyAfterEdit(range: offset..<offset + 1, sizeBefore:)` (full `notify()` — the size grew);
    `notifyCompanionContentFullyChanged()`; return. (`doc.insert` leaves the caret at `offset`:
    `clampSelection` only clamps to the new size; inserting at the caret keeps the caret on the new byte.)
  - low nibble (`nibble == 1`): `let old = byteAt(offset) ?? 0`;
    `try? doc.overwrite(range: offset..<offset + 1, with: [(old & 0xF0) | UInt8(digit)])` (fills the
    low nibble **in place**); `nibble = 0`; `endTypingGroup()` (records the insert+overwrite pair as one
    transaction, `naturalCaretAfter` = offset+1); `advanceAfterByte()`; touch `lastTypingTime`;
    `onEdit?(.overwrite(range: offset..<offset + 1))`;
    `notifyAfterEdit(range: offset..<offset + 1, sizeBefore:)`; return.
- **`typeASCII`** — insert branch: `endTypingGroup()` (flush any pending hex nibble group, as today),
  `ensureTypingSeries(mode:)`, then `try? doc.insert(at: offset, bytes: [byte])` instead of overwrite,
  `nibble = 0`, `advanceAfterByte()`, `onEdit?(.insert(...))`, `notifyAfterEdit`,
  `notifyCompanionContentFullyChanged()`. (Still `endTypingGroup()` first, as today; skip
  `prepareForTyping`.)

Everything downstream is reused: `notifyAfterEdit` already does a full `notify()` when the size changed,
`notifyCompanionContentFullyChanged()` repaints the companion's diff background (an insert moves every
offset at/after the caret), and `advanceAfterByte()` advances the caret past the inserted byte.

### 4. Caret — `DumpCompareApp/HexView.swift` + `HexLayout`
- `HexViewDataSource`: add `var hexInsertMode: Bool { get }`.
- `HexTheme`: add `static let insertCaretColor = NSColor.systemRed`.
- `drawCaret` (line 1220): when `dataSource?.hexInsertMode ?? false`, draw a 1 pt vertical line at the
  **byte boundary** in red — hex region: `x = layout.hexByteX(column:)` (left edge of byte `offset`'s
  cell, i.e. the boundary it is about to be inserted before); ascii region: `x = layout.asciiX(column:)`.
  Same rect height as today (`layout.rowFrame(row:).minY` … `.rowHeight`). Otherwise keep the current
  overwrite bar (`layout.caretX(...nibble:)`, width 2/1, `HexTheme.caretColor`).
- **Empty low-nibble slot** (`draw`, after the row loop, before `drawCaret`): when
  `isActive`, `hexInsertMode == true`, and `hexCaretNibble() == 1`, draw a dim placeholder `_` over the
  low-nibble cell of the caret byte — `x = layout.hexByteX(column:) + layout.charWidth`, baseline and
  row height as today, color `HexTheme.mutedTextColor` (reuse the existing `draw(text:in:baseline:color:)`,
  line 1247). The row's hex string already painted the byte as e.g. `A0`; the placeholder covers the
  `0` so the user sees `A_` until the second digit lands (which zeroes the nibble and clears the slot).
  Add `HexTheme.insertCaretColor = NSColor.systemRed`.

### 5. Tests
- **`DumpCompareTests/PaneViewModelTests.swift`** (patterns already exist: `openPane`, `typeASCII`,
  `typeHexNibble`, `caretOffset`, `fileSize`, `hexByteStates`, `hexCaretNibble`, `undo()`/`redo()`,
  `PaneViewModel.clock`):
  1. `testInsertModeFirstHexNibbleInsertsByteWithEmptyLowNibble` — open 1 byte, set `isInsertMode = true`,
     type `A` → file grows to 2, byte 0 == 0xA0 (low nibble empty), old byte 0 shifted to offset 1,
     `caretOffset == 0` (caret stays on the new byte), `hexCaretNibble() == 1`.
  2. `testInsertModeSecondHexNibbleFillsInPlaceThenAdvances` — continue `B` → size still 2,
     byte 0 == 0xAB, byte 1 == the original byte, `caretOffset == 1`.
  3. `testTypeASCIIInsertModeInsertsByte` — type `0x41` → size 2, byte at 0 is 0x41, byte at 1 is the
     original byte, caret 1.
  4. `testInsertSeriesUndoIsSegmented` — with `clock` pinned, type `0x41`/`0x42`/`0x43` in insert mode
     (each byte = one undo step via the edit group) → `undo()` removes only the last byte (size shrinks
     by 1), fast `undo()` removes the rest of the series, `redo()` restores all three (mirrors the
     existing overwrite-series tests at lines ~315–410).
  5. `testOverwriteModeStillOverwrites` — default (no insert mode): existing behavior, size unchanged.
  6. **Warning tests** (inject `pane.confirmInsertModeWarning` — a counting closure):
     - `testInsertModeFirstEditWarnsOnce` — closure returns true; type `A` → byte inserted, closure
       called exactly once; type `4` (completes 0xA4) → not called again; type `B` → still not called
       (`hasWarnedInsertShift` stuck for the file).
     - `testInsertModeWarningCancelSwallowsKeystroke` — closure returns false → type `A`: size
       unchanged, caret 0, `hexCaretNibble() == 0`, **no undo step** (nothing inserted); then a second
       keystroke with the closure now returning true inserts normally (the warning re-asks because the
       first was cancelled).
     - `testInsertModeNilWarningCallbackTypesWithoutAsking` — no callback set → inserts proceed
       (already the path covered by tests 1–4, asserted explicitly here).
     - Reset check: with the flag set, `open(url:)` on a fresh file → `typeHexNibble` calls the closure
       again (flag cleared on open).
- **`DumpCompareTests/CaretPlacementTests.swift`** (or a small new test): render the active pane,
  sample pixels via the `sampleRowColours`/brightness helpers from `MinimapTests`:
  - `testInsertModeCaretIsRedVerticalLine` — insert mode on: the pixel at `layout.hexByteX(column:)`
    is red (`red − blue > threshold`); overwrite mode (default): the same x is the accent caret blue.
  - `testInsertModePendingNibbleShowsEmptyLowNibbleSlot` — insert mode, drive `pane.typeHexNibble(0xA)`
    (nibble == 1), render: the low-nibble cell (`hexByteX + charWidth`) is **dim/placeholder**
    (muted, near the cell background), not the byte-text/accent color; after `typeHexNibble(0xB)` the
    cell shows the digit `B` at normal byte-text brightness.
- **`DumpCompareTests/MainWindowMenuTests.swift`**: the Edit menu has an "Insert Mode" item wired to
  `#selector(MainViewController.toggleInsertMode)` (follow the existing title-order tests, line 54).
- **Menu state** (mirror the overview pattern at MinimapTests.swift:1578): fresh controller →
  `validateMenuItem` on a `toggleInsertMode` item leaves `.off`; after `controller.toggleInsertMode(nil)` →
  `.on`, both panes' `isInsertMode == true`, and both panes' `confirmInsertModeWarning != nil` (the
  closure was wired).

## Known limitations

- Each inserted byte is a full O(n) storage rewrite (the existing `EditOverlayStorage.insert`), so
  typing in insert mode on a very large file is expensive — same primitive `Paste Insert…` uses, and
  acceptable for the feature's first pass. **Buffered input** (typing into a temporary buffer, applied
  to the document on a pause, UI never blocked) is explicitly **out of scope here** — the user made it
  a separate topic that will also cover `pasteInsert`.
- Moving the caret between a byte's two nibbles (half-typed) leaves the edit group open in **both**
  overwrite and insert mode — the next typed byte coalesces into the same undo step. This is
  pre-existing overwrite behavior (`moveCaret` calls `closeTypingSeries` but never `endTypingGroup`);
  the insert-mode flow reuses the same group, so the edge is consistent. Not addressed here.

## Verification

- Targeted: `xcodebuild -project DumpCompare.xcodeproj -scheme DumpCompare -derivedDataPath
  "$CLAUDE_JOB_DIR/tmp/dd-insert" build-for-testing` then `test-without-building`
  `-only-testing:DumpCompareTests/PaneViewModelTests` (and the caret + menu suites), logs to files.
- Manual: toggle Insert Mode in the Edit menu → caret turns into a red vertical line at the boundary;
  **first keystroke** shows the "Insert?" confirm (Insert/Cancel, destructive); Cancel swallows the key,
  Insert proceeds; a later keystroke in the same file does **not** re-warn; re-enabling the mode after
  toggling off doesn't re-warn; opening another file re-arms it. Type hex digits → the **first** digit
  inserts a byte with the high nibble and an **empty low-nibble slot** (`A_`), the tail shifts right;
  the **second** digit fills the slot in place (`A5`) and the caret advances; typing ASCII inserts a
  whole byte at once. Cmd+Z removes the last completed byte (one step per byte), a fast second Cmd+Z
  rolls back the whole series, Cmd+Shift+Z restores; the checkmark follows the mode; relaunch → back
  to Overwrite.
- Do **not** commit until the user asks (project rule).
