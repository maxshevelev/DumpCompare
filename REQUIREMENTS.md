You are an expert macOS software engineer specializing in Swift, AppKit, large-file processing, and high-quality desktop UX.

Design and implement a macOS GUI application for visually comparing and editing two binary files.

The output must be a production-quality, maintainable, testable macOS app.

=====================================================================
1. PRODUCT GOAL
=====================================================================

Create a macOS GUI tool that can:

1. Open one or two binary files.
2. Display each file as a hex dump with ASCII representation.
3. Allow hex editing of each file independently.
4. When two files are open, compare them byte-by-byte by absolute zero-based offsets only.
5. Highlight differing bytes and EOF-only regions.
6. Support navigation to next/previous difference/same blocks.
7. Support large files that do not fit fully into RAM.

Do not implement structural diff, block matching, move detection, or sequence alignment. Comparison must always be by absolute offset only.

=====================================================================
2. PLATFORM AND PROJECT CONSTRAINTS
=====================================================================

Platform:
- macOS 14.0 minimum.
- Native macOS app.
- Swift + AppKit.
- Xcode project.
- Swift concurrency should be used for asynchronous work.
- Avoid third-party dependencies unless absolutely necessary and explicitly justified.

App model:
- The app has a single main comparison window in MVP.
- The main window supports three modes:
  1. Empty mode: no file opened.
  2. Single-file mode: one file opened.
  3. Comparison mode: two files opened.

The app must not require multiple windows in MVP, but architecture should not make future multi-window support impossible.

App icon:
- The icon shows a chip from above with two hex bytes on it, the second marked
  the way the hex view marks a difference: dark glyphs on the difference orange
  (§6). A line down the chip's centre stands for the two files.
- It is generated, not hand-drawn: `Design/AppIcon.swift` draws the 1024 pt
  master and `Design/render-appicon.sh` slices it into the asset catalog, so a
  change to the artwork is a change to code.
- Only a clean build proves the icon actually ships — an incremental build
  restores the compiled catalog from its intermediates even when the artwork is
  gone.

=====================================================================
3. WINDOW, PANES, AND LAYOUT
=====================================================================

The main window contains up to two file panes.

Each file pane displays one opened binary file.

Layout rules:

1. In empty mode, show a placeholder area with:
   - an “Open File” button;
   - a hint that files can be dragged and dropped.

2. In single-file mode:
   - the only file pane occupies the entire client area.

3. In comparison mode:
   - two panes are visible.
   - panes can be arranged either left/right or top/bottom.
   - the arrangement is user-configurable.
   - the selected arrangement must persist across app launches.
   - a draggable splitter should allow adjusting pane size.
   - the active pane must be visually distinguishable.

4. Each pane should have a title/header showing:
   - file name;
   - dirty indicator as “*” when the file has unsaved changes;
   - read-only/locked indicator if the file cannot be written back directly.

5. Pane closing:
   - the user can close either pane in comparison mode.
   - closing a pane returns the app to single-file mode.
   - if pane 1 is closed, pane 2 becomes pane 1.
   - if the last pane is closed, the app returns to empty mode.
   - closing a pane with unsaved changes must prompt the user to save/discard/cancel.

6. Window closing:
   - closing the window with unsaved changes must prompt for each modified file or present a combined dialog where every modified file can be saved or discarded.
   - the user must never lose unsaved changes silently.

=====================================================================
4. FILE OPENING RULES
=====================================================================

Files can be opened by:

- File > Open…
- drag-and-drop from Finder or other file providers.

Only regular files are supported. Directories and packages should be rejected with a clear alert unless future support is explicitly added.

4.1 File > Open behavior

The Open panel may allow multiple selection.

Placement rules:

1. If no panes are occupied:
   - first selected file opens in pane 1;
   - second selected file opens in pane 2;
   - if more than two files are selected, open only the first two and notify the user that additional files were ignored.

2. If only pane 1 is occupied:
   - the first selected file opens in pane 2;
   - additional selected files are ignored with notification.

3. If both panes are occupied:
   - the first selected file replaces the file in the currently selected/active pane;
   - additional selected files are ignored with notification.

4. Replacing a pane that has unsaved changes requires confirmation:
   - offer “Save and Replace”, “Replace Without Saving”, and “Cancel”.
   - if saving fails, the operation must be cancelled.

5. If the file selected for opening is already open in the target pane:
   - if the file has no unsaved changes, treat as reload/revert or no-op with unobtrusive feedback;
   - if the file has unsaved changes, prompt whether to discard changes and reload, or cancel.

6. If the file selected for opening is already open in the other pane:
   - do not open it again;
   - show a warning that the same file cannot be opened in both panes.

4.2 Same-file identity

The app must detect “same file” using a robust canonical identity:

- prefer volume UUID + inode / URL resource identifier if available;
- fallback to resolved standardized path after resolving symlinks;
- hard links and symlinked paths pointing to the same underlying file must be considered the same file.

4.3 Drag-and-drop behavior

General:

- The app must accept file URLs from drag-and-drop.
- Dropping more files than can be opened must result in a notification.
- Only the first two dropped files may be opened.

Drop in empty mode:

- first file opens pane 1;
- second file opens pane 2;
- extra files ignored with notification.

Drop in comparison mode:

- dropping onto a specific pane targets that pane;
- if multiple files are dropped:
  - first file targets the hovered pane;
  - second file opens in the other pane only if that pane is empty;
  - if the other pane is occupied, the second file is not opened automatically;
  - extra files are ignored;
  - the user is notified which files were ignored.

Drop in single-file mode:

- when a file drag enters the single pane window, visually split the window into two drop targets:
  1. “Replace current file”;
  2. “Open as second file”.
- the split orientation should match the current or default pane layout:
  - left/right layout: replace target on one side, add target on the other;
  - top/bottom layout: replace target on one side, add target on the other.
- if the user drops on “Replace current file”:
  - the first dropped file replaces the current file;
  - if a second dropped file exists, it opens as pane 2.
- if the user drops on “Open as second file”:
  - the first dropped file opens as pane 2;
  - additional files are ignored with notification.
- if the drag leaves the window or is cancelled, no change occurs.

Dirty-state protection applies to drag-replacement too.

=====================================================================
5. FILE MODEL, DIRTY STATE, SAVE, AND SAVE AS
=====================================================================

Each opened file must have an independent document model.

Per-file state includes:

- canonical file identity;
- display URL/path;
- file size;
- read/write status;
- unsaved/dirty state;
- undo/redo stack;
- edit overlay or storage object;
- selection/cursor state if UI-related.

5.1 Dirty state

- Each file has an independent dirty flag.
- Dirty state is shown in the pane title using a leading or trailing “*” alongside the file name.
- Undoing all modifications must clear dirty state if contents match the last saved state.
- Saving clears dirty state.

5.2 Save

- Save operates on the currently selected/active pane.
- Cmd+S must save the active pane.
- If the file is writable and no length change requires a full rewrite, saving may patch modified bytes in place.
- If in-place patching is unsafe or impossible, save via a temporary file and atomic replacement.
- Save must preserve file contents integrity.
- If save fails, the document must remain dirty and an error must be shown.

5.3 Save As

- Save As operates on the active pane.
- Cmd+Shift+S must open Save As for the active pane.
- Save As must not allow saving to the same canonical file already open in the other pane.
- If the destination file exists, confirm overwrite.
- After Save As:
  - update pane URL/title;
  - clear dirty state;
  - refresh file permissions/read-only state;
  - refresh comparison.

5.4 Read-only files

If a file cannot be written to its current location:

- show a read-only/locked indicator;
- allow in-memory editing if feasible;
- Save should automatically become Save As or prompt the user to choose a writable location;
- do not silently fail to save.

5.5 External file changes

If an opened file changes on disk while open:

- if the document is not dirty, prompt to reload or keep current contents;
- if the document is dirty, warn about conflict and offer:
  - reload and discard local changes;
  - keep local changes;
  - save as.

=====================================================================
6. HEX VIEW AND VISUAL REPRESENTATION
=====================================================================

Each file pane displays the file as an industry-standard hex dump.

Per row:

- 16 bytes per row;
- grouped as 8 bytes + space + 8 bytes;
- offset column on the left;
- hex byte values in two uppercase hexadecimal digits;
- ASCII representation on the right.

Display rules:

- offsets are zero-based;
- offset column should be hexadecimal by default;
- printable ASCII bytes 0x20–0x7E are shown as characters;
- non-printable bytes are shown as “.”;
- use a monospaced font;
- support Dark Mode;
- ensure sufficient contrast and accessibility.

EOF display:

- when comparison mode is active and one file is shorter, the shorter file must show missing cells as empty/placeholder EOF cells;
- EOF-only bytes in the longer file are highlighted as differences.

Visual states:

1. Difference state:
   - bytes that differ between the two files at the same absolute offset are highlighted with a background color.

2. Unsaved modification state:
   - bytes modified relative to last saved state are shown with red foreground/text color.
   - optionally add a subtle underline or marker, but red foreground must be the primary indicator.

3. Difference + unsaved modification:
   - if a byte is both different and unsaved-modified, display both states unambiguously:
     - background color for difference;
     - red foreground for unsaved modification.

4. Selected state:
   - selection must remain visible and must not completely hide difference/modification indication.
   - use standard selection treatment adjusted for hex view.

5. Missing EOF in shorter file:
   - display empty cells with a distinct muted background or separator style.

=====================================================================
7. EDITING MODEL
=====================================================================

Editing must be supported in both panes.

The hex dump contains two interactive regions per pane:

1. Hex area:
   - edit individual bytes via hexadecimal nibble input.
   - typing a hex digit edits the current nibble.
   - after second nibble, cursor advances to next byte.

2. ASCII area:
   - edit bytes via ASCII character input.
   - printable ASCII characters map directly to bytes.
   - non-ASCII input should be rejected or ignored with unobtrusive feedback.

7.1 Overwrite-first policy

The default editing model is overwrite.

- Typing overwrites existing bytes.
- Paste Write overwrites existing bytes.
- No existing offsets are shifted by overwrite operations.
- If typing or paste write occurs at EOF and extends the file, this is allowed without structural confirmation because existing offsets are not shifted.
- Any length change must still update file size, comparison, undo, and dirty state.

7.2 Length-changing operations

Operations that insert or delete bytes and therefore shift existing offsets are potentially destructive for structured binary dumps.

Such operations must be explicit and confirmed.

Confirmed length-changing operations include:

- Paste Insert;
- Delete Bytes / Remove Bytes;
- any explicit “Insert Bytes” operation if implemented.

Confirmation dialog must explain:

- operation type;
- target offset;
- number of bytes inserted/deleted;
- that subsequent offsets will shift;
- that the file structure may be affected.

7.3 Delete/Backspace default behavior

To avoid accidental structural damage:

- Delete/Backspace must not change file length by default.
- They should fill the selected bytes with 0x00.
- If no selection:
  - Delete fills current byte with 0x00;
  - Backspace fills previous byte with 0x00 and moves cursor back.

A separate explicit menu command, e.g. Edit > Delete Bytes, performs true length-changing deletion and requires confirmation.

7.4 Selection editing

- If a selection exists and the user types, the selected range is overwritten with typed bytes.
- If paste write is invoked with a selection, paste starts at selection start and overwrites bytes; it does not shift existing bytes.
- Selection can span multiple rows.
- Cmd+A selects all bytes in the active file.

7.5 Undo/Redo

- Each file has an independent undo/redo stack.
- Undo/Redo must support:
  - byte overwrite;
  - fill zero;
  - paste write;
  - paste insert;
  - delete bytes;
  - any other mutating operation.
- Undo/Redo should group logically, e.g. one typing sequence, one paste, one delete command.
- Undo must restore:
  - byte contents;
  - file length;
  - dirty state where applicable;
  - the selection, not merely the caret: the state the edit started from, whole.
    Typing into a selection consumes it byte by byte (§7.4), so an undo that
    dropped the selection would land on a state the editing never passed
    through, and the next keystroke would then overwrite a single byte instead
    of resuming the sequence.
- Redo must reapply the operation and restore the selection the command left —
  the remainder still to be typed over, or the collapsed caret a fill leaves.
  The document cannot derive this from the byte range alone, so the command
  that made the edit states it after placing the selection.
- Undo history may be bounded by memory/disk resources, but must be sufficient for practical editing sessions.

=====================================================================
8. COMPARISON MODEL
=====================================================================

Comparison is enabled only when two files are open.

Comparison rules:

1. Compare by absolute zero-based 64-bit offsets only.
2. Do not attempt to find matching blocks at different offsets.
3. Do not perform structural diffing.
4. Always compare current unsaved contents, including pending edits.
5. If either file is edited, comparison must update.
6. Visible region comparison updates must be immediate or near-immediate.
7. Full-file comparison can be computed asynchronously.

8.1 Difference semantics

For each offset:

- if both files have a byte and bytes are equal: Equal.
- if both files have a byte and bytes differ: Different.
- if only the longer file has a byte and the shorter file is past EOF: MissingInShorter / EOF-only difference.

Block definitions:

- A different block is a maximal contiguous range of offsets where the two files differ at the same absolute offset.
- A same block is a maximal contiguous range of offsets where the two files are identical.
- EOF-only bytes in the longer file are considered part of a different block.

8.2 Highlighting

- Different bytes must be highlighted in both panes where a byte exists.
- In the shorter pane, EOF-only missing regions should be shown as empty/placeholder cells.
- EOF-only bytes in the longer pane must be highlighted as differences.
- Navigation to next/previous difference must include EOF-only different blocks.

8.3 Comparison lifecycle

When two files are open:

- start comparison automatically;
- compute visible-region differences synchronously or with very low latency;
- compute a full-file block index in the background;
- show progress if full comparison is long;
- allow cancellation if a pane is closed or files change significantly.

When edits occur:

- invalidate affected comparison ranges;
- update visible rows immediately;
- update background diff index incrementally where possible;
- insert/delete operations that shift offsets must invalidate from the earliest affected offset onward.

When one file is closed:

- clear comparison state;
- return to single-file mode.

=====================================================================
9. SYNCHRONIZATION BETWEEN PANES
=====================================================================

In comparison mode, panes must be synchronized by absolute offset whenever possible.

Synchronized state includes:

1. Scroll position.
2. Cursor/caret offset.
3. Selection range.

Behavior:

- scrolling in the active pane scrolls the other pane to the same absolute offset;
- moving the cursor in the active pane moves the other pane cursor to the same offset if that offset exists;
- selecting a range in the active pane selects the same absolute range in the other pane where possible;
- both panes scroll over the same extent — the longer file — so a synchronized offset past the shorter file’s EOF is reachable in both panes and the two never drift apart at the tail;
- where a row is only partly past the shorter file’s EOF, its missing cells carry the EOF cue (§15); rows entirely past the end are drawn empty — no bytes, no offsets, no cue — since repeating the cue for the whole tail would be noise rather than information;
- synchronization must not cause crashes for empty files or EOF positions.

In single-file mode, synchronization is not applicable.

Optional future enhancement: independent scroll mode. For MVP, synchronized behavior is required.

=====================================================================
10. NAVIGATION
=====================================================================

10.1 Go To Position

- Cmd+G opens a Go To Position dialog.
- The dialog accepts a single absolute offset.
- Offset input must support:
  - hexadecimal with `0x` or `0X` prefix;
  - decimal without prefix.
- The offset input field should be pre-filled with `0x` by default.
- Offsets are zero-based.
- Input parsing must be case-insensitive for hex.
- Invalid input must show inline validation or alert.

Go To behavior:

- In single-file mode, move the active pane cursor to the requested offset if valid.
- In comparison mode, move both panes to the same absolute offset.
- If the offset is beyond the active file length but within the other file length:
  - the shorter file shows EOF/blank region;
  - the longer file shows the byte at that offset.
- If the offset is beyond both files:
  - clamp to the end of the longer file;
  - show a warning or status message.

10.2 Select Block

Provide a Select Block dialog with two modes:

1. Start and End offsets.
2. Start and Length.

Rules:

- all offsets/lengths support hexadecimal with `0x` prefix and decimal without prefix;
- fields should be pre-filled with `0x` where appropriate;
- validate:
  - numeric format;
  - non-negative values;
  - start/end relationship;
  - length validity.
- For start/end mode:
  - if start > end, show error or optionally swap after confirmation; default: error.
- Selection must be applied to the active pane and synchronized to the other pane where possible.
- The status bar must show selection length and selected range.

10.3 Next/Previous block navigation

The app must support:

- Next different block.
- Previous different block.
- Next same block.
- Previous same block.

Requirements:

- Navigation includes EOF-only difference blocks.
- Navigation should move the cursor to the start of the target block.
- Both panes should synchronize to the resulting offset.
- If no further block exists in the requested direction:
  - show a status message or unobtrusive feedback;
  - do not silently wrap by default.
- If the full-file diff index is still being computed:
  - navigation may perform on-demand scanning;
  - show progress for long scans;
  - keep UI responsive.

Suggested shortcuts:

- Next difference: Cmd+Option+Right Arrow.
- Previous difference: Cmd+Option+Left Arrow.
- Next same block: Cmd+Option+Shift+Right Arrow.
- Previous same block: Cmd+Option+Shift+Left Arrow.

Shortcuts may be adjusted, but must be discoverable in menus.

=====================================================================
11. SEARCH
=====================================================================

Search operates on the active pane.

Requirements:

- Search must use current unsaved contents, including edits.
- Search must run in the background for large files.
- Search must not block the UI thread.
- Search must be cancellable.
- Search progress/status should be visible.

Search modes:

1. Hex bytes:
   - input as hexadecimal byte sequence;
   - allow optional spaces between bytes;
   - case-insensitive;
   - examples:
     - `DEADBEEF`
     - `DE AD BE EF`
     - `0xDE 0xAD` optional support.

2. Text:
   - ASCII;
   - UTF-8;
   - UTF-16 LE;
   - UTF-16 BE.

Text search semantics:

- The text string is encoded into bytes using the selected encoding.
- UTF-16 must explicitly support LE and BE.
- Do not add BOM automatically unless the user explicitly includes it.
- Search is binary-exact over encoded bytes.

Case-insensitive matching:

- Offered for ASCII and UTF-8 only, and withheld (the control disabled, the
  search forced exact) for hex and for UTF-16.
- The scan folds ASCII letter bytes, which models case exactly for a
  single-byte ASCII-compatible encoding and nothing else: for hex it would
  make the pattern 41 match the byte 61, and for UTF-16 it would fold the
  high byte of a code unit, so a search for U+6100 (61 00) would also match
  U+4100 (41 00).
- A remembered "case insensitive" state must never leak into an encoding that
  cannot support it.

Search navigation:

- Find Next.
- Find Previous.
- When a match is found:
  - move cursor to match start;
  - select the matched byte range;
  - synchronize the other pane in comparison mode;
  - ensure match is visible.
- If no match is found, show a status message. The scan is directional and
  does not wrap, so the message must say which way it looked — otherwise a
  caret past the last match is indistinguishable from a file with no match at
  all.

Search All (results panel):

- Every occurrence is listed in a panel belonging to the pane that was
  searched, filling as the scan streams matches in rather than at the end.
- The panel caps how many results it lists. The header must distinguish a
  search that filled the cap exactly (a complete result) from one that had
  more matches than the cap (reported as too many results).
- The panel has its own close control, which stops the scan behind it.
  Dismissing the Find bar must not close the panel or cancel its scan; a
  change of window mode must, since the pane it belongs to is rebuilt.
- Starting another Search All supersedes the previous one: the older scan must
  not touch the newer one's panel, nor disable its close control.
- Excerpts and offsets are read from the pane's live content, so they follow
  edits made while the panel is open.
- Column widths default to the width of the values they hold, not to fixed
  constants. The value font is monospaced and every value has a known length
  (a zero-padded offset; an excerpt of a fixed byte count), so the widths are
  computed from template strings rather than measured per row. A total wider
  than the panel scrolls horizontally.

Optional but recommended:

- highlight matches in visible region;
- show match count if it can be computed efficiently.

=====================================================================
12. CLIPBOARD, COPY, PASTE
=====================================================================

12.1 Copy

- Cmd+C copies the selected byte range from the active pane.
- Copy must place raw bytes on the pasteboard as the primary representation.
- Copy may also place a hex text representation for debugging or interop.

If no selection exists:
- Copy is disabled or no-op.

12.2 Paste Write

- Cmd+V performs Paste Write.
- Paste Write inserts no structural offset shift.
- It overwrites bytes starting at the cursor position.
- If cursor + clipboard length exceeds current EOF, the file is extended.
- Extending at EOF does not require structural confirmation.
- Paste Write must support undo/redo.
- Paste Write must update dirty state and comparison.

12.3 Paste Insert

- Paste Insert is available from Edit menu, not as default Cmd+V.
- Paste Insert inserts clipboard bytes before the cursor position.
- Paste Insert increases file length and shifts subsequent offsets.
- Paste Insert must require explicit confirmation.
- After confirmation, perform insert and update:
  - comparison;
  - selection;
  - cursor;
  - undo stack;
  - dirty state.

12.4 Clipboard parsing

Preferred paste source:

- raw bytes.

If only text is available:

- attempt to parse as hexadecimal byte pairs if the text clearly matches a hex byte pattern;
- otherwise reject with a clear error or offer explicit paste-as-text only if unambiguous.
- Avoid ambiguous implicit conversions.

=====================================================================
13. LARGE FILE SUPPORT
=====================================================================

The app must support very large files that do not fit completely in memory.

Requirements:

1. Do not load entire files into memory.
2. Use chunked/block-based storage.
3. Use a cache with bounded memory usage.
4. Use lazy loading for visible regions and on-demand access.
5. Use file-backed temporary storage for edits when necessary.
6. Undo history may use memory plus temporary disk storage.
7. Diff and search must process files incrementally.
8. UI must remain responsive while processing large files.
9. Redrawing must be partial: a change repaints the rows and columns it
   affects, not the whole pane.

Recommended architecture:

- Original file storage can be memory-mapped or read through chunk cache.
- Edits are stored as an edit overlay or sparse change log.
- Insert/delete may require copy-on-write or temporary file materialization.
- Save can patch in-place for overwrite-only edits where safe.
- Save may rewrite file for length-changing edits or Save As.

Performance expectations:

- Scrolling should remain responsive.
- Visible row rendering should be fast.
- Visible diff highlighting after edits should be near-instant.
- Full-file diff/search may run in background with progress.
- A change must mark every row it affects for repaint, including rows that are
  currently off screen. A row that has already been drawn keeps its pixels
  until it is marked dirty, so clamping the invalidation to the visible area
  leaves a stale row on screen the moment it is scrolled back to. Marking
  off-screen rows costs nothing now: the display draws only the visible part
  and defers the rest until it is scrolled into view.
- Where a change spans very many rows, one whole-view invalidation is preferred
  to a rect per row; the display still draws only the visible part of it.

=====================================================================
14. INTERNAL ARCHITECTURE
=====================================================================

The architecture must cleanly separate:

1. Data storage layer.
2. Data/model layer.
3. Presentation/UI layer.

The layers must be modular, reusable, and testable.

14.1 Storage layer

Responsibilities:

- reading bytes from file;
- chunk cache;
- edit overlay;
- temporary file management;
- saving changes;
- handling large files efficiently.

Suggested protocols:

- `ByteStorage`
- `EditableByteStorage`
- `FileBackedStorage`
- `EditOverlayStorage`

The storage layer must not depend on AppKit.

14.2 Model layer

Responsibilities:

- binary document state;
- dirty state;
- undo/redo;
- selection model;
- offset parsing/validation;
- diff/comparison engine;
- search engine;
- clipboard data parsing/serialization;
- block model: same/different/EOF blocks.

The model layer should be pure Swift where practical and must not depend on AppKit.

14.3 Presentation layer

Responsibilities:

- AppKit windows, panes, views;
- hex rendering;
- cursor/selection drawing;
- drag-and-drop;
- menus/toolbars/status bar;
- dialogs and alerts;
- view models/presenters coordinating UI state.

Presentation must not contain core binary processing logic.

14.4 Concurrency

- Long-running operations must run off the main thread.
- Use Swift concurrency, background tasks, or actors as appropriate.
- UI state must be updated on MainActor/main thread.
- Cancellable operations should support cancellation.
- Diff/search tasks should be cancelable when files close or inputs change.

=====================================================================
15. USER INTERFACE DETAILS
=====================================================================

Menus and commands should include at least:

File:
- Open…
- Close Pane or Close File
- Save
- Save As…
- Revert (recommended)

Edit:
- Undo
- Redo
- Copy
- Paste Write
- Paste Insert
- Fill Selection with Zero (recommended)
- Delete Bytes…
- Select Block…
- Find…
- Go To Position…

View/Navigate:
- Toggle Pane Layout Left/Right vs Top/Bottom
- Show/Hide Minimap
- Next Difference
- Previous Difference
- Next Same Block
- Previous Same Block

Status bar or equivalent info area should show:

- active file name/path;
- file size;
- cursor offset in hex and decimal;
- selection length;
- dirty state;
- read-only state;
- comparison status;
- background task progress for diff/search when applicable.

Accessibility:

- keyboard navigation must work;
- major controls must have accessible labels;
- colors must have sufficient contrast;
- Dark Mode must be supported;
- do not rely on color alone where possible; consider text/style cues for EOF and unsaved changes.

=====================================================================
16. ERROR HANDLING
=====================================================================

Show clear, non-destructive errors for:

- unable to open file;
- file is directory/package;
- permission denied;
- sandbox access denied;
- same file already open in other pane;
- invalid hex/decimal input;
- invalid selection range;
- paste data unsupported/invalid;
- save failure;
- external modification conflict.

Rules:

- Never lose user changes silently.
- Prefer recoverable prompts over fatal alerts.
- Destructive operations require confirmation.

=====================================================================
17. TESTING REQUIREMENTS
=====================================================================

Unit tests are required for data processing logic in the model/storage layers.

Minimum test coverage should include:

1. Offset parsing:
   - hex with `0x`;
   - decimal;
   - invalid input;
   - large 64-bit values.

2. Selection logic:
   - start/end;
   - start/length;
   - out-of-range handling;
   - empty selection.

3. Edit overlay/storage:
   - overwrite;
   - append at EOF;
   - insert;
   - delete;
   - read-back correctness;
   - undo/redo interactions.

4. Diff engine:
   - identical files;
   - completely different files;
   - single-byte difference;
   - multiple difference blocks;
   - one empty file;
   - shorter/longer files;
   - EOF-only differences;
   - edit invalidation;
   - insert/delete offset shift invalidation.

5. Search:
   - hex sequence parsing;
   - ASCII encoding;
   - UTF-8 encoding;
   - UTF-16 LE/BE encoding;
   - match at start/middle/end;
   - no match;
   - current unsaved contents.

6. Clipboard:
   - raw bytes roundtrip;
   - hex text parsing where supported;
   - invalid clipboard content.

7. Dirty state:
   - edit sets dirty;
   - save clears dirty;
   - undo to saved state clears dirty;
   - redo sets dirty again.

UI tests are optional but valuable for:
- file open flows;
- drag-and-drop flows;
- save prompts;
- navigation commands.

=====================================================================
18. ACCEPTANCE CRITERIA
=====================================================================

The implementation is acceptable if:

1. The app opens one or two files using menu and drag-and-drop.
2. Single-file mode supports editing without comparison.
3. Comparison mode highlights byte differences by absolute offset.
4. EOF-only bytes are treated as differences and navigable.
5. Editing updates comparison immediately in visible region.
6. Insert/delete operations require confirmation and update comparison correctly.
7. Undo/redo works independently per file.
8. Save and Save As work per active pane and respect dirty state.
9. Large files can be opened without loading entire contents into RAM.
10. Search and full-file diff do not block the UI.
11. Unit tests cover core model/storage logic and pass.
12. The app follows a clean layered architecture.
13. The UI is usable, keyboard-accessible, and supports Dark Mode.
14. No operation silently destroys user data.
15. The minimap draws every byte at a fixed scale, follows the panes, and can
    be dragged and clicked to navigate, without reading the whole file.

=====================================================================
19. MINIMAP PANEL
=====================================================================

19.1 Purpose and placement

An optional minimap panel gives a zoomed-out view of the open file(s) and a
way to navigate them by pointing.

- The panel sits at the right edge of the content area, sharing it with the
  hex panes through a draggable divider.
- It is hidden by default. Toggling it is available from the toolbar (an
  item at the far right) and from the View menu, whose item names the
  action it will perform ("Show Minimap" / "Hide Minimap").
- The toolbar toggle is a plain icon button, sized to its icon and set apart
  from the difference navigation by a system space item — not by an empty
  custom view, which the toolbar would draw inside the toggle's own
  background, stretching it into an oblong capsule with the icon off-centre.
- A second View item switches the render mode (§19.4). It is a checked item,
  not a flipping title: both modes are a minimap, so the check reads as which
  one is in use. It mirrors the header's switch, which is the primary control:
  the mode is a choice a reader makes constantly, so it must be one click
  away, not buried in a menu.
- The panel is never removed from the view hierarchy; hidden means its
  width is zero.
- The panel is built like a pane (§3.4): a header, the map, and a status bar.
  Their heights are derived from where the dump beside them actually is, so
  the map's top and bottom edges land on the dump's — a bare map started
  above the first byte row and ended below the last, and the two never read
  as the same file. Whatever moves the bytes (a taller row §6, an open Find
  bar §11) moves the map's edges with them.
  - The header carries the mode switch (§19.4): Local ⇄ Overview, in the
    band the panes put their file names in. It is a standard segmented
    control: native appearance and behaviour are the point (§1).
  - The map draws inside its own area and nowhere else. It is handed a
    repaint region belonging to the whole panel, and drawing to it
    unclipped paints over the chrome — which is exactly what hid the mode
    switch until the map was clipped to its bounds.
  - The status bar carries the progress of a full overview rebuild (§19.9)
    and is otherwise empty.
  - The map keeps a minimum height: a Search All panel (§11) can take most
    of a pane's height, and the chrome must not consume the map to match it.

19.2 Panel width

- The panel keeps a minimum width of 120 pt and never exceeds 240 pt, so it
  stays a compact column beside the dumps.
- The width the user drags is persisted and restored on the next show.
- A window resize must not change the panel's width: the hex panes absorb
  the whole delta, and the clamp above holds at any window size.
- Zoom-to-fit must make room for a visible panel on top of the hex grids.

19.3 Maps

The panel is divided into maps that mirror the pane arrangement:

- single-file mode: one map over the whole panel;
- comparison, side-by-side panes: two maps, split by a vertical line at the
  panel's centre, separated by a gutter proportional to the panel's width;
- comparison, stacked panes: two maps, split by a horizontal line that
  mirrors the panes' divider and moves with it.

19.4 Rendering: two modes

A map draws its file one of two ways, switched from the View menu and
remembered. Which one a file opens in is decided by whether detail mode could
say anything useful about it: a file whose rows all fit the panel opens in
detail, a dump that would only ever show a sliver of itself opens in overview.
An explicit choice by the user overrides that from then on.

19.4.1 Detail mode

A miniature hex dump — the hex column only, no offset column and no decoded
text.

- The scale is fixed: a byte cell is 2 pt tall with 1 pt between rows, so
  one hex row costs 3 pt regardless of the file's size.
- Every byte is drawn as its own cell. Bytes must not be grouped or
  aggregated: one row of the map is exactly one hex row of the dump, and a
  partial final row draws only the bytes it has.
- Byte columns keep the hex dump's proportions, including the word grouping
  and the gap between the two 8-byte groups, scaled to the map's width.
- A cell is coloured the way the hex panes colour that byte, layered the
  same way: a byte that differs from the companion gets a difference
  background, and the byte itself is drawn on top — modified (unsaved) in
  the modified colour, significant bytes in ink, a 0x00/0xFF fill muted.
  The difference background must remain visible behind an opaque byte.
- The selection is drawn as a translucent overlay on top of the cells.
- Byte state must come from the same per-byte source the panes paint from,
  so the map cannot disagree with the dump beside it.

19.4.2 Overview mode

The whole file at once: one row per device pixel, so the panel's full vertical
resolution is used and nothing is spent on gaps.

- A row covers a slice of the file; its 16 cells cover equal sub-slices. The
  columns are decorative here — a cell is a range of bytes, not a byte column —
  and are drawn contiguously, snapped to the pixel grid. The hex dump's word and
  group gaps must not be reproduced: at one pixel per row they turn the map into
  a barcode.
- A cell is shaded by *how much* of its slice is real content, not by whether
  any of it is. A boolean "contains a significant byte" test saturates on a
  large dump and hides the layout; shading separates erased 0xFF padding from
  code and from mixed regions at a glance.
- The shading stays inside the tonal range the dump itself occupies. A slice of
  pure 0x00/0xFF fill inside the file is drawn muted rather than left blank —
  the dump draws such a byte muted too — and a full slice stops well short of
  solid ink, because a dense row of the dump is glyphs on paper and reads as a
  mid grey. Mapping content to black and padding to bare paper made the map a
  set of black islands on white, nothing like the file beside it. Rows past the
  file's own end are the only ones left blank.
- Cell boundaries are snapped to the device pixel grid in the panel's own
  coordinates, and each cell reaches the next boundary rather than sharing one
  width. Otherwise a solid region shows hairline vertical stripes: a shared
  width leaves gaps where snapped boundaries fall further apart, and snapping
  within a map's content puts every boundary of the second map mid-pixel,
  because its content begins after a gutter that is a fraction of the panel.
- Difference and modification are drawn over the shading, and at least two
  pixels tall so a single byte among thousands stays visible. Where a cell is
  both, modified wins: at hundreds of bytes per cell the two overlap often, and
  the difference is still legible across the rest of the region.
- Rows are binned over the comparison's extent, so the same height is the same
  absolute offset on both maps (§9); rows past a shorter file's end stay empty.
  Empty means empty: the difference index is built over the extent, so every
  byte past the shorter file's end counts as a difference in it, and a map must
  not paint those on the file that ended — its tail carries no shading, no
  difference and no modification. The longer file's map does mark that region,
  because it holds bytes the other file does not (§9).
- The picture must be computed off the main thread and cached: every row is on
  screen at once, so it cannot be read per repaint. It must be recomputed when
  the bins change (a resize), when the bytes change, and when the comparison
  index changes — difference marks come from that index rather than from
  re-reading both files.

19.5 The window onto the file (detail mode)

Because the detail scale is fixed, a file taller than the panel does not fit:
the map shows a window onto it, not the whole file. Overview mode has no
window — it shows everything.

- The window's position is derived from the panes; the minimap has no
  scroll position of its own and no scroll bar.
- The window's position within the file must match the panes' own position
  within the file: at the file's start the window starts at its first row,
  at the file's end the window's last row is the file's last row.
- Both maps share one window, since the panes are synchronized by absolute
  offset (§9): the same offset must sit at the same height on both maps.
  A map whose file ends earlier simply draws fewer rows, so its tail is empty
  — the same thing its pane shows there (§9).
- Only the visible rows may be read. Building state for the whole file is
  not permitted — a file of any supported size must cost the same as a
  small one (§13).

19.6 Viewport band

The panes' visible slice is drawn as a translucent band over the map.

- The band spans the visible rows at the map's own scale.
- In side-by-side comparison the band is a single rectangle across the
  whole panel, covering both maps and the gutter between them; the divider
  between the maps must not interrupt it.
- In stacked comparison each map keeps its own band.
- The band is drawn under the selection overlay, so a selection inside it
  stays readable.
- In overview a visible page is a fraction of a pixel, so nothing is drawn
  across the content at all: the position is marked by a chevron in each outer
  margin, level with the middle of the visible slice, pointing inward. A band or
  line spanning the panel would cost a whole row of the picture, and on a dump
  every row carries information. The marker states a position and must not
  pretend to show an extent.

19.7 Navigation

- Dragging the band scrolls the panes and keeps the band under the cursor.
  Because the window slides with the panes, the band travels the map's full
  height over the course of the whole file, so the map acts as a
  proportional scroll bar for it.
- Clicking the map away from the band moves the caret to the byte drawn at
  that point — row from the vertical position, column from the horizontal
  one — and centres the pane on it. In comparison mode the click also makes
  the clicked map's pane active. In overview the same rule lands the caret
  proportionally into the file, the column narrowing the target within the
  row's slice.
- Clicking the band itself begins a drag and must leave the caret alone.
- A scroll wheel over the panel scrolls the panes.
- Navigation by pointer must clamp at the file's start and end.

19.9 Repainting

- The maps are static between changes to the bytes: a scroll moves only the
  viewport overlay, and a selection change only the selection overlay. Each
  change must therefore repaint the area its overlay covers — the area it
  vacated and the area it moved to — and not the panel.
  - In detail mode the exception is a scroll that slides the window
    (§19.5): the whole picture moves, so the whole panel repaints.
  - In overview mode a scroll never slides the window, so a scroll repaints
    the two chevron boxes (§19.6) and nothing else. A full repaint there is
    ~19 000 cells and takes tens of milliseconds, which is felt as lag on
    every wheel tick.
- An edit repaints the rows it changed. The overview's picture is compared
  row by row against the one on screen, and only the differing rows are
  repainted; an event cell is two pixels tall, so the row below a changed
  row is repainted with it.
- A repaint must start from the panel's background, since it can no longer
  rely on the whole panel being redrawn.
- Rebuilding the overview's picture walks the whole file and must not run on
  the main thread, must be debounced, and must be cancelled when superseded.
  The two files of a comparison are independent passes and are computed
  concurrently.
- A rebuild reports progress to the panel's status bar (§19.1). The bar
  appears only if the pass outlives a short delay — a small dump is binned in
  milliseconds, and a bar shown for one frame reads as a glitch — and it is
  then held for a minimum showing before it clears, because the pass itself is
  fast: two 16 MB dumps are binned in ~150 ms, so a bar that vanished the
  instant the pass ended was never seen at all.
- Any change to the panel's frame is drawn by stretching the picture in hand,
  not by redrawing the maps: a height change re-bins the file and needs the
  background pass, and a width change redraws every cell at a new width. Both
  arrive as a stream during a drag, so the exact picture is drawn once the
  frame stops moving. The stretch keeps the file's orientation, marks its
  events visibly, and never leaves the map short of its area or spilling past
  it.
- The stretched picture must be the same picture, colour for colour. It is
  therefore rendered by the *same* routine that draws the map on screen, at one
  pixel per row, and composited in the window's own colour space. Both
  shortcuts were visible to the eye: composing the colours by hand drew a solid
  difference column — what a long file compared against a much shorter one
  looks like — at roughly 0.35 alpha instead of the 0.58 the exact pass reaches
  by drawing events two pixels tall, and compositing in a generic colour space
  left the same column more saturated than the exact one.

19.8 Accessibility

- The panel must expose itself as a single accessible element with a label
  and a value describing which part of the file the panes are showing, in
  the same terms the hex dump uses (hex offsets, size in bytes). Individual
  byte cells must not be exposed: at this scale a single cell carries no
  information a reader can use.
- The pointer gestures the panel offers are not discoverable by a reader, so
  it must also carry help text describing them.
- The panel need not be a keyboard focus stop: every navigation it offers
  must already be reachable from the keyboard in the panes (§10) and its
  toggle from the View menu (§15).
