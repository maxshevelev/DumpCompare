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

    /// Recursively finds the first view of type `T` in the hierarchy rooted at
    /// `root` — the pane's views are the controller's subviews, and the
    /// controller keeps no test-reachable handle to them.
    private func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        for subview in root.subviews {
            if let match = subview as? T { return match }
            if let found = findView(type, in: subview) { return found }
        }
        return nil
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
        // The pane detached from its file: untitled and dirty, and the join is
        // one undo step on top of any earlier edits (§22.2).
        XCTAssertTrue(pane.isUntitled, "the join detaches the pane from its file")
        XCTAssertTrue(pane.status.isDirty, "the joined content is unsaved")
        XCTAssertTrue(pane.document?.canUndo ?? false, "the join is one undo step")
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

    // MARK: - The caret after a join

    /// A join puts the caret at the start of the added part (§22.5) — 0 for an
    /// insert at the start, the new file's start — replacing whatever selection
    /// the pane held.
    func testAnInsertAtStartPutsTheCaretAtZero() throws {
        let (controller, window, _) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, nil) }
        let pane = controller.windowModel.pane1
        pane.setSelection(SelectionModel(start: 4, end: 8, fileSize: 16))

        let source = try makeSourceFile([0xB0, 0xB1])  // 2 bytes
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.insertFileAtStart()

        XCTAssertEqual(pane.caretOffset, 0,
                       "the caret is at 0, the start of the added part")
        _ = window
    }

    /// An append puts the caret at the seam — the start of the added part, the
    /// old end — replacing whatever selection the pane held (§22.5).
    func testAnAppendPutsTheCaretAtTheSeam() throws {
        let (controller, window, _) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, nil) }
        let pane = controller.windowModel.pane1
        pane.setSelection(SelectionModel(start: 4, end: 8, fileSize: 16))

        let source = try makeSourceFile([0xA0, 0xA1, 0xA2])  // 3 bytes
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()

        XCTAssertEqual(pane.caretOffset, 16,
                       "the caret is at the seam, the start of the added part")
        _ = window
    }

    // MARK: - The seam's reveal

    /// A join reveals its seam — the caret, at the start of the added part —
    /// centred in the pane, so the result is seen mid-pane rather than at its
    /// edge (§22.5). The file and the source are both large enough that the seam
    /// sits mid-document and the centre is not clamped to an edge: the scroll
    /// lands where the seam's row is centred, not where a plain into-view scroll
    /// would leave it.
    func testAnAppendRevealsTheSeamCentredInThePane() throws {
        // Two 4096-byte halves: the seam lands at 4096, mid-document, so
        // centring it is a real scroll, not a clamp to the top or the bottom.
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 4096))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([UInt8](repeating: 0x22, count: 4096))
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()

        window.layoutIfNeeded()
        let hexView = try XCTUnwrap(findView(HexView.self, in: controller.view),
                                    "the pane hosts a hex view")
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        let layout = hexView.hexLayout

        // The seam is where the caret landed: the old end, now mid-document.
        let seam = pane.caretOffset
        XCTAssertEqual(seam, 4096, "the caret is at the start of the added part")
        let (row, _) = layout.rowColumn(of: seam)
        let rowFrame = layout.rowFrame(row: row)
        let maxOriginY = max(0, hexView.bounds.height - clip.bounds.height)
        let expected = min(max(0, rowFrame.midY - clip.bounds.height / 2), maxOriginY)

        // The centre is a real position: not clamped to either edge.
        XCTAssertGreaterThan(expected, 0, "the seam is below the top of the document")
        XCTAssertLessThan(expected, maxOriginY, "the seam is above the bottom of the document")
        XCTAssertEqual(clip.bounds.origin.y, expected, accuracy: 0.5,
                       "the seam's row is centred in the pane, not merely scrolled into view")
    }

    /// Redoing a join re-centres the seam, the same as the join itself (§10.4,
    /// §22.5): the undo returns the caret to where it was before the join (the
    /// top of the file), and the redo restores it to the seam — outside the
    /// viewport again — so the reveal centres it.
    func testRedoingAnAppendRevealsTheSeamCentredInThePane() throws {
        // Two 4096-byte halves: the seam lands at 4096, mid-document, so
        // centring it is a real scroll, not a clamp to an edge.
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 4096))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([UInt8](repeating: 0x22, count: 4096))
        let capture = JoinCapture()
        wire(controller, capture, sources: [source], confirmResponse: .alertFirstButtonReturn)

        controller.appendFile()
        _ = try pane.undo()
        _ = try pane.redo()

        window.layoutIfNeeded()
        let hexView = try XCTUnwrap(findView(HexView.self, in: controller.view),
                                    "the pane hosts a hex view")
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        let layout = hexView.hexLayout

        // The redo restored the caret to the seam: the old end, mid-document.
        let seam = pane.caretOffset
        XCTAssertEqual(seam, 4096, "the redo put the caret back at the seam")
        let (row, _) = layout.rowColumn(of: seam)
        let rowFrame = layout.rowFrame(row: row)
        let maxOriginY = max(0, hexView.bounds.height - clip.bounds.height)
        let expected = min(max(0, rowFrame.midY - clip.bounds.height / 2), maxOriginY)

        // The centre is a real position: not clamped to either edge.
        XCTAssertGreaterThan(expected, 0, "the seam is below the top of the document")
        XCTAssertLessThan(expected, maxOriginY, "the seam is above the bottom of the document")
        XCTAssertEqual(clip.bounds.origin.y, expected, accuracy: 0.5,
                       "redoing the join re-centres the seam in the pane")
    }

    /// The same centring holds when the append is made by dropping the file on
    /// the Append-at-End band, not from the menu (§22.5): the drop joins the
    /// file and must leave the seam centred, exactly the way the menu command
    /// does — the drop's post-join mode refresh must not rebuild the pane and
    /// re-follow the caret to the top of the viewport. The sizes are the user's
    /// repro: a 7,340,032-byte file with a 9,437,184-byte file appended, the
    /// seam at 43.7% of the joined document.
    func testDroppingAnAppendRevealsTheSeamCentredInThePane() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 7_340_032))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1

        let source = try makeSourceFile([UInt8](repeating: 0x22, count: 9_437_184))

        controller.handleSingleFileDrop(target: .appendAtEnd, urls: [source])

        window.layoutIfNeeded()
        let hexView = try XCTUnwrap(findView(HexView.self, in: controller.view),
                                    "the pane hosts a hex view")
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        let layout = hexView.hexLayout

        // The seam is where the caret landed: the old end, now mid-document.
        let seam = pane.caretOffset
        XCTAssertEqual(seam, 7_340_032, "the caret is at the start of the added part")
        let (row, _) = layout.rowColumn(of: seam)
        let rowFrame = layout.rowFrame(row: row)
        let maxOriginY = max(0, hexView.bounds.height - clip.bounds.height)
        let expected = min(max(0, rowFrame.midY - clip.bounds.height / 2), maxOriginY)

        // The centre is a real position: not clamped to either edge.
        XCTAssertGreaterThan(expected, 0, "the seam is below the top of the document")
        XCTAssertLessThan(expected, maxOriginY, "the seam is above the bottom of the document")
        XCTAssertEqual(clip.bounds.origin.y, expected, accuracy: 0.5,
                       "the drop's join leaves the seam centred, as the menu's does")
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

    // MARK: - Joining a file to itself

    /// A file dropped on a pane that already holds it doubles the content, which
    /// on a bench is a slip far more often than an intention. It asks, and doing
    /// nothing is the default answer.
    func testJoiningAFileToItselfAsksFirst() throws {
        let controller = MainViewController()
        let url = try tempFile([UInt8](repeating: 0xA5, count: 32))
        controller.openFiles([url])
        let pane = controller.windowModel.pane1
        var asked: NSAlert?
        MainViewController.modalResponder = { alert in
            asked = alert
            return .alertSecondButtonReturn  // Cancel
        }
        addTeardownBlock { MainViewController.modalResponder = nil }

        controller.handleSingleFileDrop(target: .appendAtEnd, urls: [url])

        let alert = try XCTUnwrap(asked, "joining a file to itself must ask")
        XCTAssertTrue(alert.messageText.contains(url.lastPathComponent))
        XCTAssertTrue(alert.messageText.contains("to itself"))
        XCTAssertEqual(pane.fileSize, 32, "cancelled: nothing was joined")
    }

    /// It asks rather than refusing: a join copies bytes, so the doubled dump is
    /// a real document and someone may mean it.
    func testJoiningAFileToItselfIsAllowedWhenConfirmed() throws {
        let controller = MainViewController()
        let url = try tempFile([UInt8](repeating: 0xA5, count: 32))
        controller.openFiles([url])
        MainViewController.modalResponder = { _ in .alertFirstButtonReturn }
        addTeardownBlock { MainViewController.modalResponder = nil }

        controller.handleSingleFileDrop(target: .appendAtEnd, urls: [url])

        XCTAssertEqual(controller.windowModel.pane1.fileSize, 64, "the dump, twice")
    }

    /// A different file is joined without the question — it is only the same
    /// file that is worth asking about.
    func testJoiningADifferentFileDoesNotAsk() throws {
        let controller = MainViewController()
        let mine = try tempFile([UInt8](repeating: 0xA5, count: 32))
        let other = try tempFile([UInt8](repeating: 0x5A, count: 16))
        controller.openFiles([mine])
        var asked = 0
        MainViewController.modalResponder = { _ in
            asked += 1
            return .alertFirstButtonReturn
        }
        addTeardownBlock { MainViewController.modalResponder = nil }

        controller.handleSingleFileDrop(target: .appendAtEnd, urls: [other])

        XCTAssertEqual(asked, 0, "a clean pane joining another file asks nothing")
        XCTAssertEqual(controller.windowModel.pane1.fileSize, 48)
    }
}
