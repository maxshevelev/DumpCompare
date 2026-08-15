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

    private let titleLabel = NSTextField(labelWithString: "")
    private let lockLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// The pinned column header above the dump ("Offset" / "Hex" / "Decoded
    /// text"). It sits outside the scroll view, so it never scrolls vertically,
    /// and mirrors the horizontal scroll to stay aligned with the columns (§6).
    private let columnHeader = HexColumnHeaderView()
    private var columnHeaderScrollObserver: NSObjectProtocol?
    /// The status-bar strip for the running background operation (name +
    /// progress bar + ×), hidden while idle (§14.4). Internal so tests can
    /// assert the debounced reveal / hide.
    let operationView = OperationStatusView()

    /// Extra status text appended on the right (e.g. "Indexing… 42%" or diff
    /// counts in comparison mode). Set by ComparisonView/MainViewController.
    var comparisonInfo: String = "" {
        didSet { updateStatus() }
    }

    /// Fired when the user clicks anywhere in the pane (activates it).
    var onActivate: (() -> Void)?
    /// Fired when the user double-clicks the header: expand this pane so its
    /// hex content fits by width (§3.3).
    var onHeaderDoubleClick: (() -> Void)?
    /// Fired when the comparison-mode close button is clicked.
    var onClose: (() -> Void)?
    /// Fired with the dropped file URLs (comparison-mode drops target this pane,
    /// §4.3). Only active after `enableFileDrop()`.
    var onDropFiles: (([URL]) -> Void)?

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
        lockLabel.font = .systemFont(ofSize: 12)
        lockLabel.textColor = .secondaryLabelColor

        let closeButton = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.setButtonType(.momentaryChange)
        closeButton.toolTip = "Close pane"
        closeButton.contentTintColor = .secondaryLabelColor

        let header = PaneHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onDoubleClick = { [weak self] in
            self?.onHeaderDoubleClick?()
        }
        // Low priorities keep this container flexible so a narrow pane
        // (§3.3) can shrink it and truncate the title instead of forcing a
        // minimum width.
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(titleLabel)
        header.addSubview(lockLabel)
        header.addSubview(closeButton)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        lockLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
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
        columnHeader.heightAnchor.constraint(equalToConstant: columnHeader.headerHeight).isActive = true
        columnHeaderScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.columnHeader.horizontalOffset = self?.scrollView.contentView.bounds.origin.x ?? 0
        }

        // Scrollable hex view.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = hexView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Same reason as the header/status bar: the pane's width is owned by
        // the NSSplitView, never by this content (§3.3).
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(columnHeader)
        stack.addArrangedSubview(scrollView)
        stack.addArrangedSubview(statusBar)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    deinit {
        if let columnHeaderScrollObserver {
            NotificationCenter.default.removeObserver(columnHeaderScrollObserver)
        }
    }

    // MARK: - Binding

    private func bind() {
        hexView.dataSource = viewModel
        hexView.delegate = viewModel
        // Focus is the single source of truth for the active pane (§3.3):
        // clicking the dump makes the hex view first responder, which fires
        // `onActivate`, so the highlighted pane and the typing target never
        // diverge.
        hexView.onFocus = { [weak self] in
            self?.onActivate?()
        }
        viewModel.onChange = { [weak self] in
            self?.refresh()
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
        hexView.isActive = isActive
    }

    // MARK: - Background operation (§14.4)

    /// The operation currently shown in this pane's status bar, or nil.
    private var currentOperation: BackgroundOperation?
    /// Token cancelling a delayed `beginOperation` reveal, so an operation that
    /// finishes before the debounce elapses never shows its bar.
    private var operationShowWorkItem: DispatchWorkItem?
    /// Debounce before the operation strip appears — a search on a small file
    /// finishes in a few milliseconds and must not flash a bar.
    private static let operationDebounce: TimeInterval = 0.3

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
        hexView.reloadData()
        // The layout may have changed (offset digits, word size) — redraw the
        // header so its labels track the columns.
        columnHeader.needsDisplay = true
        hexView.revealCaret()
        updateHeader()
        updateStatus()
    }

    private func updateHeader() {
        let status = viewModel.status
        let dirtyStar = status.isDirty ? "*" : ""
        titleLabel.stringValue = "\(status.fileName)\(dirtyStar)"
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

    /// Height: one hex row, so the header reads as a pinned first row.
    var headerHeight: CGFloat { hexView?.hexLayout.rowHeight ?? 17 }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let hexView else { return }
        let layout = hexView.hexLayout

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.translateBy(x: -horizontalOffset, y: 0)

        let baseline = hexView.hexBaseline
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
