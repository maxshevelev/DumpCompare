import Cocoa

/// The File Types tab of the Settings window (§25): the extensions the app
/// offers to open on a double-click, each row saying which app opens it now and
/// a checkbox for making it this one.
///
/// The checkbox is not a stored preference — it is a reading of the system
/// (§25.3). Every change is a request to Launch Services, macOS may put its own
/// confirmation in front of it, and the answer can be no; so nothing is assumed
/// after a click, the row is simply re-read. That is also why the tab re-reads
/// on every appearance: a default changed in Finder must show up here.
final class FileTypesSettingsViewController: NSViewController,
                                            NSTableViewDataSource, NSTableViewDelegate {
    /// The rows as the table currently shows them — a snapshot, so a row index
    /// means the same thing to every method that reads one.
    private(set) var rows: [DefaultHandlerSettings.Entry] = []

    /// The widgets. Internal so tests can click them: the settings window is not
    /// on screen under XCTest.
    private(set) var table: NSTableView!
    private(set) var addButton: NSButton!
    private(set) var removeButton: NSButton!

    // MARK: - Seams
    //
    // Everything that reaches the system, or the user, goes through a closure a
    // test can replace: the real calls change the machine's file associations
    // and can raise a modal alert, neither of which belongs in a test run.

    /// Asks for an extension to add. Nil when the user cancelled.
    var promptForExtension: (() -> String?)?
    /// Says something the user has to read (the cases macOS itself cannot).
    var presentMessage: ((String) -> Void) = FileTypesSettingsViewController.showMessage
    /// Reads the system: is this app the handler, and whose name to show.
    var isSelfDefault: ((String) -> Bool) = DefaultHandlerService.isSelfDefault(for:)
    var handlerName: ((String) -> String?) = DefaultHandlerService.handlerName(for:)
    var currentHandlerIdentifier: ((String) -> String?) = DefaultHandlerService.currentHandlerIdentifier(for:)
    /// Writes the system.
    var setSelfAsDefault: ((String, @escaping (Error?) -> Void) -> Void) = { ext, then in
        DefaultHandlerService.setSelfAsDefault(for: ext, then: then)
    }
    var setHandler: ((String, String, @escaping (Error?) -> Void) -> Void) = { ext, bundleID, then in
        DefaultHandlerService.setHandler(bundleIdentifier: bundleID, for: ext, then: then)
    }

    private enum ColumnID {
        static let enabled = NSUserInterfaceItemIdentifier("fileTypeEnabled")
        static let ext = NSUserInterfaceItemIdentifier("fileTypeExtension")
        static let handler = NSUserInterfaceItemIdentifier("fileTypeHandler")
    }

    /// The list's height: the rows it has, floored so an empty list is not a
    /// sliver and capped so a long one scrolls instead of growing the window.
    private var tableHeight: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 24
    private static let minVisibleRows = 3
    private static let maxVisibleRows = 8

    // MARK: - Layout

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: "File Types")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        let list = makeTable()
        let footer = makeFooter()

        let caption = NSTextField(wrappingLabelWithString:
            "Ticking a type asks macOS to open files with that extension in DumpCompare; "
            + "macOS may ask you to confirm. Unticking hands the type back to the app it "
            + "was taken from. Add any extension you keep dumps under — it works the same.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 4

        for subview in [titleLabel, list, footer, caption] {
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

            caption.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            // Pinned, not bounded: the window sizes to this view's fitting size,
            // and a floor would leave an empty band under the text.
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            // Exact width, like every other tab: a wrapping label's ideal width
            // is its whole text on one line, so only a fixed width makes it wrap
            // and the fitting size come out right.
            root.widthAnchor.constraint(equalToConstant: 480),
        ])
        view = root

        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The truth may have moved while the tab was away — a default changed in
        // Finder, or by another app (§25.3).
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
        table.addTableColumn(column(ColumnID.enabled, "Open With DumpCompare", width: 160))
        table.addTableColumn(column(ColumnID.ext, "Extension", width: 90))
        table.addTableColumn(column(ColumnID.handler, "Opens With Now", width: 170))
        self.table = table

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.height(forRows: 2))
        tableHeight.isActive = true
        return scrollView
    }

    private static func height(forRows count: Int) -> CGFloat {
        let visible = min(max(count, minVisibleRows), maxVisibleRows)
        // The header takes a row's worth of space on top of the rows themselves.
        return CGFloat(visible + 1) * rowHeight + 4
    }

    /// The `+`/`−` footer under the table — the Segments form's idiom (§21.4):
    /// two small borderless icon buttons at the left, drawn into one square
    /// bitmap each so the `+` and the `−` come out the same size.
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
        plus.image = footerIcon("plus", "Add File Type")
        plus.imagePosition = .imageOnly
        plus.isBordered = false
        plus.contentTintColor = .secondaryLabelColor
        plus.toolTip = "Add a file extension…"
        plus.setAccessibilityLabel("Add File Type")
        addButton = plus

        let minus = NSButton(title: "", target: self, action: #selector(removePressed))
        minus.image = footerIcon("minus", "Remove File Type")
        minus.imagePosition = .imageOnly
        minus.isBordered = false
        minus.contentTintColor = .secondaryLabelColor
        minus.toolTip = "Remove the selected file extension"
        minus.setAccessibilityLabel("Remove File Type")
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

    /// Re-reads the list and the system, and repaints. The single path by which
    /// anything on screen changes: no click assumes its own outcome (§25.3).
    func reload() {
        rows = DefaultHandlerSettings.entries
        tableHeight?.constant = Self.height(forRows: rows.count)
        table?.reloadData()
        updateRemoveButton()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier else { return nil }
        let entry = rows[row]
        switch id {
        case ColumnID.enabled:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(togglePressed(_:)))
            checkbox.tag = row
            checkbox.state = isSelfDefault(entry.ext) ? .on : .off
            checkbox.setAccessibilityLabel("Open .\(entry.ext) with DumpCompare")
            let cell = NSTableCellView()
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case ColumnID.ext:
            return label(".\(entry.ext)", secondary: false)
        case ColumnID.handler:
            // "—" rather than an empty cell: nothing claims the type, which is a
            // fact worth reading, not a missing value.
            return label(handlerName(entry.ext) ?? "—", secondary: true)
        default:
            return nil
        }
    }

    private func label(_ text: String, secondary: Bool) -> NSTableCellView {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        removeButton?.isEnabled = (table?.selectedRow ?? -1) >= 0
    }

    /// The checkbox in `row`, for tests: the cell is built on demand, so this
    /// asks the table for the view it is showing.
    func checkbox(atRow row: Int) -> NSButton? {
        guard let table, row < rows.count,
              let column = table.tableColumns.firstIndex(where: { $0.identifier == ColumnID.enabled })
        else { return nil }
        let cell = table.view(atColumn: column, row: row, makeIfNecessary: true)
        return cell?.subviews.compactMap { $0 as? NSButton }.first
    }

    /// The handler name shown in `row`, for tests.
    func handlerLabel(atRow row: Int) -> String? {
        guard let table, row < rows.count,
              let column = table.tableColumns.firstIndex(where: { $0.identifier == ColumnID.handler })
        else { return nil }
        let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.stringValue
    }

    // MARK: - Actions

    @objc private func togglePressed(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        let entry = rows[sender.tag]
        if sender.state == .on {
            register(entry.ext)
        } else {
            unregister(entry)
        }
    }

    /// Takes the type over. The handler being displaced is recorded first —
    /// after the change the answer is this app, and unchecking would have
    /// nowhere to hand the type back to (§25.3).
    private func register(_ ext: String) {
        let displaced = currentHandlerIdentifier(ext)
        if displaced != DefaultHandlerService.selfBundleIdentifier {
            DefaultHandlerSettings.recordDisplacedHandler(displaced, for: ext)
        }
        setSelfAsDefault(ext) { [weak self] _ in
            // Whatever came back — success, or the user declining the system's
            // confirmation — the row is re-read rather than assumed.
            self?.reload()
        }
    }

    /// Hands the type back to whoever had it. There is no API to clear a
    /// default, so with nobody recorded there is nothing this tab can do but say
    /// so (§25.3).
    private func unregister(_ entry: DefaultHandlerSettings.Entry) {
        guard let displaced = entry.displacedHandler else {
            presentMessage("macOS has no way to un-set a default application. "
                            + "Choose another app for .\(entry.ext) in Finder: select a file, "
                            + "press ⌘I, and use Open with ▸ Change All.")
            reload()
            return
        }
        setHandler(entry.ext, displaced) { [weak self] error in
            if error == nil {
                DefaultHandlerSettings.clearDisplacedHandler(for: entry.ext)
            }
            self?.reload()
        }
    }

    @objc private func addPressed() {
        guard let raw = prompt() else { return }
        guard let ext = DefaultHandlerSettings.add(raw) else {
            presentMessage("\"\(raw)\" is not a file extension. Use letters and digits, "
                            + "for example dump or bin.")
            return
        }
        reload()
        if let index = rows.firstIndex(where: { $0.ext == ext }) {
            table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    @objc private func removePressed() {
        guard let table, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        // Only the row leaves the list: the file association stays where it is.
        // Removing a type the app holds and then wondering why .bin still opens
        // here would be worse than leaving the row in place, so the message says
        // what happened.
        let entry = rows[table.selectedRow]
        DefaultHandlerSettings.remove(entry.ext)
        reload()
        if isSelfDefault(entry.ext) {
            presentMessage("Removed .\(entry.ext) from the list. macOS still opens .\(entry.ext) "
                            + "files with DumpCompare — put the type back and untick it to hand it over.")
        }
    }

    /// The plain informational alert behind `presentMessage`.
    static func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "File Types"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The add prompt: a small alert with a text field. Behind a seam because a
    /// modal alert has no one to dismiss it in a test run.
    private func prompt() -> String? {
        if let promptForExtension { return promptForExtension() }
        let alert = NSAlert()
        alert.messageText = "Add File Type"
        alert.informativeText = "The file extension to open with DumpCompare, for example dump."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
