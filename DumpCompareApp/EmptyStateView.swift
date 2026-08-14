import Cocoa

/// Placeholder shown in empty mode (§3.1): an Open File button, a drag hint,
/// and drag-and-drop support (§4.3 empty mode).
final class EmptyStateView: NSView {
    /// Fired with the dropped file URLs; the view controller applies §4.3 rules.
    var onOpenFiles: (([URL]) -> Void)?

    init() {
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 4

        let openButton = NSButton(
            title: "Open File",
            target: nil,
            action: #selector(MainViewController.presentOpenPanel)
        )
        openButton.bezelStyle = .rounded

        let hintLabel = NSTextField(labelWithString:
            "Drag and drop files here to open them.\nUp to two files can be compared side by side."
        )
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: 13)

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(openButton)
        stackView.addArrangedSubview(hintLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        registerForDraggedTypes([.fileURL, .fileNames])
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = highlighted ? 3 : 0
    }
}

// NSView already conforms to NSDraggingDestination (empty defaults); we override
// the members. Only registered destination views receive drag callbacks.
extension EmptyStateView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
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
            onOpenFiles?(urls)
        }
        return true
    }
}
