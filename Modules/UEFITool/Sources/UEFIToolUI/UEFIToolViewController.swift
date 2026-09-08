import ALSplitView
import AppKit
import ToolModuleKit
import UEFIImage
import UEFITool

/// The panel: the tree above, what the node in focus is below.
///
/// It decides nothing. The tree is the parse's, the detail is built and tested
/// in the pure target, and the one zone is the presenter's — so what is on
/// screen comes from one `show(image:focus:detail:)` over values the panel only
/// lays out.
@MainActor final class UEFIToolViewController: NSViewController {
    /// The node the user picked in the tree, or nil for nothing.
    var onSelect: ((NodeID?) -> Void)?

    private var image: UEFIImage?
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

    private let summaryLabel = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
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
        view.addSubview(splitter)
        view.addSubview(bottomRow)

        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

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
    func show(image: UEFIImage?, focus: NodeID?, detail: UEFINodeDetail, catalogue: GuidsCatalogue) {
        self.image = image
        self.focus = focus
        self.catalogue = catalogue
        isShowingState = true
        defer { isShowingState = false }

        summaryLabel.stringValue = Self.summary(of: image)
        outline.reloadData()
        renderDetail(detail, subject: focus?.description ?? "")

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

    /// What the tree is, in one line: what the image is, and how much of it the
    /// tree accounts for. The image type leads — a capsule, a BIOS region, a
    /// volume — because that is what the bench opened the file to find out.
    private static func summary(of image: UEFIImage?) -> String {
        guard let image else { return "" }
        let nodes = image.allNodes
        let count = nodes.count
        guard count > 0 else { return "Nothing here looks like a firmware image." }
        let volumes = nodes.filter { $0.kind == .volume }.count
        let files = nodes.filter { $0.kind == .file }.count
        var parts: [String] = []
        let imageType = UEFITreeDisplay.imageType(of: image)
        if !imageType.isEmpty { parts.append(imageType) }
        parts.append("\(count) " + (count == 1 ? "node" : "nodes"))
        if volumes > 0 { parts.append("\(volumes) volume" + (volumes == 1 ? "" : "s")) }
        if files > 0 { parts.append("\(files) file" + (files == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
    }

    /// Expands each ancestor of the node so its row is on screen.
    private func expandPath(to nodeID: NodeID) {
        guard !nodeID.path.isEmpty else { return }
        var nodes = image?.roots ?? []
        for (step, index) in nodeID.path.enumerated() {
            guard index < nodes.count else { return }
            let node = nodes[index]
            if step < nodeID.path.count - 1 {
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
}

extension UEFIToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let image else { return 0 }
        guard let node = item as? UEFINode else { return image.roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let image else { return UEFINode(kind: .padding, name: "", range: 0..<0) }
        guard let node = item as? UEFINode else { return image.roots[index] }
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
            as? NSTableCellView ?? Self.makeCell(identifier: identifier)
        cell.textField?.stringValue = text(for: node, in: identifier)
        // Set per row, not once when the cell is made: a reused cell carries
        // the font it was made with, and the zoom moves under it.
        cell.textField?.font = ToolPanelFont.body()
        return cell
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

    private static func makeCell(
        identifier: NSUserInterfaceItemIdentifier
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = ToolPanelFont.body()
        field.lineBreakMode = .byTruncatingTail
        field.isBordered = false
        field.drawsBackground = false
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        let row = outline.selectedRow
        let node = row >= 0 ? outline.item(atRow: row) as? UEFINode : nil
        onSelect?(node?.id)
    }
}
