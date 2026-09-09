import ALSplitView
import AppKit
import MEATool
import ToolModuleKit

/// The panel: a Summary / Full Tree switch — the MEA-style summary on the
/// first tab, the analysis tree (with the focused row's detail below it) on the
/// second.
///
/// It decides nothing. The summary is the pure target's `MEASummary` and the
/// tree is the curator's, both tested in the pure target; the analysis runs in
/// the session; the one zone is `MEAZones`. What is on screen comes from one
/// `show(...)` over values the panel only lays out.
@MainActor final class MEAToolViewController: NSViewController {
    /// The user picked a row in the tree, or cleared it. The value is the row's
    /// tree path — the identity a parked session keeps.
    var onSelect: (([Int]?) -> Void)?
    /// The user picked a tab (0 = Summary, 1 = Full Tree).
    var onTabChanged: ((Int) -> Void)?
    /// The status row's Try Again was pressed, after a failed analysis.
    var onRetry: (() -> Void)?

    /// The tree as it is shown, kept from one show to the next so the data
    /// source reads the same roots the last show laid out.
    private var roots: [MEANode] = []
    /// The selected row, as its path in `roots`. Nil for nothing selected.
    private var focusPath: [Int]?
    /// The summary as it was last built — kept so a re-show with the same
    /// analysis neither rebuilds the rows nor loses the user's scroll.
    private var summaryBlocks: [MEASummaryBlock] = []
    /// The tab on screen.
    private var tabIndex = 0
    /// True while state is being shown — a selection the code made is not news,
    /// and without this the panel would select, publish, re-show and select
    /// again until the stack ran out.
    private var isShowingState = false

    private let tabs = NSSegmentedControl(labels: ["Summary", "Full Tree"],
                                          trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let contentBox = NSView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let outline = MEOutlineView()
    private let outlineScroll = NSScrollView()
    private let detail = ToolDetailScroll()
    private let summaryScroll = ToolDetailScroll()
    private let splitter = ALSplitView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let bottomRow = NSStackView()
    /// The panel draws at the app's zoom (`ToolPanelFont`); this tells it when
    /// the zoom moved.
    private var zoomObserver: NSObjectProtocol?

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let summary = NSUserInterfaceItemIdentifier("summary")
    }

    /// What each summary row's label column is wide at
    /// `ToolPanelFont.designSize` — wider than the detail list's
    /// (`detailLabelWidth`), because the summary carries long MEA labels
    /// ("TCB Security Version Number") that would otherwise truncate.
    private static let summaryLabelWidth: CGFloat = 200

    /// What each column was laid out at — a width for text at
    /// `ToolPanelFont.designSize`, scaled from there to the zoom's size. Name is
    /// the column with something to say, so it gets the rest; Summary is as wide
    /// as the longest second line a normal row puts in it ("0x126000 · 0x200").
    private static let nameWidth: CGFloat = 300
    private static let summaryWidth: CGFloat = 150
    private var columnWidthSize = ToolPanelFont.designSize

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        view.translatesAutoresizingMaskIntoConstraints = false

        configureTabs()
        configureOutline()

        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.documentView = outline

        // Top: the tree. Bottom: the detail. The divider is the user's to move.
        splitter.isVertical = false
        splitter.dividerThickness = 1
        splitter.translatesAutoresizingMaskIntoConstraints = false
        splitter.addPane(outlineScroll)
        splitter.addPane(detail)
        splitter.setPaneLayout(.fill, at: 0)
        splitter.setPaneLayout(.proportional(1.0 / 3), at: 1)

        placeholderLabel.font = ToolPanelFont.body()
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 3
        placeholderLabel.stringValue = "The analysis summary will appear here."
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        contentBox.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(placeholderLabel)
        contentBox.addSubview(summaryScroll)
        contentBox.addSubview(splitter)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentBox.leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: contentBox.trailingAnchor, constant: -16),
            // The summary and the tree both fill the box to its edges; only one
            // is visible at a time, so overlapping edge-pinned siblings are
            // fine — visibility is the switch, not geometry.
            summaryScroll.topAnchor.constraint(equalTo: contentBox.topAnchor),
            summaryScroll.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            summaryScroll.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            summaryScroll.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
            splitter.topAnchor.constraint(equalTo: contentBox.topAnchor),
            splitter.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            splitter.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            splitter.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])

        noticeLabel.font = ToolPanelFont.body()
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addArrangedSubview(noticeLabel)
        bottomRow.addArrangedSubview(retryButton)

        view.addSubview(tabs)
        view.addSubview(contentBox)
        view.addSubview(bottomRow)

        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),

            contentBox.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            contentBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            contentBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            contentBox.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

            bottomRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottomRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            barWidth,
        ])

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.applyPanelFont()
        }
        selectTab(tabIndex)
    }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    private func configureTabs() {
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: 10)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Re-reads the panel's type size and puts everything on screen at it: the
    /// tree's rows and header, and the summary/detail rows — which are views
    /// built per field, so they have to be rebuilt rather than restyled.
    private func applyPanelFont() {
        noticeLabel.font = ToolPanelFont.body()
        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
        outline.reloadData()
        renderSummary()
        renderDetail(focusPath.flatMap { MEATree.node(at: $0, in: roots) })
    }

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
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self

        let name = NSTableColumn(identifier: Column.name)
        name.title = "Name"
        name.width = Self.nameWidth
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(name)
        outline.outlineTableColumn = name

        let summary = NSTableColumn(identifier: Column.summary)
        summary.title = ""
        summary.width = Self.summaryWidth
        summary.resizingMask = .userResizingMask
        outline.addTableColumn(summary)

        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
    }

    /// Which content the selected tab shows: the summary for Summary — or the
    /// placeholder standing for none — and the tree (with its detail below) for
    /// Full Tree.
    private func selectTab(_ index: Int) {
        tabIndex = index
        let showTree = index == 1
        let showSummary = index == 0 && !summaryBlocks.isEmpty
        splitter.isHidden = !showTree
        summaryScroll.isHidden = !showSummary
        placeholderLabel.isHidden = showSummary || showTree
        tabs.selectedSegment = index
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
        onTabChanged?(sender.selectedSegment)
    }

    @objc private func retryClicked() {
        onRetry?()
    }

    // MARK: - A parse's progress

    func showBusy() {
        guard progressBar.superview == nil else { return }
        progressBar.startAnimation(nil)
        bottomRow.addArrangedSubview(progressBar)
    }

    func endBusy() {
        guard progressBar.superview != nil else { return }
        progressBar.stopAnimation(nil)
        bottomRow.removeArrangedSubview(progressBar)
        progressBar.removeFromSuperview()
    }

    /// A line under the content — what happened, or what to do next.
    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? .systemRed : .secondaryLabelColor
    }

    /// Show or hide the status row's Try Again, for a failure the user can act
    /// on (an offline database fetch, a rate limit).
    func showRetry(_ shown: Bool) {
        retryButton.isHidden = !shown
    }

    /// Everything the panel shows, in one call.
    func show(roots: [MEANode], focusPath: [Int]?, tab: Int) {
        self.roots = roots
        self.focusPath = focusPath
        isShowingState = true
        defer { isShowingState = false }

        selectTab(tab)
        outline.reloadData()
        let focus = focusPath.flatMap { MEATree.node(at: $0, in: roots) }
        renderDetail(focus)

        guard let focus else {
            outline.deselectAll(nil)
            return
        }
        expandPath(to: focusPath ?? [])
        let row = outline.row(forItem: focus)
        if row >= 0 {
            outline.scrollRowToVisible(row)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// Expands each ancestor of the row so its row is on screen, like the UEFI
    /// tool re-opens the path to the node it is re-showing.
    private func expandPath(to path: [Int]) {
        guard !path.isEmpty else { return }
        for depth in 0..<path.count {
            let prefix = Array(path.prefix(depth + 1))
            guard let node = MEATree.node(at: prefix, in: roots) else { return }
            // The last step is the row itself; its ancestors above are expanded.
            if depth < path.count - 1, !node.children.isEmpty,
               outline.row(forItem: node) >= 0 {
                outline.expandItem(node)
            }
        }
    }

    // MARK: - Summary

    /// Hands the Summary tab the analysis's blocks. A re-show with the same
    /// blocks — a selection move, a parked restore that re-parsed the same
    /// file — changes nothing, so the user's scroll survives; a *different*
    /// summary (a fresh analysis, or none after a failure) is rebuilt and, when
    /// there is something to read, read from the top.
    func showSummary(_ blocks: [MEASummaryBlock]) {
        guard blocks != summaryBlocks else { return }
        summaryBlocks = blocks
        renderSummary()
        selectTab(tabIndex)
        if !blocks.isEmpty {
            summaryScroll.documentView?.scroll(.zero)
        }
    }

    /// Rebuilds the summary's rows — the blocks `showSummary` last accepted,
    /// at the current zoom. Only label and value views: the values come
    /// pre-formatted from `MEASummary`, so nothing is decided here.
    private func renderSummary() {
        let stack = summaryScroll.content
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        summaryScroll.placeholder.isHidden = true

        let labelWidth = ToolPanelFont.scaled(Self.summaryLabelWidth)
        for (index, block) in summaryBlocks.enumerated() {
            // A real gap before each block after the first (the table needs no
            // title, the messages block does — and both read better apart).
            if index > 0, let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(14, after: last)
            }
            if let title = block.title {
                let heading = NSTextField(labelWithString: title)
                heading.font = ToolPanelFont.title()
                heading.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(heading)
            }
            for row in block.rows {
                stack.addArrangedSubview(Self.summaryRowView(row, labelWidth: labelWidth))
            }
        }
    }

    /// One Field/Value line: a fixed-width label column — wider than the detail
    /// list's, because summary labels run long ("TCB Security Version
    /// Number") — and a value. A `.comingSoon` value is drawn grey and
    /// unselectable, the shape of a row the engine will answer once the bridge
    /// reaches it.
    private static func summaryRowView(
        _ row: MEASummaryRow, labelWidth: CGFloat
    ) -> NSView {
        let label = NSTextField(labelWithString: row.label)
        label.font = ToolPanelFont.body()
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let value: NSTextField
        switch row.value {
        case .value(let text):
            value = NSTextField(labelWithString: text)
            value.font = text.hasPrefix("0x")
                ? ToolPanelFont.monospacedDigits()
                : ToolPanelFont.body()
            value.isSelectable = true
            value.textColor = .labelColor
        case .comingSoon:
            value = NSTextField(labelWithString: "Coming soon")
            value.font = ToolPanelFont.body()
            value.textColor = .secondaryLabelColor
        }
        value.lineBreakMode = .byTruncatingTail
        value.translatesAutoresizingMaskIntoConstraints = false

        let line = NSStackView(views: [label, value])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    /// Rebuilds the detail list from the focused row's own fields.
    private func renderDetail(_ focus: MEANode?) {
        guard let focus, !focus.fields.isEmpty else {
            detail.showPlaceholder(focus == nil
                ? "Select a row to see what it is."
                : "Nothing more to show for this row.")
            return
        }
        detail.prepareForRows(subject: focus.title)

        let title = NSTextField(labelWithString: focus.title)
        title.font = ToolPanelFont.title()
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.content.addArrangedSubview(title)

        for field in focus.fields {
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

extension MEAToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard !roots.isEmpty else { return 0 }
        guard let node = item as? MEANode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? MEANode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? MEANode)?.children.isEmpty == false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? MEANode, let identifier = tableColumn?.identifier
        else { return nil }
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: identifier)
        cell.textField?.stringValue = text(for: node, in: identifier)
        cell.textField?.font = identifier == Column.summary && node.subtitle.hasPrefix("0x")
            ? ToolPanelFont.monospacedDigits()
            : ToolPanelFont.body()
        return cell
    }

    private func text(
        for node: MEANode, in column: NSUserInterfaceItemIdentifier
    ) -> String {
        column == Column.summary ? node.subtitle : node.title
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        let row = outline.selectedRow
        let node = row >= 0 ? outline.item(atRow: row) as? MEANode : nil
        onSelect?(node?.path)
    }
}

/// The tree, with no behaviour past NSOutlineView's — kept as its own subclass
/// so a future context menu (like the UEFI tool's Fix Checksum) has a home.
private final class MEOutlineView: NSOutlineView {}
