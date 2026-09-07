import ALSplitView
import AppKit
import FITTool
import ToolModuleKit

/// The panel: the table's entries above, what is wrong with them below.
///
/// It decides nothing. Everything on screen comes from one `show(_:focus:canWrite:)`
/// over a `FITDisplay` built and tested in the pure target, so the list and the
/// outlines in the dump are one state rather than two copies of it.
@MainActor final class FITToolViewController: NSViewController {
    var onSelect: ((Int?) -> Void)?
    var onGoToTarget: ((Int) -> Void)?
    var onSelectTable: (() -> Void)?
    var onCopyCPUID: ((Int) -> Void)?
    var onReplaceMicrocode: ((Int) -> Void)?
    var onRemoveMicrocode: ((Int) -> Void)?
    var onAddMicrocode: (() -> Void)?
    var onGoToProblem: ((Int) -> Void)?
    var onFixChecksum: (() -> Void)?

    private(set) var display = FITDisplay.empty
    /// What the last `show` was allowed to do. Kept so the button and the menu
    /// items can come back exactly as they were once a parse that stood them
    /// down is done.
    private var canWrite = false
    /// True while a parse runs. The modification controls stand down for the
    /// whole of it — a parse reads a snapshot of the file as it is now, so
    /// letting an edit race it would make the bar a lie and the two sides of
    /// the panel disagree.
    private var busy = false

    /// True while the tables are being loaded from the model — a selection the
    /// code made is not news, and without this the panel selects, publishes,
    /// re-shows and selects again until the stack runs out.
    private var isShowingState = false

    let entries = NSTableView()
    let problems = NSTableView()
    private let entriesScroll = NSScrollView()
    private let problemsScroll = NSScrollView()
    private let detail = ToolDetailScroll()
    private let splitter = ALSplitView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(labelWithString: "")
    /// The row under the buttons: the notice, and the parse's progress bar on
    /// the same line while one runs — the module's own status line carries its
    /// progress rather than a second strip appearing below it.
    private let bottomRow = NSStackView()
    private let progressBar = NSProgressIndicator()
    private let addButton = NSButton()
    /// The problems list is as tall as its content, capped at half the height
    /// of the entries.
    private var problemsRatio: NSLayoutConstraint?
    private var problemsContent: NSLayoutConstraint?

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
        // The title names the table; clicking it takes the dump there and puts
        // the whole table in focus rather than a row.
        summaryLabel.toolTip = "Show the whole table in the dump"
        summaryLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(summaryClicked))
        )

        configure(entries, doubleAction: #selector(entryDoubleClicked))
        // Fixed widths, and the table scrolls sideways when they do not fit.
        // Squeezing "Points at" to whatever is left is how the one column with
        // something to say ends up saying "Microco…".
        entries.columnAutoresizingStyle = .noColumnAutoresizing
        column(entries, Column.index, "#", 20)
        column(entries, Column.type, "Type", 96)
        column(entries, Column.address, "Address", 76)
        column(entries, Column.size, "Size", 84)
        column(entries, Column.target, "Points at", 300)
        entries.menu = contextMenu()

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

        // Top: the entries. Bottom: the detail for the row in focus. The
        // divider is the user's to move. `ALSplitView` places its panes by
        // frame from its own bounds, so the third the detail starts with is a
        // policy rather than a position measured off a view that has not been
        // laid out yet.
        splitter.isVertical = false
        splitter.dividerThickness = 1
        splitter.translatesAutoresizingMaskIntoConstraints = false
        splitter.addPane(entriesScroll)
        splitter.addPane(detail)
        splitter.setPaneLayout(.fill, at: 0)
        splitter.setPaneLayout(.proportional(1.0 / 3), at: 1)

        func button(_ button: NSButton, _ title: String, _ action: Selector, _ tip: String) {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        // Remove and Fix Checksum are not buttons: they are offered where they
        // apply, in the row's menu, rather than on a bar that is always there.
        button(addButton, "Add Microcode…", #selector(addMicrocodeClicked),
               "Put a microcode in the image and name it in the table")

        let buttons = NSStackView(views: [addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        // The bar takes its width and the notice gives way: while a parse runs
        // the notice is one short sentence, and there is no bar when it is not.
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The parse's bar, not in the row yet — a session puts it there with
        // `showBusy()` and takes it away with `endBusy()`, so the notice owns
        // the whole row the rest of the time.
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addArrangedSubview(noticeLabel)

        view.addSubview(summaryLabel)
        view.addSubview(splitter)
        view.addSubview(problemsScroll)
        view.addSubview(buttons)
        view.addSubview(bottomRow)

        // As tall as it needs to be, up to half the splitter's height, and no
        // height at all when there is nothing to say — an empty box under a
        // table that checks out is a box the user has to work out the meaning
        // of, and a half-height box under one line is a lie about how much is
        // wrong. The cap is on the splitter, not on the entries scroll inside
        // it: a constraint that reaches into a split view's subview fights the
        // split view's own layout and is how the detail below loses its height.
        let ratio = problemsScroll.heightAnchor.constraint(
            lessThanOrEqualTo: splitter.heightAnchor, multiplier: 0.5
        )
        problemsRatio = ratio
        let content = problemsScroll.heightAnchor.constraint(equalToConstant: 0)
        content.priority = .defaultHigh
        problemsContent = content
        let bottom = bottomRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        // Breakable, for the reason the panel's own insets are (§19.2): a panel
        // squeezed to nothing is a legal state, and this chain must give way
        // there rather than log a conflict against the header's height.
        bottom.priority = .defaultHigh
        // The bar keeps this width while the notice wraps around it; high, not
        // required, so a row squeezed very narrow gives the bar up first.
        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            splitter.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            splitter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            splitter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            splitter.bottomAnchor.constraint(
                equalTo: problemsScroll.topAnchor, constant: -6
            ),

            problemsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            problemsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            problemsScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            ratio, content,

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

            bottomRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottom,
            barWidth
        ])
    }

    // MARK: - A parse's progress

    /// A parse is running: the bar joins the row under the buttons, and the
    /// one button — Add — stands down for the whole of it, with the menu items
    /// that modify the table (Remove Microcode, Fix Checksum) standing down
    /// beside it. A parse reads a snapshot of the file as it is *now*, so an
    /// edit that slipped in while it ran would make the bar a lie and the
    /// panel's next re-read the two of them disagreeing.
    ///
    /// The notice is left alone — `start()` has said "Reading…" and a re-read
    /// that follows an edit must not wipe the note the edit just earned — so
    /// this is only ever a bar appearing beside text, never a second line.
    func showBusy() {
        busy = true
        updateButtons()
        progressBar.doubleValue = 0
        guard progressBar.superview == nil else { return }
        bottomRow.addArrangedSubview(progressBar)
    }

    /// How far the parse has got, a fraction in 0…1. Reported from a detached
    /// task; the session hops it here.
    func updateProgress(_ fraction: Double) {
        progressBar.doubleValue = fraction
    }

    /// The parse is done: the bar leaves the row and the buttons come back as
    /// the last reading said they should.
    func endBusy() {
        busy = false
        updateButtons()
        guard progressBar.superview != nil else { return }
        bottomRow.removeArrangedSubview(progressBar)
        progressBar.removeFromSuperview()
    }

    /// What the one button is allowed to do right now. While a parse runs it
    /// stands down — the menu items that modify the table stand down with it,
    /// in `menuNeedsUpdate` — otherwise it follows the reading on show:
    /// nothing to add when the table is empty.
    private func updateButtons() {
        addButton.isEnabled = !busy && canWrite && !display.rows.isEmpty
    }

    private func configure(_ table: NSTableView, doubleAction: Selector) {
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        // The column order is the design's, not a drag target.
        table.allowsColumnReordering = false
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
        self.canWrite = canWrite
        isShowingState = true
        defer { isShowingState = false }

        summaryLabel.stringValue = display.summary
        entries.reloadData()
        problems.reloadData()
        renderDetail(display.detail, subject: focus.map(String.init) ?? "")
        if let focus, let row = display.rows.firstIndex(where: { $0.index == focus }) {
            entries.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            entries.deselectAll(nil)
        }
        updateButtons()

        let hasProblems = !display.problems.isEmpty
        problemsScroll.isHidden = !hasProblems
        problemsContent?.constant = hasProblems ? problemListHeight() : 0
    }

    /// Rebuilds the detail list from the fields the pure target decided.
    private func renderDetail(_ rowDetail: FITRowDetail, subject: String) {
        guard !rowDetail.fields.isEmpty else {
            detail.showPlaceholder(rowDetail.title.isEmpty
                ? "Select a row to see what it is."
                : rowDetail.title)
            return
        }
        detail.prepareForRows(subject: subject)

        if !rowDetail.title.isEmpty {
            let title = NSTextField(labelWithString: rowDetail.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(title)
        }

        for field in rowDetail.fields {
            let label = NSTextField(labelWithString: field.label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 104).isActive = true

            let value = NSTextField(labelWithString: field.value)
            value.font = field.value.hasPrefix("0x")
                ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 11)
            // Selectable, not a dead label: a bench copies an offset or a CPUID
            // out of here, and a value it cannot select is one it has to retype.
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingTail
            value.translatesAutoresizingMaskIntoConstraints = false

            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(row)
        }
    }

    /// What the problems would take to show without scrolling. Read off the
    /// table rather than assumed, so a row height set by the system still fits.
    private func problemListHeight() -> CGFloat {
        let row = problems.rowHeight + problems.intercellSpacing.height
        return CGFloat(display.problems.count) * row + 8
    }

    /// A line under the buttons — what happened, or what to do next. The panel
    /// has no room for an alert sheet and nothing here is worth one.
    ///
    /// A refusal is red, because it is the one kind of line the user has to
    /// read: they pressed something and it did not happen. Everything else is
    /// a note about what did.
    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func fixChecksumClicked() { onFixChecksum?() }
    @objc private func addMicrocodeClicked() { onAddMicrocode?() }
    @objc private func summaryClicked() { onSelectTable?() }

    @objc private func replaceMicrocodeFromMenuClicked() {
        guard let row = clickedEntry() else { return }
        onReplaceMicrocode?(row.index)
    }

    @objc private func removeMicrocodeFromMenuClicked() {
        guard let row = clickedEntry() else { return }
        onRemoveMicrocode?(row.index)
    }

    @objc private func entryDoubleClicked() {
        guard entries.clickedRow >= 0, entries.clickedRow < display.rows.count else { return }
        onGoToTarget?(display.rows[entries.clickedRow].index)
    }

    /// Built fresh every time it opens, for the row under the pointer:
    /// `clickedRow` is what a right-click sets, and an item that does not apply
    /// to that row should not be there rather than be there and greyed.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func copyCPUIDClicked() {
        guard let row = clickedEntry() else { return }
        onCopyCPUID?(row.index)
    }

    @objc private func goToOffsetClicked() {
        guard let row = clickedEntry() else { return }
        onGoToTarget?(row.index)
    }

    private func clickedEntry() -> FITDisplayRow? {
        let row = entries.clickedRow
        guard row >= 0, row < display.rows.count else { return nil }
        return display.rows[row]
    }

    @objc private func problemDoubleClicked() {
        guard problems.clickedRow >= 0, problems.clickedRow < display.problems.count else { return }
        onGoToProblem?(problems.clickedRow)
    }
}

extension FITToolViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The items that modify the table stand down for a parse — greyed, not
        // gone, so the menu still says what it would do once the reading is
        // done — and a parse reads a snapshot of the file, so an edit that
        // slipped in while it ran would make the two sides of the panel
        // disagree.
        menu.autoenablesItems = false
        guard let row = clickedEntry() else { return }
        for command in row.commands {
            let action: Selector
            switch command {
            case .copyCPUID: action = #selector(copyCPUIDClicked)
            case .goToOffset: action = #selector(goToOffsetClicked)
            case .replaceMicrocode: action = #selector(replaceMicrocodeFromMenuClicked)
            case .removeMicrocode: action = #selector(removeMicrocodeFromMenuClicked)
            case .fixChecksum: action = #selector(fixChecksumClicked)
            }
            let item = menu.addItem(withTitle: command.title, action: action, keyEquivalent: "")
            item.target = self
            if busy {
                switch command {
                case .replaceMicrocode, .removeMicrocode, .fixChecksum:
                    item.isEnabled = false
                default:
                    break
                }
            }
        }
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
            // The number the reader counts, from one — not the row's zero-based
            // place, which the header would show as 0.
            cell.textField?.stringValue = "\(entry.displayNumber)"
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
