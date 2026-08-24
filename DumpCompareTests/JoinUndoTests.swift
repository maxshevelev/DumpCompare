import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §22.2 the join is undoable, exercised through the real `MainViewController`:
/// a join detaches the pane (untitled, seam cut), and ⌘Z reverses the whole
/// join — the inserted bytes are removed *and* the pane re-attaches to the file
/// it was opened from (name, watcher, and dirty state restored). The join stacks
/// on top of any earlier edits, which undo as usual. Revert to Saved keeps the
/// partition the user set up, re-based onto the saved size (§21.2).
@MainActor
final class JoinUndoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A full controller whose active pane is open over `bytes`.
    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL?) {
        controller.windowModel.pane1.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// A temp source file holding `bytes`, removed when the test ends.
    private func makeSourceFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoinUndoTests-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The pane's bytes for `range`, read live (edits included).
    private func paneBytes(_ pane: PaneViewModel, _ range: Range<UInt64>) throws -> [UInt8] {
        try XCTUnwrap(pane.byteStorage).read(at: range.lowerBound, length: Int(range.count))
    }

    // MARK: - Undo / redo of the join

    /// A join detaches the pane (untitled, seam cut); ⌘Z reverses the whole
    /// join: the inserted bytes are removed and the pane re-attaches to the file
    /// it was opened from — one piece again, no seam.
    func testUndoingAJoinRestoresThePane() throws {
        let (controller, window, url) = try makeController([UInt8](0x10..<0x20))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        try pane.join(contentsOf: source, at: .end)

        XCTAssertEqual(pane.fileSize, 19)
        XCTAssertEqual(try paneBytes(pane, 0..<19), [UInt8](0x10..<0x20) + [0xA0, 0xA1, 0xA2])
        XCTAssertTrue(pane.isUntitled, "the join detaches the pane from its file")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<16, 16..<19],
                       "the seam is a cut at the old end")

        XCTAssertTrue(try pane.undo(), "the join is an undoable step")

        XCTAssertEqual(pane.fileSize, 16, "the joined bytes are removed")
        XCTAssertEqual(try paneBytes(pane, 0..<16), [UInt8](0x10..<0x20),
                       "the original content is back")
        XCTAssertFalse(pane.isUntitled, "undoing the join re-attaches to the file")
        XCTAssertEqual(pane.status.fileName, url.lastPathComponent,
                       "the original file name is restored")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<16],
                       "the seam cut is gone: one piece again")
        _ = window
    }

    /// Redoing the join re-inserts the bytes and re-detaches the pane — the
    /// inverse of the undo.
    func testRedoingAJoinRejoins() throws {
        let (controller, window, url) = try makeController([UInt8](0x10..<0x20))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        try pane.join(contentsOf: source, at: .end)
        _ = try pane.undo()
        XCTAssertFalse(pane.isUntitled)

        XCTAssertTrue(try pane.redo(), "the join can be redone")

        XCTAssertEqual(pane.fileSize, 19, "the joined bytes are back")
        XCTAssertEqual(try paneBytes(pane, 0..<19), [UInt8](0x10..<0x20) + [0xA0, 0xA1, 0xA2])
        XCTAssertTrue(pane.isUntitled, "redoing the join re-detaches the pane")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<16, 16..<19],
                       "the seam cut is back")
        _ = window
    }

    /// The join stacks on top of an earlier edit: undoing the join reverts it
    /// (and re-attaches), and a further undo reverts the earlier edit, landing
    /// back at the saved bytes.
    func testAJoinStacksOnAnEarlierEdit() throws {
        let (controller, window, url) = try makeController([UInt8](0x10..<0x20))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        // An earlier edit: overwrite byte 0.
        pane.typeASCII(0x41)
        XCTAssertEqual(try paneBytes(pane, 0..<1), [0x41], "the edit stands")

        let source = try makeSourceFile([0xA0])
        try pane.join(contentsOf: source, at: .end)
        XCTAssertEqual(pane.fileSize, 17)

        // Undo the join: the joined byte is removed and the file is re-attached,
        // but the earlier edit still stands.
        _ = try pane.undo()
        XCTAssertEqual(pane.fileSize, 16)
        XCTAssertFalse(pane.isUntitled, "undoing the join re-attaches the pane")
        XCTAssertEqual(try paneBytes(pane, 0..<1), [0x41],
                       "the earlier edit still stands after the join is undone")

        // Undo the earlier edit: back to the saved byte.
        _ = try pane.undo()
        XCTAssertEqual(try paneBytes(pane, 0..<1), [0x10],
                       "the earlier edit is undone after the join")
        _ = window
    }

    // MARK: - Revert keeps the partition (§21.2)

    /// A Revert to Saved keeps the partition the user set up: the cut survives,
    /// re-based onto the saved size, and the bytes go back to the saved content.
    func testRevertKeepsThePartition() throws {
        let (controller, window, url) = try makeController([UInt8](0x10..<0x20))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        // The user sets up a cut, then makes an edit.
        XCTAssertTrue(pane.segmentStore.addCut(at: 8))
        pane.typeASCII(0x41)
        XCTAssertEqual(try paneBytes(pane, 0..<1), [0x41], "the edit stands")

        try pane.revert()

        XCTAssertEqual(pane.fileSize, 16)
        XCTAssertEqual(try paneBytes(pane, 0..<1), [0x10], "the bytes are back to the saved content")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<8, 8..<16],
                       "the cut survives the revert")
        _ = window
    }

    /// A Revert to Saved re-bases the partition onto the saved size: a cut that
    /// an insert pushed past the new EOF is dropped, and the partition stays
    /// consistent.
    func testRevertRebasesACutPastTheNewEnd() throws {
        let (controller, window, url) = try makeController([UInt8](0x10..<0x20))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        // A cut at 12, then an insert at the start that pushes the cut to 20
        // (size 24). A plain insert (not a join) so no seam cut is added.
        XCTAssertTrue(pane.segmentStore.addCut(at: 12))
        try pane.pasteInsert([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])
        XCTAssertEqual(pane.fileSize, 24)
        XCTAssertEqual(pane.segmentStore.cuts, [20],
                       "the insert at the start pushed the cut from 12 to 20")

        // Revert: the size goes back to 16, and the cut at 20 is past the new
        // EOF, so it is dropped — one piece again.
        try pane.revert()

        XCTAssertEqual(pane.fileSize, 16)
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<16],
                       "the cut past the new EOF is dropped")
        _ = window
    }
}
