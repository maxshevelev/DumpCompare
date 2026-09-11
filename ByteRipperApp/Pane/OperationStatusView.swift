import Cocoa

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
        // Breakable: a pane dragged toward zero must be able to compress the
        // strip — a required 120 pt bar would floor the whole pane at its
        // width. At any real width the bar keeps its 120 pt.
        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 120)
        barWidth.priority = .defaultHigh
        barWidth.isActive = true

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
