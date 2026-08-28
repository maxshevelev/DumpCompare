import Foundation
import XCTest
@testable import DumpCompareCore

/// §21.6 the segment replacer: a piece's bytes replaced by the contents of a
/// donor, same length. The donor is streamed in bounded chunks and the whole
/// swap is one undo transaction, so the tests drive it directly against an
/// in-memory document and check the bytes, the transaction count, and the
/// length-mismatch refusal.
final class SegmentReplacerTests: XCTestCase {
    /// An in-memory document over `bytes` — the untitled "New File" shape, so no
    /// file on disk is involved.
    private func makeDocument(_ bytes: [UInt8]) -> BinaryDocument {
        BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: bytes)),
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("replacer-\(UUID().uuidString).bin"),
            readOnly: false
        )
    }

    // MARK: - The bytes of a swap

    /// The donor's bytes land in the range; the rest of the document is
    /// untouched, and a same-length swap changes no size.
    func testTheDonorsBytesLandInTheRange() throws {
        let doc = makeDocument([UInt8](0..<16))  // 00 01 … 0F
        let donor = ArrayStorage([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])

        try SegmentReplacer.replace(range: 8..<16, in: doc, withContentsOf: donor)

        XCTAssertEqual(try doc.read(at: 8, length: 8),
                       [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7],
                       "the range holds the donor's bytes")
        XCTAssertEqual(try doc.read(at: 0, length: 8), [UInt8](0..<8),
                       "the other half is untouched")
        XCTAssertEqual(doc.size, 16, "a same-length swap changes no size")
    }

    // MARK: - One transaction

    /// A swap bigger than one chunk is still one undo transaction: the whole
    /// swap coalesces into a single commit, so undo takes it back as one step.
    /// Without the edit group, each chunk's `overwrite` would commit on its own.
    func testAMultiChunkSwapIsOneTransaction() throws {
        let size = 1536 * 1024  // 1.5 MiB: two 1 MiB chunks
        let doc = makeDocument((0..<size).map { UInt8($0 % 251) })
        let donor = ArrayStorage((0..<size).map { UInt8(($0 + 7) % 251) })
        var commits = 0
        doc.onTransactionCommitted = { commits += 1 }

        try SegmentReplacer.replace(range: 0..<UInt64(size), in: doc, withContentsOf: donor)

        XCTAssertEqual(commits, 1, "the whole multi-chunk swap is one transaction")
        XCTAssertEqual(try doc.read(at: 0, length: size),
                       (0..<size).map { UInt8(($0 + 7) % 251) },
                       "every byte lands at its own offset")
    }

    // MARK: - The length-mismatch refusal

    /// A donor whose length differs from the piece's is refused with both sizes
    /// named, and the document is left exactly as it was.
    func testALengthMismatchIsRefusedWithBothSizes() throws {
        let doc = makeDocument([UInt8](0..<16))
        let original = try doc.read(at: 0, length: 16)
        let donor = ArrayStorage([0xB0, 0xB1, 0xB2])  // 3 bytes, not 8

        XCTAssertThrowsError(
            try SegmentReplacer.replace(range: 8..<16, in: doc, withContentsOf: donor)
        ) { error in
            XCTAssertEqual(error as? SegmentReplaceError,
                           .lengthMismatch(pieceLength: 8, donorLength: 3),
                           "the refusal names both sizes")
        }
        XCTAssertEqual(try doc.read(at: 0, length: 16), original,
                       "a refused swap changes nothing")
        XCTAssertEqual(doc.size, 16)
    }

    // MARK: - The donor shrinking under the swap (§21.6)

    /// A donor read that comes back short means the donor shrank under the swap.
    /// Breaking out of the loop there committed HALF a replacement as one
    /// transaction and called it a success: the piece held the donor's first
    /// chunks and the document's own bytes after them. The swap must fail and
    /// leave the document exactly as it was.
    func testAShortDonorReadLeavesTheDocumentUnchanged() throws {
        let size = UInt64(3 * SegmentReplacer.chunkSize)
        let original = [UInt8](repeating: 0x11, count: Int(size))
        let document = BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: original)),
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("replace-\(UUID().uuidString).bin"),
            readOnly: false
        )
        let donor = ShrinkingStorage(size: size, shrinksOnRead: 2)

        XCTAssertThrowsError(
            try SegmentReplacer.replace(range: 0..<size, in: document, withContentsOf: donor)
        ) { error in
            XCTAssertEqual(error as? StorageError, .readFailed)
        }

        XCTAssertEqual(try document.read(at: 0, length: Int(size)), original,
                       "not one byte of a failed swap survives")
        XCTAssertFalse(document.undoHistory.canUndo,
                       "and it records no transaction to undo")
    }
}
