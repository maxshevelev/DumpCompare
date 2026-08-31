import Cocoa
import DumpCompareCore

/// The "Text Decoding" pane of the Settings window (§3.4): the active decoding
/// table and placeholder character, plus a live 16×16 preview of the effective
/// mapping for all 256 byte values. Every change applies immediately through
/// `TextDecodingSettingsStore` (no Save/Apply button).
final class TextDecodingSettingsViewController: NSViewController {
    private let store = TextDecodingSettingsStore()
    private let tablePopup = NSPopUpButton()
    private let placeholderField = NSTextField()
    private let validationLabel = NSTextField(labelWithString: "")
    private let previewView = TextDecodingPreviewView()
    private var settingsObserver: NSObjectProtocol?

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: "Text Decoding")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        // Decoding table popup.
        let tableLabel = NSTextField(labelWithString: "Decoding table:")
        tablePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tablePopup.target = self
        tablePopup.action = #selector(tableChanged(_:))
        tablePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        // Placeholder character field (exactly one character).
        let placeholderLabel = NSTextField(labelWithString: "Placeholder character:")
        placeholderField.placeholderString = "."
        placeholderField.delegate = self
        placeholderField.alignment = .center
        placeholderField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        placeholderField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        let placeholderRow = NSStackView()
        placeholderRow.orientation = .horizontal
        placeholderRow.spacing = 8
        placeholderRow.alignment = .centerY
        placeholderRow.addArrangedSubview(placeholderField)
        placeholderRow.addArrangedSubview(validationLabel)

        // Live preview.
        let previewCaption = NSTextField(wrappingLabelWithString:
            "All 256 byte values decoded with the current table. Row headers are the byte value in hex.")
        previewCaption.font = .systemFont(ofSize: 11)
        previewCaption.textColor = .secondaryLabelColor
        previewCaption.maximumNumberOfLines = 2
        previewCaption.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetTapped))
        // `.push` is the current name of the standard rounded bezel (was
        // `.rounded`).
        resetButton.bezelStyle = .push
        resetButton.controlSize = .regular

        let grid = NSGridView(views: [
            [tableLabel, tablePopup],
            [placeholderLabel, placeholderRow],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Left column: title, controls, caption, reset.
        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 14
        leftStack.addArrangedSubview(titleLabel)
        leftStack.addArrangedSubview(grid)
        leftStack.addArrangedSubview(previewCaption)
        leftStack.addArrangedSubview(resetButton)

        // Preview box to the right of the controls for a compact pane.
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .top
        container.spacing = 28
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(leftStack)
        container.addArrangedSubview(previewView)
        root.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            container.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            container.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18),
            // Let the caption wrap at the controls' width, not the preview's.
            previewCaption.widthAnchor.constraint(lessThanOrEqualTo: grid.widthAnchor),
            // Exact width: the window sizes to this view's fitting size per tab.
            root.widthAnchor.constraint(equalToConstant: 620),
        ])
        view = root

        syncControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-sync in case settings changed from elsewhere (menu, tests).
        syncControls()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: TextDecodingSettingsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncControls()
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    /// Loads the current settings into the controls and the preview.
    private func syncControls() {
        let settings = store.settings

        // Popup: rebuild items from the registry, selecting the active table.
        tablePopup.removeAllItems()
        let menu = tablePopup.menu!
        for descriptor in TextDecoderRegistry.all {
            let item = menu.addItem(withTitle: descriptor.displayName, action: nil, keyEquivalent: "")
            item.representedObject = descriptor.identifier
        }
        let index = tablePopup.indexOfItem(withRepresentedObject: settings.identifier)
        tablePopup.selectItem(at: index >= 0 ? index : 0)

        // Placeholder field: only update when the user isn't mid-edit.
        if placeholderField.stringValue.count != 1 {
            placeholderField.stringValue = String(settings.placeholder)
        }
        validationLabel.isHidden = true

        // Preview.
        previewView.decoder = TextDecoderRegistry.make(
            identifier: settings.identifier,
            placeholder: settings.placeholder
        )
    }

    @objc private func tableChanged(_ sender: NSPopUpButton) {
        let identifier = sender.selectedItem?.representedObject as? String
            ?? TextDecoderRegistry.defaultIdentifier
        apply(TextDecodingSettings(identifier: identifier, placeholder: store.settings.placeholder))
    }

    @objc private func resetTapped() {
        store.resetToDefaults()
        syncControls()
    }

    /// Validates and persists the current placeholder + table.
    private func apply(_ settings: TextDecodingSettings) {
        store.apply(settings)
        syncControls()
    }

    /// Inline validation feedback for the placeholder field.
    private func showValidationError(_ message: String) {
        validationLabel.stringValue = message
        validationLabel.isHidden = false
    }
}

// MARK: - NSTextFieldDelegate

extension TextDecodingSettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === placeholderField else { return }
        let text = field.stringValue
        switch text.count {
        case 0:
            showValidationError("Enter a character")
        case 1:
            validationLabel.isHidden = true
            apply(TextDecodingSettings(identifier: store.settings.identifier, placeholder: text.first!))
        default:
            // Multi-character: keep only the first and apply, or reject outright.
            showValidationError("Exactly one character")
        }
    }
}

// MARK: - Preview grid

/// A 16×16 grid rendering all 256 byte values through a `TextDecoder`, with
/// hex row headers — the same visual rules as the hex view's decoded column:
/// monospaced glyphs, dimmed placeholders, ink-blue headers.
final class TextDecodingPreviewView: NSView {
    /// The decoder to render; replacing it redraws the grid.
    var decoder: any TextDecoder {
        didSet { needsDisplay = true }
    }

    private let font: NSFont
    private let charWidth: CGFloat
    private let lineHeight: CGFloat
    private let baseline: CGFloat

    /// Uniform outer padding around the grid on all four sides.
    private static let padding: CGFloat = 12
    /// Inset between the row header and the grid, plus a small margin.
    private static let headerInset: CGFloat = 8
    /// Row-header width: two hex digits plus a gap.
    private var rowHeaderWidth: CGFloat { 2 * charWidth + Self.headerInset }

    init() {
        font = AppearanceSettings.font(size: 12)
        charWidth = AppearanceSettings.charWidth(for: font)
        lineHeight = ceil(font.ascender - font.descender) + 3
        baseline = AppearanceSettings.centeredBaseline(font: font, rowHeight: lineHeight)
        decoder = TextDecoderRegistry.make(identifier: TextDecoderRegistry.defaultIdentifier, placeholder: ".")
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 2 * Self.padding + rowHeaderWidth + 16 * charWidth,
               height: 2 * Self.padding + 16 * lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()

        let gridX = Self.padding + rowHeaderWidth

        // Row headers (00-F0).
        for row in 0..<16 {
            draw(Self.hex2(row * 16), x: Self.padding,
                 y: Self.padding + CGFloat(row) * lineHeight, color: HexTheme.inkBlue)
        }

        // Cells.
        for row in 0..<16 {
            for column in 0..<16 {
                let byte = UInt8(row * 16 + column)
                let char = decoder.decode(byte)
                let color: NSColor = decoder.isDisplayable(byte)
                    ? (byte == 0x00 || byte == 0xFF ? HexTheme.mutedTextColor : .labelColor)
                    : HexTheme.mutedTextColor
                draw(String(char), x: gridX + CGFloat(column) * charWidth,
                     y: Self.padding + CGFloat(row) * lineHeight, color: color)
            }
        }
    }

    private func draw(_ text: String, x: CGFloat, y: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        (text as NSString).draw(at: NSPoint(x: x, y: y + baseline), withAttributes: attributes)
    }

    private static func hex2(_ value: Int) -> String {
        String(format: "%02X", value)
    }
}
