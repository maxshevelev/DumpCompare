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

    /// The row whose name is being edited, if any — what makes Escape two-level
    /// (§10.1): it cancels the edit while one is running, and closes the form
    /// only when none is.
    private(set) var editingNameRow: Int?

    /// Set while a name edit is being backed out, so the end of the editing
    /// session it provokes does not write the abandoned text to the store.
    private var cancellingNameEdit = false

    /// How the form closes itself. Replaced in tests: `dismiss` traps on a
    /// controller that was never presented, and what those tests are about is
    /// what the form asks for, not the window it lives in.
    var dismissForm: (() -> Void)?

    private enum ColumnID {
        static let offset = NSUserInterfaceItemIdentifier("bookmarkOffset")
        static let name = NSUserInterfaceItemIdentifier("bookmarkName")
    }

    init(store: BookmarkStore, focus: Focus, onGo: @escaping (UInt64) -> Void) {
        self.store = store
        self.focus = focus
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
        root.addArrangedSubview(makeOffsetRow())

        // Always in the layout, empty when there is nothing wrong: a label that
        // appeared and disappeared would move the list up and down under the
        // pointer as the user types.
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        root.addArrangedSubview(errorLabel)

        let listLabel = NSTextField(labelWithString: "Bookmarks")
        listLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        listLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(listLabel)

        let scrollView = makeTable()
        root.addArrangedSubview(scrollView)

        let buttonRow = makeButtonRow()
        root.addArrangedSubview(buttonRow)

        // A root that can claim Escape before the Cancel button's key
        // equivalent does — that is the whole of the two-level Escape (§10.1).
        let contentView = GoToFormView()
        contentView.escapeHandler = { [weak self] in self?.cancelNameEdit() ?? false }
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
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),

            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor,
                                              constant: -(root.edgeInsets.left + root.edgeInsets.right)),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor,
                                             constant: -(root.edgeInsets.left + root.edgeInsets.right)),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])
        // A concrete frame lets the presentation size the window before auto
        // layout runs (the view arrives with a zero frame), as the sheets do.
        contentView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view = contentView

        reloadBookmarks()
        refreshHistoryItems()
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
        offsetColumn.width = 110
        offsetColumn.minWidth = 90
        let nameColumn = NSTableColumn(identifier: ColumnID.name)
        nameColumn.title = "Name"
        nameColumn.width = 280
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
        // No stripes: a handful of bookmarks in a tall box would be a few rows
        // of content in a page of banding — the addresses are the pattern here.
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        table.setAccessibilityLabel("Bookmarks")
        table.onReturn = { [weak self] in self?.goToSelectedBookmark() }
        table.onDelete = { [weak self] in self?.removeSelectedBookmark() }
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
    }

    private func refreshHistoryItems() {
        offsetCombo.removeAllItems()
        offsetCombo.addItems(withObjectValues: GoToHistoryStore.recent)
    }

    // MARK: - Going

    /// Return in the field, and the Go To button: the typed address.
    @objc func goToTypedOffset() {
        guard let offset = try? OffsetParser.parse(offsetCombo.stringValue) else {
            errorLabel.stringValue = "Invalid offset — use hex with 0x prefix or decimal."
            return
        }
        errorLabel.stringValue = ""
        GoToHistoryStore.record(offset)
        jump(to: offset)
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

    /// A double click jumps too, so the mouse needs no detour to the keyboard —
    /// except on a name, where it is the gesture for renaming in place (§20.5).
    /// Takes the row and column rather than reading `clickedRow` itself, because
    /// those are AppKit's to set and a test cannot.
    func handleDoubleClick(row: Int, column: Int) {
        guard row >= 0, row < bookmarks.count else { return }
        if column == nameColumnIndex {
            beginEditingName(row: row)
        } else {
            bookmarkTable.selectRowIndexes([row], byExtendingSelection: false)
            goToSelectedBookmark()
        }
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
        let row = bookmarkTable.selectedRow
        guard row >= 0, row < bookmarks.count else { return }
        store.remove(rowContaining: bookmarks[row].row)
        reloadBookmarks()
        guard !bookmarks.isEmpty else { return }
        bookmarkTable.selectRowIndexes([min(row, bookmarks.count - 1)],
                                       byExtendingSelection: false)
    }

    /// Starts an in-place edit of a row's name.
    func beginEditingName(row: Int) {
        guard row >= 0, row < bookmarks.count else { return }
        editingNameRow = row
        bookmarkTable.selectRowIndexes([row], byExtendingSelection: false)
        bookmarkTable.editColumn(columnIndex(ColumnID.name), row: row, with: nil, select: true)
    }

    /// The end of a name edit — Return in the cell, or a click elsewhere:
    /// whatever is in the field is the name (§20.2 trims it, and an empty name
    /// means the bookmark shows its address again).
    @objc func nameEdited(_ sender: NSTextField) {
        guard !cancellingNameEdit else { return }
        let row = bookmarkTable.row(for: sender)
        guard row >= 0, row < bookmarks.count else { return }
        editingNameRow = nil
        store.rename(rowContaining: bookmarks[row].row, to: sender.stringValue)
        reloadBookmarks()
    }

    /// Escape's first level: backs out of a name edit, restoring the name the
    /// store holds. Returns whether there was an edit to cancel — when there was
    /// not, Escape falls through to the Cancel button and closes the form, which
    /// is why editing a name and pressing Escape cannot throw the window away
    /// (§10.1).
    @discardableResult
    func cancelNameEdit() -> Bool {
        guard let row = editingNameRow else { return false }
        editingNameRow = nil
        cancellingNameEdit = true
        if row < bookmarks.count,
           let field = nameField(atRow: row) {
            field.stringValue = bookmarks[row].name
        }
        // Ending the session sends the field's action; the flag above is what
        // keeps that from writing the abandoned text back.
        view.window?.makeFirstResponder(bookmarkTable)
        cancellingNameEdit = false
        reloadBookmarks()
        return true
    }

    /// The editable name field of a laid-out row, if the table has built it.
    private func nameField(atRow row: Int) -> NSTextField? {
        let column = columnIndex(ColumnID.name)
        guard column >= 0 else { return nil }
        let cell = bookmarkTable.view(atColumn: column, row: row, makeIfNecessary: false)
        return (cell as? NSTableCellView)?.textField
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
                ?? BookmarkCellView(identifier: ColumnID.offset, editable: false)
            // The dump's own address shape and colour (§6), so a row in the list
            // reads as the row it points at.
            cell.textField?.font = AppearanceSettings.font(size: 12)
            cell.textField?.textColor = HexTheme.inkBlue
            cell.textField?.stringValue = Bookmark.addressLabel(bookmark.row)
            return cell
        case ColumnID.name:
            let cell = (tableView.makeView(withIdentifier: ColumnID.name, owner: self) as? BookmarkCellView)
                ?? BookmarkCellView(identifier: ColumnID.name, editable: true)
            cell.textField?.target = self
            cell.textField?.action = #selector(nameEdited(_:))
            // The cell shows the name and nothing else. An unnamed bookmark is
            // called by its address (§20.2) and the Offset column beside it
            // already says that address, so filling this cell with it too would
            // print the same thing twice on one row.
            cell.textField?.stringValue = bookmark.name
            return cell
        default:
            return nil
        }
    }
}

extension GoToBookmarksController: NSComboBoxDelegate {
    /// A picked address only fills the field; the jump is still a Return away,
    /// so the dropdown cannot navigate the window by itself.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        errorLabel.stringValue = ""
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
    init(identifier: NSUserInterfaceItemIdentifier, editable: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier

        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.isEditable = editable
        field.isSelectable = editable
        field.isBordered = false
        field.drawsBackground = false
        // A name typed here is committed by Return and by clicking away; the
        // form's Escape puts the stored name back before the session ends.
        field.cell?.sendsActionOnEndEditing = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
