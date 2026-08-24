import Foundation
import XCTest
@testable import DumpCompareCore

/// §22 the join: a second file's bytes come into the document, at the start or
/// the end. The source is streamed in bounded chunks into one transaction, and
/// the result is an untitled, never-saved document that is dirty with an empty
/// undo history — it cannot be undone (there is no prior state to return to)
/// but must not be silently discarded on close.
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
    /// untitled and writable, its history cleared (nothing to undo, nothing to
    /// redo) but still dirty, so a close warns instead of silently discarding
    /// the joined content.
    func testTheJoinedDocumentIsNeverSavedDirtyWithAnEmptyHistory() throws {
        let doc = makeDocument([UInt8](0x10..<0x20))
        let originalURL = doc.url
        try doc.overwrite(range: 0..<4, with: [0x01, 0x02, 0x03, 0x04])
        XCTAssertTrue(doc.canUndo, "an edit stands before the join")

        try doc.join(contentsOf: ArrayStorage([0xA0, 0xA1]), at: .end)

        XCTAssertFalse(doc.canUndo, "the join clears the undo history")
        XCTAssertFalse(doc.canRedo)
        XCTAssertTrue(doc.isDirty, "the joined content is unsaved and must warn on close")
        XCTAssertNotEqual(doc.url, originalURL, "the join detaches from the file")
        XCTAssertEqual(doc.url.lastPathComponent, "Untitled",
                       "the result is untitled, mirroring a New File")
        XCTAssertFalse(doc.readOnly)
    }
}
