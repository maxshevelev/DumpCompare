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

    /// A file the sandboxed app has been granted but whose directory it cannot
    /// write: the shape that forces the direct-write fallback, because
    /// `rewriteViaSiblingTemp` decides on exactly one thing — whether it can
    /// create a file next to the target. Returns the target and asserts both
    /// halves of the premise.
    private func makeTargetInAnUnwritableDirectory(_ initial: Data) throws -> URL {
        let target = try TestSupport.makeTempFile(contents: initial)
        let directory = target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                             ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: directory.path)
        }
        XCTAssertFalse(FileManager.default.createFile(
            atPath: directory.appendingPathComponent(".probe.tmp").path, contents: nil),
                       "the sibling temp file really cannot be created")
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: target.path),
                      "the chosen file really is still writable")
        return target
    }

    /// The sandbox fallback for Save As: the app owns the file the user chose but
    /// not its directory, so the atomic swap is impossible. The content must
    /// still land, written straight into the target.
    func testASaveAsFallsBackToWritingTheChosenFileDirectly() throws {
        let (s, _) = try makeEditable(Data([0x01, 0x02, 0x03]))
        try s.insert(at: 1, bytes: [0xFF])
        let target = try makeTargetInAnUnwritableDirectory(Data([0xEE]))

        try StorageSaver.save(s, to: target)
        XCTAssertEqual(try TestSupport.readAll(target), Data([0x01, 0xFF, 0x02, 0x03]))
    }

    /// The case the fallback exists for and the one it got wrong: a plain
    /// **Save** of a length-changing edit, in the sandbox, where the file being
    /// written IS the file the overlay still reads its base from.
    ///
    /// Writing straight into it opened the target with `O_TRUNC`, which emptied
    /// the base before a single byte had been read out of it — so the save wrote
    /// the overlay's zero-padded short reads over the user's file. A 3-byte
    /// dump with one inserted byte came out as `00 FF 00 00`.
    func testAPlainSaveThroughTheDirectWritePathKeepsTheContent() throws {
        let target = try makeTargetInAnUnwritableDirectory(Data([0x01, 0x02, 0x03]))
        let base = try FileBackedStorage(url: target)
        let storage = EditOverlayStorage(base: base)
        try storage.insert(at: 1, bytes: [0xFF])
        XCTAssertFalse(storage.canPatchInPlace,
                       "premise: a length-changing edit cannot be patched in place")

        try StorageSaver.save(storage, to: target)

        XCTAssertEqual(try TestSupport.readAll(target), Data([0x01, 0xFF, 0x02, 0x03]),
                       "the file the base was read from must not be truncated before it is read")
    }

    /// The direct write must truncate: writing content shorter than what the
    /// chosen file already held cannot leave the tail of the older version
    /// behind, or the saved file ends in bytes from a stranger.
    func testTheDirectWriteLeavesNoTailOfWhatTheFileHeldBefore() throws {
        let (s, _) = try makeEditable(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
        try s.delete(range: 1..<5)
        let target = try makeTargetInAnUnwritableDirectory(
            Data([0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8]))

        try StorageSaver.save(s, to: target)
        XCTAssertEqual(try TestSupport.readAll(target), Data([0x01, 0x06]))
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

    // MARK: - The base file shrinking under the document (§5.5)

    /// Another process truncates the file the document was opened from. The
    /// overlay cannot read the missing bytes any more, and it pads them with
    /// ZEROS so the offsets after them stay where they are — right for the hex
    /// view, catastrophic for a save: the save would write those zeros into the
    /// user's file and report success. It must refuse, and leave the file as the
    /// truncation left it, for the reload the change watcher offers (§5.5).
    func testASaveIsRefusedWhenTheBaseFileHasShrunk() throws {
        let url = try TestSupport.makeTempFile(contents: Data([UInt8](repeating: 0xAB, count: 4096)))
        defer { try? FileManager.default.removeItem(at: url) }
        let overlay = EditOverlayStorage(base: try FileBackedStorage(url: url))
        try overlay.overwrite(range: 0..<1, with: [0x01])   // an edit to save

        // The file loses everything but its first byte.
        try Data([0xAB]).write(to: url)

        XCTAssertThrowsError(try StorageSaver.save(overlay, to: url)) { error in
            XCTAssertEqual(error as? StorageError, .readFailed)
        }
        XCTAssertEqual(try TestSupport.readAll(url), Data([0xAB]),
                       "the file is left as the truncation left it, not padded with zeros")
    }
}
