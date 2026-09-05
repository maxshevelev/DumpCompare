import Cocoa
import DumpCompareCore

/// The questions a merge could not answer, put to the user
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// One row per conflict, not one dialog per file: what happened is that two
/// machines said different things about *this pattern*, and that is what the
/// user has to see — "renamed here, deleted on the laptop" reads as what it is.
/// The two bulk answers are for the common case where one machine was simply
/// the right one.
///
/// Nothing is written until this sheet is answered, and the library is
/// read-only meanwhile (§11): a half-merged list must never be saved.
final class LibraryConflictSheetController: SheetViewController {
    private let conflicts: [LibraryConflict]
    private let onResolve: ([UUID: LibraryResolution]) -> Void

    /// The answer for each conflict, keyed the way `LibraryMerge.resolve` takes
    /// them. Every row starts on this machine's version — the state the app is
    /// already showing, so leaving the sheet alone changes nothing.
    private(set) var answers: [UUID: LibraryResolution] = [:]

    private var table: NSTableView!

    /// The inset the sheets keep from their own edges (§10).
    private static let sheetInset: CGFloat = 18

    private enum ColumnID {
        static let pattern = NSUserInterfaceItemIdentifier("conflictPattern")
        static let ours = NSUserInterfaceItemIdentifier("conflictOurs")
        static let theirs = NSUserInterfaceItemIdentifier("conflictTheirs")
        static let choice = NSUserInterfaceItemIdentifier("conflictChoice")
    }

    init(conflicts: [LibraryConflict],
         onResolve: @escaping ([UUID: LibraryResolution]) -> Void) {
        self.conflicts = conflicts
        self.onResolve = onResolve
        super.init(title: conflicts.count == 1 ? "One conflicting change"
                       : "\(conflicts.count) conflicting changes",
                   message: "This Mac and the shared library were both changed before either "
                       + "saw the other. Choose which to keep.")
        for conflict in conflicts { answers[conflict.id] = .keepOurs }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        super.loadView()
        let table = makeTable()
        contentStack.addArrangedSubview(table)
        contentStack.addArrangedSubview(makeBulkRow())
        // The sheet's width drives the table, not the other way round. A table
        // given a width of its own pushed past the sheet's insets and took the
        // buttons with it — a table against the window's edge, and "Keep All
        // Mine" against the frame.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 700),
            table.widthAnchor.constraint(equalTo: view.widthAnchor,
                                         constant: -2 * Self.sheetInset),
        ])
        submitButton.title = "Apply"
        // "Later" rather than "Cancel": the questions do not go away, the
        // library stays read-only, and the tab goes on offering the sheet.
        buttonRow.arrangedSubviews.compactMap { $0 as? NSButton }
            .first { $0.title == "Cancel" }?.title = "Later"
    }

    private func makeTable() -> NSView {
        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.allowsMultipleSelection = false

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            return column
        }
        // The four together must fit the sheet's width less its insets, or the
        // last one is squeezed to an ellipsis — which is the column the user
        // has to *use*.
        table.addTableColumn(column(ColumnID.pattern, "Entry", width: 130))
        table.addTableColumn(column(ColumnID.ours, "This Mac", width: 190))
        table.addTableColumn(column(ColumnID.theirs, "Shared Library", width: 190))
        table.addTableColumn(column(ColumnID.choice, "Keep", width: 140))
        self.table = table

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Room for four rows even when there is one: a sheet whose table is a
        // single line reads as a message with a stray control in it, and
        // conflicts arrive in twos and threes as often as alone.
        scrollView.heightAnchor.constraint(
            equalToConstant: CGFloat(min(max(conflicts.count, 4), 10) + 1) * 24 + 4).isActive = true
        return scrollView
    }

    /// For someone who knows which machine was right and does not want six
    /// questions.
    private func makeBulkRow() -> NSView {
        let mine = NSButton(title: "Keep All Mine", target: self, action: #selector(keepAllMine))
        let theirs = NSButton(title: "Keep All Theirs", target: self, action: #selector(keepAllTheirs))
        for button in [mine, theirs] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [mine, theirs, spacer])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - What a row says

    /// What the row is about: the entry, by the name this machine has for it.
    private func pattern(of conflict: LibraryConflict) -> String {
        switch conflict {
        case .bothEdited(let entry, _), .duplicate(let entry, _),
             .editedAndDeleted(let entry, _, _):
            return entry.label
        }
    }

    /// What one side says, in full. How an item reads is the view's business
    /// and lives with the naming (`SyncPresentable`).
    private func describe(_ entry: SearchPatternEntry) -> String { entry.summary }

    private func ourSide(of conflict: LibraryConflict) -> String {
        switch conflict {
        case .bothEdited(let ours, _), .duplicate(let ours, _):
            return describe(ours)
        case .editedAndDeleted(let entry, _, let deletedHere):
            return deletedHere ? "Deleted here" : "\(describe(entry)) — changed here"
        }
    }

    private func theirSide(of conflict: LibraryConflict) -> String {
        switch conflict {
        case .bothEdited(_, let theirs), .duplicate(_, let theirs):
            return describe(theirs)
        case .editedAndDeleted(let entry, let deletedBy, let deletedHere):
            if deletedHere { return "\(describe(entry)) — changed on another Mac" }
            return deletedBy.isEmpty ? "Deleted" : "Deleted on another Mac"
        }
    }

    /// "Keep both" means two entries, which is only an answer where the two are
    /// genuinely different searches — §11 keeps one search once.
    private func allowsKeepingBoth(_ conflict: LibraryConflict) -> Bool {
        if case .duplicate = conflict { return false }
        if case .editedAndDeleted = conflict { return false }
        return true
    }

    // MARK: - Actions

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard sender.tag < conflicts.count else { return }
        let conflict = conflicts[sender.tag]
        answers[conflict.id] = choices(for: conflict)[max(0, sender.indexOfSelectedItem)]
    }

    private func choices(for conflict: LibraryConflict) -> [LibraryResolution] {
        allowsKeepingBoth(conflict) ? [.keepOurs, .keepTheirs, .keepBoth] : [.keepOurs, .keepTheirs]
    }

    private func titles(for conflict: LibraryConflict) -> [String] {
        if case .editedAndDeleted(_, _, let deletedHere) = conflict {
            // Always this machine's side first, as every other row reads.
            return deletedHere ? ["The deletion", "Their version"] : ["Mine", "The deletion"]
        }
        return allowsKeepingBoth(conflict) ? ["This Mac", "Shared", "Both"] : ["This Mac", "Shared"]
    }

    @objc private func keepAllMine() {
        setAll(.keepOurs)
    }

    @objc private func keepAllTheirs() {
        setAll(.keepTheirs)
    }

    private func setAll(_ resolution: LibraryResolution) {
        for conflict in conflicts { answers[conflict.id] = resolution }
        table?.reloadData()
    }

    override func handleSubmit() {
        onResolve(answers)
    }

    /// The questions this sheet is asking, so whoever opened it can tell
    /// whether they are still the ones outstanding.
    var questions: [LibraryConflict] { conflicts }

    /// True once the sheet closed itself because those questions changed under
    /// it — answered on another Mac, or joined by new ones.
    private(set) var closedBecauseTheQuestionsChanged = false

    /// Closes the sheet because what it is asking about is no longer what is
    /// outstanding.
    ///
    /// An answer given on one Mac settles the same disagreement on the other,
    /// which is what makes this necessary: a sheet left standing offers a
    /// choice about something already decided, and its Apply would find nothing
    /// to apply. Better to take it away and say why than to let someone answer
    /// into nothing.
    func closeBecauseTheQuestionsChanged() {
        closedBecauseTheQuestionsChanged = true
        // Only what is actually on screen can be taken off it: AppKit raises
        // over a dismissal of something never presented, which is how this
        // sheet exists in a test run.
        guard presentingViewController != nil else { return }
        dismiss(self)
    }

    // MARK: - Test seams

    /// Answers one row the way picking from its popup does.
    func chooseForTests(_ resolution: LibraryResolution, row: Int) {
        guard row < conflicts.count else { return }
        answers[conflicts[row].id] = resolution
        table?.reloadData()
    }

    /// What a row reads, for tests: pattern, this Mac, the shared library.
    func rowForTests(_ row: Int) -> (pattern: String, ours: String, theirs: String)? {
        guard row < conflicts.count else { return nil }
        let conflict = conflicts[row]
        return (pattern(of: conflict), ourSide(of: conflict), theirSide(of: conflict))
    }

    var conflictCountForTests: Int { conflicts.count }

    func keepAllMineForTests() { keepAllMine() }
    func keepAllTheirsForTests() { keepAllTheirs() }
}

extension LibraryConflictSheetController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { conflicts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < conflicts.count, let id = tableColumn?.identifier else { return nil }
        let conflict = conflicts[row]
        switch id {
        case ColumnID.pattern:
            return label(pattern(of: conflict), monospaced: false)
        case ColumnID.ours:
            return label(ourSide(of: conflict), monospaced: false)
        case ColumnID.theirs:
            return label(theirSide(of: conflict), monospaced: false)
        case ColumnID.choice:
            let popup = NSPopUpButton()
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 12)
            for title in titles(for: conflict) { popup.addItem(withTitle: title) }
            let chosen = choices(for: conflict).firstIndex(of: answers[conflict.id] ?? .keepOurs) ?? 0
            popup.selectItem(at: chosen)
            popup.tag = row
            popup.target = self
            popup.action = #selector(choiceChanged(_:))
            return cell(around: popup)
        default:
            return nil
        }
    }

    private func label(_ text: String, monospaced: Bool) -> NSTableCellView {
        let field = NSTextField(labelWithString: text)
        field.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular)
                                : .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        let holder = cell(around: field)
        holder.textField = field
        return holder
    }

    private func cell(around control: NSView) -> NSTableCellView {
        let holder = NSTableCellView()
        control.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 2),
            control.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -2),
            control.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }
}
