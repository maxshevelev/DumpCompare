# DumpCompare

A macOS hex editor and binary-file comparator, written in Swift/AppKit for macOS 14+. Compare two files byte by byte — by absolute offset, no alignment tricks — and edit either one in place. No third-party dependencies.

DumpCompare grew out of bench work on BIOS and firmware dumps, so the comparison model stays deliberately simple: a byte at offset N is compared to the byte at offset N, nothing more. If you work with such dumps on macOS, it may spare you the usual chore of eyeballing two hex columns side by side.

## Features

### Comparison

- Two panes: open one or two files via **File > Open…** (⌘O) or drag-and-drop. One file — single-pane mode; two — comparison.
- Differing bytes get an orange fill, with theme-appropriate intensities for light and dark mode; the shorter file's EOF tail counts as a difference too.
- The status bar shows a live summary — `12 differing · 2048 same` — updating as you edit.
- **Next/Previous Difference** (⌘⌥→ / ⌘⌥←) and **Next/Previous Same Block** (⌘⌥⇧→ / ⌘⌥⇧←): forward lands on a block's start, backward on its last byte, and the result is centered in the view.
- A selection in one pane is outlined in the other (mirror contour), so the two halves of the same offset read as one.

### Hex grid

- 16 bytes per row, split into two 8-byte groups; **View > Word Size** regroups the bytes into 1/2/4/8-byte words (16/32/64-bit reads).
- Three columns: address (Offset), hex values, decoded text. The column header is pinned above the dump and follows horizontal scrolling.
- `0x00`/`0xFF` bytes are muted so significant data reads with more contrast; offsets and headers use a quiet ink-blue.
- Navigation like a text editor: arrow keys, Home/End, Page Up/Down, direct hex-digit typing, and editing right in the decoded-text column.

### Editing

- Type hex digits or text — bytes overwrite in place, with per-pane Undo/Redo (⌘Z / ⇧⌘Z).
- ⌘V with the hex dump focused overwrites bytes from the clipboard (raw bytes are the primary format, hex text the fallback); ⌘V in a text field is the standard system paste.
- **Paste Insert…** inserts bytes with a shift (confirmed first), **Delete Bytes…** deletes with confirmation, **Fill Selection with…** repeats a pattern across the selection.
- Modified bytes are drawn red; cells past EOF carry hatching, so the end of the file is readable without color.

### Selection & clipboard

- Mouse selection, ⌘A, **Select Block…** (start + length), **Go To Position…** (⌘G).
- **Copy** puts both raw bytes and hex text on the clipboard.
- The status bar always shows the caret in hex and decimal, plus the selection length.

### Search

- **Find** (⌘F): a field with query history, an encoding popup (**Hex bytes**, **Text — ASCII**, **UTF-8**, **UTF-16 LE/BE**), a case toggle (disabled for hex — hex is always byte-exact), and paired ‹ › buttons.
- History entries record their encoding, so `"abcd" (Hex)` and `"abcd" (ASCII)` are distinct.
- Searches run in the background with a progress indicator; the result is centered in the pane.

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
- Everything primary has a key equivalent: ⌘N/⌘O/⌘S/⇧⌘S/⌘W, ⌘Z/⇧⌘Z, ⌘C/⌘V/⌘A, ⌘F/⌘G, ⌘,, diff navigation, ⌘⌃F for full screen.

## Native macOS

- AppKit and no dependencies — no Electron, no web wrapper.
- Light and dark themes out of the box; all colors are dynamic.
- Standard menus and key equivalents, a standard tabbed settings window, standard alert dialogs, SF Symbols in headers.
- **Window > Zoom** sizes the window to exactly fit the hex content; the top edge stays in place, so the window grows from the bottom.
- Accessibility labels on the grid and document state; frame autosave; multi-display aware.

## Requirements

- macOS 14.0 or later
- Builds from source with Xcode; no prebuilt .app is bundled

## Build

Project files are generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`; after adding source files, run `xcodegen generate`:

```sh
xcodegen generate
xcodebuild build -project DumpCompare.xcodeproj -scheme DumpCompare -destination 'platform=macOS'
```

## Tests

```sh
# Core (model/storage logic) — no AppKit required
swift test --package-path DumpCompareCore

# App (view-models, open placement, file watchers)
xcodebuild test -project DumpCompare.xcodeproj -scheme DumpCompare -destination 'platform=macOS'
```

## Architecture

Storage layer (`DumpCompareCore`) → model (`BinaryDocument`, diff, search, undo) → view-models (`PaneViewModel`, `WindowModel`) → AppKit views (`HexView`, `FilePaneView`, `ComparisonView`). Domain code is pure Swift and unit-tested; all UI runs on the main actor, and long-running work (diff, search) runs in background tasks.
