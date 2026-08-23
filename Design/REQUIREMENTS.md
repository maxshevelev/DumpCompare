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
  (§6). Nothing is drawn between them — the marked cell is the separation.
- The package is the icon's shape: a black moulded body with a light sheen,
  spanning the full width of the tile, with one row of five polished metal leads
  above it and one below. There is no plate or rounded-square ground behind it,
  so the background is transparent.
- The package is deep enough that body and leads fill most of the square tile,
  rather than sitting in a band across its middle. The byte size is limited by
  the tile's width, so the extra depth is plastic around the marking, not bigger
  type.
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
   - an “Open File” affordance — a large borderless icon with its label under
     it, not a titled push button: the empty window is a landing screen, and a
     small grey rounded rectangle in the middle of it reads as a disabled field;
   - a hint that files can be dragged and dropped.
   - the window opens as wide as **one** pane’s hex grid at the saved word size,
     whatever the saved pane arrangement — no file is open yet, and one file is
     the common case; the height is the standard default. Window > Zoom fits the
     real content once files are open.

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
   - a dirty indicator: the document glyph beside the name is filled in while
     the file has unsaved changes (an outline when it is clean, a “+” badge for
     an untitled document), which says the same thing as a trailing “*” without
     spending a character of the name on it;
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

6. Bookmarked row (§20):
   - a state of the row's Offset column, not of its byte cells: the address
     stands on a right-pointing arrow in the bookmark colour — the column filled
     with the bookmark colour and its right end pointed into the gap before the
     hex column, the address drawn in white on top.
   - it is orthogonal to states 1–5: a bookmarked row may also be different,
     modified, or selected in its byte cells, and the arrow is drawn on top of
     the Offset column without disturbing them.

The layering, bottom to top, for a byte cell: the segment tint (§21.3), then the
difference fill (1), the selection fill (4), and the text — modified bytes red
(2), muted `0x00`/`0xFF` grey, the caret over everything. A state covers the
tint, which is correct: what a byte *is* outranks which piece it belongs to, and
the piece stays readable in the gaps and the rows either side.

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

The default editing model is overwrite. Insert mode (§7.6) is an optional,
never-persisted departure from it; everything below describes the default.

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
- any explicit “Insert Bytes” operation if implemented;
- Insert mode (§7.6), where confirmation is once per opened file rather than per
  keystroke — per-keystroke confirmation would make the mode unusable.

These confirmations can be switched off, from a setting and from a "Do not ask
again" checkbox on the dialogs themselves — one switch, reached two ways, so
dismissing a dialog with the box ticked is reflected in the setting and the
setting silences the dialogs. Ticking the box counts whichever button dismissed
the dialog: it says "stop asking", not "and do it". They are on by default: these
are the edits that quietly ruin a structured dump. With them off the edits still
record undo steps, and insert mode still announces itself in the status bar and in
the caret.

Confirmation dialog must explain:

- operation type;
- target offset;
- number of bytes inserted/deleted;
- that subsequent offsets will shift;
- that the file structure may be affected.

7.3 Delete/Backspace default behavior

To avoid accidental structural damage (in insert mode these keys delete bytes
instead — §7.6):

- Delete/Backspace must not change file length by default.
- They should fill the selected bytes with 0x00.
- If no selection:
  - Delete fills current byte with 0x00;
  - Backspace fills previous byte with 0x00 and moves cursor back.

A separate explicit menu command, e.g. Edit > Delete Bytes, performs true length-changing deletion and requires confirmation.

7.4 Selection editing

- If a selection exists and the user types, the selected range is overwritten with typed bytes (in insert mode the selection is dropped and the byte inserted at its start — §7.6).
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
- One undo gesture is one *step*. Steps group logically: a paste, a fill, a
  delete command are one step each; typed input is grouped into series (§7.5.1).
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
- Dirty state must track the document's content against the last saved state,
  not the number of edits standing. Two different edits at the same depth of the
  history are not the same state: undoing an edit and making a different one
  leaves the document dirty, even though as many edits stand as when it was
  saved. Reporting it clean would let closing or replacing the file discard the
  change without a prompt (§5.1, §17.7).
- Undo history may be bounded by memory/disk resources, but must be sufficient for practical editing sessions.

7.5.1 Typed input: series and segmented undo

Typing byte after byte must cost neither one undo press per byte nor a single
press for a whole session: a typo at the end of a run has to be correctable on
its own, and a long run has to be removable without holding the key down.

- A *series* is a run of completed bytes typed in one input region. Each byte is
  its own step; the steps of one series are linked as one.
- A series is broken by:
  - a pause longer than the series-break threshold since the last typed event;
  - a change of input region (hex ↔ text);
  - caret movement by the user — arrows, a click, block navigation, a search
    result;
  - any other mutating command: delete, fill, paste write, paste insert;
  - a selection change, an undo, or a redo;
  - a save. The saved state is a checkpoint the user must be able to return to
    in one press, so no series and therefore no batch may span it.
  The caret advancing by itself after a completed byte does not break a series,
  and neither does the two-nibble pair of one hex byte.
- Rollback of a series:
  - the first undo removes its last byte;
  - a repeat within the fast-undo window removes the rest of the series as one
    step;
  - a repeat after that window removes one more byte.
- Redo is symmetric: what one press removed, one press restores, and a restored
  batch becomes byte-by-byte steps again — so correcting a single byte stays
  available after a redo.
- A batch restores the selection the series started from, and its redo the
  selection the series' last byte left (§7.5).
- Both thresholds are fixed constants of the build — a series break of about
  0.7 s, a fast-undo window of about 0.5 s — not user settings. The fast-undo
  window must be no shorter than the system's key-repeat delay, or holding the
  undo key never reaches the batch.
- A batch is one change to the storage: the comparison and the minimap update
  from the single net edit it reports, not once per byte (§8.3, §19.9).
- A byte left half typed (one nibble entered) ends when the user leaves it — a
  caret move or a region change — and becomes an undo step of its own. It must
  never stay pending and coalesce with the next byte typed somewhere else: one
  press would then take back two unrelated bytes.

7.6 Insert mode

An optional typing mode, off at every launch and never persisted, that turns
typing into insertion. It is a mode, not a command: it changes what the keys of
§7 do until it is switched off.

- Scope: one mode per pane, toggled for the active pane from Edit > Insert Mode
  (a checked item) or its key equivalent. The checkmark follows the active pane's
  mode, and each pane's status bar reports its own — one file can be typed into
  while the other is being read.
- Typing inserts: a completed byte is inserted at the caret and every byte from
  there on shifts right; the file grows by one. Hex entry inserts on the first
  digit with the low nibble still empty, and the second digit fills that nibble
  in place — the pair is one undo step, as in overwrite mode (§7.5.1).
- The empty low nibble of a half-typed byte is drawn as a placeholder slot, not
  as the zero it currently holds, and drawing it must not disturb the cell's
  background — a difference fill, a selection, an EOF cell keep their own (§6).
- The caret marks the byte boundary the next byte will land on, and is visually
  distinct from the overwrite caret. Switching modes redraws it where it is,
  without scrolling: the caret has not moved.
- Every pane's status bar shows the mode as INS/OVR (§15). INS is drawn in the
  same red the insert caret and modified bytes use — in this app red means "not
  the file you opened", which is what the mode leads to. The indicator keeps its
  width across both states so the bar does not shift when the mode flips.
- Backspace on a half-typed byte rolls that byte back — the inserted byte
  disappears and nothing is recorded, as if the nibble had never been entered.
- Delete and Backspace otherwise remove bytes and shift the tail (Backspace the
  byte before the caret, Delete the byte at it; with a selection, the selected
  span). §7.3's fill-with-0x00 rule is the overwrite-mode behavior.
- Typing with a selection drops the selection to its start and inserts there. It
  does not consume the selection (§7.4 is an overwrite rule): the selected bytes
  shift right, so a surviving highlight would name bytes the user never picked.
- Confirmation: insert mode shifts offsets, so §7.2 applies, but per keystroke
  it is unusable. The mode asks once per opened file, on the first keystroke or
  delete that shifts anything, and then stays silent for that file; cancelling
  swallows the keystroke and leaves the file untouched, and the next one asks
  again. Opening or closing a file re-arms it. Toggling the mode off and on
  within the same file does not. The confirmation can be switched off for good
  (§7.2).
- Cost: each inserted or deleted byte rewrites the file's storage, so the mode is
  meant for small edits, not for typing over a chip-sized dump. Buffering typed
  input is a separate topic (it would cover Paste Insert too).

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

A batch of queued edits is collapsed before it is applied. Applying rescans
against current bytes, so a shifting edit already covers every edit at or after
its offset: a run of ten inserted bytes is one rescan of the tail, not ten.
Overwrites below the shift point survive it, merged where they touch. Only the
first full build reports progress — an incremental apply is short enough that a
bar would flash (§19.9 says what that reads as).

Because a shifting edit invalidates everything after it, the scan itself has to
be fast enough that rescanning a file's tail is not an event: comparing two
16 MB dumps must cost tens of milliseconds, not seconds. Comparison is by
absolute offset, so it is a memory comparison — it must be done a machine word
at a time, with a whole-chunk comparison for the chunks that match (which is
most of them when the two files are reads of the same chip). A byte-at-a-time
loop ran at 16 MB/s, which made one inserted byte cost a two-second rescan and a
run of ten cost twenty.

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

Go To and the bookmark list (§20) are one form, presented in a window centred
over the one it navigates. They are one form because they are one question — "go
where?" — and split in two they would be two windows each offering half an
answer: the addresses worth returning to are exactly the ones a user would
otherwise be typing again.

- Cmd+G opens the form with the offset field focused; Option+Cmd+B opens the same
  form with the bookmark list focused. The two shortcuts differ only in which
  half the keyboard starts in.
- Either command needs a file open: with nothing open there is nothing to
  navigate, and both menu items are greyed out.
- The field accepts a single absolute offset. A **Go To** button beside it names
  the action rather than leaving it to be guessed from Return.
- Offset input must support:
  - hexadecimal with `0x` or `0X` prefix;
  - decimal without prefix.
- The offset input field should be pre-filled with `0x` by default, with the
  caret behind the prefix so hex digits can be typed straight away. The last
  address is deliberately not pre-filled: the caret sits at the end of the text,
  so a pre-filled address would turn Cmd+G, type, Return into digits appended to
  the previous jump.
- Offsets are zero-based.
- Input parsing must be case-insensitive for hex.
- The field is validated as it is typed in, the way the Select Block sheet's
  fields are (§10.2): the message under it — starting at the field's own left
  edge, not the dialog's, because it belongs to that field — names what is wrong
  and clears the moment the input becomes valid, and the **Go To** button is enabled only for an
  offset that parses — so the form says whether it can act on the field before
  any key is pressed. The form opens with the button off and no message: the "0x"
  prefix is not an offset yet, and there is nothing to complain about until
  something is typed.
- Return in a field that does not parse beeps and does nothing else. The button
  beside it is already disabled and the message already says why, so the key owes
  no new words — only an answer that it was heard and refused. An invalid offset
  leaves the form up, with the caret in the field, so it can be corrected.
- **Return follows the focus.** In the field it goes to the typed offset; in the
  list it goes to the selected bookmark; in the list with nothing selected it
  does nothing at all. One Return means two things without ever guessing — which
  is also why the Go To button must not be a default button, since a default
  button claims Return from the whole window.
- **Escape is two-level**: while a bookmark's name is being edited in the list it
  cancels that edit, restoring the name the store holds; with no edit running it
  closes the form. Editing a name and pressing Escape must not throw the window
  away.
- The offsets Go To was sent to are remembered in the field's dropdown: the last
  ten, most recent first, persisted across launches. An entry is the offset's
  canonical address, not the keystrokes that produced it — `0x7af00`, `0x07AF00`
  and `503552` are one address, and a history listing them three times would be a
  log of typing rather than a list of places. A jump from the bookmark list is
  not recorded: it is already in the list below.
- A jump dismisses the form, and the row it lands on is revealed centred — the
  form is centred over the window it is about to scroll, so the destination has
  to be where the user is looking.

Go To behavior:

- In single-file mode, move the active pane cursor to the requested offset if valid.
- In comparison mode, move both panes to the same absolute offset.
- If the offset is beyond the active file length but within the other file length:
  - the shorter file shows EOF/blank region;
  - the longer file shows the byte at that offset.
- If the offset is beyond both files:
  - clamp to the end of the longer file;
  - show a warning or status message.

The bookmark list in the lower half of the form, and everything it does with a
bookmark, is §20.5.

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
- Opened from the offset context menu ("Select block from here", §10.2) the sheet
  carries no message line: the Start field already shows the address that was
  right-clicked and Length is already the active option, so a sentence saying
  both would be the sheet narrating its own fields.
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
- The toolbar carries the difference block only in comparison mode: with fewer
  than two files there is nothing to navigate at all, and a pair of buttons that
  can never do anything still reads as something the window offers. The menu
  items stay in place, disabled — a menu is a list of what the app can do, and a
  greyed item says why this one is not available now. Inserting the block must be
  followed by a validation pass, or its buttons show up enabled: the default
  validation only asks whether the target responds to the action.
- The menu items and the toolbar's arrows must both be disabled whenever the
  command would find nothing — index still building, or no target in that
  direction from the caret. Toolbar items are validated by the target, not by
  pushing their enabled state: the framework revalidates visible items on its
  own schedule and would undo a pushed value. The arrows must also be
  revalidated when the availability changes, so they follow the caret at once
  instead of on the next idle pass.
- If the full-file diff index is still being computed:
  - navigation may perform on-demand scanning;
  - show progress for long scans;
  - keep UI responsive.

Suggested shortcuts:

- Next difference: Cmd+Option+Right Arrow.
- Previous difference: Cmd+Option+Left Arrow.
- Next same block: Cmd+Option+Shift+Right Arrow.
- Previous same block: Cmd+Option+Shift+Left Arrow.
- Go To Position (the form's offset field): Cmd+G.
- Bookmarks (the same form, its list focused): Cmd+Option+B — Cmd+B is the
  system's Bold, so the list takes the Option variant.
- Toggle Bookmark: Cmd+D; Edit Bookmark: Shift+Cmd+D (§20.3).

Shortcuts may be adjusted, but must be discoverable in menus.

10.3.1 Difference grouping for navigation

The unit navigation steps by is a difference *hunk*, not a byte-exact
difference block.

- A hunk is a maximal run of difference blocks in which every two neighbours
  are separated by a matching run shorter than the grouping distance. A
  matching run of at least the grouping distance separates two hunks.
- A hunk's bounds are its first and last differing byte. Forward navigation
  lands on the first, backward navigation on the last, so navigation never
  lands on a byte that does not differ.
- Grouping is by distance only. It must not be defined on the 16-byte row grid:
  row grouping makes the effective threshold depend on where the differing
  bytes fall inside a row (bytes 30 apart in two adjacent rows would merge
  while bytes 16 apart across one clean row would not), so the same spacing
  would group differently depending on alignment.
- Same-block navigation is the complement of the hunks: the matching runs
  between hunks, plus the leading and trailing runs of the comparison extent.
  A matching run swallowed by a hunk is not a navigation target — it is inside
  a change. The leading and trailing runs may be shorter than the grouping
  distance; nothing was merged across them.
- A caret inside a hunk — including inside a run the hunk swallowed — belongs
  to that hunk: the next/previous target is the neighbouring hunk, never a
  fragment of the current one.
- The grouping distance is user-configurable (Settings > Comparison), offering
  16 / 32 / 64 / 256 bytes, defaulting to 64. A change applies to an open
  comparison immediately and must re-derive the hunks from the existing block
  index — grouping changes nothing about the comparison itself, so the files
  are not rescanned.
- Grouping affects navigation only:
  - byte highlighting stays per byte (§8.2);
  - the difference/same byte counts in the status bar stay per byte;
  - the block index keeps its byte-exact semantics (§8.1); the hunks are
    derived from it.
- Enabling/disabling the navigation commands must use the same grouped unit as
  the commands themselves, so a command is enabled exactly when it would move.
- The derivation is a linear pass over the blocks and must not run on the main
  thread: a pair of files whose differing bytes alternate with matching ones
  holds a block per byte.

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
- Edits are stored as a piece list over two immutable sources: the file as it was
  opened, and an append-only buffer of the bytes editing added.
- No edit may cost work proportional to the file: an insert or a delete is a
  change to the piece list, not a copy of the content. Materializing the content
  into a temporary file is allowed only as an amortized valve — an oversized
  insert, an add buffer past its budget, a piece list long enough to slow reads —
  and at most one such file may be kept at a time.
- Save can patch in-place for overwrite-only edits where safe. The ranges it
  patches must survive a materialization.
- Save may rewrite file for length-changing edits or Save As.

Performance expectations:

- Editing a byte must cost the same on a 32 MB dump as on a 1 KB file, and the
  same at either end of it.
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
- Paste (the standard item; with the dump focused it pastes bytes over the
  selection — §12.2. There is deliberately no separate "Paste Write" item: a
  second ⌘V owner would take the shortcut away from every text field in the app.)
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
- background task progress for diff/search when applicable;
- the typing mode as INS/OVR (§7.6), with INS coloured — the mode changes what
  every keystroke does, so it must be readable without opening a menu.

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

A map draws its file one of two ways, switched from the View menu or the panel's
header. Which one a file opens in is a property of the file, not a preference,
so nothing is remembered: every open picks the more informative view, and a
switch by hand holds only until the open files change.

- Up to a few kilobytes — a size the detail window shows most or all of, byte by
  byte — a file opens in detail. Above it, where detail could only ever show a
  sliver, it opens in overview. The threshold is a fixed size, not the panel's
  current row capacity: which view a file opens in must not depend on how the
  window happened to be sized at that moment.
- In comparison mode the longer file decides, since it is the comparison's
  extent (§9).
- Overview is offered only while it would *compress* the file: every pixel row
  must stand for at least one byte. Below that each byte is stretched over
  several rows — a magnified smear of a file that detail shows whole, with real
  per-byte state — so the mode switch's Overview half and the View menu item are
  disabled there, and the panel leaves overview if it becomes so. The panel must
  never be parked in a view its own switch refuses to offer.
- The offer is recomputed whenever either side of that comparison moves: the
  panel's height (a window resize, in both directions — the choice comes back
  when it shrinks again) and the file's size (an insert or a delete can carry a
  file across the line). Leaving the mode is forced; returning to it stays the
  user's choice.

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
- The mapping must hold in both directions. A row covers fewer bytes than it has
  cells whenever the file is smaller than 16 bytes per pixel row, and covers a
  *fraction* of a byte once the file is smaller than the panel has rows. Each
  byte is then stretched over the cells it covers — a row standing for one byte
  is that byte across its whole width — and a row thinner than a byte still
  draws the byte its position falls in. Slicing per cell in that regime leaves
  every cell but the last with an empty byte range: the file collapses into a
  stripe down the map's right edge and the rest of the panel is a pale field.
  The same stretch applies to the difference and modification marks, so a byte
  marks the cells it occupies rather than only the first of them.
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
  pixels tall so a single byte among thousands stays visible.
- A byte is modified when it is not the byte the saved file holds at that offset
  — the rule the panes paint by. An insert or a delete moves every byte after it,
  so from that offset to the end the file no longer holds what it did there and
  the whole tail is modified; the map must say so, as the hex view does. Marking
  only where editing *wrote* was true while overwriting was the only kind of edit
  and became a lie with insert mode: one inserted byte left the map with a single
  marked row and the dump beside it entirely red.
- A modified byte marks its row across the map's whole width — as far as its own
  file reaches — rather than the cell it falls in, and over everything else in
  that row. Two pixels tall in one cell of sixteen, a single edited byte was a
  couple of dozen pixels in the whole panel and simply not findable, which reads
  as the overview not marking edits at all. "You changed this" is the rarest
  thing the map says, and at this scale the column it happened in says almost
  nothing: one column of a 16 MB dump's row is a kilobyte. Differences keep
  their per-cell shading — they come in runs, and the shading is what makes a
  run's shape legible.
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

19.4.3 Bookmarks in the margin

Bookmarked rows (§20) are marked on the maps, so a marked region can be found
without opening anything.

- A mark is a small arrow in the map's **side margin** — outside the content
  area, pointing inward at the row it marks — in the bookmark colour (purple,
  §20.4), which keeps it apart from the file's own inks and from the grey
  viewport marker that can share the margin with it. Nothing is drawn over the
  content: on a dump every column of every row carries information.
- The two margin markers are the **same shape**: an equilateral triangle whose
  apex stops the same distance short of the content edge. A viewport's position
  and a bookmark's row are the same kind of statement about where something is,
  so they are the same arrow — the bookmark's is the smaller of the two, because
  they can share a margin and the viewport is the one the eye should find first,
  and colour is what says which is which.
- **Hovering a mark names it**: `offset: name`, or the offset alone when the
  bookmark has no name — bare digits, the way the list writes an address (§20.5). A mark carries no text of its own, so this is where its
  name shows on the map — and the address belongs here even for a named bookmark,
  because on a map the arrow's position only approximates it (a row of the
  overview is kilobytes). Hovering anywhere else on the panel shows nothing.
- Which margin depends on the layout. Side by side the two maps meet at the
  gutter with no padding between them, so the second map marks its rows in its
  right margin, pointing left; everywhere else the mark sits on the left.
- Both render modes mark the same rows — the mode changes the scale, not what is
  marked. In detail a mark is level with its row exactly; in overview it is level
  with the row the bookmark's offset falls in, so several bookmarks close
  together can land on one arrow, which is what that scale means everywhere else
  on the map.
- One list serves both maps, because a bookmark is an absolute offset (§8): a
  marked row is marked at the same height on each. A row past a file's own end is
  not marked on that file's map — there is no such row there (§9) — and in detail
  a row outside the window is not marked at all.
- A bookmark changes nothing about the file's picture, so adding, moving or
  removing one repaints only the margins the marks live in, never the maps
  (§19.9). A rename repaints nothing: the arrows have not moved.

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
  across the content at all: the position is marked by an equilateral triangle in
  each outer margin, level with the middle of the visible slice, pointing inward
  — the same shape a bookmark's mark uses, one size larger (§19.4.3). A band or
  line spanning the panel would cost a whole row of the picture, and on a dump
  every row carries information. The marker states a position and must not
  pretend to show an extent.

19.6.1 Clicking near a bookmark's mark

- A click within a few points of a bookmark's mark (§19.4.3) means **that
  bookmark's row**, not the byte drawn under the pointer. On a full-dump overview
  a row is kilobytes, so a pointer dead on the arrow still resolves to an offset a
  dozen rows off the bookmark — the mark is what the user aimed at, and it is a
  two-pixel target without this.
- With two marks in range the nearer one wins, measured from each mark's own
  centre line.
- **Dragging the band never snaps.** It is a scrollbar gesture, and a continuous
  scroll that jumped to a bookmark as it passed would fight the drag.

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
  - Detail mode has no picture to compare: it pulls its cells from the panes
    as it draws, so *something must ask it to repaint* those rows. Every
    change to what the map shows counts — a typed byte, an undo, a redo, and
    a save (which changes no byte but clears the modified marks). Without
    that request the map keeps its old pixels until some unrelated event
    repaints it, which is how modified bytes and differences came to appear
    only on the next scroll or resize.
  - An edit repaints its rows on *both* maps: comparison is by absolute
    offset (§9), so a byte edited in one file changes the difference state
    the other map draws at that offset.
  - An insert or delete moves every byte after it, so no range describes the
    change and the maps repaint whole.
- A repaint must start from the panel's background, since it can no longer
  rely on the whole panel being redrawn.
- The panel is repainted only when the picture can look different. A typed byte
  moves the extent by one, which moves each row's slice by a fraction of a byte:
  nothing to see, and asking for a repaint of it on every keystroke cost tens of
  milliseconds of main thread each time. A map the repaint does not reach is
  skipped whole, and the theme's inks are resolved to concrete colours once per
  pass — `setFill` on a dynamic colour resolves it again on every call, which at
  one call per row was most of the cost of drawing a map.
- A row one colour covers whole is one fill, and consecutive such rows are one
  fill together. Neighbouring cells that draw the same thing are one fill too: a
  dump's rows are largely uniform, sixteen cells of erased padding or of dense
  content. After an edit that shifts offsets the whole tail is modified —
  and in a comparison differing as well — so nearly every row is in that state:
  drawing them cell by cell put a full repaint of two maps at 138 ms on the main
  thread, once per rebuild, which is felt as the typing stuttering. Rows the
  file's end falls in are drawn on their own, so a fill never runs past it.
- An edit must not rebuild the overview's picture. A byte lands in one row of
  a thousand, so the rows its range falls in are recomputed — from the file for
  their density, from the edit overlay for their modified marks, from the
  comparison index for their differences — and the rest of the picture is left
  as it is. The patch runs on the main thread: it reads one row's slice per map
  (tens of kilobytes), so the mark appears with the keystroke, with no debounce
  to wait out. A patched picture must equal the picture a full pass would
  build; anything else drifts the map away from the file as editing goes on.
  - The difference marks come from the comparison index, and a consumer that
    needs a few rows of them asks the index for that window, by binary search
    over its blocks. Flattening the index into a list of differing ranges to
    find them walks every block in it: two reads of a chip with scattered
    differences make tens of thousands of blocks, and doing that twice per
    keystroke — once for the edit, once when the index absorbs it — put a third
    of the main thread into building arrays, which is what the typing stuck on.
  - The index absorbs the edit in its own background pass. Those rows are therefore patched twice: once
    with the keystroke, once when the index reports the change.
  - An index change that is *not* the absorption of a recorded edit — a fresh
    build, a cancel, a stop — invalidates the whole derived picture, so that
    still rebuilds.
- A full rebuild is for the changes no row range describes: a new file, a
  resize that re-bins the rows, an insert or delete, a save (which clears every
  modified mark), a fresh comparison index. It walks the whole file and must
  not run on the main thread, must be debounced, and must be cancelled when
  superseded. The two files of a comparison are independent passes and are
  computed concurrently.
- A rebuild reports progress to the panel's status bar (§19.1). The bar
  appears only if the pass outlives a short delay — a small dump is binned in
  milliseconds, and a bar shown for one frame reads as a glitch — and it is
  then held for a minimum showing before it clears, because the pass itself is
  fast: two 16 MB dumps are binned in ~150 ms, so a bar that vanished the
  instant the pass ended was never seen at all.
- The rebuild waits for the edits to stop: every request restarts the delay, so
  a burst of keystrokes costs one pass after it rather than one per keystroke. A
  pass reads both files whole, and at auto-repeat speed — thirty keys a second —
  running one per keystroke starves the main thread of the same caches it draws
  from, which is felt as the typing sticking. A request that arrives while a pass
  is running does not cancel it: it is remembered and honoured when that pass
  lands. The exception is a change to the row count, which makes the running
  pass's result useless — it is binned for a panel height that no longer exists.
- While it waits, the map keeps the picture it has. It is a byte or two out of
  date, which at a row per few kilobytes is invisible, and that is the whole
  point: an interim answer must not be a *different* picture. Marking the shifted
  tail red in the meantime was tried and rejected — an edit near the start of a
  file paints the entire map red, which is worse than a picture slightly behind.
- Background work — a pass, an index absorbing an edit — runs below the
  interface's priority. Nothing on screen waits for it: the panes compute the
  differences they show from the bytes themselves, and the map is already
  showing something.
- The picture in hand is never thrown away while its replacement is computed.
  A rebuild is triggered by things that make the picture stale, not wrong to
  look at: an edit that changes the longest file's length re-bins every row, but
  by a fraction of a percent, so the old picture is stretched over the map (the
  same stand-in a resize uses) until the pass lands. Blanking the panel instead
  made every inserted byte blink — and blink asymmetrically, since deleting from
  the shorter file of a comparison leaves the extent, and therefore the bins,
  untouched. A stale picture is not patched row by row: its rows cover different
  slices than the patch measured, so the pass on its way replaces it whole.
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

=====================================================================
20. BOOKMARKS
=====================================================================

A bookmark is a marked row of the hex dump — an address the user has decided is
worth coming back to. Comparison is by absolute offset (§8), so a bookmark is an
offset, not "an offset in file A": one list serves both panes and marks the same
height in both, which is the whole point of it in a comparison.

20.1 What a bookmark marks

- A bookmark marks a row, not a byte: its offset is rounded down to a multiple of
  16 (the bytes per row). The places a bookmark has to be visible are
  row-granular by construction — the Offset column carries one address per row,
  and a minimap row is one hex row (§19) — so byte precision would be invisible
  exactly where the mark is meant to be seen. It also removes the "two bookmarks
  in one row" ambiguity from the drawing.
- Bookmarks are absolute addresses: an insert or a delete shifts the bytes, not
  the bookmark (§8). A bookmark past the end of a file stays in the list and is
  simply not drawn where the file does not reach (§9).
- Bookmarks are session-only: they live as long as the window, not the file. So
  closing a file and opening it again keeps its marks, which is the case that
  matters on a bench — the same chip read twice. Opening an *unrelated* file
  inherits them too; the list is not cleared, because the app cannot tell a
  re-read from a new dump, and a mark that turns out to be meaningless is cheaper
  than losing the marks of a re-read. Persisting bookmarks per file is a project
  feature (§20 opening note), not a session one.
- The mark has no text of its own, so the pane's accessibility value says whether
  the caret's row carries one and what it is called, as it says the caret's
  offset (§15).
- A bookmarked row is marked in the minimap's margin as well as in the Offset
  column, in both of the minimap's modes (§19.4.3) — that is what makes a marked
  region findable without opening anything.

20.2 The model

- A bookmark is a value: the row it marks (always a multiple of 16) and a name;
  an empty name means "show the address".
- The store keeps the bookmarks sorted by row and answers the questions the
  panes ask: the bookmark on the row containing an offset, a toggle of the mark
  on that row (adds an unnamed bookmark when the row is unmarked, removes it when
  it is marked), and the set of bookmarked rows in a range of offsets — asked
  once per drawn row range, not per row.
- The store snaps an offset to its row (the offset rounded down to a multiple of
  16) and fires a change signal carrying the affected row's start offset, so each
  pane repaints just that row instead of the whole dump.
- One instance lives on the window's view model, reached by both panes — that is
  what makes the list shared rather than merged. The store holds no bytes and is
  AppKit-free, so its arithmetic is unit-testable in the app suite.
- Besides the toggle the store can mark-and-name a row in one act (an
  already-marked row keeps its one mark and takes the new name), rename a mark
  that exists, and remove one — each reporting what it found, so a caller never
  has to read the list first, and each firing the same change signal, so a name
  typed in a dialog shows up without anything else repainting the row.
- It can also move a mark to another row, keeping its name and reporting the row
  it ended on — which is not always the row asked for: the store owns the
  one-bookmark-per-row rule, so it is the store that decides where a mark dragged
  onto an occupied row lands (§20.6). The far row it may not pass comes from the
  caller, because how far a pane reaches is the view's knowledge, not the list's.
- Names are stored trimmed of surrounding whitespace, and a name that is nothing
  but whitespace is no name — so the "empty means show the address" rule cannot
  be defeated by a space.
- The store fires that same change signal at whatever else is showing its
  contents — the edit popover, which must not outlive its mark (§20.3), and the
  open form's list (§20.5) — so a bookmark made or removed anywhere shows up
  everywhere without any of those surfaces polling it.

20.3 Marking and naming a row

- Edit ▸ Toggle Bookmark (⌘D) marks the active pane's caret row and unmarks it
  again — one command for both, and its title says so rather than promising only
  to add.
- Marking a row opens the edit popover on the new mark: a small panel anchored
  to the mark itself, with the caret already in its Name field. **Return** saves
  the name (nothing typed means an unnamed bookmark, shown by its address);
  **Esc** removes the mark again, cancelling the whole act, not just the name.
  So **⌘D, Return** is the whole gesture for "mark this row", and ⌘D, a name,
  Return the one for "mark it and call it this" — the muscle memory is one
  command plus Return either way.
- A popover, not a modal dialog: editing a bookmark is an aside to reading a
  dump, and the mark being edited has to stay visible while the name is typed. It
  holds the bookmark's **address** and its **name**, each a field spanning the
  popover's width, the name labelled by its own placeholder — and no instructions:
  a panel with two fields is not where the keyboard needs explaining.
- On an **existing** bookmark it also carries one button, **Delete**, because
  removing the bookmark is the one act the popover's keys cannot express: Esc
  means "leave it as it was", and it has to keep meaning that. A mark that is
  still being named gets no such button — its Esc already takes it away, and two
  ways to undo one half-finished act is one too many.
- The address is a field, not a title, so a mark put a row off is corrected by
  typing the right address — the keyboard's version of dragging the mark (§20.6),
  and it keeps the name. Committing a different address moves the one bookmark
  there; it is never removed and re-made, so it never appears without its name.
- The address is validated as it is typed, as every offset field is (§10.1) —
  shown in the field itself, in red, because a panel this small has no room for a
  sentence and red digits among digits say the same thing. An address that names
  no row refuses Return with a beep and keeps the popover up: a typo, or a row
  another bookmark already holds, one row holding one bookmark (§20.1). The
  mark's own row is of course always available to it.
- The caret starts in the **Name** field in both jobs — making a mark and editing
  one — because the address is already right and is there to be corrected, not
  filled in. An existing name arrives selected, so typing replaces it. So ⌘D,
  Return stays two keystrokes: Return in the name saves outright.
- Return in the **address** confirms the address rather than the whole bookmark:
  the field is rewritten as the row it names and the caret moves on to the name,
  and the next Return saves. A bookmark marks a row (§20.1), so an address inside
  a row means that row — and typing `0x3333` only to be told afterwards that the
  bookmark went to `0x3330` is the app changing the input behind the user's back.
  The field says where it is going before anything is saved.
- Dismissing the popover any other way — a click outside it — keeps what was
  typed. The mark is already on the row by then, so discarding the name would be
  the surprising outcome. A half-typed address is the one thing not kept: the
  bookmark stays on the row it was on, with the name.
- ⌘D on a row that is already marked removes the mark on the spot, with no
  popover: there is nothing to name.
- A **double click on an address** in the Offset column opens the edit popover on
  that row: it marks the row first when it carries no mark — the mouse gesture for
  ⌘D — and edits the mark that is already there otherwise, which is how a mark is
  opened everywhere else (the list opens a name the same way, §20.5). What it
  never does is unmark: the pointer covers the mark it is aimed at, so a toggle
  here would silently take an existing bookmark away on a click landing a row off.
  The gesture belongs to the Offset column only — a double click in the hex or
  decoded-text columns still selects.
- The edit popover never outlives the mark it is editing. ⌘D's key equivalent
  reaches the menu through an open popover, so the row can be unmarked while its
  name is being typed; the popover then closes, saving nothing and undoing
  nothing. Any removal path does this, because it follows from the bookmark
  change itself, not from the command that caused it. Marking another row while
  a popover is open likewise replaces it rather than leaving two panels up.
- Edit ▸ Edit Bookmark… (⇧⌘D) opens the same popover on an existing mark, with
  its current name selected so typing replaces it; Esc leaves the bookmark
  exactly as it was, address and name. The command is enabled only when the
  caret's row carries a mark — ⌘D is how a mark is made, and it opens the same
  popover, so this one only ever edits.
- Toggle is enabled only when the active pane has a file open: with nothing open
  there is no caret row to mark.
- Because both panes read the same store, marking a row shows it at the same
  height in both panes of a comparison.
- The offset context menu (§10.2) carries the same two commands for the row that
  was right-clicked rather than the caret's, in the pane that was right-clicked:
  *Toggle Bookmark at «address»* — the same command ⌘D is, popover and all — and
  *Edit Bookmark…* on a row that has something to edit. The address in the
  title is the ROW's, because a right-click on a byte marks that byte's row, and
  the title is what makes that visible.
- Hovering a marked row's address shows the bookmark's **name**, and nothing
  else: the address is drawn under the pointer, on the mark itself, so a tooltip
  repeating it would explain a thing to itself. An unmarked row shows no tooltip,
  and neither does a marked row with no name — there is nothing to add. (The
  minimap's marks do say the address, because there the arrow only approximates
  it, §19.4.3.) The pane's accessibility value reads the name out with the
  caret's offset (§15).

20.4 Rendering a marked row (§6)

A marked row's address stands on a right-pointing arrow in the bookmark colour
(systemPurple — the palette is otherwise spoken for, red modified, orange
difference, accent caret, ink-blue addresses): the Offset column is filled with
the bookmark colour and its right end comes to a point into the gap before the
hex column, and the address is drawn over it in the colour for text on a filled
selection. The mark is a state of the Offset column, not of the byte cells, so it
is orthogonal to the difference, modification, and selection states (§6) and is
drawn on top of the column without disturbing them. Both panes draw it, because
both read the same store; in a comparison the shorter file's pane has no such row
to draw (§9).

The mark's body is the right-click focus ring's own rect — the Offset column
padded horizontally, with the same corner radius (§10.2) — so the mark and the
ring are one shape at one size. The tip is a blunt 120° point: it reads as a flag
beside the address rather than an arrow aimed at the bytes. Its reach follows from
the mark's height, which scales with the font, so the angle holds at every font
size; the reach is clamped to the gap before the hex column, which the tip must
never touch.

Right-clicking a marked row's address therefore does not draw the ring: the ring
on top of the fill is unreadable. Instead the mark itself becomes the ring — the
same shape stroked in the bookmark colour at the ring's line width, **dashed**,
with no fill — and the address keeps its ink colour while the menu is up, because
there is no longer a fill to read against. Dashed rather than solid because at
that line width a closed purple loop around an address reads as a slab: the
dashes say the row is marked and the menu is about it without shouting louder
than the fill they replace. The outline's path opens midway along an edge rather
than at a corner, or closing it draws a spur into that corner — a visible notch
on the mark. A menu opened on a *byte* of a marked row frames
that byte as usual (§10.2) and leaves the mark filled: only the address anchor
occupies the mark's rect.

20.5 The list

The bookmarks are listed in the lower half of the Go To form (§10.1), which is
the only place they are listed: going to a bookmark and managing one are the same
window, so nothing about a bookmark lives in two places.

- The list is **as tall as it has rows**, up to ten; past that it scrolls. A form
  that opened with a page of empty table over three bookmarks would be mostly
  nothing, and one that grew without limit would push its own buttons off the
  screen. An empty list keeps a few rows' worth of height, because its message
  needs room to be read.
- **The window is as tall as the form**, and follows it as rows come and go —
  nothing pins a minimum height, and no strip of nothing is left under the list.
  Its width is the user's to widen; the fields fill whatever it is.
- Two columns, one row per bookmark, ordered by address: the address in the
  **bookmark colour** (§20.4), and the name beside it. The bookmark colour rather
  than the dump's address ink, because in a list *of* bookmarks the address is
  what the purple mark in the Offset column and the purple arrow in the minimap
  point at — one colour ties the three together. It is written as bare padded hex
  digits, without the `0x` the dialogs use: a whole column of addresses in a
  window about addresses does not need each one announcing that it is hex. The
  column is exactly as wide as eight digits in the dump's font, so everything else
  on the row belongs to the name.
- **An unnamed bookmark is described by what is at it**: where its name would be,
  the list shows the row's bytes as the dump writes them, read from the ACTIVE
  pane — in a comparison the two files hold different bytes at the same address,
  and the list describes the one being worked in. That is what the row was marked
  for, and it is the one thing the address column does not already say. A row past
  the end of that pane's file says so in words instead: a bookmark is an absolute
  address and stays in the list where the file does not reach (§9), and "nothing
  there" is worth saying outright rather than leaving a blank cell. Both are shown
  the way a placeholder is — dimmed, and replaced the moment a name is typed.
- **Return** goes to the selected bookmark — the key the form's focus rule is
  built on (§10.1) — and dismisses the form, behaving exactly as a typed offset
  does: both panes of a comparison move, because a bookmark is an absolute offset
  (§8). The **Go To** button does the same for the mouse.
- A **double click on a row** opens that bookmark's editor, wherever in the row
  it lands: a double click opens what it lands on rather than acting on it, and
  the list's one keyboard gesture is already the jump.
- **A bookmark is edited in its own popover**, opened by a double click on its row
  or from the row's context menu (*Edit Bookmark…*) — the same popover ⇧⌘D opens on a mark in the dump (§20.3).
  One editor for a bookmark wherever it is edited from, and it can do what a name
  field in a row could not: change the address, and delete the bookmark. The list
  itself holds no editable fields, so every click in it means one thing — select
  the row, or, on a double click, activate it.
- Nothing in the list is renamed in place. A field inside a table row is edited by
  a click on an already-selected row, which collides with the double click that
  activates it, and it can only ever edit the one column it sits in. Sending the
  gesture to a menu command and the popover keeps both jobs whole.
- **Escape closes the editor before it closes the form**: editing a bookmark and
  pressing Escape must not throw the window away (§10.1).
- The selection belongs to a **bookmark**, and it is the form's state rather than
  the table's. A table view's selection is a row *number*, and a row number is a
  rendering detail: the list re-sorts when an address is edited, renumbers when a
  bookmark is made elsewhere, and forgets its selection outright on every reload.
  So the form keeps which bookmark is selected and tells the table; the table is
  the authority only at the moment the user picks a row. The selection therefore
  survives a reload and follows an edited bookmark to wherever the list re-sorts
  it. Only removing moves it: there the neighbour takes it, as `⌫` in the list
  leaves it. Return commits the name, a click elsewhere commits it too, and Escape
  restores the name the store holds without closing the form (§10.1).
- **⌫** removes the selected bookmark. The selection stays where it was, so a run
  of them can be cleared without reaching for the mouse between presses;
  removing the last row selects the one now at the end. With nothing selected
  neither key does anything.
- Opened by Option+Cmd+B the list arrives with its first bookmark selected — the
  command exists to go to a bookmark, and the list is ordered by address, so the
  lowest one is a real default. The jump still takes a Return: a selection is an
  offer, not an act. Opened by Cmd+G, which is about typing an address, the list
  offers nothing.
- **Empty state**: with no bookmarks the list says so and names the gesture that
  makes one (⌘D). It is a message over the table, not a row in it — a pseudo-row
  would answer ⌫ and Return as if it held a bookmark.
- A **name being edited** goes back to its resting colour, because the field
  editor draws its own white background over the row: a selected row's
  white-on-selection text would be white on white, and the name would vanish as
  it was typed.
- **Right-clicking a row** offers *Delete Bookmark*, acting on the row that was
  clicked as every context menu in the app does (§10.2). `⌫` does the same, but
  nothing on screen says so.
- On a **selected** row every cell reads as text on a selection, the address and
  the row preview included: the address is drawn in the dump's ink blue and the
  preview in a dim grey, and both are close to unreadable on the selection fill.
  AppKit does this for a plain label by itself; a colour set by hand has to follow
  the row's state by hand. The preview stays dimmer than a name even there — it is
  still a placeholder, not a value.
- The list follows the store (§20.2): a bookmark made or removed anywhere while
  the form is open appears in or disappears from it, and removing the last one
  brings the empty state back.

A toolbar button belongs here too, but the toolbar's composition — and this
item's icon — is a separate question, left for when the toolbar is filled out as
a whole.

20.6 Moving a mark

A mark can be dragged to another row: press and hold on it, and the bookmark
follows the pointer row by row until the button is released. (The same move by
keyboard is ⇧⌘D and a new address, §20.3.) It is the same act
as marking the right row in the first place, done a second time — a dump gets
read before it is understood, and a mark often turns out to belong a few rows
from where it was put. Dragging it there beats removing it and marking again,
which would lose its name.

- The mark is grabbed by pressing anywhere on its row's address: the mark fills
  that column (§20.4), so there is nothing else there to hit. The press also
  places the caret, as a press on an address always has — only a press that then
  travels to another row moves anything, so a click stays a click.
- The bookmark moves as the pointer crosses each row, not on release: what the
  drag is doing is visible while it is done, and the name travels with the mark.
- A step answers the pointer **crossing** into another row, and only that. Two
  points of hysteresis hold the boundary still, so a hand resting on the mouse
  cannot step the mark to and fro across a row edge; and the row already answered
  is never answered twice, which is what makes a jump over another mark final.
  (Re-reading the same row after a jump would compute the jump again, in the
  other direction, the mark now being on the far side of the obstacle — the mark
  would flicker instead of settling.)
- A drag pushed past the visible top or bottom edge autoscrolls the pane exactly
  as a drag selection does (§6), and the mark keeps moving while the pane scrolls
  — that is what makes it possible to drag a mark somewhere off screen.
- A drag inside the Offset column is never a selection, and a drag from an
  address that carries no mark is still the selection it has always been. The
  gesture belongs to the mark, not to the column.
- **One row holds one bookmark** (§20.1), so a mark dragged onto a marked row
  does not merge with it. It **jumps over** it, landing on the first free row
  beyond it in the direction of travel — one mark sliding past another. When the
  rows beyond are occupied all the way to the end of what the pane draws, the
  mark **stops before** the obstacle instead, on the last free row on the way
  there: it may neither leave the file to find room nor swallow the bookmark in
  its way, but it should still travel as far as the pointer took it. Only when
  even that room is missing does nothing move, and the pointer runs on ahead of a
  mark that stayed.
- A mark cannot be dragged off the file: the last row it can reach is the last
  row with bytes in it, and a pointer above the first row leaves it on row 0.
- Everything watching the store follows a move, because it is the store's own
  change signal that reports it (§20.2): both panes repaint the two rows
  involved, the open form's list re-sorts, and an edit popover on the row the
  mark left closes with it (§20.3).

=====================================================================
21. SEGMENTS
=====================================================================

A segmentation is a *partition* of the pane's content: pieces that are
contiguous, never overlap, and cover the file completely. The model is an
ordered list of **pieces**, each recorded by its opening offset and its name —
a cut is simply a piece's opening, other than the first piece's — and a gap or
an overlap is impossible by construction rather than by validation. Every open
file has at least one segment: itself, so the list is never empty. Nothing
about a segment changes the bytes; a partition is a way of *reading* a file,
and every operation that writes is explicit about it.

21.1 What a segment is

- A segment is a piece of the file's content: a contiguous, non-overlapping
  stretch that, with its neighbours, covers the whole file. A segmentation is a
  partition — an ordered list of pieces, each its opening offset and its name —
  so a gap or an overlap cannot be represented, let alone validated. A cut is a
  piece's opening, other than the first piece's: N pieces are N−1 cuts.
- A segment is the pane's, not the window's: it describes one file's make-up,
  and the other pane holds a different file. Swapping panes swaps them; closing
  a file drops its partition. That is the opposite of a bookmark (§20), which
  is the window's and serves both panes at once.
- **A mark never moves; a cut always does.** A bookmark is an address the user
  chose and must stay put (§20.1); a cut is the edge of a stretch of content
  and must travel with it. The case that proves it: append B to A, then insert
  C at the start, and the first seam moves.
- The label is positional — S0, S1, S2 … in file order — and renumbers whenever
  a cut is added or removed. Zero-based, like every other offset in the app
  (§10). Every segment always has one, so nothing is ever nameless.
- The name is optional and survives renumbering: rename a piece and add a cut
  before it later, and the piece keeps its name while its label changes. A
  segment with no name is still shown as its label, never blank. Two pieces may
  carry the same name — it describes, it does not identify; the label
  identifies.
- Segments are session-only: they live as long as the file is open. Closing the
  file drops its partition; nothing is persisted (a project file would change
  that, TODO).

21.2 The model

- A segment is a value: the piece's half-open byte range and a name; the label
  is derived from its position, never stored. It is built only by the partition
  that owns it, so a segment cannot be fabricated with boundaries no partition
  holds.
- The store keeps **pieces, not ranges**: each piece is its opening offset and
  its name, so the ranges and the labels are derived from the piece list and
  the file's size, and there is no second array to keep in step with the
  offsets. It answers the questions the panes ask — the piece containing an
  offset, the pieces in file order — and the editing verbs: add a cut
  (splitting the piece that contains it; the earlier piece keeps its name, the
  new one starts unnamed), remove a segment (dropping the piece and merging its
  bytes into a neighbour, which keeps its name — removing S0 reopens the piece
  below at the file start, so what was S1 becomes S0), move a cut (only within
  the interval it currently bounds, so it never jumps over another cut; the
  piece it opens keeps its name, which travels with the boundary), and rename a
  piece.
- **A snapshot is a frozen, self-consistent view.** The partition is an
  immutable value, and the store holds a `current` one; taking a snapshot — for
  undo, or to paint a page from one point in time — copies that value, so two
  pieces read from the same snapshot rest on the same boundaries even if the
  store moves on in between. A paint job takes `current` once and draws the
  whole page from it, so it cannot split across two boundaries if a cut lands
  mid-job.
- A cut is refused at 0, at EOF, or on an existing cut: every piece must stay
  non-empty.
- **Following the content.** A cut travels with the content — the opposite rule
  to a bookmark (§20.1). The store applies the same net edit the comparison
  index and the minimap consume (§8.3), with the file's size after the edit:
  - *overwrite* — nothing moves (the size may have grown, e.g. a paste past
    EOF).
  - *insert(at:length:)* — the cuts strictly after the insert shift by
    `+length`; a cut exactly at the insert stays, so the inserted bytes join
    the piece that *starts* there.
  - *delete(range:)* — a cut at or before the range's start stays; a cut
    strictly inside the range is swallowed, and the two pieces it separated
    merge into the one that starts before the deletion, which keeps its name;
    a cut at or after the range's end shifts by `−length`. A piece left with no
    bytes is dropped with its name, and the labels renumber.
- **Undo.** A cut's offset and name are not in the edit that removes it, so
  undo restores the partition by **snapshot**, not by inverse edit. The pane
  keeps a stack of snapshots parallel to the document's undo stack — one per
  committed transaction, captured before the edit lands, popped and restored on
  undo — with the same lifecycle the document's own stack has: cleared on open
  and revert, the redo side dropped on a divergent edit. This mirrors how the
  caret and the selection are restored (§7.5), one level up.
- One instance lives on the pane's view model, beside its document. The store
  holds no bytes and is AppKit-free, so its arithmetic is unit-testable in the
  app suite.

21.3 The tint

- **A pale tint behind the bytes.** Each piece fills its own rows with a muted,
  desaturated background — solid, and edge to edge: from the row's left edge,
  across the Offset column, through the gaps between the two 8-byte groups and
  before the decoded-text column, out to the row's right edge. The gaps take the
  colour of the piece they sit beside, which is what reads as one continuous
  stretch rather than a row of tinted cells; they are also what keeps the tint
  visible under a difference, because the orange fill paints byte cells only
  (§8.2) and leaves the gaps alone.
- **The Offset column is tinted too.** The band runs the full width of the row,
  so the column takes the colour of the piece beside it. The addresses, the
  bookmark's mark and the right-click ring (§20.4) are drawn on top of the tint,
  so the column stays legible and the mark is never swallowed by the fill.
- **A mid-row cut is drawn exactly**, byte by byte: the bytes before it keep the
  earlier piece's colour, the bytes after it take the next one's, and the step is
  visible inside the row where it belongs. The boundary passes through the middle
  of the gap between the two bytes it separates, and the two fills meet there —
  no uncoloured slit between them. A boundary is not obliged to land on the row
  grid, so nothing is rounded, dashed or apologised for.
- **Past EOF there is no tint**: no bytes, no piece. The EOF cue (§15) stands as
  it does today.
- **The layering, bottom to top** (an addition to §6's stack): segment tint,
  then the Offset column's addresses and the bookmark's mark, then the difference
  fill, the selection fill, and the text — modified bytes red, muted
  `0x00`/`0xFF` grey, the caret over everything. The bookmark's mark sits above
  the tint, so a mark on a tinted row is never swallowed by it. Selection and
  difference cover the tint, which is correct: what a byte *is* outranks which
  piece it belongs to, and the piece is still readable in the gaps and in the
  rows either side.
- **The status bar reads the caret's piece** as one block, `S1: <start>-<end>
  (length)` — the label, the piece's half-open range in bare hex (no `0x`
  prefix), and its size. The caret's offset is shown the same way, bare hex with
  no decimal. The block is absent when the pane is a single piece: its appearing
  is the signal that the dump is partitioned.
- **The palette** is a small set of pastels — light green, light pink, pale
  blue, pale yellow, lavender, peach — cycled by label, in the spirit of how
  Fusion 360 tints components: enough colour to tell one piece from the next,
  never enough to draw the eye. Six is plenty; a dump will not have more pieces
  than that in practice, and if it does the palette repeats, which is harmless
  because what has to be distinguishable is *neighbours*, not every pair. Four
  rules it has to satisfy, and each is a test rather than an opinion:
  1. *Background weight.* Barely off the paper: the tint sits under text, so its
     contrast with the paper is small and its contrast with the *ink* is what
     must survive — including the muted `0x00`/`0xFF` at 40 % alpha (§6), which
     is most of a dump.
  2. *Adjacent contrast.* Consecutive entries must be plainly different from
     each other, since that is what draws the boundary. Measured, not eyeballed:
     a minimum channel distance between neighbouring entries in the cycle.
  3. *No conflict with the states drawn over it.* An orange difference and the
     accent selection must still read as themselves on every tint, and no tint
     may be mistakable for either — so nothing in the orange band, nothing at
     the accent's saturation, and nothing close to the bookmark purple.
  4. *Two sets, one order.* A light-theme set and a dark-theme set of the same
     hues at the other end of the lightness range, resolved the way the rest of
     the colours resolve, so S1 is "the pink one" in both themes.
