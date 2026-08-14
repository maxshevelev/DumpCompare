import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Editing-rule tests for the single-file pane (hex/ASCII typing, fill-zero
/// delete, selection overwrite, paste, undo/redo, modified-byte detection).
@MainActor
final class PaneViewModelTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func openPane(_ bytes: [UInt8]) throws -> (PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        return (pane, url)
    }

    // MARK: - Open / status

    func testOpenSetsStatus() throws {
        let url = try tempFile([0x00, 0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        XCTAssertEqual(pane.fileSize, 4)
        XCTAssertEqual(pane.status.fileName, url.lastPathComponent)
        XCTAssertEqual(pane.status.fileSize, 4)
        XCTAssertEqual(pane.status.cursorHex, "0x0")
        XCTAssertFalse(pane.status.isDirty)
        XCTAssertFalse(pane.status.isReadOnly)
    }

    // MARK: - Hex nibble typing (§7)

    func testTypeHexNibblesWritesByteAndAdvances() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        pane.typeHexNibble(0xA)            // high nibble
        XCTAssertEqual(pane.hexCaretNibble(), 1)
        XCTAssertEqual(pane.caretOffset, 0)

        pane.typeHexNibble(0xB)            // low nibble → 0xAB, advance
        XCTAssertEqual(pane.hexCaretNibble(), 0)
        XCTAssertEqual(pane.caretOffset, 1)

        let state = pane.hexByteStates(in: 0..<1)[0]
        XCTAssertEqual(state.byte, 0xAB)
        XCTAssertTrue(state.isModified)
    }

    func testTypeHexIgnoresInvalidDigit() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.typeHexNibble(16)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0x00)
        XCTAssertFalse(pane.status.isDirty)
    }

    // MARK: - ASCII typing (§7)

    func testTypeASCIIWritesPrintableByte() throws {
        let (pane, url) = try openPane([0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.typeASCII(0x41)               // 'A'
        XCTAssertEqual(pane.caretOffset, 1)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0x41)
    }

    func testTypeASCIIIgnoresNonPrintable() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.typeASCII(0x00)
        pane.typeASCII(0x7F)
        pane.typeASCII(0xFF)
        XCTAssertEqual(pane.caretOffset, 0)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0x00)
    }

    // MARK: - Delete / Backspace fill zero (§7.3)

    func testDeleteForwardFillsZero() throws {
        let (pane, url) = try openPane([0xFF, 0xFF])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.deleteForward()
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0x00)
        XCTAssertEqual(pane.caretOffset, 0)
        XCTAssertEqual(pane.fileSize, 2)   // length unchanged
    }

    func testDeleteBackwardFillsZeroAndMovesCaret() throws {
        let (pane, url) = try openPane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 2)
        pane.deleteBackward()
        XCTAssertEqual(pane.caretOffset, 1)
        XCTAssertEqual(pane.hexByteStates(in: 1..<2)[0].byte, 0x00)
    }

    // MARK: - Selection overwrite (§7.4)

    func testTypingOverSelectionConsumesItByteByByte() throws {
        let (pane, url) = try openPane([0x10, 0x20, 0x30])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.setSelection(SelectionModel(start: 1, end: 3, fileSize: 3))

        pane.typeHexNibble(0xA)            // nibble 0 of byte 1
        pane.typeHexNibble(0xB)            // nibble 1 of byte 1 → 0xAB
        XCTAssertEqual(pane.hexByteStates(in: 1..<2)[0].byte, 0xAB)
        // Selection shrank to the unconsumed byte.
        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 2)
        XCTAssertEqual(sel.end, 3)
    }

    func testTypingOverSelectionFinishesAtEnd() throws {
        let (pane, url) = try openPane([0x10, 0x20])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.setSelection(SelectionModel(start: 0, end: 2, fileSize: 2))

        pane.typeASCII(0x41)  // 'A'
        pane.typeASCII(0x42)  // 'B'
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0x41, 0x42])
        XCTAssertTrue(pane.hexSelection().isEmpty)
        XCTAssertEqual(pane.caretOffset, 2)
    }

    // MARK: - Length-changing edits (§7.1, §7.2, §12)

    func testPasteWriteExtendsPastEOF() throws {
        let (pane, url) = try openPane([0xAA])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 1)  // at EOF: pasted bytes append (§12.2)
        try pane.pasteWrite([0xBB, 0xCC])
        XCTAssertEqual(pane.fileSize, 3)
        XCTAssertEqual(pane.caretOffset, 3)
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0xAA, 0xBB, 0xCC])
    }

    func testPasteWriteOverwritesFromCaret() throws {
        let (pane, url) = try openPane([0xAA, 0xBB])
        defer { try? FileManager.default.removeItem(at: url) }
        try pane.pasteWrite([0x11])  // caret at 0 → overwrite byte 0
        XCTAssertEqual(pane.fileSize, 2)
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0x11, 0xBB])
    }

    func testPasteInsertShiftsOffsets() throws {
        let (pane, url) = try openPane([0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 1)
        try pane.pasteInsert([0x99])
        XCTAssertEqual(pane.fileSize, 4)
        XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x01, 0x99, 0x02, 0x03])
        XCTAssertEqual(pane.caretOffset, 2)
    }

    func testDeleteBytesRemovesRange() throws {
        let (pane, url) = try openPane([0x01, 0x02, 0x03, 0x04])
        defer { try? FileManager.default.removeItem(at: url) }
        try pane.deleteBytes(in: 1..<3)
        XCTAssertEqual(pane.fileSize, 2)
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0x01, 0x04])
        XCTAssertEqual(pane.caretOffset, 1)
    }

    func testFillSelectionWithZero() throws {
        let (pane, url) = try openPane([0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.setSelection(SelectionModel(start: 0, end: 2, fileSize: 3))
        pane.fillSelectionWithZero()
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0x00, 0x00])
        XCTAssertEqual(pane.fileSize, 3)   // length unchanged
    }

    // MARK: - Undo / Redo

    func testUndoRedo() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.typeHexNibble(0xF)
        pane.typeHexNibble(0xF)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0xFF)
        XCTAssertTrue(pane.status.canUndo)

        XCTAssertTrue(try pane.undo())
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0x00)

        XCTAssertTrue(try pane.redo())
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0xFF)
    }

    // MARK: - Save / revert / modified detection

    func testSaveClearsDirtyAndRevertRestores() throws {
        let (pane, url) = try openPane([0x01])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.typeHexNibble(0x0)
        pane.typeHexNibble(0x2)
        XCTAssertTrue(pane.status.isDirty)

        try pane.save()
        XCTAssertFalse(pane.status.isDirty)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0x02)

        pane.typeHexNibble(0x0)
        pane.typeHexNibble(0x9)
        try pane.revert()
        XCTAssertFalse(pane.status.isDirty)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0x02)
    }

    func testModifiedByteDetection() throws {
        let (pane, url) = try openPane([0x00, 0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.typeASCII(0x41)  // 'A'
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.isModified), [true, false, false])

        try pane.save()
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.isModified), [false, false, false])
    }

    // MARK: - EOF placeholder cells

    func testEOFPlaceholderCells() throws {
        let (pane, url) = try openPane([0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: url) }
        let states = pane.hexByteStates(in: 0..<5)
        XCTAssertEqual(states.count, 5)
        XCTAssertFalse(states[0].isEOF)
        XCTAssertFalse(states[2].isEOF)
        XCTAssertTrue(states[3].isEOF)
        XCTAssertEqual(states[4].byte, 0)
        XCTAssertTrue(states[4].isEOF)
    }

    // MARK: - Caret / selection

    func testMoveCaretClampsToFileSize() throws {
        let (pane, url) = try openPane([0x01, 0x02])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 100)
        XCTAssertEqual(pane.caretOffset, 2)
        pane.moveCaret(by: -10)
        XCTAssertEqual(pane.caretOffset, 0)
    }

    func testSelectAll() throws {
        let (pane, url) = try openPane([0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.selectAll()
        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 3)
    }

    // MARK: - Find

    func testFindPatternForward() throws {
        let (pane, url) = try openPane([0xDE, 0xAD, 0xBE, 0xEF])
        defer { try? FileManager.default.removeItem(at: url) }
        let range = try pane.find(pattern: [0xAD, 0xBE], from: 0, direction: .forward)
        XCTAssertEqual(range, 1..<3)
    }

    func testFindPatternBackward() throws {
        let (pane, url) = try openPane([0x01, 0x02, 0x01, 0x02])
        defer { try? FileManager.default.removeItem(at: url) }
        let range = try pane.find(pattern: [0x01, 0x02], from: 3, direction: .backward)
        XCTAssertEqual(range, 2..<4)
    }

    func testFindReturnsNilWhenAbsent() throws {
        let (pane, url) = try openPane([0xDE, 0xAD, 0xBE, 0xEF])
        defer { try? FileManager.default.removeItem(at: url) }
        let range = try pane.find(pattern: [0x99], from: 0, direction: .forward)
        XCTAssertNil(range)
    }

    // MARK: - External change detection (§5.5)

    func testExternalWriteSurfacesExternalChange() async throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        var fired = false
        pane.onExternalChange = { fired = true }
        try await Task.sleep(nanoseconds: 300_000_000)  // watcher registration

        try Data([0x01]).write(to: url)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !fired {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(fired, "external write never surfaced")
    }

    func testOwnSaveDoesNotTriggerExternalChange() async throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        var fired = false
        pane.onExternalChange = { fired = true }
        try await Task.sleep(nanoseconds: 300_000_000)

        pane.typeASCII(0x41)  // dirty the doc, then save → own write
        try pane.save()
        try await Task.sleep(nanoseconds: 1_200_000_000)  // past the suppression window

        XCTAssertFalse(fired, "own save triggered an external-change prompt")
    }
}
