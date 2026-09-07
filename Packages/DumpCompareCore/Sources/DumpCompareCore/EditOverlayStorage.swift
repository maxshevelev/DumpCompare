import Foundation

/// An editable byte stream layered over a read-only base (decision D3).
///
/// The content is a `PieceTable` over two immutable sources: the base the
/// document was opened from, and an append-only buffer holding the bytes editing
/// has added. Every edit — overwrite, insert, delete — is a change to the piece
/// list, so it costs the same wherever in the file it lands and whether the file
/// is a kilobyte or 32 megabytes.
///
/// This replaced a design that materialized the whole content into a fresh
/// temporary file on every length-changing edit. That cost a full read plus a
/// full write per typed byte (25 ms on 8 MB, 87 ms on 32 MB, the same at either
/// end of the file), left one full copy of the file in the temp directory per
/// keystroke, and dropped the chunk cache each time.
///
/// Materializing still exists, but as an amortized valve instead of a per-edit
/// cost (see `Budgets`): an oversized insert, an add buffer past its budget, or
/// a piece list long enough to slow reads down collapses the table into a new
/// base file, and only one such file is kept at a time.
///
/// Saving is unchanged (§5.2): while no edit has shifted an offset, the added
/// ranges are still the original file's offsets, so `StorageSaver` can patch
/// them in place; after a shift the file is rewritten.
///
/// Thread safety: all state is guarded by a lock; reads and mutations may come
/// from any thread.
public final class EditOverlayStorage: EditableByteStorage, @unchecked Sendable {
    /// When the piece table gives way to a fresh base file. All three are
    /// amortized — one file copy per many edits — and injectable for tests.
    public struct Budgets: Sendable {
        /// An insert larger than this is materialized rather than held in the add
        /// buffer, so a large Paste Insert does not sit in memory.
        public var maxInlineInsert: Int
        /// Total size of the add buffer before it is folded into a new base.
        public var maxAddedBytes: Int
        /// Piece count before the list is collapsed: reads binary-search it, and
        /// a pathological edit pattern should not make them crawl.
        public var maxPieces: Int

        public init(maxInlineInsert: Int = 8 << 20,
                    maxAddedBytes: Int = 64 << 20,
                    maxPieces: Int = 100_000) {
            self.maxInlineInsert = maxInlineInsert
            self.maxAddedBytes = maxAddedBytes
            self.maxPieces = maxPieces
        }
    }

    private let lock = NSLock()
    private var base: any ByteStorage
    /// Append-only: the bytes typed or pasted, referenced by the table's added
    /// pieces. Never rewritten, so a piece's offsets stay valid for its life.
    private var added: [UInt8] = []
    private var table: PieceTable
    private var didLengthChange = false
    /// The lowest offset any insert or delete has moved bytes from, if one has.
    /// Everything at or after it sits at a different offset than it did in the
    /// file as opened, so it counts as changed even though editing never wrote
    /// there — which is what the panes show when they paint the whole tail of a
    /// file red after one inserted byte.
    private var shiftedFrom: UInt64?
    /// Ranges overwritten before a materialization folded them into the base.
    /// Without this, collapsing the table would erase the record an in-place
    /// save needs. Meaningful only while `didLengthChange` is false, which is
    /// the only state the save path reads it in.
    private var retainedChangedRanges: [Range<UInt64>] = []
    private let cache: ChunkCache
    private let tempStore: TemporaryFileStore
    private let budgets: Budgets
    /// True when the base is one nothing outside this storage can write: a temp
    /// file `materialize()` wrote, or a buffer handed in that only this storage
    /// holds. False for the user's own file, which the app's own save patches.
    /// What `contentSnapshot(scratch:)` reads to decide whether the base can be
    /// shared as it is (§23).
    private var baseIsPrivate: Bool

    /// The file this storage was opened from, when the base is file-backed.
    /// Used by `StorageSaver` to decide whether patching in place is safe: the
    /// on-disk bytes at untouched offsets still match the base only when saving
    /// to the very file the base reads from.
    public private(set) var originalURL: URL?

    public init(
        base: any ByteStorage,
        cache: ChunkCache = ChunkCache(),
        tempStore: TemporaryFileStore = TemporaryFileStore(),
        budgets: Budgets = Budgets()
    ) {
        self.base = base
        self.cache = cache
        self.tempStore = tempStore
        self.budgets = budgets
        self.table = PieceTable(baseSize: base.size)
        self.originalURL = (base as? FileBackedStorage)?.url
        // A file-backed base is the file the document was opened from, which
        // saving writes to; anything else is a buffer the caller built for this
        // storage alone.
        self.baseIsPrivate = !(base is FileBackedStorage)
    }

    deinit {
        tempStore.removeAll()
    }

    // MARK: - ByteStorage

    public var size: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return table.size
    }

    public func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return try readLocked(at: offset, length: length)
    }

    // MARK: - EditableByteStorage

    public func overwrite(range: Range<UInt64>, with bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        try overwriteLocked(bytes, at: range.lowerBound)
    }

    public func append(_ bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        try overwriteLocked(bytes, at: table.size)
    }

    public func insert(at offset: UInt64, bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let at = min(offset, table.size)
        table.insert(at: at, addedRange: appendToAddBuffer(bytes))
        didLengthChange = true
        shiftedFrom = min(shiftedFrom ?? at, at)
        try materializeIfNeeded(lastAddedSize: bytes.count)
    }

    public func delete(range: Range<UInt64>) throws {
        lock.lock()
        defer { lock.unlock() }
        let start = min(range.lowerBound, table.size)
        let end = min(range.upperBound, table.size)
        guard end > start else { return }
        table.delete(start..<end)
        didLengthChange = true
        shiftedFrom = min(shiftedFrom ?? start, start)
        try materializeIfNeeded(lastAddedSize: 0)
    }

    // MARK: - Save support

    /// Updates the file this storage's content is assumed to match. Called by
    /// the document layer after a Save As: the target now holds the current
    /// content, so later overwrite-only saves to it may patch in place.
    public func rebaseOriginalURL(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        originalURL = url
    }

    /// True when the storage holds only overwrites (no offset-shifting edit),
    /// so saving can patch the original file in place.
    /// The size of the base the table's offsets are written against. `StorageSaver`
    /// compares it with the base file's size on disk before a save: a base that
    /// has shrunk since it was opened cannot be read any more, and `read` pads
    /// the missing bytes with zeros to keep the offsets after them in place — so
    /// a save would write those zeros into the user's file and report success.
    public var baseSize: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return base.size
    }

    public var canPatchInPlace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didLengthChange
    }

    /// True when the storage holds any unsaved edit.
    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didLengthChange || !table.addedRanges.isEmpty || !retainedChangedRanges.isEmpty
    }

    /// Ranges whose bytes are not the bytes the base holds at those offsets.
    ///
    /// While nothing has shifted, that is exactly where editing wrote, and those
    /// offsets are still the file's own — which is what lets a save patch them in
    /// place. Once an insert or a delete has moved bytes, everything from that
    /// offset on holds different content than the file did there, so the tail is
    /// part of the answer; the save path does not use this in that state (it
    /// rewrites), but the minimap does, to know where a modified byte can be.
    public var changedRanges: [Range<UInt64>] {
        lock.lock()
        defer { lock.unlock() }
        var ranges = retainedChangedRanges + table.addedRanges
        if let from = shiftedFrom, from < table.size {
            ranges.append(from..<table.size)
        }
        return Self.merged(ranges)
    }

    /// How many pieces the content is currently described by — the cost of a
    /// read, and what the piece budget watches. For tests and diagnostics.
    public var pieceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return table.pieceCount
    }

    // MARK: - Snapshots (Duplicate, §23)

    /// An immutable view of the content as it is right now, for a second
    /// document to build its own overlay on (§23).
    ///
    /// No bytes are copied. An overlay only ever writes to its own piece table
    /// and add buffer, never to its base, so the whole common content can simply
    /// be shared: the snapshot freezes the piece list and the add buffer (Swift
    /// arrays — a value copy that diverges only when one side is written) and
    /// holds the base as it is. Nothing needs copying later either, on an edit or
    /// on a close: both documents keep their edits in their own overlay, and a
    /// `FileBackedStorage` holds its descriptor open, so a temp file unlinked
    /// under it (the next materialization, this storage's deinit) stays readable.
    ///
    /// The one thing that *can* change under a reader is the base when it is the
    /// user's own file, because the app's own save patches that file in place
    /// (§5.2) — the copy would then quietly stop being the bytes it was taken
    /// from. So a file-backed base is cloned first, into `scratch`:
    /// `clonefile(2)` on APFS is O(1) and occupies no disk until one side is
    /// written, which is exactly the copy-on-write wanted here — a later save to
    /// the file copies the blocks it touches and the clone keeps the originals.
    /// Where a clone is impossible (another filesystem, the file has gone) the
    /// content is folded into a private temp file instead — the same valve the
    /// budgets use — and that is shared.
    ///
    /// - Parameter scratch: the temporary store a clone is put in. It belongs to
    ///   the copy, not to this storage, so closing this document does not take
    ///   the copy's bytes with it.
    public func contentSnapshot(scratch: TemporaryFileStore) throws -> any ByteStorage {
        lock.lock()
        defer { lock.unlock() }
        if !baseIsPrivate {
            if let file = base as? FileBackedStorage,
               let clone = try? cloneBase(file, into: scratch) {
                // The clone holds the same bytes at the same offsets, so the
                // piece list needs no adjusting — only the base it points at
                // changes, and this storage keeps reading the user's file.
                return ContentSnapshot(base: clone, added: added, table: table)
            }
            try materialize()
        }
        return ContentSnapshot(base: base, added: added, table: table)
    }

    /// Clones the base's file into `scratch` and opens a storage over the clone.
    /// The clone gets a cache of its own: a `ChunkCache` is keyed by chunk index
    /// only, so one shared with the base would serve the wrong file's chunks.
    private func cloneBase(_ file: FileBackedStorage,
                           into scratch: TemporaryFileStore) throws -> FileBackedStorage {
        let url = try scratch.reserveTempURL()
        guard clonefile(file.url.path, url.path, 0) == 0 else {
            throw StorageError.writeFailed
        }
        return try FileBackedStorage(url: url, cache: ChunkCache(config: cache.config))
    }

    // MARK: - Internals

    /// Copies `bytes` into the add buffer and returns the range they occupy.
    private func appendToAddBuffer(_ bytes: [UInt8]) -> Range<UInt64> {
        let start = UInt64(added.count)
        added.append(contentsOf: bytes)
        return start..<UInt64(added.count)
    }

    private func overwriteLocked(_ bytes: [UInt8], at offset: UInt64) throws {
        guard !bytes.isEmpty else { return }
        // A write starting past EOF leaves a gap, and that gap has always read
        // as zeros. They go through the add buffer, so the gap is real content
        // rather than a hole in the table.
        if offset > table.size {
            let gap = Int(offset - table.size)
            table.insert(at: table.size,
                         addedRange: appendToAddBuffer([UInt8](repeating: 0, count: gap)))
        }
        let end = offset + UInt64(bytes.count)
        table.replace(offset..<end, with: appendToAddBuffer(bytes))
        try materializeIfNeeded(lastAddedSize: bytes.count)
    }

    private func readLocked(at offset: UInt64, length: Int) throws -> [UInt8] {
        try Self.read(at: offset, length: length, table: table, base: base, added: added)
    }

    /// Reads a window of the content a piece table describes over `base` and
    /// `added`. Static and stateless because the live storage is not its only
    /// reader: the immutable snapshots it hands out (§23) resolve their pieces
    /// through the very same code, so a copy can never read its bytes
    /// differently from the storage it was taken from.
    static func read(at offset: UInt64, length: Int,
                     table: PieceTable, base: any ByteStorage, added: [UInt8]) throws -> [UInt8] {
        guard length > 0, offset < table.size else { return [] }
        let count = min(UInt64(length), table.size - offset)
        var result = [UInt8]()
        result.reserveCapacity(Int(count))
        for segment in table.segments(in: offset..<(offset + count)) {
            switch segment.source {
            case .base:
                let wanted = Int(segment.range.count)
                let bytes = try base.read(at: segment.range.lowerBound, length: wanted)
                result.append(contentsOf: bytes)
                // The base is immutable, so a short read means the file was
                // truncated under us. Pad, so the bytes after it keep their
                // offsets instead of sliding left.
                if bytes.count < wanted {
                    result.append(contentsOf: [UInt8](repeating: 0, count: wanted - bytes.count))
                }
            case .added:
                result.append(contentsOf: added[Int(segment.range.lowerBound)..<Int(segment.range.upperBound)])
            }
        }
        return result
    }

    /// Folds the table into a fresh base file when a budget is exceeded. This is
    /// the old per-edit cost, now paid once per many edits.
    private func materializeIfNeeded(lastAddedSize: Int) throws {
        guard lastAddedSize > budgets.maxInlineInsert
                || added.count > budgets.maxAddedBytes
                || table.pieceCount > budgets.maxPieces else { return }
        try materialize()
    }

    /// Writes the current content into a new temporary file and makes it the
    /// base, leaving the table with a single piece and the add buffer empty.
    private func materialize() throws {
        let url = try tempStore.createTempURL()
        let handle = try FileHandle(forWritingTo: url)
        do {
            var offset: UInt64 = 0
            let total = table.size
            while offset < total {
                let step = min(UInt64(1024 * 1024), total - offset)
                let bytes = try readLocked(at: offset, length: Int(step))
                guard !bytes.isEmpty else { break }
                try handle.write(contentsOf: Data(bytes))
                offset += UInt64(bytes.count)
            }
            // No `synchronize()`: this is a scratch copy of state that also lives
            // in memory, and fsyncing it cost about a tenth of every edit.
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // The overwritten ranges are about to stop being visible in the table —
        // keep them, or an in-place save after a materialization would find
        // nothing to patch.
        if !didLengthChange {
            retainedChangedRanges = Self.merged(retainedChangedRanges + table.addedRanges)
        }
        // A ChunkCache is keyed by chunk index only, so one instance can never
        // serve two different files — sharing it across successive materialized
        // bases would serve stale chunks after the swap. Each materialized base
        // gets a fresh cache with the same budget; the old base is released.
        base = try FileBackedStorage(url: url, cache: ChunkCache(config: cache.config))
        // The new base is this storage's own file: nothing else writes it, so it
        // can be shared with a copy as it is (§23).
        baseIsPrivate = true
        added = []
        table = PieceTable(baseSize: base.size)
        // The previous materialization is dead weight now.
        tempStore.removeAll(except: url)
    }

    /// Sorts ranges and merges those that touch or overlap.
    private static func merged(_ ranges: [Range<UInt64>]) -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
