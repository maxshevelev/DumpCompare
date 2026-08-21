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
                          focus: GoToBookmarksController.Focus = .offsetField)
        -> (form: GoToBookmarksController, store: BookmarkStore,
            jumps: () -> [UInt64], closes: () -> Int) {
        let store = BookmarkStore()
        for (row, name) in rows.sorted(by: { $0.key < $1.key }) {
            store.add(rowContaining: row, name: name)
        }
        var jumps: [UInt64] = []
        var closes = 0
        let form = GoToBookmarksController(store: store, focus: focus) { jumps.append($0) }
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
        form.offsetCombo.stringValue = "0xZZ"

        form.goToTypedOffset()

        XCTAssertTrue(jumps().isEmpty)
        XCTAssertEqual(closes(), 0, "an invalid offset leaves the form up to correct it")
        XCTAssertFalse(form.errorLabel.stringValue.isEmpty)
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

    /// On a name the same gesture renames instead: a double click that jumped
    /// from the name column would leave no way to rename with the mouse.
    func testADoubleClickOnANameEditsItInsteadOfJumping() {
        let (form, _, jumps, closes) = makeForm(rows: [0x10: "EC table"])

        form.handleDoubleClick(row: 0, column: form.nameColumnIndex)

        XCTAssertTrue(jumps().isEmpty)
        XCTAssertEqual(closes(), 0)
        XCTAssertEqual(form.editingNameRow, 0)
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

    func testANameEditedInTheListRenamesTheBookmark() throws {
        let (form, store, _, _) = makeForm(rows: [0x10: "old"])
        let field = try nameField(form, row: 0)
        XCTAssertEqual(field.stringValue, "old")
        XCTAssertTrue(field.isEditable, "the name is edited where it is listed")

        field.stringValue = "  EC table  "
        form.nameEdited(field)

        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x10, name: "EC table")],
                       "§20.2 trims the name")
        XCTAssertNil(form.editingNameRow)
    }

    /// An unnamed bookmark shows an empty name cell: the Offset column beside it
    /// is already the address it is called by (§20.2), and printing that address
    /// twice on one row says nothing new.
    func testAnUnnamedBookmarkShowsNoNameAtAll() throws {
        let (form, _, _, _) = makeForm(rows: [0x10: ""])
        let field = try nameField(form, row: 0)

        XCTAssertEqual(field.stringValue, "")
        XCTAssertNil(field.placeholderString)
    }

    // MARK: - Escape is two-level (§10.1)

    /// Editing a name and pressing Escape must not throw the window away.
    func testEscapeDuringANameEditCancelsTheEditAndKeepsTheForm() throws {
        let (form, store, _, closes) = makeForm(rows: [0x10: "EC table"])
        form.beginEditingName(row: 0)
        let field = try nameField(form, row: 0)
        field.stringValue = "half-typed"

        let escape = try keyDown("\u{1B}", keyCode: 53)
        XCTAssertTrue(form.view.performKeyEquivalent(with: escape),
                      "the form claims Escape while a name is being edited")

        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x10, name: "EC table")],
                       "the abandoned text is not written to the store")
        XCTAssertNil(form.editingNameRow)
        XCTAssertEqual(closes(), 0, "the form is still up")
        XCTAssertEqual(try nameField(form, row: 0).stringValue, "EC table",
                       "the cell shows the name the store holds again")
    }

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
