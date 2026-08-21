import Cocoa

/// The popover that names a bookmark (§20.3), in the shape Xcode gives a
/// breakpoint: it appears on the mark the moment the mark appears, with the
/// caret already in the Name field, and the keyboard finishes the job —
/// **Return** saves, **Esc** backs out. That is what makes ⌘D, Return a single
/// gesture for "mark this row" and ⌘D, a name, Return one for "mark it and call
/// it this".
///
/// A popover, not a modal sheet: naming a row is an aside to reading a dump, and
/// the mark it is attached to has to stay visible while the name is typed.
///
/// What the two keys mean depends on why the popover opened, so the caller says:
/// `onCommit` takes the typed name, `onCancel` undoes whatever opening it did —
/// removing a mark just created, or leaving an existing name alone. Closing the
/// popover any other way (a click outside it) commits, because by then the mark
/// is already on the row and dropping the typed name would be the surprise.
@MainActor
final class BookmarkNamePopoverController: NSViewController, NSTextFieldDelegate {
    /// Internal so tests can type into it; the popover cannot be driven by a
    /// synthesized key event without a real key window.
    private(set) var nameField: NSTextField!

    private let row: UInt64
    private let initialName: String
    private let creating: Bool
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void

    /// The popover this controller is shown in, so committing or cancelling can
    /// close it. Weak: the popover owns the controller.
    private weak var popover: NSPopover?

    /// Set by the first of commit/cancel to win, so the close that follows —
    /// and `popoverDidClose`, which commits by default — cannot run a second
    /// outcome on the same popover.
    private var settled = false

    /// - Parameters:
    ///   - row: the row being named, shown in the title — which is also what an
    ///     unnamed bookmark will be called (§20.2).
    ///   - existingName: the name to edit, or nil when the mark was just created
    ///     — which is also what makes Esc mean "remove it again".
    init(row: UInt64, existingName: String?,
         onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.row = row
        self.initialName = existingName ?? ""
        self.creating = existingName == nil
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let address = Bookmark.addressLabel(row)

        let title = NSTextField(labelWithString: "Bookmark at \(address)")
        title.font = .boldSystemFont(ofSize: 13)

        let label = NSTextField(labelWithString: "Name")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // A plain field: AppKit selects its whole text on focus, which is what a
        // name wants — the popover opens with the current name ready to be
        // replaced (unlike the offset sheets, whose "0x" is a prefix to type
        // after, §10).
        let field = NSTextField(string: initialName)
        field.font = .systemFont(ofSize: 12)
        // "Optional", not the address: the title line above already says which
        // row this is, and an empty name is exactly how a bookmark ends up being
        // called by that address (§20.2).
        field.placeholderString = "Optional"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        field.setAccessibilityLabel("Bookmark name")
        nameField = field

        let fieldRow = NSStackView(views: [label, field])
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .firstBaseline
        fieldRow.spacing = 8

        // The keys, spelled out: Esc does different things to a new mark and to
        // an existing name, and the popover is where that has to be said.
        let hint = NSTextField(labelWithString: creating
            ? "Return saves. Esc removes the bookmark."
            : "Return saves. Esc keeps the current name.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, fieldRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 108))
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The caret goes straight into the field: ⌘D, Return has to work without
        // a click, and typing a name has to work without a Tab.
        view.window?.makeFirstResponder(nameField)
    }

    // MARK: - Presenting

    /// Shows the popover pointing at `rect` in `view` — the mark's own body, so
    /// the popover is visibly about that row (§20.3).
    @discardableResult
    func show(relativeTo rect: CGRect, of view: NSView) -> NSPopover {
        // Load the field before handing the controller to the popover: the
        // popover would load it when it displays, and everything below — the
        // caret, the name it starts with — assumes it exists.
        loadViewIfNeeded()
        let popover = NSPopover()
        popover.contentViewController = self
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        return popover
    }

    // MARK: - Outcomes

    /// Saves the typed name and closes. The store normalizes it, so trailing
    /// spaces and a name of nothing but spaces are already handled (§20.2).
    func commit() {
        guard !settled else { return }
        settled = true
        onCommit(nameField.stringValue)
        popover?.performClose(nil)
    }

    /// Backs out: removes a mark that was created for this popover, or leaves an
    /// existing name as it was.
    func cancel() {
        guard !settled else { return }
        settled = true
        onCancel()
        popover?.performClose(nil)
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}

extension BookmarkNamePopoverController: NSPopoverDelegate {
    /// A popover dismissed by anything but the two keys — a click outside it,
    /// the window losing focus — keeps what was typed. The mark is already on
    /// the row by then, so committing is the quiet outcome and throwing the name
    /// away would not be.
    func popoverDidClose(_ notification: Notification) {
        guard !settled else { return }
        settled = true
        onCommit(nameField.stringValue)
    }
}
