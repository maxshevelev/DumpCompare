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

    /// What the rows on screen describe, so a refill can tell a different
    /// subject from the same one re-read. Nil while the placeholder is up.
    private var shownSubject: String?

    /// The panel's rows are rebuilt by their own module when the zoom moves;
    /// the placeholder is this view's own text, so it re-reads the size here.
    private var zoomObserver: NSObjectProtocol?

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

        placeholder.font = ToolPanelFont.body()
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

        // The side insets break rather than fight a panel squeezed to zero
        // width, which is what a closed tool panel is. Required, the two of
        // them ask a 0-point-wide list for 20 points, and AppKit recovers by
        // striking one of them out — for good. The list then had no width to
        // follow, so a panel later dragged narrower laid its rows out for the
        // width it used to have.
        let sideInsets = [
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
        ]
        sideInsets.forEach { $0.priority = .defaultHigh }

        // The placeholder's own margins, breakable for the same reason: it
        // cannot be kept 10 points clear of both edges of a list that is not
        // 20 points wide, and a required pair there is a constraint AppKit
        // strikes out to recover.
        let placeholderInsets = [
            placeholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: document.leadingAnchor, constant: 10
            ),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: document.trailingAnchor, constant: -10
            ),
        ]
        placeholderInsets.forEach { $0.priority = .defaultHigh }

        // The list follows the clip view's width, down to a floor: a pane of a
        // split is laid out by frame, and its first one — before the split has
        // a size of its own — is nothing at all. A row is a name, six points
        // and a value, which does not fit in nothing however low the
        // priorities inside it are, so the engine strikes one of the row's own
        // constraints out to recover. Under the floor a scroll view does what
        // it is for and clips.
        let followsTheClip = document.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor
        )
        followsTheClip.priority = .required - 1

        NSLayoutConstraint.activate(sideInsets + [
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            followsTheClip,
            document.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            document.heightAnchor.constraint(
                greaterThanOrEqualTo: contentView.heightAnchor
            ),
            fitsTheClip,

            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            // What never gives: the rows stay inside the list.
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            document.bottomAnchor.constraint(
                greaterThanOrEqualTo: content.bottomAnchor, constant: 8
            ),

            placeholder.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: document.centerYAnchor),
        ] + placeholderInsets)

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.placeholder.font = ToolPanelFont.body()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    /// Empties the rows and shows `text` in their place.
    public func showPlaceholder(_ text: String) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.stringValue = text
        placeholder.isHidden = false
        shownSubject = nil
    }

    /// Empties the rows and hides the placeholder, ready to be refilled with
    /// the rows describing `subject` — a row's index, a node's path, whatever
    /// the panel calls the thing in focus.
    ///
    /// The scroll goes back to the first row only when `subject` is not what
    /// is already on screen. A panel re-reads and re-renders for reasons that
    /// have nothing to do with the user: an edit anywhere in the dump costs a
    /// re-parse, and resetting on every refill would throw a reader back to
    /// the top of the detail they were part-way through. A *different* subject
    /// is the opposite — its first field is where the reader wants to be, not
    /// wherever the last subject had been scrolled to.
    public func prepareForRows(subject: String) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.isHidden = true
        guard subject != shownSubject else { return }
        shownSubject = subject
        documentView?.scroll(.zero)
    }
}
