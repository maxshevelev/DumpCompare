# Piece table: make insert/delete cost O(1) instead of a file copy

## The problem, measured

`EditOverlayStorage.insert` materializes the whole content into a fresh
temporary file on every call: prefix, inserted bytes, suffix. `delete` does the
same. So one typed byte in insert mode costs a full read plus a full write of the
file, whatever the offset:

| file | insert@0 | insert@middle | insert@EOF | overwrite |
|---|---|---|---|---|
| 1 MB | 6.7 ms | 5.3 ms | 5.7 ms | 0.028 ms |
| 8 MB | 25.5 ms | 26.2 ms | 24.9 ms | 0.010 ms |
| 32 MB | 86.6 ms | 84.9 ms | 89.1 ms | 0.012 ms |

Ten inserts into an 8 MB file: 24-32 ms each, and they leave **ten full copies**
of the file behind (80 MB) — `TemporaryFileStore` only cleans up when the
storage is deallocated. Every materialization also swaps in a fresh `ChunkCache`,
so the rows on screen are re-read from disk after each keystroke. All of it runs
synchronously on the main thread inside `doc.insert`.

`fsync` is not the problem (32 MB: 86.6 ms with, 78.4 ms without). The copy is.

## The shape of the fix

A piece table: the logical content is a list of pieces, each naming a range of
one of two immutable sources —

- **base**: the storage the file was opened from (`FileBackedStorage`,
  `MemoryBackedStorage` for an untitled document);
- **added**: an append-only buffer of bytes the user has typed or pasted.

Inserting splits a piece and adds one; deleting drops or trims pieces;
overwriting is a delete plus an insert. Nothing copies the file. Reading walks
the pieces that intersect the requested window and copies from the two sources —
the base still through its chunk cache, so large files stay unloaded.

This keeps `EditOverlayStorage`'s public surface exactly as it is
(`ByteStorage`, `EditableByteStorage`, `originalURL`, `canPatchInPlace`,
`changedRanges`, `isDirty`, `rebaseOriginalURL`), so `BinaryDocument`,
`StorageSaver`, `PaneViewModel` and the diff/search engines are untouched.

## Design

### 1. `PieceTable` — a pure value type

```swift
struct PieceTable {
    enum Source { case base, added }
    struct Piece { var source: Source; var start: UInt64; var length: UInt64 }
    struct Segment { var source: Source; var range: Range<UInt64> }   // in source coords

    init(baseSize: UInt64)
    var size: UInt64 { get }
    var pieceCount: Int { get }

    /// The source segments covering a logical window, in order.
    func segments(in range: Range<UInt64>) -> [Segment]
    /// Logical ranges backed by `added` — the overwritten ranges, while no
    /// length-changing edit has happened (see `changedRanges` below).
    var addedRanges: [Range<UInt64>] { get }

    mutating func insert(at offset: UInt64, addedRange: Range<UInt64>)
    mutating func delete(_ range: Range<UInt64>)
    mutating func replace(_ range: Range<UInt64>, with addedRange: Range<UInt64>)
}
```

No I/O, no locks: a list of pieces and the arithmetic on it, unit-testable on
its own. Piece lookup is a binary search over a cached prefix-sum of lengths,
rebuilt on mutation (O(pieces), not O(bytes)).

**Coalescing.** Typing must not grow the list by one piece per keystroke: an
insert whose added bytes continue the previous added piece *and* whose offset is
that piece's end extends the piece in place. A typed run is one piece.

### 2. `EditOverlayStorage` on top of it

```
base: any ByteStorage        // immutable, chunk-cached, never swapped by an edit
added: [UInt8]               // append-only
table: PieceTable
didLengthChange: Bool        // unchanged meaning: an offset-shifting edit happened
```

- `read(at:length:)`: `table.segments(in:)`, then copy from `base.read` /
  `added`. Same signature, same clamping, same thread safety (the existing
  `NSLock` stays).
- `overwrite(range:with:)`: append to `added`, `table.replace`. Past EOF it
  extends the file, and a gap between EOF and the write is filled with zeros
  through `added` — matching today's behaviour, where the unwritten gap reads as
  zeros.
- `insert` / `delete`: append (for insert) and `table.insert` / `table.delete`;
  set `didLengthChange`.
- `append`: `overwrite` at `size`.
- `changedRanges`: `table.addedRanges`. `StorageSaver` reads it only when
  `canPatchInPlace` (`!didLengthChange`) is true, and while no shift has
  happened a logical offset *is* the original file's offset, so the ranges mean
  what the in-place patch needs. (This is what `OverlayRangeMap` was for; it
  becomes dead code and goes.)
- `isDirty`: `didLengthChange || !table.addedRanges.isEmpty`.

### 3. Materialization stays, as a valve

`writeToNewBase` (the current full rewrite) is kept as `materialize()`: it
streams the current content into a temp file, makes that the base, and resets
the table to one piece. It is no longer on the keystroke path; it runs when

- a single insert is larger than `maxInlineInsert` (8 MB) — a big Paste Insert
  would otherwise sit in RAM, which is the one thing today's design does better;
- `added` grows past `maxAddedBytes` (64 MB) in a long session;
- the piece count passes `maxPieces` (100 000) — a safety valve against a
  pathological edit pattern making reads slow.

All three are amortized: one copy per many edits, instead of one per edit. The
temp file is also reused rather than accumulated — each materialization removes
the previous one (`TemporaryFileStore.replaceAll(with:)`), so the temp directory
holds at most one copy.

`fsync` on the materialized temp file goes: it is a throwaway file, and losing it
to a crash costs nothing that the crash did not already cost.

### 4. What this fixes beyond speed

- The chunk cache survives an edit, so the visible rows stay warm.
- The temp directory stops growing by one file copy per keystroke.
- Undo of an insert (a `delete`) is as cheap as the insert was.

### Out of scope

- Buffering typed input before it reaches the document (a separate story). With
  insert costing O(1) it is no longer needed for responsiveness.
- The comparison index's own O(n): `DiffEngine.apply` rescans `[offset, EOF)` on
  an insert. That runs in the `DiffIndexBuilder` actor, off the main thread, so
  it delays a fresh index rather than the keystroke. Untouched here.

## Stages

1. `PieceTable` + its tests (pure logic: splitting, coalescing, deleting across
   pieces, reading windows, `addedRanges`).
2. `EditOverlayStorage` rebuilt on it, `OverlayRangeMap` deleted. The existing
   core suite is the regression net — overwrite, insert, delete, save-in-place,
   save-as, revert, undo/redo all already have tests.
3. Materialization valve + temp-file reuse.
4. Re-measure and record the numbers here; add a test that pins the property
   that matters: N inserts into a large file create no per-insert file copies.

## Measured after the change

| file | insert@0 | insert@middle | insert@EOF | delete | overwrite |
|---|---|---|---|---|---|
| 1 MB | 0.046 ms | 0.006 ms | 0.007 ms | 0.007 ms | 0.011 ms |
| 8 MB | 0.017 ms | 0.007 ms | 0.005 ms | 0.005 ms | 0.006 ms |
| 32 MB | 0.030 ms | 0.014 ms | 0.008 ms | 0.011 ms | 0.013 ms |

Insert at the start of a 32 MB file: **86.6 ms → 0.030 ms**, and it no longer
depends on the file's size or on where in the file it lands.

A run of 200 typed bytes into a 32 MB file: 0.89 ms in total (0.0045 ms per
byte), 3 pieces, **0 temporary files** — the same run used to write 200 full
copies of the file, 6.4 GB, and to take about 17 seconds of blocked main thread.
A 4 KB window read after that run costs 0.158 ms, cold cache included.

## Verification

- `swift test` in `DumpCompareCore` (the storage suite is there), then the app
  suite for the editing paths.
- The measurement from the top of this file, repeated: insert cost must become
  independent of file size, and the temp directory must hold at most one copy.
