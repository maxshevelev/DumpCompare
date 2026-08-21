import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §10.1 / §20.5 — Go To and the bookmark list as one form: Return follows the
/// focus (the typed offset in the field, the selected bookmark in the list, and
/// nothing at all in the list with nothing selected), the list is where
/// bookmarks are managed, and Escape cancels a name edit before it closes the
/// window.
@MainActor
final class GoToBookmarksTests: XCTestCase {
    /// A throwaway defaults domain, so the recents these tests record never
    /// touch the real app's history (the same isolation §11's tests use).
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        isolatedSuiteName = "GoToBookmarksTests-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: isolatedSuiteName)
        GoToHistoryStore.defaults = isolatedDefaults
    }

    override func tearDown() {
        removeTempFiles()
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        GoToHistoryStore.defaults = .standard
        isolatedDefaults = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private var windows: [NSWindow] = []
    private var tempFiles: [URL] = []

    private func removeTempFiles() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goto-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        tempFiles.append(url)
        return url
    }

    // MARK: - The form on its own

    /// The form in a real window (the table needs a layout to build its cell
    /// views), with the jumps it asks for and how often it closed itself.
    private func makeForm(rows: [UInt64: String] = [:],
                          focus: GoToBookmarksController.Focus = .offsetField,
                          fileSize: UInt64 = 0x1000,
                          fill: UInt8 = 0x11)
        -> (form: GoToBookmarksController, store: BookmarkStore,
            jumps: () -> [UInt64], closes: () -> Int) {
        let store = BookmarkStore()
        for (row, name) in rows.sorted(by: { $0.key < $1.key }) {
            store.add(rowContaining: row, name: name)
        }
        var jumps: [UInt64] = []
        var closes = 0
        // Stands in for the active pane's storage: `fill` bytes up to
        // `fileSize`, and nothing at all past it.
        let form = GoToBookmarksController(
            store: store, focus: focus,
            rowBytes: { row in
                guard row < fileSize else { return nil }
                let length = Int(min(16, fileSize - row))
                return [UInt8](repeating: fill, count: length)
            },
            onGo: { jumps.append($0) })
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
        return (form, store, { jumps }, { closes })
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

    // MARK: - Return follows the focus (§10.1)

    /// The fast path: ⌘G, type, Return. The field's own action carries Return —
    /// the Go To button must NOT be a default button, or it would claim Return
    /// from the list as well.
    func testReturnInTheFieldGoesToTheTypedOffset() {
        let (form, _, jumps, closes) = makeForm()
        form.offsetCombo.stringValue = "0x30"

        form.goToTypedOffset()

        XCTAssertEqual(jumps(), [0x30])
        XCTAssertEqual(closes(), 1, "a jump dismisses the form")
        XCTAssertNil(form.goButton.keyEquivalent.first,
                     "a default button would take Return away from the list")
    }

    /// Decimal without a prefix is an offset too (§10).
    func testTheFieldTakesADecimalOffset() {
        let (form, _, jumps, _) = makeForm()
        form.offsetCombo.stringValue = "1024"

        form.goToTypedOffset()

        XCTAssertEqual(jumps(), [1024])
    }

    func testAnUnparseableOffsetShowsAnErrorAndGoesNowhere() {
        let (form, _, jumps, closes) = makeForm()
        var beeps = 0
        form.beep = { beeps += 1 }
        form.offsetCombo.stringValue = "0xZZ"

        form.goToTypedOffset()

        XCTAssertTrue(jumps().isEmpty)
        XCTAssertEqual(closes(), 0, "an invalid offset leaves the form up to correct it")
        XCTAssertFalse(form.errorLabel.stringValue.isEmpty)
        XCTAssertEqual(beeps, 1, "Return on an offset that does not parse says so out loud")
    }

    // MARK: - Validation while typing (§10.1)

    /// Typing into the field re-validates it, as the Select Block sheet's fields
    /// do (§10.2): the button follows what is in the field, and the message says
    /// what is wrong.
    func testTypingAnInvalidOffsetDisablesGoToAndSaysWhy() {
        let (form, _, _, _) = makeForm()

        form.offsetCombo.stringValue = "0x12"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                               object: form.offsetCombo))
        XCTAssertTrue(form.goButton.isEnabled)
        XCTAssertEqual(form.errorLabel.stringValue, "")

        form.offsetCombo.stringValue = "0x12Z"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                               object: form.offsetCombo))
        XCTAssertFalse(form.goButton.isEnabled, "there is nothing to go to")
        XCTAssertFalse(form.errorLabel.stringValue.isEmpty)

        form.offsetCombo.stringValue = "300"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                               object: form.offsetCombo))
        XCTAssertTrue(form.goButton.isEnabled, "a decimal offset is an offset (§10)")
        XCTAssertEqual(form.errorLabel.stringValue, "", "a stale error clears the moment it is fixed")
    }

    /// The form opens on its "0x" prefix, which is not an offset yet: the button
    /// is off, but there is no error — nothing has been typed wrong.
    func testTheFormOpensWithGoToOffAndNothingComplainedAbout() {
        let (form, _, _, _) = makeForm()

        XCTAssertEqual(form.offsetCombo.stringValue, "0x")
        XCTAssertFalse(form.goButton.isEnabled)
        XCTAssertEqual(form.errorLabel.stringValue, "")
    }

    /// A valid offset does not beep — the sound belongs to the refused Return.
    func testReturnOnAValidOffsetIsSilent() {
        let (form, _, jumps, _) = makeForm()
        var beeps = 0
        form.beep = { beeps += 1 }
        form.offsetCombo.stringValue = "0x30"

        form.goToTypedOffset()

        XCTAssertEqual(jumps(), [0x30])
        XCTAssertEqual(beeps, 0)
    }

    /// Picking a recent address re-enables the button: the field's own text
    /// catches up only after the notification, so the picked item is what the
    /// form validates.
    func testPickingARecentAddressEnablesGoTo() {
        GoToHistoryStore.record(0x7AF00)
        let (form, _, _, _) = makeForm()
        XCTAssertFalse(form.goButton.isEnabled)

        form.offsetCombo.selectItem(at: 0)

        XCTAssertTrue(form.goButton.isEnabled)
        XCTAssertEqual(form.errorLabel.stringValue, "")
    }

    func testReturnInTheListGoesToTheSelectedBookmark() throws {
        let (form, _, jumps, closes) = makeForm(rows: [0x10: "EC table", 0x100: ""],
                                                focus: .bookmarks)
        form.bookmarkTable.selectRowIndexes([1], byExtendingSelection: false)

        form.bookmarkTable.keyDown(with: try keyDown("\r", keyCode: 36))

        XCTAssertEqual(jumps(), [0x100])
        XCTAssertEqual(closes(), 1)
    }

    /// The same Return in the same window must never be a coin flip between the
    /// typed address and a guessed bookmark (§10.1).
    func testReturnInTheListWithNothingSelectedDoesNothing() throws {
        let (form, _, jumps, closes) = makeForm(rows: [0x10: "", 0x100: ""],
                                                focus: .bookmarks)
        form.bookmarkTable.deselectAll(nil)
        form.offsetCombo.stringValue = "0x30"

        form.bookmarkTable.keyDown(with: try keyDown("\r", keyCode: 36))

        XCTAssertTrue(jumps().isEmpty, "with nothing selected the list has nothing to go to")
        XCTAssertEqual(closes(), 0)
    }

    /// ⌥⌘B is opened to go to a bookmark, so the list arrives with its first one
    /// offered — the jump still takes a Return.
    func testTheListOpensWithItsFirstBookmarkSelected() {
        let (form, _, jumps, _) = makeForm(rows: [0x200: "", 0x10: ""], focus: .bookmarks)

        form.viewDidAppear()

        XCTAssertEqual(form.bookmarkTable.selectedRow, 0)
        XCTAssertTrue(jumps().isEmpty, "a selection is an offer, not a jump")
        form.goToSelectedBookmark()
        XCTAssertEqual(jumps(), [0x10], "the list is sorted by address")
    }

    func testTheFieldKeepsTheFocusWhenTheFormIsOpenedForIt() {
        let (form, _, _, _) = makeForm(rows: [0x10: ""], focus: .offsetField)

        form.viewDidAppear()

        XCTAssertEqual(form.bookmarkTable.selectedRow, -1,
                       "⌘G is about typing an address; the list offers nothing yet")
    }

    // MARK: - The mouse

    func testADoubleClickOnARowJumpsToIt() {
        let (form, _, jumps, closes) = makeForm(rows: [0x10: "", 0x100: ""])

        form.handleDoubleClick(row: 1, column: form.offsetColumnIndex)

        XCTAssertEqual(jumps(), [0x100])
        XCTAssertEqual(closes(), 1)
    }

    /// A double click on the name jumps as well: a double click activates the
    /// item, wherever in the row it lands, the way it opens a file in the Finder.
    /// Editing a bookmark is a menu command and its own popover, so no click in
    /// the list means two things (§20.5).
    func testADoubleClickOnANameJumpsToo() {
        let (form, _, jumps, closes) = makeForm(rows: [0x10: "EC table"])

        form.handleDoubleClick(row: 0, column: form.nameColumnIndex)

        XCTAssertEqual(jumps(), [0x10])
        XCTAssertEqual(closes(), 1)
        XCTAssertFalse(form.isEditingBookmark, "a double click never opens the editor")
    }

    /// Nothing in the list takes the keyboard: the name is a label, not a field,
    /// so a click on it selects the row like a click anywhere else in it.
    func testTheListHoldsNoEditableFields() throws {
        let (form, _, _, _) = makeForm(rows: [0x10: "EC table", 0x20: ""])

        for row in 0..<2 {
            let field = try nameField(form, row: row)
            XCTAssertFalse(field.isEditable, "row \(row)'s name is a label")
            XCTAssertFalse(field.isSelectable)
        }
    }

    // MARK: - Editing from the list (§20.5)

    /// The list's Edit Bookmark… opens the same popover the dump's ⇧⌘D opens
    /// (§20.3) — one editor for a bookmark, wherever it is edited from, and it can
    /// move the bookmark and delete it, which a name field in the list could not.
    func testTheListEditsABookmarkInThePopover() throws {
        let (form, store, jumps, closes) = makeForm(rows: [0x10: "EC table", 0x20: ""])
        var presented: [BookmarkEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }
        let menu = try XCTUnwrap(form.bookmarkTable.menu)
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit Bookmark…" })
        XCTAssertEqual(edit.action, #selector(GoToBookmarksController.editClickedBookmark))
        XCTAssertTrue(edit.target === form)

        form.bookmarkTable.selectRowIndexes([0], byExtendingSelection: false)
        form.editClickedBookmark()

        let popover = try XCTUnwrap(presented.first, "the editor opened")
        popover.loadViewIfNeeded()
        XCTAssertEqual(popover.row, 0x10)
        XCTAssertEqual(popover.nameField.stringValue, "EC table",
                       "on the right bookmark, with its name")
        XCTAssertTrue(form.isEditingBookmark)
        XCTAssertTrue(jumps().isEmpty, "editing is not going")
        XCTAssertEqual(closes(), 0, "and the form stays up behind it")

        popover.nameField.stringValue = "descriptor"
        popover.offsetField.stringValue = "0x40"
        popover.commit()

        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x20, name: ""),
                                         Bookmark(row: 0x40, name: "descriptor")],
                       "committing moves and renames the one bookmark")
        XCTAssertEqual(form.bookmarks.map(\.row), [0x20, 0x40], "and the list followed")
        XCTAssertFalse(form.isEditingBookmark)
    }

    /// Its Delete removes the bookmark from the list too.
    func testDeletingFromThePopoverRemovesTheRow() throws {
        let (form, store, _, _) = makeForm(rows: [0x10: "EC table", 0x20: ""])
        var presented: [BookmarkEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }
        form.bookmarkTable.selectRowIndexes([0], byExtendingSelection: false)
        form.editClickedBookmark()
        let popover = try XCTUnwrap(presented.first)
        popover.loadViewIfNeeded()

        popover.deletePressed()

        XCTAssertEqual(store.bookmarks.map(\.row), [0x20])
        XCTAssertEqual(form.bookmarks.map(\.row), [0x20])
        XCTAssertFalse(form.isEditingBookmark)
    }

    /// Escape closes the editor before it closes the form: editing a bookmark and
    /// pressing Escape must not throw the window away (§10.1).
    func testEscapeClosesTheEditorFirstAndTheFormSecond() throws {
        let (form, store, _, closes) = makeForm(rows: [0x10: "EC table"])
        var presented: [BookmarkEditPopoverController] = []
        form.editPopoverPresenter = { presented.append($0) }
        form.bookmarkTable.selectRowIndexes([0], byExtendingSelection: false)
        form.editClickedBookmark()
        let popover = try XCTUnwrap(presented.first)
        popover.loadViewIfNeeded()
        popover.nameField.stringValue = "half-typed"

        let escape = try keyDown("\u{1B}", keyCode: 53)
        XCTAssertTrue(form.view.performKeyEquivalent(with: escape),
                      "the form claims Escape while the editor is up")
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x10, name: "EC table")],
                       "the abandoned text is not written")
        XCTAssertFalse(form.isEditingBookmark)
        XCTAssertEqual(closes(), 0, "the form is still up")

        _ = form.view.performKeyEquivalent(with: escape)
        XCTAssertEqual(closes(), 1, "and the next Escape closes it")
    }

    // MARK: - Managing the list (§20.5)

    func testTheListShowsWhatTheStoreHolds() {
        let (form, store, _, _) = makeForm(rows: [0x100: "NVRAM", 0x10: ""])

        XCTAssertEqual(form.bookmarks.map(\.row), [0x10, 0x100])
        XCTAssertEqual(form.numberOfRows(in: form.bookmarkTable), 2)
        XCTAssertTrue(form.emptyLabel.isHidden)

        store.remove(rowContaining: 0x10)
        form.reloadBookmarks()
        XCTAssertEqual(form.bookmarks.map(\.row), [0x100])
    }

    /// The empty state says what a bookmark is and how one is made — a list with
    /// nothing in it is otherwise just an empty box.
    func testTheEmptyListSaysHowToMakeABookmark() {
        let (form, _, _, _) = makeForm()

        XCTAssertFalse(form.emptyLabel.isHidden)
        XCTAssertTrue(form.emptyLabel.stringValue.contains("⌘D"),
                      "the empty state names the gesture that makes a bookmark")
    }

    func testDeleteRemovesTheSelectedBookmarkAndKeepsASelection() throws {
        let (form, store, jumps, closes) = makeForm(rows: [0x10: "", 0x100: "", 0x200: ""],
                                                    focus: .bookmarks)
        form.bookmarkTable.selectRowIndexes([1], byExtendingSelection: false)

        form.bookmarkTable.keyDown(with: try keyDown("\u{7F}", keyCode: 51))

        XCTAssertEqual(store.bookmarks.map(\.row), [0x10, 0x200])
        XCTAssertEqual(form.bookmarks.map(\.row), [0x10, 0x200], "the list follows the store")
        XCTAssertEqual(form.bookmarkTable.selectedRow, 1,
                       "the selection stays put so ⌫ can be pressed again")
        XCTAssertTrue(jumps().isEmpty, "removing is not going")
        XCTAssertEqual(closes(), 0)
    }

    func testDeleteWithNothingSelectedRemovesNothing() throws {
        let (form, store, _, _) = makeForm(rows: [0x10: ""], focus: .bookmarks)
        form.bookmarkTable.deselectAll(nil)

        form.bookmarkTable.keyDown(with: try keyDown("\u{7F}", keyCode: 51))

        XCTAssertEqual(store.bookmarks.count, 1)
    }

    /// The name field of a row, as the table built it.
    private func nameField(_ form: GoToBookmarksController, row: Int) throws -> NSTextField {
        let cell = form.bookmarkTable.view(atColumn: form.nameColumnIndex, row: row,
                                           makeIfNecessary: true)
        return try XCTUnwrap((cell as? NSTableCellView)?.textField)
    }

    /// An unnamed bookmark is described by what is AT it — the row's bytes as
    /// the dump shows them (§20.5). The address is already in the column beside
    /// it, so repeating that would say nothing new.
    func testAnUnnamedBookmarkShowsTheRowsBytes() throws {
        let (form, _, _, _) = makeForm(rows: [0x10: ""], fill: 0xFF)
        let field = try nameField(form, row: 0)

        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(field.placeholderAttributedString?.string,
                       "FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF")
    }

    /// A named bookmark shows its name; the bytes are only what stands in for a
    /// name that is not there.
    func testANamedBookmarkShowsItsName() throws {
        let (form, _, _, _) = makeForm(rows: [0x10: "EC table"])

        XCTAssertEqual(try nameField(form, row: 0).stringValue, "EC table")
    }

    /// A bookmark is an absolute address and stays in the list where the file
    /// does not reach (§9), so the row says so instead of showing a blank cell.
    func testABookmarkPastTheEndOfTheFileSaysSo() throws {
        let (form, _, _, _) = makeForm(rows: [0x2000: ""], fileSize: 0x100)

        XCTAssertEqual(try nameField(form, row: 0).placeholderAttributedString?.string,
                       "Past the end of the file")
    }

    /// The last row of a file is usually a partial one — only the bytes that are
    /// there are shown.
    func testTheLastRowShowsOnlyTheBytesItHas() throws {
        let (form, _, _, _) = makeForm(rows: [0x100: ""], fileSize: 0x104, fill: 0xAB)

        XCTAssertEqual(try nameField(form, row: 0).placeholderAttributedString?.string,
                       "AB AB AB AB")
    }

    /// §20.5: bare hex digits in the list — a whole column of addresses in a
    /// window about addresses does not need each one announcing that it is hex.
    func testTheListWritesAddressesWithoutThe0xPrefix() throws {
        let (form, _, _, _) = makeForm(rows: [0x7AF00: ""])
        let cell = form.bookmarkTable.view(atColumn: form.offsetColumnIndex, row: 0,
                                           makeIfNecessary: true)
        let field = try XCTUnwrap((cell as? NSTableCellView)?.textField)

        XCTAssertEqual(field.stringValue, "0007AF00")
    }

    // MARK: - The list's height (§20.5)

    /// The list is as tall as it has rows: a form that opened with a page of
    /// empty table over three bookmarks would be mostly nothing.
    func testTheListIsAsTallAsItsRows() {
        let five = makeForm(rows: [0x00: "", 0x10: "", 0x20: "", 0x30: "", 0x40: ""]).form
        let step = five.rowStep
        let scrollHeight = five.bookmarkTable.enclosingScrollView?.frame.height ?? 0

        XCTAssertEqual(scrollHeight, 5 * step + 2, accuracy: 1,
                       "five bookmarks, five rows of table")
    }

    /// Past ten rows it stops growing and scrolls instead.
    func testTheListStopsGrowingAtTenRowsAndScrolls() throws {
        var rows: [UInt64: String] = [:]
        for index in 0..<25 { rows[UInt64(index) * 16] = "" }
        let (form, _, _, _) = makeForm(rows: rows)
        let scrollView = try XCTUnwrap(form.bookmarkTable.enclosingScrollView)

        XCTAssertEqual(form.bookmarks.count, 25)
        XCTAssertEqual(scrollView.frame.height,
                       CGFloat(GoToBookmarksController.maxVisibleRows) * form.rowStep + 2,
                       accuracy: 1, "ten rows is as tall as the list gets")
        XCTAssertGreaterThan(form.bookmarkTable.frame.height, scrollView.contentView.bounds.height,
                             "and the rest is reached by scrolling")
        XCTAssertTrue(scrollView.hasVerticalScroller)
    }

    /// An empty list keeps room for its message — two lines of text over the
    /// table, which need somewhere to be read.
    func testAnEmptyListKeepsRoomForItsMessage() throws {
        let (form, _, _, _) = makeForm()
        let scrollView = try XCTUnwrap(form.bookmarkTable.enclosingScrollView)

        XCTAssertEqual(scrollView.frame.height,
                       CGFloat(GoToBookmarksController.minVisibleRows) * form.rowStep + 2,
                       accuracy: 1)
        XCTAssertFalse(form.emptyLabel.isHidden)
    }

    /// Removing a bookmark shrinks the list with it.
    func testRemovingARowShrinksTheList() throws {
        let (form, store, _, _) = makeForm(rows: [0x00: "", 0x10: "", 0x20: "",
                                                  0x30: "", 0x40: "", 0x50: ""])
        let scrollView = try XCTUnwrap(form.bookmarkTable.enclosingScrollView)
        let before = scrollView.frame.height

        store.remove(rowContaining: 0x50)
        form.reloadBookmarks()
        form.view.layoutSubtreeIfNeeded()

        XCTAssertLessThan(scrollView.frame.height, before, "one row shorter")
    }

    // MARK: - A selected row (§20.5)

    /// On a selected row the address and the row-preview placeholder switch to
    /// the colour for text on a selection: ink blue and a dim grey are close to
    /// unreadable on the selection fill, which is what the name never had to
    /// worry about (AppKit tints a plain label by itself).
    func testASelectedRowInvertsItsAddressAndPlaceholder() throws {
        let (form, _, _, _) = makeForm(rows: [0x10: ""], fill: 0xEE)
        let offsetCell = try XCTUnwrap(form.bookmarkTable.view(atColumn: form.offsetColumnIndex,
                                                              row: 0, makeIfNecessary: true) as? NSTableCellView)
        let nameCell = try XCTUnwrap(form.bookmarkTable.view(atColumn: form.nameColumnIndex,
                                                            row: 0, makeIfNecessary: true) as? NSTableCellView)

        XCTAssertEqual(offsetCell.textField?.textColor, HexTheme.bookmarkColor,
                       "on paper the address wears the bookmark colour (§20.4)")
        let restingPlaceholder = try XCTUnwrap(nameCell.textField?.placeholderAttributedString)
        XCTAssertEqual(restingPlaceholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.secondaryLabelColor)

        offsetCell.backgroundStyle = .emphasized
        nameCell.backgroundStyle = .emphasized

        XCTAssertEqual(offsetCell.textField?.textColor, .alternateSelectedControlTextColor,
                       "selected, it reads as text on the selection")
        let selectedPlaceholder = try XCTUnwrap(nameCell.textField?.placeholderAttributedString)
        let colour = try XCTUnwrap(selectedPlaceholder.attribute(.foregroundColor, at: 0,
                                                                effectiveRange: nil) as? NSColor)
        XCTAssertLessThan(colour.alphaComponent, 1.0,
                          "still a placeholder, so still dimmer than a value")
        XCTAssertNotEqual(colour.usingColorSpace(.deviceRGB)?.redComponent,
                          NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)?.redComponent,
                          "and no longer the resting grey")
        XCTAssertEqual(selectedPlaceholder.string, restingPlaceholder.string,
                       "and it is the same preview, only recoloured")

        offsetCell.backgroundStyle = .normal
        XCTAssertEqual(offsetCell.textField?.textColor, HexTheme.bookmarkColor,
                       "deselected, it goes back to the bookmark colour")
    }

    /// The window is as tall as the form wants to be — the list sizes itself to
    /// its rows (§20.5), and the window has to follow, not the other way round.
    func testTheWindowIsAsTallAsTheForm() throws {
        let (form, store, _, _) = makeForm(rows: [0x00: "", 0x10: "", 0x20: "", 0x30: ""])
        let window = try XCTUnwrap(form.view.window)
        form.viewDidAppear()

        XCTAssertEqual(window.contentLayoutRect.height, form.view.fittingSize.height,
                       accuracy: 1, "no strip of nothing under the form")

        // And it follows the list as rows come and go.
        let before = window.contentLayoutRect.height
        for row in stride(from: UInt64(0x100), to: 0x400, by: 0x10) {
            store.add(rowContaining: row)
        }
        form.reloadBookmarks()
        XCTAssertGreaterThan(window.contentLayoutRect.height, before,
                             "more rows, a taller window")
    }

    /// The list's right-click menu removes a bookmark: ⌫ does it too, but nothing
    /// on screen says so (§20.5).
    func testTheListsContextMenuDeletesABookmark() throws {
        let (form, store, jumps, closes) = makeForm(rows: [0x10: "", 0x20: "", 0x30: ""])
        let menu = try XCTUnwrap(form.bookmarkTable.menu, "the list has a context menu")
        let item = try XCTUnwrap(menu.items.first { $0.title == "Delete Bookmark" })
        XCTAssertEqual(item.action, #selector(GoToBookmarksController.deleteClickedBookmark))
        XCTAssertTrue(item.target === form)

        // Nothing was right-clicked in a test, so the selected row stands in for
        // the clicked one — the same fallback a real click never needs.
        form.bookmarkTable.selectRowIndexes([1], byExtendingSelection: false)
        form.deleteClickedBookmark()

        XCTAssertEqual(store.bookmarks.map(\.row), [0x10, 0x30])
        XCTAssertEqual(form.bookmarks.map(\.row), [0x10, 0x30], "the list followed")
        XCTAssertTrue(jumps().isEmpty, "deleting is not going")
        XCTAssertEqual(closes(), 0, "and the form stays up")
    }

    /// With nothing clicked and nothing selected it removes nothing.
    func testTheContextMenuRemovesNothingWithNoRow() throws {
        let (form, store, _, _) = makeForm(rows: [0x10: ""])
        form.bookmarkTable.deselectAll(nil)

        form.deleteClickedBookmark()

        XCTAssertEqual(store.bookmarks.count, 1)
    }

    // MARK: - Escape is two-level (§10.1)

    /// With no edit running, the same key closes the form — that is the Cancel
    /// button's key equivalent doing its ordinary job.
    func testEscapeAtRestClosesTheForm() throws {
        let (form, _, jumps, closes) = makeForm(rows: [0x10: ""])

        _ = form.view.performKeyEquivalent(with: try keyDown("\u{1B}", keyCode: 53))

        XCTAssertEqual(closes(), 1)
        XCTAssertTrue(jumps().isEmpty, "cancelling goes nowhere")
        XCTAssertEqual(form.cancelButton.keyEquivalent, "\u{1B}")
    }

    // MARK: - Recently typed offsets

    func testAJumpFromTheFieldIsRecordedCanonically() {
        let (form, _, _, _) = makeForm()
        form.offsetCombo.stringValue = "0x7af00"

        form.goToTypedOffset()

        XCTAssertEqual(GoToHistoryStore.recent, ["0x0007AF00"],
                       "the history lists addresses, not keystrokes")
    }

    /// The recents are the offsets that were TYPED; a bookmark is already in the
    /// list below, so recording it would list it twice.
    func testAJumpFromTheListIsNotRecorded() {
        let (form, _, jumps, _) = makeForm(rows: [0x10: ""], focus: .bookmarks)
        form.bookmarkTable.selectRowIndexes([0], byExtendingSelection: false)

        form.goToSelectedBookmark()

        XCTAssertEqual(jumps(), [0x10])
        XCTAssertTrue(GoToHistoryStore.recent.isEmpty)
    }

    func testTheHistoryKeepsTheLastTenMostRecentFirst() {
        for offset in 1...12 {
            GoToHistoryStore.record(UInt64(offset) * 0x10)
        }

        let recent = GoToHistoryStore.recent
        XCTAssertEqual(recent.count, GoToHistoryStore.limit)
        XCTAssertEqual(recent.first, "0x000000C0", "12 * 0x10, the most recent")
        XCTAssertEqual(GoToHistoryStore.mostRecent, recent.first)
        XCTAssertFalse(recent.contains("0x00000010"), "the oldest two fell off")
    }

    func testRecordingAnAddressAgainMovesItToTheFront() {
        GoToHistoryStore.record(0x10)
        GoToHistoryStore.record(0x20)
        GoToHistoryStore.record(0x10)

        XCTAssertEqual(GoToHistoryStore.recent, ["0x00000010", "0x00000020"],
                       "one entry per address, most recent first")
    }

    /// The history is persisted: a form opened later offers the same addresses.
    func testTheFieldOffersThePersistedRecents() {
        GoToHistoryStore.record(0x10)
        GoToHistoryStore.record(0x7AF00)

        let (form, _, _, _) = makeForm()

        XCTAssertEqual(form.offsetCombo.objectValues as? [String],
                       ["0x0007AF00", "0x00000010"])
        XCTAssertEqual(form.offsetCombo.stringValue, "0x",
                       "the field is prefilled with the prefix, not the last address")
    }

    /// §10: the caret sits behind the "0x" so hex digits can be typed at once —
    /// the rule the sheets' `HexInputField` follows, in the combo box too.
    func testTheFieldsCaretLandsAfterThe0xPrefix() throws {
        let (form, _, _, _) = makeForm()
        let window = try XCTUnwrap(form.view.window)

        window.makeFirstResponder(form.offsetCombo)

        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0),
                       "the prefix is typed for the user, not selected")
    }

    // MARK: - Through the window's own commands (§10.1)

    /// A real controller with one file open, and the form the commands present
    /// captured instead of shown: a modal window has no one to dismiss it under
    /// XCTest.
    private func makeController(bytes: [UInt8]) throws
        -> (MainViewController, () -> [GoToBookmarksController]) {
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
        return (controller, captureForms(controller))
    }

    private func captureForms(_ controller: MainViewController)
        -> () -> [GoToBookmarksController] {
        var forms: [GoToBookmarksController] = []
        controller.goToFormPresenter = { form in
            form.loadViewIfNeeded()
            form.dismissForm = {}
            forms.append(form)
        }
        return { forms }
    }

    func testCmdGOpensTheFormOnTheFieldAndOptCmdBOnTheList() throws {
        let (controller, forms) = try makeController(bytes: [UInt8](repeating: 0x11, count: 0x100))

        controller.goToPosition()
        controller.showBookmarks()

        XCTAssertEqual(forms().count, 2, "both commands open the one form")
        XCTAssertEqual(forms().first?.focus, .offsetField)
        XCTAssertEqual(forms().last?.focus, .bookmarks)
    }

    func testTheFormGoesToATypedOffset() throws {
        let (controller, forms) = try makeController(bytes: [UInt8](repeating: 0x11, count: 0x100))
        controller.goToPosition()
        let form = try XCTUnwrap(forms().first)

        form.offsetCombo.stringValue = "0x40"
        form.goToTypedOffset()

        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, 0x40)
    }

    /// §10.1: an offset past the end of the file(s) warns and lands at the end
    /// rather than refusing to move.
    func testAnOffsetPastTheEndAlertsAndLandsAtTheEnd() throws {
        let (controller, forms) = try makeController(bytes: [UInt8](repeating: 0x11, count: 0x100))
        controller.goToPosition()
        let form = try XCTUnwrap(forms().first)

        form.offsetCombo.stringValue = "0x5000"
        form.goToTypedOffset()

        XCTAssertEqual(controller.lastAlertTitle, "Offset beyond end of file")
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, 0x100)
    }

    /// A bookmark is an absolute offset (§8), so going to one moves BOTH panes
    /// of a comparison — the same rule a typed offset follows (§10.1).
    func testAJumpFromTheListMovesBothPanesOfAComparison() throws {
        let wc = MainWindowController()
        let controller = try XCTUnwrap(wc.mainViewController)
        let urlA = try tempFile([UInt8](repeating: 0x11, count: 0x200))
        let urlB = try tempFile([UInt8](repeating: 0x22, count: 0x200))
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        wc.window?.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
        }
        let forms = captureForms(controller)
        controller.windowModel.bookmarkStore.add(rowContaining: 0x120, name: "EC table")

        controller.showBookmarks()
        let form = try XCTUnwrap(forms().first)
        form.bookmarkTable.selectRowIndexes([0], byExtendingSelection: false)
        form.goToSelectedBookmark()

        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, 0x120)
        XCTAssertEqual(controller.windowModel.pane2.hexSelection().start, 0x120,
                       "a bookmark is an absolute offset, so both panes follow it")
    }

    /// The bytes standing in for a missing name come from the ACTIVE pane: in a
    /// comparison the two files hold different bytes at the same address, and the
    /// list describes the one the user is working in (§20.5).
    func testTheListDescribesARowFromTheActivePane() throws {
        let wc = MainWindowController()
        let controller = try XCTUnwrap(wc.mainViewController)
        let urlA = try tempFile([UInt8](repeating: 0xAA, count: 0x100))
        let urlB = try tempFile([UInt8](repeating: 0xBB, count: 0x100))
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        wc.window?.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
        }
        let forms = captureForms(controller)
        controller.windowModel.bookmarkStore.add(rowContaining: 0x20)

        controller.windowModel.setActivePane(1)
        controller.showBookmarks()
        let form = try XCTUnwrap(forms().first)

        XCTAssertEqual(try nameField(form, row: 0).placeholderAttributedString?.string.prefix(5),
                       "BB BB", "pane 2 is the active one")
    }

    /// The store is the one list (§20.2): a bookmark made or removed while the
    /// form is up shows up in it, without the form having to ask.
    func testTheOpenFormFollowsTheStore() throws {
        let (controller, forms) = try makeController(bytes: [UInt8](repeating: 0x11, count: 0x100))
        controller.goToPosition()
        let form = try XCTUnwrap(forms().first)
        XCTAssertTrue(form.bookmarks.isEmpty)

        controller.windowModel.bookmarkStore.add(rowContaining: 0x30, name: "here")
        XCTAssertEqual(form.bookmarks.map(\.displayName), ["here"])

        controller.windowModel.bookmarkStore.remove(rowContaining: 0x30)
        XCTAssertTrue(form.bookmarks.isEmpty)
    }

    /// Removing the last bookmark from the list leaves the empty state behind,
    /// not an empty box.
    func testRemovingTheLastBookmarkBringsBackTheEmptyState() throws {
        let (controller, forms) = try makeController(bytes: [UInt8](repeating: 0x11, count: 0x100))
        controller.windowModel.bookmarkStore.add(rowContaining: 0x30)
        controller.showBookmarks()
        let form = try XCTUnwrap(forms().first)
        form.bookmarkTable.selectRowIndexes([0], byExtendingSelection: false)

        form.removeSelectedBookmark()

        XCTAssertTrue(form.bookmarks.isEmpty)
        XCTAssertFalse(form.emptyLabel.isHidden)
    }

    func testNeitherCommandOpensTheFormWithNoFileOpen() throws {
        let wc = MainWindowController()
        let controller = try XCTUnwrap(wc.mainViewController)
        addTeardownBlock { @MainActor in wc.close() }
        let forms = captureForms(controller)

        controller.goToPosition()
        controller.showBookmarks()

        XCTAssertTrue(forms().isEmpty, "there is nothing to navigate")
    }

    // MARK: - The menu (§10.3)

    func testTheEditMenuOffersBothWaysIn() {
        let menu = MainWindowController().makeEditMenu()

        let goTo = menu.items.first { $0.action == #selector(MainViewController.goToPosition) }
        XCTAssertEqual(goTo?.title, "Go To Position…")
        XCTAssertEqual(goTo?.keyEquivalent, "g")
        XCTAssertEqual(goTo?.keyEquivalentModifierMask, [.command])

        let bookmarks = menu.items.first { $0.action == #selector(MainViewController.showBookmarks) }
        XCTAssertEqual(bookmarks?.title, "Bookmarks…")
        XCTAssertEqual(bookmarks?.keyEquivalent, "b")
        XCTAssertEqual(bookmarks?.keyEquivalentModifierMask, [.command, .option])
    }

    func testBothCommandsAreGreyedOutWithNoFileOpen() throws {
        let wc = MainWindowController()
        let controller = try XCTUnwrap(wc.mainViewController)
        addTeardownBlock { @MainActor in wc.close() }

        for selector in [#selector(MainViewController.goToPosition),
                         #selector(MainViewController.showBookmarks)] {
            let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item),
                           "\(selector) needs a file to navigate")
        }
    }
}
