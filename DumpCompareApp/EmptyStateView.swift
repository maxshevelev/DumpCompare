import Cocoa

/// Placeholder shown in empty mode (§3.1): an Open File button and a drag hint.
final class EmptyStateView: NSView {
    init() {
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
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
    }
}
