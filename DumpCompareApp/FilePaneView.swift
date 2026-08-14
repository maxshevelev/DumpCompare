import Cocoa

/// One file pane (§3.4, §15): a header (file name, `*` dirty, read-only lock),
/// the virtualized hex dump, and a status bar.
///
/// In single-file mode this fills the client area; in comparison mode (M5) two
/// of these sit side by side. The pane owns no model logic — it binds a
/// `PaneViewModel` to the hex view and mirrors its `onChange` into the chrome.
final class FilePaneView: NSView {
    let viewModel: PaneViewModel

    private let hexView: HexView
    private let titleLabel = NSTextField(labelWithString: "")
    private let lockLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(viewModel: PaneViewModel) {
        self.viewModel = viewModel
        self.hexView = HexView()
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

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(lockLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        lockLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockLabel.leadingAnchor, constant: -6),
            lockLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            lockLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
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
        let scrollView = NSScrollView()
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
        titleLabel.textColor = status.isDirty ? .labelColor : .secondaryLabelColor
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
