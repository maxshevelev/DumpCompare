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

    func testFillPatternRepeatsAcrossRange() throws {
        let (doc, _) = try makeDocument([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        try doc.fill(pattern: [0xDE, 0xAD], in: 1..<6)
        XCTAssertEqual(try readAll(doc), [0x01, 0xDE, 0xAD, 0xDE, 0xAD, 0xDE])
    }

    func testFillPatternLongerThanRangeTruncates() throws {
        let (doc, _) = try makeDocument([0x01, 0x02, 0x03])
        try doc.fill(pattern: [0xAA, 0xBB, 0xCC, 0xDD], in: 1..<3)
        XCTAssertEqual(try readAll(doc), [0x01, 0xAA, 0xBB])
    }

    func testFillPatternUndoRedo() throws {
        let (doc, _) = try makeDocument([0x01, 0x02, 0x03, 0x04])
        try doc.fill(pattern: [0xDE, 0xAD], in: 0..<4)
        XCTAssertEqual(try readAll(doc), [0xDE, 0xAD, 0xDE, 0xAD])

        try doc.undo()
        XCTAssertEqual(try readAll(doc), [0x01, 0x02, 0x03, 0x04])

        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0xDE, 0xAD, 0xDE, 0xAD])
    }

    func testFillEmptyPatternIsNoOp() throws {
        let (doc, _) = try makeDocument([0x01, 0x02, 0x03])
        try doc.fill(pattern: [], in: 0..<2)
        XCTAssertEqual(try readAll(doc), [0x01, 0x02, 0x03])
        XCTAssertFalse(doc.isDirty)
    }

    func testFillClampsToEndOfFile() throws {
        let (doc, _) = try makeDocument([0x01, 0x02, 0x03])
        try doc.fill(pattern: [0xFF], in: 1..<10)
        XCTAssertEqual(try readAll(doc), [0x01, 0xFF, 0xFF])
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

    func testUndoRestoresCaretBeforeRedoRestoresCaretAfter() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03, 0x04])
        doc.setSelection(SelectionModel.empty(at: 3, fileSize: doc.size))
        try doc.overwrite(range: 3..<4, with: [0xFF])

        try doc.undo()
        XCTAssertEqual(doc.selection.start, 3, "undo returns the caret to where the edit began")

        try doc.redo()
        XCTAssertEqual(doc.selection.start, 4, "redo lands the caret where the edit left it")
    }

    func testUndoRedoInsertCaret() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02])
        doc.setSelection(SelectionModel.empty(at: 1, fileSize: doc.size))
        try doc.insert(at: 1, bytes: [0xAA, 0xBB])
        XCTAssertEqual(doc.selection.start, 1)  // insert doesn't move the caret

        try doc.undo()
        XCTAssertEqual(doc.selection.start, 1, "undo returns to the insert point")

        try doc.redo()
        XCTAssertEqual(doc.selection.start, 3, "redo restores the post-insert caret (at+count)")
    }

    func testUndoRestoresTheSelectionTheEditStartedFrom() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03, 0x04])
        doc.setSelection(SelectionModel(start: 1, end: 4, fileSize: doc.size))
        try doc.overwrite(range: 1..<2, with: [0xFF])

        try doc.undo()
        XCTAssertEqual(doc.selection, SelectionModel(start: 1, end: 4, fileSize: doc.size),
                       "undo restores the whole selection, not just its caret")
    }

    func testRedoRestoresTheSelectionTheCommandLeft() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03, 0x04])
        doc.setSelection(SelectionModel(start: 1, end: 4, fileSize: doc.size))
        try doc.overwrite(range: 1..<2, with: [0xFF])
        // What typing into a selection leaves: the unconsumed remainder.
        doc.setSelection(SelectionModel(start: 2, end: 4, fileSize: doc.size))
        doc.noteSelectionAfterEdit()

        try doc.undo()
        try doc.redo()
        XCTAssertEqual(doc.selection, SelectionModel(start: 2, end: 4, fileSize: doc.size),
                       "redo returns to the state the command left, remainder included")
    }

    func testANoteAfterAnUndoDoesNotTouchTheOlderTransaction() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        try doc.overwrite(range: 0..<1, with: [0xAA])
        try doc.overwrite(range: 1..<2, with: [0xBB])
        try doc.undo()   // the second edit is now on the redo stack

        // A stray note (a selection change after the undo) must not be attached
        // to the first edit as if it were its outcome.
        doc.setSelection(SelectionModel(start: 3, end: 4, fileSize: doc.size))
        doc.noteSelectionAfterEdit()

        try doc.undo()
        try doc.redo()
        XCTAssertEqual(doc.selection, SelectionModel.empty(at: 1, fileSize: doc.size),
                       "the first edit still redoes to its own end")
    }

    func testUndoOfACoalescedTypingGroupRestoresTheSelectionAtItsStart() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03, 0x04])
        doc.setSelection(SelectionModel(start: 2, end: 5, fileSize: doc.size))
        doc.beginEditGroup()
        try doc.overwrite(range: 2..<3, with: [0xF0])
        try doc.overwrite(range: 2..<3, with: [0xFF])   // the second nibble
        doc.endEditGroup()

        try doc.undo()
        XCTAssertEqual(doc.selection, SelectionModel(start: 2, end: 5, fileSize: doc.size),
                       "the group's whole selection comes back, not the caret alone")
    }

    // MARK: - Typing series (segmented undo, Variant B)

    func testTypingSeriesUndoByteThenBatch() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        doc.beginSeries(1)
        // The caret advances between bytes, as the view model does.
        try doc.overwrite(range: 0..<1, with: [0xA0])
        doc.setSelection(SelectionModel.empty(at: 1, fileSize: doc.size))
        try doc.overwrite(range: 1..<2, with: [0xA1])
        doc.setSelection(SelectionModel.empty(at: 2, fileSize: doc.size))
        try doc.overwrite(range: 2..<3, with: [0xA2])
        doc.setSelection(SelectionModel.empty(at: 3, fileSize: doc.size))
        doc.endSeries()

        // The first undo removes only the last byte of the series.
        try doc.undo(batch: false)
        XCTAssertEqual(try readAll(doc), [0xA0, 0xA1, 0x02, 0x03])
        XCTAssertEqual(doc.selection.start, 2, "caret lands where the removed byte was")

        // A fast second undo removes the rest of the series in one step.
        try doc.undo(batch: true)
        XCTAssertEqual(try readAll(doc), [0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(doc.selection.start, 0, "caret at the start of the series")
        XCTAssertFalse(doc.canUndo)

        // Redo is symmetric: the batch comes back in one press (caret at the
        // batch's end), then the single byte (caret at the series' end).
        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0xA0, 0xA1, 0x02, 0x03])
        XCTAssertEqual(doc.selection.start, 2)
        try doc.redo()
        XCTAssertEqual(try readAll(doc), [0xA0, 0xA1, 0xA2, 0x03])
        XCTAssertEqual(doc.selection.start, 3)
    }

    func testTypingSeriesBatchUndoRestoresTheConsumedSelection() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03, 0x04])
        doc.setSelection(SelectionModel(start: 2, end: 5, fileSize: doc.size))
        doc.beginSeries(1)
        // Typing into a selection consumes it byte by byte.
        try doc.replace(range: 2..<3, with: [0xF0])
        doc.setSelection(SelectionModel(start: 3, end: 5, fileSize: doc.size))
        doc.noteSelectionAfterEdit()
        try doc.replace(range: 3..<4, with: [0xF1])
        doc.setSelection(SelectionModel(start: 4, end: 5, fileSize: doc.size))
        doc.noteSelectionAfterEdit()
        try doc.replace(range: 4..<5, with: [0xF2])
        doc.setSelection(SelectionModel.empty(at: 5, fileSize: doc.size))
        doc.noteSelectionAfterEdit()
        doc.endSeries()

        try doc.undo(batch: false)
        XCTAssertEqual(doc.selection, SelectionModel(start: 4, end: 5, fileSize: doc.size),
                       "the last byte's consumed selection comes back with it")

        try doc.undo(batch: true)
        XCTAssertEqual(doc.selection, SelectionModel(start: 2, end: 5, fileSize: doc.size),
                       "the batch restores the full selection the series started from")

        try doc.redo()
        XCTAssertEqual(doc.selection, SelectionModel(start: 4, end: 5, fileSize: doc.size),
                       "the batch redo returns to the state after its last byte")
        try doc.redo()
        XCTAssertEqual(doc.selection, SelectionModel.empty(at: 5, fileSize: doc.size))
    }

    func testFillCaretOverrideUsedOnUndoRedo() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        doc.setSelection(SelectionModel(start: 1, end: 3, fileSize: doc.size))
        try doc.fill(pattern: [0xFF], in: 1..<3, caretAfter: 1)

        try doc.undo()
        XCTAssertEqual(doc.selection.start, 1, "caretBefore = the selection start")

        try doc.redo()
        XCTAssertEqual(doc.selection.start, 1, "a fill leaves the caret at the range start (override)")
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
        XCTAssertNil(try doc.undo())            // nothing left before the first edit
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

    func testInMemoryDocumentWithReadOnlyOverrideCanSave() throws {
        // The untitled "New File" pattern: a placeholder URL with no file on
        // disk, an in-memory base, and an explicit writable override.
        let doc = BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage()),
            url: FileManager.default.temporaryDirectory.appendingPathComponent("placeholder-\(UUID().uuidString).bin"),
            readOnly: false
        )
        XCTAssertFalse(doc.readOnly)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.size, 0)

        try doc.overwrite(range: 0..<0, with: [0xCA, 0xFE])
        XCTAssertEqual(doc.size, 2)
        XCTAssertTrue(doc.isDirty)

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("untitled-saved-\(UUID().uuidString).bin")
        try doc.save(to: target)
        XCTAssertEqual(try TestSupport.readAll(target), Data([0xCA, 0xFE]))
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.url, target)
    }

    func testSelectionClampedAfterSizeChange() throws {
        let (doc, _) = try makeDocument([0x00, 0x01, 0x02, 0x03])
        doc.setSelection(SelectionModel(start: 1, length: 3, fileSize: doc.size))
        XCTAssertEqual(doc.selection, SelectionModel(start: 1, end: 4, fileSize: 4))

        try doc.delete(range: 1..<3)
        // File shrank to 2 bytes; selection must clamp, never point past EOF.
        XCTAssertEqual(doc.size, 2)
        XCTAssertEqual(doc.selection.fileSize, 2)
        XCTAssertEqual(doc.selection.end, 2)
    }
}
