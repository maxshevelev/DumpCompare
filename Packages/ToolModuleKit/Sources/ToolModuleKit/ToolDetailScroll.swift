import AppKit

/// A panel's scrolling detail: a column of label/value rows that starts at the
/// top, is as wide as the visible area, and scrolls only once it outgrows it.
///
/// Both firmware tool-modules show one under their table, and the AppKit recipe
/// behind it is wrong by default in three ways that all look like "the panel is
/// broken" rather than like a layout mistake:
///
/// - A document view with no constraints tying it to the clip view has no size
///   the engine can solve for, so it logs a conflict and lands on whatever
///   number falls out.
/// - A document view is **not flipped**, so a scroll view shows the *bottom* of
///   content taller than itself: rows pinned to the visual top end up above the
///   visible area, and the panel looks empty until the user scrolls up.
/// - Content shorter than the visible area leaves the document either too tall
///   (a placeholder centred in it sits below the fold) or too short to fill the
///   box behind it.
///
/// So the whole of it lives here once: the document is flipped, pinned to the
/// clip view on three sides, at least as tall as the visible area and taller
/// only when the rows need it.
@MainActor public final class ToolDetailScroll: NSScrollView {
    /// The rows. A panel empties it and refills it on every selection.
    public let content = NSStackView()

    /// What stands in for the rows when there are none — centred in the
    /// *visible* area, because the document is exactly the visible area's
    /// height whenever the rows do not overflow it.
    public let placeholder = NSTextField(labelWithString: "")

    /// A flipped document, so the scroll view starts at the first row rather
    /// than the last.
    private final class TopDownView: NSView {
        override var isFlipped: Bool { true }
    }

    public init() {
        super.init(frame: .zero)

        hasVerticalScroller = true
        // No horizontal scroller: the rows are pinned to the visible width, so
        // there is never anything to the side to reach.
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .bezelBorder
        translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 3
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setHuggingPriority(.defaultHigh, for: .vertical)

        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 2
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        document.addSubview(placeholder)
        documentView = document

        // The document is only ever as tall as it has to be: at least the
        // visible height, so the placeholder is centred in what the user can
        // see and the box behind the rows is filled, and taller than that only
        // when the rows themselves ask for it.
        let fitsTheClip = document.heightAnchor.constraint(
            equalTo: contentView.heightAnchor
        )
        fitsTheClip.priority = .defaultLow

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            document.heightAnchor.constraint(
                greaterThanOrEqualTo: contentView.heightAnchor
            ),
            fitsTheClip,

            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            document.bottomAnchor.constraint(
                greaterThanOrEqualTo: content.bottomAnchor, constant: 8
            ),

            placeholder.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            placeholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: document.leadingAnchor, constant: 10
            ),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: document.trailingAnchor, constant: -10
            )
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Empties the rows and shows `text` in their place.
    public func showPlaceholder(_ text: String) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.stringValue = text
        placeholder.isHidden = false
    }

    /// Empties the rows and hides the placeholder, ready to be refilled. Also
    /// puts the scroll back at the first row: the rows that follow describe a
    /// different thing than the ones just removed, and an offset kept from
    /// those would open the new detail part-way down.
    public func prepareForRows() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.isHidden = true
        documentView?.scroll(.zero)
    }
}
