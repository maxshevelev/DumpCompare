import AppKit
import FITTool

/// The sheet for adding a microcode: the catalogue from
/// `github.com/platomav/CPUMicrocodes`, narrowed down.
///
/// It decides nothing about the image — the placement, the transaction and
/// every refusal are the session's. What it owns is the narrowing, and even
/// that is done by `MicrocodeCatalogue.filter`, which is tested without a
/// window.
@MainActor final class FITAddMicrocodeViewController: NSViewController {
    var onAdd: ((MicrocodeCatalogueEntry) -> Void)?
    var onChooseFile: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The CPUIDs the open image already names. A dump is for one board, and
    /// what is worth adding to it is almost always a newer revision of one of
    /// these — so that is the list it opens on.
    var cpuidsInTheImage: Set<UInt32> = []

    private var entries: [MicrocodeCatalogueEntry] = []
    private(set) var shown: [MicrocodeCatalogueEntry] = []

    let table = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let onlyInImage = NSButton(checkboxWithTitle: "Only CPUIDs in this image",
                                       target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let progress = NSProgressIndicator()

    private enum Column {
        static let cpuid = NSUserInterfaceItemIdentifier("cpuid")
        static let platform = NSUserInterfaceItemIdentifier("platform")
        static let revision = NSUserInterfaceItemIdentifier("revision")
        static let date = NSUserInterfaceItemIdentifier("date")
        static let release = NSUserInterfaceItemIdentifier("release")
        static let size = NSUserInterfaceItemIdentifier("size")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))

        // "Intel" in the title and not only in the line below it: the list has
        // no vendor picker any more, so what is being shown has to be said
        // where it cannot be missed.
        let title = NSTextField(labelWithString: "Add Intel Microcode")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let source = NSTextField(labelWithString:
            "From github.com/platomav/CPUMicrocodes — a FIT names no other kind.")
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor

        searchField.placeholderString = "CPUID, revision or file name"
        searchField.target = self
        searchField.action = #selector(narrow)
        onlyInImage.target = self
        onlyInImage.action = #selector(narrow)
        onlyInImage.controlSize = .small
        // Off to begin with: picking a vendor is asking to see what that vendor
        // has, and narrowing it before the user has looked would hide most of
        // it.
        onlyInImage.state = .off

        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .small
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(addClicked)
        column(Column.cpuid, "CPUID", 70)
        column(Column.platform, "Plat", 46)
        column(Column.revision, "Revision", 74)
        column(Column.date, "Date", 90)
        column(Column.release, "Release", 74)
        column(Column.size, "Size", 70)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        func button(_ title: String, _ action: Selector, _ key: String = "") -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.keyEquivalent = key
            return button
        }
        addButton.title = "Add"
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.isEnabled = false
        let cancel = button("Cancel", #selector(cancelClicked), "\u{1b}")
        let chooseFile = button("Choose File…", #selector(chooseFileClicked))
        chooseFile.toolTip = "Add a microcode you already have, without the network"

        let filters = NSStackView(views: [onlyInImage, searchField])
        filters.orientation = .horizontal
        filters.spacing = 8
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        let buttons = NSStackView(views: [progress, statusLabel, spacer, chooseFile,
                                          cancel, addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, source, filters, scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            filters.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    private func column(_ identifier: NSUserInterfaceItemIdentifier, _ title: String,
                        _ width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        table.addTableColumn(column)
    }

    /// The catalogue arrived.
    func show(_ entries: [MicrocodeCatalogueEntry]) {
        self.entries = entries
        onlyInImage.isEnabled = !cpuidsInTheImage.isEmpty
        narrow()
    }

    /// A line at the bottom: what is happening, or what went wrong. What went
    /// wrong is red — the sheet is where the user is looking, and a grey line
    /// under a list they are reading goes unread.
    func say(_ text: String, busy: Bool = false, asProblem: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = asProblem ? .systemRed : .secondaryLabelColor
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    var selectedEntry: MicrocodeCatalogueEntry? {
        let row = table.selectedRow
        return row >= 0 && row < shown.count ? shown[row] : nil
    }

    @objc private func narrow() {
        // Intel and nothing else: a FIT names no other kind (§6, §7.1), so
        // listing AMD or VIA would be listing what cannot be added.
        shown = MicrocodeCatalogue.filter(
            entries,
            vendor: .intel,
            search: searchField.stringValue,
            cpuidsInTheImage: onlyInImage.state == .on ? cpuidsInTheImage : nil
        )
        table.reloadData()
        addButton.isEnabled = false
        guard !entries.isEmpty else { return say("") }
        let total = MicrocodeCatalogue.counts(in: entries)[.intel] ?? 0
        say(shown.count == total
            ? "\(total) Intel microcodes"
            : "\(shown.count) of \(total) Intel microcodes")
    }

    @objc private func addClicked() {
        guard let entry = selectedEntry else { return }
        onAdd?(entry)
    }

    @objc private func cancelClicked() { onCancel?() }
    @objc private func chooseFileClicked() { onChooseFile?() }
}

extension FITAddMicrocodeViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView? {
        guard row < shown.count, let column = tableColumn else { return nil }
        let entry = shown[row]
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self)
            as? NSTableCellView ?? makeCell(identifier: column.identifier)
        cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cell.textField?.textColor = .labelColor
        switch column.identifier {
        case Column.cpuid: cell.textField?.stringValue = entry.cpuidText
        case Column.platform: cell.textField?.stringValue = entry.platformText
        case Column.revision: cell.textField?.stringValue = entry.revisionText
        case Column.date: cell.textField?.stringValue = entry.date
        case Column.release:
            cell.textField?.stringValue = entry.isProduction ? "PRD" : "pre-release"
            cell.textField?.font = .systemFont(ofSize: 11)
            // A pre-release is worth telling apart before it goes into a board.
            cell.textField?.textColor = entry.isProduction ? .labelColor : .systemOrange
        default:
            cell.textField?.stringValue = "0x" + String(entry.size, radix: 16, uppercase: true)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addButton.isEnabled = selectedEntry != nil
        // A CPUID the table already names is replaced rather than added a
        // second time, and the button says which it will be before it is
        // pressed.
        let replaces = selectedEntry?.cpuid.map(cpuidsInTheImage.contains) ?? false
        addButton.title = replaces ? "Replace" : "Add"
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
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
