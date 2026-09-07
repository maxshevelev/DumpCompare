import Foundation
import XCTest
@testable import DumpCompareCore

/// §22 the join: a second file's bytes come into the document, at the start or
/// the end. The source is streamed in bounded chunks into one transaction, and
/// the result is an untitled, never-saved document that is dirty and must not
/// be silently discarded on close. The join is **undoable** (§22.2): the byte
/// insert is a normal transaction on the undo stack, and undoing it re-attaches
/// the document to the file it came from; the join stacks on top of any earlier
/// edits, which undo as usual.
final class BinaryDocumentJoinTests: XCTestCase {
    /// An in-memory document over `bytes`, attached to a (placeholder) file URL
    /// so the join has a file to detach from.
    private func makeDocument(_ bytes: [UInt8]) -> BinaryDocument {
        BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: bytes)),
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("join-\(UUID().uuidString).bin"),
            readOnly: false
        )
    }

    // MARK: - Where the bytes land

    /// A join at the start puts the source's bytes first, in order, and pushes
    /// the original content right — the seam is exact: the source's last byte
    /// sits next to the original's first.
    func testAJoinAtStartPutsTheSourceFirst() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))  // 10 11 … 1F
        let source = ArrayStorage([0xA0, 0xA1, 0xA2])

        try doc.join(contentsOf: source, at: .start)

        XCTAssertEqual(doc.size, 19)
        XCTAssertEqual(try doc.read(at: 0, length: 19),
                       [0xA0, 0xA1, 0xA2] + [UInt8](0x10..<0x20))
        XCTAssertEqual(try doc.read(at: 2, length: 3), [0xA2, 0x10, 0x11],
                       "the seam: the source's last byte, then the original's first two")
    }

    /// A join at the end leaves the original content in place and appends the
    /// source's bytes after it.
    func testAJoinAtEndAppendsTheSource() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        let source = ArrayStorage([0xA0, 0xA1, 0xA2])

        try doc.join(contentsOf: source, at: .end)

        XCTAssertEqual(doc.size, 19)
        XCTAssertEqual(try doc.read(at: 0, length: 19),
                       [UInt8](0x10..<0x20) + [0xA0, 0xA1, 0xA2])
        XCTAssertEqual(try doc.read(at: 15, length: 3), [0x1F, 0xA0, 0xA1],
                       "the seam: the original's last byte, then the source's first two")
    }

    /// Two joins in a row: the second joins the already-joined (already
    /// untitled) document, and the bytes stack in the order the joins asked for.
    func testTwoJoinsInARowStackInOrder() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))

        try doc.join(contentsOf: ArrayStorage([0xA0]), at: .start)
        try doc.join(contentsOf: ArrayStorage([0xB0]), at: .end)

        XCTAssertEqual(try doc.read(at: 0, length: 18),
                       [0xA0] + [UInt8](0x10..<0x20) + [0xB0])
    }

    // MARK: - One transaction

    /// A source bigger than one chunk is still one undo transaction: the edit
    /// group coalesces the chunks into a single commit, so `onTransactionCommitted`
    /// fires exactly once and every byte lands at its own offset.
    func testAMultiChunkJoinIsOneTransaction() throws {
        let size = 1024 * 1024 + 1  // just over one 1 MiB chunk: two chunks
        let doc = makeDocument([UInt8](0x10..<0x20))
        let source = ArrayStorage((0..<size).map { UInt8($0 % 251) })
        var commits = 0
        doc.onTransactionCommitted = { commits += 1 }

        try doc.join(contentsOf: source, at: .start)

        XCTAssertEqual(commits, 1, "the whole multi-chunk join is one transaction")
        let expected = (0..<size).map { UInt8($0 % 251) } + [UInt8](0x10..<0x20)
        XCTAssertEqual(try doc.read(at: 0, length: expected.count), expected,
                       "every byte lands at its own offset")
    }

    // MARK: - The add-buffer budget

    /// A source that overflows the overlay's inline budget makes the storage
    /// fold itself into a fresh base mid-join. The join survives the folding:
    /// every byte still lands, and the fold's temp file proves it happened.
    func testAJoinLargerThanTheAddBufferBudgetStillLands() throws {
        let size = 1024 * 1024 + 1  // two chunks: 1 MiB, then 1 byte
        let store = TemporaryFileStore()
        let directory = try storeDirectory(store)
        let budgets = EditOverlayStorage.Budgets(maxInlineInsert: 512 * 1024,
                                                 maxAddedBytes: 64 << 20,
                                                 maxPieces: 100_000)
        let storage = EditOverlayStorage(
            base: MemoryBackedStorage(bytes: [UInt8](0x10..<0x20)),
            tempStore: store, budgets: budgets)
        let doc = BinaryDocument(
            storage: storage,
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("join-\(UUID().uuidString).bin"),
            readOnly: false
        )
        let source = ArrayStorage((0..<size).map { UInt8($0 % 251) })

        try doc.join(contentsOf: source, at: .start)

        XCTAssertEqual(try doc.read(at: 0, length: size + 16),
                       (0..<size).map { UInt8($0 % 251) } + [UInt8](0x10..<0x20),
                       "the folding lost no bytes")
        XCTAssertGreaterThanOrEqual(tempFileCount(directory), 1,
                                    "the oversized chunk was folded into a fresh base mid-join")
    }

    /// Files a temporary store has on disk right now.
    private func tempFileCount(_ directory: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil)) ?? []).count
    }

    private func storeDirectory(_ store: TemporaryFileStore) throws -> URL {
        let probe = try store.createTempURL()
        try? FileManager.default.removeItem(at: probe)
        return probe.deletingLastPathComponent()
    }

    // MARK: - The refusal

    /// An empty source is refused before anything changes: no bytes, no
    /// detachment, no dirty state — joining nothing would only turn the file
    /// into an untitled copy of itself.
    func testAnEmptySourceIsRefusedAndChangesNothing() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        let originalURL = doc.url

        XCTAssertThrowsError(try doc.join(contentsOf: ArrayStorage([]), at: .start)) { error in
            XCTAssertEqual(error as? JoinError, JoinError.emptySource)
        }
        XCTAssertEqual(try doc.read(at: 0, length: 16), [UInt8](0x10..<0x20))
        XCTAssertEqual(doc.size, 16)
        XCTAssertEqual(doc.url, originalURL, "a refused join does not detach")
        XCTAssertFalse(doc.isDirty, "a refused join makes nothing dirty")
        XCTAssertFalse(doc.canUndo)
    }

    // MARK: - The joined document is never-saved

    /// The join detaches the document from the file it came from: the result is
    /// untitled and writable and dirty, so a close warns instead of silently
    /// discarding the joined content. The history is **not** cleared — the join
    /// is one undoable step on top of any earlier edits (§22.2).
    func testTheJoinedDocumentIsNeverSavedAndDirty() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        try doc.overwrite(range: 0..<4, with: [0x01, 0x02, 0x03, 0x04])
        XCTAssertTrue(doc.canUndo, "an edit stands before the join")

        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1]), at: .end)

        XCTAssertTrue(doc.canUndo, "the join is an undoable step, not a history clear")
        XCTAssertFalse(doc.canRedo, "nothing has been undone yet")
        XCTAssertTrue(doc.isDirty, "the joined content is unsaved and must warn on close")
        XCTAssertFalse(doc.isAttached, "the join detaches from the file")
        XCTAssertEqual(doc.url.lastPathComponent, "Untitled",
                       "the result is untitled, mirroring a New File")
        XCTAssertFalse(doc.readOnly)
    }

    // MARK: - Undo / redo of the join (§22.2)

    /// Undoing the join removes the inserted bytes **and** re-attaches the
    /// document to the file it came from — the pane looks exactly as it did
    /// before the join.
    func testUndoingAJoinReattachesToTheOriginalFile() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        let originalURL = doc.url
        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1]), at: .end)

        XCTAssertFalse(doc.isAttached)
        XCTAssertEqual(doc.size, 18)

        try doc.undo()

        XCTAssertTrue(doc.isAttached, "undoing the join re-attaches to the file")
        XCTAssertEqual(doc.url, originalURL, "the original file is restored")
        XCTAssertEqual(doc.size, 16, "the joined bytes are removed")
        XCTAssertEqual(try doc.read(at: 0, length: 16), [UInt8](0x10..<0x20),
                       "the original content is back")
    }

    /// Redoing the join re-inserts the bytes and re-detaches the document — the
    /// inverse of the undo.
    func testRedoingAJoinRedetaches() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1]), at: .end)
        try doc.undo()
        XCTAssertTrue(doc.isAttached)

        try doc.redo()

        XCTAssertFalse(doc.isAttached, "redoing the join re-detaches")
        XCTAssertEqual(doc.url.lastPathComponent, "Untitled")
        XCTAssertEqual(doc.size, 18, "the joined bytes are back")
        XCTAssertEqual(try doc.read(at: 0, length: 18),
                       [UInt8](0x10..<0x20) + [0xA0, 0xA1])
    }

    /// The join stacks on top of earlier edits: undoing the join reverts it
    /// (and re-attaches), and a further undo reverts the earlier edit, landing
    /// back at the saved state.
    func testAJoinStacksOnTopOfEarlierEdits() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        try doc.overwrite(range: 0..<2, with: [0x01, 0x02])   // an earlier edit
        try doc.join(contentsOf: ArrayStorage([0xA0]), at: .end)

        // Undo the join: the joined byte is removed and the file is re-attached,
        // but the earlier edit still stands.
        try doc.undo()
        XCTAssertTrue(doc.isAttached)
        XCTAssertEqual(doc.size, 16)
        XCTAssertEqual(try doc.read(at: 0, length: 2), [0x01, 0x02],
                       "the earlier edit still stands after the join is undone")

        // Undo the earlier edit: back to the saved state, clean.
        try doc.undo()
        XCTAssertEqual(try doc.read(at: 0, length: 2), [0x10, 0x11],
                       "the earlier edit is undone after the join")
        XCTAssertFalse(doc.isDirty, "back at the saved state, the document is clean")
        XCTAssertTrue(doc.isAttached)
    }

    /// A join on a clean document makes it dirty — the join's transaction moves
    /// the state past the saved checkpoint, so a close warns.
    func testAJoinMakesACleanDocumentDirty() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        XCTAssertFalse(doc.isDirty, "a freshly opened document is clean")
        try doc.join(contentsOf: ArrayStorage([0xA0]), at: .end)
        XCTAssertTrue(doc.isDirty, "the join's transaction makes the document dirty")
    }

    // MARK: - The caret (§22.5)

    /// A join at the end puts the caret at the seam — the old end, the start of
    /// the added part — as a bare caret, not a selection.
    func testAJoinAtEndPutsTheCaretAtTheSeam() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1, 0xA2]), at: .end)
        XCTAssertEqual(doc.selection.start, 16, "the caret is at the start of the added part")
        XCTAssertEqual(doc.selection.count, 0, "the caret is bare, not a selection")
    }

    /// A join at the start puts the caret at 0 — the start of the added part.
    func testAJoinAtStartPutsTheCaretAtZero() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1, 0xA2]), at: .start)
        XCTAssertEqual(doc.selection.start, 0, "the caret is at the start of the added part")
        XCTAssertEqual(doc.selection.count, 0)
    }

    /// Undoing the join returns the caret to where it was before the join.
    func testUndoingAJoinRestoresThePreJoinCaret() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        doc.setSelection(SelectionModel.empty(at: 5, fileSize: doc.size))
        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1]), at: .end)
        XCTAssertEqual(doc.selection.start, 16, "the join moved the caret to the seam")

        try doc.undo()

        XCTAssertEqual(doc.selection.start, 5, "undoing the join restores the pre-join caret")
    }

    /// Redoing the join brings the caret back to the seam — the same spot the
    /// forward join left it, not the bare end of the inserted bytes.
    func testRedoingAJoinRestoresTheSeamCaret() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        doc.setSelection(SelectionModel.empty(at: 5, fileSize: doc.size))
        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1]), at: .end)
        try doc.undo()
        XCTAssertEqual(doc.selection.start, 5, "the undo returned the pre-join caret")

        try doc.redo()

        XCTAssertEqual(doc.selection.start, 16, "redo puts the caret back at the seam")
    }

    /// Two joins in a row, then undo both: the document is byte-identical to the
    /// file it came from, so it must be attached to that file again. One slot for
    /// the pre-join attachment held only the SECOND join's — which by then was
    /// the placeholder the first join left — so undoing everything gave back the
    /// bytes and kept the document detached, with Save asking for a location for
    /// content that already had one.
    func testUndoingTwoJoinsReattachesTheOriginalFile() throws {
        let doc = makeDocument([0x11, 0x22])
        let original = doc.url

        try doc.join(contentsOf: ArrayStorage([0xAA]), at: .end)
        try doc.join(contentsOf: ArrayStorage([0xBB]), at: .end)
        XCTAssertFalse(doc.isAttached, "each join detaches")

        _ = try doc.undo()
        XCTAssertFalse(doc.isAttached, "the first join is still in force")
        XCTAssertEqual(try doc.read(at: 0, length: 3), [0x11, 0x22, 0xAA])

        _ = try doc.undo()
        XCTAssertEqual(try doc.read(at: 0, length: 2), [0x11, 0x22])
        XCTAssertEqual(doc.url, original, "the file it came from is back")
        XCTAssertTrue(doc.isAttached)

        // And redoing walks the attachment back out again, join by join.
        _ = try doc.redo()
        XCTAssertFalse(doc.isAttached)
        XCTAssertEqual(try doc.read(at: 0, length: 3), [0x11, 0x22, 0xAA])
        _ = try doc.redo()
        XCTAssertFalse(doc.isAttached)
        XCTAssertEqual(try doc.read(at: 0, length: 4), [0x11, 0x22, 0xAA, 0xBB])

        _ = try doc.undo()
        _ = try doc.undo()
        XCTAssertEqual(doc.url, original, "and undoing again gives it back once more")
    }

    // MARK: - Joining a document to itself

    /// A document can be joined to its own storage — the same bytes twice.
    ///
    /// This is the case that cannot be written naively: the source is the
    /// storage being written to, so its size grows with every chunk. A loop that
    /// reads "until the end of the source" never reaches it, and the document
    /// grows until the disk stops it. The size is therefore taken once, before
    /// anything is written.
    func testAppendingADocumentToItselfDoublesIt() throws {
        let document = makeDocument([0x01, 0x02, 0x03, 0x04])

        try document.join(contentsOf: document.storage, at: .end)

        XCTAssertEqual(document.size, 8)
        XCTAssertEqual(try document.read(at: 0, length: 8),
                       [0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04])
    }

    /// Inserting at the start moves the original bytes right as it goes, so a
    /// self-join has to follow them: byte `k` is at `k + inserted` by the time it
    /// is read. Without that the second half comes out as a copy of the first
    /// chunk over and over.
    func testInsertingADocumentIntoItsOwnStartDoublesIt() throws {
        let document = makeDocument([0xAA, 0xBB, 0xCC, 0xDD])

        try document.join(contentsOf: document.storage, at: .start)

        XCTAssertEqual(document.size, 8)
        XCTAssertEqual(try document.read(at: 0, length: 8),
                       [0xAA, 0xBB, 0xCC, 0xDD, 0xAA, 0xBB, 0xCC, 0xDD])
    }

    /// The same, over more than one chunk, so the offset arithmetic is exercised
    /// rather than a single read that happens to cover everything.
    func testASelfJoinIsCorrectAcrossSeveralChunks() throws {
        let size = BinaryDocument.joinChunkSize + BinaryDocument.joinChunkSize / 2
        // Every byte distinct within a chunk, so a chunk read from the wrong
        // offset cannot look like the right one.
        let bytes = (0..<size).map { UInt8($0 % 251) }
        let document = makeDocument(bytes)

        try document.join(contentsOf: document.storage, at: .start)

        XCTAssertEqual(document.size, UInt64(size * 2))
        // The whole content, not samples of it: sampling passed even with the
        // offset correction removed, because the places sampled happened to hold
        // the right bytes either way.
        XCTAssertEqual(try document.read(at: 0, length: size * 2), bytes + bytes)
    }

    /// A self-join is one undo step, like any other join.
    func testASelfJoinUndoesInOneStep() throws {
        let document = makeDocument([0x10, 0x20])

        try document.join(contentsOf: document.storage, at: .end)
        XCTAssertEqual(document.size, 4)

        try document.undo()

        XCTAssertEqual(document.size, 2)
        XCTAssertEqual(try document.read(at: 0, length: 2), [0x10, 0x20])
    }
}
