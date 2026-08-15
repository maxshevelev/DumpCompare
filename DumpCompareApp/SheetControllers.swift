import Cocoa
import DumpCompareCore

// MARK: - Shared sheet chrome

/// Base class for the input dialogs (Go To Position, Select Block).
/// Builds a titled sheet with a field stack, an inline error label, and a
/// Cancel/Submit button row; subclasses add fields and validation (§10).
class SheetViewController: NSViewController {
    let titleText: String
    let messageText: String?
    private(set) var contentStack: NSStackView!
    private(set) var errorLabel: NSTextField!
    private(set) var buttonRow: NSStackView!
    private(set) var submitButton: NSButton!

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Set synchronously around the `makeFirstResponder` call in `viewDidAppear`.
    /// AppKit fires the field's action (`submitPressed`) as a side effect of
    /// `makeFirstResponder` ending the field-editing session that the sheet's
    /// initial focus started; suppressing it keeps the sheet from dismissing
    /// itself before it ever attaches.
    private var presentationInProgress = false

    init(title: String, message: String?) {
        self.titleText = title
        self.messageText = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)

        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        root.addArrangedSubview(titleLabel)

        if let messageText {
            let messageLabel = NSTextField(wrappingLabelWithString: messageText)
            messageLabel.font = .systemFont(ofSize: 12)
            messageLabel.textColor = .secondaryLabelColor
            root.addArrangedSubview(messageLabel)
        }

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        root.addArrangedSubview(contentStack)

        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        root.addArrangedSubview(errorLabel)

        buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1B}"  // Esc
        buttonRow.addArrangedSubview(cancel)

        let submit = NSButton(title: "OK", target: self, action: #selector(submitPressed))
        submit.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(submit)
        submitButton = submit

        root.addArrangedSubview(buttonRow)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
        ])

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        // A concrete, generous default frame lets `presentAsSheet` size the
        // sheet window even before auto layout runs (the view arrives with a
        // zero frame); it is wide/tall enough to hold any of the subclasses.
        contentView.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        view = contentView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let field = firstField() {
            // The sheet's initial focus already made the field's field editor
            // first responder; calling makeFirstResponder again ends that
            // editing session synchronously, and `textDidEndEditing` sends the
            // field's action (`submitPressed`). Suppress that transient event —
            // a real submit from the OK button / Return happens later, after the
            // sheet is attached and this flag is clear again.
            presentationInProgress = true
            view.window?.makeFirstResponder(field)
            presentationInProgress = false
        }
    }

    // MARK: - Overridable

    /// The first focusable text field (default: nil).
    func firstField() -> NSView? { nil }

    /// Returns an error message, or nil when the input is valid.
    func validate() -> String? { nil }

    /// Called after successful validation and dismissal.
    func handleSubmit() { onSubmit?() }

    /// Called when the user cancels.
    func handleCancel() { onCancel?() }

    // MARK: - Actions

    @objc func submitPressed() {
        // Ignore the action fired by the sheet's initial focus setup (see
        // `presentationInProgress`); the user cannot have submitted yet.
        guard !presentationInProgress else { return }
        if let error = validate() {
            showError(error)
            return
        }
        dismiss(self)
        handleSubmit()
    }

    @objc func cancelPressed() {
        dismiss(self)
        handleCancel()
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    /// Builds a label + text field row inside `contentStack` and returns the field.
    func addFieldRow(label text: String, initial: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let field = NSTextField(string: initial)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.target = self
        field.action = #selector(submitPressed)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        field.setAccessibilityLabel(text)  // §15: VoiceOver names the field.

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        contentStack.addArrangedSubview(row)
        return field
    }
}

// MARK: - Go To Position (§10.1)

/// Cmd+G: single absolute offset, `0x`-prefixed by default, inline validation.
final class GoToSheetController: SheetViewController {
    private var offsetField: NSTextField!
    private let onGo: (UInt64) -> Void

    init(fileSize: UInt64, onGo: @escaping (UInt64) -> Void) {
        self.onGo = onGo
        super.init(title: "Go To Position",
                   message: "Enter a zero-based offset in hex (file is \(fileSize) bytes).")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        super.loadView()
        offsetField = addFieldRow(label: "Offset:", initial: "0x")
    }

    override func firstField() -> NSView? { offsetField }

    override func validate() -> String? {
        do {
            _ = try OffsetParser.parse(offsetField.stringValue)
            return nil
        } catch {
            return "Invalid offset — use hex with 0x prefix or decimal."
        }
    }

    override func handleSubmit() {
        if let offset = try? OffsetParser.parse(offsetField.stringValue) {
            onGo(offset)
        }
    }
}

// MARK: - Select Block (§10.2)

/// Select a range by Start/End or by Start/Length.
final class SelectBlockSheetController: SheetViewController {
    private enum Mode: Int { case startEnd = 0, startLength = 1 }

    private let fileSize: UInt64
    private let onSelect: (SelectionModel) -> Void

    private var startField: NSTextField!
    private var secondField: NSTextField!
    private var secondLabel: NSTextField!

    init(fileSize: UInt64, onSelect: @escaping (SelectionModel) -> Void) {
        self.fileSize = fileSize
        self.onSelect = onSelect
        super.init(title: "Select Block",
                   message: "Select a byte range by absolute offsets.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        super.loadView()

        let modePopup = NSPopUpButton()
        modePopup.addItems(withTitles: ["Start and End", "Start and Length"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        contentStack.addArrangedSubview(modePopup)

        startField = addFieldRow(label: "Start:", initial: "0x")

        secondLabel = NSTextField(labelWithString: "End:")
        secondLabel.font = .systemFont(ofSize: 12)
        secondLabel.textColor = .secondaryLabelColor
        secondLabel.alignment = .right
        secondLabel.translatesAutoresizingMaskIntoConstraints = false
        secondLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

        secondField = NSTextField(string: "0x")
        secondField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        secondField.target = self
        secondField.action = #selector(submitPressed)
        secondField.translatesAutoresizingMaskIntoConstraints = false
        secondField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        secondField.setAccessibilityLabel("End")  // §15; updated by modeChanged.

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(secondLabel)
        row.addArrangedSubview(secondField)
        contentStack.addArrangedSubview(row)
    }

    override func firstField() -> NSView? { startField }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        secondLabel.stringValue = sender.indexOfSelectedItem == Mode.startEnd.rawValue ? "End:" : "Length:"
        secondField.setAccessibilityLabel(secondLabel.stringValue)  // §15
    }

    override func validate() -> String? {
        let isLengthMode = secondLabel.stringValue == "Length:"
        guard let start = parse(startField.stringValue) else {
            return "Invalid start offset."
        }
        guard start <= fileSize else {
            return "Start is beyond the end of the file."
        }
        guard let second = parse(secondField.stringValue) else {
            return isLengthMode ? "Invalid length." : "Invalid end offset."
        }
        if !isLengthMode {
            if start > second {
                return "Start must not exceed end."
            }
            if second > fileSize {
                return "End is beyond the end of the file."
            }
        }
        return nil
    }

    override func handleSubmit() {
        let isLengthMode = secondLabel.stringValue == "Length:"
        guard let start = parse(startField.stringValue), start <= fileSize else { return }
        guard let second = parse(secondField.stringValue) else { return }
        let selection: SelectionModel
        if isLengthMode {
            selection = SelectionModel(start: start, length: second, fileSize: fileSize)
        } else {
            guard second <= fileSize else { return }
            selection = SelectionModel(start: start, end: second, fileSize: fileSize)
        }
        onSelect(selection)
    }

    private func parse(_ text: String) -> UInt64? {
        try? OffsetParser.parse(text)
    }
}

// MARK: - Fill Selection (§7.3)

/// Remembers the last byte pattern used in Edit > Fill Selection with… so the
/// next fill starts from it instead of always defaulting to `FF`. Persisted in
/// `UserDefaults` (same pattern as `WordSize`), so it survives app restarts.
enum FillPatternStore {
    static let userDefaultsKey = "LastFillPattern"
    static let defaultPattern = "FF"

    /// The last pattern the user filled with, or `defaultPattern` when none is
    /// saved yet.
    static var last: String {
        UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultPattern
    }

    /// Persists `pattern` as the value to offer next time.
    static func save(_ pattern: String) {
        UserDefaults.standard.set(pattern, forKey: userDefaultsKey)
    }
}

/// Edit > Fill Selection with…: a hex byte sequence repeated across the
/// selection, defaulting to the last used pattern (or `FF`). Uses the same hex
/// parsing as Find.
final class FillSheetController: SheetViewController {
    private var bytesField: NSTextField!
    private let onFill: ([UInt8]) -> Void

    init(selectionCount: UInt64, onFill: @escaping ([UInt8]) -> Void) {
        self.onFill = onFill
        super.init(title: "Fill Selection with…",
                   message: "Fill the selected \(selectionCount) byte(s) by repeating the byte sequence.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        super.loadView()
        bytesField = addFieldRow(label: "Bytes:", initial: FillPatternStore.last)
    }

    override func firstField() -> NSView? { bytesField }

    override func validate() -> String? {
        let text = bytesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Enter at least one byte (e.g. FF)." }
        do {
            _ = try SearchEngine.parsePattern(text, encoding: .hex)
            return nil
        } catch {
            return "Invalid hex — use pairs like DE AD BE EF."
        }
    }

    override func handleSubmit() {
        guard let pattern = try? SearchEngine.parsePattern(bytesField.stringValue, encoding: .hex) else { return }
        // Remember the raw text as typed (trimmed of surrounding whitespace), so
        // the next fill offers the same pattern (§7.3).
        FillPatternStore.save(bytesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        onFill(pattern.bytes)
    }
}

// MARK: - Find history (§11)

/// Remembers the last searches (pattern + encoding + case-sensitivity) so the
/// Find bar can offer them in the pattern combo and default to the most recent
/// one. Persisted in `UserDefaults` (same pattern as `WordSize`); capped at 10
/// entries, most recent first, one entry per (pattern, encoding) pair.
enum FindHistoryStore {
    static let userDefaultsKey = "FindHistory"
    static let limit = 10

    /// The defaults domain the history lives in. Swappable so tests run against
    /// an isolated store instead of the real app's `UserDefaults.standard`
    /// (which would otherwise pick up and pollute the user's own searches §11).
    static var defaults: UserDefaults = .standard

    struct Entry: Equatable {
        let pattern: String
        let encoding: SearchEncoding
        /// Whether the search was run case-sensitively. Meaningful only for text
        /// encodings — hex is always byte-exact, so its recorded flag (true)
        /// never shows in the dropdown and is never restored.
        let caseSensitive: Bool
    }

    /// The saved searches, most recent first.
    static var recent: [Entry] {
        // The stored rows now mix Strings and a Bool, so the array casts to
        // [[String: Any]] (a [[String: String]] cast would fail and wipe the
        // whole history).
        guard let raw = defaults.array(forKey: userDefaultsKey) as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let pattern = dict["pattern"] as? String,
                  let encodingName = dict["encoding"] as? String,
                  let encoding = SearchEncoding(rawValue: encodingName) else { return nil }
            return Entry(pattern: pattern, encoding: encoding,
                         caseSensitive: dict["caseSensitive"] as? Bool ?? false)
        }
    }

    /// The most recent search — the default the sheet offers on open.
    static var mostRecent: Entry? { recent.first }

    /// Records a search: moves the (pattern, encoding) pair to the front,
    /// dropping any older entry with the SAME pair, and capping the list at
    /// `limit`. The same pattern under a different encoding is a separate item
    /// — "abcd" as ASCII and "abcd" as hex both stay in the history (§11).
    /// The `caseSensitive` flag rides along with the pair: re-recording the same
    /// pair with a different flag replaces the entry (latest search wins), and
    /// the flag is what the dropdown's "(CS)" suffix reflects.
    static func record(pattern: String, encoding: SearchEncoding, caseSensitive: Bool = false) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = recent.filter { !($0.pattern == trimmed && $0.encoding == encoding) }
        entries.insert(Entry(pattern: trimmed, encoding: encoding, caseSensitive: caseSensitive), at: 0)
        defaults.set(
            Array(entries.prefix(limit)).map {
                ["pattern": $0.pattern,
                 "encoding": $0.encoding.rawValue,
                 "caseSensitive": $0.caseSensitive]
            },
            forKey: userDefaultsKey
        )
    }
}

