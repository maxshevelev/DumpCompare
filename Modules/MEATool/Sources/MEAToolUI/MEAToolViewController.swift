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
    /// Taking the summary somewhere else: as text to paste into a note or a
    /// report, or as a picture of the whole of it. They sit in the tab row,
    /// against its trailing edge, and belong to the Summary tab — the tree has
    /// its own ways out (a zone, a reveal) and no one page to hand over.
    private let copyButton = NSButton()
    private let screenshotButton = NSButton()
    private let summaryActions = NSStackView()
    private let contentBox = NSView()
    /// The empty Summary tab: an icon over a line saying what the panel is
    /// doing, or why there is nothing to read.
    private let placeholder = NSStackView()
    private let placeholderIcon = NSImageView()
    private let placeholderTitle = NSTextField(labelWithString: "")
    private let placeholderCaption = NSTextField(labelWithString: "")
    /// Which of the three things the empty tab is saying, kept so a zoom change
    /// can re-lay it out without the caller saying it again.
    private var placeholderState = Placeholder.waiting
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

    /// What an empty Summary tab is: the analysis is running, it finished with
    /// nothing to summarise, or it did not finish. An empty tab used to say the
    /// same sentence in all three — "the summary will appear here" — which is a
    /// promise while a parse runs and a lie once one has failed. The panel is
    /// the only screen the user is looking at while the ME region is read, so
    /// this is where it says so.
    enum Placeholder {
        case waiting
        case empty
        case failed

        /// The system symbol the state wears. A running analysis is the engine
        /// the panel is about; nothing found is a question; a failure is the
        /// warning that goes with the red line under the panel.
        var symbol: String {
            switch self {
            case .waiting: return "cpu"
            case .empty: return "questionmark.circle"
            case .failed: return "exclamationmark.triangle"
            }
        }

        var title: String {
            switch self {
            case .waiting: return "Analyzing the ME firmware…"
            case .empty: return "No ME firmware"
            case .failed: return "The analysis did not finish"
            }
        }

        /// The second line — what the user can do with the wait, or where the
        /// rest of the answer is. A failure's reason is in the status row, in
        /// red, so the caption points at it rather than repeating it.
        var caption: String {
            switch self {
            case .waiting: return "Reading the region and its partitions."
            case .empty: return "Nothing in this file reads as Intel ME firmware."
            case .failed: return "The line below says what went wrong."
            }
        }
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
        configureSummaryActions()
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

        configurePlaceholder()

        contentBox.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(placeholder)
        contentBox.addSubview(summaryScroll)
        contentBox.addSubview(splitter)
        // The empty tab's own margins are breakable: a collapsed panel is not
        // 32 points wide, and a required pair there is one AppKit strikes out
        // to recover — taking the panel's own edge pins with it.
        let placeholderInsets = [
            placeholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentBox.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: contentBox.trailingAnchor, constant: -16),
        ]
        placeholderInsets.forEach { $0.priority = .defaultHigh }

        NSLayoutConstraint.activate(placeholderInsets + [
            placeholder.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor),
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
        view.addSubview(summaryActions)
        view.addSubview(contentBox)
        view.addSubview(bottomRow)

        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh
        // Clear of the tabs, and giving way before them: the switch is what the
        // row is for.
        let clearOfTabs = summaryActions.leadingAnchor.constraint(
            greaterThanOrEqualTo: tabs.trailingAnchor, constant: 8
        )
        clearOfTabs.priority = .defaultHigh
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),

            clearOfTabs,
            summaryActions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            summaryActions.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),

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

    /// The empty tab's icon and two lines, stacked and centred. The icon is a
    /// system symbol, so it follows the theme and the accessibility weights on
    /// its own; a build of macOS without one just shows the words.
    private func configurePlaceholder() {
        placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
        placeholderIcon.contentTintColor = .tertiaryLabelColor
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        for label in [placeholderTitle, placeholderCaption] {
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            // A sentence in the middle of the panel must not be what decides
            // how narrow the panel can be dragged: it gives its width up and
            // takes another line instead. Without this the caption's own
            // length became the panel's minimum width, and the tree and the
            // detail beside it were laid out for a panel wider than the one
            // on screen.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        placeholderTitle.textColor = .secondaryLabelColor
        placeholderCaption.textColor = .tertiaryLabelColor

        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 4
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.addArrangedSubview(placeholderIcon)
        placeholder.setCustomSpacing(10, after: placeholderIcon)
        placeholder.addArrangedSubview(placeholderTitle)
        placeholder.addArrangedSubview(placeholderCaption)

        applyPlaceholder()
    }

    /// Says what the empty Summary tab is showing. The three states are the
    /// three ways there can be no summary, and the panel is told which by the
    /// module that knows — a parse starting, one ending with nothing, one
    /// failing.
    func setPlaceholder(_ state: Placeholder) {
        placeholderState = state
        applyPlaceholder()
        // A parse starting is news for what is on screen, not only for what the
        // placeholder says: it is told before any roots arrive, and the tab it
        // is standing in for is whichever one is open.
        selectTab(tabIndex)
    }

    /// The placeholder as the state and the current zoom make it. The icon is
    /// sized off the panel's type rather than fixed, so it stays the same
    /// weight beside the words at every zoom.
    private func applyPlaceholder() {
        let side = (ToolPanelFont.size * 3).rounded()
        let icon = NSImage(systemSymbolName: placeholderState.symbol,
                           accessibilityDescription: placeholderState.title)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            )
        // Re-stated: the configuration hands back a new image, and what it
        // carries over is not promised. The description is what the state is
        // called, so a screen reader says the same thing the words below do.
        icon?.accessibilityDescription = placeholderState.title
        placeholderIcon.image = icon
        placeholderIcon.isHidden = icon == nil

        placeholderTitle.font = ToolPanelFont.body(weight: .semibold)
        placeholderTitle.stringValue = placeholderState.title
        placeholderCaption.font = ToolPanelFont.body()
        placeholderCaption.stringValue = placeholderState.caption
    }

    private func configureTabs() {
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: 10)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        // The switch keeps its own width whatever else is in the row.
        tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The two ways out of the Summary tab, as icons in its own row: the rows
    /// as text to paste, and the whole page as a picture.
    private func configureSummaryActions() {
        for (button, symbol, name, action) in [
            (copyButton, "doc.on.doc", "Copy Summary", #selector(copySummary)),
            (screenshotButton, "camera", "Copy Screenshot", #selector(copyScreenshot)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            button.imagePosition = .imageOnly
            // The panel's own close button's treatment: a plain symbol in the
            // chrome's colour, not a control with a box around it.
            button.bezelStyle = .inline
            button.controlSize = .small
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = name
            button.setAccessibilityLabel(name)
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        summaryActions.orientation = .horizontal
        summaryActions.alignment = .centerY
        summaryActions.spacing = 10
        summaryActions.translatesAutoresizingMaskIntoConstraints = false
        summaryActions.addArrangedSubview(copyButton)
        summaryActions.addArrangedSubview(screenshotButton)
    }

    /// Re-reads the panel's type size and puts everything on screen at it: the
    /// tree's rows and header, and the summary/detail rows — which are views
    /// built per field, so they have to be rebuilt rather than restyled.
    private func applyPanelFont() {
        noticeLabel.font = ToolPanelFont.body()
        applyPlaceholder()
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

    /// Which content the selected tab shows: the summary for Summary, the tree
    /// (with its detail below) for Full Tree — and, for either of them with
    /// nothing in it yet, the placeholder saying why. A tab is empty for the
    /// same three reasons on both sides, and while the ME region is being read
    /// an empty tree is a wait, not an answer; an empty outline with a spinner
    /// under it said nothing about which.
    private func selectTab(_ index: Int) {
        tabIndex = index
        let showTree = index == 1 && !roots.isEmpty
        let showSummary = index == 0 && !summaryBlocks.isEmpty
        splitter.isHidden = !showTree
        summaryScroll.isHidden = !showSummary
        placeholder.isHidden = showSummary || showTree
        // Nothing to copy and nothing to picture until the summary is up.
        summaryActions.isHidden = !showSummary
        tabs.selectedSegment = index
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
        onTabChanged?(sender.selectedSegment)
    }

    @objc private func retryClicked() {
        onRetry?()
    }

    // MARK: - Taking the summary away

    /// The summary as rich text on the clipboard: headings bold, each row a
    /// label and its value on one tabbed line, so it pastes into a note or a
    /// report as the table it is on screen rather than as a run-on paragraph.
    /// An `NSAttributedString` carries both spellings — the RTF and the plain
    /// text under it — so a plain-text field gets a readable version for free.
    @objc func copySummary() {
        guard !summaryBlocks.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.richText(of: summaryBlocks)])
    }

    /// A picture of the whole summary on the clipboard — all of it, not the
    /// part that happens to be scrolled into view: the document view is as tall
    /// as its rows, and that is what is cached.
    @objc func copyScreenshot() {
        guard !summaryBlocks.isEmpty, let image = summaryPicture() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// A picture of the summary's rows, drawn whole and cropped to them.
    ///
    /// The rows rather than the list they scroll in: the list is as wide as the
    /// panel and at least as tall as the visible area, so picturing it would
    /// hand over the summary in the middle of a field of empty background.
    /// `cacheDisplay` draws a view and everything under it whatever an ancestor
    /// clips, so the rows below the fold come too.
    ///
    /// Nil when there is nothing laid out to draw — a panel that has never been
    /// on screen has no size.
    func summaryPicture() -> NSImage? {
        let rows = summaryScroll.content
        let bounds = rows.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let cache = rows.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        rows.cacheDisplay(in: bounds, to: cache)
        let cached = NSImage(size: bounds.size)
        cached.addRepresentation(cache)

        let margin: CGFloat = 10
        let size = NSSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)
        let picture = NSImage(size: size)
        picture.lockFocus()
        // Under the theme the rows were *drawn* in, not the one that happens to
        // be current here. A dark panel's rows are pale, and a background
        // resolved outside its appearance comes back the light one — pale text
        // on white, which is a picture of nothing.
        summaryScroll.effectiveAppearance.performAsCurrentDrawingAppearance {
            // The rows draw no background of their own; the list behind them
            // does. Without it the picture would paste as text on nothing.
            (summaryScroll.drawsBackground ? summaryScroll.backgroundColor : .textBackgroundColor)
                .setFill()
            NSRect(origin: .zero, size: size).fill()
            cached.draw(in: NSRect(x: margin, y: margin,
                                   width: bounds.width, height: bounds.height))
        }
        picture.unlockFocus()
        return picture
    }

    /// The blocks as one attributed string. The label column is a tab stop
    /// rather than padding, so the values line up in whatever font the reader's
    /// document is in.
    static func richText(of blocks: [MEASummaryBlock]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let size = ToolPanelFont.size
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.tabStops = [NSTextTab(textAlignment: .left, location: size * 16)]
        rowStyle.defaultTabInterval = size * 16
        rowStyle.headIndent = size * 16

        for block in blocks {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            if let title = block.title {
                text.append(NSAttributedString(string: title + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size + 1, weight: .semibold),
                ]))
            }
            for row in block.rows {
                text.append(NSAttributedString(string: row.label + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: size),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: rowStyle,
                ]))
                let value: String
                let emphasized: Bool
                switch row.value {
                case .value(let shown):
                    value = shown
                    // The same weight the panel gives a status-toned value.
                    emphasized = row.tone != .standard
                case .comingSoon:
                    value = "Coming soon"
                    emphasized = false
                }
                text.append(NSAttributedString(string: value + "\n", attributes: [
                    .font: value.hasPrefix("0x")
                        ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                        : NSFont.systemFont(ofSize: size, weight: emphasized ? .bold : .regular),
                    .foregroundColor: MEASummaryToneColor.color(for: row.tone),
                    .paragraphStyle: rowStyle,
                ]))
            }
        }
        return text
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
                let (line, label) = Self.summaryRowView(row)
                stack.addArrangedSubview(line)
                // As wide as the list itself, so a long value has a column to
                // wrap inside rather than a line to run off the side of.
                line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                // The label column, breakable, and capped at half the list.
                // Required, this width was a floor under the whole panel — at
                // a large zoom the panel could not be dragged narrower than
                // one summary label, and what gave way instead was the
                // panel's own edge pins.
                let column = label.widthAnchor.constraint(equalToConstant: labelWidth)
                column.priority = .defaultHigh
                column.isActive = true
                label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                             multiplier: 0.5).isActive = true
            }
        }
    }

    /// One Field/Value line: a label column — wider than the detail list's,
    /// because summary labels run long ("TCB Security Version Number") — and a
    /// value that wraps inside what is left of the width. The column's width is
    /// the caller's to constrain, since only it knows the list the row is in. A
    /// `.comingSoon` value is drawn grey and unselectable, the shape of a row
    /// the engine will answer once the bridge reaches it.
    private static func summaryRowView(
        _ row: MEASummaryRow
    ) -> (line: NSStackView, label: NSTextField) {
        let label = NSTextField(labelWithString: row.label)
        label.font = ToolPanelFont.body()
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let value: ToolWrappingLabel
        switch row.value {
        case .value(let text):
            value = ToolWrappingLabel(string: text)
            // A status-toned value (File System State) is bold as well as
            // coloured — the weight makes the state read at a glance.
            let emphasized = row.tone != .standard
            value.font = text.hasPrefix("0x")
                ? ToolPanelFont.monospacedDigits()
                : ToolPanelFont.body(weight: emphasized ? .bold : .regular)
            value.isSelectable = true
            value.textColor = MEASummaryToneColor.color(for: row.tone)
        case .comingSoon:
            value = ToolWrappingLabel(string: "Coming soon")
            value.font = ToolPanelFont.body()
            value.textColor = .secondaryLabelColor
        }

        let line = NSStackView(views: [label, value])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false
        return (line, label)
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

        // The engine's field names run long — "systemHeaderCRCValid",
        // "matchesMFSDictionary" — and the shared default column cut them off
        // mid-word. The column is as wide as the longest name it carries, so
        // one that fits is shown whole; never narrower than the default, so a
        // list of short names reads exactly as it did; and never wider than
        // half the list, where a name that still does not fit wraps rather
        // than crowding the value out.
        let labels = focus.fields.map { field -> ToolWrappingLabel in
            let label = ToolWrappingLabel(string: field.label)
            label.font = ToolPanelFont.body()
            label.textColor = .secondaryLabelColor
            return label
        }
        // Measured before they are in the hierarchy, where a wrapping label
        // still reports what it needs on one line.
        let nameColumn = max(ToolPanelFont.detailLabelWidth,
                             labels.map(\.intrinsicContentSize.width).max() ?? 0)

        for (field, label) in zip(focus.fields, labels) {
            let value = ToolWrappingLabel(string: field.value)
            value.font = field.value.hasPrefix("0x")
                ? ToolPanelFont.monospacedDigits()
                : ToolPanelFont.body()
            value.isSelectable = true

            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(row)
            // Anchored to the list only once the row is in it — a constraint
            // across two hierarchies is not one the engine will take.
            //
            // The value column is what is left of the list's width, and a
            // hash or a GUID wraps inside it.
            row.widthAnchor.constraint(
                equalTo: detail.content.widthAnchor
            ).isActive = true
            // The name column, breakable, and the cap is the one thing that
            // breaks it: past half the list the name wraps instead of taking
            // more.
            let column = label.widthAnchor.constraint(equalToConstant: nameColumn)
            column.priority = .defaultHigh
            column.isActive = true
            label.widthAnchor.constraint(lessThanOrEqualTo: detail.content.widthAnchor,
                                         multiplier: 0.5).isActive = true
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
        // A section that holds nothing reads grey in the value column: it is a
        // place in the layout rather than something to go and look at. Its
        // name stays black — the row is still worth finding.
        cell.textField?.textColor = identifier == Column.summary && node.isEmptySection
            ? .secondaryLabelColor
            : .labelColor
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

/// The colour a summary row's value is drawn in, by its `MEASummaryTone`.
/// The three status tones are resolved per appearance — a saturated but darker
/// shade in light mode, a lighter pastel in dark — so each stays legible
/// against the panel background in both themes.
private enum MEASummaryToneColor {
    static func color(for tone: MEASummaryTone) -> NSColor {
        switch tone {
        case .standard: return .labelColor
        case .good: return Self.good
        case .caution: return Self.caution
        case .bad: return Self.bad
        }
    }

    /// A settled File System State — green in both themes.
    private static let good = NSColor(name: nil) { appearance in
        Self.isDark(appearance)
            ? NSColor(srgbRed: 0.55, green: 0.82, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.07, green: 0.46, blue: 0.12, alpha: 1)
    }

    /// A mid-lifecycle File System State — brown, brightened to tan in dark
    /// mode so it does not sink into the background.
    private static let caution = NSColor(name: nil) { appearance in
        Self.isDark(appearance)
            ? NSColor(srgbRed: 0.86, green: 0.66, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.34, blue: 0.04, alpha: 1)
    }

    /// A failed File System State — red in both themes.
    private static let bad = NSColor(name: nil) { appearance in
        Self.isDark(appearance)
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.12, blue: 0.12, alpha: 1)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
