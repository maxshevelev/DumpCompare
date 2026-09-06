import Cocoa

/// The tool-module panel's chrome: a header naming the tool-module and the file
/// it is working on, a close button, and the tool-module's own view below
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// The header exists to answer one question the panel would otherwise leave
/// open — *which* file this is. A session is bound to the pane it was opened
/// for and does not follow the active pane, so in a comparison the panel and
/// the pane the user is typing in can be different files, and what the header
/// names is where the tool-module's writes go.
///
/// The panel hosts a view controller it does not own: the tool-module builds
/// it, this holds it, and swapping tool-modules swaps the view.
final class ToolPanelView: NSView {
    /// Fired by the header's ✕. The same thing as Tools ▸ None.
    var onClose: (() -> Void)?

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let bottomSeparator = NSView()
    private let trailingSeparator = NSView()
    /// Where the tool-module's view goes.
    private let body = NSView()

    /// The chrome's height, matching the pane's title bar so the panel's body
    /// starts level with the dump beside it.
    static let headerHeight: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        // A hidden panel is a zero-width pane, not a hidden view — the same
        // rule the minimap panel follows (§19.1) — and an `NSView` does not
        // clip its subviews, so without this the header's labels would paint
        // over the dump beside the panel while the panel itself is nothing but
        // a sliver.
        wantsLayer = true
        layer?.masksToBounds = true

        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        // The file name is what gives way first when the panel is narrow: the
        // tool-module's name is the shorter of the two and the one that says
        // what the panel is.
        fileLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close the tool panel"
        closeButton.setAccessibilityLabel("Close the tool panel")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        for separator in [bottomSeparator, trailingSeparator] {
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }

        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(body)
        addSubview(trailingSeparator)
        header.addSubview(titleLabel)
        header.addSubview(fileLabel)
        header.addSubview(closeButton)
        header.addSubview(bottomSeparator)

        // The side insets break rather than fight a panel squeezed to zero
        // width, for the reason the minimap panel's do (§19.2): a collapsed
        // panel is a legal state and must not log a constraint conflict every
        // time it is reached.
        let leading = titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8)
        leading.priority = .defaultHigh
        let gap = fileLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6)
        gap.priority = .defaultHigh
        let trailing = closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6)
        trailing.priority = .defaultHigh
        let toClose = fileLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                                          constant: -6)
        toClose.priority = .defaultHigh

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            leading, gap, trailing, toClose,
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            fileLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            bottomSeparator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),

            // The panel's own edge against the dump. The split view draws a
            // divider there too, but it is a drag target rather than a rule.
            trailingSeparator.topAnchor.constraint(equalTo: topAnchor),
            trailingSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingSeparator.widthAnchor.constraint(equalToConstant: 1),

            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingSeparator.leadingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func closeClicked() {
        onClose?()
    }

    /// What the header says: the tool-module, and the file its session is bound
    /// to.
    func setTitle(_ title: String, fileName: String) {
        titleLabel.stringValue = title
        fileLabel.stringValue = fileName
    }

    /// The tool-module's view, or nil to empty the panel. The panel constrains
    /// it to fill the body; the tool-module decides everything inside it.
    func setContent(_ view: NSView?) {
        for existing in body.subviews { existing.removeFromSuperview() }
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }

    /// What the panel is showing, for the tests that ask.
    var contentView: NSView? { body.subviews.first }
    var title: String { titleLabel.stringValue }
    var fileName: String { fileLabel.stringValue }
}
