import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.4 — The Segments form: the pieces in a table (label, start, size, name),
/// a row editor that is the Add Cut popover (offset and description), a +/−
/// footer, and the row's context menu. The form follows the pane's store, so a
/// cut made from the dump's own context menu shows up in the list without the
/// form having to ask.
@MainActor
final class SegmentsFormTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A pane over a real temp file, open and ready to take cuts.
    private func makePane(_ bytes: [UInt8]) throws -> (PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        return (pane, url)
    }

    /// The form in a real window (the table needs a layout to build its cell
    /// views), with the jumps it asks for and how often it closed itself.
    private func makeForm(cuts: [UInt64] = [], names: [Int: String] = [:],
                          fileSize: UInt64 = 0x100)
        throws -> (form: SegmentsFormController, pane: PaneViewModel, url: URL,
                   jumps: () -> [UInt64], closes: () -> Int) {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: Int(fileSize)))
        for cut in cuts.sorted() { pane.segmentStore.addCut(at: cut) }
        for (index, name) in names { pane.segmentStore.rename(index, to: name) }
        var jumps: [UInt64] = []
        var closes = 0
        let form = SegmentsFormController(pane: pane) { jumps.append($0) }
        // `dismiss` traps on a controller that was never presented, and a modal
        // window would have no one to close it under XCTest.
        form.dismissForm = { closes += 1 }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // ARC owns this window; letting AppKit release it on close as well is an
        // over-release, and it crashes the test host at the pool pop.
        window.isReleasedWhenClosed = false
        window.contentViewController = form
        window.setContentSize(NSSize(width: 520, height: 420))
        window.layoutIfNeeded()
        windows.append(window)
        return (form, pane, url, { jumps }, { closes })
    }

    /// A full controller whose active pane is open, with the forms it presents
    /// captured — the setup the presenter's own wiring (the store following)
    /// reads.
    private func makeController(_ bytes: [UInt8]) throws
        -> (MainViewController, () -> [SegmentsFormController]) {
        let wc = MainWindowController()
        let controller = try XCTUnwrap(wc.mainViewController)
        let url = try tempFile(bytes)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        wc.window?.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            controller.windowModel.pane1.close()
            wc.close()
        }
        var forms: [SegmentsFormController] = []
        controller.segmentsFormPresenter = { form in
            form.loadViewIfNeeded()
            form.dismissForm = {}
            forms.append(form)
        }
        return (controller, { forms })
    }

    /// A keyDown for the list's own keys, so Return and ⌫ are tested where the
    /// user presses them rather than through the methods they call.
    private func keyDown(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: characters,
                                       charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }

    /// The text of one cell of the list, by column and row.
    private func cellText(_ form: SegmentsFormController, _ column: NSTableColumn,
                          row: Int) -> String {
        let view = form.tableView(form.segmentTable, viewFor: column, row: row)
            as? NSTableCellView
        return view?.textField?.stringValue ?? ""
    }

    // MARK: - The table

    /// The table shows the pieces in file order: the positional label, the
    /// piece's opening offset in the dump's own bare-hex address shape, its
    /// length in the app's byte-size shape, and its name — a freshly opened
    /// file's piece is named for the file, and a piece never named shows an
    /// empty cell.
    func testTheTableShowsThePiecesInFileOrder() throws {
        let (form, _, url, _, _) = try makeForm(cuts: [8, 16], names: [1: "middle"])
        let label = form.segmentTable.tableColumns[0]
        let start = form.segmentTable.tableColumns[1]
        let size = form.segmentTable.tableColumns[2]
        let name = form.segmentTable.tableColumns[3]

        XCTAssertEqual(form.segments.map(\.range), [0..<8, 8..<16, 16..<0x100])
        XCTAssertEqual(cellText(form, label, row: 0), "S0")
        XCTAssertEqual(cellText(form, label, row: 1), "S1")
        XCTAssertEqual(cellText(form, label, row: 2), "S2")
        XCTAssertEqual(cellText(form, start, row: 0), "00000000")
        XCTAssertEqual(cellText(form, start, row: 1), "00000008")
        XCTAssertEqual(cellText(form, start, row: 2), "00000010")
        XCTAssertEqual(cellText(form, size, row: 0), "8 B")
        XCTAssertEqual(cellText(form, size, row: 1), "8 B")
        XCTAssertEqual(cellText(form, size, row: 2), "240 B")
        XCTAssertEqual(cellText(form, name, row: 0), url.lastPathComponent,
                       "a freshly opened file's piece is named for the file")
        XCTAssertEqual(cellText(form, name, row: 1), "middle")
        XCTAssertEqual(cellText(form, name, row: 2), "")
    }

    // MARK: - The row editor

    /// A double click opens the piece's editor: the offset field starts at the
    /// piece's own start, so the field opens not red, and committing moves the
    /// cut and renames the piece in one act.
    func testTheRowEditorMovesTheCutAndRenamesThePiece() throws {
        let (form, pane, _, jumps, closes) = try makeForm(cuts: [8, 16])
        var presented: [CutEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }

        form.handleDoubleClick(row: 1)   // S1, the piece that opens at 8

        let popover = try XCTUnwrap(presented.first, "a double click opens the editor")
        popover.loadViewIfNeeded()
        XCTAssertEqual(popover.offsetField.stringValue, "0x8",
                       "the field starts at the piece's own start")
        XCTAssertEqual(popover.editedOffset, 8,
                       "the current offset is legal, so the field opens not red")

        popover.offsetField.stringValue = "0xC"
        popover.descriptionField.stringValue = "header"
        popover.commit()

        XCTAssertEqual(pane.segmentStore.cuts, [0xC, 0x10], "the cut moved from 8 to 0xC")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range),
                       [0..<0xC, 0xC..<0x10, 0x10..<0x100])
        XCTAssertEqual(pane.segmentStore.segments[1].name, "header",
                       "the piece that opened at 8 is the one the description names")
        XCTAssertEqual(form.segments.map(\.range), [0..<0xC, 0xC..<0x10, 0x10..<0x100],
                       "and the list followed")
        XCTAssertFalse(form.isEditingSegment)
        XCTAssertTrue(jumps().isEmpty, "editing is not going")
        XCTAssertEqual(closes(), 0, "and the form stays up behind it")
    }

    /// S0 has no cut to move: its offset is the file start, locked to 0, so the
    /// editor renames the piece and nothing else.
    func testEditingS0RenamesButCannotMove() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8])
        var presented: [CutEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }

        form.handleDoubleClick(row: 0)

        let popover = try XCTUnwrap(presented.first)
        popover.loadViewIfNeeded()
        XCTAssertEqual(popover.offsetField.stringValue, "0x0")
        XCTAssertEqual(popover.editedOffset, 0, "0 is the one legal offset for S0")

        popover.offsetField.stringValue = "0x4"
        XCTAssertNil(popover.editedOffset, "S0 cannot move: the field goes red")

        popover.offsetField.stringValue = "0x0"
        popover.descriptionField.stringValue = "preamble"
        popover.commit()

        XCTAssertEqual(pane.segmentStore.cuts, [8], "the cut did not move")
        XCTAssertEqual(pane.segmentStore.segments[0].name, "preamble",
                       "but the name changed")
    }

    /// A double click opens the editor with the piece's current name in the
    /// description, so editing a named piece does not open blank (§21.4).
    func testTheRowEditorOpensWithThePiecesCurrentName() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8, 16], names: [1: "middle"])
        var presented: [CutEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }

        form.handleDoubleClick(row: 1)   // S1, named "middle"

        let popover = try XCTUnwrap(presented.first)
        popover.loadViewIfNeeded()
        XCTAssertEqual(popover.descriptionField.stringValue, "middle",
                       "the description opens with the piece's current name")
        XCTAssertFalse(popover.focusOffset, "the caret stays on the description")

        // Committing without changing the name keeps it.
        popover.commit()
        XCTAssertEqual(pane.segmentStore.segments[1].name, "middle",
                       "an unchanged name is kept")
    }

    /// The editor's Esc closes it and leaves the piece as it was — and with no
    /// editor up, Escape falls through to the form's own Close.
    func testEscapeClosesTheEditorBeforeTheForm() throws {
        let (form, pane, _, _, closes) = try makeForm(cuts: [8])
        var presented: [CutEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }
        form.handleDoubleClick(row: 1)
        let popover = try XCTUnwrap(presented.first)
        popover.loadViewIfNeeded()
        popover.offsetField.stringValue = "0xC"

        XCTAssertTrue(form.cancelEdit(), "Escape's first level is the editor")
        XCTAssertFalse(form.isEditingSegment)
        XCTAssertEqual(pane.segmentStore.cuts, [8], "the piece is as it was")

        XCTAssertFalse(form.cancelEdit(), "with no editor up, Escape falls through")
        XCTAssertEqual(closes(), 0, "to the Close button, which the key equivalent — not this — drives")
    }

    // MARK: - The +/− footer

    /// `+` opens the Add Cut popover with the offset field empty — just the
    /// `0x` prefix — and the caret on it: from the form the cut has no caret to
    /// start from, the offset is the thing to be filled in (§21.4).
    func testThePlusButtonOpensTheAddCutPopover() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8])
        var presented: [CutEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }

        form.addCutPressed()

        let popover = try XCTUnwrap(presented.first, "`+` opens the Add Cut popover")
        popover.loadViewIfNeeded()
        XCTAssertEqual(popover.offsetField.stringValue, "0x",
                       "the offset opens empty, just the prefix")
        XCTAssertTrue(popover.focusOffset, "the caret goes to the offset")
        XCTAssertNil(popover.editedOffset, "an unfilled offset is not a cut yet")

        popover.offsetField.stringValue = "0x14"
        popover.descriptionField.stringValue = "second half"
        popover.commit()

        XCTAssertEqual(pane.segmentStore.cuts, [8, 0x14], "committing makes the cut")
        XCTAssertEqual(pane.segmentStore.segments[2].name, "second half",
                       "and names the piece that starts there")
        XCTAssertEqual(form.segments.map(\.range), [0..<8, 8..<0x14, 0x14..<0x100],
                       "and the list followed")
    }

    /// `+` with the offset left unfilled makes no segment: an empty `0x` is not
    /// a cut, so committing or closing it changes nothing (§21.4).
    func testThePlusButtonMakesNoCutWhileTheOffsetIsUnfilled() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8])
        var presented: [CutEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }
        var beeps = 0

        form.addCutPressed()
        let popover = try XCTUnwrap(presented.first)
        popover.loadViewIfNeeded()
        popover.beep = { beeps += 1 }

        popover.commit()
        XCTAssertEqual(pane.segmentStore.cuts, [8], "an unfilled offset makes no cut")
        XCTAssertEqual(beeps, 1, "a refused commit beeps")

        // And a stray close with the field still empty keeps nothing.
        form.addCutPressed()
        let stray = try XCTUnwrap(presented.last)
        stray.loadViewIfNeeded()
        stray.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(pane.segmentStore.cuts, [8], "a stray close keeps no empty cut")
    }

    /// `−` is disabled only when the pane is a single piece — there is no
    /// neighbour to merge into. With more than one piece it is enabled, whether
    /// or not a row is selected (§21.4).
    func testMinusIsDisabledOnlyOnASinglePiece() throws {
        let (single, _, _, _, _) = try makeForm()
        single.selectSegment(atIndex: 0)
        XCTAssertFalse(single.removeButton.isEnabled,
                       "a single piece has no neighbour to merge into")

        let (partitioned, _, _, _, _) = try makeForm(cuts: [8])
        XCTAssertTrue(partitioned.removeButton.isEnabled,
                      "two pieces: a neighbour to merge into exists")
        partitioned.segmentTable.deselectAll(nil)
        XCTAssertTrue(partitioned.removeButton.isEnabled,
                      "and it stays enabled with no selection")
    }

    /// `−` is the same width as `+`, so it does not read as a smaller, disabled
    /// button beside a full `+` (§21.4).
    func testMinusIsTheSameWidthAsPlus() throws {
        let (form, _, _, _, _) = try makeForm()
        XCTAssertGreaterThan(form.addButton.frame.width, 0, "the footer is laid out")
        XCTAssertEqual(form.removeButton.frame.width, form.addButton.frame.width,
                       "the two footer buttons are the same width")
    }

    // MARK: - The button row

    /// Remove All asks first, and once confirmed leaves one piece — the whole
    /// file, named for it (§21.4). A "No" leaves the partition as it was, and a
    /// single piece has nothing to remove.
    func testRemoveAllAsksAndResetsToOnePiece() throws {
        let (single, _, _, _, _) = try makeForm()
        XCTAssertFalse(single.removeAllButton.isEnabled,
                       "a single piece has nothing to remove")

        let (form, pane, url, _, _) = try makeForm(cuts: [8, 16])
        XCTAssertTrue(form.removeAllButton.isEnabled, "partitioned: Remove All is on")
        form.confirmRemoveAll = { true }

        form.removeAllPressed()

        XCTAssertEqual(pane.segmentStore.cuts, [], "every cut is gone")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<0x100],
                       "one piece, the whole file")
        XCTAssertEqual(pane.segmentStore.segments[0].name, url.lastPathComponent,
                       "named for the file")
        XCTAssertFalse(form.removeAllButton.isEnabled,
                       "back to one piece, Remove All is disabled again")

        // A "No" leaves the partition as it was.
        let (kept, keptPane, _, _, _) = try makeForm(cuts: [8, 16])
        kept.confirmRemoveAll = { false }
        kept.removeAllPressed()
        XCTAssertEqual(keptPane.segmentStore.cuts, [8, 16], "declining keeps the cuts")
    }

    /// Once the dump is partitioned, `−` is enabled on every piece — S0 too,
    /// which is removed by re-opening the piece below at the file start.
    func testMinusIsEnabledOnEveryPieceOncePartitioned() throws {
        let (form, _, _, _, _) = try makeForm(cuts: [8, 16])

        form.selectSegment(atIndex: 0)
        XCTAssertTrue(form.removeButton.isEnabled, "S0 is removable once the dump is partitioned")
        form.selectSegment(atIndex: 1)
        XCTAssertTrue(form.removeButton.isEnabled, "a middle piece is removable")
        form.selectSegment(atIndex: 2)
        XCTAssertTrue(form.removeButton.isEnabled, "the last piece is removable")
    }

    /// Removing a middle piece merges its bytes into a neighbour that keeps its
    /// name, and the selection stays where the row was.
    func testMinusRemovesTheSelectedPiece() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8, 16], names: [2: "tail"])
        form.selectSegment(atIndex: 1)

        form.removeCutPressed()

        XCTAssertEqual(pane.segmentStore.cuts, [16], "the piece's cut is gone")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<16, 16..<0x100],
                       "its bytes merged into the neighbour")
        XCTAssertEqual(pane.segmentStore.segments[1].name, "tail",
                       "and the neighbour that kept them kept its name")
        XCTAssertEqual(form.selectedSegmentIndex, 1,
                       "the selection stays where the row was")
    }

    /// Removing S0 reopens the piece below at the file start: what was S1
    /// becomes S0, keeping its name.
    func testRemovingS0RenumbersThePieceBelow() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8, 16], names: [1: "middle"])
        form.selectSegment(atIndex: 0)

        form.removeCutPressed()

        XCTAssertEqual(pane.segmentStore.cuts, [16], "S0 removed, one cut left")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<16, 16..<0x100])
        XCTAssertEqual(pane.segmentStore.segments[0].name, "middle",
                       "the promoted piece keeps its name")
        XCTAssertEqual(form.segments.map(\.name), ["middle", ""], "and the list shows it")
        XCTAssertEqual(form.selectedSegmentIndex, 0, "the selection took the promoted row")
    }

    /// ⌫ is `−`: the same removal, from the list's own key.
    func testBackspaceDoesWhatMinusDoes() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8, 16])
        form.selectSegment(atIndex: 1)

        form.segmentTable.keyDown(with: try keyDown("\u{7F}", keyCode: 51))

        XCTAssertEqual(pane.segmentStore.cuts, [16], "⌫ removed the selected piece")
        XCTAssertEqual(form.selectedSegmentIndex, 1, "and the selection stayed where the row was")
    }

    // MARK: - The row's context menu

    /// The row menu carries what acts on one piece — Save Segment…, Replace
    /// Segment from File…, Edit…, Remove Segment — all aimed at the form, with
    /// the Stage 4/6 acts greyed until they land.
    func testTheRowMenuCarriesThePieceActions() throws {
        let (form, _, _, _, _) = try makeForm(cuts: [8, 16])
        let menu = try XCTUnwrap(form.segmentTable.menu)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles, ["Save Segment…", "Replace Segment from File…",
                                "", "Edit…", "Remove Segment"])

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.target === form, "\(item.title) is aimed at the form")
        }

        form.selectSegment(atIndex: 1)
        let save = try XCTUnwrap(menu.items.first { $0.title == "Save Segment…" })
        let replace = try XCTUnwrap(menu.items.first { $0.title == "Replace Segment from File…" })
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove Segment" })
        XCTAssertFalse(form.validateMenuItem(save), "Save Segment… is Stage 4")
        XCTAssertFalse(form.validateMenuItem(replace), "Replace Segment from File… is Stage 6")
        XCTAssertTrue(form.validateMenuItem(remove),
                      "Remove Segment needs a piece with a neighbour, and there is one")
    }

    /// The row menu's Remove Segment acts on the piece the menu was built for
    /// (the selection, when no row was right-clicked), and greys out on a pane
    /// that is a single piece.
    func testTheRowMenuRemovesThePiecesPiece() throws {
        let (form, pane, _, _, _) = try makeForm(cuts: [8, 16])
        let menu = try XCTUnwrap(form.segmentTable.menu)
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove Segment" })

        form.selectSegment(atIndex: 1)
        form.removeClickedSegment()

        XCTAssertEqual(pane.segmentStore.cuts, [16], "the selected piece is gone")

        // Down to one piece, the item greys out: there is no neighbour to merge
        // into.
        form.selectSegment(atIndex: 0)
        form.removeClickedSegment()
        XCTAssertFalse(form.validateMenuItem(remove), "a single piece has nothing to remove")
    }

    // MARK: - Following the store

    /// The store is the one list (§21.4): a cut made while the form is up — from
    /// the dump's own context menu — shows up in it, without the form having to
    /// ask. This is the presenter's wiring, so it is tested through the
    /// controller that makes it.
    func testTheFormFollowsACutMadeElsewhere() throws {
        let (controller, forms) = try makeController([UInt8](repeating: 0x11, count: 0x100))
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)

        controller.showSegments()
        let form = try XCTUnwrap(forms().first)
        XCTAssertEqual(form.segments.map(\.range), [0..<8, 8..<0x100])
        form.selectSegment(atIndex: 0)

        pane.segmentStore.addCut(at: 16)

        XCTAssertEqual(form.segments.map(\.range), [0..<8, 8..<16, 16..<0x100],
                       "the new piece is in the list without the form asking")
        XCTAssertEqual(form.selectedSegmentIndex, 0,
                       "and the selection stayed on the piece it was on")
    }

    // MARK: - Keys

    /// ⌥⌘S opens the Segments form: the Edit menu's Segments… item carries the
    /// Option variant of ⌘S (⌘S is Save, ⇧⌘S is Save As), the way Bookmarks…
    /// carries ⌥⌘B (§21.4).
    func testTheSegmentsFormSitsOnOptCmdS() throws {
        let items = MainWindowController().makeEditMenu().items
        let segments = try XCTUnwrap(items.first { $0.title == "Segments…" })
        XCTAssertEqual(segments.keyEquivalent, "s")
        XCTAssertEqual(segments.keyEquivalentModifierMask, [.command, .option])
    }

    /// Return goes to the selected piece's start: the form asks for the jump and
    /// closes, the way the Go To form's jump does.
    func testReturnGoesToTheSelectedPiecesStart() throws {
        let (form, _, _, jumps, closes) = try makeForm(cuts: [8, 16])
        form.selectSegment(atIndex: 1)

        form.segmentTable.keyDown(with: try keyDown("\r", keyCode: 36))

        XCTAssertEqual(jumps(), [8], "Return goes to the selected piece's start")
        XCTAssertEqual(closes(), 1, "and the form goes first")
    }

    /// The same Return in the same window must never be a coin flip: with
    /// nothing selected it goes nowhere and leaves the form up.
    func testReturnWithNothingSelectedDoesNothing() throws {
        let (form, _, _, jumps, closes) = try makeForm(cuts: [8])
        form.segmentTable.deselectAll(nil)

        form.segmentTable.keyDown(with: try keyDown("\r", keyCode: 36))

        XCTAssertTrue(jumps().isEmpty, "nothing selected, nowhere to go")
        XCTAssertEqual(closes(), 0, "and the form stays up")
    }
}
