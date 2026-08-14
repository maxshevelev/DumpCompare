import XCTest
@testable import DumpCompareCore

final class BinaryDocumentTests: XCTestCase {
    private func makeDocument(_ bytes: [UInt8]) throws -> (BinaryDocument, URL) {
        let url = try TestSupport.makeTempFile(contents: Data(bytes))
        return (try BinaryDocument(url: url), url)
    }

    private func readAll(_ doc: BinaryDocument) throws -> [UInt8] {
        var result: [UInt8] = []
        var offset: UInt64 = 0
        while offset < doc.size {
            let bytes = try doc.read(at: offset, length: 64 * 1024)
            guard !bytes.isEmpty else { break }
            result.append(contentsOf: bytes)
            offset += UInt64(bytes.count)
        }
        return result
    }

    func testOpenExposesSizeAndIdentity() throws {
        let url = try TestSupport.makeTempFile(contents: Data([0x01, 0x02, 0x03]))
        let doc = try BinaryDocument(url: url)
        XCTAssertEqual(doc.size, 3)
        XCTAssertEqual(doc.identity, FileIdentity(url: url))
        XCTAssertFalse(doc.readOnly)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.canRedo)
    }

    func testOverwriteUndoRedo() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        try doc.overwrite(range: 1..<2, with: [0xAA])
        XCTAssertEqual(try readAll(doc), [0x00, 0xAA, 0x02, 0x03])
        XCTAssertTrue(doc.isDirty)

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02, 0x03])
        XCTAssertFalse(doc.canUndo)

        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0x00, 0xAA, 0x02, 0x03])
        XCTAssertTrue(doc.canUndo)
    }

    func testInsertUndoRedo() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        try doc.insert(at: 2, bytes: [0xFF, 0xFE])
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0xFF, 0xFE, 0x02, 0x03])

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02, 0x03])

        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0xFF, 0xFE, 0x02, 0x03])
    }

    func testDeleteUndoRedo() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03, 0x04])
        try doc.delete(range: 1..<3)
        XCTAssertEqual(try readAll(doc), [0x00, 0x03, 0x04])

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02, 0x03, 0x04])

        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x03, 0x04])
    }

    func testFillZeroUndoRestores() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        try doc.fillZero(in: 1..<3)
        XCTAssertEqual(try readAll(doc), [0x00, 0x00, 0x00, 0x03])

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02, 0x03])
    }

    func testOverwritePastEOFUndoShrinks() throws {
        let (doc, _) = try makeDocument([0x00, 0x01])
        try doc.overwrite(range: 1..<1, with: [0xAA, 0xBB])
        XCTAssertEqual(try readAll(doc), [0x00, 0xAA, 0xBB])
        XCTAssertEqual(doc.size, 3)

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x01])
        XCTAssertEqual(doc.size, 2)

        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0x00, 0xAA, 0xBB])
    }

    func testReplaceShorterDeletesLeftover() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        try doc.replace(range: 1..<3, with: [0xFF])
        XCTAssertEqual(try readAll(doc), [0x00, 0xFF, 0x03])

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02, 0x03])

        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0x00, 0xFF, 0x03])
    }

    func testDirtyLifecycleThroughSave() throws {
        let (doc, _) = try makeDocument([0x00, 0x01])
        XCTAssertFalse(doc.isDirty)

        try doc.overwrite(range: 0..<1, with: [0xAA])
        XCTAssertTrue(doc.isDirty)

        try doc.save()
        XCTAssertFalse(doc.isDirty)

        try doc.overwrite(range: 1..<2, with: [0xBB])
        XCTAssertTrue(doc.isDirty)

        try doc.undo()                        // back to the saved state
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try readAll(doc), [0xAA, 0x01])

        try doc.redo()                        // past the saved state
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try readAll(doc), [0xAA, 0xBB])
    }

    func testUndoGroupCoalesces() throws {
        let (doc, _) = try makeDocument([0x00, 0x01])
        doc.beginEditGroup()
        try doc.overwrite(range: 0..<1, with: [0xAA])
        try doc.overwrite(range: 1..<2, with: [0xBB])
        doc.endEditGroup()

        XCTAssertEqual(try readAll(doc), [0xAA, 0xBB])
        XCTAssertEqual(doc.undoHistory.undoDepth, 1)

        try doc.undo()                        // one undo reverts the whole session
        XCTAssertEqual(try readAll(doc), [0x00, 0x01])
    }

    func testRedoStackClearedOnNewEdit() throws {
        let (doc, _) = try makeDocument([0x00])
        try doc.overwrite(range: 0..<1, with: [0xAA])
        try doc.undo()
        XCTAssertTrue(doc.canRedo)

        try doc.overwrite(range: 0..<1, with: [0xBB])
        XCTAssertFalse(doc.canRedo)
        XCTAssertEqual(try readAll(doc), [0xBB])

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x00])
        XCTAssertFalse(try doc.undo())          // nothing left before the first edit
    }

    func testSaveAsWritesNewFileAndUpdatesURL() throws {
        let url = try TestSupport.makeTempFile(contents: Data([0x00, 0x01]))
        let doc = try BinaryDocument(url: url)
        try doc.overwrite(range: 0..<1, with: [0xAA])
        try doc.insert(at: 2, bytes: [0xFF])   // length change forces a rewrite
        XCTAssertEqual(try readAll(doc), [0xAA, 0x01, 0xFF])

        let target = url.deletingLastPathComponent()
            .appendingPathComponent("saved-\(UUID().uuidString).bin")
        try doc.save(to: target)

        XCTAssertEqual(try TestSupport.readAll(target), Data([0xAA, 0x01, 0xFF]))
        XCTAssertEqual(doc.url, target)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.readOnly)
    }

    func testRevertDiscardsEdits() throws {
        let url = try TestSupport.makeTempFile(contents: Data([0x00, 0x01, 0x02]))
        let doc = try BinaryDocument(url: url)
        try doc.overwrite(range: 0..<1, with: [0xAA])
        try doc.insert(at: 1, bytes: [0xFF])
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try readAll(doc), [0xAA, 0xFF, 0x01, 0x02])

        try doc.revert()
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02])
    }

    func testReadOnlyFileSaveThrowsAndSaveAsWorks() throws {
        let url = try TestSupport.makeTempFile(contents: Data([0x01, 0x02, 0x03]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        let doc = try BinaryDocument(url: url)
        XCTAssertTrue(doc.readOnly)

        try doc.overwrite(range: 0..<1, with: [0xAA])
        XCTAssertTrue(doc.isDirty)

        XCTAssertThrowsError(try doc.save()) { error in
            XCTAssertEqual(error as? DocumentError, .fileIsReadOnly)
        }

        let target = url.deletingLastPathComponent()
            .appendingPathComponent("copy-\(UUID().uuidString).bin")
        try doc.save(to: target)
        XCTAssertEqual(try TestSupport.readAll(target), Data([0xAA, 0x02, 0x03]))
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.url, target)
    }

    func testSelectionClampedAfterSizeChange() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        try doc.setSelection(SelectionModel(start: 1, length: 3, fileSize: doc.size))
        XCTAssertEqual(doc.selection, SelectionModel(start: 1, end: 4, fileSize: 4))

        try doc.delete(range: 1..<3)
        // File shrank to 2 bytes; selection must clamp, never point past EOF.
        XCTAssertEqual(doc.size, 2)
        XCTAssertEqual(doc.selection.fileSize, 2)
        XCTAssertEqual(doc.selection.end, 2)
    }
}
