import XCTest
@testable import DumpCompareCore

final class StorageSaverTests: XCTestCase {
    private func makeEditable(_ data: Data) throws -> (EditOverlayStorage, URL) {
        let url = try TestSupport.makeTempFile(contents: data)
        let base = try FileBackedStorage(url: url)
        return (EditOverlayStorage(base: base), url)
    }

    func testPatchInPlacePreservesUntouchedBytes() throws {
        let (s, url) = try makeEditable(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))
        try s.overwrite(range: 2..<4, with: [0xAA, 0xBB])
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x00, 0x01, 0xAA, 0xBB, 0x04, 0x05, 0x06, 0x07]))
    }

    func testPatchInPlaceExtendsFileAtEOF() throws {
        let (s, url) = try makeEditable(Data([0x01, 0x02]))
        try s.append([0x03, 0x04, 0x05])
        XCTAssertTrue(s.canPatchInPlace)
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testPatchInPlaceMultipleRanges() throws {
        let (s, url) = try makeEditable(Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        try s.overwrite(range: 0..<1, with: [0x11])
        try s.overwrite(range: 4..<5, with: [0x44])
        try s.append([0x99])
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x11, 0x00, 0x00, 0x00, 0x44, 0x00, 0x99]))
    }

    func testRewriteAfterInsert() throws {
        let (s, url) = try makeEditable(Data([0x00, 0x01, 0x02, 0x03]))
        try s.insert(at: 2, bytes: [0xFF])
        XCTAssertFalse(s.canPatchInPlace)
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x00, 0x01, 0xFF, 0x02, 0x03]))
    }

    func testRewriteAfterDelete() throws {
        let (s, url) = try makeEditable(Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        try s.delete(range: 1..<3)
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x00, 0x03, 0x04]))
    }

    func testRewritePreservesOverlayAfterLengthChange() throws {
        let (s, url) = try makeEditable(Data([0x00, 0x01, 0x02, 0x03]))
        try s.overwrite(range: 0..<1, with: [0x99])
        try s.insert(at: 4, bytes: [0xEE])
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x99, 0x01, 0x02, 0x03, 0xEE]))
    }

    func testSavingCleanStorageIsNoop() throws {
        let (s, url) = try makeEditable(Data([0x01]))
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x01]))
    }

    func testSaveCanWriteToNewLocation() throws {
        let (s, url) = try makeEditable(Data([0x00, 0x01]))
        try s.append([0x02, 0x03])
        let target = url.deletingLastPathComponent().appendingPathComponent("copy-\(UUID().uuidString).bin")
        try StorageSaver.save(s, to: target)
        XCTAssertEqual(try TestSupport.readAll(target), Data([0x00, 0x01, 0x02, 0x03]))
    }

    func testSaveFailureThrowsAndLeavesOriginalIntact() throws {
        let (s, url) = try makeEditable(Data([0x01]))
        try s.overwrite(range: 0..<1, with: [0xAA])
        // Patch path: target directory does not exist → open fails.
        let bad = url.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathComponent("x.bin")
        XCTAssertThrowsError(try StorageSaver.save(s, to: bad))
        // Original untouched.
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x01]))
    }

    func testRewriteFailureLeavesNoTempLitter() throws {
        let (s, url) = try makeEditable(Data([0x01, 0x02]))
        try s.insert(at: 1, bytes: [0x99])
        let badDir = url.deletingLastPathComponent()
            .appendingPathComponent("missing-dir-\(UUID().uuidString)")
        let bad = badDir.appendingPathComponent("x.bin")
        XCTAssertThrowsError(try StorageSaver.save(s, to: bad))
        // No leftover temp files anywhere near the target directory.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".tmp") })
    }
}
