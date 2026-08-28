import Foundation
import XCTest
@testable import DumpCompareCore

/// §23 Duplicate: a document hands out a second document holding a copy of its
/// current content as an untitled, never-saved file. The copy is a snapshot —
/// the bytes as they were at the moment of the call — and the two documents are
/// independent from then on: an edit, a save or a close on either side leaves
/// the other exactly as it was. That independence is what the sharing underneath
/// (no bytes copied, §23) must not cost.
final class BinaryDocumentDuplicateTests: XCTestCase {
    /// A document over an in-memory base, attached to a (placeholder) file URL,
    /// so the copy has an attachment to be detached from.
    private func makeDocument(_ bytes: [UInt8],
                              budgets: EditOverlayStorage.Budgets = .init()) -> BinaryDocument {
        BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: bytes), budgets: budgets),
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("duplicate-\(UUID().uuidString).bin"),
            readOnly: false
        )
    }

    /// A document over a real file on disk, the case the app's Duplicate hits
    /// most: nothing edited, the base is the user's own dump.
    private func makeFileDocument(_ bytes: [UInt8]) throws -> (BinaryDocument, URL) {
        let url = try TestSupport.makeTempFile(contents: Data(bytes))
        return (try BinaryDocument(url: url), url)
    }

    private func readAll(_ doc: BinaryDocument) throws -> [UInt8] {
        try doc.read(at: 0, length: Int(doc.size))
    }

    // MARK: - What the copy holds

    func testTheCopyHoldsTheSourcesBytes() throws {
        let (doc, _) = try makeFileDocument([UInt8](0x10..<0x20))

        let copy = try doc.duplicate()

        XCTAssertEqual(copy.size, doc.size)
        XCTAssertEqual(try readAll(copy), [UInt8](0x10..<0x20))
    }

    /// The copy is of the content the pane *shows*, not of the file on disk: a
    /// source with unsaved edits is duplicated with them.
    func testTheCopyCarriesTheSourcesUnsavedEdits() throws {
        let (doc, _) = try makeFileDocument([0x00, 0x01, 0x02, 0x03])
        try doc.overwrite(range: 1..<2, with: [0xAA])
        try doc.insert(at: 4, bytes: [0xBB])

        let copy = try doc.duplicate()

        XCTAssertEqual(try readAll(copy), [0x00, 0xAA, 0x02, 0x03, 0xBB])
    }

    func testTheCopyOfAnEmptyDocumentIsEmpty() throws {
        let doc = makeDocument([])

        let copy = try doc.duplicate()

        XCTAssertEqual(copy.size, 0)
    }

    func testDuplicatingAStorageThatCannotBeSnapshottedThrows() throws {
        let doc = BinaryDocument(storage: MemoryBackedStorage(bytes: [1, 2, 3]),
                                 url: BinaryDocument.placeholderURL,
                                 readOnly: false)

        XCTAssertThrowsError(try doc.duplicate()) { error in
            XCTAssertEqual(error as? DocumentError, .unsupportedStorage)
        }
    }

    // MARK: - The copy is an untitled, never-saved document

    func testTheCopyIsDetachedDirtyAndWritable() throws {
        let (doc, _) = try makeFileDocument([0x01, 0x02])

        let copy = try doc.duplicate()

        XCTAssertFalse(copy.isAttached, "the copy came from no file of its own")
        XCTAssertEqual(copy.url, BinaryDocument.placeholderURL)
        XCTAssertFalse(copy.readOnly, "the copy must be saveable, like any new document")
        XCTAssertTrue(copy.isDirty, "content that has never been on disk must warn on close")
        XCTAssertFalse(copy.canUndo, "there is no state before the copy to return to")
        XCTAssertFalse(copy.canRedo)
    }

    /// A copy of a read-only file is not itself read-only: it is a new document,
    /// and the file's permissions were never its own.
    func testTheCopyOfAReadOnlyFileIsWritable() throws {
        let (doc, url) = try makeFileDocument([0x01, 0x02])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let reopened = try BinaryDocument(url: url)
        XCTAssertTrue(reopened.readOnly)

        let copy = try reopened.duplicate()

        XCTAssertFalse(copy.readOnly)
    }

    /// Saving the copy writes its own full content to the chosen file, and
    /// leaves the file the source came from alone — the copy never had a claim
    /// on it, even though it reads its bytes from a clone of it.
    func testSavingTheCopyWritesItsOwnFileAndLeavesTheSourcesAlone() throws {
        let (doc, sourceURL) = try makeFileDocument([0x00, 0x01, 0x02, 0x03])
        let copy = try doc.duplicate()
        try copy.overwrite(range: 0..<1, with: [0xFF])
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-save-\(UUID().uuidString).bin")
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }

        try copy.save(to: target)

        XCTAssertEqual([UInt8](try Data(contentsOf: target)), [0xFF, 0x01, 0x02, 0x03])
        XCTAssertEqual([UInt8](try Data(contentsOf: sourceURL)), [0x00, 0x01, 0x02, 0x03],
                       "the source's file must not be touched by the copy's save")
        XCTAssertFalse(copy.isDirty, "the save gave the copy a file of its own")
        XCTAssertTrue(copy.isAttached)
    }

    // MARK: - The source is left alone

    func testDuplicatingChangesNothingAboutTheSource() throws {
        let (doc, url) = try makeFileDocument([0x00, 0x01, 0x02])
        try doc.overwrite(range: 0..<1, with: [0xAA])
        let dirtyBefore = doc.isDirty
        let depthBefore = doc.undoHistory.undoDepth

        _ = try doc.duplicate()

        XCTAssertEqual(doc.url, url, "the source keeps its file")
        XCTAssertTrue(doc.isAttached)
        XCTAssertEqual(doc.isDirty, dirtyBefore)
        XCTAssertEqual(doc.undoHistory.undoDepth, depthBefore,
                       "a duplicate is not an edit: it records no undo step")
        XCTAssertEqual(try readAll(doc), [0xAA, 0x01, 0x02])
    }

    // MARK: - The two are independent afterwards

    func testEditingTheCopyDoesNotChangeTheSource() throws {
        let (doc, _) = try makeFileDocument([0x00, 0x01, 0x02])
        let copy = try doc.duplicate()

        try copy.overwrite(range: 1..<2, with: [0xEE])
        try copy.insert(at: 0, bytes: [0xDD])

        XCTAssertEqual(try readAll(copy), [0xDD, 0x00, 0xEE, 0x02])
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02])
    }

    func testEditingTheSourceDoesNotChangeTheCopy() throws {
        let (doc, _) = try makeFileDocument([0x00, 0x01, 0x02])
        let copy = try doc.duplicate()

        try doc.overwrite(range: 1..<2, with: [0xEE])
        try doc.delete(range: 0..<1)

        XCTAssertEqual(try readAll(doc), [0xEE, 0x02])
        XCTAssertEqual(try readAll(copy), [0x00, 0x01, 0x02])
    }

    /// The one way the shared bytes could have gone wrong: a plain Save patches
    /// the source's file in place (§5.2), and the copy reads its unedited bytes
    /// from that very file. It must read a snapshot of it instead — which is why
    /// the file is cloned rather than shared (§23).
    func testSavingTheSourceOverItsOwnFileDoesNotChangeTheCopy() throws {
        let (doc, url) = try makeFileDocument([0x00, 0x01, 0x02, 0x03])
        let copy = try doc.duplicate()

        try doc.overwrite(range: 2..<4, with: [0xEE, 0xFF])
        try doc.save()

        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [0x00, 0x01, 0xEE, 0xFF],
                       "the source's save must reach its file")
        XCTAssertEqual(try readAll(copy), [0x00, 0x01, 0x02, 0x03],
                       "the copy keeps the bytes it was taken from")
    }

    /// An external write to the file behind the source has no way to reach the
    /// copy either: the copy reads its own clone.
    func testRewritingTheSourcesFileFromOutsideDoesNotChangeTheCopy() throws {
        let (doc, url) = try makeFileDocument([0x00, 0x01, 0x02, 0x03])
        let copy = try doc.duplicate()

        try Data([0xFF, 0xFF, 0xFF, 0xFF]).write(to: url)

        XCTAssertEqual(try readAll(copy), [0x00, 0x01, 0x02, 0x03])
    }

    /// Closing the source is what an app does when the user closes its pane, and
    /// it must not need a copy of the bytes to be made first: the temp file the
    /// copy may read from is unlinked by the source's deinit, and an unlinked
    /// file stays readable through the descriptor already open on it.
    func testTheCopyOutlivesTheSource() throws {
        let bytes = [UInt8](0x00..<0x40)
        var doc: BinaryDocument? = try makeFileDocument(bytes).0
        // An edit, so the snapshot cannot simply be the file: the copy reads a
        // piece list over a clone the source's storage owns the store for.
        try doc!.overwrite(range: 0..<1, with: [0xAA])
        let copy = try doc!.duplicate()

        doc = nil

        XCTAssertEqual(try readAll(copy), [0xAA] + bytes.dropFirst())
    }

    /// The source folding its piece table into a fresh base file (the budget
    /// valve, §13) replaces the very object the copy may be reading from, and
    /// unlinks the previous one. The copy must not notice.
    func testTheSourceMaterializingDoesNotChangeTheCopy() throws {
        // A one-piece budget: the next edit after the duplicate materializes.
        let doc = makeDocument([UInt8](0x00..<0x20),
                               budgets: .init(maxInlineInsert: 1 << 20,
                                              maxAddedBytes: 1 << 20,
                                              maxPieces: 2))
        try doc.overwrite(range: 0..<1, with: [0xAA])
        let copy = try doc.duplicate()
        let copyBytes = try readAll(copy)

        for offset in stride(from: UInt64(4), to: 20, by: 2) {
            try doc.overwrite(range: offset..<(offset + 1), with: [0xBB])
        }
        let overlay = try XCTUnwrap(doc.storage as? EditOverlayStorage)
        XCTAssertLessThanOrEqual(overlay.pieceCount, 2, "the source must have materialized")

        XCTAssertEqual(try readAll(copy), copyBytes)
    }

    /// The copy may end up sharing a temp file the **source** owns: the base the
    /// source materialized is already immutable, so it is shared where it lies.
    /// Closing the source unlinks that file and removes the directory around it,
    /// and the copy must go on reading it through the descriptor it already
    /// holds — that is what makes closing a pane cost nothing (§23.4).
    func testTheCopyOutlivesTheSourceWhenTheySharedTheSourcesTempFile() throws {
        let bytes = [UInt8](0x00..<0x40)
        // A piece budget of one: the first edit folds the content into a temp
        // file of the source's own, and that file becomes the shared base.
        var doc: BinaryDocument? = makeDocument(bytes,
                                                budgets: .init(maxInlineInsert: 1 << 20,
                                                               maxAddedBytes: 1 << 20,
                                                               maxPieces: 1))
        try doc!.overwrite(range: 0..<1, with: [0xAA])
        let overlay = try XCTUnwrap(doc!.storage as? EditOverlayStorage)
        XCTAssertEqual(overlay.pieceCount, 1, "the source must have materialized")
        let copy = try doc!.duplicate()

        doc = nil

        XCTAssertEqual(try readAll(copy), [0xAA] + bytes.dropFirst())
    }

    // MARK: - No bytes are copied

    /// The point of the snapshot: taking one reads nothing. A base the overlay
    /// owns is shared as it is, so the counting storage below sees no read until
    /// the copy is actually read from — a duplicate of a 32 MB dump costs no
    /// 32 MB pass.
    func testTakingTheCopyReadsNoBytes() throws {
        let counting = CountingStorage([UInt8](0x00..<0x40))
        let doc = BinaryDocument(storage: EditOverlayStorage(base: counting),
                                 url: BinaryDocument.placeholderURL,
                                 readOnly: false)

        let copy = try doc.duplicate()

        XCTAssertEqual(counting.reads, 0, "a duplicate must not walk the content")
        XCTAssertEqual(try readAll(copy), [UInt8](0x00..<0x40))
        XCTAssertGreaterThan(counting.reads, 0, "reading the copy does read the shared base")
    }

    /// The snapshot of an unedited file **clones** it rather than copying it: the
    /// clone's data blocks are the file's own, which is what makes Duplicate cost
    /// no pass over the bytes and no disk until one side is written (§23.4). A
    /// filesystem that cannot clone skips this — correctness there is covered by
    /// the tests above, which do not care which path produced the bytes.
    func testTheSnapshotClonesTheFileRatherThanCopyingIt() throws {
        var random = SystemRandomNumberGenerator()
        let bytes = (0..<(4 << 20)).map { _ in UInt8.random(in: 0...255, using: &random) }
        let (doc, url) = try makeFileDocument(bytes)
        try XCTSkipUnless(canClone(url), "this filesystem cannot clone files")
        let store = TemporaryFileStore()
        let overlay = try XCTUnwrap(doc.storage as? EditOverlayStorage)

        _ = try overlay.contentSnapshot(scratch: store)

        let clone = try XCTUnwrap(filesIn(store.directory).first,
                                  "the snapshot must have put a clone in the store")
        for logical in [off_t(0), off_t(1 << 20), off_t(3 << 20)] {
            XCTAssertEqual(physicalOffset(clone, logical: logical),
                           physicalOffset(url.path, logical: logical),
                           "the clone must share the file's blocks at \(logical >> 20) MiB")
        }
    }

    // MARK: - Filesystem helpers

    /// Whether the temp directory's filesystem can clone at all — the guard for
    /// the clone assertion above.
    private func canClone(_ url: URL) -> Bool {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        return clonefile(url.path, probe.path, 0) == 0
    }

    private func filesIn(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .map { directory.appendingPathComponent($0).path } ?? []
    }

    /// The physical device offset of the extent covering `logical`.
    /// `F_LOG2PHYS_EXT` takes the logical offset in `l2p_devoffset` and the query
    /// length in `l2p_contigbytes`, and overwrites both with the answer — so two
    /// files reporting the same offset for the same logical position are reading
    /// the same blocks.
    private func physicalOffset(_ path: String, logical: off_t) -> off_t? {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var l2p = log2phys(l2p_flags: 0, l2p_contigbytes: 4096, l2p_devoffset: logical)
        guard fcntl(fd, F_LOG2PHYS_EXT, &l2p) == 0 else { return nil }
        return l2p.l2p_devoffset
    }
}

/// A `ByteStorage` that counts the reads it serves — how a test tells sharing
/// apart from copying.
private final class CountingStorage: ByteStorage, @unchecked Sendable {
    private let bytes: [UInt8]
    private let lock = NSLock()
    private var readCount = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    var size: UInt64 { UInt64(bytes.count) }

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        lock.lock()
        readCount += 1
        lock.unlock()
        guard length > 0, offset < size else { return [] }
        let start = Int(offset)
        return Array(bytes[start..<min(start + length, bytes.count)])
    }
}
