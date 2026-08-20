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

    func testTypeASCIIWritesGivenByte() throws {
        let (pane, url) = try openPane([0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        // Representability is decided in the view via the decoder's encode()
        // (§3.2); the VM writes whatever byte it is handed. 0xFF is ÿ in the
        // default cp1252 table; 0x00 is written verbatim (the view never
        // forwards non-encodable characters, so control bytes only reach here
        // from direct callers).
        pane.typeASCII(0xFF)
        pane.typeASCII(0x00)
        XCTAssertEqual(pane.caretOffset, 2)
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0xFF, 0x00])
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
        pane.fillSelection(with: [0])
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

    func testUndoRestoresCaretRedoReappliesIt() throws {
        let (pane, url) = try openPane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5)
        pane.typeASCII(0x41)
        XCTAssertEqual(pane.caretOffset, 6)

        XCTAssertTrue(try pane.undo())
        XCTAssertEqual(pane.caretOffset, 5, "undo returns the caret to where typing began")

        XCTAssertTrue(try pane.redo())
        XCTAssertEqual(pane.caretOffset, 6, "redo lands the caret after the byte")
    }

    func testUndoReportsNetDiffEditAndSkipsFullInvalidation() throws {
        let (pane, url) = try openPane([UInt8](repeating: 0, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }
        var edits: [DiffEdit] = []
        var fullInvalidations = 0
        pane.onEdit = { edits.append($0) }
        pane.onFullInvalidation = { fullInvalidations += 1 }

        pane.moveCaret(to: 5)
        pane.typeASCII(0x41)
        edits.removeAll()   // the forward edit's own onEdit

        try pane.undo()
        XCTAssertEqual(edits, [.overwrite(range: 5..<6)],
                       "undo derives the net edit of the typed byte — incremental, not a rebuild")
        XCTAssertEqual(fullInvalidations, 0, "undo/redo must not trigger a full-file comparison rebuild")
    }

    func testUndoRestoresTheSelectionTypingWasConsuming() throws {
        let (pane, url) = try openPane([0x00, 0x11, 0x22, 0x33, 0x44])
        defer { try? FileManager.default.removeItem(at: url) }
        let size = pane.fileSize
        pane.setSelection(SelectionModel(start: 1, end: 5, fileSize: size))

        // Typing eats the selection from its start, one byte per pair of nibbles.
        pane.typeHexNibble(0xA); pane.typeHexNibble(0xA)
        XCTAssertEqual(pane.hexSelection(), SelectionModel(start: 2, end: 5, fileSize: size),
                       "the first byte is consumed, three are left selected")
        pane.typeHexNibble(0xB); pane.typeHexNibble(0xB)
        XCTAssertEqual(pane.hexSelection(), SelectionModel(start: 3, end: 5, fileSize: size))

        try pane.undo()
        XCTAssertEqual(pane.hexSelection(), SelectionModel(start: 2, end: 5, fileSize: size),
                       "undo puts back the selection the second byte was typed into")
        XCTAssertEqual(pane.hexByteStates(in: 1..<3).map(\.byte), [0xAA, 0x22])

        try pane.undo()
        XCTAssertEqual(pane.hexSelection(), SelectionModel(start: 1, end: 5, fileSize: size),
                       "the second undo returns the selection the typing began with")
        XCTAssertEqual(pane.hexByteStates(in: 1..<3).map(\.byte), [0x11, 0x22])

        try pane.redo()
        XCTAssertEqual(pane.hexSelection(), SelectionModel(start: 2, end: 5, fileSize: size),
                       "redo returns to the state that keystroke left, remainder included")
    }

    func testUndoOfATypedByteOutsideASelectionLeavesNoSelection() throws {
        let (pane, url) = try openPane([0x00, 0x11])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.typeHexNibble(0xA); pane.typeHexNibble(0xA)

        try pane.undo()
        XCTAssertTrue(pane.hexSelection().isEmpty,
                      "an edit that began with a bare caret undoes back to a bare caret")
        XCTAssertEqual(pane.caretOffset, 0)
    }

    func testUndoOfAFillPutsTheSelectionBack() throws {
        let (pane, url) = try openPane([0x00, 0x01, 0x02, 0x03, 0x04])
        defer { try? FileManager.default.removeItem(at: url) }
        let size = pane.fileSize
        pane.setSelection(SelectionModel(start: 1, end: 4, fileSize: size))
        pane.fillSelection(with: [0xFF])
        XCTAssertTrue(pane.hexSelection().isEmpty, "the fill collapses the selection")

        try pane.undo()
        XCTAssertEqual(pane.hexSelection(), SelectionModel(start: 1, end: 4, fileSize: size),
                       "undo re-selects the region the fill covered")

        try pane.redo()
        XCTAssertTrue(pane.hexSelection().isEmpty,
                      "redo leaves what the fill left — a caret at the range start")
        XCTAssertEqual(pane.caretOffset, 1)
    }

    func testFillUndoRedoRestoreCaretToSelectionStart() throws {
        let (pane, url) = try openPane([0x00, 0x01, 0x02, 0x03, 0x04])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.setSelection(SelectionModel(start: 1, end: 4, fileSize: pane.fileSize))
        pane.fillSelection(with: [0xFF])
        XCTAssertEqual(pane.caretOffset, 1, "a fill leaves the caret at the selection start")

        try pane.undo()
        XCTAssertEqual(pane.caretOffset, 1, "undo returns to where the fill began")

        try pane.redo()
        XCTAssertEqual(pane.caretOffset, 1, "redo lands where the fill left the caret")
    }

    // MARK: - Typing series (segmented undo, Variant B)

    /// Substitutes `PaneViewModel.clock` with a controllable time source for
    /// the duration of `body`; `body` receives a closure that advances the
    /// fake clock, so the series-break and fast-undo windows are deterministic.
    private func withControllableClock(
        _ body: (_ advance: (TimeInterval) -> Void) throws -> Void
    ) rethrows {
        var now: TimeInterval = 1000
        let real = PaneViewModel.clock
        PaneViewModel.clock = { now }
        defer { PaneViewModel.clock = real }
        try body { now += $0 }
    }

    func testFastUndoRemovesTheRestOfTheTypingSeries() throws {
        let (pane, url) = try openPane([0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            pane.typeASCII(0x41)               // 'A'
            advance(0.05)
            pane.typeASCII(0x42)               // 'B'
            advance(0.05)
            pane.typeASCII(0x43)               // 'C'
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x43])

            // First undo: the last byte of the series.
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x00])
            XCTAssertEqual(pane.caretOffset, 2)

            // Fast second undo: the rest of the series in one step.
            advance(0.1)                       // within fastUndoWindow (0.5)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x00, 0x00, 0x00])
            XCTAssertEqual(pane.caretOffset, 0)
            XCTAssertFalse(pane.status.canUndo)

            // Redo is symmetric: the batch comes back in one press...
            advance(0.1)
            XCTAssertTrue(try pane.redo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x00])
            // ...and the single byte in the next.
            advance(0.1)
            XCTAssertTrue(try pane.redo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x43])
            XCTAssertEqual(pane.caretOffset, 3)
        }
    }

    func testUndoAfterAPauseRemovesOneByteAgain() throws {
        let (pane, url) = try openPane([0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            pane.typeASCII(0x41)
            advance(0.05)
            pane.typeASCII(0x42)
            advance(0.05)
            pane.typeASCII(0x43)

            XCTAssertTrue(try pane.undo())     // byte 3
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x00])

            advance(1.0)                       // longer than fastUndoWindow
            XCTAssertTrue(try pane.undo())     // byte 2 — no batch
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x00, 0x00])
            XCTAssertEqual(pane.caretOffset, 1)
        }
    }

    func testAPauseBetweenBytesBreaksTheSeries() throws {
        let (pane, url) = try openPane([0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            pane.typeASCII(0x41)               // series 1
            advance(1.0)                       // longer than seriesBreakThreshold
            pane.typeASCII(0x42)               // series 2
            advance(0.05)
            pane.typeASCII(0x43)
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x43])

            // Undo walks back series 2: C, then the batch of the rest of
            // series 2 (B only — the pause kept A in its own series).
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x00])
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x00, 0x00])
            // A fast third undo still stops at the series boundary: A comes
            // back only on its own press.
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x00, 0x00, 0x00])
        }
    }

    func testCaretMovementBreaksTheSeries() throws {
        let (pane, url) = try openPane([0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            pane.typeASCII(0x41)               // series 1, caret now at 1
            pane.moveCaret(to: 2)              // breaks the series
            pane.typeASCII(0x42)               // series 2, at offset 2
            advance(0.05)
            pane.typeASCII(0x43)               // series 2, at offset 3
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x41, 0x00, 0x42, 0x43])

            // The batch stays inside series 2: C, then B — A survives both.
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x41, 0x00, 0x42, 0x00])
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x41, 0x00, 0x00, 0x00])
        }
    }

    func testInputRegionChangeBreaksTheSeries() throws {
        let (pane, url) = try openPane([0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            pane.typeHexNibble(0x4)            // hex series: high nibble
            pane.typeHexNibble(0x1)            // → 0x41, caret 1
            pane.setInputRegion(.ascii)        // breaks the series
            pane.typeASCII(0x42)               // ascii series, at offset 1
            advance(0.05)
            pane.typeASCII(0x43)               // ascii series, at offset 2
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x43])

            // The batch stays inside the ASCII series: C, then B — the hex
            // byte 0x41 survives both.
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x42, 0x00])
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x00, 0x00])
        }
    }

    func testAutoRepeatTypingIsOneSeries() throws {
        let (pane, url) = try openPane([UInt8](repeating: 0, count: 8))
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            // A held-down key: 30–90 ms between characters — well under the
            // break threshold, so the whole run is one series.
            let bytes: [UInt8] = [0x41, 0x42, 0x43, 0x44]
            for (i, byte) in bytes.enumerated() {
                pane.typeASCII(byte)
                advance(i.isMultiple(of: 2) ? 0.03 : 0.09)
            }
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x41, 0x42, 0x43, 0x44])

            // One byte, then the whole rest in the fast second press.
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x41, 0x42, 0x43, 0x00])
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x00, 0x00, 0x00, 0x00])
            XCTAssertFalse(pane.status.canUndo)
        }
    }

    /// A save is a checkpoint the user must be able to come back to in one press
    /// (§7.5.1), so a series never spans it: the bytes typed after a save are
    /// their own series, and the fast second undo stops at the saved state
    /// instead of rolling past it.
    func testASaveBreaksTheTypingSeries() throws {
        let (pane, url) = try openPane([0x00, 0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            pane.typeASCII(0x41)
            advance(0.05)
            pane.typeASCII(0x42)
            advance(0.05)
            pane.typeASCII(0x43)
            try pane.save()
            XCTAssertFalse(pane.status.isDirty, "the three typed bytes are on disk")

            // Two more bytes, close enough in time to continue a series if the
            // save had not ended it.
            advance(0.05)
            pane.typeASCII(0x44)
            advance(0.05)
            pane.typeASCII(0x45)
            XCTAssertEqual(pane.hexByteStates(in: 0..<5).map(\.byte),
                           [0x41, 0x42, 0x43, 0x44, 0x45])
            XCTAssertTrue(pane.status.isDirty)

            XCTAssertTrue(try pane.undo())     // the last byte
            advance(0.1)                       // inside the fast-undo window
            XCTAssertTrue(try pane.undo())     // the rest of the post-save series
            XCTAssertEqual(pane.hexByteStates(in: 0..<5).map(\.byte),
                           [0x41, 0x42, 0x43, 0x00, 0x00],
                           "the batch must stop at the save, not roll through it")
            XCTAssertFalse(pane.status.isDirty,
                           "which lands exactly on the saved state")
        }
    }

    func testFastUndoDoesNotBatchSeparateEdits() throws {
        let (pane, url) = try openPane([0xFF, 0xFF, 0xFF, 0xFF])
        defer { try? FileManager.default.removeItem(at: url) }

        try withControllableClock { advance in
            pane.typeASCII(0x41)               // series 1: byte 0 → 'A', caret 1
            pane.deleteForward()               // breaker: fills byte 1 with 0x00
            advance(0.1)
            pane.typeASCII(0x42)               // series 2: byte 1 → 'B'

            // Each press undoes exactly one transaction: the typing byte...
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x41, 0x00, 0xFF, 0xFF])
            // ...the delete (no series of its own — a fast repeat does not
            // batch it with the typing series below it)...
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x41, 0xFF, 0xFF, 0xFF])
            // ...and the first typed byte.
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0xFF, 0xFF, 0xFF, 0xFF])
        }
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

    /// Repeated Shift+Right must grow the selection past anchor + 1: the
    /// moving end is `selection.end`, while the normalized `start` is the fixed
    /// anchor — moving from `start` froze the selection at one byte.
    func testShiftRightExtendsForwardByteByByte() throws {
        let (pane, url) = try openPane(Array(repeating: 0x00, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5)
        pane.moveCaret(by: 1, extendSelection: true)
        pane.moveCaret(by: 1, extendSelection: true)
        pane.moveCaret(by: 1, extendSelection: true)
        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 5)
        XCTAssertEqual(sel.end, 8)
    }

    /// Shift+Left extends backward: the moving end is the left edge, and
    /// `moveCaret(by:)` must keep walking it left, not bounce off `start`.
    func testShiftLeftExtendsBackwardByteByByte() throws {
        let (pane, url) = try openPane(Array(repeating: 0x00, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5)
        pane.moveCaret(by: -1, extendSelection: true)
        pane.moveCaret(by: -1, extendSelection: true)
        pane.moveCaret(by: -1, extendSelection: true)
        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 2)
        XCTAssertEqual(sel.end, 5)
    }

    /// Shift+Down extends forward by a whole row per press — the same moving-
    /// end rule as Shift+Right, at line granularity.
    func testShiftDownExtendsForwardByOneRowPerPress() throws {
        let (pane, url) = try openPane(Array(repeating: 0x00, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 3)
        let row = UInt64(HexLayout.bytesPerRow)
        pane.moveCaret(by: Int64(row), extendSelection: true)
        pane.moveCaret(by: Int64(row), extendSelection: true)
        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 3)
        XCTAssertEqual(sel.end, 3 + 2 * row)
    }

    /// Reversing direction must shrink from the moving end, not re-anchor at
    /// the opposite edge and start growing the other way.
    func testShiftArrowDirectionFlipShrinksFromMovingEnd() throws {
        let (pane, url) = try openPane(Array(repeating: 0x00, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5)
        pane.moveCaret(by: 1, extendSelection: true)   // (5,6)
        pane.moveCaret(by: 1, extendSelection: true)   // (5,7)
        pane.moveCaret(by: -1, extendSelection: true)  // shrink back to (5,6)
        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexSelection().end, 6)

        pane.moveCaret(to: 5)
        pane.moveCaret(by: -1, extendSelection: true)  // (4,5)
        pane.moveCaret(by: -1, extendSelection: true)  // (3,5)
        pane.moveCaret(by: 1, extendSelection: true)   // shrink back to (4,5)
        XCTAssertEqual(pane.hexSelection().start, 4)
        XCTAssertEqual(pane.hexSelection().end, 5)
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
        // The match at 2..<4 spans the caret (offset 3), so it is skipped —
        // backward must return the last match ending at or before `from` (the
        // same way forward returns the first match starting at or after `from`).
        let range = try pane.find(pattern: [0x01, 0x02], from: 3, direction: .backward)
        XCTAssertEqual(range, 0..<2)
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

    // MARK: - Insert mode typing

    /// The first hex digit in insert mode inserts a new byte at the caret with
    /// the high nibble set and the low nibble empty; the tail shifts right and
    /// the caret stays on the new byte so the next digit fills it.
    func testInsertModeFirstHexNibbleInsertsByteWithEmptyLowNibble() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true

        pane.typeHexNibble(0xA)   // high nibble → insert 0xA0 at offset 0

        XCTAssertEqual(pane.fileSize, 2)
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0xA0, 0x00])
        XCTAssertEqual(pane.caretOffset, 0, "the caret stays on the new byte")
        XCTAssertEqual(pane.hexCaretNibble(), 1)
    }

    /// The second hex digit fills the low nibble in place (no new insertion)
    /// and advances past the completed byte.
    func testInsertModeSecondHexNibbleFillsInPlaceThenAdvances() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true

        pane.typeHexNibble(0xA)   // insert 0xA0
        pane.typeHexNibble(0xB)   // fill low nibble → 0xAB, advance

        XCTAssertEqual(pane.fileSize, 2)
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0xAB, 0x00])
        XCTAssertEqual(pane.caretOffset, 1)
        XCTAssertEqual(pane.hexCaretNibble(), 0)
    }

    /// An ASCII character in insert mode inserts a whole byte at the caret.
    func testTypeASCIIInsertModeInsertsByte() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true

        pane.typeASCII(0x41)   // 'A' → insert at offset 0

        XCTAssertEqual(pane.fileSize, 2)
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0x41, 0x00])
        XCTAssertEqual(pane.caretOffset, 1)
    }

    /// Backspace on a half-typed insert-mode byte (the high nibble was just
    /// inserted, the low nibble is still pending) rolls the first nibble back:
    /// the inserted byte disappears, the tail shifts left, the caret returns to
    /// where it was, and — because the open edit group is cancelled — nothing
    /// lands on the undo stack, as if the first nibble was never entered.
    func testInsertModeBackspaceRollsBackFirstNibble() throws {
        let (pane, url) = try openPane([0x11, 0x22, 0x33])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true

        pane.typeHexNibble(0xA)   // insert 0xA0 at offset 0, tail shifts right
        XCTAssertEqual(pane.fileSize, 4)
        XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0xA0, 0x11, 0x22, 0x33])
        XCTAssertEqual(pane.caretOffset, 0)
        XCTAssertEqual(pane.hexCaretNibble(), 1)

        pane.deleteBackward()     // roll the first nibble back

        XCTAssertEqual(pane.fileSize, 3, "the inserted byte is removed, tail shifts left")
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x11, 0x22, 0x33],
                       "the file is back to its original bytes")
        XCTAssertEqual(pane.caretOffset, 0, "the caret returns to where it was")
        XCTAssertEqual(pane.hexCaretNibble(), 0)
        XCTAssertFalse(pane.status.canUndo, "the cancelled group records no undo step")
    }

    /// A mid-byte caret a *click* placed (nibble 1, but no pending insert) does
    /// not trigger the insert rollback — `pendingInsertOffset` is nil, so
    /// Backspace behaves normally: in insert mode it deletes the byte before
    /// the caret (the tail shifts left, the file shrinks by one).
    func testInsertModeBackspaceAfterClickIsNormal() throws {
        let (pane, url) = try openPane([0x11, 0x22, 0x33])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true

        // A click in the second half of byte 2 places the caret mid-byte
        // (nibble 1) without any pending insert.
        pane.hexEditor(HexView(), didClickAt: 2, region: .hex, extendSelection: false, nibble: 1)
        XCTAssertEqual(pane.caretOffset, 2)
        XCTAssertEqual(pane.hexCaretNibble(), 1)

        pane.deleteBackward()   // normal backspace, not a rollback

        XCTAssertEqual(pane.fileSize, 2, "the byte before the caret was deleted")
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0x11, 0x33],
                       "the tail shifted left over the deleted byte")
        XCTAssertEqual(pane.caretOffset, 1, "the caret takes the deleted byte's place")
        XCTAssertTrue(pane.status.canUndo, "a real delete records an undo step")
    }

    /// In insert mode, Backspace on a byte boundary deletes the byte before the
    /// caret — the tail shifts left and the file shrinks by one (a real delete,
    /// unlike overwrite mode's fill-with-0) — and undo restores it.
    func testInsertModeBackspaceDeletesByteBeforeCaret() throws {
        let (pane, url) = try openPane([0x11, 0x22, 0x33, 0x44])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true
        pane.moveCaret(to: 2)   // caret on the boundary before byte 2

        pane.deleteBackward()   // delete byte 1 (0x22)

        XCTAssertEqual(pane.fileSize, 3, "the file shrinks by one")
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x11, 0x33, 0x44],
                       "the byte before the caret is gone, the tail shifted left")
        XCTAssertEqual(pane.caretOffset, 1, "the caret takes the deleted byte's place")
        XCTAssertEqual(pane.hexCaretNibble(), 0)
        XCTAssertTrue(pane.status.canUndo)

        // Undo restores the deleted byte and the original size.
        XCTAssertTrue(try pane.undo())
        XCTAssertEqual(pane.fileSize, 4)
        XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x11, 0x22, 0x33, 0x44])
    }

    /// Toggling the typing mode only changes the caret's *appearance* — its
    /// position does not move — so it must fire the caret-appearance callback
    /// (a redraw in place) and NOT the selection-changed callback (which would
    /// scroll the view to the caret and yank it away from where the user was
    /// reading).
    func testInsertModeToggleRedrawsCaretWithoutScrolling() throws {
        let (pane, url) = try openPane([0x11, 0x22, 0x33, 0x44])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 2)

        var appearanceFired = false
        var selectionFired = false
        pane.onCaretAppearanceChanged = { appearanceFired = true }
        pane.onSelectionChanged = { selectionFired = true }

        pane.isInsertMode = true

        XCTAssertTrue(appearanceFired, "a mode flip repaints the caret in place")
        XCTAssertFalse(selectionFired, "a mode flip is not a selection move (no scroll)")
    }

    /// A mid-byte caret a click placed (nibble 1, nothing pending) is just a
    /// caret position: typing in insert mode overwrites only the low nibble of
    /// the byte the caret sits on — no new byte is inserted and the file does
    /// not shift.
    func testInsertModeTypeAfterMidByteClickOverwritesLowNibbleOnly() throws {
        let (pane, url) = try openPane([0x11, 0x22, 0x33, 0x44])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true

        // A click in the second half of byte 1 places the caret mid-byte
        // (nibble 1) with nothing pending.
        pane.hexEditor(HexView(), didClickAt: 1, region: .hex, extendSelection: false, nibble: 1)
        XCTAssertEqual(pane.hexCaretNibble(), 1)

        pane.typeHexNibble(0x9)   // fills the low nibble of byte 1 in place

        XCTAssertEqual(pane.fileSize, 4, "no byte is inserted — the file does not shift")
        XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte), [0x11, 0x29, 0x33, 0x44],
                       "only the low nibble of the byte is overwritten")
        XCTAssertEqual(pane.caretOffset, 2, "the caret advances past the byte")
        XCTAssertEqual(pane.hexCaretNibble(), 0)
    }

    /// Each insert-mode byte (high-nibble insert + low-nibble fill, coalesced
    /// into one undo step by the edit group) undoes as a unit; a fast second
    /// undo rolls back the rest of the series, and redo restores symmetrically.
    func testInsertSeriesUndoIsSegmented() throws {
        let (pane, url) = try openPane([0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true

        try withControllableClock { advance in
            pane.typeHexNibble(0x4); pane.typeHexNibble(0x1)   // 0x41
            advance(0.05)
            pane.typeHexNibble(0x4); pane.typeHexNibble(0x2)   // 0x42
            advance(0.05)
            pane.typeHexNibble(0x4); pane.typeHexNibble(0x3)   // 0x43
            XCTAssertEqual(pane.fileSize, 7)
            XCTAssertEqual(pane.hexByteStates(in: 0..<7).map(\.byte),
                           [0x41, 0x42, 0x43, 0x00, 0x00, 0x00, 0x00])

            // First undo: the last byte of the series (the file shrinks by one).
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.fileSize, 6)
            XCTAssertEqual(pane.hexByteStates(in: 0..<6).map(\.byte),
                           [0x41, 0x42, 0x00, 0x00, 0x00, 0x00])
            XCTAssertEqual(pane.caretOffset, 2)

            // Fast second undo: the rest of the series in one step.
            advance(0.1)
            XCTAssertTrue(try pane.undo())
            XCTAssertEqual(pane.fileSize, 4)
            XCTAssertEqual(pane.hexByteStates(in: 0..<4).map(\.byte),
                           [0x00, 0x00, 0x00, 0x00])
            XCTAssertEqual(pane.caretOffset, 0)
            XCTAssertFalse(pane.status.canUndo)

            // Redo is symmetric: the batch comes back in one press...
            advance(0.1)
            XCTAssertTrue(try pane.redo())
            XCTAssertEqual(pane.fileSize, 6)
            XCTAssertEqual(pane.hexByteStates(in: 0..<6).map(\.byte),
                           [0x41, 0x42, 0x00, 0x00, 0x00, 0x00])
            // ...and the single byte in the next.
            advance(0.1)
            XCTAssertTrue(try pane.redo())
            XCTAssertEqual(pane.fileSize, 7)
            XCTAssertEqual(pane.hexByteStates(in: 0..<7).map(\.byte),
                           [0x41, 0x42, 0x43, 0x00, 0x00, 0x00, 0x00])
            XCTAssertEqual(pane.caretOffset, 3)
        }
    }

    /// Default (no insert mode): typing overwrites in place and the size is
    /// unchanged — the pre-existing behavior is preserved.
    func testOverwriteModeStillOverwrites() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        pane.typeHexNibble(0xA)
        pane.typeHexNibble(0xB)

        XCTAssertEqual(pane.fileSize, 1, "overwrite never grows the file")
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0xAB)
    }

    // MARK: - Insert mode one-time warning

    /// The one-time warning fires on the first insert-mode edit and never again
    /// for the same file — not on the second nibble, not on the next byte.
    func testInsertModeFirstEditWarnsOnce() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true
        var calls = 0
        pane.confirmInsertModeWarning = { calls += 1; return true }

        pane.typeHexNibble(0xA)   // warns, inserts 0xA0
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pane.fileSize, 2)

        pane.typeHexNibble(0x4)   // completes 0xA4 — no re-warn
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0xA4)

        pane.typeHexNibble(0xB)   // next byte — still no re-warn
        XCTAssertEqual(calls, 1)
    }

    /// A cancelled warning swallows the keystroke entirely (no byte, no undo
    /// step) and does not set the warned flag, so the next keystroke re-asks.
    func testInsertModeWarningCancelSwallowsKeystroke() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true
        var allow = false
        var calls = 0
        pane.confirmInsertModeWarning = { calls += 1; return allow }

        pane.typeHexNibble(0xA)   // cancelled → swallowed
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pane.fileSize, 1)
        XCTAssertEqual(pane.caretOffset, 0)
        XCTAssertEqual(pane.hexCaretNibble(), 0)
        XCTAssertFalse(pane.status.canUndo, "nothing was inserted")

        allow = true
        pane.typeHexNibble(0xA)   // re-asks (the first was cancelled) → inserts
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(pane.fileSize, 2)
        XCTAssertEqual(pane.hexCaretNibble(), 1)
    }

    /// With no presenter injected (the pure-unit-test path) insert-mode typing
    /// proceeds without asking.
    func testInsertModeNilWarningCallbackTypesWithoutAsking() throws {
        let (pane, url) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.isInsertMode = true
        XCTAssertNil(pane.confirmInsertModeWarning)

        pane.typeHexNibble(0xA)
        pane.typeHexNibble(0xB)

        XCTAssertEqual(pane.fileSize, 2)
        XCTAssertEqual(pane.hexByteStates(in: 0..<1)[0].byte, 0xAB)
    }

    /// The warned flag is per opened file: opening a fresh file re-arms the
    /// one-time warning (the mode itself is session-global and stays on).
    func testInsertModeWarningRearmsOnNewFile() throws {
        let (pane, url1) = try openPane([0x00])
        defer { try? FileManager.default.removeItem(at: url1) }
        pane.isInsertMode = true
        var calls = 0
        pane.confirmInsertModeWarning = { calls += 1; return true }

        pane.typeHexNibble(0xA)   // warns once
        XCTAssertEqual(calls, 1)

        let url2 = try tempFile([0x00])
        defer { try? FileManager.default.removeItem(at: url2) }
        try pane.open(url: url2)

        pane.typeHexNibble(0xA)   // warns again (flag cleared on open)
        XCTAssertEqual(calls, 2)
    }
}
