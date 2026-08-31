import Cocoa

/// One table cell: a label that fills the cell and is updated per column on
/// reuse. The excerpt reaches the label whole; the label's single-line mode
/// renders it on exactly one line, truncating the tail with "…" against the
/// column's current width (§11).
final class SearchResultCellView: NSTableCellView {
    /// The label's inset from each side of the cell. Read by the column sizing,
    /// so a value's measured width and the room it gets cannot drift apart.
    static let labelInset: CGFloat = 4

    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = AppearanceSettings.font()
        // A result value must never wrap onto a second line. Single-line mode
        // is the standard SDK guarantee: an attributed string without an
        // explicit paragraph style would otherwise render with the default
        // word-wrapping (ignoring the field's own lineBreakMode) and grow the
        // row taller. With single-line mode the text always stays on one line,
        // truncating at the tail with "…" when the column is too narrow — and
        // it re-truncates automatically as the column resizes (§11).
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.labelInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var attributedText: NSAttributedString {
        get { label.attributedStringValue }
        set { label.attributedStringValue = newValue }
    }
}
