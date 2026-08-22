import XCTest
@testable import DumpCompareCore

final class StorageSaverTests: XCTestCase {
    private func makeEditable(_ data: Data) throws -> (EditOverlayStorage, URL) {
        let url = try TestSupport.makeTempFile(contents: data)
        let base = try FileBackedStorage(url: url)
        return (EditOverlayStorage(base: base), url)
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

    /// Once an edit has shifted an offset the file cannot be patched in place, so
    /// saving rewrites it whole — and the rewritten file must hold the overlay's
    /// current content, overwrites included.
    func testRewriteAfterALengthChange() throws {
        let cases: [(name: String, initial: [UInt8],
                     edit: (EditOverlayStorage) throws -> Void, expected: [UInt8])] = [
            ("after an insert",
             [0x00, 0x01, 0x02, 0x03],
             { try $0.insert(at: 2, bytes: [0xFF]) },
             [0x00, 0x01, 0xFF, 0x02, 0x03]),
            ("after a delete",
             [0x00, 0x01, 0x02, 0x03, 0x04],
             { try $0.delete(range: 1..<3) },
             [0x00, 0x03, 0x04]),
            ("an overwrite made before the insert survives the rewrite",
             [0x00, 0x01, 0x02, 0x03],
             {
                 try $0.overwrite(range: 0..<1, with: [0x99])
                 try $0.insert(at: 4, bytes: [0xEE])
             },
             [0x99, 0x01, 0x02, 0x03, 0xEE]),
        ]
        for testCase in cases {
            let (s, url) = try makeEditable(Data(testCase.initial))
            try testCase.edit(s)
            XCTAssertFalse(s.canPatchInPlace, "\(testCase.name): the edit shifted an offset")
            try StorageSaver.save(s, to: url)
            XCTAssertEqual(try TestSupport.readAll(url), Data(testCase.expected), testCase.name)
        }
    }

    func testSavingCleanStorageIsNoop() throws {
        let (s, url) = try makeEditable(Data([0x01]))
        try StorageSaver.save(s, to: url)
        XCTAssertEqual(try TestSupport.readAll(url), Data([0x01]))
    }

    /// Save As: the target is not the file the base reads from, so the content is
    /// always written whole — from a file-backed base, from an untitled
    /// (in-memory) one, and from an untitled one nothing was typed into.
    func testSaveToANewLocation() throws {
        let cases: [(name: String, make: () throws -> EditOverlayStorage, expected: [UInt8])] = [
            ("from a file-backed base", {
                let (s, _) = try self.makeEditable(Data([0x00, 0x01]))
                try s.append([0x02, 0x03])
                return s
            }, [0x00, 0x01, 0x02, 0x03]),
            ("from an untitled document", {
                let s = EditOverlayStorage(base: MemoryBackedStorage())
                try s.overwrite(range: 0..<2, with: [0xAB, 0xCD])
                return s
            }, [0xAB, 0xCD]),
            ("from an untitled document nothing was typed into", {
                EditOverlayStorage(base: MemoryBackedStorage())
            }, []),
        ]
        for testCase in cases {
            let s = try testCase.make()
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("save-as-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: target) }
            try StorageSaver.save(s, to: target)
            XCTAssertEqual(try TestSupport.readAll(target), Data(testCase.expected), testCase.name)
        }
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
