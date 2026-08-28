# DumpCompare

A macOS hex editor and binary-file comparator, written in Swift/AppKit for macOS 14+. Compare two files byte by byte — by absolute offset, no alignment tricks — and edit either one in place. No third-party dependencies.

DumpCompare grew out of bench work on BIOS and EC dumps, so the comparison model stays deliberately simple: a byte at offset N is compared to the byte at offset N, nothing more. That is exactly the question a repair bench asks — *is this chip's content the same as the one that works?* — and the app is built around answering it fast, on files of the size a programmer clip actually pulls off a board.

<img width="1541" height="799" alt="Screenshot 2026-08-21 at 23 15 39" src="https://github.com/user-attachments/assets/0ff1c54c-78b5-4f7c-94e4-53a005a782ed" />


## Download

[**DumpCompare 0.4**](https://github.com/maxshevelev/DumpCompare/releases/latest) — a universal `.dmg` (Apple silicon and Intel), macOS 14 or later.

The build is ad-hoc signed and not notarized, so Gatekeeper stops the first launch: right-click the app and choose **Open**, or clear the quarantine flag once.

```sh
xattr -dr com.apple.quarantine /Applications/DumpCompare.app
```

## On the bench

The workflows the app is shaped around:

- **Two reads of the same chip.** Read it twice, open both dumps, look at the summary: `0 differing` means the read is trustworthy. Anything else is a contact problem — a clip, a socket, a hot chip — not a firmware finding, and you learn it before you start diagnosing the board.
- **A dump against a known-good donor.** Differing bytes are filled orange; ⌘⌥→ / ⌘⌥← walk the differing regions and centre each one, so scrolling 16 MB by hand is not part of the job.
- **Finding the region that matters.** The overview minimap draws the whole chip in one column, shaded by how much real content each slice holds: erased `0xFF` blocks stay pale, code and tables read dense. A blanked, truncated or corrupted region shows up as the wrong texture at the wrong place — before you know its offset.
- **Keeping your place in it.** ⌘D marks the caret's row and offers it a name; the mark is a purple arrow in the Offset column and in the minimap's margin, so the header, the table and the region under investigation stay findable while you work between them.
- **Patching by hand.** ⌘G to the offset, type the hex digits, the changed bytes turn red until saved. Confirmations guard the operations that shift data.
- **Verifying a write-back.** Re-read the chip and compare the new dump against the file you flashed; the difference count is the pass/fail.
- **Chip-sized files, not toy files.** Files are read in chunks and never loaded whole, so a 16 MB SPI dump — or a 1 GB image — opens immediately and stays within a low double-digit megabyte working set.

## Features

### Comparison

- Two panes: open one or two files via **File > Open…** (⌘O) or drag-and-drop. One file — single-pane mode; two — comparison.
- Differing bytes get an orange fill, tuned for light and dark mode; the shorter file's EOF tail counts as a difference too. The status bar shows a live summary — `12 differing · 2048 same` — updating as you edit.
- **Next/Previous Difference** (⌘⌥→ / ⌘⌥←) and **Next/Previous Same Block** (⌘⌥⇧→ / ⌘⌥⇧←) centre each result. Navigation steps between *changes*, not bytes: differing bytes closer together than the grouping distance (64 bytes by default) are one target, so a rewritten NVRAM area is one press instead of hundreds while highlighting stays per byte.
- A selection in one pane is outlined in the other, so the two halves of the same offset read as one. **View > Toggle Pane Layout** (⌘⌥L) switches side-by-side and stacked; **Swap Panels** exchanges the two files without reopening them.

### Going somewhere, and coming back

- **Go To Position…** (⌘G) and **Bookmarks…** (⌥⌘B) are one window, because they answer one question: the addresses worth returning to are exactly the ones you would otherwise be typing again. ⌘G starts in the offset field, ⌥⌘B in the list; Return follows the focus. The field takes `0x`-hex or decimal, validates as you type, and keeps the last ten addresses it was sent to.
- **⌘D marks the caret's row** and opens a popover on the mark: type a name and Return, or just Return for an unnamed one. ⇧⌘D reopens it — the popover holds the bookmark's *address* as well as its name, so a mark put a row off is corrected by typing the right one, and a **Delete** button for the act Esc cannot mean.
- A marked row's address stands on a **purple arrow** in the Offset column, and a smaller one appears in the minimap's margin in both of its modes — a marked region is findable without opening anything. Hovering a mark on the map says `ADDRESS: name`; a click near one lands exactly on the bookmark.
- **Drag a mark to another row.** A dump gets read before it is understood, and a mark often belongs a few rows from where it was put; dragging beats remaking it, which would lose the name. One row holds one bookmark, so a mark dragged onto an occupied row jumps past it or stops before it.
- The list shows every mark by address, and **describes an unnamed one by what is at it** — the row's bytes as the dump writes them, read from the pane you are working in. Return jumps, a double click opens the editor, ⌫ removes.
- Bookmarks are absolute offsets, so one list serves both panes and marks the same height in both. They live as long as the window, not the file: closing a dump and opening it again — the same chip read twice — keeps its marks.

### Minimap

- A column beside the dumps, from the toolbar button or **View > Show Minimap** (⇧⌘M), with a **Local ⇄ Overview** switch in its header (⌘⌥M).
- **Local** is a miniature hex dump around the caret, one cell per byte. **Overview** is the whole file at once, one row per device pixel, each cell shaded by how much of its slice is real content rather than fill — which is what makes erased regions, tables and code distinguishable at a glance. The mode is chosen for the file you open, and a file the overview could only magnify greys that half of the switch out.
- Differences and unsaved edits are drawn over the shading and at least two pixels tall, so a single changed byte among millions stays visible. Two maps mirror the pane arrangement and share one scale: the same height is the same absolute offset in both.
- Drag the viewport marker to scroll, click elsewhere to go there, or roll the wheel over the panel. Rebuilds run off the main thread with progress in the status bar, and a resize rescales the picture in hand while the exact pixels are recomputed.

### Hex grid

- 16 bytes per row in two 8-byte groups; **View > Word Size** regroups them into 1/2/4/8-byte words. Three columns — address, hex, decoded text — under a pinned header.
- `0x00`/`0xFF` bytes are muted so significant data reads with more contrast; cells past EOF carry hatching, so the end of a file is readable without colour.
- Navigation like a text editor: arrows, Home/End, Page Up/Down, direct hex typing, and editing in the decoded-text column.

### Editing

- Type hex digits or text — bytes overwrite in place, with per-pane Undo/Redo (⌘Z / ⇧⌘Z). Modified bytes are drawn red until saved.
- **Insert Mode** (⌥⌘I) switches typing from overwrite to insertion: the byte lands at the caret, the tail shifts right, and Delete/Backspace remove bytes instead of zeroing them. The mode is per pane — one file can be typed into while the other is read — shown as `OVR`/`INS` in the status bar and by the caret's own shape. It shifts every offset from the caret on, so the first keystroke in each file asks once.
- Undo is segmented for typed input: the first ⌘Z takes back the last byte, a quick second takes back the rest of the run, and after a pause it is one byte per press again.
- **Paste Insert…**, **Delete Bytes…** and **Fill Selection with…** — the fast way to blank a region to `0xFF`. The confirmations for edits that shift the file can be turned off in **Settings ▸ Editing**.
- **File > New File** (⌘N) opens an empty in-memory document — somewhere to paste a block out of a dump; **Revert to Saved** throws away the session's edits.
- **File > Duplicate** copies the open dump — unsaved edits and all — into the second pane as an untitled document, so the file as it stands can be patched beside the original and every difference that appears is one you made. No bytes are copied: the two documents share the content until one of them is written, and on APFS the file behind them is cloned rather than duplicated, so duplicating a 32 MB dump costs neither the pass nor the disk.

### Search

- **Find** (⌘F): query history, an encoding popup (**Hex bytes**, **Text — ASCII**, **UTF-8**, **UTF-16 LE/BE**), a case toggle, and paired ‹ › buttons. Searches run in the background and centre their result.
- **Search All** lists every occurrence in a panel beside the dump, filling as the scan streams matches in; offsets and excerpts follow later edits.

### Toolbar

- Icon-only and fixed: **Go To**, **Find** and **Segments** on the left, then the two controls worth seeing rather than clicking — the **insert-mode** toggle, lit while typing shifts the file, and the **word size**, a menu button that says "2 Bytes". On the right: the difference arrows (or the *Files are identical* badge), the **pane layout** toggle, whose icon shows the arrangement the click will produce, and the **minimap** toggle. File operations are not there on purpose — dumps arrive by drop, and ⌘S saves them.

### Selection, clipboard, menus

- Mouse selection, ⌘A, **Select Block…** (start + end, or start + length). **Copy** puts both raw bytes and hex text on the clipboard; ⌘V overwrites bytes from it.
- Right-click an address for **Copy offset** (no `0x`, so a prefixed field doesn't double it), **Select block from here** (prefilled), and the bookmark commands for *that* row. Right-click inside a selection for **Copy**, **Fill Selection with…**, **Delete Bytes** — applied to the clicked pane's selection, not the active pane's.
- Every offset field accepts `0x`-hex or decimal, puts the caret behind the prefix instead of selecting the whole text, and validates on each keystroke, with the message under the field it belongs to.

### Large files, and the rest

- Files are read through a bounded chunk cache and never loaded whole; edits are a piece list over the file as opened, so an inserted byte costs nothing measurable on a 32 MB dump. Diff and search index incrementally in the background, with progress and a cancel button in the status bar.
- **⌘,** opens a standard settings window: the monospaced font and row density, the grouping distance for diff navigation, and the text decoding table (Windows-1252 by default) with a live grid of all 256 byte values.
- External changes on disk are detected and offer a reload, keeping local edits; closing a dirty file prompts the standard Save / Don't Save / Cancel. Security-scoped bookmarks keep file access across launches.
- Light and dark themes, all colours dynamic; state is carried by colour *and* form (EOF hatching, outline contours), so it survives a theme switch and colour blindness. Accessibility labels on the grid and document state, frame autosave, **Window > Zoom** to fit the content exactly.

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

The app icon — a black flash package on a transparent ground, five leads above and below, `A5` beside a `FF` marked as a difference — is generated rather than drawn by hand: `Design/AppIcon.swift` renders the 1024 pt master and `Design/render-appicon.sh` slices it into the asset catalog.

## Tests

```sh
# Core (model/storage logic) — no AppKit required
swift test --package-path DumpCompareCore

# App (view-models, open placement, file watchers)
xcodebuild test -project DumpCompare.xcodeproj -scheme DumpCompare -destination 'platform=macOS'
```

## Architecture

Storage layer (`DumpCompareCore`) → model (`BinaryDocument`, diff, search, undo) → view-models (`PaneViewModel`, `WindowModel`) → AppKit views (`HexView`, `FilePaneView`, `ComparisonView`, `MinimapView`). Domain code is pure Swift and unit-tested; all UI runs on the main actor, and long-running work (diff, search, the overview map) runs in background tasks. The behaviour is specified in `Design/REQUIREMENTS.md`, and the design documents beside it record why each feature came out the way it did.
