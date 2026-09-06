import AppKit
import FITTool

/// The panel: the table's entries above, what is wrong with them below.
///
/// It decides nothing. Everything on screen comes from one `show(_:focus:canWrite:)`
/// over a `FITDisplay` built and tested in the pure target, so the list and the
/// outlines in the dump are one state rather than two copies of it.
@MainActor final class FITToolViewController: NSViewController {
    var onSelect: ((Int?) -> Void)?
    var onGoToTarget: ((Int) -> Void)?
    var onGoToProblem: ((Int) -> Void)?
    var onFixChecksum: (() -> Void)?

    private(set) var display = FITDisplay.empty

    /// True while the tables are being loaded from the model — a selection the
    /// code made is not news, and without this the panel selects, publishes,
    /// re-shows and selects again until the stack runs out.
    private var isShowingState = false

    let entries = NSTableView()
    let problems = NSTableView()
    private let entriesScroll = NSScrollView()
    private let problemsScroll = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(labelWithString: "")
    private let fixChecksumButton = NSButton()
    /// The problems list gets half the height of the entries when there is
    /// something in it, and none at all when there is not.
    private var problemsRatio: NSLayoutConstraint?
    private var problemsCollapsed: NSLayoutConstraint?

    private enum Column {
        static let index = NSUserInterfaceItemIdentifier("index")
        static let type = NSUserInterfaceItemIdentifier("type")
        static let address = NSUserInterfaceItemIdentifier("address")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let target = NSUserInterfaceItemIdentifier("target")
        static let problem = NSUserInterfaceItemIdentifier("problem")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 500))
        view.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(entries, doubleAction: #selector(entryDoubleClicked))
        // What a row points at is the column worth the slack when the user
        // widens the panel; the fields in front of it are fixed-width by
        // nature.
        entries.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        column(entries, Column.index, "#", 22)
        column(entries, Column.type, "Type", 132)
        column(entries, Column.address, "Address", 84)
        column(entries, Column.size, "Size", 62)
        column(entries, Column.target, "Points at", 180)

        configure(problems, doubleAction: #selector(problemDoubleClicked))
        problems.headerView = nil
        column(problems, Column.problem, "Problem", 420)

        for (scroll, table) in [(entriesScroll, entries), (problemsScroll, problems)] {
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
        }

        fixChecksumButton.title = "Fix Checksum"
        fixChecksumButton.bezelStyle = .rounded
        fixChecksumButton.controlSize = .small
        fixChecksumButton.target = self
        fixChecksumButton.action = #selector(fixChecksumClicked)
        fixChecksumButton.toolTip =
            "Write the checksum this table should have — one undo step"
        fixChecksumButton.translatesAutoresizingMaskIntoConstraints = false

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(summaryLabel)
        view.addSubview(entriesScroll)
        view.addSubview(problemsScroll)
        view.addSubview(fixChecksumButton)
        view.addSubview(noticeLabel)

        // Half the entries' height when there is something to say, and no
        // height at all when there is not — an empty box under a good table is
        // a box the user has to work out the meaning of.
        let ratio = problemsScroll.heightAnchor.constraint(
            equalTo: entriesScroll.heightAnchor, multiplier: 0.5
        )
        ratio.priority = .defaultHigh
        problemsRatio = ratio
        let collapsed = problemsScroll.heightAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultHigh
        problemsCollapsed = collapsed
        let bottom = noticeLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        // Breakable, for the reason the panel's own insets are (§19.2): a panel
        // squeezed to nothing is a legal state, and this chain must give way
        // there rather than log a conflict against the header's height.
        bottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            entriesScroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            entriesScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            entriesScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            entriesScroll.bottomAnchor.constraint(
                equalTo: problemsScroll.topAnchor, constant: -6
            ),

            problemsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            problemsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            problemsScroll.bottomAnchor.constraint(
                equalTo: fixChecksumButton.topAnchor, constant: -6
            ),
            ratio,

            fixChecksumButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            fixChecksumButton.bottomAnchor.constraint(
                equalTo: noticeLabel.topAnchor, constant: -6
            ),

            noticeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            noticeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottom
        ])
    }

    private func configure(_ table: NSTableView, doubleAction: Selector) {
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .small
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = doubleAction
    }

    private func column(
        _ table: NSTableView,
        _ identifier: NSUserInterfaceItemIdentifier,
        _ title: String,
        _ width: CGFloat
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        table.addTableColumn(column)
    }

    /// Everything the panel shows, in one call.
    func show(_ display: FITDisplay, focus: Int?, canWrite: Bool) {
        self.display = display
        isShowingState = true
        defer { isShowingState = false }

        summaryLabel.stringValue = display.summary
        entries.reloadData()
        problems.reloadData()
        if let focus, let row = display.rows.firstIndex(where: { $0.index == focus }) {
            entries.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            entries.deselectAll(nil)
        }
        fixChecksumButton.isEnabled = display.checksumFix != nil && canWrite

        let hasProblems = !display.problems.isEmpty
        problemsScroll.isHidden = !hasProblems
        problemsRatio?.isActive = hasProblems
        problemsCollapsed?.isActive = !hasProblems
    }

    /// A line under the buttons — what happened, or what to do next. The panel
    /// has no room for an alert and nothing here is worth one.
    func say(_ text: String) {
        noticeLabel.stringValue = text
    }

    // MARK: - Actions

    @objc private func fixChecksumClicked() { onFixChecksum?() }

    @objc private func entryDoubleClicked() {
        guard entries.clickedRow >= 0, entries.clickedRow < display.rows.count else { return }
        onGoToTarget?(display.rows[entries.clickedRow].index)
    }

    @objc private func problemDoubleClicked() {
        guard problems.clickedRow >= 0, problems.clickedRow < display.problems.count else { return }
        onGoToProblem?(problems.clickedRow)
    }
}

extension FITToolViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === problems ? display.problems.count : display.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView? {
        guard let column = tableColumn else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self)
            as? NSTableCellView ?? makeCell(identifier: column.identifier)

        if tableView === problems {
            guard row < display.problems.count else { return nil }
            let problem = display.problems[row]
            cell.textField?.stringValue = problem.message
            cell.textField?.textColor = problem.severity == .error ? .systemRed : .secondaryLabelColor
            return cell
        }

        guard row < display.rows.count else { return nil }
        let entry = display.rows[row]
        let monospaced = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        switch column.identifier {
        case Column.index:
            cell.textField?.stringValue = "\(entry.index)"
            cell.textField?.font = monospaced
        case Column.type:
            cell.textField?.stringValue = entry.typeText
            cell.textField?.font = .systemFont(ofSize: 11)
        case Column.address:
            cell.textField?.stringValue = entry.addressText
            cell.textField?.font = monospaced
        case Column.size:
            cell.textField?.stringValue = entry.sizeText
            cell.textField?.font = monospaced
        default:
            cell.textField?.stringValue = entry.targetText
            cell.textField?.font = .systemFont(ofSize: 11)
        }
        // A row the validator complained about is red wherever the eye lands on
        // it, not only in the list below.
        cell.textField?.textColor = entry.hasProblem ? .systemRed : .labelColor
        // The version is a real field and it decides how a policy row's address
        // is read (§7.3), but it is the same 1.00 on almost every row — so it
        // lives where a curious pointer finds it rather than in a column.
        cell.textField?.toolTip = column.identifier == Column.type
            ? "Version \(entry.versionText)"
            : (entry.targetText.isEmpty ? nil : entry.targetText)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState, notification.object as AnyObject? === entries else { return }
        let row = entries.selectedRow
        onSelect?(row >= 0 && row < display.rows.count ? display.rows[row].index : nil)
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
