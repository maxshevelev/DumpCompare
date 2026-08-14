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

    /// Margin added to `hexContentWidth` so the grid doesn't sit flush against
    /// the pane edge / scroller. Shared by zoom-to-fit and the header
    /// double-click fit-to-content-width (§3.3).
    static let contentFitSlack: CGFloat = 16

    /// Width this pane needs to show its hex content without a horizontal
    /// scroller: content plus slack (§3.3).
    var contentFitWidth: CGFloat { hexContentWidth + Self.contentFitSlack }

    private let titleLabel = NSTextField(labelWithString: "")
    private let lockLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

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
            header.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Status bar
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        // Same as the header: stay flexible so a narrow pane can shrink it.
        statusBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBar.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])

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

    // MARK: - Binding

    private func bind() {
        hexView.dataSource = viewModel
        hexView.delegate = viewModel
        viewModel.onChange = { [weak self] in
            self?.refresh()
        }
    }

    /// Makes the hex view first responder (e.g. when the pane becomes active).
    func focusHexView() {
        window?.makeFirstResponder(hexView)
    }

    /// Highlights the header to mark this pane as active (§3.3).
    func setActive(_ isActive: Bool) {
        titleLabel.font = .systemFont(ofSize: 12, weight: isActive ? .bold : .semibold)
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
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
        onActivate?()
        super.mouseDown(with: event)
    }

    private func refresh() {
        hexView.reloadData()
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
