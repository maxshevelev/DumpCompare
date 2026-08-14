# DumpCompare — Implementation Plan

Step-by-step plan to build the macOS hex editor / binary comparator described in `REQUIREMENTS.md`.
Every step cites the requirement sections it satisfies, and each milestone ends with a testable "definition of done".

---

## 1. Target architecture

Three cleanly separated layers, exactly as required (§14):

```
┌────────────────────────────────────────────────────────────────────┐
│ Presentation (AppKit, MainActor)                                    │
│   AppDelegate · MainWindowController · PaneView · HexView ·          │
│   PaneHeaderView · StatusBar · MenuBuilder · drag-and-drop ·        │
│   dialogs (GoTo / SelectBlock / Find / confirmations / save prompts)│
├────────────────────────────────────────────────────────────────────┤
│ ViewModels / Coordinator (MainActor)                                │
│   AppCoordinator · WindowViewModel · PaneViewModel · DiffViewModel  │
│   — maps model events → UI state; owns background-task lifecycle    │
├────────────────────────────────────────────────────────────────────┤
│ Domain / Model (pure Swift, unit-testable)                          │
│   BinaryDocument · FileIdentity · UndoHistory · SelectionModel ·     │
│   OffsetParser · DiffEngine/BlockIndex · SearchEngine ·             │
│   ClipboardCodec · Validation                                       │
├────────────────────────────────────────────────────────────────────┤
│ Storage (pure Swift, unit-testable)                                 │
│   ByteStorage · EditableByteStorage · FileBackedStorage ·            │
│   ChunkCache · EditOverlayStorage · Materializer · Saver ·           │
│   TemporaryFileStore · ExternalChangeDetector                       │
└────────────────────────────────────────────────────────────────────┘
```

Concurrency rules (§14.4):

- Long-running work (full-file diff, search, chunk reads) runs in `actor`s / background tasks.
- All UI mutation is on `MainActor`.
- Diff/search tasks are cancellable and invalidate when files close or inputs change.

---

## 2. Key technical decisions (with rationale)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Core as a local Swift Package** `DumpCompareCore` (storage + model). The Xcode app target depends on it. | Enforces the "no AppKit in model/storage" rule at the compiler level; makes unit tests run fast and headless (§14.1/14.2, §17). |
| D2 | **Xcode project generated with XcodeGen** from a checked-in `project.yml`; the generated `.xcodeproj` is also checked in. | **Confirmed by user (XcodeGen).** Hand-writing `project.pbxproj` for a growing multi-target project is error-prone. XcodeGen is a build-time tool only (not a runtime/third-party library dependency). |
| D3 | **Storage model = read-only base + overwrite overlay.** Base comes from the file through a bounded LRU chunk cache. Edits are recorded as overwrite ranges in the overlay. Length-changing ops (insert/delete/append) **materialize** the overlay into a temporary file (copy-on-write) and reset the overlay. | Keeps the overlay trivially simple (overwrites only), so visible-region diff and search stay fast. Length changes are rare and user-confirmed (§5.2, §7, §13). |
| D4 | **Custom per-document `UndoHistory`** in core (op stack with old/new byte ranges and length changes), grouping a typing sequence / paste / delete into one op. Dirty tracking via a monotonically increasing op index checkpointed at save. | Model layer must not depend on AppKit; a custom stack gives grouped edits, length-change support, and precise "undo back to saved state clears dirty" (§5.1, §7.5). |
| D5 | **Diff = visible-region synchronous compare + background full-file block index (actor).** Block index invalidates incrementally; insert/delete invalidates from earliest affected offset onward (§8.3). | Immediate visible highlighting + responsive navigation; no UI blocking on large files. |
| D6 | **Custom virtualized `HexView`** (an `NSView` that lays out and draws only visible rows). | Requirement to support files far larger than RAM; a `NSTextView`/`NSTableView` of all rows would blow up (§13, §6). |
| D7 | **Saver**: in-place byte patch when only overwrites exist and the file is writable; otherwise temp-file + atomic `rename` replacement. | In-place patch preserves file identity and is fast; atomic replace is safe for length changes (§5.2). |
| D8 | **File identity** via `stat` device+inode with volume identity, falling back to standardized (symlink-resolved) path. | Hard links / symlinked paths to the same file must be detected as one file (§4.2). |
| D9 | **Sandboxed app** with security-scoped file access. App Sandbox entitlement on; `NSOpenPanel`/`NSSavePanel` grants per-file access; security-scoped bookmarks persist access across launches (Milestone 6). | **Confirmed by user (Sandboxed).** Matches the "sandbox access denied" error path in §16; adds bookmark bookkeeping at the storage/presentation boundary. |
| D10 | **AppKit, not SwiftUI** for the hex surface. Dialogs and simple chrome may use AppKit controls (`NSAlert`, `NSPanel`). | Precision rendering/selection/input for a hex view is far easier in `NSView` + Core Graphics/Core Text. |

---

## 3. Milestones and ordering

Dependency graph:

```
M0 Scaffolding
   └─▶ M1 Storage ─▶ M2 Document/Model ─▶ M3 Engines (diff/search/clipboard)
                     └──────────────────────────────┴──▶ M4 Single-file UI
                                                            └─▶ M5 Comparison UI
                                                                  └─▶ M6 DnD & file lifecycle
                                                                        └─▶ M7 Hardening & acceptance
```

M1 → M2 → M3 are pure Swift and test-first. M4+ are AppKit and depend on the core being complete and green.

---

## 4. Milestone 0 — Scaffolding & test harness

**Goal:** an empty app that builds and runs, with the core package and test targets wired.

1. Create repository layout:
   - `DumpCompareCore/` — Swift package (storage + model), with `Tests/`.
   - `DumpCompareApp/` — AppKit sources (entry point, window, views).
   - `project.yml` (XcodeGen) — app target, core package dependency, unit-test targets.
2. Generate `DumpCompare.xcodeproj` (decision D2); verify `xcodebuild build` and `xcodebuild test` work.
3. Minimal app shell:
   - `@main struct` / `NSApplicationDelegate` (`AppDelegate`).
   - Main `NSWindowController` + `NSWindow`; window sizing, title "DumpCompare".
   - `WindowMode` enum: `.empty`, `.singleFile`, `.comparison`.
   - Empty-mode placeholder view: "Open File" button (opens panel) + "Drag and drop files here" hint (§3.1).
   - `File > Open…` menu item wired (Cmd+O) — opening is a stub for now.
4. Empty-mode smoke test (manual): app launches, placeholder shows, dark/light both render.

**Definition of done:** builds clean; `DumpCompareCoreTests` runs; empty mode visible; no crash on quit.

---

## 5. Milestone 1 — Storage layer (pure Swift, test-first) ✅ done

> **API note (decision taken during implementation):** `ByteStorage.read(at:length:)` is **synchronous and thread-safe** rather than `async` as in the first draft. The bounded LRU chunk cache keeps small reads fast, and all long-running consumers (full-file diff, search, save) run in actors/background tasks, calling reads in bounded chunks. This keeps visible-region rendering simple (synchronous) while still never loading whole files and never blocking the UI with large jobs.

> **Implementation findings (M1):**
> - `StorageSaver.save` patches in place **only when the target is the original file** the storage was opened from (`EditOverlayStorage.originalURL`). Any Save As to a different path always rewrites atomically — a fresh target never contains the base bytes that untouched offsets assume.
> - A `ChunkCache` is keyed by chunk index **only**, so one instance can never serve two different files. Each copy-on-write materialization therefore gives the new base a **fresh cache** (same budget); sharing one cache across successive materialized bases served stale chunks after the swap (caught by `testEmptyFileOperations`/`testMixedOperationsPreserveContent`).

Requirement sections: §5, §7, §13, §14.1; tests §17.3.

1. **`ByteStorage` protocol**: `size` (UInt64), `func read(at: UInt64, length: Int) async throws -> [UInt8]` (clamped to EOF).
2. **`ChunkCache`**: bounded LRU cache keyed by chunk index; configurable byte budget; eviction policy; thread-safe.
3. **`FileBackedStorage`**: wraps a `FileHandle`/`URL`; reads via chunk cache (on-demand, lazy, clamped); rejects directories; throws clear errors (missing, permission, is-directory) (§4, §16).
4. **`EditableByteStorage`** protocol: `overwrite(range:with:)`, `insert(at:)`, `delete(range:)`, `append(_:)`, all synchronous on an actor.
5. **`EditOverlayStorage`** (decision D3):
   - Overwrite overlay as `[Range<UInt64>: [UInt8]]` (merged/coalesced on write) above the base.
   - `read` resolves base + overlay.
   - Insert/delete/append triggers **materialization** into a temp file (via `TemporaryFileStore`), then resets the overlay.
   - Tracks whether only-overwrites (`canPatchInPlace`) vs length changed (`needsRewrite`).
6. **`TemporaryFileStore`**: creates/deletes temp files, cleanup on deinit.
7. **`Saver`**: 
   - Overwrite-only + writable file → read-modify-write patched ranges in place (preserving untouched bytes and file identity).
   - Otherwise → write full content to temp file + atomic `rename` over target; preserve original on failure.
   - On failure, document stays dirty and error propagates (§5.2, §16).
8. **Unit tests** (§17.3): overwrite, append-at-EOF, insert, delete, read-back correctness, overlay coalescing, materialization correctness, in-place vs rewrite save path, save-failure keeps dirty.

**Definition of done:** all storage tests green; can open a multi-GB file and read arbitrary chunks without loading it whole; edits apply to overlay and read back correctly.

---

## 6. Milestone 2 — Document & model layer (pure Swift, test-first) ✅ done

> **Implementation findings (M2):**
> - An overwrite that extends past EOF is **split** into an overwrite of the existing bytes plus an insert of the new tail, so undoing shrinks the file back to its previous size without a truncate op (`BinaryDocument.applyOverwrite`). Every stored `UndoOperation` is length-preserving.
> - `EditOverlayStorage.originalURL` became `private(set) var` with `rebaseOriginalURL(_:)`: a Save As rebases the storage onto the new file so later overwrite-only saves to that target patch in place.
> - Edits are permitted on a read-only file (they live in the overlay / temp files); only saving to the read-only original throws `.fileIsReadOnly`. The UI maps that to an automatic Save As (§5.4).
> - `BinaryDocument` records grouped edit sessions (`beginEditGroup`/`endEditGroup`) as a single undo transaction; dirty state is `undoHistory.isDirty` (cursor ≠ saved checkpoint), so undo-to-saved clears dirty and redo-past-it sets it again.

Requirement sections: §4.2, §5, §7.5, §10.1/10.2; tests §17.1/17.2/17.7.

1. **`FileIdentity`** (decision D8): `deviceID + fileID` (stat) + volume identity; fallback standardized path (resolving symlinks); `==` across hard links/symlinks.
2. **`BinaryDocument`**: wraps an `EditableByteStorage`; holds identity, display URL/path, size, read-only flag, dirty state, `UndoHistory`, selection.
   - All mutations (`overwrite`, `insert`, `delete`, `append`) go through one method that records undo ops, updates size, and sets dirty.
   - Read-only flag derived from writability of the URL + storage state (§5.4).
3. **`UndoHistory`** (decision D4): op kinds overwrite/insert/delete/fillZero with before/after bytes + ranges; grouping by typing session; `undo()`, `redo()`, dirty checkpoint (`savedOpIndex`). Undo to saved state clears dirty; redo past it sets dirty again (§5.1, §17.7).
4. **`SelectionModel`**: start/end (absolute), empty selection, clamped to size; supports end-based and length-based construction (§10.2).
5. **`OffsetParser`**: parse hex with `0x`/`0X`, plain decimal, case-insensitive hex, 64-bit bounds, invalid-input errors (§10.1, §17.1).
6. **`BlockRange` value type** used by selection and navigation dialogs (start/end, start/length, validation).
7. **Unit tests** (§17.1, §17.2, §17.7): parsing matrix, selection edge cases, dirty/undo lifecycle.

**Definition of done:** model tests green; a document tracks dirty correctly through edit → save → undo → redo; identity detects same file via hard link.

---

## 7. Milestone 3 — Diff, search, clipboard engines (pure Swift, test-first)

Requirement sections: §8, §11, §12, §13; tests §17.4/17.5/17.6.

1. **`DiffBlockIndex` / `DiffEngine`** (decision D5):
   - Block model: `Block { kind: same | different, range }`; EOF-only bytes in the longer file are folded into a *different* block (§8.1).
   - Compare strictly by absolute 64-bit offset; no block matching/alignment (§1, §8).
   - API: `state(at:)`, `differenceBlocks()`, `sameBlocks()`, `firstBlock(after:)`, `firstBlock(before:)` (for navigation), `nextDifference(from:)`, `previousDifference(from:)`, same-block equivalents.
   - Incremental invalidation on edit: overwrite invalidates the block containing the range; insert/delete invalidates from earliest affected offset to EOF (§8.3).
   - Long scan runs in an actor with progress + cancellation.
2. **`SearchEngine`**: 
   - Pattern encodings: hex byte sequence (spaces/`0x` tolerated), ASCII, UTF-8, UTF-16 LE, UTF-16 BE (no auto-BOM) (§11).
   - Incremental chunked scan over storage (uses current unsaved content); background + cancellable + progress.
   - `find(from:direction:)` returns first match; supports Find Next/Previous.
3. **`ClipboardCodec`**: serialize bytes ↔ raw pasteboard; parse text as hex byte pairs only when unambiguous; explicit errors otherwise (§12.4, §17.6).
4. **Unit tests** (§17.4/17.5/17.6): identical/empty/one-byte/multi-block/EOF-only files, invalidation incl. offset-shift; search encodings and boundary matches; clipboard roundtrip + rejection.

**Definition of done:** engines green; diff of a large file builds incrementally in background with correct EOF-only blocks; search finds matches at start/middle/end and respects unsaved edits.

---

## 8. Milestone 4 — Single-file mode UI (AppKit)

Requirement sections: §3, §6, §7, §10.1, §10.2, §12, §15; acceptance §18.1/18.2.

1. **`WindowViewModel` / `PaneViewModel`** (MainActor): owns one or two documents, exposes visible-row data, status fields, dirty/read-only; bridges model events (edit, undo, save) to view refreshes.
2. **`HexView`** (decision D6):
   - Virtualized rows of 16 bytes: offset column (hex), hex bytes grouped 8+8 with a space, ASCII column (0x20–0x7E printable, else `.`) (§6).
   - Monospaced font, Dark Mode support, sufficient contrast; accessible labels/rows (§6, §15).
   - Rendering of visual states: difference background, modified red foreground, both combined, selection that stays legible, EOF placeholder cells (§6).
   - Cursor + selection drawing; row/column hit-testing.
3. **Editing (§7):**
   - Hex nibble input (advance after 2nd nibble); ASCII input; overwrite-first; typed range overwrites selection; Cmd+A selects all.
   - Delete/Backspace **fill 0x00** (no length change); `Edit > Delete Bytes…` is the explicit, confirmed length-changing delete (§7.3).
   - Paste Write (Cmd+V, overwrite, may extend EOF without confirmation) vs Paste Insert (menu item, confirmed) (§7.1/7.2, §12.2/12.3).
   - Undo/Redo wired to `UndoHistory` (§7.5).
4. **Pane chrome**: header (file name, `*` dirty indicator, read-only/locked indicator), status bar (active file, size, cursor hex+decimal, selection length, dirty, read-only, comparison status, background progress) (§3.4, §15).
5. **Menus (§15):**
   - File: Open…, Close File, Save (Cmd+S), Save As… (Cmd+Shift+S), Revert.
   - Edit: Undo, Redo, Copy, Paste Write, Paste Insert, Fill Selection with Zero, Delete Bytes…, Select Block…, Find…, Go To Position… (Cmd+G).
   - Shortcuts discoverable in menu titles.
6. **Dialogs:** Go To Position (Cmd+G; `0x`-prefilled, hex/decimal, inline validation, EOF clamping/warning) (§10.1); Select Block (start/end or start/length; validation; status-bar length display) (§10.2); Save/Save As flows incl. read-only → auto Save As; overwrite confirm on Save As (§5.3/5.4).
7. **Dirty & save flow:** save clears dirty; save failure keeps dirty + shows error; revert with confirm if dirty (§5.2, §16).

**Definition of done:** open a file, scroll, edit bytes in hex and ASCII, undo/redo, save/save-as, dirty indicator updates; manual smoke pass + core-level tests already green.

---

## 9. Milestone 5 — Comparison mode

Requirement sections: §3, §6, §8, §9, §10.3, §15; acceptance §18.3–18.10.

1. **Layout:** two panes with a draggable splitter; toggle left/right ⇄ top/bottom (View menu); persist choice in `UserDefaults` (§3.3). Active pane visually distinguished (e.g. header accent) (§3.3).
2. **Comparison wiring:**
   - Auto-start when two files open; clear when a pane closes (§8.3).
   - Visible-region diff computed synchronously for visible rows; full-file `DiffBlockIndex` built in a background actor with progress + cancellation (§8.3, §13).
   - Edits invalidate visible rows immediately and the block index incrementally; insert/delete shifts invalidate from earliest offset (§8.3).
3. **Rendering states (§6):**
   - Different bytes → background highlight in both panes where a byte exists.
   - Shorter pane → muted EOF placeholder cells past its EOF; longer pane → EOF-only bytes highlighted as differences.
   - Modified bytes → red foreground; combined diff+modified → both.
4. **Navigation (§10.3):** Next/Previous Difference, Next/Previous Same Block; Cmd+Option+→/← (with Shift variants); moves cursor to block start, syncs both panes; status message when none; on-demand scan with progress while index is building.
5. **Pane synchronization (§9):** scroll, cursor, and selection synchronized by absolute offset; shorter pane clamps to EOF/missing area; safe for empty files and EOF positions.
6. **Pane/window closing (§3.5/3.6):** close pane → back to single-file (pane 2 becomes pane 1); last pane → empty mode; dirty close prompts save/discard/cancel; window close → combined prompt listing every modified file.
7. **Go To Position in comparison mode** moves both panes; clamps with warning (§10.1).

**Definition of done:** two files compare live; navigation finds diff/same/EOF blocks; edits update highlighting near-instantly in the visible region; synchronized scrolling/selection works; closing flows never lose changes silently.

---

## 10. Milestone 6 — Drag-and-drop & file lifecycle

Requirement sections: §4, §5.5; acceptance §18.1.

1. **Drag-and-drop (§4.3):** accept file URLs; enforce regular-file-only (reject directories/packages with alert, §4).
   - Empty mode: first two files → panes 1, 2; extras → notification.
   - Single-file mode: on drag-enter, split the pane visually into "Replace current file" and "Open as second file" targets matching current/default layout; behavior per §4.3.
   - Comparison mode: drop targets the hovered pane; second file opens in the other pane only if empty; notify on ignored files.
2. **Open-panel placement rules (§4.1):** multiple-selection placement across empty/single/comparison modes; replace-active-pane with confirm when dirty ("Save and Replace" / "Replace Without Saving" / "Cancel"; cancel if save fails); same-file-in-target → reload/no-op; same-file-in-other-pane → warning, do not open (§4.1.6, §4.2).
3. **External change detection (§5.5):** file watcher on open documents; prompt reload/keep when clean; reload/discard/keep/save-as when dirty.
4. **Preferences persistence:** pane layout, splitter proportions, window frame (§3.3).
5. **Sandbox access management (D9)** — security-scoped bookmarks so opened files stay accessible across launches; refresh permissions after Save As; wire the "sandbox access denied" error path (§16).

**Definition of done:** all open/drop/close rules behave per §4; same-file identity prevents double-open; external changes produce correct prompts; no data loss paths.

---

## 11. Milestone 7 — Hardening, accessibility, acceptance

Requirement sections: §15, §16, §17, §18.

1. **Accessibility (§15):** full keyboard navigation, accessible labels on hex cells/controls, contrast check in light + dark, non-color cues for EOF/unsaved states.
2. **Error handling sweep (§16):** each listed error surfaces a clear, recoverable prompt; confirm destructive ops; never lose changes silently.
3. **Performance validation (§13):** open a multi-GB file; scroll smoothly; search and full-diff in background with progress; memory stays bounded.
4. **Acceptance checklist (§18):** walk every numbered criterion; fix gaps.
5. **UI tests (optional, §17):** open flows, drag-and-drop, save prompts, navigation commands (XCTest UI target).
6. **Final polish:** menu key-equivalents review, README, local docs, git housekeeping, final code review.

**Definition of done:** all 14 acceptance criteria met; core unit tests green; no known crash or data-loss path; app is keyboard-accessible and Dark-Mode clean.

---

## 12. Build & run

```bash
# Generate the Xcode project (decision D2; generated project is checked in)
xcodegen generate

# Build the app
xcodebuild -project DumpCompare.xcodeproj -scheme DumpCompare build

# Core unit tests (local Swift package; also runnable by opening DumpCompareCore in Xcode)
swift test --package-path DumpCompareCore
```

No third-party runtime dependencies. XcodeGen (if used) is a build-time tool only.

---

## 13. Decisions and open questions

Decided (confirmed by user): **sandboxed app** (D9) and **XcodeGen** (D2).

Open:

1. **Undo history bound** — cap on in-memory undo ops with spill-to-disk (`TemporaryFileStore`) once a threshold is exceeded (§7.5 "may be bounded by memory/disk resources").

---

## 14. Requirement → work traceability

| Requirement area | Where implemented |
|---|---|
| Storage/chunking/large files (§13, §14.1) | M1 |
| Document, dirty, identity (§4.2, §5) | M2 |
| Undo/redo, selection, offset parsing (§7.5, §10.1–10.2) | M2 |
| Diff/comparison (§8), search (§11), clipboard (§12) | M3 (+M5 wiring) |
| Hex view, editing, visual states (§6, §7) | M4 |
| Layout, splitter, sync, navigation, closing (§3, §9, §10.3) | M5 |
| Open/drop rules, external changes (§4, §5.5) | M6 |
| Accessibility, errors, acceptance (§15, §16, §17, §18) | M7 (throughout) |
