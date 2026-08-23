import Cocoa
import DumpCompareCore

/// The popover that makes a cut (§21.3): a field for **where** the cut goes
/// and a field for **what the piece that starts there is called**. The offset
/// is pre-filled with the caret's and validated as it is typed (§10.1) — a cut
/// at 0, at EOF, or on a seam another cut already holds leaves the field red,
/// and Return refuses it with a beep rather than committing.
///
/// A popover, not a modal sheet: the dump has to stay visible while the offset
/// is typed, and the caret the field starts from has to stay under the eye.
///
/// What the two keys mean is fixed by what the popover is for: **Return**
/// makes the cut, **Esc** backs out. Unlike the bookmark's, this popover
/// *creates* what it names — nothing exists on the file until it commits — so
/// Esc and a click outside it simply close it. A click outside still commits
/// when the offset is legal, the way the bookmark's does: the user opened the
/// popover to make a cut, typed it, and clicked away, so the cut is the quiet
/// outcome; a red field is the one thing not kept, and it closes without
/// cutting.
@MainActor
final class CutEditPopoverController: NSViewController, NSTextFieldDelegate {
    /// Internal so tests can type into them; a popover cannot be driven by a
    /// synthesized key event without a real key window.
    private(set) var offsetField: NSTextField!
    private(set) var descriptionField: NSTextField!

    /// The offset the field starts at — the caret's for a cut opened from the
    /// dump, the piece's own start for an edit. Nil for a cut opened from the
    /// Segments form's `+`, where the field starts empty ("0x") and the offset
    /// is the thing to be filled in (§21.4).
    private let prefillOffset: UInt64?
    /// The name the description field starts with — empty for a new cut, the
    /// piece's current name for an edit, so editing a named piece does not open
    /// blank (§21.4).
    private let prefillDescription: String
    /// Which field the caret goes to on open: the offset for a new cut (the
    /// offset is the thing to be filled in), the description for an edit (the
    /// offset is already right, the name is the thing to change). Internal so a
    /// test can read the decision the focus makes — the handoff itself needs a
    /// key window a headless host has not got (§20.5's lesson).
    let focusOffset: Bool
    /// Whether an offset is a legal cut for this popover — the bounds (0 and
    /// EOF) and any seam another cut already holds for a *new* cut, the interval
    /// the cut bounds for a *move* (the current offset legal, so the field opens
    /// not red). The popover checks it as the offset is typed (§10.1); Return
    /// refuses while it says no.
    private let validate: (UInt64) -> Bool
    private let onCommit: (UInt64, String) -> Void
    /// Called when the popover is dismissed without committing — Esc, or a click
    /// outside with a red field — so the presenter that opened it can forget it
    /// (the bookmark's editor does the same for its own, §20.3).
    private let onCancel: (() -> Void)?

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

    /// The popover that makes a cut (§21.3): a legal cut is strictly inside the
    /// file and not on a seam another cut already holds — every piece must stay
    /// non-empty (§21.2).
    /// - Parameters:
    ///   - prefillOffset: the offset the field starts at — the caret's, or nil
    ///     for a field that opens empty ("0x") and waits to be filled.
    ///   - fileSize: the pane's file size, which bounds a legal cut.
    ///   - isAlreadyACut: whether an offset another cut already holds.
    ///   - prefillDescription: the name the description field starts with.
    ///   - focusOffset: whether the caret goes to the offset field on open —
    ///     true for a field that opens empty, where the offset is the thing to
    ///     be filled in; false (the default) for a pre-filled offset, where the
    ///     description is.
    ///   - onCommit: the cut's offset and the name for the piece that starts
    ///     there.
    init(prefillOffset: UInt64?, fileSize: UInt64,
         isAlreadyACut: @escaping (UInt64) -> Bool,
         prefillDescription: String = "",
         focusOffset: Bool = false,
         onCommit: @escaping (UInt64, String) -> Void,
         onCancel: (() -> Void)? = nil) {
        self.prefillOffset = prefillOffset
        self.prefillDescription = prefillDescription
        self.focusOffset = focusOffset
        self.validate = { offset in
            offset > 0 && offset < fileSize && !isAlreadyACut(offset)
        }
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    /// The popover that edits a piece (§21.4): the offset is judged by `validate`
    /// — for a move, the interval the cut bounds (the current offset legal, so
    /// the field opens not red); for S0, locked to 0, so only the name changes.
    /// - Parameters:
    ///   - prefillOffset: the offset the field starts at — the piece's start.
    ///   - validate: whether an offset is a legal cut here.
    ///   - prefillDescription: the name the description field starts with — the
    ///     piece's current name, so editing a named piece does not open blank.
    ///   - focusOffset: whether the caret goes to the offset field on open —
    ///     false (the default) for an edit, where the description is the thing
    ///     to change.
    ///   - onCommit: the cut's offset and the name for the piece that starts
    ///     there.
    init(prefillOffset: UInt64,
         validate: @escaping (UInt64) -> Bool,
         prefillDescription: String = "",
         focusOffset: Bool = false,
         onCommit: @escaping (UInt64, String) -> Void,
         onCancel: (() -> Void)? = nil) {
        self.prefillOffset = prefillOffset
        self.prefillDescription = prefillDescription
        self.focusOffset = focusOffset
        self.validate = validate
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // The address in the shape the dialogs write one (§10), in the dump's
        // own font: this field is read far more often than it is edited, so it
        // has to read as an address first and behave as a field second. A cut
        // opened from the Segments form's `+` starts empty — just the "0x" the
        // user types over — because the offset is the thing to be filled in.
        let offsetText = prefillOffset.map { String(format: "0x%X", $0) } ?? "0x"
        let offset = OffsetField(string: offsetText)
        offset.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        offset.delegate = self
        offset.translatesAutoresizingMaskIntoConstraints = false
        offset.setAccessibilityLabel("Cut offset")
        offsetField = offset

        // A plain field: AppKit selects its whole text on focus, which is what
        // a name wants — the popover opens with the field ready to be filled.
        // Its placeholder says what the field is for, so the field needs no
        // label beside it and can have the popover's whole width. An edit opens
        // with the piece's current name, so renaming does not start from blank.
        let description = NSTextField(string: prefillDescription)
        description.font = .systemFont(ofSize: 12)
        description.placeholderString = "Description"
        description.delegate = self
        description.translatesAutoresizingMaskIntoConstraints = false
        description.setAccessibilityLabel("Segment description")
        descriptionField = description

        // Two lines: where the cut goes, and what the piece is called. Return
        // and Esc are not spelled out — a popover with two fields is not where
        // the keyboard needs explaining.
        let stack = NSStackView(views: [offset, description])
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
            description.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset),
        ])
        view = root
    }

    /// The popover's width. Fixed rather than fitted: a panel that resized
    /// itself around the address it is naming would jitter from cut to cut.
    private static let width: CGFloat = 300

    override func viewDidAppear() {
        super.viewDidAppear()
        // The caret goes straight into the field that is the thing to be filled
        // in: the DESCRIPTION when the offset is already right (a cut from the
        // dump, an edit — "type, Return" makes a named cut without a click), the
        // OFFSET when it opens empty (the Segments form's `+`), where the offset
        // is what has to be typed.
        view.window?.makeFirstResponder(focusOffset ? offsetField : descriptionField)
    }

    // MARK: - Presenting

    /// Shows the popover pointing at `rect` in `view` — the caret's own cell,
    /// so the popover is visibly about where the cut will land (§21.3).
    @discardableResult
    func show(relativeTo rect: CGRect, of view: NSView) -> NSPopover {
        // Load the fields before handing the controller to the popover: the
        // popover would load them when it displays, and everything below — the
        // caret, the offset it starts with — assumes they exist.
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

    /// The offset the Offset field currently names, or nil when it names none:
    /// the text does not parse as an offset (§10), or `validate` says it is not
    /// a legal cut here.
    var editedOffset: UInt64? {
        guard let offset = try? OffsetParser.parse(offsetField.stringValue) else { return nil }
        guard validate(offset) else { return nil }
        return offset
    }

    /// Validation as the address is typed, as everywhere else an offset is typed
    /// (§10.1) — but shown in the field itself rather than in a message: a panel
    /// this small has no room for a sentence, and red digits in a field of digits
    /// say the same thing. Return refuses while they are red.
    private func updateOffsetValidation() {
        offsetField.textColor = editedOffset == nil ? .systemRed : .labelColor
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject?) === offsetField else { return }
        updateOffsetValidation()
    }

    // MARK: - Outcomes

    /// Makes the cut and names the piece that starts there, then closes. The
    /// store normalizes the name, so trailing spaces and a name of nothing but
    /// spaces are already handled. An offset that is not a legal cut refuses:
    /// the field is already red, so the key only owes an answer that it was
    /// heard.
    func commit() {
        guard !settled else { return }
        guard let target = editedOffset else {
            beep()
            return
        }
        settled = true
        onCommit(target, descriptionField.stringValue)
        popover?.performClose(nil)
    }

    /// Closes without cutting: there is no half-made cut to take back, because
    /// nothing exists until this commits.
    func cancel() {
        guard !settled else { return }
        settled = true
        onCancel?()
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

/// The offset field: it does not select its whole text when it gains focus —
/// the caret lands after the existing text (the "0x" prefix), the way every
/// other offset field in the app does (§10), so a field that opens as "0x" is
/// ready to have hex digits typed after the prefix rather than to replace it.
private final class OffsetField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused, let editor = currentEditor() as? NSTextView {
            let length = (stringValue as NSString).length
            editor.selectedRange = NSRange(location: length, length: 0)
        }
        return focused
    }
}

extension CutEditPopoverController: NSPopoverDelegate {
    /// A popover dismissed by anything but the two keys — a click outside it,
    /// the window losing focus — keeps what was typed when the offset is legal:
    /// the user opened it to make a cut, so the cut is the quiet outcome. A red
    /// field is the one thing not kept: it closes without cutting, because an
    /// illegal offset is not a cut the user asked for.
    func popoverDidClose(_ notification: Notification) {
        guard !settled else { return }
        settled = true
        if let target = editedOffset {
            onCommit(target, descriptionField.stringValue)
        } else {
            // A red field is not a cut the user asked for: it closes without
            // committing, and the presenter that opened it is told.
            onCancel?()
        }
    }
}
