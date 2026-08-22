import Cocoa

/// The pane's title bar (file name, dirty/read-only state, close button).
///
/// Besides showing the title it recognizes a double-click anywhere on the bar —
/// except on the close button — and reports it via `onDoubleClick`. In
/// side-by-side mode that tells ComparisonView to expand this pane so its hex
/// content fits by width (§3.3).
final class PaneHeaderView: NSView {
    /// Fired on a double-click in the header (not on the close button).
    var onDoubleClick: (() -> Void)?

    /// Routes every click in the bar to the bar itself — the title/lock labels
    /// are plain text and must not swallow the gesture. The close button keeps
    /// its clicks. Points outside the bar pass through untouched.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    /// Right-click pops the pane's File menu (assigned via `menu`), acting on
    /// this pane — not the active pane. The close button keeps its own clicks.
    override func rightMouseDown(with event: NSEvent) {
        if let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// One file pane (§3.4, §15): a header (file name, `*` dirty, read-only lock,
/// comparison-mode close button), the virtualized hex dump, and a status bar.
///
/// In single-file mode this fills the client area; in comparison mode (M5) two
/// of these sit side by side. The pane owns no model logic — it binds a
/// `PaneViewModel` to the hex view and mirrors its `onChange` into the chrome.
final class FilePaneView: NSView {
    let viewModel: PaneViewModel
    /// The scroll view hosting the hex view; ComparisonView uses its clip view
    /// for synchronized scrolling (§9).
    let scrollView: NSScrollView

    private let hexView: HexView
    /// The title bar at the top of the pane (file name, dirty/read-only state,
    /// close button). Stored so the pane's right-click File menu can be attached
    /// to it via `paneMenu` (§4/§5).
    private let header = PaneHeaderView()

    /// Ideal width of this pane's hex content, for zoom-to-fit (§3.1).
    var hexContentWidth: CGFloat { hexView.hexContentWidth }

    /// Ideal height of this pane's hex content — all rows of the current file.
    /// Used by window zoom-to-fit (§3.1).
    var hexContentHeight: CGFloat { hexView.hexContentHeight }

    /// Margin added to `hexContentWidth` so the grid doesn't sit flush against
    /// the pane edge / scroller. Shared by zoom-to-fit and the header
    /// double-click fit-to-content-width (§3.3).
    static let contentFitSlack: CGFloat = 16

    /// Width this pane needs to show its hex content without a horizontal
    /// scroller: content plus slack (§3.3).
    var contentFitWidth: CGFloat { hexContentWidth + Self.contentFitSlack }

    /// Fixed pane chrome above and below the scroll view (§3.4): the header and
    /// the status bar. Sizing constants shared with window zoom-to-fit (§3.1).
    static let headerHeight: CGFloat = 28
    static let statusBarHeight: CGFloat = 24

    /// Height this pane needs to show its hex content without a vertical
    /// scroller: all rows plus the title header, column header, and status bar
    /// (§3.1).
    var contentFitHeight: CGFloat {
        hexContentHeight + Self.headerHeight + Self.statusBarHeight + columnHeader.headerHeight
    }

    /// The dump's own area in window coordinates — the rectangle the minimap
    /// lines its map up with (§19.2). Nil until the pane is in a window.
    ///
    /// Measured rather than summed from the chrome constants, because the sum is
    /// never quite right: the scroll view has its own inset, the split adds a
    /// divider, and an open Find bar (§11) or a taller row (§6) moves the dump
    /// besides. Whatever pushes the bytes around, this follows.
    var dumpAreaInWindow: NSRect? {
        guard window != nil else { return nil }
        return scrollView.convert(scrollView.bounds, to: nil)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    /// The document glyph before the file name: "document" while the file is
    /// clean, "document.fill" once there are unsaved changes (§3.4). Tinted to
    /// match the title so it reads as part of the header, not as a button.
    private let documentIcon = NSImageView()
    /// The SF Symbol the header glyph is currently showing ("document" or
    /// "document.fill"). NSImage doesn't report a system symbol's name, so the
    /// pane tracks it for tests and VoiceOver.
    private(set) var documentSymbolName = "document"
    private let lockLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// The typing-mode indicator at the right end of the status bar: `OVR` in
    /// the status bar's own quiet grey, `INS` in the insert caret's red (§7.6).
    /// Insert mode grows the file on every keystroke, so it is the state that
    /// gets the colour — the mode is readable at a glance, without hunting for
    /// the caret or opening the Edit menu. Internal so tests can read it.
    let typingModeLabel = NSTextField(labelWithString: "OVR")
    /// The pinned column header above the dump ("Offset" / "Hex" / "Decoded
    /// text"). It sits outside the scroll view, so it never scrolls vertically,
    /// and mirrors the horizontal scroll to stay aligned with the columns (§6).
    private let columnHeader = HexColumnHeaderView()
    private var columnHeaderScrollObserver: NSObjectProtocol?
    /// Pins the header to one hex row plus its vertical padding; the constant
    /// is updated when the appearance (row height) changes (§3.2).
    private var columnHeaderHeightConstraint: NSLayoutConstraint?
    private var appearanceObserver: NSObjectProtocol?
    /// Redraws the column header when the word size changes (§6): the grid
    /// regroups, so the labels must track the new column positions.
    private var wordSizeObserver: NSObjectProtocol?
    /// The status-bar strip for the running background operation (name +
    /// progress bar + ×), hidden while idle (§14.4). Internal so tests can
    /// assert the debounced reveal / hide.
    let operationView = OperationStatusView()
    /// The Search All results panel, hidden while no search results are shown
    /// (§11). Internal so tests can assert its header count and drive row
    /// clicks.
    let searchResultsView = SearchResultsView()

    /// The dump and the results panel share the pane through a native
    /// NSSplitView: its system divider resizes the panel, and hiding the panel
    /// collapses it so the dump reclaims the full height (§11). Internal so
    /// tests can assert the collapse and the resized height.
    let searchResultsSplit = SearchResultsSplitView()

    /// Whether this pane has already shown the results panel once this session.
    /// The one-third-of-the-dump clamp applies only to the height restored
    /// from a previous launch; a height the user chose by dragging a divider in
    /// this session is applied as-is on later shows (§11).
    private var hasRestoredPanelHeightThisSession = false

    /// Where the panel height is persisted. Swappable so the suite does not write
    /// the user's real preference: the panel is shown at a legal height by some
    /// twenty tests, and each of those was a write to `UserDefaults.standard`.
    static var defaults: UserDefaults = .standard

    /// `UserDefaults` key for the user's chosen Search All panel height (§11).
    static let searchResultsHeightDefaultsKey = "SearchResultsPanelHeight"
    /// The results panel keeps at least this height when resized (§11).
    static let minSearchResultsHeight: CGFloat = 80
    /// The hex dump keeps at least this height when the panel is resized (§11).
    static let minHexHeightInPane: CGFloat = 40

    /// Extra status text appended on the right (e.g. "Indexing… 42%" or diff
    /// counts in comparison mode). Set by ComparisonView/MainViewController.
    var comparisonInfo: String = "" {
        didSet { updateStatus() }
    }

    /// The pane header's right-click File menu, built by MainViewController so
    /// every item resolves THIS pane (§4, §5). Set before the pane is shown;
    /// `PaneHeaderView.rightMouseDown` pops it. The menu bar's File submenu is a
    /// separate menu acting on the active pane.
    var paneMenu: NSMenu? {
        didSet { header.menu = paneMenu }
    }

    /// Builds the context menu shown when the user right-clicks an address in
    /// the hex dump's Offset column — the "Select block from here" menu — given
    /// the clicked offset. Built by MainViewController so the item resolves
    /// THIS pane even when it is not the active one (§10.2).
    var offsetMenuProvider: ((UInt64) -> NSMenu)? {
        didSet { hexView.offsetMenuProvider = offsetMenuProvider }
    }

    /// Fired when the user double-clicks an address in the Offset column, with
    /// that row's start offset — the mouse gesture for marking a row (§20.3).
    /// Wired by MainViewController so it resolves THIS pane, as the offset menu
    /// does.
    var onOffsetDoubleClick: ((UInt64) -> Void)? {
        didSet { hexView.onOffsetDoubleClick = onOffsetDoubleClick }
    }

    /// Fired when the user clicks anywhere in the pane (activates it).
    var onActivate: (() -> Void)?
    /// Fired when the user double-clicks the header: expand this pane so its
    /// hex content fits by width (§3.3).
    var onHeaderDoubleClick: (() -> Void)?
    /// Fired when the comparison-mode close button is clicked.
    var onClose: (() -> Void)?
    /// Fired when the user closes the Search All results panel (the ×), with
    /// this pane. The panel is hidden and cleared by `hideSearchResults()`
    /// regardless; the owner uses the hook to stop the in-flight search (§11).
    var onSearchResultsClose: ((FilePaneView) -> Void)?
    /// Fired with the dropped file URLs (comparison-mode drops target this pane,
    /// §4.3). Only active after `enableFileDrop()`.
    var onDropFiles: (([URL]) -> Void)?
    /// Fired with the hex view's visible byte range whenever it changes (scroll,
    /// resize). The minimap draws its viewport rectangle from it (§19).
    var onHexViewportChanged: ((Range<UInt64>) -> Void)?

    private var dropEnabled = false
    /// Whether this pane is the active one. The operation indicator shows only
    /// in the active pane's status bar (§14.4).
    private(set) var isActive = false

    init(viewModel: PaneViewModel) {
        self.viewModel = viewModel
        self.hexView = HexView()
        self.scrollView = NSScrollView()
        super.init(frame: .zero)
        setUp()
        bind()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func setUp() {
        // Header
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        // The labels truncate; low priorities let them shrink gracefully when
        // the splitter makes a pane narrow (§3.3). The pane's width itself is
        // owned by ProportionalSplitView, not by this content.
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A 12 pt outline document in front of the title; the symbol swaps to
        // "document.fill" in `updateHeader` when the file becomes dirty.
        documentIcon.image = NSImage(systemSymbolName: "document", accessibilityDescription: "File document")
        documentIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        documentIcon.contentTintColor = .secondaryLabelColor
        documentIcon.imageScaling = .scaleProportionallyUpOrDown
        lockLabel.font = .systemFont(ofSize: 12)
        lockLabel.textColor = .secondaryLabelColor

        let closeButton = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.setButtonType(.momentaryChange)
        closeButton.toolTip = "Close pane"
        closeButton.contentTintColor = .secondaryLabelColor

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onDoubleClick = { [weak self] in
            self?.onHeaderDoubleClick?()
        }
        // Low priorities keep this container flexible so a narrow pane
        // (§3.3) can shrink it and truncate the title instead of forcing a
        // minimum width.
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(documentIcon)
        header.addSubview(titleLabel)
        header.addSubview(lockLabel)
        header.addSubview(closeButton)
        documentIcon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        lockLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            documentIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            documentIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: documentIcon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockLabel.leadingAnchor, constant: -6),
            lockLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            lockLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
        ])

        // Status bar: the regular status text on the left, the background
        // operation strip (name + progress + ×) to its right. An NSStackView
        // collapses a hidden arranged subview, so hiding the strip frees its
        // width and the label can stretch across the whole bar (§14.4).
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The mode indicator keeps its width: three monospaced characters, the
        // same in both states, so the bar's layout never shifts when the mode
        // flips. It holds its size against a narrow pane — the status text
        // truncates first.
        typingModeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        typingModeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        typingModeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A pane built while the mode is already on shows INS from the start.
        updateTypingModeIndicator(viewModel.isInsertMode)
        // The strip keeps its size; a narrow pane shrinks the status text.
        operationView.isHidden = true
        operationView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        operationView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let statusStack = NSStackView()
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 10
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(typingModeLabel)
        statusStack.addArrangedSubview(operationView)

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        // Same as the header: stay flexible so a narrow pane can shrink it.
        statusBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBar.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10),
            statusStack.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
        ])

        // Column header: pinned above the dump (so it never scrolls) and
        // mirroring the horizontal scroll, so the labels track their columns.
        columnHeader.hexView = hexView
        columnHeader.translatesAutoresizingMaskIntoConstraints = false
        columnHeaderHeightConstraint = columnHeader.heightAnchor.constraint(equalToConstant: columnHeader.headerHeight)
        columnHeaderHeightConstraint?.isActive = true
        columnHeaderScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.columnHeader.horizontalOffset = self?.scrollView.contentView.bounds.origin.x ?? 0
        }
        // When the font or row-height factor changes, the header grows or
        // shrinks with the rows and redraws its labels (§3.2).
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.columnHeaderHeightConstraint?.constant = self.columnHeader.headerHeight
            self.columnHeader.refreshForGridChange()
        }
        // The word size regroups the hex cells, so the header redraws its
        // labels at the new column positions (§6). The row height is unchanged,
        // so the height constraint is left alone.
        wordSizeObserver = NotificationCenter.default.addObserver(
            forName: WordSize.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.columnHeader.refreshForGridChange()
        }

        // Scrollable hex view.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = hexView

        // Search All results panel (§11): the dump and the panel share the
        // pane vertically through a native NSSplitView. Its system divider
        // resizes the panel with the standard drag behaviour and cursor; the
        // panel is hidden (collapsed natively by NSSplitView) while no results
        // are shown and revealed with the user's stored height on a Search All.
        searchResultsView.onClose = { [weak self] in
            guard let self else { return }
            // Stop the owner's in-flight search first, then hide and forget the
            // results — a closed panel must not keep receiving matches (§11).
            self.onSearchResultsClose?(self)
            self.hideSearchResults()
        }
        searchResultsView.onSelect = { [weak self] range in
            guard let self else { return }
            // Selecting a result mirrors a single Find match (§11): the range
            // is selected in the hex view and scrolled to the vertical centre.
            self.viewModel.select(range: range)
            self.hexView.revealSelectionCentered()
            self.focusHexView()
        }

        searchResultsSplit.isVertical = false
        searchResultsSplit.dividerStyle = .thin
        searchResultsSplit.translatesAutoresizingMaskIntoConstraints = false
        // The delegate owns the divider's min/max clamping and persists the
        // panel height whenever the divider moves (§11).
        searchResultsSplit.delegate = self
        searchResultsSplit.addArrangedSubview(scrollView)
        searchResultsSplit.addArrangedSubview(searchResultsView)
        // The panel starts collapsed at zero height — the split's first real
        // layout pins the divider to the bottom — so the dump gets the whole
        // pane until a Search All shows results (§11).

        // The header and column header are pinned at the top; the split view and
        // the status bar fill the rest. A stack arranged subview is sized to its
        // fitting height, and a split view's fitting height is ambiguous (its
        // panes' content) — so a stack would collapse the split instead of
        // letting it share the pane's height. Pinning the header and column
        // header directly (each has a required height constraint) forces the
        // split view to take exactly the leftover height.
        addSubview(header)
        addSubview(columnHeader)
        addSubview(searchResultsSplit)
        addSubview(statusBar)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            columnHeader.topAnchor.constraint(equalTo: header.bottomAnchor),
            columnHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnHeader.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchResultsSplit.topAnchor.constraint(equalTo: columnHeader.bottomAnchor),
            searchResultsSplit.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchResultsSplit.trailingAnchor.constraint(equalTo: trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: searchResultsSplit.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    deinit {
        if let columnHeaderScrollObserver {
            NotificationCenter.default.removeObserver(columnHeaderScrollObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let wordSizeObserver {
            NotificationCenter.default.removeObserver(wordSizeObserver)
        }
    }

    // MARK: - Binding

    private func bind() {
        hexView.dataSource = viewModel
        hexView.delegate = viewModel
        hexView.textDecoder = viewModel.textDecoder
        // Focus is the single source of truth for the active pane (§3.3):
        // clicking the dump makes the hex view first responder, which fires
        // `onActivate`, so the highlighted pane and the typing target never
        // diverge.
        hexView.onFocus = { [weak self] in
            self?.onActivate?()
        }
        hexView.onVisibleRangeChanged = { [weak self] range in
            self?.onHexViewportChanged?(range)
        }
        viewModel.onChange = { [weak self] in
            self?.refresh()
        }
        // A pure selection move (drag, click, keyboard): the bytes are
        // unchanged, so redraw only the rows the selection now covers
        // differently instead of the whole pane (§3.3).
        viewModel.onSelectionChanged = { [weak self] in
            self?.refreshSelection()
        }
        // A typing-mode flip recolors/reshapes the caret in place (its position
        // did not move): redraw the caret's row without scrolling, and swap the
        // status bar's INS/OVR indicator.
        viewModel.onCaretAppearanceChanged = { [weak self] in
            self?.hexView.redrawCaret()
            self?.updateStatus()
        }
        // A content change — bytes overwritten in this pane, or its decoder
        // rebuilt: redraw just the affected rows/columns and refresh the chrome
        // that follows the caret, without a full `reloadData` (§3.3 extension).
        viewModel.onContentChanged = { [weak self] change in
            self?.refreshContent(change)
        }
        // The companion pane's bytes changed: this pane's comparison-difference
        // background for those rows must repaint. A redraw only; this pane's
        // own content, status, and scroll are untouched (§3.3 extension).
        viewModel.onCompanionContentChanged = { [weak self] change in
            self?.hexView.reloadContent(change)
        }
        // When the companion's selection changed, this pane's mirror frames
        // moved — redraw only the rows those frames now cover differently. A
        // redraw only; this pane's own content, status, and scroll are
        // untouched (§3.3).
        viewModel.onMirroredSelectionChanged = { [weak self] in
            self?.hexView.reloadSelection()
        }
        // A bookmark mark appeared or disappeared on a row (§20). The list is
        // shared by both panes, so the same row repaints in each — a redraw
        // only; the bytes, selection, and scroll are untouched.
        viewModel.onBookmarksChanged = { [weak self] row in
            self?.hexView.redrawRow(startingAt: row)
        }
        // Dragging a mark moves the bookmark itself (§20.6) — the store decides
        // where it lands, since it is the one that knows which rows are taken.
        hexView.onBookmarkDrag = { [weak viewModel] from, to, lastRow in
            viewModel?.bookmarkStore?.move(rowContaining: from, to: to, lastRow: lastRow)
        }
    }

    /// Makes the hex view first responder (e.g. when the pane becomes active).
    func focusHexView() {
        window?.makeFirstResponder(hexView)
    }

    /// Scrolls the hex view so the current selection sits in the vertical centre
    /// of the visible area — used after a Find result lands, so the match is
    /// shown mid-pane instead of at its edge (§11).
    func revealSelectionCentered() {
        hexView.revealSelectionCentered()
    }

    /// Scrolls the hex view so the row containing `offset` sits in the vertical
    /// centre of the visible area (clamped to the document's edges). Used to
    /// show a newly selected block's start mid-pane (§10.2).
    func revealOffsetCentered(_ offset: UInt64) {
        hexView.revealOffsetCentered(offset)
    }

    /// Scrolls the hex view so the row containing `offset` sits at the top of the
    /// visible area. Driven by the minimap's viewport drag and wheel (§19).
    func scrollRowToTop(containing offset: UInt64) {
        hexView.scrollRowToTop(containing: offset)
    }

    /// Shows the bookmark edit popover on the mark of the row containing `offset`
    /// (§20.3). The row is scrolled into view first if it is not there: a popover
    /// has to point at something the user can see, and ⇧⌘D can be pressed with
    /// the caret's row just off screen.
    ///
    /// The pane view presents it because the mark's rect is the hex view's to
    /// give — the controller says which row, which rows are free, and what the
    /// two keys mean.
    @discardableResult
    func presentBookmarkEditPopover(
        rowContaining offset: UInt64, existingName: String?,
        rowIsFree: @escaping (UInt64) -> Bool,
        onCommit: @escaping (UInt64, String) -> Void, onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) -> BookmarkEditPopoverController {
        if !hexView.visibleByteRange().contains(offset) {
            hexView.revealOffsetCentered(offset)
            // The scroll has to land before the anchor rect is read, or the
            // popover points at where the row used to be.
            scrollView.contentView.layoutSubtreeIfNeeded()
        }
        let controller = BookmarkEditPopoverController(
            row: BookmarkStore.row(containing: offset), existingName: existingName,
            rowIsFree: rowIsFree, onCommit: onCommit, onCancel: onCancel, onDelete: onDelete
        )
        controller.show(relativeTo: hexView.bookmarkMarkRect(forRowContaining: offset), of: hexView)
        return controller
    }

    /// Shows a transient message (e.g. "No match found.") in the status bar,
    /// replacing the regular status for a couple of seconds, then restoring it.
    /// Used by the Find bar for errors and empty results (§11).
    func showTransientMessage(_ message: String) {
        statusLabel.stringValue = message
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(restoreStatus), object: nil)
        perform(#selector(restoreStatus), with: nil, afterDelay: 2.0)
    }

    @objc private func restoreStatus() {
        updateStatus()
    }

    /// Highlights the header to mark this pane as active (§3.3). The hex view
    /// uses the same flag to show the caret only on the active pane and draw the
    /// mirror frame on the inactive one.
    func setActive(_ isActive: Bool) {
        self.isActive = isActive
        titleLabel.font = .systemFont(ofSize: 12, weight: isActive ? .bold : .semibold)
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        documentIcon.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        hexView.isActive = isActive
    }

    // MARK: - Background operation (§14.4)

    /// The operation currently shown in this pane's status bar, or nil.
    private var currentOperation: BackgroundOperation?
    /// Token cancelling a delayed `beginOperation` reveal, so an operation that
    /// finishes before the debounce elapses never shows its bar.
    private var operationShowWorkItem: DispatchWorkItem?
    /// Debounce before the operation strip appears — a search on a small file
    /// finishes in a few milliseconds and must not flash a bar. A `var` so tests
    /// can shorten it instead of sleeping 0.5 s to outlast a private literal.
    static let defaultOperationDebounce: TimeInterval = 0.3
    static var operationDebounce: TimeInterval = defaultOperationDebounce

    /// Shows `op` in the status bar, replacing any previous operation. The
    /// reveal is debounced by `operationDebounce`, so an operation that
    /// finishes before then never appears; `endOperation()` cancels a pending
    /// reveal. Pass `revealImmediately` when moving an already-running
    /// operation onto this pane (the active pane changed) — skipping the
    /// debounce keeps the bar from blinking off and on.
    func beginOperation(_ op: BackgroundOperation, revealImmediately: Bool = false) {
        endOperation()
        currentOperation = op
        operationView.nameLabel.stringValue = op.name
        operationView.progressBar.doubleValue = op.progress
        operationView.onCancel = { [weak op] in op?.cancel() }
        // Progress and completion follow the op wherever it is presented; only
        // the pane that currently holds the op updates its bar.
        op.onProgress = { [weak self] fraction in
            self?.operationView.progressBar.doubleValue = fraction
        }
        op.onFinish = { [weak self] in
            guard let self, self.currentOperation === op else { return }
            self.endOperation()
        }
        if revealImmediately {
            operationView.isHidden = false
        } else {
            let token = DispatchWorkItem { [weak self, weak op] in
                guard let self, let op, self.currentOperation === op, op.isActive else { return }
                self.operationView.isHidden = false
            }
            operationShowWorkItem = token
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.operationDebounce, execute: token)
        }
    }

    /// Hides the operation strip and forgets the current operation (cancelling
    /// a pending debounced reveal).
    func endOperation() {
        operationShowWorkItem?.cancel()
        operationShowWorkItem = nil
        operationView.isHidden = true
        currentOperation = nil
    }

    /// Registers the pane as a drag destination (comparison mode only, §4.3).
    /// Single-file mode must NOT call this — the outer `SingleFileDropView`
    /// owns the drop there, and the deepest registered view would win and steal
    /// the drag.
    func enableFileDrop() {
        guard !dropEnabled else { return }
        dropEnabled = true
        wantsLayer = true
        layer?.cornerRadius = 4
        registerForDraggedTypes([.fileURL, .fileNames])
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = highlighted ? 3 : 0
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        // Chrome clicks (e.g. the header, reached here via the responder chain)
        // activate the pane through the same path as dump clicks: focus the hex
        // view, and `onFocus` fires `onActivate`. Focus stays the single source
        // of truth for the active pane (§3.3).
        focusHexView()
        super.mouseDown(with: event)
    }

    private func refresh() {
        hexView.textDecoder = viewModel.textDecoder
        hexView.reloadData()
        // The layout may have changed (offset digits, word size) — redraw the
        // header so its labels track the columns.
        columnHeader.needsDisplay = true
        hexView.revealCaret()
        updateHeader()
        updateStatus()
        // Structural changes (open/revert/undo/redo/insert/delete, save) can
        // shift every offset, so a stale results panel is hidden; the next
        // Search All rebuilds it (§11).
        hideSearchResults()
    }

    // MARK: - Search All results (§11)

    /// Shows the Search All results panel with every match of the pattern, read
    /// lazily from the pane's live storage so edits since the scan are
    /// reflected in the excerpts.
    func showSearchResults(matches: [Range<UInt64>], matchLength: Int) {
        searchResultsView.configure(
            matches: matches,
            byteProvider: { [weak viewModel] offset, length in
                guard let storage = viewModel?.byteStorage else { return [] }
                return (try? storage.read(at: offset, length: length)) ?? []
            },
            textDecoder: viewModel.textDecoder,
            fileSize: { [weak viewModel] in viewModel?.fileSize ?? 0 },
            matchLength: matchLength)
        searchResultsSplit.resultsPanelVisible = true
        applySearchResultsHeight()
    }

    /// Hides and clears the Search All results panel (the ×, or a structural
    /// change that invalidates the offsets). The divider moves to the very
    /// bottom — the delegate (now pinned by `resultsPanelVisible` == false)
    /// clamps it there, so the panel collapses to zero height and the dump
    /// reclaims the pane (§11). The panel is never `isHidden`; zero height is
    /// its native collapsed state.
    func hideSearchResults() {
        searchResultsSplit.resultsPanelVisible = false
        searchResultsView.clear()
        searchResultsSplit.setPanelHeight(0)
    }

    /// Gives the results panel the height the user last chose (or the built-in
    /// default), by placing the native divider accordingly. On the pane's first
    /// show of a session the stored height is clamped to the current room —
    /// never below the panel's minimum, never taller than a third of the pane's
    /// shared height, so the hex dump keeps at least two thirds and the panel
    /// never exceeds half the dump (§11) — because the stored value may date
    /// from a taller window or the other pane. Once the pane has shown the
    /// panel, a height the user picked by dragging in this session is applied
    /// as-is. The split's delegate would clamp the same `setPosition`, but
    /// clamping here keeps the restoration correct without depending on that
    /// implicit behavior.
    private func applySearchResultsHeight() {
        guard searchResultsSplit.resultsPanelVisible else { return }
        let total = searchResultsSplit.bounds.height
        guard total > 0 else { return }
        let stored = Self.defaults.object(forKey: Self.searchResultsHeightDefaultsKey) as? NSNumber
        let preferred = stored.map { CGFloat($0.doubleValue) } ?? SearchResultsView.panelHeight
        let height: CGFloat
        if hasRestoredPanelHeightThisSession {
            height = preferred
        } else {
            hasRestoredPanelHeightThisSession = true
            let room = max(FilePaneView.minSearchResultsHeight,
                           (total - searchResultsSplit.dividerThickness) / 3)
            height = min(max(preferred, FilePaneView.minSearchResultsHeight), room)
        }
        searchResultsSplit.setPanelHeight(height)
    }

    /// The selection-only counterpart of `refresh()`: the bytes are unchanged,
    /// so the hex view redraws just the affected rows, and only the status bar
    /// (whose offset/selection readout follows the caret) is updated. The
    /// header, layout, and column header are untouched (§3.3).
    private func refreshSelection() {
        hexView.reloadSelection()
        hexView.revealCaret()
        updateStatus()
    }

    /// The content-change counterpart of `refresh()`: the bytes changed (or the
    /// decoder rebuilt) but the layout did not, so the hex view redraws just the
    /// affected rows/columns and the caret-following chrome is refreshed — no
    /// `reloadData`, no column-header redraw (§3.3 extension).
    private func refreshContent(_ change: HexViewChange) {
        switch change {
        case .bytes:
            hexView.reloadContent(change)
            // The edit moved the caret/selection — redraw the rows the
            // selection now covers differently, and keep the caret on screen.
            hexView.reloadSelection()
            hexView.revealCaret()
            // The dirty glyph and the offset/selection readout follow the edit.
            updateHeader()
            updateStatus()
        case .textDecoding:
            // Assigning the decoder invalidates the decoded-text band in the
            // view (its `textDecoder` didSet).
            hexView.textDecoder = viewModel.textDecoder
        }
    }

    private func updateHeader() {
        let status = viewModel.status
        titleLabel.stringValue = status.fileName
        // The header's document glyph doubles as the modified marker (§3.4):
        // outline for a clean file, filled once there are unsaved changes —
        // replacing the "*" the title used to append. An untitled document
        // (File > New File, never saved) carries a plus badge to mark it as
        // new; it follows the same outline/fill convention, so the badge fills
        // once the buffer is edited. The status bar still spells out
        // "Modified" textually alongside (§15).
        let symbol: String
        if status.isUntitled {
            symbol = status.isDirty ? "document.badge.plus.fill" : "document.badge.plus"
        } else {
            symbol = status.isDirty ? "document.fill" : "document"
        }
        documentSymbolName = symbol
        documentIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if status.isUntitled {
            documentIcon.setAccessibilityLabel(status.isDirty ? "Modified new file" : "New file")
        } else {
            documentIcon.setAccessibilityLabel(status.isDirty ? "Modified file" : "File document")
        }
        lockLabel.stringValue = status.isReadOnly ? "🔒 Read-Only" : ""
        // VoiceOver names the grid after its file (§15).
        hexView.accessibilityTitle = "Hex dump — \(status.fileName)"
    }

    private func updateStatus() {
        let status = viewModel.status
        var parts: [String] = []
        parts.append("Offset \(status.cursorHex) (\(status.cursorDecimal))")
        if status.selectionLength > 0 {
            parts.append("\(status.selectionLength) selected")
        }
        parts.append(Self.friendlySize(status.fileSize))
        if status.isDirty {
            parts.append("Modified")
        }
        if status.isReadOnly {
            parts.append("Read-Only")
        }
        if !comparisonInfo.isEmpty {
            parts.append(comparisonInfo)
        }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
        updateTypingModeIndicator(status.isInsertMode)
    }

    /// INS/OVR (§7.6). Red for insert — the colour of its caret and of a byte
    /// the user has changed but not saved: in this app red means "this is not
    /// the file you opened", which is exactly what the mode is about.
    private func updateTypingModeIndicator(_ isInsertMode: Bool) {
        typingModeLabel.stringValue = isInsertMode ? "INS" : "OVR"
        typingModeLabel.textColor = isInsertMode ? HexTheme.insertCaretColor : .secondaryLabelColor
        typingModeLabel.setAccessibilityLabel(isInsertMode ? "Insert mode" : "Overwrite mode")
    }

    private static func friendlySize(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[index])
    }
}

// MARK: - Drag-and-drop (§4.3)

extension FilePaneView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropEnabled, !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        setDropHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        let urls = sender.draggingPasteboard.droppedFileURLs
        if !urls.isEmpty {
            onDropFiles?(urls)
        }
        return true
    }
}

// MARK: - Search All results split divider (§11)

extension FilePaneView: NSSplitViewDelegate {
    /// The divider's legal range. While the panel is shown, a drag (or a pane
    /// resize) never shrinks the hex dump below its minimum nor the results
    /// panel below its minimum. While hidden, both bounds pin the divider to
    /// the very bottom so the panel collapses to zero height (§11).
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        searchResultsSplit.resultsPanelVisible
            ? FilePaneView.minHexHeightInPane
            : splitView.bounds.height - splitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard searchResultsSplit.resultsPanelVisible else {
            return splitView.bounds.height - splitView.dividerThickness
        }
        return max(
            FilePaneView.minHexHeightInPane,
            splitView.bounds.height - FilePaneView.minSearchResultsHeight - splitView.dividerThickness
        )
    }

    /// The divider moved — a drag, a programmatic `setPosition`, or a pane
    /// resize — so the panel's new height becomes the user's preferred height
    /// for the next Search All. Only persisted while the panel is shown and
    /// within the legal range: NSSplitView can report transient layouts (e.g.
    /// mid-animation) whose panel height is absurd, and persisting those would
    /// poison the next reveal.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView, split === searchResultsSplit else { return }
        guard searchResultsSplit.resultsPanelVisible, split.arrangedSubviews.count == 2 else { return }
        let dumpHeight = split.arrangedSubviews[0].frame.height
        let panelHeight = split.bounds.height - dumpHeight - split.dividerThickness
        let legalMax = split.bounds.height - FilePaneView.minHexHeightInPane - split.dividerThickness
        guard panelHeight >= FilePaneView.minSearchResultsHeight,
              panelHeight <= legalMax else { return }
        Self.defaults.set(panelHeight, forKey: Self.searchResultsHeightDefaultsKey)
    }
}

// MARK: - Column header (§6)

/// The pinned column header above the hex dump: the column names — "Offset",
/// the sequential byte offsets "00".."0F" over the hex cells, and "Decoded
/// text" — in ink blue, separated from the rows by a thin rule.
///
/// Sits in the pane chrome above the scroll view, so it never scrolls
/// vertically; it mirrors the scroll view's horizontal offset so the labels
/// stay aligned with the columns as the dump scrolls sideways.
final class HexColumnHeaderView: NSView {
    /// The hex view supplying the grid geometry. The label positions come from
    /// `hexLayout`, the glyph ink from the same font/baseline as the rows.
    weak var hexView: HexView?

    /// The clip view's horizontal scroll offset; the drawing shifts left by it
    /// so each label tracks the column it names.
    var horizontalOffset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    /// The column names at the row's edges.
    private static let offsetTitle = "Offset"
    private static let asciiTitle = "Decoded text"

    /// The sequential byte offset shown above a hex cell: "00".."0F", one
    /// two-digit index per byte, aligned with the byte's cell (§6).
    private static func columnIndex(_ column: Int) -> String {
        String(format: "%02X", column)
    }

    /// Vertical padding above and below the labels. Without it the strip is one
    /// hex row tall and the ink — drawn at the row baseline — nearly touches the
    /// top and bottom edges (§6).
    static let verticalPadding: CGFloat = 4

    /// Height: one hex row plus symmetric top/bottom padding, so the labels
    /// have breathing room instead of hugging the strip's edges.
    var headerHeight: CGFloat { (hexView?.hexLayout.rowHeight ?? 17) + 2 * Self.verticalPadding }

    /// How many times the pane has told the header the grid geometry changed
    /// (word size / appearance). A test hook: `needsDisplay` isn't reliably
    /// readable in a headless test host, so tests assert this instead.
    private(set) var gridRefreshCount = 0

    /// Redraws the header because the underlying grid geometry changed (word
    /// size, appearance). The label positions are re-derived from
    /// `hexView.hexLayout` in `draw`, so a plain redraw is enough.
    func refreshForGridChange() {
        gridRefreshCount += 1
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let hexView else { return }
        let layout = hexView.hexLayout

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.translateBy(x: -horizontalOffset, y: 0)

        // The row baseline shifted down by the header's vertical padding, so
        // the ink stays centered in the taller strip.
        let baseline = hexView.hexBaseline + Self.verticalPadding
        draw(Self.offsetTitle, x: layout.offsetColumnFrame(row: 0).minX, baseline: baseline)
        for column in 0..<HexLayout.bytesPerRow {
            draw(Self.columnIndex(column), x: layout.hexByteX(column: column), baseline: baseline)
        }
        draw(Self.asciiTitle, x: layout.asciiX(column: 0), baseline: baseline)

        // Thin ink-blue rule separating the header from the dump.
        HexTheme.inkBlue.withAlphaComponent(0.35).setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        rule.line(to: NSPoint(x: layout.contentWidth, y: bounds.height - 0.5))
        rule.lineWidth = 1
        rule.stroke()
    }

    private func draw(_ text: String, x: CGFloat, baseline: CGFloat) {
        guard let font = hexView?.hexFont else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: HexTheme.inkBlue,
        ]
        (text as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: attributes)
    }

    /// The frames the labels are drawn into (view coordinates, already shifted
    /// by `horizontalOffset`): the offset title, one frame per byte-offset
    /// index (each as wide as a byte cell), and the ASCII title. Exposed
    /// (internal) for tests.
    func labelFrames() -> (offset: CGRect, columns: [CGRect], ascii: CGRect) {
        let layout = hexView?.hexLayout ?? HexLayout(charWidth: 8, rowHeight: 17)
        let shift = -horizontalOffset
        let height = headerHeight
        let columns = (0..<HexLayout.bytesPerRow).map { column in
            CGRect(x: layout.hexByteX(column: column) + shift, y: 0,
                   width: layout.hexByteWidth, height: height)
        }
        return (
            CGRect(x: layout.offsetColumnFrame(row: 0).minX + shift, y: 0,
                   width: layout.offsetColumnWidth, height: height),
            columns,
            CGRect(x: layout.asciiX(column: 0) + shift, y: 0,
                   width: layout.asciiColumnWidth, height: height)
        )
    }
}

// MARK: - Background operation strip (§14.4)

/// The status-bar strip for one background operation: a name label, a
/// bar-style determinate progress indicator, and a (×) cancel button. Shown by
/// `FilePaneView.beginOperation(_:)`, hidden by `endOperation()`.
final class OperationStatusView: NSView {
    let nameLabel = NSTextField(labelWithString: "")
    let progressBar = NSProgressIndicator()
    /// The (×) button. Tests drive cancellation through it.
    let cancelButton = NSButton()
    /// Fired when the user clicks (×); wired to `BackgroundOperation.cancel()`.
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 120).isActive = true

        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel operation")
        cancelButton.isBordered = false
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.setAccessibilityLabel("Cancel operation")  // §15
        cancelButton.toolTip = "Cancel operation"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(progressBar)
        stack.addArrangedSubview(cancelButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}
