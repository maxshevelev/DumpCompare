import Cocoa
import DumpCompareCore

/// The Segments form (§21.4): the place the partition is read and edited —
/// modal, like Go To. The table lists the pieces in file order (label, start,
/// size, name); a double click on a row, or the row's context menu, edits one in
/// the stage 2 popover (offset and description); a `+`/`−` footer under the
/// table adds a cut and removes the selected piece; the button row holds what
/// acts on the whole partition (Save All as Separate Files… and Close).
///
/// It follows the pane's store through `onChange` (§21.4), the way the Go To
/// form follows the window's bookmark store (§20.5), so nothing is duplicated
/// while it is open: a cut made from the dump's own context menu shows up here
/// without the form having to ask. Modality costs nothing because nothing in the
/// form needs the dump to move underneath it — a cut is made by typing an offset
/// in the popover, not by aiming at a row.
@MainActor
final class SegmentsFormController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// The pane whose partition the form shows. One form, one pane: the segments
    /// of the file the user is looking at (§21.1), not the window's.
    private let pane: PaneViewModel

    /// The jump itself (§21.4): Return on a selected row closes the form and
    /// lands the caret on the piece's start, revealed the way the Go To form's
    /// jump reveals (§10.1). The presenter owns the reveal — the form holds the
    /// pane, not its view — the same division the Go To form makes.
    private let onGo: (UInt64) -> Void

    /// The pieces as the table currently shows them — a snapshot, so a row index
    /// means the same thing to every method that reads one, and the store is
    /// asked once per reload rather than once per cell.
    private(set) var segments: [Segment] = []

    /// The widgets. Internal so tests can select rows and read the table; a modal
    /// window has no one to click it under XCTest.
    private(set) var segmentTable: NSTableView!
    private(set) var addButton: NSButton!
    private(set) var removeButton: NSButton!
    private(set) var removeAllButton: NSButton!
    private(set) var saveAllButton: NSButton!
    private(set) var closeButton: NSButton!

    /// The list's height, re-set from the number of pieces (§20.5).
    private var tableHeight: NSLayoutConstraint!

    /// How the form closes itself. Replaced in tests: `dismiss` traps on a
    /// controller that was never presented, and what those tests are about is
    /// what the form asks for, not the window it lives in.
    var dismissForm: (() -> Void)?

    /// Where a cut popover goes — the row editor's and the `+` button's are the
    /// same popover (§21.4). Nil means the real popover on the row or the button;
    /// a test replaces it, because a popover anchored in a window that is never
    /// on screen closes the instant it opens.
    var editPopoverPresenter: ((CutEditPopoverController) -> Void)?

    /// How the form confirms a destructive act (Remove All). Replaced in tests:
    /// a real NSAlert's `runModal` hangs a headless host, and what those tests
    /// are about is what the form does once it is allowed, not the alert it
    /// shows. Returns whether to proceed.
    var confirmRemoveAll: (() -> Bool)?

    /// The popover on screen, if any: Escape closes it before it closes the form
    /// (§10.1), and it must not outlive the piece it is editing.
    private weak var openEditPopover: CutEditPopoverController?

    /// Whether a piece's editor is up — what Escape's first level acts on.
    var isEditingSegment: Bool { openEditPopover != nil }

    /// What a refused Return sounds like. A closure so a test can hear it: a beep
    /// leaves no trace of its own.
    var beep: () -> Void = { NSSound.beep() }

    private enum ColumnID {
        static let label = NSUserInterfaceItemIdentifier("segmentLabel")
        static let start = NSUserInterfaceItemIdentifier("segmentStart")
        static let size = NSUserInterfaceItemIdentifier("segmentSize")
        static let name = NSUserInterfaceItemIdentifier("segmentName")
    }

    init(pane: PaneViewModel, onGo: @escaping (UInt64) -> Void) {
        self.pane = pane
        self.onGo = onGo
        super.init(nibName: nil, bundle: nil)
        // The presented window takes its title from here (§10.1).
        title = "Segments"
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

        let scrollView = makeTable()
        // The list is as tall as it needs to be, up to `maxVisibleRows`: a form
        // that opened with a page of empty table over three pieces would be
        // mostly nothing. `updateTableHeight` sets the constant.
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        root.addArrangedSubview(scrollView)

        root.addArrangedSubview(makeFooter())
        root.addArrangedSubview(makeButtonRow())

        // A root that can claim Escape before the Close button's key equivalent
        // does — that is the whole of the two-level Escape (§10.1).
        let contentView = SegmentsFormView()
        contentView.escapeHandler = { [weak self] in self?.cancelEdit() ?? false }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),

            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor,
                                              constant: -(root.edgeInsets.left + root.edgeInsets.right)),
            tableHeight,
        ])
        // The footer and the button row span the table, inside the root's insets.
        for arranged in root.arrangedSubviews where arranged !== scrollView {
            NSLayoutConstraint.activate([
                arranged.widthAnchor.constraint(equalTo: root.widthAnchor,
                                                constant: -(root.edgeInsets.left + root.edgeInsets.right)),
            ])
        }
        // A concrete frame lets the presentation size the window before auto
        // layout runs (the view arrives with a zero frame), as the sheets do.
        contentView.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        view = contentView

        reloadSegments()   // also sizes the list to its rows
    }

    /// The list and its `+`/`−` footer. The footer is the way Apple's own tables
    /// do it (the Target Dependencies pane in Xcode is the reference): a hairline,
    /// then two borderless small buttons at the left (§21.4).
    private func makeTable() -> NSScrollView {
        let labelColumn = NSTableColumn(identifier: ColumnID.label)
        labelColumn.title = "Segment"
        labelColumn.width = 64
        labelColumn.minWidth = 56
        labelColumn.maxWidth = 96

        let startColumn = NSTableColumn(identifier: ColumnID.start)
        startColumn.title = "Start"
        startColumn.width = 96
        startColumn.minWidth = 72

        let sizeColumn = NSTableColumn(identifier: ColumnID.size)
        sizeColumn.title = "Size"
        sizeColumn.width = 72
        sizeColumn.minWidth = 48

        let nameColumn = NSTableColumn(identifier: ColumnID.name)
        nameColumn.title = "Name"
        nameColumn.width = 240
        nameColumn.minWidth = 80

        let table = SegmentTableView()
        table.addTableColumn(labelColumn)
        table.addTableColumn(startColumn)
        table.addTableColumn(sizeColumn)
        table.addTableColumn(nameColumn)
        // The columns are self-evident (a label, an address, a size, a name), so
        // no header row — the Go To form's list makes the same choice.
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        // Spare width goes to the Name column, not shared out: the label, the
        // address and the size are fixed, and stretching them only pushes the
        // names away from the pieces they belong to.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // No stripes: a handful of pieces in a tall box would be a few rows of
        // content in a page of banding — the pieces are the pattern here.
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        table.setAccessibilityLabel("Segments")
        table.onReturn = { [weak self] in self?.goToSelectedSegment() }
        table.onDelete = { [weak self] in self?.removeSelectedSegment() }
        // A right-click offers what acts on the piece under it (§21.4) — the same
        // menu the strip beside the map will offer (§21.3), so one shape in both
        // places.
        table.menu = makeRowMenu()
        segmentTable = table

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        return scrollView
    }

    /// The `+`/`−` footer under the table (§21.4): a hairline, then two
    /// borderless small buttons at the left. `+` opens the Add Cut popover,
    /// anchored to the button itself; `−` removes the selected piece.
    private func makeFooter() -> NSView {
        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        let plus = NSButton(title: "", target: self, action: #selector(addCutPressed))
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Cut")
        plus.imagePosition = .imageOnly
        plus.isBordered = false
        plus.bezelStyle = .smallSquare
        plus.toolTip = "Add Cut…"
        plus.setAccessibilityLabel("Add Cut")
        plus.translatesAutoresizingMaskIntoConstraints = false
        addButton = plus

        let minus = NSButton(title: "", target: self, action: #selector(removeCutPressed))
        minus.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Segment")
        minus.imagePosition = .imageOnly
        minus.isBordered = false
        minus.bezelStyle = .smallSquare
        minus.toolTip = "Remove Segment"
        minus.setAccessibilityLabel("Remove Segment")
        minus.translatesAutoresizingMaskIntoConstraints = false
        removeButton = minus

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [plus, minus, spacer])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        // The two symbols are the same size: "−" must not read as a smaller,
        // disabled button beside a full "+". Activated only once both buttons
        // share the row as an ancestor — a constraint between views that do
        // not is an exception at layout time.
        minus.widthAnchor.constraint(equalTo: plus.widthAnchor).isActive = true

        let footer = NSStackView(views: [hairline, buttonRow])
        footer.orientation = .vertical
        footer.spacing = 4
        footer.translatesAutoresizingMaskIntoConstraints = false
        return footer
    }

    /// The dialog's own button row holds only what acts on the whole partition
    /// (§21.4): Remove All at the left, then Save All as Separate Files… and
    /// Close at the right.
    private func makeButtonRow() -> NSView {
        // Remove All, at the left of the row (§21.4): it undoes the whole
        // partition at once, so it sits apart from the per-piece `−` in the
        // footer and asks before acting.
        let removeAll = NSButton(title: "Remove All",
                                 target: self, action: #selector(removeAllPressed))
        removeAllButton = removeAll

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Save All as Separate Files… writes the partition out as its pieces
        // (§21.5) — Stage 4. In Stage 3 the command is the seam that stage lands
        // on; the button is present so the row's shape is the final one.
        let saveAll = NSButton(title: "Save All as Separate Files…",
                               target: self, action: #selector(saveAllPressed))
        // Stage 4 lands the panel and the writer; until then the button is the
        // seam and is greyed, so the row's shape is final without the act being
        // a silent no-op.
        saveAll.isEnabled = false
        saveAllButton = saveAll

        // Close, not Cancel: nothing in this form is undone by leaving it. A
        // piece edited, added or removed from the list is already so, and the
        // form is a view of the partition, not a draft of one.
        let close = NSButton(title: "Close", target: self, action: #selector(closePressed))
        close.keyEquivalent = "\u{1B}"  // Esc — at rest it closes the form.
        closeButton = close

        let row = NSStackView(views: [removeAll, spacer, saveAll, close])
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
        view.window?.makeFirstResponder(segmentTable)
        // The form opens on the first piece, the way the Go To form opens on its
        // first bookmark: `−` and Return need a selection, and the lowest piece
        // is the natural one to start on.
        if selectedSegmentIndex == nil, let first = segments.first {
            applySelection(first.index)
        }
        updateRemoveButton()
    }

    // MARK: - Content

    /// Re-reads the list from the store. Called on every change the form makes,
    /// and by the pane when the partition changes under it (§21.4) — a cut made
    /// from the dump's own context menu shows up here without the form asking.
    func reloadSegments() {
        let selected = selectedSegmentIndex
        segments = pane.segmentStore.segments
        segmentTable.reloadData()
        updateTableHeight()
        // `reloadData` clears the table's own selection, so the form puts its
        // selection back — clamped, because a piece the selection pointed at may
        // have been removed or renumbered (§20.5's lesson, applied to a list
        // whose indices move).
        applySelection(selected)
        updateRemoveButton()
    }

    /// Which piece the list has selected — the form's state, not the table's.
    ///
    /// A table view's selection is a row *number*, and for a partition a row
    /// number is the piece's index, which renumbers when a cut is added or
    /// removed. The selection means "this piece", so it is kept as one and the
    /// table is told; nothing reads it back out of the table.
    private(set) var selectedSegmentIndex: Int?

    /// Set while the form is writing its selection into the table, so the
    /// notification that comes back is not mistaken for the user's choice.
    private var isApplyingSelection = false

    /// The selected piece, or nil when the selection points at nothing.
    var selectedSegment: Segment? {
        guard let selectedSegmentIndex, segments.indices.contains(selectedSegmentIndex) else { return nil }
        return segments[selectedSegmentIndex]
    }

    /// Selects the piece at `index`, wherever the list now keeps it.
    func selectSegment(atIndex index: Int) {
        applySelection(index)
    }

    /// Points the selection at `index` and makes the table show it. An index the
    /// list no longer holds leaves nothing selected.
    private func applySelection(_ index: Int?) {
        isApplyingSelection = true
        defer {
            isApplyingSelection = false
            // The button's state is a function of the selection's: it follows
            // every change of it, wherever the change came from.
            updateRemoveButton()
        }
        guard let index, segments.indices.contains(index) else {
            selectedSegmentIndex = nil
            segmentTable.deselectAll(nil)
            return
        }
        selectedSegmentIndex = index
        segmentTable.selectRowIndexes([index], byExtendingSelection: false)
    }

    /// The user picked a row: that is the one moment the table is the authority,
    /// and the form writes down which piece it means.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = segmentTable.selectedRow
        selectedSegmentIndex = segments.indices.contains(row) ? segments[row].index : nil
        updateRemoveButton()
    }

    /// How many rows the list shows before it starts scrolling.
    static let maxVisibleRows = 10

    /// The fewest rows' worth of height the list keeps: a partition is always at
    /// least one piece, and the list needs room to be read.
    static let minVisibleRows = 3

    /// What one row of the list costs vertically. Internal so a test can measure
    /// the list in rows rather than in points.
    var rowStep: CGFloat {
        segmentTable.rowHeight + segmentTable.intercellSpacing.height
    }

    /// Sizes the list to its contents, capped at `maxVisibleRows` — beyond that
    /// it scrolls (§20.5). The window follows, so a piece removed does not leave
    /// a strip of empty table behind.
    private func updateTableHeight() {
        let rows = min(max(segments.count, Self.minVisibleRows), Self.maxVisibleRows)
        // Two points for the bezel the rows sit inside.
        tableHeight.constant = CGFloat(rows) * rowStep + 2
        fitWindowToContent()
    }

    /// Makes the window exactly as tall as the form wants to be. The width is
    /// left alone: it is the user's to widen, and the columns fill whatever it is.
    private func fitWindowToContent() {
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.height > 0 else { return }
        window.setContentSize(NSSize(width: max(window.contentLayoutRect.width, fitting.width),
                                     height: fitting.height))
    }

    /// `−` is disabled only when the pane is a single piece — there is no
    /// neighbour to merge into (§21.3). It does not depend on the selection: the
    /// form opens with the first piece selected and keeps one after every change,
    /// so there is always a piece to act on, and a button that greys out whenever
    /// the selection is cleared would read as broken. It is enabled on S0 too —
    /// removing S0 reopens the piece below at the file start.
    private func updateRemoveButton() {
        // `−` and Remove All both need a neighbour to merge into: both are
        // disabled on a single piece and enabled the moment the dump is
        // partitioned.
        let removable = pane.segmentStore.segments.count > 1
        removeButton.isEnabled = removable
        removeAllButton.isEnabled = removable
    }

    // MARK: - The row editor (§21.4)

    /// Return in the list: the selected piece's start. With nothing selected
    /// nothing happens — the same Return in the same window must never be a coin
    /// flip (§10.1). The form closes first: it is centred over the window it is
    /// about to scroll, and the row it lands on has to be visible.
    func goToSelectedSegment() {
        guard let selected = selectedSegment else { return }
        closeForm()
        onGo(selected.range.lowerBound)
    }

    @objc private func rowDoubleClicked() {
        handleDoubleClick(row: segmentTable.clickedRow)
    }

    /// A double click opens the piece's editor, wherever in the row the click
    /// lands (§20.5's gesture). Takes the row rather than reading `clickedRow`
    /// itself, because that is AppKit's to set and a test cannot.
    func handleDoubleClick(row: Int) {
        editSegment(atRow: row)
    }

    /// The list's context menu > Edit…: the row that was right-clicked, falling
    /// back to the selection, the way every context menu in the app acts on what
    /// was clicked (§10.2).
    @objc func editClickedSegment() {
        let clicked = segmentTable.clickedRow
        if clicked >= 0 {
            editSegment(atRow: clicked)
        } else if let index = selectedSegmentIndex {
            editSegment(atIndex: index)
        }
    }

    /// The popover for the piece at `row` — its offset (movable within the
    /// interval the cut bounds, or locked to 0 for S0) and its name. One editor
    /// for a piece, wherever it is edited from: a double click, the row's context
    /// menu, or the dump's own Split Here all reach the same popover (§21.3).
    private func editSegment(atRow row: Int) {
        guard row >= 0, row < segments.count else { return }
        editSegment(atIndex: segments[row].index)
    }

    private func editSegment(atIndex index: Int) {
        guard segments.indices.contains(index) else { return }
        let segment = segments[index]
        applySelection(index)

        let store = pane.segmentStore
        let validate: (UInt64) -> Bool
        if index == 0 {
            // S0 has no cut to move: the offset is the file start, locked to 0,
            // so the editor renames the piece and nothing else.
            validate = { $0 == 0 }
        } else {
            // The cut at the piece's start bounds (the previous cut, the next cut
            // or the file's end); moving inside it keeps the partition whole
            // (§21.2). The current offset is legal, so the field opens not red.
            let lower = index > 0 ? store.segments[index - 1].range.lowerBound : 0
            let upper = index + 1 < store.segments.count
                ? store.segments[index + 1].range.lowerBound
                : store.contentSize
            validate = { offset in offset > lower && offset < upper }
        }
        let from = segment.range.lowerBound
        let controller = CutEditPopoverController(
            prefillOffset: from, validate: validate,
            // The piece's current name, so editing a named piece opens with the
            // name to be changed rather than blank (§21.4).
            prefillDescription: segment.name,
            onCommit: { [weak self] offset, name in
                guard let self else { return }
                openEditPopover = nil
                // Moving the cut and renaming the piece are one act: the piece
                // that opened at `from` is the one the description names, and its
                // name travels with the boundary (§21.2).
                if offset != from {
                    pane.segmentStore.moveCut(from: from, to: offset)
                }
                pane.segmentStore.rename(index, to: name)
                // The list shows the edit at once — the same act the Go To form
                // does after its own edits (§20.5); the piece keeps its index, so
                // the reload re-points the selection at it.
                reloadSegments()
            },
            onCancel: { [weak self] in self?.openEditPopover = nil }
        )
        openEditPopover = controller
        if let editPopoverPresenter {
            editPopoverPresenter(controller)
            return
        }
        // The table is ordered by index, so the row is the index.
        controller.show(relativeTo: segmentTable.rect(ofRow: index), of: segmentTable)
    }

    // MARK: - The +/− footer (§21.4)

    /// `+`: the Add Cut popover, anchored to the button itself — the same popover
    /// the dump's Split Here opens (§21.3), so a cut made from the form and one
    /// made from the bar are the same act.
    @objc func addCutPressed() {
        let store = pane.segmentStore
        let controller = CutEditPopoverController(
            // Empty — just the "0x" — with the caret on the offset (§21.4): from
            // the form the cut has no caret to start from, the offset is the
            // thing to be typed, and an unfilled offset makes no cut.
            prefillOffset: nil, fileSize: pane.fileSize,
            isAlreadyACut: { store.cuts.contains($0) },
            focusOffset: true,
            onCommit: { [weak self] offset, name in
                guard let self else { return }
                openEditPopover = nil
                // The selected piece, by where it opens: a cut added above it
                // renumbers it, and the selection belongs to the piece, not to a
                // row number (§20.5's lesson).
                let selectedStart = selectedSegment?.range.lowerBound
                guard pane.segmentStore.addCut(at: offset) else { return }
                // The cut splits the piece at `offset`; the new piece is the one
                // that starts there, so it is the one the description names.
                if let piece = pane.segmentStore.segment(containing: offset) {
                    pane.segmentStore.rename(piece.index, to: name)
                }
                reloadSegments()
                if let selectedStart {
                    applySelection(segments.first { $0.range.lowerBound == selectedStart }?.index)
                }
            },
            onCancel: { [weak self] in self?.openEditPopover = nil }
        )
        openEditPopover = controller
        if let editPopoverPresenter {
            editPopoverPresenter(controller)
            return
        }
        controller.show(relativeTo: addButton.bounds, of: addButton)
    }

    /// `−`: removes the selected piece, merging its bytes into a neighbour that
    /// keeps its name (§21.3). The selection stays where the row was, so a run of
    /// them can be cleared without reaching for the mouse between presses.
    @objc func removeCutPressed() {
        removeSelectedSegment()
    }

    func removeSelectedSegment() {
        guard let index = selectedSegmentIndex else { return }
        removeSegment(atIndex: index)
    }

    private func removeSegment(atIndex index: Int) {
        guard segments.indices.contains(index) else { return }
        guard pane.segmentStore.removePiece(at: index) else { return }
        reloadSegments()
        // The piece the selection pointed at is gone, so the neighbour takes it —
        // the row that slid up into its place, or the new last row.
        guard !segments.isEmpty else { return }
        applySelection(segments[min(index, segments.count - 1)].index)
    }

    // MARK: - The row's context menu (§21.4)

    /// The menu a right-click on a row offers: what acts on the piece under it.
    /// The same menu the strip beside the map will offer (§21.3), so one shape in
    /// both places. Each item carries the piece it acts on in its
    /// `representedObject`, the way the offset menu carries its target.
    private func makeRowMenu() -> NSMenu {
        let menu = NSMenu()

        // Save Segment… writes one piece to a file (§21.5) — Stage 4. Present now
        // so the row's shape is the final one; its action lands with that stage.
        let save = menu.addItem(withTitle: "Save Segment…",
                                action: #selector(saveSegment(_:)), keyEquivalent: "")
        save.target = self

        // Replace Segment from File… reads one piece from a file (§21.6) — Stage
        // 6. The same arrangement: the shape now, the act with the stage.
        let replace = menu.addItem(withTitle: "Replace Segment from File…",
                                   action: #selector(replaceSegmentFromFile(_:)), keyEquivalent: "")
        replace.target = self

        menu.addItem(.separator())

        let edit = menu.addItem(withTitle: "Edit…",
                                action: #selector(editClickedSegment), keyEquivalent: "")
        edit.target = self

        let remove = menu.addItem(withTitle: "Remove Segment",
                                  action: #selector(removeClickedSegment), keyEquivalent: "")
        remove.target = self

        return menu
    }

    /// The piece a row-menu item acts on: the row that was right-clicked, falling
    /// back to the selection. Nil when there is no piece to act on.
    private func pieceForMenuAction() -> Segment? {
        let clicked = segmentTable.clickedRow
        if clicked >= 0, segments.indices.contains(clicked) {
            return segments[clicked]
        }
        return selectedSegment
    }

    /// The row's context menu > Remove Segment: the piece under the click rather
    /// than the selected one, the way every context menu in the app acts on what
    /// was clicked (§10.2).
    @objc func removeClickedSegment() {
        guard let piece = pieceForMenuAction() else { return }
        removeSegment(atIndex: piece.index)
    }

    /// Save Segment… (§21.5): writes the piece under the click to a file. Stage 4
    /// lands the panel and the writer; this is the seam it reaches.
    @objc func saveSegment(_ sender: Any?) {
        // Stage 4: the ordinary save panel, one file, on the piece the menu was
        // built for.
    }

    /// Replace Segment from File… (§21.6): reads the piece under the click from a
    /// file. Stage 6 lands the panel and the read; this is the seam it reaches.
    @objc func replaceSegmentFromFile(_ sender: Any?) {
        // Stage 6: an open panel, one file, replacing the piece's bytes.
    }

    // MARK: - The dialog's button row (§21.4)

    /// Remove All (§21.4): back to one piece — the whole file, named for it —
    /// removing every cut at once. Destructive, so it asks first; a "No" leaves
    /// the partition exactly as it was.
    @objc func removeAllPressed() {
        guard pane.segmentStore.segments.count > 1 else { return }
        let proceed = confirmRemoveAll?() ?? presentRemoveAllConfirmation()
        guard proceed else { return }
        pane.segmentStore.reset(size: pane.fileSize,
                                name: pane.document?.url.lastPathComponent ?? "")
        reloadSegments()
    }

    /// The confirmation for Remove All, as a real alert.
    private func presentRemoveAllConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove All Segments?"
        alert.informativeText = "This removes every cut and leaves the file as a single segment."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Save All as Separate Files… (§21.5): writes the whole partition out as its
    /// pieces. Stage 4 lands the directory panel, the preview and the writer; this
    /// is the seam it reaches.
    @objc func saveAllPressed() {
        // Stage 4: a directory chosen in directory mode, a base name pre-filled
        // from the document, a preview of what will be written.
    }

    @objc private func closePressed() {
        closeForm()
    }

    private func closeForm() {
        if let dismissForm {
            dismissForm()
            return
        }
        dismiss(self)
    }

    // MARK: - Menu validation (§21.4)

    /// The row menu and the button row enable themselves by what they can act on:
    /// Save Segment…, Replace Segment from File… and Save All as Separate Files…
    /// are Stage 4/6, so they are greyed until those stages land — the shape is
    /// the final one, the acts are not yet. Remove Segment needs a piece with a
    /// neighbour to merge into.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveSegment(_:)), #selector(replaceSegmentFromFile(_:)),
             #selector(saveAllPressed):
            return false   // Stage 4/6
        case #selector(removeClickedSegment):
            return pieceForMenuAction() != nil && pane.segmentStore.segments.count > 1
        default:
            return true
        }
    }

    // MARK: - Escape's two levels (§10.1)

    /// Escape's first level: closes an open piece editor instead of the form,
    /// leaving the piece as it was. Returns whether there was one to close — when
    /// there was not, Escape falls through to the Close button and closes the form.
    @discardableResult
    func cancelEdit() -> Bool {
        guard let popover = openEditPopover else { return false }
        openEditPopover = nil
        popover.cancel()
        return true
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        segments.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < segments.count else { return nil }
        let segment = segments[row]
        switch tableColumn.identifier {
        case ColumnID.label:
            let cell = makeCell(tableColumn)
            cell.restingTextColor = .labelColor
            cell.textField?.font = .systemFont(ofSize: 12, weight: .semibold)
            cell.textField?.stringValue = "S\(segment.index)"
            return cell
        case ColumnID.start:
            let cell = makeCell(tableColumn)
            cell.restingTextColor = .labelColor
            cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            // The dump's own address shape (§6): bare digits, no "0x" — a whole
            // column of addresses does not need each one announcing that it is hex.
            cell.textField?.stringValue = Bookmark.bareAddressLabel(segment.range.lowerBound)
            return cell
        case ColumnID.size:
            let cell = makeCell(tableColumn)
            cell.restingTextColor = .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.stringValue = FilePaneView.friendlySize(UInt64(segment.range.count))
            return cell
        case ColumnID.name:
            let cell = makeCell(tableColumn)
            cell.restingTextColor = .labelColor
            cell.textField?.font = .systemFont(ofSize: 12)
            // An unnamed piece shows its label in the Label column, so the Name
            // column is simply empty — never blank in the way that hides the
            // piece, because the label beside it names it (§21.1).
            cell.textField?.stringValue = segment.name
            return cell
        default:
            return nil
        }
    }

    private func makeCell(_ column: NSTableColumn) -> SegmentCellView {
        // A fresh cell, not a dequeued one: the list holds at most a dozen
        // pieces, so reuse buys nothing, and a cell taken out of the table's
        // registry would be one the table is showing — asking for row 3's cell
        // would repaint row 1's.
        SegmentCellView(identifier: column.identifier)
    }
}

// MARK: - Widgets

/// The form's root view: it sees Escape before the Close button's key equivalent
/// does, which is what makes Escape cancel a piece edit first and close the form
/// second (§10.1).
private final class SegmentsFormView: NSView {
    /// Returns true when it consumed the Escape (a piece edit was cancelled).
    var escapeHandler: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\u{1B}", escapeHandler?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The segment list. Return and `⌫` are the list's own keys (§21.4): Return goes
/// to the selected piece's start, and `⌫` removes it.
private final class SegmentTableView: NSTableView {
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

/// One cell of the list: a label that fills the cell. A piece is edited in its
/// own popover (§21.4), so nothing in the list takes the keyboard and every click
/// in it means one thing — select the row, or activate it on a double click.
private final class SegmentCellView: NSTableCellView {
    /// The label's inset from each side of the cell.
    static let labelInset: CGFloat = 4

    /// The colour the label has on paper. On a selected row every cell switches
    /// to the colour for text on a selection instead — a colour set by hand has to
    /// follow the style by hand (§20.5).
    var restingTextColor: NSColor = .labelColor {
        didSet { applyBackgroundStyle() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyBackgroundStyle() }
    }

    private func applyBackgroundStyle() {
        let selected = backgroundStyle == .emphasized
        textField?.textColor = selected ? .alternateSelectedControlTextColor : restingTextColor
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

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
