PROMPT FOR LLM

You are a senior macOS/Swift engineer. Design and implement a production-quality macOS GUI application for visually comparing and editing two binary files.

If any requirement is ambiguous, use the explicit defaults in this document. If a requirement is impossible or contradictory, state the conflict and propose the closest safe alternative. Prefer correctness, data safety, testability, responsiveness, and macOS HIG compliance.

====================================================================
1. DELIVERABLES AND TECHNOLOGY CONSTRAINTS
====================================================================

1.1. Deliver an Xcode project written in Swift.
1.2. Target macOS 14 or later. Use Swift 5.10+ language mode if practical.
1.3. Include:
    - macOS app target;
    - unit test target for model/data-processing logic.
1.4. Do not use third-party dependencies unless absolutely unavoidable. If unavoidable, justify and isolate them.
1.5. SwiftUI may be used for app chrome, menus, dialogs, settings, and toolbars. The hex editor view should be implemented with a high-performance rendering approach; AppKit/CoreText/custom drawing is acceptable and encouraged where needed.
1.6. Use Swift Concurrency:
    - UI state on MainActor;
    - file IO, search, diff scanning, save, and clipboard-heavy operations in background tasks/actors;
    - long-running operations must be cancellable.
1.7. Code should be modular, testable, and cleanly separated into layers.

====================================================================
2. APPLICATION MODEL AND WINDOW LIFECYCLE
====================================================================

2.1. The app is centered around a single comparison window per app instance. Multiple comparison windows are out of scope for v1.

2.2. The comparison window has two file slots:
    - File A;
    - File B.

2.3. File B is optional.

2.4. If only one file slot is occupied, the app is in single-file mode:
    - the remaining file pane takes the whole window;
    - hex editing functions are available;
    - comparison functions are disabled;
    - it must not matter whether the remaining file is File A or File B.

2.5. If both File A and File B are open, comparison mode is enabled in addition to hex editing in both panes.

2.6. Each opened file has an independent dirty state.

2.7. Dirty state must be shown in the pane title:
    - file name plus "*" when dirty;
    - example: `file.bin *`;
    - if the file has no path yet, use `Untitled` or similar;
    - if the file is read-only or not writable, show a lock/read-only indicator.

2.8. Closing a pane:
    - if the pane has unsaved changes, prompt the user to Save, Don’t Save, or Cancel;
    - if Cancel is chosen, the pane remains open;
    - closing either File A or File B leaves the app in single-file mode with the remaining file.

2.9. Closing the window or quitting the app:
    - if any open file has unsaved changes, prompt for each modified file;
    - the user must be able to Save, Don’t Save, or Cancel;
    - a sheet listing modified files is acceptable if equivalent choices are provided;
    - if the user cancels, the close/quit operation is aborted;
    - optionally provide Save All.

====================================================================
3. FILE OPENING AND DRAG & DROP
====================================================================

3.1. Files can be opened from the File menu and by drag & drop.

3.2. Menu commands:
    - File > Open Pane A…;
    - File > Open Pane B…;
    - File > Open… opens into the currently selected/active pane; if no pane is selected, use File A.

3.3. Opening/replacing a dirty file:
    - if the target pane contains unsaved changes, prompt the user to Save, Don’t Save, or Cancel;
    - if Cancel is chosen, abort the open/replace operation.

3.4. Drag & drop must accept file URLs only.

3.5. Reject unsupported drops gracefully:
    - directories;
    - unreadable files;
    - non-file URLs.
    Show a user-facing alert for rejected items.

3.6. Dragging over the comparison window should show visual drop targets.

3.7. Single-file mode drag & drop:
    - when dragging a file into a window with one open file, temporarily split the window into two visible drop zones:
        a. Replace File A;
        b. Open as File B.
    - dropping one file into a zone performs the corresponding action;
    - if the dragged set contains two files and the drop is not targeted at a specific pane, assign first file to File A and second file to File B, with dirty prompts if needed.

3.8. Two-file mode drag & drop:
    - dropping onto a specific pane replaces that pane;
    - if the drop location is ambiguous, optionally show drop targets for Replace File A and Replace File B.

3.9. Multiple-file drop rules:
    - if the drop context targets a specific pane and multiple files are dragged, use only the first file for that pane and notify that additional files were ignored;
    - if the drop context supports filling two slots and more than two files are dragged, use only the first two files and notify the user that only the first two files were opened;
    - the order of dragged files should be preserved where the platform provides it.

3.10. If replacing any dirty file, always prompt before replacement.

====================================================================
4. LAYOUT AND PANES
====================================================================

4.1. The two file panes can be arranged either:
    - left/right;
    - top/bottom.

4.2. The arrangement is user-configurable and persisted.

4.3. Provide View menu and/or toolbar controls to switch layout.

4.4. If only one file is open, its pane takes the whole window.

4.5. If two files are open, the split divider should be resizable.

4.6. Each pane should have a clear title and close control.

4.7. The app should remember layout preference between launches.

====================================================================
5. HEX VIEW RENDERING
====================================================================

5.1. Display each file as a hex dump with:
    - 16 bytes per row;
    - offset/address column;
    - hex byte cells;
    - ASCII representation on the right.

5.2. Offsets:
    - absolute zero-based offsets;
    - displayed in hexadecimal;
    - use 64-bit offset representation in the UI where practical;
    - example: 16 hex digits for 64-bit offsets.

5.3. ASCII column:
    - printable ASCII bytes 0x20...0x7E are shown as characters;
    - non-printable bytes are shown as "." or a similar placeholder.

5.4. The ASCII pane is read-only in v1 unless the implementation can support full text-encoding-safe ASCII editing without breaking binary correctness.

5.5. Rendering must be virtualized:
    - render only visible rows plus a small prefetch margin;
    - do not create UI rows for the whole file.

5.6. Visual states to support:
    - normal bytes;
    - selected bytes;
    - caret/active editing cell;
    - difference bytes;
    - EOF/missing region;
    - modified unsaved bytes;
    - bytes that are both different and modified unsaved.

5.7. Colors and indicators:
    - support light and dark mode;
    - ensure sufficient contrast;
    - do not rely on color alone; use gutter markers, borders, or text indicators where useful;
    - difference state uses background color;
    - modified unsaved state uses red foreground color;
    - if a byte is both different and modified unsaved, show difference background plus red foreground;
    - selection must remain legible over all states.

5.8. EOF region in the shorter file:
    - show empty cells;
    - visually distinguish EOF/missing area;
    - do not render fake bytes.

====================================================================
6. CARET AND SELECTION
====================================================================

6.1. Each pane has an active caret offset.

6.2. Selection model for v1:
    - single contiguous byte range per pane;
    - architecture should not make future multi-selection impossible, but v1 may implement single selection.

6.3. Selection can be created by:
    - mouse drag;
    - shift + click;
    - keyboard navigation;
    - Select Range dialog.

6.4. Show selection information in a status bar or equivalent UI:
    - start offset;
    - length;
    - current caret offset;
    - file size.

6.5. Internal ranges must use half-open representation:
    - [start, end)
    - length = end - start.

6.6. User-facing range dialogs may present either:
    - Start + Length;
    - Start + End, where End is inclusive in the UI.
    Convert inclusive end to internal half-open range.

====================================================================
7. HEX EDITING
====================================================================

7.1. Hex editing must be supported in both File A and File B when open.

7.2. Editing operates on the current logical in-memory contents of the file, not necessarily the entire file loaded into RAM.

7.3. Hex pane editing:
    - typing hexadecimal digits edits bytes;
    - support nibble-level editing;
    - first hex digit edits the high nibble of the current byte;
    - second hex digit edits the low nibble and advances the caret;
    - typing at EOF extends the file by creating new byte(s);
    - valid hex digits are 0-9, a-f, A-F.

7.4. Overwrite behavior:
    - keyboard hex input overwrites existing bytes by default;
    - at EOF, it appends.

7.5. Insert/delete behavior:
    - provide an explicit Insert Byte command that inserts 0x00 at the caret;
    - provide Delete commands;
    - if a selection is active, Delete removes the selected bytes and reduces file length;
    - if no selection is active:
        - Delete removes the byte at the caret, if present;
        - Backspace removes the byte before the caret, if caret > 0;
    - insert/delete operations update file length.

7.6. Paste operations are explicit:
    - Paste Write;
    - Paste Insert.

7.7. Paste Write:
    - default paste command, Cmd+V;
    - overwrites bytes starting at the caret position;
    - if caret is at EOF, it appends;
    - if clipboard content extends beyond EOF, the file length is extended;
    - if a write would begin beyond EOF for any reason, fill the gap with zero bytes.

7.8. Paste Insert:
    - available from Edit menu;
    - inserts bytes before the caret position;
    - shifts existing bytes forward;
    - extends file length;
    - if caret is at EOF, it appends.

7.9. Paste and selection behavior:
    - paste commands operate at the caret;
    - if there is a non-empty selection, collapse the selection to the caret/start position before pasting;
    - paste does not automatically delete the selection;
    - users can use Delete/Cut to remove selection first.

7.10. Cut:
    - optional but recommended: Cut = Copy selected bytes + Delete selected bytes.

7.11. Read-only / non-writable files:
    - if a file cannot be written on disk, still allow in-memory editing if feasible;
    - clearly indicate read-only/non-writable state;
    - Save should be disabled or fail gracefully with a clear alert;
    - Save As should remain available.

====================================================================
8. UNDO / REDO AND DIRTY STATE
====================================================================

8.1. Each file has an individual undo/redo history.

8.2. Undo/redo must cover at least:
    - overwrite edits;
    - insert edits;
    - delete edits;
    - paste write;
    - paste insert;
    - cut/delete selection.

8.3. Undo/redo should coalesce rapid consecutive typing where reasonable, but preserve predictable undo steps.

8.4. A new edit clears that file’s redo stack.

8.5. Undo/redo should restore content and dirty state correctly.

8.6. Selection/caret restoration after undo/redo should be best-effort.

8.7. Saving does not necessarily clear undo history.

8.8. Dirty state:
    - a file is dirty if its current logical content differs from its last saved or loaded on-disk snapshot;
    - if undo returns the file exactly to the saved snapshot, dirty state becomes false;
    - if undo/redo changes content away from the saved snapshot, dirty state becomes true.

8.9. Modified bytes:
    - a modified byte is any byte that differs from the file’s last saved/loaded snapshot;
    - maximal contiguous modified bytes form modified blocks;
    - modified unsaved bytes/blocks are highlighted with red foreground.

8.10. If a byte is both:
    - different due to comparison with the other file;
    - modified unsaved;
    then display both states unambiguously:
    - background color for difference state;
    - red foreground for unsaved modification.

====================================================================
9. SAVE BEHAVIOR
====================================================================

9.1. Save and Save As operate on the currently selected/active pane.

9.2. If no pane is selected, Save commands should target the active pane or be disabled if no file is open.

9.3. Save:
    - writes the current logical content to the current file path;
    - should be atomic where practical, e.g. write to temporary file then rename;
    - should preserve file permissions best-effort;
    - for large files, show progress and allow cancel if feasible;
    - must not silently lose data on failure.

9.4. Save As:
    - prompts for a new file path;
    - updates the pane’s file path and title;
    - clears dirty state after successful save.

9.5. If Save fails:
    - keep the file dirty;
    - show a user-facing error;
    - offer Save As if appropriate.

9.6. External modification detection:
    - before saving, if the on-disk file appears to have changed since it was opened, warn the user;
    - offer options such as Reload, Overwrite, Save As, or Cancel where practical.

9.7. Optional but recommended:
    - File > Save All when multiple files are dirty.

====================================================================
10. COMPARISON MODE
====================================================================

10.1. Comparison is enabled only when both File A and File B are open.

10.2. Comparison works by absolute zero-based 64-bit offsets only.

10.3. Do not attempt to find matching blocks at different offsets.
    - no diff alignment;
    - no sequence matching;
    - no move detection.

10.4. Comparison must always use the current logical in-memory contents of both files, including unsaved edits.
    - “in-memory” means the logical model with cached pages/overlay edits, not necessarily the entire file resident in RAM.

10.5. Any insert, delete, overwrite, or paste operation that changes byte contents or file length must immediately update comparison results in the visible region.

10.6. For large files, comparison beyond the visible region may be computed lazily/in background.

10.7. Byte comparison states:
    - same: both files have a byte at this offset and bytes are equal;
    - different: both files have a byte at this offset and bytes differ;
    - missing in shorter file: offset exists only in the longer file.

10.8. EOF-only bytes in the longer file:
    - are treated as a special difference type: missing in shorter file;
    - the longer file highlights these bytes as different;
    - the shorter file shows an EOF/missing region as empty cells;
    - navigation to next/previous difference must include these EOF differences.

10.9. Block definitions:
    - a different block is a maximal contiguous range of bytes where the two files differ at the same absolute offset;
    - a same block is a maximal contiguous range of bytes where the two files are identical;
    - EOF-only bytes in the longer file form a different block.

10.10. Difference highlighting:
    - different existing bytes are highlighted in both panes;
    - difference state uses background color;
    - EOF missing region is visually distinct;
    - modified unsaved state overlays red foreground as specified earlier.

====================================================================
11. DIFF NAVIGATION
====================================================================

11.1. Provide commands:
    - Next Difference Block;
    - Previous Difference Block;
    - Next Same Block;
    - Previous Same Block.

11.2. These commands are enabled only in comparison mode.

11.3. Navigation starts from the active pane’s caret/viewport position.

11.4. If the current position is inside a block:
    - Next moves to the next block of the requested type;
    - Previous moves to the previous block of the requested type.

11.5. Navigation must include EOF-only difference blocks.

11.6. Default behavior:
    - no wrap-around;
    - when no further block exists, show a status message or non-blocking indication.

11.7. Optional setting:
    - allow wrap-around navigation.

11.8. When navigating:
    - move the active pane to the target block;
    - synchronized pane should scroll to the same absolute offset if sync is enabled;
    - clamp to EOF for the shorter file where necessary.

====================================================================
12. PANE SYNCHRONIZATION
====================================================================

12.1. Scrolling or explicit repositioning in one pane should automatically position the other pane to the same absolute offset.

12.2. Synchronization applies to viewport repositioning, including:
    - scrolling;
    - page up/down;
    - Go To Offset;
    - search match navigation;
    - diff/same block navigation.

12.3. Synchronization should be enabled by default.

12.4. Provide a user-visible toggle, e.g. View > Synchronize Panes.

12.5. When sync is enabled:
    - the inactive pane scrolls to the same absolute top offset;
    - if the inactive file is shorter, clamp to EOF;
    - avoid recursive event loops when programmatically syncing panes.

12.6. Selection/caret:
    - ordinary selection and caret movement during editing need not be fully mirrored;
    - explicit navigation commands should keep viewports synchronized;
    - if feasible, mirror caret offset best-effort when it does not interfere with editing.

====================================================================
13. SEARCH
====================================================================

13.1. Search operates on the active pane only in v1.

13.2. Provide a Find UI, e.g. find bar or sheet.

13.3. Search modes:
    - Hex bytes;
    - Text ASCII;
    - Text UTF-8;
    - Text UTF-16 LE;
    - Text UTF-16 BE.

13.4. Hex search:
    - input is a sequence of hex bytes;
    - allow optional spaces between bytes;
    - allow optional 0x prefixes if easy;
    - case-insensitive;
    - validate that the number of hex digits is even;
    - show inline error for invalid input.

13.5. Text search:
    - convert the input string to raw bytes using the selected encoding;
    - perform exact byte sequence matching;
    - do not apply locale-sensitive normalization by default;
    - UTF-16 must explicitly support LE and BE.

13.6. Search operations:
    - Find Next;
    - Find Previous;
    - forward/backward direction support.

13.7. Search execution:
    - must run in background for large files;
    - must not block the UI thread;
    - should show progress or spinner for long operations;
    - must be cancellable.

13.8. Search result behavior:
    - when a match is found, select the matched range and scroll it into view;
    - update caret position;
    - if synchronized, update the other pane viewport;
    - if no match is found, show a status message.

====================================================================
14. GO TO OFFSET AND SELECT RANGE
====================================================================

14.1. Go To Absolute Position:
    - provide a Go To Offset command;
    - accept hexadecimal input;
    - optionally accept decimal input with clear syntax;
    - offsets are zero-based;
    - if offset is beyond EOF, clamp to EOF and show a status/hint;
    - move caret and scroll into view;
    - if sync is enabled, move the other pane viewport to the same offset.

14.2. Select Range dialog:
    - allow selecting a range by:
        a. Start + Length;
        b. Start + End.
    - values are entered as hexadecimal.

14.3. Range semantics:
    - internal model uses half-open [start, end);
    - if UI uses Start + End, End is inclusive and converted to end + 1 internally;
    - Start must be valid and not greater than file length;
    - if End/Length extends beyond EOF, clamp to EOF and notify the user;
    - zero-length selection is allowed and may collapse to caret.

14.4. Applying Select Range:
    - sets selection in the active pane;
    - scrolls selection into view;
    - updates status bar.

====================================================================
15. CLIPBOARD COPY / PASTE
====================================================================

15.1. Copy selected bytes with Cmd+C.

15.2. Clipboard writing:
    - write raw bytes using a custom pasteboard type, e.g. com.example.binarydiffeditor.bytes;
    - also write a hex text representation as public UTF-8 text for interoperability;
    - if no selection, Copy is disabled.

15.3. Paste:
    - prefer raw bytes from the custom pasteboard type;
    - if only plain text is available, attempt to parse it as hex bytes if it is valid hex;
    - if pasteboard content cannot be parsed safely, show an alert;
    - do not silently corrupt data.

15.4. Large clipboard operations:
    - paste of large data should be done asynchronously where practical;
    - show progress if needed;
    - allow cancel if practical;
    - avoid excessive memory use where possible.

15.5. All paste operations must be undoable and must update:
    - file content;
    - dirty state;
    - modified blocks;
    - comparison result for visible region;
    - file length if applicable.

====================================================================
16. LARGE FILE SUPPORT
====================================================================

16.1. The app must support very large files that do not fit completely in memory.

16.2. Do not read entire large files into RAM.

16.3. Use a file-backed chunked storage model:
    - page/chunk cache;
    - bounded memory cache;
    - read chunks on demand;
    - prefetch visible/nearby regions where useful.

16.4. Editing large files:
    - edits must not require copying the entire file in memory;
    - use an overlay, piece table, sparse edit log, temporary backing store, or equivalent;
    - support insert/delete/overwrite operations efficiently enough for interactive editing.

16.5. Comparison and search:
    - operate lazily/chunkwise;
    - visible region updates should be fast;
    - full-file scans may run in background and be cancellable.

16.6. Save:
    - saving a large file may require rewriting the full file;
    - show progress;
    - allow cancel if feasible;
    - keep dirty state if save fails.

16.7. Offsets:
    - use 64-bit offsets;
    - use safe integer conversions;
    - handle large file sizes gracefully;
    - practical limits may be imposed by OS/disk, but app should not artificially limit to 32-bit.

====================================================================
17. INTERNAL ARCHITECTURE
====================================================================

17.1. Cleanly separate:
    - data storage;
    - data/domain model;
    - presentation layer.

17.2. Suggested layering:

    Storage Layer:
    - file access;
    - chunk cache;
    - temporary edit backing;
    - atomic save support;
    - no UI dependencies.

    Domain/Model Layer:
    - file buffer abstraction;
    - editable buffer;
    - undo/redo service;
    - dirty state tracking;
    - modified ranges;
    - diff engine;
    - search engine;
    - range/selection model;
    - clipboard parsing/serialization helpers;
    - pure Swift where possible;
    - no AppKit/SwiftUI dependencies.

    ViewModel/Presentation State Layer:
    - observable UI state;
    - user intents;
    - async task coordination;
    - MainActor where appropriate.

    View Layer:
    - SwiftUI/AppKit views;
    - drag & drop;
    - menus, toolbars, dialogs;
    - hex rendering.

17.3. Use protocols and dependency injection to make layers modular, reusable, and testable.

17.4. Avoid data races:
    - isolate mutable state appropriately;
    - use actors or MainActor where needed;
    - make domain types Sendable where practical.

17.5. Long-running operations:
    - search;
    - diff scanning;
    - large save;
    - large paste;
    - file loading/prefetch;
    must run off the main thread and must be cancellable.

====================================================================
18. PERFORMANCE AND RESPONSIVENESS
====================================================================

18.1. The UI must remain responsive.

18.2. Time-consuming operations must not block the UI thread.

18.3. Provide progress/cancel UI for operations that may take a long time:
    - search;
    - large save;
    - large paste;
    - diff scanning beyond visible region.

18.4. Scrolling should be smooth for large files due to virtualization and bounded rendering.

18.5. Visible diff updates after local edits should feel immediate.

18.6. Memory usage should remain bounded even for very large files.

====================================================================
19. MENUS, SHORTCUTS, AND COMMANDS
====================================================================

19.1. Provide standard macOS menus and shortcuts where practical.

19.2. Recommended File menu:
    - Open Pane A…;
    - Open Pane B…;
    - Open…;
    - Close Pane A;
    - Close Pane B;
    - Save;
    - Save As…;
    - Save All (optional);
    - Revert to Saved (optional but recommended);
    - Close Window;
    - Quit.

19.3. Recommended Edit menu:
    - Undo;
    - Redo;
    - Cut (optional);
    - Copy;
    - Paste Write;
    - Paste Insert;
    - Delete;
    - Insert Byte;
    - Select Range…;
    - Go To Offset…;
    - Find…;
    - Find Next;
    - Find Previous.

19.4. Recommended View menu:
    - Layout Left/Right;
    - Layout Top/Bottom;

19.5. Recommended Compare menu:
    - Next Difference Block (Cmd+]);
    - Previous Difference Block (Cmd+[);
    - Next Same Block;
    - Previous Same Block.

19.6. Use standard shortcuts where appropriate:
    - Cmd+S Save;
    - Shift+Cmd+S Save As;
    - Cmd+C Copy;
    - Cmd+V Paste Write;
    - Cmd+Z Undo;
    - Shift+Cmd+Z Redo;
    - Cmd+F Find;
    - Cmd+G Find Next / Shift+Cmd+G Find Previous, or platform-appropriate alternatives.

====================================================================
20. NON-FUNCTIONAL REQUIREMENTS
====================================================================

20.1. Accessibility:
    - keyboard navigation should work;
    - important controls should be accessible;
    - provide meaningful labels;
    - ensure sufficient contrast;
    - do not rely on color alone for state indication.

20.2. Appearance:
    - support light and dark mode;
    - use system colors/semantic colors where possible;
    - hex view should remain readable in both modes.

20.3. Localization:
    - all user-facing strings should be localizable;
    - base language can be English.

20.4. Error handling:
    - use user-friendly alerts for errors;
    - do not crash on invalid input;
    - handle:
        - unreadable files;
        - permission denied;
        - directories dropped as files;
        - invalid hex input;
        - invalid range input;
        - disk full/save failures;
        - clipboard parse failures.

20.5. Security:
    - app should be sandbox-friendly;
    - access files only through user selection, open panel, or drag & drop;
    - no network access is required;
    - do not execute external commands;
    - validate file URLs and inputs.

20.6. Logging:
    - use OSLog or similar for diagnostics;
    - avoid logging sensitive file contents.

====================================================================
21. UNIT TESTS
====================================================================

21.1. Unit tests are required for data processing logic of the data/model layer.

21.2. Minimum test coverage should include:

    Edit buffer:
    - read/write bytes;
    - overwrite at offset;
    - insert at offset;
    - delete range;
    - length changes;
    - edits at EOF;
    - zero-fill gap when writing beyond EOF, if applicable.

    Undo/Redo:
    - undo restores previous content;
    - redo reapplies change;
    - new edit clears redo;
    - dirty state changes correctly;
    - undo after save can make file dirty again.

    Dirty/modified tracking:
    - modified bytes detected after edit;
    - modified blocks are maximal contiguous ranges;
    - save clears dirty state;
    - undo to saved snapshot clears dirty state.

    Diff engine:
    - identical files produce same blocks only;
    - single-byte difference produces one different block;
    - multi-byte differences produce maximal contiguous blocks;
    - same blocks are maximal contiguous identical ranges;
    - EOF-only bytes in longer file are different block;
    - shorter file missing offsets are handled;
    - insert/delete length changes affect absolute-offset comparison correctly;
    - no block matching/move detection is performed.

    Search:
    - hex parsing valid/invalid;
    - ASCII encoding;
    - UTF-8 encoding;
    - UTF-16 LE encoding;
    - UTF-16 BE encoding;
    - search match offsets;
    - no match behavior.

    Range selection:
    - Start + Length conversion;
    - Start + End inclusive conversion to half-open;
    - invalid ranges;
    - clamping to EOF.

    Clipboard parsing:
    - raw bytes roundtrip if testable;
    - hex text parsing valid/invalid.

21.3. Model tests must not depend on UI.

21.4. Use deterministic temporary files for storage tests where needed.

21.5. UI tests are optional, not required.

====================================================================
22. ACCEPTANCE CRITERIA
====================================================================

22.1. The app opens files via menu and drag & drop.

22.2. Dropping more than two files results in only the first two being used in two-slot drop contexts, with a user notification.

22.3. Dropping onto a specific pane replaces that pane, with dirty prompt if needed.

22.4. In single-file mode, dragging shows split drop targets allowing:
    - replace File A;
    - open as File B.

22.5. With one file open:
    - pane occupies the whole window;
    - hex editing works;
    - comparison commands are disabled.

22.6. With two files open:
    - comparison mode is enabled;
    - both panes support hex editing.

22.7. Closing either pane returns the app to single-file mode.

22.8. Dirty state is independent per file and indicated by "*" in pane title.

22.9. Closing window/quit with unsaved changes prompts correctly for each modified file and allows cancel.

22.10. Layout can be switched left/right and top/bottom, and persists.

22.11. Hex view shows 16 bytes per row plus ASCII representation.

22.12. Scrolling/repositioning syncs panes by absolute offset when sync is enabled.

22.13. Comparison:
    - uses absolute offsets only;
    - includes unsaved edits;
    - updates visible region immediately after edits;
    - treats EOF-only bytes in longer file as differences;
    - highlights differences in both panes.

22.14. Next/previous difference and next/previous same block navigation works and includes EOF differences.

22.15. Editing supports undo/redo per file.

22.16. Modified unsaved bytes use red foreground.

22.17. Bytes that are both different and modified unsaved show both states unambiguously.

22.18. Go To Offset works.

22.19. Search works in active pane for:
    - hex bytes;
    - ASCII;
    - UTF-8;
    - UTF-16 LE;
    - UTF-16 BE.

22.20. Search runs in background and does not block UI.

22.21. Select Range works with Start/Length and Start/End hex input.

22.22. Copy copies selected bytes.

22.23. Paste Write overwrites from caret and can extend file length.

22.24. Paste Insert inserts before caret and extends file length.

22.25. App can open and interact with very large files without loading entire files into memory.

22.26. Architecture cleanly separates storage, model, and presentation.

22.27. Required unit tests pass.

====================================================================
23. IMPLEMENTATION GUIDANCE
====================================================================

23.1. Start with core model types and protocols before UI.

23.2. Suggested core protocols/classes:
    - FileStorage / ChunkedFileStorage;
    - EditableFileBuffer;
    - FileDocumentModel;
    - UndoService;
    - DiffEngine;
    - SearchEngine;
    - SelectionModel;
    - ClipboardService;
    - HexViewModel or pane view model.

23.3. Keep domain logic pure and deterministic where possible.

23.4. Make diff and search engines operate on ranges/chunks so they can be tested without huge files.

23.5. Use small value types for offsets and ranges:
    - Offset64 or UInt64 wrapper;
    - Range64 half-open range;
    - validated constructors.

23.6. Avoid force-unwraps and unchecked integer conversions in production code.

23.7. Provide README or documentation describing:
    - architecture;
    - how to run tests;
    - known limitations;
    - assumptions made.

