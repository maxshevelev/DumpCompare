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
    private let vendorPopUp = NSPopUpButton()
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

        let title = NSTextField(labelWithString: "Add Microcode")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let source = NSTextField(labelWithString:
            "From github.com/platomav/CPUMicrocodes. A FIT names Intel microcode only —"
            + " the other vendors are here to look at.")
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor

        searchField.placeholderString = "CPUID, revision or file name"
        searchField.target = self
        searchField.action = #selector(narrow)
        // Every vendor the collection has a directory for, Intel first because
        // that is the only kind a FIT can name.
        for vendor in MicrocodeVendor.allCases {
            vendorPopUp.addItem(withTitle: vendor.rawValue)
        }
        vendorPopUp.selectItem(at: 0)
        vendorPopUp.target = self
        vendorPopUp.action = #selector(narrow)
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

        // Labelled, because the column two rows down is called "Plat" and means
        // Intel's platform id — a different thing entirely.
        let vendorLabel = NSTextField(labelWithString: "Vendor:")
        vendorLabel.font = .systemFont(ofSize: 11)
        vendorLabel.textColor = .secondaryLabelColor

        let filters = NSStackView(views: [vendorLabel, vendorPopUp, onlyInImage, searchField])
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
        let counts = MicrocodeCatalogue.counts(in: entries)
        for (index, vendor) in MicrocodeVendor.allCases.enumerated() {
            vendorPopUp.item(at: index)?.title =
                "\(vendor.rawValue) (\(counts[vendor] ?? 0))"
        }
        onlyInImage.isEnabled = !cpuidsInTheImage.isEmpty
        narrow()
    }

    /// The vendor the popup is on. Intel unless the user says otherwise: it is
    /// the only kind a FIT can name.
    private var vendor: MicrocodeVendor {
        let index = vendorPopUp.indexOfSelectedItem
        let all = MicrocodeVendor.allCases
        return index >= 0 && index < all.count ? all[index] : .intel
    }

    /// A line at the bottom: what is happening, or what went wrong.
    func say(_ text: String, busy: Bool = false) {
        statusLabel.stringValue = text
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    var selectedEntry: MicrocodeCatalogueEntry? {
        let row = table.selectedRow
        return row >= 0 && row < shown.count ? shown[row] : nil
    }

    @objc private func narrow() {
        shown = MicrocodeCatalogue.filter(
            entries,
            vendor: vendor,
            search: searchField.stringValue,
            cpuidsInTheImage: onlyInImage.state == .on ? cpuidsInTheImage : nil
        )
        table.reloadData()
        addButton.isEnabled = false
        guard !entries.isEmpty else { return say("") }
        let total = MicrocodeCatalogue.counts(in: entries)[vendor] ?? 0
        say(shown.count == total
            ? "\(total) \(vendor.rawValue) microcodes"
            : "\(shown.count) of \(total) \(vendor.rawValue) microcodes")
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
