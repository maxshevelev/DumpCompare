import ALSplitView
import AppKit
import ToolModuleKit
import UEFIImage
import UEFITool

/// The panel: the tree above, what the node in focus is below.
///
/// It decides nothing. The tree is the parse's, the detail is built and tested
/// in the pure target, and the one zone is the presenter's — so what is on
/// screen comes from one `show(...)` over values the panel only lays out.
@MainActor final class UEFIToolViewController: NSViewController {
    /// The node the user picked in the tree, or nil for nothing.
    var onSelect: ((NodeID?) -> Void)?
    /// The title was clicked. Only ever fired when the summary stands for a
    /// node that has no row of its own.
    var onSelectTop: (() -> Void)?
    /// The title-row reveal button was clicked: show the node under the caret
    /// in the dump.
    var onRevealAtCaret: (() -> Void)?
    /// A flagged node's Fix Checksum menu item was chosen.
    var onFixChecksum: ((NodeID) -> Void)?

    private var image: UEFIImage?
    /// The tree as it is shown: the outline's top level and the root node the
    /// summary stands for, decided in the pure target. Kept from one show to
    /// the next so the data source reads the same top level the last show laid
    /// out.
    private var presented = UEFITreeDisplay.PresentedImage(title: nil, rows: [])
    private var focus: NodeID?
    /// The detail on screen, kept so the rows can be rebuilt at a new type
    /// size without waiting for the next parse — a zoom is not a re-read.
    private var detailShown: UEFINodeDetail = .empty
    private var detailSubject = ""
    /// The GUID catalogue the names are read from. The session owns it — it
    /// downloads a fresh one in the background and passes it in on every show —
    /// so the tree shows the GUIDs themselves at first paint and the catalogue
    /// names once the download lands.
    private var catalogue: GuidsCatalogue = .empty
    /// True while the tree is being loaded from the model — a selection the
    /// code made is not news, and without this the panel selects, publishes,
    /// re-shows and selects again until the stack runs out.
    private var isShowingState = false
    /// The nodes whose checksums the last parse found wrong, keyed by node id.
    /// The red triangle before a name and the Fix Checksum menu item both ask
    /// it.
    private var badChecksums: [NodeID: Set<UEFIChecksumField>] = [:]
    /// Whether the file is open for writing. Without it the Fix Checksum menu
    /// item stands down — the module would refuse anyway, but a greyed item
    /// says so before the click.
    private var canWrite = false

    private let summaryLabel = NSTextField(labelWithString: "")
    /// The title row's right-hand button: reveal in the tree the node under
    /// the caret in the dump. Same glyph as the toolbar's Go To, because it is
    /// the same act — go where the caret points — pointed at the tree instead
    /// of the dump.
    private let revealButton = NSButton()
    private let outline = UEFIOutlineView()
    private let outlineScroll = NSScrollView()
    private let detail = ToolDetailScroll()
    private let splitter = ALSplitView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let bottomRow = NSStackView()
    /// The panel draws at the app's zoom (`ToolPanelFont`); this is what tells
    /// it the zoom moved.
    private var zoomObserver: NSObjectProtocol?

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let type = NSUserInterfaceItemIdentifier("type")
        static let subtype = NSUserInterfaceItemIdentifier("subtype")
    }

    /// What each column was laid out at — a width for text at
    /// `ToolPanelFont.designSize`, scaled from there to the size the zoom is
    /// at.
    ///
    /// Type and Subtype are as wide as the words they hold and no wider: what
    /// they say is one short word on almost every row ("Volume", "Section",
    /// "Driver", "Free space"), and the few long ones — "FlashDeviceMap store"
    /// — are not worth two columns of empty space on every other row. Name is
    /// the column with something to say, so it gets the rest: the widest thing
    /// in the tree is a GUID or a catalogue name, and a truncated one is the
    /// row the reader came for.
    ///
    /// Both are as narrow as they can be and still hold the longest word a
    /// normal row puts in them — "Free space" and "Empty (FFh)", measured at
    /// the design size with the cell's own 2-point insets — so taking another
    /// few points off either would start truncating the rows that are there on
    /// every dump.
    private static let nameWidth: CGFloat = 319
    private static let typeWidth: CGFloat = 62
    private static let subtypeWidth: CGFloat = 69

    /// The size the widths on screen were scaled for. A zoom moves them by
    /// what has changed since, so a column the user dragged keeps the width
    /// they gave it rather than snapping back to the design's.
    private var columnWidthSize = ToolPanelFont.designSize

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        view.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        // The title names the image, not a row: the one root the tree folded
        // into it is selected by a click as its row would. Without a root to
        // fold, the title is not clickable — the module guards.
        summaryLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(summaryClicked))
        )

        // Borderless and quiet, like every other icon control in a panel
        // header: the glyph carries the meaning, not a bezel.
        revealButton.image = NSImage(
            systemSymbolName: "dot.scope",
            accessibilityDescription: "Reveal node at caret"
        )
        revealButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        revealButton.isBordered = false
        revealButton.imagePosition = .imageOnly
        revealButton.contentTintColor = .secondaryLabelColor
        revealButton.toolTip = "Show the node under the caret in the tree"
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        configureOutline()

        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.documentView = outline

        // Top: the tree. Bottom: the detail. The divider is the user's to
        // move. `ALSplitView` places its panes by frame from its own bounds, so
        // the third the detail starts with is a policy rather than a position
        // measured off a view that has not been laid out yet.
        splitter.isVertical = false
        splitter.dividerThickness = 1
        splitter.translatesAutoresizingMaskIntoConstraints = false
        splitter.addPane(outlineScroll)
        splitter.addPane(detail)
        splitter.setPaneLayout(.fill, at: 0)
        splitter.setPaneLayout(.proportional(1.0 / 3), at: 1)

        noticeLabel.font = ToolPanelFont.body()
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        view.addSubview(revealButton)
        view.addSubview(splitter)
        view.addSubview(bottomRow)

        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            // The button owns the title row's right end; a long image name
            // truncates before it rather than running under it.
            summaryLabel.trailingAnchor.constraint(
                equalTo: revealButton.leadingAnchor, constant: -6
            ),

            // A small square: the glyph is 12 point, and a button the size of
            // its image alone would be a needlessly thin thing to hit.
            revealButton.widthAnchor.constraint(equalToConstant: 18),
            revealButton.heightAnchor.constraint(equalToConstant: 18),
            revealButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            revealButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            splitter.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            splitter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            splitter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            splitter.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

            bottomRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottomRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            barWidth
        ])

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.applyPanelFont()
        }
    }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    /// Re-reads the panel's type size and puts everything on screen at it: the
    /// two lines around the splitter, the tree's rows and header, and the
    /// detail's own rows — which are views built per field, so they have to be
    /// rebuilt rather than restyled.
    private func applyPanelFont() {
        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        noticeLabel.font = ToolPanelFont.body()
        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
        outline.reloadData()
        renderDetail(detailShown, subject: detailSubject)
    }

    /// Moves the columns to the size on screen — the widths grow and shrink
    /// with the type, since a column that does not is a column whose text no
    /// longer fits it.
    private func applyColumnWidths() {
        let size = ToolPanelFont.size
        guard size != columnWidthSize else { return }
        ToolPanelTable.scaleColumnWidths(of: outline, by: size / columnWidthSize)
        columnWidthSize = size
    }

    private func configureOutline() {
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        // The column order is the design's, not a drag target.
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self
        // A right-click is answered here rather than with a `menu` assigned to
        // the view: a plain menu pops over a clean row too, and this panel's
        // whole contextual menu is the one item a flagged row earns.
        outline.onContextMenu = { [weak self] event in self?.contextMenu(for: event) }
        // A click on the row that is already the selection publishes its zone,
        // exactly as a click that moved the selection would — the outline only
        // reports that second kind itself (see `UEFIOutlineView`).
        outline.onRowReclick = { [weak self] row in self?.chooseNode(atRow: row) }

        let name = NSTableColumn(identifier: Column.name)
        name.title = "Name"
        name.width = Self.nameWidth
        // Draggable, and the one column that also takes the slack when the
        // panel is resized. Without `.userResizingMask` a column cannot be
        // dragged at all, whatever `allowsColumnResizing` says.
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(name)
        outline.outlineTableColumn = name

        let type = NSTableColumn(identifier: Column.type)
        type.title = "Type"
        type.width = Self.typeWidth
        type.resizingMask = .userResizingMask
        outline.addTableColumn(type)

        let subtype = NSTableColumn(identifier: Column.subtype)
        subtype.title = "Subtype"
        subtype.width = Self.subtypeWidth
        subtype.resizingMask = .userResizingMask
        outline.addTableColumn(subtype)

        // The rows, the header and the widths — laid out just above for text at
        // `ToolPanelFont.designSize` — follow the app's zoom, so this comes
        // after the columns exist rather than with the rest of the tree's
        // setup.
        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
    }

    // MARK: - A parse's progress

    func showBusy() {
        guard progressBar.superview == nil else { return }
        bottomRow.addArrangedSubview(progressBar)
    }

    /// How far the parse has got, a fraction in 0…1. Reported from a detached
    /// task; the session hops it here.
    func updateProgress(_ fraction: Double) {
        progressBar.doubleValue = fraction
    }

    func endBusy() {
        guard progressBar.superview != nil else { return }
        bottomRow.removeArrangedSubview(progressBar)
        progressBar.removeFromSuperview()
    }

    /// A line under the splitter — what happened, or what to do next.
    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? .systemRed : .secondaryLabelColor
    }

    /// Everything the panel shows, in one call.
    func show(
        image: UEFIImage?,
        focus: NodeID?,
        detail: UEFINodeDetail,
        catalogue: GuidsCatalogue,
        badChecksums: [NodeID: Set<UEFIChecksumField>],
        canWrite: Bool
    ) {
        self.image = image
        self.focus = focus
        self.catalogue = catalogue
        self.badChecksums = badChecksums
        self.canWrite = canWrite
        // Without a parse there is nothing to reveal the caret into.
        revealButton.isEnabled = image != nil
        isShowingState = true
        defer { isShowingState = false }

        presented = image.map(UEFITreeDisplay.present)
            ?? UEFITreeDisplay.PresentedImage(title: nil, rows: [])
        summaryLabel.stringValue = UEFITreeDisplay.summary(of: image)
        updateSummaryEmphasis()
        outline.reloadData()
        renderDetail(detail, subject: focus?.description ?? "")

        // The focus is the root the tree folded into the title: it has no row
        // to select, and the title already stands for it in accent colour, so
        // there is nothing to do to the tree.
        if presented.title != nil, focus == presented.title?.id {
            outline.deselectAll(nil)
            return
        }

        guard let image, let focus, let node = image.node(focus) else {
            outline.deselectAll(nil)
            return
        }
        expandPath(to: focus)
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.scrollRowToVisible(row)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// The title reads as clickable only when it stands for a folded root, and
    /// reads as *selected* when that root is the focus — the accent colour is
    /// the row the root would have got.
    private func updateSummaryEmphasis() {
        guard presented.title != nil else {
            summaryLabel.toolTip = nil
            summaryLabel.textColor = .labelColor
            return
        }
        summaryLabel.toolTip = "Show the whole image in the dump"
        summaryLabel.textColor = focus == presented.title?.id ? .controlAccentColor : .labelColor
    }

    /// Expands each ancestor of the node so its row is on screen. An ancestor
    /// that was folded into the title has no row — its children are already the
    /// top of the tree — so only ancestors that are on screen are expanded.
    private func expandPath(to nodeID: NodeID) {
        guard !nodeID.path.isEmpty else { return }
        var nodes = image?.roots ?? []
        for (step, index) in nodeID.path.enumerated() {
            guard index < nodes.count else { return }
            let node = nodes[index]
            if step < nodeID.path.count - 1, !node.children.isEmpty,
               outline.row(forItem: node) >= 0 {
                outline.expandItem(node)
            }
            nodes = node.children
        }
    }

    /// Rebuilds the detail list from the fields the pure target decided.
    private func renderDetail(_ node: UEFINodeDetail, subject: String) {
        detailShown = node
        detailSubject = subject
        guard !node.fields.isEmpty else {
            detail.showPlaceholder(node.title.isEmpty
                ? "Select a node to see what it is."
                : node.title)
            return
        }
        detail.prepareForRows(subject: subject)

        if !node.title.isEmpty {
            let title = NSTextField(labelWithString: node.title)
            title.font = ToolPanelFont.title()
            title.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(title)
        }

        for field in node.fields {
            let label = NSTextField(labelWithString: field.label)
            label.font = ToolPanelFont.body()
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(
                equalToConstant: ToolPanelFont.detailLabelWidth
            ).isActive = true

            let value = NSTextField(labelWithString: field.value)
            value.font = field.value.hasPrefix("0x")
                ? ToolPanelFont.monospacedDigits()
                : ToolPanelFont.body()
            // A checksum that does not check out is the one thing in the detail
            // worth colouring red: it is what the Fix Checksum item would write.
            if field.isProblem {
                value.textColor = .systemRed
            }
            // Selectable, not a dead label: a bench copies an offset or a GUID
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

    /// The title names the image, not a row; the module decides what the fold
    /// stands for and does nothing when there is nothing to select.
    @objc private func summaryClicked() {
        onSelectTop?()
    }

    /// The reveal button: show the node the caret in the dump is in. The
    /// module reads the caret and decides; this is only the click.
    @objc private func revealClicked() {
        onRevealAtCaret?()
    }
}

extension UEFIToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard !presented.rows.isEmpty else { return 0 }
        guard let node = item as? UEFINode else { return presented.rows.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? UEFINode else { return presented.rows[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? UEFINode)?.children.isEmpty == false
    }

    /// A row's cell, view-based and with its text centred.
    ///
    /// Not `objectValueFor`: that is the cell-based path, and an
    /// `NSTextFieldCell` draws its text against the TOP of the row rather than
    /// down the middle of it, which reads as every row in the tree sitting too
    /// high. Every other table in the project is view-based for the same
    /// reason.
    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? UEFINode, let identifier = tableColumn?.identifier
        else { return nil }
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: identifier,
                                       warning: identifier == Column.name)
        cell.textField?.stringValue = text(for: node, in: identifier)
        // Set per row, not once when the cell is made: a reused cell carries
        // the font it was made with, and the zoom moves under it.
        cell.textField?.font = ToolPanelFont.body()
        // The Name column wears the warning: a node whose checksums do not
        // check out, with what is wrong under the pointer.
        if identifier == Column.name {
            let bad = badChecksums[node.id] ?? []
            ToolPanelTable.setWarning(!bad.isEmpty, on: cell,
                                      explanation: bad.isEmpty ? nil : warningText(for: bad))
        }
        return cell
    }

    /// What the pointer reads on a flagged row's triangle: which of the node's
    /// checksums is wrong, since "invalid" alone leaves the reader to open the
    /// detail to find out.
    private func warningText(for fields: Set<UEFIChecksumField>) -> String {
        let names = fields.map(\.label).sorted()
        return names.count == 1
            ? "Invalid \(names[0]) checksum"
            : "Invalid checksums: \(names.joined(separator: ", "))"
    }

    private func text(
        for node: UEFINode, in column: NSUserInterfaceItemIdentifier
    ) -> String {
        switch column {
        case Column.type:
            return UEFITreeDisplay.typeText(for: node)
        case Column.subtype:
            return UEFITreeDisplay.subtypeText(for: node)
        default:
            return UEFITreeDisplay.name(for: node, catalogue: catalogue)
        }
    }

    /// The menu a right-click asks for: one Fix Checksum item on the node under
    /// the pointer when its checksum is wrong, and nothing at all on any other
    /// row. The item greys out on a read-only file rather than vanishing, so
    /// the menu still says what fixing would do.
    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: point)
        guard row >= 0,
              let node = outline.item(atRow: row) as? UEFINode,
              !(badChecksums[node.id]?.isEmpty ?? true)
        else { return nil }

        let item = NSMenuItem(
            title: "Fix Checksum",
            action: #selector(fixChecksumClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = canWrite
        // The node the click was on, read back when the item fires — by id, not
        // by node: a parse between the click and the action re-reads the tree,
        // and the id is what still points at the node.
        item.representedObject = node.id
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        return menu
    }

    @objc private func fixChecksumClicked(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? NodeID else { return }
        onFixChecksum?(nodeID)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        chooseNode(atRow: outline.selectedRow)
    }

    /// A row was chosen — by a selection that moved, or by a click on the row
    /// that was already the selection. Both publish the row's zone; the outline
    /// only reports the second kind itself (see `UEFIOutlineView`).
    private func chooseNode(atRow row: Int) {
        let node = row >= 0 ? outline.item(atRow: row) as? UEFINode : nil
        onSelect?(node?.id)
    }
}

/// The tree, with two behaviours past NSOutlineView's.
///
/// It answers a right-click itself: a plain outline given a `menu` pops it
/// over every row — a flagged node's Fix Checksum item and a clean row's empty
/// menu alike — but AppKit asks `menu(for:)` first and shows nothing when it
/// answers nil, which is how a clean row gets no popup at all. The controller
/// decides per row.
///
/// And it reports a plain click on the row that is already the one selection.
/// AppKit treats that click as a change of nothing and posts no
/// `selectionDidChange`, so it would answer nothing — though a click that moved
/// the selection would publish the row's zone. A row the reveal chose sits in
/// exactly that state: shown and selected, but deliberately not published (the
/// dump does not move). A click on it is how the user asks for the zone, so it
/// chooses the row afresh. The disclosure triangle, a double click and a
/// modifier click keep their own meanings.
private final class UEFIOutlineView: NSOutlineView {
    /// What a right-click on this outline offers, decided on the main actor.
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    /// A plain click landed on the row that was already selected.
    var onRowReclick: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedItem = clickedRow >= 0 ? item(atRow: clickedRow) : nil
        let wasSelected = clickedRow >= 0 && selectedRowIndexes.contains(clickedRow)
        let wasExpanded = clickedItem.map { isItemExpanded($0) }
        super.mouseDown(with: event)

        // A click that moved the selection needs no help — the outline reports
        // it. Only the click on the row that was already selected is answered
        // here (see the class doc).
        guard wasSelected, let clickedItem, let wasExpanded else { return }
        guard clickedRow == selectedRow,
              event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              // Not the disclosure triangle: that click folds or unfolds, and
              // keeps meaning what it always meant.
              !frameOfOutlineCell(atRow: clickedRow).insetBy(dx: -2, dy: -2).contains(point),
              isItemExpanded(clickedItem) == wasExpanded
        else { return }
        onRowReclick?(clickedRow)
    }
}
