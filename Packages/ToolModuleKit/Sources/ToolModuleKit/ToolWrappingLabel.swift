import AppKit

/// A label that wraps inside whatever width the layout gives it.
///
/// An `NSTextField` decides how tall it wants to be from
/// `preferredMaxLayoutWidth`, and nothing sets that for a label whose width is
/// decided by constraints — so a multi-line label in a stack either stays one
/// long line or reports a height for a width it does not have. This one reads
/// its own laid-out width back into that property and asks for a new height
/// when it changes, which is the standard way round it.
///
/// It is a *label*: word-wrapping, no line limit, selectable text left to the
/// caller. A table cell must never use it — a cell that wraps grows past its
/// row and draws over the rows around it (see `ToolPanelTable.makeCell`).
@MainActor public final class ToolWrappingLabel: NSTextField {
    public init(string: String) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        stringValue = string
        // The two that make it a paragraph rather than a line.
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        // The width belongs to the layout, the height to the text: give the
        // width up readily and never let the height be squeezed.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override public func layout() {
        super.layout()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}
