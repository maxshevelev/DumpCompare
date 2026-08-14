import Cocoa

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
    /// Fired when the comparison-mode close button is clicked.
    var onClose: (() -> Void)?

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
        lockLabel.font = .systemFont(ofSize: 12)
        lockLabel.textColor = .secondaryLabelColor

        let closeButton = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.setButtonType(.momentaryChange)
        closeButton.toolTip = "Close pane"
        closeButton.contentTintColor = .secondaryLabelColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
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
        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
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
