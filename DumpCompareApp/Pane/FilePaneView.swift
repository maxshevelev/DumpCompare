import Cocoa
import ALSplitView

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
    ///
    /// The *split's* rectangle, not the scroll view's, so the Search All results
    /// panel is not one of the things that pushes it around (§11). The panel is
    /// transient chrome laid over the lower part of the dump; the map mirrors the
    /// file, and shrinking it because a panel opened would rescale the whole map
    /// — every mark and the viewport band with it — for something that is about
    /// to close again. The split spans what the dump owns whether or not the
    /// panel is showing, which is the honest span for the map to match.
    var dumpAreaInWindow: NSRect? {
        guard window != nil else { return nil }
        return searchResultsSplit.convert(searchResultsSplit.bounds, to: nil)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    /// The field that stands in the title's place while the name is being
    /// edited (§23), or nil when it is not. Built on demand and gone when the
    /// edit ends: a header holds a label, and only briefly something else.
    private var nameEditor: NSTextField?
    /// Set when Escape ended the edit, so the field's closing does not write
    /// what was typed. Read and cleared by `endRenaming`.
    private var renameWasCancelled = false
    /// The document glyph before the file name: "document" while the file is
    /// clean, "document.fill" once there are unsaved changes (§3.4). Tinted to
    /// match the title so it reads as part of the header, not as a button.
    private let documentIcon = NSImageView()
    /// The SF Symbol the header glyph is currently showing ("document" or
    /// "document.fill"). NSImage doesn't report a system symbol's name, so the
    /// pane tracks it for tests and VoiceOver.
    private(set) var documentSymbolName = "document"
    private let lockLabel = NSTextField(labelWithString: "")
    /// The status bar's main readout. Internal (not private) so a test can read
    /// the rendered string, the way `typingModeLabel` is.
    let statusLabel = NSTextField(labelWithString: "")
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
    /// (§11).
    ///
    /// A controller owns it, because where it appears is a choice: the pane
    /// arranges it in a split view today, and the same panel should be able to
    /// go in a window of its own (see `SearchResultsViewController`). The pane
    /// still decides its height and its divider — that is this pane's
    /// arrangement of its own chrome, not the panel's business.
    let searchResults: SearchResultsViewController


    /// The dump and the results panel share the pane through an `ALSplitView`:
    /// the dump is the `.fill` pane and the panel a `.fixed` one, so the panel
    /// keeps the height the user chose while the dump absorbs window resizes.
    /// Hiding the panel fixes it at zero height, so the dump reclaims the full
    /// height (§11). Internal so tests can assert the collapse and the resized
    /// height.
    let searchResultsSplit = ALSplitView()

    /// Whether the Search All results panel is shown. Drives the split's
    /// divider clamp: while hidden, the clamp pins the divider to the very
    /// bottom so the panel sits at zero height and the dump reclaims the pane
    /// (§11).
    private(set) var searchResultsPanelVisible = false

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

    /// The narrowest a pane may be squeezed to in a side-by-side comparison
    /// (§3.3): room for the header's document glyph — the 10-point leading
    /// inset, the 14-point glyph, and the 6-point gap the title would have had.
    ///
    /// A pane pushed all the way to zero disappears: nothing left on screen says
    /// the second file is still open, and getting it back means catching a
    /// divider that is now flush against the window's edge — or against the
    /// minimap's own divider, which is easy to grab by mistake. Keeping the glyph
    /// visible keeps the pane both findable and grabbable, and it is the least
    /// that can be shown to say "this is still here".
    static let minPaneWidth: CGFloat = 30

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
    /// the hex dump's Offset column — the "Select Block from Here at «address»" menu — given
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
    /// Fired when this pane's own drag session begins and ends.
    ///
    /// A pane drag is the application's business, not one window's: any window
    /// can receive it, so every window's New Tab strip goes up for its duration.
    /// The source is the only participant guaranteed to see both ends of the
    /// session — a destination that declined the drag may never be told it is
    /// over.
    var onDragSessionChanged: ((Bool) -> Void)?

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
        // Made with the pane, so the panel never has to ask who it belongs to.
        self.searchResults = SearchResultsViewController(pane: viewModel)
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
        // owned by the split view, not by this content.
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

        // An `xmark` symbol rather than a "✕" character: the glyph is the
        // system's, so it lines up with the rest of the chrome and scales with
        // the interface instead of being a 10 pt letter. The default button type
        // dims it while it is held; `.momentaryChange` swapped in an
        // `alternateTitle` that was never set, so a press showed nothing.
        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
                ?? NSImage(),
            target: self,
            action: #selector(closeTapped)
        )
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        closeButton.setAccessibilityLabel("Close pane")
        closeButton.toolTip = "Close pane"
        closeButton.contentTintColor = .secondaryLabelColor

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onDoubleClick = { [weak self] in
            self?.onHeaderDoubleClick?()
        }
        header.onDragThresholdPassed = { [weak self] event in
            self?.beginPaneDrag(with: event)
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
        // The horizontal chain is breakable end to end: a pane dragged to zero
        // is squeezed below the ~34pt the insets and spacings need, and a
        // required link in the chain would floor the pane (the least-squares
        // solver compromises at the chain's minimum instead of letting the
        // pane reach zero). At any real width every link holds exactly (§3.4).
        let headerChain: [NSLayoutConstraint] = [
            documentIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: documentIcon.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockLabel.leadingAnchor, constant: -6),
            lockLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
        ]
        for constraint in headerChain { constraint.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            documentIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            lockLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
        ])
        NSLayoutConstraint.activate(headerChain)

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
        // flips. Its resistance beats the status text's, so a narrowing pane
        // truncates the status text first; both stay below required, so the
        // split — which sets a pane's frame outright — can still squeeze a
        // pane dragged to zero down to zero. The indicator is simply the last
        // thing to compress.
        typingModeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        typingModeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        typingModeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
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
        // The side insets are breakable, like the header's: a pane dragged to
        // zero is squeezed below the 20pt the insets need, and a required inset
        // would then floor the pane (the least-squares solver compromises at the
        // insets' minimum instead of letting the pane reach zero). At any real
        // width the insets hold exactly (§3.4).
        let statusLeadingInset = statusStack.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10)
        let statusTrailingInset = statusStack.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10)
        statusLeadingInset.priority = .defaultHigh
        statusTrailingInset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            statusLeadingInset,
            statusTrailingInset,
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
        // pane vertically through an ALSplitView. Its divider resizes the
        // panel with the standard drag behaviour and cursor; the panel is
        // collapsed (fixed at zero height) while no results are shown and
        // revealed with the user's stored height on a Search All.
        searchResults.onClose = { [weak self] in
            guard let self else { return }
            // Stop the owner's in-flight search first, then hide and forget the
            // results — a closed panel must not keep receiving matches (§11).
            self.onSearchResultsClose?(self)
            self.hideSearchResults()
        }
        searchResults.onSelect = { [weak self] range in
            guard let self else { return }
            // Selecting a result mirrors a single Find match (§11): the range
            // is selected in the hex view and scrolled to the vertical centre.
            self.viewModel.select(range: range)
            self.hexView.revealSelectionCentered()
            self.focusHexView()
        }

        searchResultsSplit.isVertical = false
        searchResultsSplit.dividerThickness = 1
        searchResultsSplit.translatesAutoresizingMaskIntoConstraints = false
        searchResultsSplit.addPane(scrollView)
        searchResultsSplit.addPane(searchResults.view)
        // The dump fills whatever the panel doesn't take; the panel starts
        // collapsed at zero height, so the dump gets the whole pane until a
        // Search All shows results (§11).
        searchResultsSplit.setPaneLayout(.fill, at: 0)
        searchResultsSplit.setPaneLayout(.fixed(0), at: 1)
        // The clamp owns the divider's legal range (§11): while the panel is
        // shown, a drag never shrinks the hex dump below its minimum nor the
        // results panel below its minimum; while hidden, both bounds pin the
        // divider to the very bottom so the panel collapses to zero height.
        searchResultsSplit.clampDividerPosition = { [weak self] _, position in
            guard let self else { return position }
            let total = self.searchResultsSplit.bounds.height
            let thickness = self.searchResultsSplit.dividerThickness
            guard self.searchResultsPanelVisible else {
                return max(0, total - thickness)
            }
            let minDump = FilePaneView.minHexHeightInPane
            let maxDump = max(minDump, total - FilePaneView.minSearchResultsHeight - thickness)
            return min(max(position, minDump), maxDump)
        }
        // A divider move — a drag or a programmatic sizing — makes the panel's
        // new height the user's preferred height for the next Search All
        // (§11).
        searchResultsSplit.onDividerMoved = { [weak self] _, position in
            self?.persistSearchResultsPanelHeight(position: position)
        }

        // The header and column header are pinned at the top; the split view and
        // the status bar fill the rest. Pinning the header and column header
        // directly (each has a required height constraint) forces the split
        // view to take exactly the leftover height.
        addSubview(header)
        addSubview(columnHeader)
        addSubview(searchResultsSplit)
        addSubview(statusBar)

        // The one link in the vertical chain that yields. The chrome above the
        // dump is 76 points of required heights — header, column header, status
        // bar — and a pane can be shorter than that: squeezed to nothing by the
        // splitter (§3.3), or laid out before its window has a size. Nothing is
        // legible at that height either way, so the chrome keeps its sizes and
        // the bottom pin lets it overflow, instead of the solver breaking a
        // constraint of its choosing and saying so on every layout pass.
        //
        // 999, not 750: it must still outrank the split view's content
        // compression resistance at any real height, where the whole system is
        // satisfiable and the status bar belongs on the bottom edge. Same
        // reasoning as the header's breakable horizontal chain above.
        let bottomPin = statusBar.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomPin.priority = NSLayoutConstraint.Priority(999)

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
            bottomPin,
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
        viewModel.onChange = { [weak self] center in
            self?.refresh(center: center)
        }
        // A pure selection move (drag, click, keyboard): the bytes are
        // unchanged, so redraw only the rows the selection now covers
        // differently instead of the whole pane (§3.3).
        viewModel.onSelectionChanged = { [weak self] reveal in
            self?.refreshSelection(reveal: reveal)
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
        // It never scrolls: a content change does not move the caret, so the
        // caret reveal is left to the selection and full channels (§10.4).
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

    /// Shows the cut popover (§21.3). The pane view presents it because the
    /// anchor rect is the hex view's to give — the controller says which offset
    /// it starts at, which offsets are already cut, and what the two keys mean.
    ///
    /// With `anchoredToOffset` (the default, Split Here at «address») the popover hangs off the
    /// byte it is pre-filled with, and that byte is scrolled into view first if it
    /// is not there: a popover has to point at something the user can see. With it
    /// off (Add Cut…) the popover is centred in the pane's visible area instead of
    /// stuck to the caret — the offset is still pre-filled with the caret's, but
    /// the popover is a dialog, not a pointer.
    @discardableResult
    func presentCutEditPopover(
        prefillOffset: UInt64, fileSize: UInt64,
        isAlreadyACut: @escaping (UInt64) -> Bool,
        onCommit: @escaping (UInt64, String) -> Void,
        anchoredToOffset: Bool = true
    ) -> CutEditPopoverController {
        let controller = CutEditPopoverController(
            prefillOffset: prefillOffset, fileSize: fileSize,
            isAlreadyACut: isAlreadyACut, onCommit: onCommit
        )
        if anchoredToOffset {
            if !hexView.visibleByteRange().contains(prefillOffset) {
                hexView.revealOffsetCentered(prefillOffset)
                // The scroll has to land before the anchor rect is read, or the
                // popover points at where the caret used to be.
                scrollView.contentView.layoutSubtreeIfNeeded()
            }
            // The popover hangs off the byte it is pre-filled with — the
            // right-clicked byte for Split Here at «address» (§21.3).
            controller.show(relativeTo: hexView.byteCellRect(for: prefillOffset), of: hexView)
        } else {
            // Add Cut…: centred in the pane's visible area, not stuck to the
            // caret (§21.3). The visible rect is in the hex view's own
            // coordinates, so it is already the anchor's coordinate space.
            let visible = scrollView.documentVisibleRect
            controller.show(
                relativeTo: NSRect(x: visible.midX, y: visible.midY, width: 1, height: 1),
                of: hexView)
        }
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

    private func refresh(center: Bool = false) {
        hexView.textDecoder = viewModel.textDecoder
        hexView.reloadData()
        // The layout may have changed (offset digits, word size) — redraw the
        // header so its labels track the columns.
        columnHeader.needsDisplay = true
        hexView.revealCaret(center: center)
        updateHeader()
        updateStatus()
        // Structural changes (open/revert/undo/redo/insert/delete, save) can
        // shift every offset, so a stale results panel is hidden; the next
        // Search All rebuilds it (§11).
        hideSearchResults()
    }

    // MARK: - Search All results (§11)

    /// Makes room for the Search All results panel and opens it, empty, for the
    /// scan that is about to fill it.
    ///
    /// What the panel *shows* is its own controller's business, including how a
    /// row reads the pane's live bytes. What is left here is what the pane
    /// arranges: that the panel is on screen at all, and how tall it is (§11).
    func showSearchResults(matchLength: Int) {
        searchResults.beginSearch(matchLength: matchLength)
        searchResultsPanelVisible = true
        applySearchResultsHeight()
    }

    /// Hides and clears the Search All results panel (the ×, or a structural
    /// change that invalidates the offsets). The divider moves to the very
    /// bottom — the split's clamp (now pinned by `searchResultsPanelVisible`
    /// == false) holds it there, so the panel collapses to zero height and the
    /// dump reclaims the pane (§11). The panel is never `isHidden`; zero
    /// height is its collapsed state.
    func hideSearchResults() {
        searchResultsPanelVisible = false
        searchResults.clear()
        setSearchResultsPanelHeight(0)
    }

    /// Moves the divider so the results panel gets `height` points (clamped to
    /// the pane's room by the split's divider clamp). The same code path a
    /// divider drag takes, so programmatic sizing and user dragging behave
    /// identically.
    func setSearchResultsPanelHeight(_ height: CGFloat) {
        let total = searchResultsSplit.bounds.height
        guard total > 0 else { return }
        searchResultsSplit.setDividerPosition(
            total - height - searchResultsSplit.dividerThickness)
    }

    /// Persists the panel's current height as the user's preferred height for
    /// the next Search All. Only while the panel is shown and within the legal
    /// range: a transient layout (e.g. mid-animation) whose panel height is
    /// absurd would poison the next reveal if persisted.
    private func persistSearchResultsPanelHeight(position: CGFloat) {
        guard searchResultsPanelVisible else { return }
        let split = searchResultsSplit
        let panelHeight = split.bounds.height - position - split.dividerThickness
        let legalMax = split.bounds.height - FilePaneView.minHexHeightInPane - split.dividerThickness
        guard panelHeight >= FilePaneView.minSearchResultsHeight,
              panelHeight <= legalMax else { return }
        Self.defaults.set(panelHeight, forKey: Self.searchResultsHeightDefaultsKey)
    }

    /// Gives the results panel the height the user last chose (or the built-in
    /// default), by placing the divider accordingly. On the pane's first
    /// show of a session the stored height is clamped to the current room —
    /// never below the panel's minimum, never taller than a third of the pane's
    /// shared height, so the hex dump keeps at least two thirds and the panel
    /// never exceeds half the dump (§11) — because the stored value may date
    /// from a taller window or the other pane. Once the pane has shown the
    /// panel, a height the user picked by dragging in this session is applied
    /// as-is. The split's divider clamp would clamp the same move, but
    /// clamping here keeps the restoration correct without depending on that
    /// implicit behavior.
    private func applySearchResultsHeight() {
        guard searchResultsPanelVisible else { return }
        let total = searchResultsSplit.bounds.height
        guard total > 0 else { return }
        let stored = Self.defaults.object(forKey: Self.searchResultsHeightDefaultsKey) as? NSNumber
        let preferred = stored.map { CGFloat($0.doubleValue) } ?? SearchResultsViewController.panelHeight
        let height: CGFloat
        if hasRestoredPanelHeightThisSession {
            height = preferred
        } else {
            hasRestoredPanelHeightThisSession = true
            let room = max(FilePaneView.minSearchResultsHeight,
                           (total - searchResultsSplit.dividerThickness) / 3)
            height = min(max(preferred, FilePaneView.minSearchResultsHeight), room)
        }
        setSearchResultsPanelHeight(height)
    }

    /// The selection-only counterpart of `refresh()`: the bytes are unchanged,
    /// so the hex view redraws just the affected rows, and only the status bar
    /// (whose offset/selection readout follows the caret) is updated. The
    /// header, layout, and column header are untouched (§3.3).
    private func refreshSelection(reveal: PaneViewModel.SelectionReveal = .follow) {
        hexView.reloadSelection()
        switch reveal {
        case .follow: hexView.revealCaret(center: false)
        case .center: hexView.revealCaret(center: true)
        case .stay: break
        }
        updateStatus()
    }

    /// The content-change counterpart of `refresh()`: the bytes changed (or the
    /// decoder rebuilt) but the layout did not, so the hex view redraws just the
    /// affected rows/columns and the caret-following chrome is refreshed — no
    /// `reloadData`, no column-header redraw (§3.3 extension). It never scrolls:
    /// a content change does not move the caret, so revealing it is the
    /// selection and full channels' job (§10.4).
    private func refreshContent(_ change: HexViewChange) {
        switch change {
        case .bytes:
            hexView.reloadContent(change)
            // The edit may have changed the selection's shape — redraw the rows
            // it now covers differently.
            hexView.reloadSelection()
            // The dirty glyph and the offset/selection readout follow the edit.
            updateHeader()
            updateStatus()
        case .textDecoding:
            // Assigning the decoder invalidates the decoded-text band in the
            // view (its `textDecoder` didSet).
            hexView.textDecoder = viewModel.textDecoder
        }
    }

    /// Fired whenever the header's picture of its file changed — the name, the
    /// untitled badge, the dirty glyph. The window's title says the same thing
    /// about the same files, so it rides this rather than a signal of its own:
    /// whatever keeps the header honest keeps the title honest, and there is no
    /// second list of places to remember to update.
    var onHeaderChanged: (() -> Void)?

    // MARK: - Dragging the pane by its header

    /// The pill is carried at its drawn size. It is a plate with a file name on
    /// it, and a name that has to be squinted at says nothing worth carrying —
    /// leaving its pane is already visible from the pill leaving the pane.
    static let paneDragMinWidth: CGFloat = 200

    /// The widest the pill gets. Past this the name truncates rather than the
    /// pill stretching across the screen.
    static let paneDragMaxWidth: CGFloat = 260

    /// The pill's size, given the width of what goes on it — the document glyph,
    /// the gap after it, and the name.
    ///
    /// Height is the header's: the pill is not scaled at all, so the shape stays
    /// the shape the pane wears, which is what makes it recognisable in flight.
    /// Width fits the content between its paddings, floored so a two-letter name
    /// still gets a plate rather than a lozenge, and capped so a long one
    /// truncates. Pure, so the arithmetic is checked without drawing anything.
    static func paneDragPillSize(contentWidth: CGFloat, height: CGFloat) -> NSSize {
        let padded = contentWidth + paneDragTextInset * 2
        let width = min(paneDragMaxWidth, max(paneDragMinWidth, padded))
        return NSSize(width: width, height: height)
    }

    /// The gap between the content and the pill's rounded ends.
    static let paneDragTextInset: CGFloat = 16

    /// The gap between the document glyph and the name.
    static let paneDragIconGap: CGFloat = 6

    /// Picks the pane up: a dragging session carrying nothing but this pane's
    /// identity (`Design/PANE_DRAG_PLAN.md`).
    private func beginPaneDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(viewModel.dragID.uuidString, forType: .pane)
        let dragItem = NSDraggingItem(pasteboardWriter: item)

        let image = paneDragPill()
        let size = image.size
        // Centred on the pointer, so the pill goes where the hand goes rather
        // than trailing from wherever in the header the press landed.
        let point = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(
            NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                   width: size.width, height: size.height),
            contents: image)

        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        // One item, and it is already where it should be: without this AppKit
        // is free to re-arrange the drag's contents into a formation of its own.
        session.draggingFormation = .none
        // The cancel animation is kept, and it does not land where the header
        // is. Two facts about AppKit, both established by watching it rather
        // than by reading it:
        //
        // - **The return position is screen coordinates, fixed when the item's
        //   frame is set** — not a live view-relative frame. `draggingFrame` is
        //   given in the source view's space, but it is resolved to the screen
        //   there and then. So when the New Tab strip opens and pushes the panes
        //   down, the recorded point stays where the header *was*, which by then
        //   is where the strip is.
        // - **`endedAt` arrives after the flight, not at the mouse-up.** So the
        //   strip cannot be collapsed in time to meet the pill; the panes rise
        //   after it has landed, whatever the collapse is timed to.
        //
        // Left as it is, deliberately. Turning the animation off is the honest
        // alternative and was tried; keeping the panes still during a pane drag
        // (the strip overlaying instead of displacing) would fix the target but
        // brings back the covered headers that displacing was introduced to
        // solve. Retargeting mid-flight through `enumerateDraggingItems` is the
        // third option and the least safe: `draggingFrame` also governs where
        // the image sits under the cursor.
    }

    /// The pill the hand carries: the pane's document glyph and file name on an
    /// opaque rounded plate with a hairline edge.
    ///
    /// Drawn rather than snapshotted. The header's own picture is text on
    /// nothing — over a dump it reads as a smear of letters with no object
    /// behind them, and there is nothing to see the edge of when it crosses into
    /// another pane. The glyph is the header's own, so a modified or untitled
    /// pane is still recognisable as itself while it is in flight.
    private func paneDragPill() -> NSImage {
        let name = viewModel.status.fileName
        let paragraph = NSMutableParagraphStyle()
        // Middle truncation: the tail of a dump's name is what tells two apart
        // (`…_donor.bin` against `…_board.bin`), so it is the middle that goes.
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let height = max(24, header.bounds.height)
        let icon = paneDragGlyph()
        let iconWidth = icon?.size.width ?? 0
        let gap = icon == nil ? 0 : Self.paneDragIconGap
        let nameSize = (name as NSString).size(withAttributes: attributes)
        let size = Self.paneDragPillSize(contentWidth: iconWidth + gap + nameSize.width,
                                         height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        // The window's appearance, not whatever is current: the pill is drawn
        // once and carried, so its colours have to be resolved against the theme
        // it was picked up in (§3.2).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let pill = NSBezierPath(roundedRect: rect,
                                    xRadius: rect.height / 2, yRadius: rect.height / 2)
            // Near-opaque: enough of the dump shows through to say the pill is
            // over it, not enough for the two to be read together.
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            pill.fill()
            NSColor.separatorColor.setStroke()
            pill.lineWidth = 1
            pill.stroke()

            // Glyph and name are centred together, so a short name sits in the
            // middle of the minimum-width plate rather than clinging to its left
            // end. A name too long for the plate takes what is left and
            // truncates inside it.
            let budget = size.width - Self.paneDragTextInset * 2 - iconWidth - gap
            let textWidth = min(nameSize.width, budget)
            let contentWidth = iconWidth + gap + textWidth
            var x = (size.width - contentWidth) / 2
            if let icon {
                icon.draw(in: NSRect(x: x, y: (size.height - icon.size.height) / 2,
                                     width: icon.size.width, height: icon.size.height))
                x += iconWidth + gap
            }
            (name as NSString).draw(
                with: NSRect(x: x, y: (size.height - nameSize.height) / 2,
                             width: textWidth, height: nameSize.height),
                options: [.usesLineFragmentOrigin], attributes: attributes)
        }
        image.unlockFocus()
        return image
    }

    /// The header's document glyph, tinted for the pill. A template image draws
    /// as a mask, so it is filled rather than simply drawn.
    private func paneDragGlyph() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: documentSymbolName,
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
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
        onHeaderChanged?()
    }

    private func updateStatus() {
        let status = viewModel.status
        // Every address in the bar takes the same width: the hex digits of the
        // file's largest address — the last piece's exclusive end, which can be
        // the file's own size — so the offset and the segment's bounds read as
        // aligned columns, zero-padded to that width (§21.3).
        let width = status.fileSize > 0 ? String(status.fileSize, radix: 16).count : 1
        func address(_ value: UInt64) -> String {
            String(value, radix: 16, uppercase: true).leftPadded(to: width, with: "0")
        }
        var parts: [String] = []
        parts.append("Offset \(address(status.cursorOffset))")
        if status.selectionLength > 0 {
            // The selection's length, abbreviated and rounded to a whole value
            // of its unit, like the file size beside it (§3.4): "255 KB
            // selected", not "262144 selected".
            parts.append("\(Self.friendlySize(status.selectionLength)) selected")
        }
        // The caret's piece, beside the offset (§21.3): one block,
        // "S1: <start>-<end> (length)" — bare hex, no 0x prefix, zero-padded to
        // the bar's address width. Absent when the pane is one piece — its
        // appearing is the signal the dump is partitioned.
        if let seg = status.segment {
            parts.append("\(seg.label): \(address(seg.range.lowerBound))-\(address(seg.range.lastByte)) (\(Self.friendlySize(UInt64(seg.range.count))))")
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

    /// The app's byte-size format ("8 B", "255 KB", "4 MB") — whole values of
    /// the abbreviation, rounded, shared with the status bar's segment readout
    /// (§21.3) and the Segments form's size column (§21.4).
    static func friendlySize(_ bytes: UInt64) -> String {
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
        // Rounded to a whole value of the abbreviation: "255 KB", not "255.5 KB".
        // The loop leaves value < 1024, so the only way rounding reaches 1024 is
        // the last half-unit, which rolls up to one of the next unit.
        let rounded = Int(value.rounded())
        if rounded >= 1024, index < units.count - 1 {
            return "1 \(units[index + 1])"
        }
        return "\(rounded) \(units[index])"
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

// MARK: - Renaming an unsaved document in place (§23)

extension FilePaneView: NSTextFieldDelegate {
    /// Whether a name is being edited right now — the header shows a field
    /// rather than its title.
    var isRenaming: Bool { nameEditor != nil }

    /// The name field's current text, for a test to read and set.
    var renameFieldForTesting: NSTextField? { nameEditor }

    /// Starts renaming in place: the title becomes a field in the same spot,
    /// carrying the name the header was showing, with all of it selected.
    ///
    /// In place rather than in a dialog because the name is one short string and
    /// the header is where it is read — a sheet to type a filename into would be
    /// a window's worth of ceremony for a label. The pane's own file menu is
    /// what opens it (Rename), so the gesture is the one the Finder taught.
    func beginRenaming() {
        guard viewModel.canRename, nameEditor == nil else { return }
        let field = NSTextField(string: viewModel.status.fileName)
        field.font = titleLabel.font
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("File name")
        field.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(field)
        // Where the title is, and no narrower than a name can be read in. Every
        // link breakable, like the rest of the header's chain (§3.4): a pane
        // squeezed to nothing must still be able to reach nothing.
        let placement = [
            field.leadingAnchor.constraint(equalTo: documentIcon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(lessThanOrEqualTo: lockLabel.leadingAnchor,
                                            constant: -6),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            field.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 20),
        ]
        for constraint in placement { constraint.priority = .defaultHigh }
        NSLayoutConstraint.activate(placement)
        titleLabel.isHidden = true
        nameEditor = field
        renameWasCancelled = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Ends the edit: writes the name unless Escape cancelled it, takes the
    /// field away and gives the title back.
    ///
    /// The model refuses a name that is empty once trimmed, or one that has not
    /// changed — so a field closed on an accident leaves the header as it was
    /// rather than blanking it.
    func endRenaming(commit: Bool) {
        guard let field = nameEditor else { return }
        let typed = field.stringValue
        // Cleared first: taking the field away makes it resign, which comes back
        // here through the delegate, and a second pass would rename again.
        nameEditor = nil
        field.delegate = nil
        let wasFirstResponder = field.currentEditor() != nil
        field.removeFromSuperview()
        titleLabel.isHidden = false
        if commit, !renameWasCancelled, viewModel.rename(to: typed) {
            updateHeader()
        }
        renameWasCancelled = false
        // The dump takes focus back, the way it has it everywhere else — a pane
        // whose field just vanished must not leave the window with no responder.
        if wasFirstResponder { focusHexView() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking away, or anything else that takes the focus, is a commit:
        // the Finder's rename behaves this way, and the alternative — losing
        // what was typed to a stray click — is the worse surprise.
        endRenaming(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endRenaming(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            renameWasCancelled = true
            endRenaming(commit: false)
            return true
        default:
            return false
        }
    }
}

extension FilePaneView: NSDraggingSource {
    /// A pane can be moved or copied, and only inside this app: outside it the
    /// drag means nothing, so it is offered nothing to mean.
    ///
    /// Both are offered so AppKit can narrow the mask to `.copy` while Option is
    /// held — that is how the modifier reaches the destinations, and how they
    /// know to say "Duplicate" instead of "Move".
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragSessionChanged?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // First thing, so the panes start rising while the pill is still in the
        // air rather than after it has landed.
        onDragSessionChanged?(false)
    }
}

