# DumpCompare

A macOS hex editor for binary dumps with a side-by-side comparison view. Open two files and
DumpCompare highlights every byte that differs — by absolute offset, with no block matching or
alignment — while still letting you edit either file directly.

Built with Swift + AppKit, macOS 14+. No third-party dependencies. Full requirements in
[`REQUIREMENTS.md`](REQUIREMENTS.md); the implementation plan (milestones M0–M7) is in
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).

## Features

- **Two file panes.** Open one or two files via **File > Open…** or drag-and-drop. With a single
  file open, the app runs in single-file mode; dropping on the half-panes replaces the current file
  or opens a second file for comparison.
- **Hex + ASCII grid.** 16 bytes per row, groups of 8, with a printable-ASCII column. Arrow keys,
  Home/End, Page Up/Down, and direct hex/ASCII typing; `0x`-style offsets everywhere.
- **Comparison by absolute offset.** Differing bytes get an orange background (including the shorter
  file's EOF-only tail). Jump between differences with **Next/Previous Difference**.
- **Editing.** Overwrite (paste, typing), insert, delete, fill-with-zero — with undo/redo per pane
  and confirmation before destructive operations. Unsaved bytes are shown in red with an underline;
  EOF cells carry a hatch pattern, so neither relies on color alone.
- **Large files.** Files are read through a bounded chunk cache (never loaded whole), edits are
  stored as a sparse overlay, and diff/search run incrementally in the background with a progress
  indicator. A 1 GB file stays well under ~10 MB of working-set overhead.
- **Robust lifecycle.** External-change detection, security-scoped sandbox bookmarks, dirty-state
  prompts on close/replace, and per-file Save/Save As/Revert.

## Build

Project files are generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from
`project.yml`; after adding source files, regenerate with `xcodegen generate`.

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

Storage layer (`DumpCompareCore`) → model (`BinaryDocument`, diff, search, undo) → view-models
(`PaneViewModel`, `WindowModel`) → AppKit views (`HexView`, `FilePaneView`, `ComparisonView`).
Domain code is pure Swift and unit-tested; all UI runs on the main actor, and long-running work
(diff, search) runs in background tasks.
