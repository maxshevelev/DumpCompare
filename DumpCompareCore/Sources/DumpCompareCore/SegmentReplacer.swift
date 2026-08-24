import Foundation

/// Errors thrown by `SegmentReplacer`.
///
/// The presentation layer maps these to user-facing alerts (§16, §21.6). A
/// length mismatch is the one refusal the swap makes: the donor must match the
/// piece's length exactly, and making it an insert-and-shift is a decision, not a
/// default.
public enum SegmentReplaceError: Error, Equatable, Sendable {
    /// The donor's length differs from the piece's. Both sizes are named so the
    /// caller can say what it expected and what it got.
    case lengthMismatch(pieceLength: UInt64, donorLength: UInt64)
}

/// Replaces one piece's bytes with the contents of a donor, same length (§21.6).
///
/// The donor is read in bounded slices and each slice is written to the document
/// with `overwrite`; the whole swap is one undo transaction (an edit group), so
/// it undoes as one step and the donor is never loaded whole into RAM. This is
/// the read-side mirror of `SegmentWriter` (which streams pieces *out* to files):
/// `SegmentWriter` generalises the single-file atomic write, this one generalises
/// the single `overwrite` into a chunked, same-length swap.
///
/// A same-length overwrite moves no cut (§21.2): the document's size is
/// unchanged, so the segment partition's boundaries do not shift.
public enum SegmentReplacer {
    /// The read/write step; matches `SegmentWriter`'s 1 MiB so a large piece is
    /// streamed rather than loaded whole into RAM.
    static let chunkSize = 1024 * 1024

    /// Overwrites `range` with the donor's bytes, in chunks, as one transaction.
    ///
    /// Throws `lengthMismatch` when `donor.size != range.count`, before anything
    /// is written. A failure part-way through the chunks rolls the partial edit
    /// group back (reverting the ops collected so far, recording no transaction)
    /// and rethrows, so a failed swap leaves the document exactly as it was.
    public static func replace(
        range: Range<UInt64>,
        in document: BinaryDocument,
        withContentsOf donor: any ByteStorage
    ) throws {
        let length = range.upperBound - range.lowerBound
        guard donor.size == length else {
            throw SegmentReplaceError.lengthMismatch(pieceLength: length, donorLength: donor.size)
        }
        guard length > 0 else { return }

        document.beginEditGroup()
        do {
            var target = range.lowerBound
            let end = range.upperBound
            var source = UInt64(0)
            while target < end {
                let step = min(UInt64(chunkSize), end - target)
                let bytes = try donor.read(at: source, length: Int(step))
                guard !bytes.isEmpty else { break }
                try document.overwrite(range: target..<(target + UInt64(bytes.count)), with: bytes)
                target += UInt64(bytes.count)
                source += UInt64(bytes.count)
            }
        } catch {
            // A mid-stream failure: revert the partial group and record nothing,
            // so the document is left exactly as it was.
            try? document.cancelEditGroup()
            throw error
        }
        document.endEditGroup()
    }
}
