import Cocoa
import DumpCompareCore

// MARK: - Shared sheet chrome

/// Base class for the input dialogs (Go To Position, Select Block, Find).
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
        ])
        view = contentView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let field = firstField() {
            view.window?.makeFirstResponder(field)
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

// MARK: - Find (§11)

/// Pattern + encoding + Find Next / Find Previous.
final class FindSheetController: SheetViewController {
    private let onFind: ([UInt8], SearchDirection) -> Bool  // returns found

    private var patternField: NSTextField!
    private var encodingPopup: NSPopUpButton!

    init(onFind: @escaping ([UInt8], SearchDirection) -> Bool) {
        self.onFind = onFind
        super.init(title: "Find", message: "Search the active file's current contents.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        super.loadView()

        patternField = addFieldRow(label: "Pattern:", initial: "")

        encodingPopup = NSPopUpButton()
        encodingPopup.addItems(withTitles: SearchEncoding.allCases.map(Self.title(for:)))
        let label = NSTextField(labelWithString: "Encoding:")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(label)
        row.addArrangedSubview(encodingPopup)
        contentStack.addArrangedSubview(row)

        // Replace the base OK button with Find Next / Find Previous.
        submitButton.removeFromSuperview()
        let findNext = NSButton(title: "Find Next", target: self, action: #selector(findNext))
        findNext.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(findNext)
        let findPrevious = NSButton(title: "Find Previous", target: self, action: #selector(findPrevious))
        findPrevious.keyEquivalent = ""
        buttonRow.addArrangedSubview(findPrevious)
    }

    override func firstField() -> NSView? { patternField }

    private func currentEncoding() -> SearchEncoding {
        SearchEncoding.allCases[min(encodingPopup.indexOfSelectedItem, SearchEncoding.allCases.count - 1)]
    }

    private func parsedPattern() -> SearchPattern? {
        do {
            return try SearchEngine.parsePattern(patternField.stringValue, encoding: currentEncoding())
        } catch {
            showError(Self.errorText(for: error))
            return nil
        }
    }

    @objc func findNext() {
        guard let pattern = parsedPattern() else { return }
        if onFind(pattern.bytes, .forward) {
            dismiss(self)
        } else {
            showError("No match found.")
        }
    }

    @objc func findPrevious() {
        guard let pattern = parsedPattern() else { return }
        if onFind(pattern.bytes, .backward) {
            dismiss(self)
        } else {
            showError("No match found.")
        }
    }

    private static func errorText(for error: Error) -> String {
        if let searchError = error as? SearchError {
            switch searchError {
            case .emptyPattern: return "Enter a non-empty pattern."
            case .invalidHexPattern: return "Invalid hex — use pairs like DE AD BE EF."
            case .undecodableText: return "Text cannot be encoded in the selected encoding."
            }
        }
        return "Invalid pattern."
    }

    private static func title(for encoding: SearchEncoding) -> String {
        switch encoding {
        case .hex: return "Hex bytes"
        case .ascii: return "Text — ASCII"
        case .utf8: return "Text — UTF-8"
        case .utf16LE: return "Text — UTF-16 LE"
        case .utf16BE: return "Text — UTF-16 BE"
        }
    }
}
