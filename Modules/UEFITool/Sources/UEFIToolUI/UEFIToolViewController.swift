import ALSplitView
import AppKit
import ToolModuleKit
import UEFIImage
import UEFITool

/// The panel: the tree above, what the node in focus is below.
///
/// It decides nothing. The rows come from the pane's shared tree, the detail is
/// built and tested in the pure target, and the one zone is the presenter's —
/// so what is on screen comes from one `show(...)` over values the panel only
/// lays out. The one thing it does on its own is ask the tree for a branch when
/// a row is opened, and put a "Loading…" row there until it arrives.
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
    /// A row was opened or shut. What is open belongs to the file rather than
    /// to this panel, so the session writes it through to where the tree
    /// lives (`UEFITreeProviding.setOpenUEFIRows`).
    var onOpenRowsChanged: (() -> Void)?

    /// The tree as one value, for everything that reads it rather than walks
    /// it: the summary line, the title fold, the detail panel. It is the
    /// pane's tree as materialized so far — the same nodes `tree` hands out,
    /// in a shape the pure target already knows how to read.
    private var image: UEFIImage?
    /// The pane's shared lazy tree — what the outline's rows and children come
    /// from, and what materializes a branch when a row is opened. Nil only
    /// before the first `show`, or when there is no file to read.
    private var tree: LazyUEFITree?
    /// True while the tree's top level is still being worked out — a signature
    /// scan of a chip dump with no descriptor, which is the one thing about
    /// opening an image that is never instant. The outline shows one
    /// "Loading…" row for the duration.
    private var isBuilding = false
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
    /// One row object per path, so the outline is handed the same item for the
    /// same node every time (`UEFITreeRow`). Emptied when the tree is replaced
    /// or cut back, which is also when the outline's own expansion state stops
    /// meaning anything.
    private var rows: [NodeID: UEFITreeRow] = [:]
    /// The "Loading…" rows, one per branch being read, kept apart from the
    /// rows above so the two never hand out the same object for the same path.
    private var loadingRows: [NodeID: UEFITreeRow] = [:]
    /// Branches the reader has asked for and the tree has not answered yet,
    /// with the moment we asked. The row stays *shut* while one is in flight:
    /// opening it onto a "Loading…" row that is replaced a few milliseconds
    /// later is two animations over the same rows, and what that looks like is
    /// the whole table rippling.
    private var opening: [NodeID: Date] = [:]
    /// The branches slow enough to have earned a "Loading…" row.
    private var showingPlaceholder: Set<NodeID> = []
    /// How long a branch may take before the reader is told it is being read.
    /// Under this, the row simply opens when it is ready and no placeholder is
    /// ever drawn — which is the common case and the one that used to ripple.
    private static var placeholderDelay: TimeInterval { UEFIToolModule.loadingRowDelay }
    /// How long a row takes to open. Ours to choose, because every expansion
    /// here is the panel's own (`outlineView(_:shouldExpandItem:)` refuses the
    /// click and the panel opens the row when there is something in it), and
    /// it is the window during which nothing else may touch the table.
    private static let expandAnimation: TimeInterval = 0.25

    /// Changes to the table, run one at a time.
    ///
    /// A row opening is an animation, and so is a "Loading…" row giving way to
    /// what was under it. A change that lands on rows another is still moving
    /// leaves the outline animating towards a layout that no longer exists,
    /// and what that looks like is a wave running through the whole table. So
    /// they queue: each runs inside its own animation group, and the next
    /// starts when that group is done.
    private var queued: [(animated: Bool, body: @MainActor () -> Void)] = []
    private var isAnimating = false
    /// Whether a refresh is already queued, and whether any of the shows it
    /// stands for moved rows. One refresh serves however many shows land while
    /// an animation runs.
    private var queuedRefresh: Bool?

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
        progressBar.isIndeterminate = true
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

    /// Something is being read. Indeterminate on purpose: what the panel waits
    /// for now is a branch of the tree or a node's checksum, and neither
    /// reports a fraction of anything the reader would recognise.
    func showBusy() {
        guard progressBar.superview == nil else { return }
        bottomRow.addArrangedSubview(progressBar)
        progressBar.startAnimation(nil)
    }

    func endBusy() {
        guard progressBar.superview != nil else { return }
        progressBar.stopAnimation(nil)
        bottomRow.removeArrangedSubview(progressBar)
        progressBar.removeFromSuperview()
    }

    /// A line under the splitter — what happened, or what to do next.
    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? .systemRed : .secondaryLabelColor
    }

    /// Everything the panel shows, in one call. `tree` is the pane's shared
    /// lazy tree — what the outline's rows are materialized from; `image` is
    /// the same tree as one value, which is what the summary line, the title
    /// fold and the detail panel read.
    ///
    /// `rowsChanged` says whether the *set* of rows can have moved. A branch
    /// arriving is not one of these — the panel opens that row itself, in one
    /// animation — so the common shows (a checksum pass, the GUID catalogue, a
    /// selection) only re-render what is already there.
    func show(
        image: UEFIImage?,
        tree: LazyUEFITree?,
        focus: NodeID?,
        detail: UEFINodeDetail,
        catalogue: GuidsCatalogue,
        badChecksums: [NodeID: Set<UEFIChecksumField>],
        canWrite: Bool,
        isBuilding: Bool,
        rowsChanged: Bool
    ) {
        // A different tree is a different file: the rows standing for the old
        // one's paths mean nothing now, and the outline's memory of which of
        // them were open means nothing either.
        if tree !== self.tree {
            rows.removeAll()
            loadingRows.removeAll()
        }
        self.image = image
        self.tree = tree
        self.focus = focus
        self.catalogue = catalogue
        self.badChecksums = badChecksums
        self.canWrite = canWrite
        self.isBuilding = isBuilding
        // Without a tree there is nothing to reveal the caret into.
        revealButton.isEnabled = image != nil
        isShowingState = true
        defer { isShowingState = false }

        presented = image.map(UEFITreeDisplay.present)
            ?? UEFITreeDisplay.PresentedImage(title: nil, rows: [])
        summaryLabel.stringValue = UEFITreeDisplay.summary(of: image)
        updateSummaryEmphasis()
        renderDetail(detail, subject: focus?.description ?? "")
        queueRefresh(rowsChanged: rowsChanged)
    }

    /// The table half of a show, queued behind whatever the outline is
    /// animating. Everything it reads is already stored above, so a refresh
    /// that runs a moment later draws the latest state rather than the state
    /// its own show was called with — which is why several shows arriving
    /// during one animation collapse into one refresh.
    private func queueRefresh(rowsChanged: Bool) {
        if let already = queuedRefresh {
            queuedRefresh = already || rowsChanged
            return
        }
        queuedRefresh = rowsChanged
        enqueue(animated: false) { [weak self] in
            guard let self else { return }
            let rowsChanged = self.queuedRefresh ?? false
            self.queuedRefresh = nil
            self.refreshTheOutline(rowsChanged: rowsChanged)
        }
    }

    private func refreshTheOutline(rowsChanged: Bool) {
        isShowingState = true
        defer { isShowingState = false }

        if rowsChanged {
            outline.reloadData()
        } else {
            // Only what the rows *say* changed — a checksum pass landing, the
            // GUID catalogue arriving, a new selection. Re-rendering the cells
            // leaves the row set alone.
            outline.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns)
            )
        }

        // The focus is the root the tree folded into the title: it has no row
        // to select, and the title already stands for it in accent colour, so
        // there is nothing to do to the tree.
        if presented.title != nil, focus == presented.title?.id {
            outline.deselectAll(nil)
            return
        }

        guard let focus, let tree, tree.node(focus) != nil else {
            outline.deselectAll(nil)
            return
        }
        reveal(focus, in: tree)
    }

    // MARK: - One change to the table at a time

    private func enqueue(animated: Bool, _ body: @escaping @MainActor () -> Void) {
        queued.append((animated, body))
        runTheNextChange()
    }

    private func runTheNextChange() {
        guard !isAnimating, !queued.isEmpty else { return }
        let change = queued.removeFirst()
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = change.animated ? Self.expandAnimation : 0
            change.body()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAnimating = false
                self.runTheNextChange()
            }
        }
    }

    /// Selects and scrolls to `nodeID`'s row, expanding every ancestor first —
    /// through the tree (materializing a closed volume or region) and then in
    /// the outline itself. An ancestor's expansion finishes later than this
    /// call; either way, the selection lands once the whole path is as
    /// expanded as it can be.
    private func reveal(_ nodeID: NodeID, in tree: LazyUEFITree) {
        expandAncestors(of: nodeID, in: tree) { [weak self] in
            guard let self, tree.node(nodeID) != nil else { return }
            // The selection is the panel's own doing, not the reader's, so it
            // must not read back as a click — that would publish a zone and
            // scroll the dump away from the byte a reveal was asked about.
            self.isShowingState = true
            defer { self.isShowingState = false }
            self.selectAndScroll(to: nodeID)
        }
    }

    private func selectAndScroll(to nodeID: NodeID) {
        let row = outline.row(forItem: row(nodeID))
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The rows that are open, by the place in the tree each stands for.
    var openRows: Set<NodeID> {
        var open: Set<NodeID> = []
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row), outline.isItemExpanded(item),
                  let treeRow = item as? UEFITreeRow, !treeRow.isLoading
            else { continue }
            open.insert(treeRow.id)
        }
        return open
    }

    /// Puts back the rows that were open when the reader last looked at this
    /// file, outermost first — a row cannot be opened before the row holding
    /// it is, and a branch that has been dropped since is read again on the
    /// way. Each waits for the one before it, so every row exists by the time
    /// its own turn comes.
    func restoreOpenRows(_ rows: Set<NodeID>) {
        openInTurn(rows.sorted { $0.path.count < $1.path.count }, from: 0)
    }

    private func openInTurn(_ rows: [NodeID], from index: Int) {
        guard index < rows.count else { return }
        let id = rows[index]
        guard let tree, let node = tree.node(id) else {
            openInTurn(rows, from: index + 1)
            return
        }
        guard node.children.isEmpty, node.isExpandable else {
            expandRow(id) { [weak self] in self?.openInTurn(rows, from: index + 1) }
            return
        }
        tree.expand(id) { [weak self] _ in
            guard let self else { return }
            self.expandRow(id) { [weak self] in self?.openInTurn(rows, from: index + 1) }
        }
    }

    /// Opens `id`'s row, when it has one — animated, and behind whatever the
    /// outline is already animating.
    ///
    /// Through the outline's own item, resolved when the change runs rather
    /// than when it is queued: an outline recognises only the object it is
    /// itself holding, and by the time this runs the rows may have moved.
    private func expandRow(_ id: NodeID, then done: (@MainActor () -> Void)? = nil) {
        enqueue(animated: true) { [weak self] in
            guard let self else { return }
            if let item = self.outlineItem(for: id) {
                self.outline.animator().expandItem(item)
            }
            // Inside the same step, so whatever follows an opening sees the
            // rows it opened. A caller that runs when the opening is merely
            // *queued* is a caller looking at a table that has not changed yet
            // — which is how a reveal came to open the tree and select nothing.
            done?()
        }
    }

    /// Expands, in order, every ancestor of `nodeID` that the tree has not
    /// already expanded — a volume synchronously, a region once its
    /// background scan completes — calling `completion` exactly once the
    /// whole path is as far along as it can go. Stops early, without calling
    /// `completion` again, if a step's node cannot be found (the path no
    /// longer resolves — an edit moved or removed it).
    private func expandAncestors(
        of nodeID: NodeID, in tree: LazyUEFITree, completion: @escaping () -> Void
    ) {
        func step(_ index: Int) {
            guard index < nodeID.path.count - 1 else { completion(); return }
            let partialID = NodeID(Array(nodeID.path.prefix(index + 1)))
            guard let ancestor = tree.node(partialID) else { completion(); return }
            guard ancestor.isExpandable, ancestor.children.isEmpty else {
                expandRow(partialID) { step(index + 1) }
                return
            }
            tree.expand(partialID) { [weak self] _ in
                guard let self else { return }
                self.expandRow(partialID) { step(index + 1) }
            }
        }
        step(0)
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

            let value = ToolWrappingLabel(string: field.value)
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

            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(row)
            // As wide as the list, so a value too long for the column — a
            // GUID, a hash — wraps inside it instead of running off the side.
            row.widthAnchor.constraint(
                equalTo: detail.content.widthAnchor
            ).isActive = true
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

/// One row of the outline: the place in the tree it stands for, and nothing
/// else. Public because it is what an outline item *is* here — a caller
/// reading a row asks the tree what is at `id`, the way the panel does.
///
/// The outline is handed these rather than `UEFINode` values, and that is the
/// whole point of the type. An outline decides what it is looking at by
/// comparing the item it was handed, and a node is a value that *changes* as
/// its branch arrives: `children` fills in, `isExpandable` goes false. The row
/// drawn before the branch and the row drawn after are two different values,
/// so the outline drops everything it knew about the first — including the
/// fact that the reader had just opened it, which is how a click on a
/// disclosure triangle came to close itself again a moment later.
///
/// A path does not change. One instance per path, handed out by
/// `row(_:)`, so the outline sees the same object for the same node for as
/// long as the tree holds it.
public final class UEFITreeRow {
    public let id: NodeID
    /// True for the "Loading…" row standing in for a branch still being read.
    /// `id` is that branch's, so every opening branch gets a placeholder of its
    /// own — an outline needs each of its items to be a distinct object, and
    /// one shared placeholder under two branches opening at once is the same
    /// object in two places, which is a tree the outline cannot lay out.
    public let isLoading: Bool

    init(_ id: NodeID, isLoading: Bool = false) {
        self.id = id
        self.isLoading = isLoading
    }
}

extension UEFIToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// `item`'s children as the outline should see them right now: the ones
    /// the tree has, or the single "Loading…" row a branch slow enough to have
    /// earned one shows in their place.
    ///
    /// A row is not normally opened before its branch is there — that is
    /// `outlineView(_:shouldExpandItem:)`'s job — so this mostly answers with
    /// real children. The rest of it covers a row opened some other way.
    private func childrenList(for id: NodeID) -> [Any] {
        guard let tree, let node = tree.node(id) else { return [] }
        if !node.children.isEmpty {
            return node.children.map { row($0.id) }
        }
        guard node.isExpandable else { return [] }
        if showingPlaceholder.contains(id) { return [placeholder(under: id)] }
        beginOpening(id)
        return showingPlaceholder.contains(id) ? [placeholder(under: id)] : []
    }

    /// A row the reader clicked open whose branch has not been read yet stays
    /// shut, and the reading starts. The row opens in `branchArrived(_:)` —
    /// once, with what is actually in it.
    ///
    /// Except once the branch has been slow enough to earn a "Loading…" row:
    /// this is asked for a programmatic `expandItem` too, so refusing then
    /// would refuse the panel's own attempt to put that row up, and the branch
    /// would never open at all.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let row = item as? UEFITreeRow, !row.isLoading, let tree,
              let node = tree.node(row.id), node.children.isEmpty, node.isExpandable,
              !showingPlaceholder.contains(row.id)
        else { return true }
        beginOpening(row.id)
        return false
    }

    /// Starts reading a branch, and — only if it turns out to be slow — puts a
    /// "Loading…" row up to say so.
    private func beginOpening(_ id: NodeID) {
        guard let tree, opening[id] == nil else { return }
        opening[id] = Date()
        tree.expand(id) { [weak self] _ in self?.branchArrived(id) }
        guard opening[id] != nil else { return }   // it was already in hand

        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.placeholderDelay * 1_000_000_000)
            )
            guard let self, self.opening[id] != nil else { return }
            self.showingPlaceholder.insert(id)
            self.expandRow(id)
        }
    }

    /// The branch is there. A row that never showed a placeholder simply opens
    /// now, in one animation, with its real children in it. A row that did has
    /// them put in its place — but not while the outline is still animating the
    /// placeholder in.
    private func branchArrived(_ id: NodeID) {
        guard opening.removeValue(forKey: id) != nil else { return }
        guard showingPlaceholder.remove(id) != nil else {
            expandRow(id)
            return
        }
        enqueue(animated: true) { [weak self] in
            guard let self, let item = self.outlineItem(for: id) else { return }
            self.outline.reloadItem(item, reloadChildren: true)
        }
    }

    /// The one "Loading…" row standing in for `id`'s branch.
    private func placeholder(under id: NodeID) -> UEFITreeRow {
        if let row = loadingRows[id] { return row }
        let row = UEFITreeRow(id, isLoading: true)
        loadingRows[id] = row
        return row
    }

    /// The outline's own item for this path, when it has a row.
    private func outlineItem(for id: NodeID) -> Any? {
        let row = outline.row(forItem: row(id))
        guard row >= 0 else { return nil }
        return outline.item(atRow: row)
    }

    /// The one row object standing for this place in the tree.
    private func row(_ id: NodeID) -> UEFITreeRow {
        if let row = rows[id] { return row }
        let row = UEFITreeRow(id)
        rows[id] = row
        return row
    }

    /// The node an outline item stands for, as the tree has it now. A
    /// "Loading…" row stands for no node at all — its `id` is the branch it is
    /// waiting on, not something to select, name or publish.
    private func node(of item: Any) -> UEFINode? {
        guard let row = item as? UEFITreeRow, !row.isLoading else { return nil }
        return tree?.node(row.id)
    }

    /// The outline's own top level: one "Loading…" row while the tree is still
    /// working out what the top level is, and the presented rows once it has.
    private var topLevelRows: [Any] {
        isBuilding ? [placeholder(under: .root)] : presented.rows.map { row($0.id) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return topLevelRows.count }
        guard let row = item as? UEFITreeRow, !row.isLoading else { return 0 }
        return childrenList(for: row.id).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item, let row = item as? UEFITreeRow, !row.isLoading
        else { return topLevelRows[index] }
        return childrenList(for: row.id)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = node(of: item) else { return false }
        return node.isExpandable || !node.children.isEmpty
    }

    /// The loading row is a placeholder, not a node — nothing to select, no
    /// zone to publish, no menu to offer.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? UEFITreeRow)?.isLoading == false
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
        guard let identifier = tableColumn?.identifier else { return nil }
        if (item as? UEFITreeRow)?.isLoading == true {
            // Built the same way a real row's cell is, warning view included:
            // cells go back into one reuse pool per column, and a placeholder
            // that made a Name cell without the warning would hand it on to
            // the next flagged row, which then has nowhere to draw its
            // triangle.
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
                as? NSTableCellView
                ?? ToolPanelTable.makeCell(identifier: identifier,
                                           warning: identifier == Column.name)
            cell.textField?.stringValue = identifier == Column.name ? "Loading…" : ""
            cell.textField?.font = ToolPanelFont.body()
            if identifier == Column.name {
                ToolPanelTable.setWarning(false, on: cell)
            }
            return cell
        }
        guard let node = node(of: item) else { return nil }
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
              let clicked = outline.item(atRow: row),
              let node = node(of: clicked),
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

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isShowingState else { return }
        onOpenRowsChanged?()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isShowingState else { return }
        onOpenRowsChanged?()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        chooseNode(atRow: outline.selectedRow)
    }

    /// A row was chosen — by a selection that moved, or by a click on the row
    /// that was already the selection. Both publish the row's zone; the outline
    /// only reports the second kind itself (see `UEFIOutlineView`).
    private func chooseNode(atRow row: Int) {
        let item = row >= 0 ? outline.item(atRow: row) : nil
        onSelect?((item as? UEFITreeRow)?.id)
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
