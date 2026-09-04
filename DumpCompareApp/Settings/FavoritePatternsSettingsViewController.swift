import Cocoa
import DumpCompareCore

/// The Favorites tab of the Settings window (§11): the named patterns the user
/// keeps, in the order they keep them in.
///
/// Every other tab in this window applies live, so this one does too — a commit
/// writes the store, and every open Find bar's menu re-reads. There is nothing
/// to confirm and nothing to lose, which is what lets the whole tab be a table.
///
/// Two rules are worth stating, because they are the ones a table like this
/// usually gets wrong:
///
/// - **Nothing unsearchable is stored.** A pattern is committed through the
///   same `SearchEngine.parsePattern` call the Find bar makes; when it throws,
///   the cell goes back to what it held and the reason is said under the table.
///   The one way an unusable entry can exist is a hand-edited plist, and the
///   menu marks those (§11).
/// - **A new row is a draft until it has a pattern.** `+` puts an empty row in
///   the *table*, not in the store: an entry with no pattern is not a search,
///   and a list the user curates should not gain a row that searches for
///   nothing. Leaving the tab abandons an unfinished row.
final class FavoritePatternsSettingsViewController: NSViewController,
                                                    NSTableViewDataSource, NSTableViewDelegate {
    /// The rows as the table shows them — a snapshot, so a row index means the
    /// same thing to every method that reads one, plus any draft row.
    private(set) var rows: [SearchPatternEntry] = []

    /// The widgets. Internal so tests can drive them: the settings window is
    /// not on screen under XCTest.
    private(set) var table: NSTableView!
    private(set) var addButton: NSButton!
    private(set) var removeButton: NSButton!
    private(set) var messageLabel: NSTextField!

    private var storeObserver: NSObjectProtocol?

    private enum ColumnID {
        static let name = NSUserInterfaceItemIdentifier("favoriteName")
        static let pattern = NSUserInterfaceItemIdentifier("favoritePattern")
        static let encoding = NSUserInterfaceItemIdentifier("favoriteEncoding")
        static let caseRule = NSUserInterfaceItemIdentifier("favoriteCase")
    }

    /// The row index a drag carries, on the pasteboard.
    private static let rowDragType = NSPasteboard.PasteboardType("com.dumpcompare.favorite-row")

    private var tableHeight: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 24
    private static let minVisibleRows = 4
    private static let maxVisibleRows = 12

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: "Favorites")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        let list = makeTable()
        let footer = makeFooter()

        let message = NSTextField(labelWithString: "")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .systemRed
        message.lineBreakMode = .byTruncatingTail
        messageLabel = message

        let caption = NSTextField(wrappingLabelWithString:
            "Patterns you keep, with the encoding they are read in. They appear under "
            + "Favorites in the Find bar's search menu, where picking one fills the bar "
            + "and searches. Drag rows to reorder them — the menu lists them in this order.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 4

        for subview in [titleLabel, list, footer, message, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            list.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            footer.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            // The message sits close under the footer it is about, with the full
            // gap before the caption — the sheets' spacing rule (§10).
            message.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 6),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            caption.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            // Exact width, like every other tab: the window sizes to this view's
            // fitting size, and a wrapping label's ideal width is its whole text
            // on one line. Wider than the others because four columns have to
            // fit — the tab bar keeps its own width, and the window follows the
            // tab that is showing.
            root.widthAnchor.constraint(equalToConstant: 540),
        ])
        view = root

        reload()
        // Another window's Find bar can keep a pattern while this tab is open
        // (§11) — the store says so, and the table is not the only writer.
        storeObserver = NotificationCenter.default.addObserver(
            forName: FavoritePatternStore.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.reloadUnlessDrafting()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func makeTable() -> NSView {
        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = Self.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.allowsMultipleSelection = false

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            return column
        }
        table.addTableColumn(column(ColumnID.name, "Name", width: 140))
        table.addTableColumn(column(ColumnID.pattern, "Pattern", width: 160))
        table.addTableColumn(column(ColumnID.encoding, "Encoding", width: 120))
        table.addTableColumn(column(ColumnID.caseRule, "Match Case", width: 70))
        self.table = table

        // The order is the user's, so it is dragged (§11).
        table.registerForDraggedTypes([Self.rowDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.height(forRows: 4))
        tableHeight.isActive = true
        return scrollView
    }

    private static func height(forRows count: Int) -> CGFloat {
        let visible = min(max(count, minVisibleRows), maxVisibleRows)
        return CGFloat(visible + 1) * rowHeight + 4
    }

    /// The `+`/`−` footer under the table — the File Types tab's idiom (§25),
    /// itself the Segments form's (§21.4).
    private func makeFooter() -> NSView {
        func footerIcon(_ name: String, _ description: String) -> NSImage {
            let glyph = NSImage(systemSymbolName: name, accessibilityDescription: description)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
                ?? NSImage()
            let side: CGFloat = 18
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let g = glyph.size
                glyph.draw(at: NSPoint(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2),
                           from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            image.isTemplate = true
            return image
        }

        let plus = NSButton(title: "", target: self, action: #selector(addPressed))
        plus.image = footerIcon("plus", "Add Favorite")
        plus.imagePosition = .imageOnly
        plus.isBordered = false
        plus.contentTintColor = .secondaryLabelColor
        plus.toolTip = "Add a pattern"
        plus.setAccessibilityLabel("Add Favorite")
        addButton = plus

        let minus = NSButton(title: "", target: self, action: #selector(removePressed))
        minus.image = footerIcon("minus", "Remove Favorite")
        minus.imagePosition = .imageOnly
        minus.isBordered = false
        minus.contentTintColor = .secondaryLabelColor
        minus.toolTip = "Remove the selected pattern"
        minus.setAccessibilityLabel("Remove Favorite")
        minus.isEnabled = false
        removeButton = minus

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [plus, minus, spacer])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    // MARK: - Data

    /// Re-reads the store and repaints.
    func reload() {
        rows = FavoritePatternStore.favorites
        show(message: nil)
        refreshTable()
    }

    /// The same, unless there is a draft row on screen — a row the user is
    /// still filling in is not in the store, and re-reading would take it away
    /// under their hands.
    private func reloadUnlessDrafting() {
        guard !hasDraft else { return }
        reload()
    }

    private var hasDraft: Bool { rows.contains { $0.pattern.isEmpty } }

    private func refreshTable() {
        tableHeight?.constant = Self.height(forRows: rows.count)
        table?.reloadData()
        updateRemoveButton()
    }

    /// Writes the rows that are searches. A draft row is left out — it has no
    /// pattern, so there is nothing to store yet.
    private func save() {
        FavoritePatternStore.replace(with: rows.filter { !$0.pattern.isEmpty })
    }

    private func show(message: String?) {
        messageLabel?.stringValue = message ?? ""
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier else { return nil }
        let entry = rows[row]
        switch id {
        case ColumnID.name:
            return field(entry.name, placeholder: "Name", column: id, row: row)
        case ColumnID.pattern:
            return field(entry.pattern, placeholder: "Pattern", column: id, row: row)
        case ColumnID.encoding:
            let popup = NSPopUpButton()
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 12)
            for encoding in SearchEncoding.allCases {
                popup.addItem(withTitle: encoding.displayName)
            }
            popup.selectItem(at: SearchEncoding.allCases.firstIndex(of: entry.encoding) ?? 0)
            popup.tag = row
            popup.target = self
            popup.action = #selector(encodingPicked(_:))
            popup.setAccessibilityLabel("Encoding")
            return cell(around: popup, inset: 0)
        case ColumnID.caseRule:
            let checkbox = NSButton(checkboxWithTitle: "", target: self,
                                    action: #selector(casePicked(_:)))
            checkbox.tag = row
            checkbox.state = entry.caseSensitive ? .on : .off
            // Hex is byte-exact whatever the flag holds, so there is nothing to
            // tick (§11) — the same reason the bar's toggle leaves the bar.
            checkbox.isEnabled = entry.encoding != .hex
            checkbox.setAccessibilityLabel("Match Case")
            return cell(around: checkbox, inset: 2)
        default:
            return nil
        }
    }

    /// An editable cell. Borderless and backgroundless so the table reads as a
    /// list rather than a grid of boxes, and editing happens in place.
    private func field(_ text: String, placeholder: String,
                       column: NSUserInterfaceItemIdentifier, row: Int) -> NSTableCellView {
        let field = NSTextField(string: text)
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.identifier = column
        field.tag = row
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.setAccessibilityLabel(placeholder)
        let holder = cell(around: field, inset: 2)
        holder.textField = field
        return holder
    }

    private func cell(around control: NSView, inset: CGFloat) -> NSTableCellView {
        let holder = NSTableCellView()
        control.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
            control.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -inset),
            control.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        removeButton?.isEnabled = (table?.selectedRow ?? -1) >= 0
    }

    // MARK: - Editing

    @objc private func fieldCommitted(_ sender: NSTextField) {
        guard sender.tag < rows.count else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender.identifier {
        case ColumnID.name:
            rows[sender.tag].name = text
        case ColumnID.pattern:
            let entry = rows[sender.tag]
            guard text.isEmpty
                    || (try? SearchEngine.parsePattern(text, encoding: entry.encoding)) != nil else {
                // Back to what it held: the same parse the bar makes said no, so
                // this text is not a search and the list does not gain one.
                sender.stringValue = entry.pattern
                show(message: Self.complaint(about: text, as: entry.encoding))
                return
            }
            rows[sender.tag].pattern = text
        default:
            return
        }
        show(message: nil)
        save()
    }

    @objc private func encodingPicked(_ sender: NSPopUpButton) {
        guard sender.tag < rows.count else { return }
        let encoding = SearchEncoding.allCases[
            min(max(0, sender.indexOfSelectedItem), SearchEncoding.allCases.count - 1)]
        var entry = rows[sender.tag]
        // The pattern has to survive its new encoding: `DE A` is fine as ASCII
        // and is not hex, so the encoding is refused rather than the entry
        // quietly becoming unsearchable.
        guard entry.pattern.isEmpty
                || (try? SearchEngine.parsePattern(entry.pattern, encoding: encoding)) != nil else {
            sender.selectItem(at: SearchEncoding.allCases.firstIndex(of: entry.encoding) ?? 0)
            show(message: Self.complaint(about: entry.pattern, as: encoding))
            return
        }
        entry.encoding = encoding
        rows[sender.tag] = entry
        show(message: nil)
        save()
        // The case checkbox belongs to the encoding (hex has none), so the row
        // is redrawn rather than left saying the wrong thing.
        table?.reloadData(forRowIndexes: IndexSet(integer: sender.tag),
                          columnIndexes: IndexSet(integer: 3))
    }

    @objc private func casePicked(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        rows[sender.tag].caseSensitive = sender.state == .on
        show(message: nil)
        save()
    }

    private static func complaint(about pattern: String, as encoding: SearchEncoding) -> String {
        encoding == .hex
            ? "\"\(pattern)\" is not hex — use pairs like DE AD BE EF."
            : "\"\(pattern)\" cannot be written in \(encoding.displayName)."
    }

    // MARK: - Add and remove

    /// Adds an empty row and puts the caret in its Name. Nothing is stored yet:
    /// a row without a pattern is not a search (see the type's note).
    @objc private func addPressed() {
        guard !hasDraft else {
            // One at a time — a second empty row would be indistinguishable
            // from the first, and the store holds neither.
            beginEditing(row: rows.firstIndex { $0.pattern.isEmpty } ?? 0, column: 0)
            return
        }
        rows.append(SearchPatternEntry(pattern: "", encoding: .hex))
        show(message: nil)
        refreshTable()
        let row = rows.count - 1
        table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        beginEditing(row: row, column: 0)
    }

    private func beginEditing(row: Int, column: Int) {
        guard let table, row < rows.count else { return }
        table.scrollRowToVisible(row)
        table.editColumn(column, row: row, with: nil, select: true)
    }

    @objc private func removePressed() {
        guard let table, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        rows.remove(at: table.selectedRow)
        show(message: nil)
        refreshTable()
        save()
    }

    // MARK: - Reordering

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation)
    -> NSDragOperation {
        // Between rows only: dropping *on* a row would mean something (replace?
        // merge?) that this list has no answer for.
        guard dropOperation == .above, draggedRow(from: info) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = draggedRow(from: info), from < rows.count else { return false }
        move(from: from, above: row)
        return true
    }

    /// Moves a row into the gap above `destination`. The drop index was read
    /// before the row left, so everything after it has shifted down by one.
    private func move(from: Int, above destination: Int) {
        guard from < rows.count else { return }
        let entry = rows.remove(at: from)
        rows.insert(entry, at: min(from < destination ? destination - 1 : destination, rows.count))
        show(message: nil)
        refreshTable()
        save()
    }

    private func draggedRow(from info: NSDraggingInfo) -> Int? {
        guard let text = info.draggingPasteboard.string(forType: Self.rowDragType) else { return nil }
        return Int(text)
    }

    // MARK: - Test seams
    //
    // The settings window is not on screen under XCTest, so a test reaches the
    // cells' controls the way the table builds them: on demand.

    /// The editable field in `row`'s Name or Pattern column.
    func fieldForTests(row: Int, name: Bool) -> NSTextField? {
        cellForTests(row: row, column: name ? 0 : 1)?.textField
    }

    func encodingPopupForTests(row: Int) -> NSPopUpButton? {
        cellForTests(row: row, column: 2)?.subviews.compactMap { $0 as? NSPopUpButton }.first
    }

    func caseCheckboxForTests(row: Int) -> NSButton? {
        cellForTests(row: row, column: 3)?.subviews.compactMap { $0 as? NSButton }.first
    }

    private func cellForTests(row: Int, column: Int) -> NSTableCellView? {
        guard let table, row < rows.count else { return nil }
        return table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    /// Types `text` into a cell and commits it, the way ending an edit does.
    func typeForTests(_ text: String, row: Int, name: Bool) {
        guard let field = fieldForTests(row: row, name: name) else { return }
        field.stringValue = text
        fieldCommitted(field)
    }

    /// Chooses `encoding` in `row`'s popup and commits it, the way a pick does.
    func pickEncodingForTests(_ encoding: SearchEncoding, row: Int) {
        guard let popup = encodingPopupForTests(row: row),
              let index = SearchEncoding.allCases.firstIndex(of: encoding) else { return }
        popup.selectItem(at: index)
        encodingPicked(popup)
    }

    /// Ticks or unticks `row`'s Match Case box, the way a click does.
    func setCaseForTests(_ on: Bool, row: Int) {
        guard let box = caseCheckboxForTests(row: row) else { return }
        box.state = on ? .on : .off
        casePicked(box)
    }

    /// What the tab is complaining about, if anything.
    var messageForTests: String { messageLabel?.stringValue ?? "" }

    /// Drops `from` into the gap above `to`, through the same move a dragged
    /// row goes through.
    func dropForTests(from: Int, above to: Int) {
        move(from: from, above: to)
    }
}
