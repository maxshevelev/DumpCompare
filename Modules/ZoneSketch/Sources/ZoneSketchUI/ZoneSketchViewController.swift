import AppKit
import ToolModuleKit
import ZoneSketch

/// The panel: a table of the zones sketched so far, and the four things that
/// can be done to them.
///
/// It decides nothing. Every button hands its intent to the session, and
/// everything on screen comes from one `show(_:focus:canWrite:)` — so what the
/// list says and what the dump draws are the same state rather than two copies
/// of it.
@MainActor final class ZoneSketchViewController: NSViewController {
    var onAdd: (() -> Void)?
    var onRemove: ((Zone.ID) -> Void)?
    var onFocus: ((Zone.ID?) -> Void)?
    var onRename: ((Zone.ID, String) -> Void)?
    var onGoTo: ((Zone.ID) -> Void)?
    var onFill: (() -> Void)?
    var onExport: (() -> Void)?

    private(set) var zones: [Zone] = []
    private(set) var focus: Zone.ID?

    /// True while the table is being loaded from the model.
    ///
    /// Without it the panel eats itself: showing the state re-selects the
    /// focused row, `NSTableView` reports that as a selection the user made,
    /// the session focuses it and shows the state again — a loop that ends when
    /// the stack does. The rule is the ordinary one for a control driven from a
    /// model: a change the code made is not news.
    private var isShowingState = false

    let table = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let fillButton = NSButton()
    private let exportButton = NSButton()
    private let noticeLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.translatesAutoresizingMaskIntoConstraints = false

        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        // The column order is the design's, not a drag target.
        table.allowsColumnReordering = false
        table.rowSizeStyle = .small
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Zone"
        name.width = 150
        let range = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("range"))
        range.title = "Offsets"
        range.width = 130
        table.addTableColumn(name)
        table.addTableColumn(range)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        func button(_ button: NSButton, _ title: String, _ action: Selector, _ tip: String) {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        button(addButton, "Add from Selection", #selector(addClicked),
               "Make a zone of what is selected in the dump")
        button(removeButton, "Remove", #selector(removeClicked), "Forget the selected zone")
        button(fillButton, "Fill FF", #selector(fillClicked),
               "Write FF over the selected zone — one undo step")
        button(exportButton, "Export…", #selector(exportClicked),
               "Save the selected zone's bytes to a file")

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [addButton, removeButton])
        let bottomRow = NSStackView(views: [fillButton, exportButton])
        for row in [topRow, bottomRow] {
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
        }

        view.addSubview(scrollView)
        view.addSubview(topRow)
        view.addSubview(bottomRow)
        view.addSubview(noticeLabel)

        let bottom = noticeLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        // Breakable, for the reason the panel's own insets are (§19.2): a panel
        // squeezed to nothing is a legal state, and this chain must give way
        // there instead of logging a conflict against the header's height.
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: topRow.topAnchor, constant: -8),

            topRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            topRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            topRow.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

            bottomRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottomRow.bottomAnchor.constraint(equalTo: noticeLabel.topAnchor, constant: -6),

            noticeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            noticeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottom
        ])
    }

    /// Everything the panel shows, in one call.
    func show(_ zones: [Zone], focus: Zone.ID?, canWrite: Bool) {
        self.zones = zones
        self.focus = focus
        isShowingState = true
        defer { isShowingState = false }
        table.reloadData()
        if let focus, let row = zones.firstIndex(where: { $0.id == focus }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        let hasFocus = focus != nil
        removeButton.isEnabled = hasFocus
        exportButton.isEnabled = hasFocus
        fillButton.isEnabled = hasFocus && canWrite
        if zones.isEmpty {
            say("Select some bytes in the dump and press Add.")
        }
    }

    /// A line under the buttons — what happened, or what to do next. The panel
    /// has no room for an alert and nothing here is worth one.
    func say(_ text: String) {
        noticeLabel.stringValue = text
    }

    // MARK: - Actions

    @objc private func addClicked() { onAdd?() }

    @objc private func removeClicked() {
        guard let focus else { return }
        onRemove?(focus)
    }

    @objc private func fillClicked() { onFill?() }
    @objc private func exportClicked() { onExport?() }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0, table.clickedRow < zones.count else { return }
        onGoTo?(zones[table.clickedRow].id)
    }
}

extension ZoneSketchViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { zones.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView? {
        guard row < zones.count, let column = tableColumn else { return nil }
        let zone = zones[row]
        let identifier = column.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        if identifier.rawValue == "name" {
            cell.textField?.stringValue = zone.name
            cell.textField?.isEditable = true
            cell.textField?.target = self
            cell.textField?.action = #selector(nameEdited(_:))
            cell.textField?.tag = row
        } else {
            cell.textField?.stringValue = ZoneSketchModel.rangeText(zone.range)
            cell.textField?.isEditable = false
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        let row = table.selectedRow
        onFocus?(row >= 0 && row < zones.count ? zones[row].id : nil)
    }

    @objc private func nameEdited(_ sender: NSTextField) {
        guard sender.tag >= 0, sender.tag < zones.count else { return }
        onRename?(zones[sender.tag].id, sender.stringValue)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
