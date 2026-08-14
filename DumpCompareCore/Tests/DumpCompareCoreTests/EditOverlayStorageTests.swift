import XCTest
@testable import DumpCompareCore

final class EditOverlayStorageTests: XCTestCase {
    private func makeStorage(_ bytes: [UInt8]) throws -> EditOverlayStorage {
        let base = try TestSupport.makeStorage(Data(bytes))
        return EditOverlayStorage(base: base)
    }

    func testOverwriteReadBack() throws {
        let s = try makeStorage([0x00, 0x00, 0x00, 0x00])
        try s.overwrite(range: 1..<3, with: [0xAA, 0xBB])
        XCTAssertEqual(try TestSupport.readAll(s), [0x00, 0xAA, 0xBB, 0x00])
        XCTAssertTrue(s.canPatchInPlace)
        XCTAssertTrue(s.isDirty)
    }

    func testOverwriteBeyondEOFExtendsSize() throws {
        let s = try makeStorage([0x00])
        try s.overwrite(range: 1..<1, with: [0x01, 0x02])
        XCTAssertEqual(s.size, 3)
        XCTAssertEqual(try TestSupport.readAll(s), [0x00, 0x01, 0x02])
    }

    func testAppend() throws {
        let s = try makeStorage([0x01])
        try s.append([0x02, 0x03])
        XCTAssertEqual(s.size, 3)
        XCTAssertEqual(try TestSupport.readAll(s), [0x01, 0x02, 0x03])
    }

    func testInsertShiftsOffsets() throws {
        let s = try makeStorage([0x01, 0x02, 0x03, 0x04])
        try s.insert(at: 2, bytes: [0xFF, 0xFE])
        XCTAssertEqual(s.size, 6)
        XCTAssertEqual(try TestSupport.readAll(s), [0x01, 0x02, 0xFF, 0xFE, 0x03, 0x04])
        XCTAssertFalse(s.canPatchInPlace)
    }

    func testInsertAtEOFAppends() throws {
        let s = try makeStorage([0x01, 0x02])
        try s.insert(at: 2, bytes: [0x03])
        XCTAssertEqual(try TestSupport.readAll(s), [0x01, 0x02, 0x03])
    }

    func testInsertOffsetBeyondEOFIsClamped() throws {
        let s = try makeStorage([0x01, 0x02])
        try s.insert(at: 50, bytes: [0x03])
        XCTAssertEqual(try TestSupport.readAll(s), [0x01, 0x02, 0x03])
    }

    func testDeleteShrinks() throws {
        let s = try makeStorage([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        try s.delete(range: 2..<4)
        XCTAssertEqual(s.size, 4)
        XCTAssertEqual(try TestSupport.readAll(s), [0x00, 0x01, 0x04, 0x05])
        XCTAssertFalse(s.canPatchInPlace)
    }

    func testDeleteClampedToSize() throws {
        let s = try makeStorage([0x00, 0x01])
        try s.delete(range: 1..<10)
        XCTAssertEqual(s.size, 1)
        XCTAssertEqual(try TestSupport.readAll(s), [0x00])
    }

    func testDeleteAll() throws {
        let s = try makeStorage([0x01, 0x02, 0x03])
        try s.delete(range: 0..<3)
        XCTAssertEqual(s.size, 0)
        XCTAssertEqual(try TestSupport.readAll(s), [])
    }

    func testMixedOperationsPreserveContent() throws {
        let s = try makeStorage([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        try s.overwrite(range: 0..<1, with: [0x99])
        try s.insert(at: 3, bytes: [0x77, 0x78])
        try s.delete(range: 5..<8)
        try s.append([0xEE])
        // 99 01 02 77 78 03 04 05 06 07 → delete 5..<8 (03 04 05) → 99 01 02 77 78 06 07 → +EE
        XCTAssertEqual(try TestSupport.readAll(s), [0x99, 0x01, 0x02, 0x77, 0x78, 0x06, 0x07, 0xEE])
        XCTAssertEqual(s.size, 8)
    }

    func testCanPatchInPlaceAfterOverwritesAndAppend() throws {
        let s = try makeStorage([0x00, 0x00, 0x00])
        try s.append([0x01]) // append is still patchable in place
        try s.overwrite(range: 0..<1, with: [0xFF])
        XCTAssertTrue(s.canPatchInPlace)
    }

    func testOverwriteAfterLengthChangeStillWorks() throws {
        let s = try makeStorage([0x00, 0x01, 0x02, 0x03])
        try s.insert(at: 2, bytes: [0xFF])
        try s.overwrite(range: 0..<1, with: [0x99])
        XCTAssertEqual(try TestSupport.readAll(s), [0x99, 0x01, 0xFF, 0x02, 0x03])
    }

    func testEmptyFileOperations() throws {
        let s = try makeStorage([])
        try s.append([0xDE, 0xAD])
        XCTAssertEqual(try TestSupport.readAll(s), [0xDE, 0xAD])
        try s.insert(at: 1, bytes: [0xBE])
        XCTAssertEqual(try TestSupport.readAll(s), [0xDE, 0xBE, 0xAD])
        try s.delete(range: 0..<1)
        XCTAssertEqual(try TestSupport.readAll(s), [0xBE, 0xAD])
    }

    func testReadClampsAtEOF() throws {
        let s = try makeStorage([0x01, 0x02, 0x03])
        XCTAssertEqual(try s.read(at: 2, length: 100), [0x03])
        XCTAssertEqual(try s.read(at: 3, length: 100), [])
    }

    func testReadMergesOverlayAndBase() throws {
        let s = try makeStorage([0x00, 0x00, 0x00, 0x00, 0x00])
        try s.overwrite(range: 1..<2, with: [0xEE])
        try s.append([0xFF])
        // Overlay has [1,2)=EE and [5,6)=FF; a window spanning both must merge.
        XCTAssertEqual(try s.read(at: 0, length: 6), [0x00, 0xEE, 0x00, 0x00, 0x00, 0xFF])
    }
}
