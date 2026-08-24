import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §22 the join, exercised through the real `MainViewController`: the two
/// commands, the dirty-pane warning (both answers), the seam's cut and names,
/// the two-joins-in-a-row stacking, and the caret shift on an insert at the
/// start. The open panel and the dirty-confirm are driven through the
/// controller's seams, so the tests assert on the pane's bytes and partition
/// after the join.
@MainActor
final class JoinTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// What a join flow leaves behind: the open panel it configured, and the
    /// dirty-confirm alert (if any) it would have shown.
    private final class JoinCapture {
        var openPanel: NSOpenPanel?
        var confirmAlert: NSAlert?
        var confirmShown = false
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

    /// A full controller whose active pane holds a dirty *untitled* document of
    /// `bytes` — the state a join leaves behind, so a second join must not warn.
    private func makeUntitledController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let pane = controller.windowModel.pane1
        pane.openUntitled()
        // Give the untitled document some content and make it dirty, like a
        // join would leave it.
        try pane.document?.insert(at: 0, bytes: bytes)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL?) {
        controller.windowModel.pane1.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// A temp source file holding `bytes`, removed when the test ends.
    private func makeSourceFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoinTests-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The pane's bytes for `range`, read live (edits included).
    private func paneBytes(_ pane: PaneViewModel, _ range: Range<UInt64>) throws -> [UInt8] {
        try XCTUnwrap(pane.byteStorage).read(at: range.lowerBound, length: Int(range.count))
    }

    /// Wires the controller's join seams: the open panel hands out `sources` in
    /// order, and the dirty-confirm returns `confirmResponse` (recording the
    /// alert it would have shown).
    private func wire(_ controller: MainViewController, _ capture: JoinCapture,
                      sources: [URL], confirmResponse: NSApplication.ModalResponse) {
        var index = 0
        controller.joinOpenPanel = { panel in
            capture.openPanel = panel
            defer { index += 1 }
            return index < sources.count ? sources[index] : nil
        }
        controller.joinConfirm = { alert in
            capture.confirmAlert = alert
            capture.confirmShown = true
            return confirmResponse
        }
    }

    // MARK: - The bytes after a join

    /// Append File… joins the chosen file's bytes after the pane's content. The
    /// pane detaches from its file (untitled, dirty, no undo), the seam is a cut
    /// named for both sources, and the open panel chose files, not directories.
    func testAppendJoinsTheBytesAfterTheContent() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()

        // The source's bytes land after the original content.
        XCTAssertEqual(pane.fileSize, 19)
        XCTAssertEqual(try paneBytes(pane, 0..<19),
                       [UInt8](0..<16) + [0xA0, 0xA1, 0xA2])
        // The pane detached from its file: untitled, dirty, nothing to undo.
        XCTAssertTrue(pane.isUntitled, "the join detaches the pane from its file")
        XCTAssertTrue(pane.status.isDirty, "the joined content is unsaved")
        XCTAssertFalse(pane.document?.canUndo ?? true, "the join is not undoable")
        // The seam is a cut: two pieces, named for their sources.
        let pieces = pane.segmentStore.segments
        XCTAssertEqual(pieces.map(\.range), [0..<16, 16..<19],
                       "the seam is a cut at the old end")
        XCTAssertEqual(pieces.first?.name, url.lastPathComponent,
                       "the original keeps the name of the file it was opened from")
        XCTAssertEqual(pieces.last?.name, source.lastPathComponent,
                       "the joined bytes take the source's name")
        // The open panel chose files, not directories.
        let panel = try XCTUnwrap(capture.openPanel)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        _ = window
    }

    // MARK: - The dirty-pane warning

    /// A dirty *named* pane is warned about, with two buttons — the operation's
    /// verb and Cancel. Choosing the verb proceeds: the join lands.
    func testTheDirtyWarningProceedsOnTheVerb() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        try pane.document?.overwrite(range: 0..<1, with: [0xFF])  // make it dirty
        XCTAssertTrue(pane.status.isDirty)

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()

        XCTAssertTrue(capture.confirmShown, "a dirty named pane is warned about")
        let alert = try XCTUnwrap(capture.confirmAlert)
        XCTAssertEqual(alert.buttons.map(\.title), ["Append", "Cancel"],
                       "the two buttons are the operation's verb and Cancel")
        XCTAssertEqual(pane.fileSize, 19, "choosing the verb proceeds with the join")
        _ = window
    }

    /// Choosing Cancel aborts the join: the bytes are unchanged, the pane is
    /// still attached to its file (not untitled), and still dirty.
    func testTheDirtyWarningAbortsOnCancel() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        try pane.document?.overwrite(range: 0..<1, with: [0xFF])
        XCTAssertTrue(pane.status.isDirty)

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertSecondButtonReturn)

        controller.appendFile()

        XCTAssertTrue(capture.confirmShown, "a dirty named pane is warned about")
        XCTAssertEqual(pane.fileSize, 16, "Cancel leaves the size unchanged")
        XCTAssertEqual(try paneBytes(pane, 0..<16), [0xFF] + [UInt8](1..<16),
                       "Cancel leaves the bytes unchanged")
        XCTAssertFalse(pane.isUntitled, "Cancel keeps the pane attached to its file")
        XCTAssertTrue(pane.status.isDirty, "Cancel keeps the pane dirty")
        _ = window
    }

    /// An *untitled* dirty pane gets no alert: there is no saved state to
    /// diverge from, and its content is carried like any other.
    func testAnUntitledDirtyPaneGetsNoWarning() throws {
        let (controller, window) = try makeUntitledController([UInt8](0..<16))
        defer { cleanup(controller, nil) }
        let pane = controller.windowModel.pane1
        XCTAssertTrue(pane.isUntitled)
        XCTAssertTrue(pane.status.isDirty)

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()

        XCTAssertFalse(capture.confirmShown, "an untitled dirty pane gets no alert")
        XCTAssertEqual(pane.fileSize, 19, "the join proceeds without a warning")
        _ = window
    }

    // MARK: - Two joins in a row

    /// Two joins in a row: the second joins the already-joined (already
    /// untitled) document, and the bytes stack in the order the joins asked for
    /// — an append then an insert at the start leaves three pieces with the
    /// right offsets and names.
    func testTwoJoinsInARowStackInOrder() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let appendSource = try makeSourceFile([0xA0, 0xA1, 0xA2])  // 3 bytes
        let insertSource = try makeSourceFile([0xB0, 0xB1])        // 2 bytes
        let capture = JoinCapture()
        wire(controller, capture, sources: [appendSource, insertSource],
             confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()        // original + A
        controller.insertFileAtStart() // B + original + A

        // The bytes stack in the order the joins asked for.
        XCTAssertEqual(pane.fileSize, 21)
        XCTAssertEqual(try paneBytes(pane, 0..<21),
                       [0xB0, 0xB1] + [UInt8](0..<16) + [0xA0, 0xA1, 0xA2])
        // Three pieces, with the right offsets and names.
        let pieces = pane.segmentStore.segments
        XCTAssertEqual(pieces.map(\.range), [0..<2, 2..<18, 18..<21],
                       "two joins leave three pieces with the right offsets")
        XCTAssertEqual(pieces[0].name, insertSource.lastPathComponent, "the inserted half")
        XCTAssertEqual(pieces[1].name, url.lastPathComponent, "the original content")
        XCTAssertEqual(pieces[2].name, appendSource.lastPathComponent, "the appended half")
        // The second join (into an untitled pane) did not warn.
        XCTAssertEqual(capture.confirmShown, false,
                       "the second join is into an untitled pane, so no warning")
        _ = window
    }

    // MARK: - The caret shift

    /// An insert at the start shifts the caret and selection by the inserted
    /// length, so they stay on the bytes they were on (§22.5); an append leaves
    /// them put.
    func testAnInsertAtStartShiftsTheSelection() throws {
        let (controller, window, _) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, nil) }
        let pane = controller.windowModel.pane1
        pane.setSelection(SelectionModel(start: 4, end: 8, fileSize: 16))

        let source = try makeSourceFile([0xB0, 0xB1])  // 2 bytes
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.insertFileAtStart()

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 6, "the selection start shifts by the inserted length")
        XCTAssertEqual(sel.end, 10, "the selection end shifts by the inserted length")
        _ = window
    }

    /// An append leaves the caret and selection where they were.
    func testAnAppendLeavesTheSelectionPut() throws {
        let (controller, window, _) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, nil) }
        let pane = controller.windowModel.pane1
        pane.setSelection(SelectionModel(start: 4, end: 8, fileSize: 16))

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 4, "an append leaves the selection start put")
        XCTAssertEqual(sel.end, 8, "an append leaves the selection end put")
        _ = window
    }

    // MARK: - The refusal

    /// A 0-byte source is refused before anything changes: the pane is
    /// unchanged and still attached to its file, and the refusal is reported.
    func testAnEmptySourceIsRefusedAndChangesNothing() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let empty = try makeSourceFile([])
        let capture = JoinCapture()
        wire(controller, capture, sources: [empty], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()

        XCTAssertEqual(pane.fileSize, 16, "a refused join changes no size")
        XCTAssertEqual(try paneBytes(pane, 0..<16), [UInt8](0..<16),
                       "a refused join changes no bytes")
        XCTAssertFalse(pane.isUntitled, "a refused join does not detach the pane")
        XCTAssertFalse(pane.status.isDirty, "a refused join makes nothing dirty")
        _ = window
    }
}
