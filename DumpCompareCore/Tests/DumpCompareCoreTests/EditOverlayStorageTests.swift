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
