import Cocoa
import DumpCompareCore

/// The popover that edits a bookmark (§20.3), in the shape Xcode gives a
/// breakpoint: it appears on the mark the moment the mark appears, with the caret
/// already in the Name field, and the keyboard finishes the job — **Return**
/// saves, **Esc** backs out. That is what makes ⌘D, Return a single gesture for
/// "mark this row" and ⌘D, a name, Return one for "mark it and call it this".
///
/// Two lines hold everything a bookmark is: **where** it is and **what it is
/// called**. The offset is a field rather than a title, so the address can be
/// corrected here too — a mark put a row off is fixed by typing the right
/// address, the same way it is fixed by dragging the mark (§20.6), and without
/// losing the name.
///
/// A popover, not a modal sheet: naming a row is an aside to reading a dump, and
/// the mark it is attached to has to stay visible while the name is typed.
///
/// What the two keys mean depends on why the popover opened, so the caller says:
/// `onCommit` takes the row and the name, `onCancel` undoes whatever opening it
/// did — removing a mark just created, or leaving an existing bookmark alone.
/// Closing the popover any other way (a click outside it) commits, because by
/// then the mark is already on the row and dropping the typed name would be the
/// surprise.
@MainActor
final class BookmarkEditPopoverController: NSViewController, NSTextFieldDelegate {
    /// Internal so tests can type into them; a popover cannot be driven by a
    /// synthesized key event without a real key window.
    private(set) var offsetField: NSTextField!
    private(set) var nameField: NSTextField!

    /// The row the popover opened on — where the bookmark is now.
    let row: UInt64

    private let initialName: String
    /// Whether a row may take this bookmark: false for a row another bookmark
    /// already holds, since one row holds one bookmark (§20.1). The mark's own
    /// row is always available to it.
    private let rowIsFree: (UInt64) -> Bool
    private let onCommit: (UInt64, String) -> Void
    private let onCancel: () -> Void

    /// What a refused Return sounds like. A closure so a test can hear it: a
    /// beep leaves no trace of its own.
    var beep: () -> Void = { NSSound.beep() }

    /// The popover this controller is shown in, so committing or cancelling can
    /// close it. Weak: the popover owns the controller.
    private weak var popover: NSPopover?

    /// Set by the first of commit/cancel to win, so the close that follows —
    /// and `popoverDidClose`, which commits by default — cannot run a second
    /// outcome on the same popover.
    private var settled = false

    /// - Parameters:
    ///   - row: the row the bookmark is on, which the Offset field starts at.
    ///   - existingName: the name to edit, or nil when the mark was just created
    ///     — which is also what makes Esc mean "remove it again".
    init(row: UInt64, existingName: String?,
         rowIsFree: @escaping (UInt64) -> Bool = { _ in true },
         onCommit: @escaping (UInt64, String) -> Void, onCancel: @escaping () -> Void) {
        self.row = row
        self.initialName = existingName ?? ""
        self.rowIsFree = rowIsFree
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // The address in the shape the dialogs write one (§10), in the dump's own
        // font: this field is read far more often than it is edited, so it has to
        // read as an address first and behave as a field second.
        let offset = NSTextField(string: Bookmark.addressLabel(row))
        offset.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        offset.delegate = self
        offset.translatesAutoresizingMaskIntoConstraints = false
        offset.setAccessibilityLabel("Bookmark offset")
        offsetField = offset

        // A plain field: AppKit selects its whole text on focus, which is what a
        // name wants — the popover opens with the current name ready to be
        // replaced. Its placeholder says what the field is for, so the field
        // needs no label beside it and can have the popover's whole width.
        let name = NSTextField(string: initialName)
        name.font = .systemFont(ofSize: 12)
        name.placeholderString = "Name"
        name.delegate = self
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setAccessibilityLabel("Bookmark name")
        nameField = name

        // Two lines and nothing else: where the bookmark is, and what it is
        // called. Return and Esc are not spelled out — a popover with two fields
        // is not where the keyboard needs explaining, and the panel stays the
        // size of its job.
        let stack = NSStackView(views: [offset, name])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 84))
        root.addSubview(stack)
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
            // Both fields span the popover, inside the stack's own insets: the
            // longest thing a name can be is the width there is.
            offset.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset),
        ])
        view = root
    }

    /// The popover's width. Fixed rather than fitted: a panel that resized itself
    /// around the address it is naming would jitter from row to row.
    private static let width: CGFloat = 300

    override func viewDidAppear() {
        super.viewDidAppear()
        // The caret goes straight into the NAME, in both jobs: ⌘D, Return has to
        // work without a click, typing a name has to work without a Tab, and the
        // address is already right — it is there to be corrected, not filled in.
        // AppKit selects a plain field's whole text on focus, so an existing
        // name arrives selected and typing replaces it rather than appending —
        // the opposite of what the offset sheets want from their "0x" prefix,
        // and the reason the Name field is a plain NSTextField (§20.3).
        view.window?.makeFirstResponder(nameField)
    }

    // MARK: - Presenting

    /// Shows the popover pointing at `rect` in `view` — the mark's own body, so
    /// the popover is visibly about that row (§20.3).
    @discardableResult
    func show(relativeTo rect: CGRect, of view: NSView) -> NSPopover {
        // Load the fields before handing the controller to the popover: the
        // popover would load them when it displays, and everything below — the
        // caret, the name it starts with — assumes they exist.
        loadViewIfNeeded()
        let popover = NSPopover()
        popover.contentViewController = self
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        return popover
    }

    // MARK: - The offset field

    /// The row the Offset field currently names, or nil when it names none: the
    /// text does not parse as an offset (§10), or it lands on a row another
    /// bookmark already holds — one row holds one bookmark (§20.1), so that is
    /// as invalid as a typo.
    var editedRow: UInt64? {
        guard let offset = try? OffsetParser.parse(offsetField.stringValue) else { return nil }
        let candidate = BookmarkStore.row(containing: offset)
        guard candidate == row || rowIsFree(candidate) else { return nil }
        return candidate
    }

    /// Validation as the address is typed, as everywhere else an offset is typed
    /// (§10.1) — but shown in the field itself rather than in a message: a panel
    /// this small has no room for a sentence, and red digits in a field of digits
    /// say the same thing. Return refuses while they are red.
    private func updateOffsetValidation() {
        offsetField.textColor = editedRow == nil ? .systemRed : .labelColor
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject?) === offsetField else { return }
        updateOffsetValidation()
    }

    // MARK: - Outcomes

    /// Saves the row and the typed name and closes. The store normalizes the
    /// name, so trailing spaces and a name of nothing but spaces are already
    /// handled (§20.2). An address that names no row refuses: the field is
    /// already red, so the key only owes an answer that it was heard.
    func commit() {
        guard !settled else { return }
        guard let target = editedRow else {
            beep()
            return
        }
        settled = true
        onCommit(target, nameField.stringValue)
        popover?.performClose(nil)
    }

    /// Closes without saving and without undoing: the mark this was editing is
    /// gone. ⌘D reaches the menu through an open popover, so the row can be
    /// unmarked while its name is being typed — and a panel editing a bookmark
    /// that no longer exists is nonsense (§20.3). Neither callback runs: there
    /// is nothing to name and nothing to take back.
    func abandon() {
        guard !settled else { return }
        settled = true
        popover?.performClose(nil)
    }

    /// Backs out: removes a mark that was created for this popover, or leaves an
    /// existing bookmark exactly as it was — address and name.
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

extension BookmarkEditPopoverController: NSPopoverDelegate {
    /// A popover dismissed by anything but the two keys — a click outside it,
    /// the window losing focus — keeps what was typed. The mark is already on
    /// the row by then, so committing is the quiet outcome and throwing the name
    /// away would not be. An address that names no row is the one thing not
    /// kept: the bookmark stays on the row it was on, with the name.
    func popoverDidClose(_ notification: Notification) {
        guard !settled else { return }
        settled = true
        onCommit(editedRow ?? row, nameField.stringValue)
    }
}
