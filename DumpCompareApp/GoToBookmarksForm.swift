import Cocoa
import DumpCompareCore

// MARK: - Recently typed offsets (§10.1)

/// Remembers the offsets Go To was sent to, so the field can offer them again in
/// its dropdown. Persisted in `UserDefaults` — the same shape as
/// `FindHistoryStore`, down to the swappable defaults domain, because it answers
/// the same question for the same reason: on a bench the interesting addresses
/// of a dump get typed over and over.
///
/// An entry is the offset's canonical address (`0x` + at least eight upper-case
/// hex digits, §10), not the keystrokes that produced it: `0x7af00`, `0x07AF00`
/// and `503552` are one address, and a history that listed them three times
/// would be a log of typing rather than a list of places.
enum GoToHistoryStore {
    static let userDefaultsKey = "GoToHistory"
    static let limit = 10

    /// The defaults domain the history lives in. Swappable so tests run against
    /// an isolated store instead of the user's own (§11 does the same).
    static var defaults: UserDefaults = .standard

    /// The recorded addresses, most recent first.
    static var recent: [String] {
        defaults.stringArray(forKey: userDefaultsKey) ?? []
    }

    /// The address Go To was last sent to.
    static var mostRecent: String? { recent.first }

    /// Records a jump: moves its address to the front, dropping any older entry
    /// for the same address, and caps the list at `limit`.
    static func record(_ offset: UInt64) {
        let label = Bookmark.addressLabel(offset)
        var entries = recent.filter { $0 != label }
        entries.insert(label, at: 0)
        defaults.set(Array(entries.prefix(limit)), forKey: userDefaultsKey)
    }
}

// MARK: - The form

/// Go To and the bookmark list in one window (§10.1, §20.5): a place to type an
/// address, and the list of the addresses already worth coming back to. They are
/// one form because they are one question — "go where?" — and keeping them apart
/// would mean two windows offering half an answer each.
///
/// The keyboard follows the focus, which is what lets one Return mean two things
/// without ever guessing: in the field it goes to what was typed, in the list it
/// goes to what is selected, and in the list with nothing selected it does
/// nothing at all. The list is also where bookmarks are managed — `⌫` removes
/// the selection, a double click on a name edits it in place — so nothing about
/// a bookmark lives in two places.
@MainActor
final class GoToBookmarksController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Which half of the form the keyboard starts in: ⌘G is about typing an
    /// address, ⌥⌘B about picking one that is already marked.
    enum Focus {
        case offsetField
        case bookmarks
    }

    let focus: Focus

    private let store: BookmarkStore
    private let onGo: (UInt64) -> Void

    /// The bytes of a bookmarked row in the ACTIVE pane, or nil when the row is
    /// past that file's end (§9) — what an unnamed bookmark is described by in
    /// the list. Read per row as the table asks, so it always shows the pane's
    /// live content.
    private let rowBytes: (UInt64) -> [UInt8]?

    /// The bookmarks as the table currently shows them — a snapshot, so a row
    /// index means the same thing to every method that reads one, and the store
    /// is asked once per reload rather than once per cell.
    private(set) var bookmarks: [Bookmark] = []

    /// The widgets. Internal so tests can type into the field, select rows and
    /// read the empty state; a modal window has no one to click it under XCTest.
    private(set) var offsetCombo: NSComboBox!
    private(set) var goButton: NSButton!
    private(set) var cancelButton: NSButton!
    private(set) var bookmarkTable: NSTableView!
    private(set) var errorLabel: NSTextField!
    private(set) var emptyLabel: NSTextField!
    /// The "Bookmarks" title over the list. Held so the layout can pull it down
    /// onto the list it names.
    private var listLabel: NSTextField!

    /// The list's height, re-set from the number of bookmarks (§20.5).
    private var tableHeight: NSLayoutConstraint!

    /// How the form closes itself. Replaced in tests: `dismiss` traps on a
    /// controller that was never presented, and what those tests are about is
    /// what the form asks for, not the window it lives in.
    var dismissForm: (() -> Void)?

    private enum ColumnID {
        static let offset = NSUserInterfaceItemIdentifier("bookmarkOffset")
        static let name = NSUserInterfaceItemIdentifier("bookmarkName")
    }

    init(store: BookmarkStore, focus: Focus,
         rowBytes: @escaping (UInt64) -> [UInt8]?,
         onGo: @escaping (UInt64) -> Void) {
        self.store = store
        self.focus = focus
        self.rowBytes = rowBytes
        self.onGo = onGo
        super.init(nibName: nil, bundle: nil)
        // The presented window takes its title from here (§10.1): the form is
        // Go To, and the bookmarks are the places it already knows.
        title = "Go To"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        // No title label inside the form: the window it is presented in carries
        // "Go To" in its title bar, and saying it twice is not saying it better.
        let offsetRow = makeOffsetRow()
        root.addArrangedSubview(offsetRow)

        // Always in the layout, empty when there is nothing wrong: a label that
        // appeared and disappeared would move the list up and down under the
        // pointer as the user types.
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        root.addArrangedSubview(errorLabel)

        listLabel = NSTextField(labelWithString: "Bookmarks")
        listLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        listLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(listLabel)

        let scrollView = makeTable()
        // The list is as tall as it needs to be, up to `maxVisibleRows`: a form
        // that opened with a page of empty table over three bookmarks would be
        // mostly nothing. `updateTableHeight` sets the constant.
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        root.addArrangedSubview(scrollView)

        let buttonRow = makeButtonRow()
        root.addArrangedSubview(buttonRow)

        // The spacing says what belongs with what, rather than spreading five
        // rows evenly down the form: the error message sits under the field it is
        // about, the "Bookmarks" title sits on the list it names, and only the
        // gap *between* those two groups is a full one. Evenly spaced, the field
        // and the list ended up an inch apart with a blank line between them.
        // Under the field, but not against it: at 2 pt the message touched the
        // field's focus ring, which is drawn outside its frame.
        root.setCustomSpacing(5, after: offsetRow)
        root.setCustomSpacing(6, after: errorLabel)
        root.setCustomSpacing(4, after: listLabel)

        // A root that can claim Escape before the Cancel button's key
        // equivalent does — that is the whole of the two-level Escape (§10.1).
        let contentView = GoToFormView()
        contentView.escapeHandler = { [weak self] in self?.cancelBookmarkEdit() ?? false }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        // The empty state sits over the table rather than in it: a table with one
        // pseudo-row would answer ⌫ and Return as if it held a bookmark.
        emptyLabel = NSTextField(wrappingLabelWithString:
            "No bookmarks yet. ⌘D marks the row your caret is on, so you can come back to it.")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),

            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor,
                                              constant: -(root.edgeInsets.left + root.edgeInsets.right)),
            tableHeight,
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor,
                                             constant: -(root.edgeInsets.left + root.edgeInsets.right)),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])
        // A concrete frame lets the presentation size the window before auto
        // layout runs (the view arrives with a zero frame), as the sheets do.
        // Its height is only a starting point: the list sizes itself to its rows
        // (§20.5) and the window follows, so nothing pins a minimum height.
        contentView.frame = NSRect(x: 0, y: 0, width: 480, height: 260)
        view = contentView

        reloadBookmarks()   // also sizes the list to its rows
        refreshHistoryItems()
        // The form opens with "0x" in the field: nothing to go to yet, so the
        // button is off — but no error, because nothing has been typed wrong.
        updateValidation(showsError: false)
    }

    /// "Offset: [ 0x… ▾ ] ( Go To )" — the fast path unchanged: ⌘G, type,
    /// Return. The button names the action rather than leaving Return to be
    /// guessed at, and the dropdown carries the addresses already visited.
    private func makeOffsetRow() -> NSView {
        let label = NSTextField(labelWithString: "Offset:")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let combo = OffsetComboBox()
        combo.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // Pre-filled with "0x" and the caret behind it (§10): hex is the
        // language of a dump, so the prefix is typed for the user. The last
        // address is deliberately NOT pre-filled — the caret sits at the end of
        // the text, so a pre-filled address would turn ⌘G, type, Return into
        // digits appended to the previous jump.
        combo.stringValue = "0x"
        combo.completes = false
        combo.numberOfVisibleItems = GoToHistoryStore.limit
        combo.target = self
        combo.action = #selector(goToTypedOffset)
        // Return in the field is what submits; picking a recent address only
        // fills the field, and losing focus submits nothing (§10).
        combo.cell?.sendsActionOnEndEditing = false
        combo.delegate = self
        combo.setAccessibilityLabel("Offset")
        combo.translatesAutoresizingMaskIntoConstraints = false
        offsetCombo = combo

        let go = NSButton(title: "Go To", target: self, action: #selector(goToTypedOffset))
        go.translatesAutoresizingMaskIntoConstraints = false
        // No Return key equivalent: a default button would claim Return from
        // the whole window, and Return in the bookmark list has to mean the
        // selected bookmark (§10.1). The field's own action carries Return here.

        let row = NSStackView(views: [label, combo, go])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        goButton = go
        return row
    }

    private func makeTable() -> NSScrollView {
        let offsetColumn = NSTableColumn(identifier: ColumnID.offset)
        offsetColumn.title = "Offset"
        // Exactly as wide as an address and no wider: eight bare hex digits
        // measured in the dump's own font, so a larger font in Settings cannot
        // clip them (§3.2) and everything else on the row belongs to the name —
        // or to the bytes standing in for one. Fixed, because an address is
        // always the same eight digits; the search results size their columns
        // from a template the same way (§11).
        let addressWidth = Self.addressColumnWidth()
        offsetColumn.width = addressWidth
        offsetColumn.minWidth = addressWidth
        offsetColumn.maxWidth = addressWidth
        let nameColumn = NSTableColumn(identifier: ColumnID.name)
        nameColumn.title = "Name"
        nameColumn.width = 320
        nameColumn.minWidth = 80

        let table = BookmarkTableView()
        table.addTableColumn(offsetColumn)
        table.addTableColumn(nameColumn)
        // Two self-evident columns in a titled group need no header row.
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        // Spare width goes to the Name column, not shared out: the address is a
        // fixed eight digits, and stretching its column only pushes the names
        // away from the addresses they belong to.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // No stripes: a handful of bookmarks in a tall box would be a few rows
        // of content in a page of banding — the addresses are the pattern here.
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        table.setAccessibilityLabel("Bookmarks")
        table.onReturn = { [weak self] in self?.goToSelectedBookmark() }
        table.onDelete = { [weak self] in self?.removeSelectedBookmark() }
        // A right-click offers the one thing the list does that a key does not
        // announce: ⌫ removes a bookmark, but nothing on screen says so (§20.5).
        let menu = NSMenu()
        let edit = menu.addItem(withTitle: "Edit Bookmark…",
                                action: #selector(editClickedBookmark), keyEquivalent: "")
        edit.target = self
        let remove = menu.addItem(withTitle: "Delete Bookmark",
                                  action: #selector(deleteClickedBookmark), keyEquivalent: "")
        remove.target = self
        table.menu = menu
        bookmarkTable = table

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        return scrollView
    }

    private func makeButtonRow() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1B}"  // Esc — at rest it closes the form.
        cancelButton = cancel

        let row = NSStackView(views: [spacer, cancel])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The window is created after `loadView`, so this is the first chance to
        // size it to the form: the list is as tall as its rows (§20.5), and the
        // window has to be as tall as the list, not the other way round.
        fitWindowToContent()
        switch focus {
        case .offsetField:
            view.window?.makeFirstResponder(offsetCombo)
        case .bookmarks:
            view.window?.makeFirstResponder(bookmarkTable)
            // ⌥⌘B is opened to go to a bookmark, so the list offers its first
            // one — the lowest address, the list being sorted by address. The
            // jump still takes a Return: a selection is an offer, not an act.
            if bookmarkTable.selectedRow < 0, !bookmarks.isEmpty {
                bookmarkTable.selectRowIndexes([0], byExtendingSelection: false)
            }
        }
    }

    // MARK: - Content

    /// Re-reads the list from the store. Called on every change the form makes,
    /// and by the window when a bookmark changes under it (§20.2).
    func reloadBookmarks() {
        bookmarks = store.bookmarks
        bookmarkTable.reloadData()
        emptyLabel.isHidden = !bookmarks.isEmpty
        updateTableHeight()
    }

    /// How many rows the list shows before it starts scrolling.
    static let maxVisibleRows = 10

    /// The fewest rows' worth of height the list keeps: the empty state is two
    /// lines of text over the table, and it needs room to be read.
    static let minVisibleRows = 3

    /// What one row of the list costs vertically. Internal so a test can measure
    /// the list in rows rather than in points.
    var rowStep: CGFloat {
        bookmarkTable.rowHeight + bookmarkTable.intercellSpacing.height
    }

    /// Sizes the list to its contents, capped at `maxVisibleRows` — beyond that
    /// it scrolls (§20.5). The window follows, so a bookmark removed does not
    /// leave a strip of empty table behind.
    private func updateTableHeight() {
        let rows = min(max(bookmarks.count, Self.minVisibleRows), Self.maxVisibleRows)
        // Two points for the bezel the rows sit inside.
        tableHeight.constant = CGFloat(rows) * rowStep + 2
        fitWindowToContent()
    }

    /// Makes the window exactly as tall as the form wants to be. The width is
    /// left alone: it is the user's to widen, and the fields fill whatever it is.
    private func fitWindowToContent() {
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.height > 0 else { return }
        window.setContentSize(NSSize(width: max(window.contentLayoutRect.width, fitting.width),
                                     height: fitting.height))
    }

    private func refreshHistoryItems() {
        offsetCombo.removeAllItems()
        offsetCombo.addItems(withObjectValues: GoToHistoryStore.recent)
    }

    // MARK: - Going

    /// Return in the field, and the Go To button: the typed address. Return on
    /// an offset that does not parse beeps — the button is already disabled and
    /// the error already says why, so the key needs no new words, only an answer
    /// that it did nothing (§10.1).
    @objc func goToTypedOffset() {
        guard let offset = try? OffsetParser.parse(offsetCombo.stringValue) else {
            showValidationError()
            beep()
            return
        }
        errorLabel.stringValue = ""
        GoToHistoryStore.record(offset)
        jump(to: offset)
    }

    /// What an invalid Return sounds like. A closure so a test can hear it: a
    /// beep leaves no trace of its own.
    var beep: () -> Void = { NSSound.beep() }

    /// Re-validates the field as it is typed in, the way the Select Block sheet
    /// does (§10.2): the **Go To** button is enabled only for an offset that
    /// parses, so the form says whether it can act on what is in the field
    /// before the key is pressed, and the message names what is wrong.
    ///
    /// `showsError` is false for the state the form opens in — the field holds
    /// its "0x" prefix, which is not yet an offset, and greeting the user with
    /// an error about text they have not typed would be scolding them for
    /// arriving. The button is still disabled: there is nowhere to go yet.
    private func updateValidation(text: String? = nil, showsError: Bool = true) {
        let offset = try? OffsetParser.parse(text ?? offsetCombo.stringValue)
        goButton.isEnabled = offset != nil
        if offset != nil {
            errorLabel.stringValue = ""
        } else if showsError {
            showValidationError()
        }
    }

    private func showValidationError() {
        errorLabel.stringValue = "Invalid offset — use hex with 0x prefix or decimal."
    }

    /// Return in the list: the selected bookmark. With nothing selected nothing
    /// happens — the same Return in the same window must never be a coin flip
    /// between a typed address and a guessed one (§10.1).
    func goToSelectedBookmark() {
        let row = bookmarkTable.selectedRow
        guard row >= 0, row < bookmarks.count else { return }
        jump(to: bookmarks[row].row)
    }

    @objc private func rowDoubleClicked() {
        handleDoubleClick(row: bookmarkTable.clickedRow, column: bookmarkTable.clickedColumn)
    }

    /// A double click jumps, wherever in the row it lands — a double click
    /// *activates* an item, which here means going to it, the way it opens a file
    /// in the Finder (§20.5). Editing a bookmark is a menu command and its own
    /// popover, so no click in the list has to mean two things. Takes the row and
    /// column rather than reading `clickedRow` itself, because those are AppKit's
    /// to set and a test cannot.
    func handleDoubleClick(row: Int, column: Int) {
        guard row >= 0, row < bookmarks.count else { return }
        bookmarkTable.selectRowIndexes([row], byExtendingSelection: false)
        goToSelectedBookmark()
    }

    /// The list's two columns, by index — what a double click is judged against.
    var offsetColumnIndex: Int { columnIndex(ColumnID.offset) }
    var nameColumnIndex: Int { columnIndex(ColumnID.name) }

    /// Closes the form and asks for the jump. The form goes first: it is centred
    /// over the window it is about to scroll, and the row it lands on has to be
    /// visible (§10.1).
    private func jump(to offset: UInt64) {
        closeForm()
        onGo(offset)
    }

    @objc private func cancelPressed() {
        closeForm()
    }

    private func closeForm() {
        if let dismissForm {
            dismissForm()
            return
        }
        dismiss(self)
    }

    // MARK: - Managing the list (§20.5)

    /// `⌫`: removes the selected bookmark. The selection stays where it was, so
    /// a run of them can be cleared without reaching for the mouse between
    /// presses; removing the last row selects the one now at the end.
    func removeSelectedBookmark() {
        removeBookmark(atRow: bookmarkTable.selectedRow)
    }

    /// The list's context menu > Edit Bookmark…: the same popover the dump's own
    /// ⇧⌘D opens (§20.3), on the row that was right-clicked. One editor for a
    /// bookmark, wherever it is edited from — and it can move the bookmark and
    /// delete it, which an in-place name field could not.
    @objc func editClickedBookmark() {
        let clicked = bookmarkTable.clickedRow
        editBookmark(atRow: clicked >= 0 ? clicked : bookmarkTable.selectedRow)
    }

    /// Where the edit popover goes. Nil means on the row itself; a test replaces
    /// it, because a popover anchored in a window that is never on screen closes
    /// the instant it opens (§20.3 does the same for the dump's).
    var editPopoverPresenter: ((BookmarkEditPopoverController) -> Void)?

    /// The popover on screen, if any: Escape closes it before it closes the form
    /// (§10.1), and it must not outlive the bookmark it is editing (§20.3).
    private weak var openEditPopover: BookmarkEditPopoverController?

    /// Whether a bookmark's editor is up — what Escape's first level acts on.
    var isEditingBookmark: Bool { openEditPopover != nil }

    private func editBookmark(atRow row: Int) {
        guard row >= 0, row < bookmarks.count else { return }
        let bookmark = bookmarks[row]
        bookmarkTable.selectRowIndexes([row], byExtendingSelection: false)
        let controller = BookmarkEditPopoverController(
            row: bookmark.row, existingName: bookmark.name,
            // One row holds one bookmark (§20.1), so a row already marked is not
            // a row this one can be given.
            rowIsFree: { [weak self] row in
                guard let self else { return true }
                return store.bookmark(atRowContaining: row) == nil
            },
            onCommit: { [weak self] target, name in
                self?.openEditPopover = nil
                self?.store.edit(rowContaining: bookmark.row, to: target, name: name)
                self?.reloadBookmarks()
            },
            onCancel: { [weak self] in self?.openEditPopover = nil },
            onDelete: { [weak self] in
                self?.openEditPopover = nil
                self?.store.remove(rowContaining: bookmark.row)
                self?.reloadBookmarks()
            })
        openEditPopover = controller
        if let editPopoverPresenter {
            editPopoverPresenter(controller)
            return
        }
        controller.show(relativeTo: bookmarkTable.rect(ofRow: row), of: bookmarkTable)
    }

    /// The list's context menu > Delete Bookmark: the row that was right-clicked
    /// rather than the selected one, the way every context menu in the app acts
    /// on what was clicked (§10.2).
    @objc func deleteClickedBookmark() {
        let clicked = bookmarkTable.clickedRow
        removeBookmark(atRow: clicked >= 0 ? clicked : bookmarkTable.selectedRow)
    }

    private func removeBookmark(atRow row: Int) {
        guard row >= 0, row < bookmarks.count else { return }
        store.remove(rowContaining: bookmarks[row].row)
        reloadBookmarks()
        guard !bookmarks.isEmpty else { return }
        bookmarkTable.selectRowIndexes([min(row, bookmarks.count - 1)],
                                       byExtendingSelection: false)
    }

    /// Escape's first level: closes an open bookmark editor instead of the form,
    /// leaving the bookmark as it was. Returns whether there was one to close —
    /// when there was not, Escape falls through to the Cancel button and closes
    /// the form (§10.1).
    @discardableResult
    func cancelBookmarkEdit() -> Bool {
        guard let popover = openEditPopover else { return false }
        openEditPopover = nil
        popover.cancel()
        return true
    }

    private func columnIndex(_ identifier: NSUserInterfaceItemIdentifier) -> Int {
        bookmarkTable.column(withIdentifier: identifier)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        bookmarks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < bookmarks.count else { return nil }
        let bookmark = bookmarks[row]
        switch tableColumn.identifier {
        case ColumnID.offset:
            let cell = (tableView.makeView(withIdentifier: ColumnID.offset, owner: self) as? BookmarkCellView)
                ?? BookmarkCellView(identifier: ColumnID.offset)
            // The dump's own address shape and colour (§6), so a row in the list
            // reads as the row it points at.
            cell.textField?.font = AppearanceSettings.font(size: 12)
            // The bookmark colour, not the dump's address ink: in a list *of*
            // bookmarks the address is what the purple mark in the gutter and the
            // purple arrow in the minimap point at, and one colour ties the three
            // together (§20.4). Bare digits, no "0x" — a whole column of
            // addresses does not need each one announcing that it is hex.
            cell.restingTextColor = HexTheme.bookmarkColor
            cell.textField?.stringValue = Bookmark.bareAddressLabel(bookmark.row)
            return cell
        case ColumnID.name:
            let cell = (tableView.makeView(withIdentifier: ColumnID.name, owner: self) as? BookmarkCellView)
                ?? BookmarkCellView(identifier: ColumnID.name)
            cell.textField?.stringValue = bookmark.name
            cell.restingTextColor = .labelColor
            // An unnamed bookmark is described by what is AT it: the row's bytes
            // as the dump would show them. That is what the user marked the row
            // for, and it is the one thing the Offset column beside it does not
            // already say (§20.5).
            cell.restingPlaceholder = Self.rowDescription(rowBytes(bookmark.row))
            return cell
        default:
            return nil
        }
    }

    // MARK: - What a row says

    /// What the list shows where an unnamed bookmark's name would be: the row's
    /// bytes in the dump's own hex, or a plain sentence when the row is past the
    /// active pane's end — a bookmark is an absolute address and stays in the
    /// list even where the file does not reach (§9), and "nothing there" is worth
    /// saying outright rather than leaving a blank cell.
    static func rowDescription(_ bytes: [UInt8]?) -> NSAttributedString {
        guard let bytes else {
            return NSAttributedString(string: pastEndOfFileText, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        // The dump's font and spacing, so the cell reads as the row it is: it is
        // a preview of the bytes, not prose about them. It truncates with "…"
        // against the column's width, like every other value in the list.
        return NSAttributedString(
            string: bytes.map { String(format: "%02X", $0) }.joined(separator: " "),
            attributes: [
                .font: AppearanceSettings.font(size: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }

    static let pastEndOfFileText = "Past the end of the file"

    /// The width an eight-digit address needs, in the font the list draws it in,
    /// plus the room the cell's label leaves either side.
    static func addressColumnWidth() -> CGFloat {
        let template = String(repeating: "0", count: 8) as NSString
        let text = template.size(withAttributes: [.font: AppearanceSettings.font(size: 12)]).width
        return ceil(text) + 2 * BookmarkCellView.labelInset + 1
    }
}

extension GoToBookmarksController: NSComboBoxDelegate {
    /// Every keystroke re-validates the field (§10.1).
    func controlTextDidChange(_ obj: Notification) {
        updateValidation()
    }

    /// A picked address only fills the field; the jump is still a Return away,
    /// so the dropdown cannot navigate the window by itself.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The field's text catches up after this notification, so the picked
        // item is what to validate — it is a recorded address, so this is what
        // re-enables the button.
        updateValidation(text: offsetCombo.objectValueOfSelectedItem as? String)
    }
}

// MARK: - Widgets

/// The form's root view: it sees Escape before the Cancel button's key
/// equivalent does, which is what makes Escape cancel a name edit first and
/// close the form second (§10.1).
private final class GoToFormView: NSView {
    /// Returns true when it consumed the Escape (a name edit was cancelled).
    var escapeHandler: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\u{1B}", escapeHandler?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The offset field: a combo box that keeps the caret behind the "0x" prefix
/// instead of selecting the whole text on focus, so hex digits can be typed
/// immediately (§10) — the same rule `HexInputField` gives the sheets.
private final class OffsetComboBox: NSComboBox {
    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused, let editor = currentEditor() as? NSTextView {
            let length = (stringValue as NSString).length
            editor.selectedRange = NSRange(location: length, length: 0)
        }
        return focused
    }
}

/// The bookmark list. Return and `⌫` are the list's own keys (§10.1): Return
/// goes to the selected bookmark — which is why the Go To button must not claim
/// Return as a default button — and `⌫` removes it.
private final class BookmarkTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return super.keyDown(with: event)
        }
        switch Int(scalar.value) {
        case NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey:
            onDelete?()
        case NSCarriageReturnCharacter, NSNewlineCharacter, NSEnterCharacter:
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// One cell of the list: a label that fills the cell, editable in the Name
/// column so a double click renames the bookmark where it is listed (§20.5).
private final class BookmarkCellView: NSTableCellView {
    /// The label's inset from each side of the cell. Read by the address
    /// column's sizing, so the room a value gets and the width it is measured at
    /// cannot drift apart.
    static let labelInset: CGFloat = 4

    /// The colour the label has on paper. On a selected row every cell switches
    /// to the colour for text on a selection instead — the address is ink blue
    /// and the row-preview placeholder a dim grey, and both are close to
    /// unreadable on the selection fill (§20.5). AppKit does this for a plain
    /// label by itself; a colour set by hand has to follow the style by hand.
    var restingTextColor: NSColor = .labelColor {
        didSet { applyBackgroundStyle() }
    }

    /// The placeholder as it reads on paper — the row's bytes, or the sentence
    /// for a row past the file's end. Re-coloured for a selected row, keeping its
    /// own font: the monospaced preview has to stay monospaced.
    var restingPlaceholder: NSAttributedString? {
        didSet { applyBackgroundStyle() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyBackgroundStyle() }
    }

    private func applyBackgroundStyle() {
        let selected = backgroundStyle == .emphasized
        textField?.textColor = selected ? .alternateSelectedControlTextColor : restingTextColor
        guard let placeholder = restingPlaceholder else {
            textField?.placeholderAttributedString = nil
            return
        }
        guard selected else {
            textField?.placeholderAttributedString = placeholder
            return
        }
        let tinted = NSMutableAttributedString(attributedString: placeholder)
        // Dimmer than the row's own text, as the resting placeholder is dimmer
        // than a name: it is still a placeholder, not a value.
        tinted.addAttribute(.foregroundColor,
                            value: NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75),
                            range: NSRange(location: 0, length: tinted.length))
        textField?.placeholderAttributedString = tinted
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        // A label, not a field: a bookmark is edited in its own popover (§20.3),
        // so nothing in the list takes the keyboard and every click in it means
        // one thing — select the row, or activate it on a double click.
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelInset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.labelInset),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
