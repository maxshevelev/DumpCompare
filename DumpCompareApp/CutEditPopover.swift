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

    private let prefillOffset: UInt64
    private let fileSize: UInt64
    /// Whether an offset already holds a cut. The bounds (0 and EOF) are the
    /// popover's own to check — every piece must stay non-empty (§21.2).
    private let isAlreadyACut: (UInt64) -> Bool
    private let onCommit: (UInt64, String) -> Void

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
    ///   - prefillOffset: the offset the field starts at — the caret's.
    ///   - fileSize: the pane's file size, which bounds a legal cut.
    ///   - isAlreadyACut: whether an offset another cut already holds.
    ///   - onCommit: the cut's offset and the name for the piece that starts
    ///     there.
    init(prefillOffset: UInt64, fileSize: UInt64,
         isAlreadyACut: @escaping (UInt64) -> Bool,
         onCommit: @escaping (UInt64, String) -> Void) {
        self.prefillOffset = prefillOffset
        self.fileSize = fileSize
        self.isAlreadyACut = isAlreadyACut
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // The address in the shape the dialogs write one (§10), in the dump's
        // own font: this field is read far more often than it is edited, so it
        // has to read as an address first and behave as a field second.
        let offset = NSTextField(string: String(format: "0x%X", prefillOffset))
        offset.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        offset.delegate = self
        offset.translatesAutoresizingMaskIntoConstraints = false
        offset.setAccessibilityLabel("Cut offset")
        offsetField = offset

        // A plain field: AppKit selects its whole text on focus, which is what
        // a name wants — the popover opens with the field ready to be filled.
        // Its placeholder says what the field is for, so the field needs no
        // label beside it and can have the popover's whole width.
        let description = NSTextField(string: "")
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
        // The caret goes straight into the DESCRIPTION, the way the bookmark's
        // does into its name: the offset is already right — it is there to be
        // corrected, not filled in — so "Add Cut…, type, Return" makes a named
        // cut without a click, and typing a description works without a Tab.
        view.window?.makeFirstResponder(descriptionField)
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
    /// the text does not parse as an offset (§10), it is 0 or at EOF (every
    /// piece must stay non-empty, §21.2), or another cut already holds it.
    var editedOffset: UInt64? {
        guard let offset = try? OffsetParser.parse(offsetField.stringValue) else { return nil }
        guard offset > 0, offset < fileSize, !isAlreadyACut(offset) else { return nil }
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
        }
    }
}
