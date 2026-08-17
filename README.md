# DumpCompare

A macOS hex editor and binary-file comparator, written in Swift/AppKit for macOS 14+. Compare two files byte by byte — by absolute offset, no alignment tricks — and edit either one in place. No third-party dependencies.

DumpCompare grew out of bench work on BIOS and EC dumps, so the comparison model stays deliberately simple: a byte at offset N is compared to the byte at offset N, nothing more. That is exactly the question a repair bench asks — *is this chip's content the same as the one that works?* — and the app is built around answering it fast, on files of the size a programmer clip actually pulls off a board.

## Download

[**DumpCompare 0.1**](https://github.com/maxshevelev/DumpCompare/releases/latest) — a universal `.dmg` (Apple silicon and Intel), macOS 14 or later.

The build is ad-hoc signed and not notarized, so Gatekeeper stops the first launch: right-click the app and choose **Open**, or clear the quarantine flag once.

```sh
xattr -dr com.apple.quarantine /Applications/DumpCompare.app
```

## On the bench

The workflows the app is shaped around:

- **Two reads of the same chip.** Read it twice, open both dumps, look at the summary: `0 differing` means the read is trustworthy. Anything else is a contact problem — a clip, a socket, a hot chip — not a firmware finding, and you learn it before you start diagnosing the board.
- **A dump against a known-good donor.** Differing bytes are filled orange; ⌘⌥→ / ⌘⌥← walk the differing regions and centre each one, so scrolling 16 MB by hand is not part of the job.
- **Finding the region that matters.** The overview minimap draws the whole chip in one column, shaded by how much real content each slice holds: erased `0xFF` blocks stay pale, code and tables read dense. A blanked, truncated or corrupted region shows up as the wrong texture at the wrong place — before you know its offset.
- **Patching by hand.** ⌘G to the offset, type the hex digits, the changed bytes turn red until saved. Confirmations guard the operations that shift data.
- **Verifying a write-back.** Re-read the chip and compare the new dump against the file you flashed; the difference count is the pass/fail.
- **Chasing a string or a signature.** Search hex bytes or text in several encodings, or list every occurrence at once in a results panel.
- **Chip-sized files, not toy files.** Files are read in chunks and never loaded whole, so a 16 MB SPI dump — or a 1 GB image — opens immediately and stays within a low double-digit megabyte working set.

## Features

### Comparison

- Two panes: open one or two files via **File > Open…** (⌘O) or drag-and-drop. One file — single-pane mode; two — comparison.
- Differing bytes get an orange fill, with theme-appropriate intensities for light and dark mode; the shorter file's EOF tail counts as a difference too.
- The status bar shows a live summary — `12 differing · 2048 same` — updating as you edit.
- **Next/Previous Difference** (⌘⌥→ / ⌘⌥←) and **Next/Previous Same Block** (⌘⌥⇧→ / ⌘⌥⇧←): forward lands on a block's start, backward on its last byte, and the result is centered in the view.
- A selection in one pane is outlined in the other (mirror contour), so the two halves of the same offset read as one.
- **View > Toggle Pane Layout** (⌘⌥L) switches side-by-side and stacked; **Swap Panels** exchanges the two files without reopening them.

### Minimap

- A column beside the dumps, from the toolbar button at the far right or **View > Show Minimap** (⇧⌘M). Its header carries a **Local ⇄ Overview** switch (also **View > Minimap Overview**, ⌘⌥M); its status bar carries the progress of a rebuild.
- **Local** mode is a miniature hex dump around the caret: one cell per byte, three points per row, so what you see there is literally the rows of the dump.
- **Overview** mode is the whole file at once — one row per device pixel. Each cell is shaded by how much of its slice is real content rather than fill, which is what makes erased regions, tables and code distinguishable at a glance.
- Differences and unsaved edits are drawn over the shading and at least two pixels tall, so a single changed byte among millions stays visible.
- Two maps mirror the pane arrangement, and their rows are binned over the comparison's whole extent: the same height is the same absolute offset on both, and a shorter file's tail is simply empty.
- The viewport is marked on the map; drag it to scroll, click elsewhere to move the caret there and centre the pane on it, or roll the wheel over the panel.
- The heavy work happens off the main thread: a rebuild reports progress in the status bar, and a resize rescales the picture immediately while the exact pixels are recomputed behind it.

### Hex grid

- 16 bytes per row, split into two 8-byte groups; **View > Word Size** regroups the bytes into 1/2/4/8-byte words (16/32/64-bit reads).
- Three columns: address (Offset), hex values, decoded text. The column header is pinned above the dump and follows horizontal scrolling.
- `0x00`/`0xFF` bytes are muted so significant data reads with more contrast; offsets and headers use a quiet ink-blue.
- Navigation like a text editor: arrow keys, Home/End, Page Up/Down, direct hex-digit typing, and editing right in the decoded-text column.

### Editing

- Type hex digits or text — bytes overwrite in place, with per-pane Undo/Redo (⌘Z / ⇧⌘Z).
- ⌘V with the hex dump focused overwrites bytes from the clipboard (raw bytes are the primary format, hex text the fallback); ⌘V in a text field is the standard system paste.
- **Paste Insert…** inserts bytes with a shift (confirmed first), **Delete Bytes…** deletes with confirmation, **Fill Selection with…** repeats a pattern across the selection — the fast way to blank a region to `0xFF`.
- Modified bytes are drawn red; cells past EOF carry hatching, so the end of the file is readable without color.
- **File > New File** (⌘N) opens an empty in-memory document — somewhere to paste a block out of a dump; **Revert to Saved** throws away the session's edits.

### Selection & clipboard

- Mouse selection, ⌘A, **Select Block…** (start + length), **Go To Position…** (⌘G).
- **Copy** puts both raw bytes and hex text on the clipboard.
- The status bar always shows the caret in hex and decimal, plus the selection length.

### Search

- **Find** (⌘F): a field with query history, an encoding popup (**Hex bytes**, **Text — ASCII**, **UTF-8**, **UTF-16 LE/BE**), a case toggle (disabled for hex — hex is always byte-exact), and paired ‹ › buttons.
- History entries record their encoding, so `"abcd" (Hex)` and `"abcd" (ASCII)` are distinct.
- Searches run in the background with a progress indicator; the result is centered in the pane.
- **Search All** lists every occurrence in a panel beside the dump, filling as the scan streams matches in. Offsets and excerpts follow later edits, and the panel says whether the list is complete or was capped.

### Context menus

- Right-click an address or a byte: **Copy offset** and **Select block from here**. The clicked anchor is framed while the menu is open.
- **Copy offset** copies the address without the `0x` prefix, so pasting into an already-prefixed field doesn't double it.
- **Select block from here** opens the Select Block dialog prefilled, with the cursor in the length field.
- Right-click a byte inside a selection adds **Copy**, **Fill Selection with…**, **Delete Bytes** — applied to the clicked pane's selection, not the active pane's.

### Input dialogs

- Offset fields accept `0x`-hex and decimal; the caret lands after the prefix on focus instead of selecting the whole field.
- Validation re-runs on every keystroke: an error clears the moment the input becomes valid.

### Large files

- Files are read through a bounded chunk cache and never loaded whole; edits are stored as a sparse overlay on top of the file; diff and search index incrementally in the background.
- The active pane's status bar shows the operation name, progress, and a cancel button while indexing. A 1 GB file stays within a low double-digit megabyte working set.

### Settings

- **⌘,** opens a standard macOS settings window with toolbar tabs.
- **Appearance:** the monospaced font and row density; changes apply live to open dumps.
- **Text Decoding:** the decoding table (Windows-1252 by default, ISO-8859-1, Strict ASCII), a placeholder character for non-printable bytes, and a live grid of all 256 byte values.

### Reliability

- External changes to a file on disk are detected and offer a reload (keeping local edits if there are any).
- Security-scoped sandbox bookmarks keep file access across launches; closing or replacing a dirty file prompts the standard Save / Don't Save / Cancel dialog.
- The window frame is saved and restored; off-screen or degenerate frames are corrected on launch.

## Details

Mostly the small things that decide whether an editor is comfortable in daily use:

- The offset field never selects its whole text on focus — the caret waits after `0x`.
- Validation feedback is immediate and disappears as soon as the input is fixed.
- Copy offset omits the prefix, so pasting into a prefixed field yields no `0x0x`.
- Destructive operations confirm first; undo/redo work per pane.
- State is encoded by color and by form (EOF hatching, outline contours), so it survives color blindness and theme switching.
- The status bar keeps the readout scannable: caret in hex and decimal, selection length, file size, Modified / Read-Only, diff summary.
- Transient messages ("No match found.", "No more differences") replace the stats briefly, then yield back.
- Focus follows the workflow: back to the search field after a search, back to the dump after an edit.
- Everything primary has a key equivalent: ⌘N/⌘O/⌘S/⇧⌘S/⌘W, ⌘Z/⇧⌘Z, ⌘C/⌘V/⌘A, ⌘F/⌘G, ⌘,, diff navigation, ⇧⌘M for the minimap, ⌘⌥L for the layout, ⌘⌃F for full screen.

## Native macOS

- AppKit and no dependencies — no Electron, no web wrapper.
- Light and dark themes out of the box; all colors are dynamic.
- Standard menus and key equivalents, a standard tabbed settings window, standard alert dialogs, SF Symbols in headers.
- **Window > Zoom** sizes the window to exactly fit the hex content; the top edge stays in place, so the window grows from the bottom.
- Accessibility labels on the grid and document state; frame autosave; multi-display aware.

## Requirements

- macOS 14.0 or later
- Apple silicon or Intel — the release build is universal

## Build

Project files are generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`; after adding source files, run `xcodegen generate`:

```sh
xcodegen generate
xcodebuild build -project DumpCompare.xcodeproj -scheme DumpCompare -destination 'platform=macOS'
```

A universal release build, the way the `.dmg` is made:

```sh
xcodebuild build -project DumpCompare.xcodeproj -scheme DumpCompare \
  -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
```

The app icon is generated rather than drawn by hand: `Design/AppIcon.swift` renders the 1024 pt master and `Design/render-appicon.sh` slices it into the asset catalog.

## Tests

```sh
# Core (model/storage logic) — no AppKit required
swift test --package-path DumpCompareCore

# App (view-models, open placement, file watchers)
xcodebuild test -project DumpCompare.xcodeproj -scheme DumpCompare -destination 'platform=macOS'
```

## Architecture

Storage layer (`DumpCompareCore`) → model (`BinaryDocument`, diff, search, undo) → view-models (`PaneViewModel`, `WindowModel`) → AppKit views (`HexView`, `FilePaneView`, `ComparisonView`, `MinimapView`). Domain code is pure Swift and unit-tested; all UI runs on the main actor, and long-running work (diff, search, the overview map) runs in background tasks.
