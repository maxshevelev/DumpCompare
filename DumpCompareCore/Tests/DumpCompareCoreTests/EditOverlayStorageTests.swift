import XCTest
@testable import DumpCompareCore

/// What is specific to the overlay. The `EditableByteStorage` contract it shares
/// with `MemoryBackedStorage` is in `EditableByteStorageContractTests`.
final class EditOverlayStorageTests: XCTestCase {
    private func makeStorage(_ bytes: [UInt8]) throws -> EditOverlayStorage {
        let base = try TestSupport.makeStorage(Data(bytes))
        return EditOverlayStorage(base: base)
    }

    /// Saving may patch the original file in place only while no edit has moved
    /// a byte: overwrites and appends keep the offsets the file was opened with,
    /// an insert or a delete does not.
    func testCanPatchInPlaceUntilAnEditShiftsAnOffset() throws {
        let overwritten = try makeStorage([0x00, 0x00, 0x00, 0x00])
        XCTAssertFalse(overwritten.isDirty, "an untouched overlay holds no edit")
        try overwritten.overwrite(range: 1..<3, with: [0xAA, 0xBB])
        XCTAssertTrue(overwritten.canPatchInPlace, "an overwrite moves no byte")
        XCTAssertTrue(overwritten.isDirty)

        let appended = try makeStorage([0x00, 0x00, 0x00])
        try appended.append([0x01])
        try appended.overwrite(range: 0..<1, with: [0xFF])
        XCTAssertTrue(appended.canPatchInPlace, "an append moves no existing byte either")

        let inserted = try makeStorage([0x01, 0x02, 0x03, 0x04])
        try inserted.insert(at: 2, bytes: [0xFF, 0xFE])
        XCTAssertFalse(inserted.canPatchInPlace, "an insert shifts the tail")

        let deleted = try makeStorage([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        try deleted.delete(range: 2..<4)
        XCTAssertFalse(deleted.canPatchInPlace, "a delete shifts the tail")
    }

    /// An overwrite lands at the *current* offsets, not the base's: after an
    /// insert has shifted the table, byte 0 is still byte 0.
    func testOverwriteAfterLengthChangeStillWorks() throws {
        let s = try makeStorage([0x00, 0x01, 0x02, 0x03])
        try s.insert(at: 2, bytes: [0xFF])
        try s.overwrite(range: 0..<1, with: [0x99])
        XCTAssertEqual(try TestSupport.readAll(s), [0x99, 0x01, 0xFF, 0x02, 0x03])
    }

    func testReadMergesOverlayAndBase() throws {
        let s = try makeStorage([0x00, 0x00, 0x00, 0x00, 0x00])
        try s.overwrite(range: 1..<2, with: [0xEE])
        try s.append([0xFF])
        // Overlay has [1,2)=EE and [5,6)=FF; a window spanning both must merge.
        XCTAssertEqual(try s.read(at: 0, length: 6), [0x00, 0xEE, 0x00, 0x00, 0x00, 0xFF])
    }

    /// One shifted byte marks the whole tail as changed: from the insert or
    /// delete point to EOF, nothing holds the content the file held at that
    /// offset any more. This is the rule the minimap paints, and the reason a
    /// single inserted byte reddens everything after it.
    func testAShiftMarksTheWholeTailAsChanged() throws {
        let inserted = try makeStorage([UInt8](repeating: 0x00, count: 100))
        try inserted.insert(at: 10, bytes: [0xFF])
        XCTAssertEqual(inserted.size, 101, "the insert really did grow the file")
        XCTAssertEqual(inserted.changedRanges, [10..<101])

        let deleted = try makeStorage([UInt8](repeating: 0x00, count: 100))
        try deleted.delete(range: 40..<45)
        XCTAssertEqual(deleted.size, 95, "the delete really did shrink the file")
        XCTAssertEqual(deleted.changedRanges, [40..<95])

        // A delete that reaches EOF leaves no tail to mark at all.
        let truncated = try makeStorage([UInt8](repeating: 0x00, count: 100))
        try truncated.delete(range: 90..<100)
        XCTAssertEqual(truncated.changedRanges, [])
    }

    /// The base is immutable by contract, so a short read from it means the file
    /// was truncated behind the overlay's back. The missing bytes read as zeros
    /// rather than sliding the bytes after them left — an offset must never
    /// change meaning because someone else shortened the file.
    func testABaseTruncatedUnderUsPadsInsteadOfShiftingOffsets() throws {
        let url = try TestSupport.makeTempFile(contents: Data((0..<100).map { UInt8($0) }))
        let s = EditOverlayStorage(base: try FileBackedStorage(url: url))

        XCTAssertEqual(Darwin.truncate(url.path, 40), 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, 40,
                       "the base file really is shorter now")
        XCTAssertEqual(s.size, 100, "the overlay still describes the file as opened")

        // A window straddling the truncation point: the bytes that survive, then
        // zeros where the file ended, each still at its own offset.
        XCTAssertEqual(try s.read(at: 35, length: 10),
                       [35, 36, 37, 38, 39, 0, 0, 0, 0, 0])
        // And a window entirely past it is all zeros, not empty.
        XCTAssertEqual(try s.read(at: 90, length: 4), [0, 0, 0, 0])
    }

    /// A random sequence of edits, checked against a plain `[UInt8]` doing the
    /// same operations: the piece table's arithmetic has many boundary cases, and
    /// this is the cheapest way to be sure none of them drifts.
    func testMatchesAPlainArrayOverARandomEditSequence() throws {
        let seed: UInt64 = 0x0DDC_0FFE_E0DD_F00D
        var rng = SeededGenerator(seed: seed)
        for round in 0..<20 {
            let context = "seed \(String(seed, radix: 16)) round \(round)"
            var model = (0..<200).map { UInt8($0 % 251) }
            let storage = try makeStorage(model)

            for _ in 0..<40 {
                let size = model.count
                switch Int.random(in: 0..<3, using: &rng) {
                case 0:
                    let at = Int.random(in: 0...size, using: &rng)
                    let bytes = (0..<Int.random(in: 1...5, using: &rng)).map { _ in
                        UInt8.random(in: 0...255, using: &rng)
                    }
                    try storage.insert(at: UInt64(at), bytes: bytes)
                    model.insert(contentsOf: bytes, at: at)
                case 1 where size > 0:
                    let lower = Int.random(in: 0..<size, using: &rng)
                    let upper = min(size, lower + Int.random(in: 1...6, using: &rng))
                    try storage.delete(range: UInt64(lower)..<UInt64(upper))
                    model.removeSubrange(lower..<upper)
                case 2 where size > 0:
                    let at = Int.random(in: 0..<size, using: &rng)
                    let bytes = (0..<Int.random(in: 1...5, using: &rng)).map { _ in
                        UInt8.random(in: 0...255, using: &rng)
                    }
                    try storage.overwrite(range: UInt64(at)..<UInt64(at + bytes.count), with: bytes)
                    for (i, byte) in bytes.enumerated() {
                        if at + i < model.count { model[at + i] = byte } else { model.append(byte) }
                    }
                default:
                    break
                }

                XCTAssertEqual(storage.size, UInt64(model.count), context)
                XCTAssertEqual(try storage.read(at: 0, length: model.count), model, context)
            }

            // And window reads agree with the whole-file read.
            let whole = try storage.read(at: 0, length: model.count)
            for start in stride(from: 0, to: model.count, by: 7) {
                let length = min(11, model.count - start)
                XCTAssertEqual(try storage.read(at: UInt64(start), length: length),
                               Array(whole[start..<(start + length)]), context)
            }
        }
    }
}
