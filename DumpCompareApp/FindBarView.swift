import Cocoa
import DumpCompareCore

/// The non-modal Find bar shown at the top of the window (§11), modelled after
/// TextEdit: a `Find` label, an editable pattern combo that stretches to fill
/// the remaining width, the encoding popup, a case-sensitive "Aa" toggle, joined
/// `<` `>` navigation, a Search All button that lists every occurrence in the
/// active pane's results panel, and a `Done` button — all on one line.
///
/// - Enter in the pattern field runs Find Next; Esc or `Done` closes the bar.
/// - The bar stays open after a search — only the selection moves.
/// - Picking an item from the pattern's history list loads that search (pattern
///   + encoding) but does NOT run it; only Enter, `<` and `>` search.
final class FindBarView: NSView {
    /// Fired when the user runs a search (Enter, `<` or `>`). The pattern is
    /// already parsed and validated; the third argument is the case toggle.
    var onSearch: ((SearchPattern, SearchDirection, Bool) -> Void)?
    /// Fired when the pattern fails to parse (shown as a transient status; no
    /// search is run).
    var onError: ((String) -> Void)?
    /// Fired when the user closes the bar (Done or Esc).
    var onClose: (() -> Void)?
    /// Fired when the user runs Search All (§11). The pattern is already parsed
    /// and validated; the second argument is the case toggle.
    var onSearchAll: ((SearchPattern, Bool) -> Void)?

    /// UserDefaults key for the persisted case-sensitive toggle.
    static let caseSensitiveKey = "FindCaseSensitive"

    /// The defaults domain the case toggle lives in. Swappable so tests run
    /// against an isolated store instead of the real app's `UserDefaults.standard`
    /// (§11).
    static var defaults: UserDefaults = .standard

    private let patternCombo = NSComboBox()
    private let encodingPopup = NSPopUpButton()
    private let caseButton = NSButton()
    /// The joined `<` `>` navigation: two chevron buttons inside one rounded,
    /// bordered block split by a hairline (§11). Each button centres its own
    /// icon (AppKit does this for `NSButton`), and there is no selected-segment
    /// highlight — the pair reads as two commands, not one 2-state control.
    private let navGroup = NSView()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let divider = NSView()
    private let doneButton = NSButton()
    /// The Search All button: lists every occurrence of the pattern in the
    /// active pane's results panel (§11).
    private let findAllButton = NSButton()

    /// Whether this search matches bytes exactly. Hex patterns are ALWAYS
    /// exact: the toggle is disabled for hex, but its state (off by default =
    /// case-insensitive, like TextEdit) would otherwise leak in and fold the
    /// hex bytes — "4545" (= EE) matching "Ee"/"eE" (§11).
    var isCaseSensitive: Bool {
        guard currentEncoding() != .hex else { return true }
        return caseButton.state == .on
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Setup

    private func setUp() {
        // Background + a 1px separator so the bar reads as a distinct strip
        // between the title bar and the pane content.
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        let findLabel = NSTextField(labelWithString: "Find")
        findLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        setUpPatternCombo()
        setUpEncodingPopup()
        setUpCaseButton()
        setUpNavGroup()
        setUpFindAllButton()
        setUpDoneButton()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        // Vertical padding around the controls keeps the strip from looking
        // cramped; the bar's height comes from the controls plus this inset (§11).
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(findLabel)
        stack.addArrangedSubview(patternCombo)
        stack.addArrangedSubview(encodingPopup)
        stack.addArrangedSubview(caseButton)
        stack.addArrangedSubview(navGroup)
        stack.addArrangedSubview(findAllButton)
        stack.addArrangedSubview(doneButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            // The pattern is the only control that grows; the rest keep their
            // intrinsic width. The stack's .fill distribution hands all extra
            // horizontal space to the view with the lowest hugging priority.
            patternCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        // Height of the nav block tracks the Aa case toggle — the bar's other
        // icon-only control — so the block reads the same size as its neighbours
        // (§11). Set here (not in setUpNavGroup) because the constraint needs
        // both views in the stack's hierarchy.
        navGroup.heightAnchor.constraint(equalTo: caseButton.heightAnchor).isActive = true

        // Give everything except the pattern a high hugging priority so only it
        // expands when the window is resized (§11).
        for view in [findLabel, encodingPopup, caseButton, navGroup, findAllButton, doneButton] {
            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        patternCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        patternCombo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func setUpPatternCombo() {
        patternCombo.isEditable = true
        patternCombo.completes = false
        patternCombo.setAccessibilityLabel("Find")
        patternCombo.target = self
        patternCombo.action = #selector(patternComboAction)
        // An editable combo only reliably sends its action on Return: picking an
        // item from the popup posts `selectionDidChangeNotification` instead (§11).
        // That's the hook that loads the picked entry into the form.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(patternSelectionChanged),
            name: NSComboBox.selectionDidChangeNotification,
            object: patternCombo
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setUpEncodingPopup() {
        encodingPopup.addItems(withTitles: SearchEncoding.allCases.map(Self.title(for:)))
        encodingPopup.setAccessibilityLabel("Encoding")
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged)
    }

    private func setUpCaseButton() {
        caseButton.setButtonType(.toggle)
        caseButton.bezelStyle = .texturedRounded
        caseButton.imagePosition = .imageOnly
        caseButton.image = NSImage(systemSymbolName: "textformat",
                                   accessibilityDescription: "Case Sensitive")
        caseButton.setAccessibilityLabel("Case Sensitive")
        caseButton.toolTip = "Case Sensitive"
        caseButton.target = self
        caseButton.action = #selector(caseToggled)
    }

    private func setUpNavGroup() {
        // The block: a rounded, bordered container drawn like a two-segment
        // control's bezel, with a hairline where the segments would meet. The
        // buttons themselves are borderless, so the block has no selected-segment
        // fill and no per-button bezel — the chevrons just sit in it (§11).
        navGroup.wantsLayer = true
        navGroup.layer?.cornerRadius = 5
        navGroup.layer?.borderWidth = 1
        navGroup.layer?.borderColor = NSColor.separatorColor.cgColor
        navGroup.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        // Clip the buttons to the rounded corners; otherwise their square
        // corners would poke past the container's radius.
        navGroup.layer?.masksToBounds = true
        navGroup.translatesAutoresizingMaskIntoConstraints = false

        // `NSButton` centres an image-only icon in its frame by itself, so the
        // chevrons line up dead-centre with no custom drawing (§11). The buttons
        // are borderless: a bezel (`.inline` especially) paints a circular fill
        // behind each icon, which reads as two separate buttons.
        prevButton.isBordered = false
        prevButton.imagePosition = .imageOnly
        prevButton.image = NSImage(systemSymbolName: "chevron.left",
                                   accessibilityDescription: "Find Previous")
        prevButton.setAccessibilityLabel("Find Previous")
        prevButton.toolTip = "Find Previous"
        prevButton.target = self
        prevButton.action = #selector(prevPressed)

        nextButton.isBordered = false
        nextButton.imagePosition = .imageOnly
        nextButton.image = NSImage(systemSymbolName: "chevron.right",
                                   accessibilityDescription: "Find Next")
        nextButton.setAccessibilityLabel("Find Next")
        nextButton.toolTip = "Find Next"
        nextButton.target = self
        nextButton.action = #selector(nextPressed)

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor

        for view in [prevButton, nextButton, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            navGroup.addSubview(view)
        }

        // Height: match the Aa case toggle, the bar's other icon-only control,
        // so the block reads the same size as its neighbours (§11). The buttons
        // are pinned only by their centre — AppKit gives a borderless image-only
        // NSButton a minimum height of its own (25-27pt) that would break
        // top/bottom pins, so centring keeps the chevron dead-centre instead.
        NSLayoutConstraint.activate([
            navGroup.widthAnchor.constraint(equalToConstant: 55),

            prevButton.leadingAnchor.constraint(equalTo: navGroup.leadingAnchor, constant: 1),
            prevButton.centerYAnchor.constraint(equalTo: navGroup.centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 26),

            divider.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor),
            divider.centerYAnchor.constraint(equalTo: navGroup.centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 16),
            divider.widthAnchor.constraint(equalToConstant: 1),

            nextButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: navGroup.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: navGroup.trailingAnchor, constant: -1),
            nextButton.widthAnchor.constraint(equalTo: prevButton.widthAnchor),
        ])
    }

    private func setUpFindAllButton() {
        findAllButton.setButtonType(.momentaryChange)
        findAllButton.bezelStyle = .texturedRounded
        findAllButton.imagePosition = .imageOnly
        findAllButton.image = NSImage(systemSymbolName: "list.bullet",
                                      accessibilityDescription: "Find All")
        findAllButton.setAccessibilityLabel("Find All")
        findAllButton.toolTip = "Find All"
        findAllButton.target = self
        findAllButton.action = #selector(findAllPressed)
    }

    private func setUpDoneButton() {
        doneButton.title = "Done"
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.setAccessibilityLabel("Done")
        // Esc closes the bar (§11): wiring Esc as the button's key equivalent
        // makes AppKit route it here from anywhere in the window.
        doneButton.keyEquivalent = "\u{1B}"
    }

    // MARK: - Show

    /// Populates the history list, restores the last search + persisted case
    /// toggle, and focuses the pattern field ready for typing.
    func prepareForShow() {
        if let mostRecent = FindHistoryStore.mostRecent {
            patternCombo.stringValue = mostRecent.pattern
            if let encodingIndex = SearchEncoding.allCases.firstIndex(of: mostRecent.encoding) {
                encodingPopup.selectItem(at: encodingIndex)
            }
        } else {
            patternCombo.stringValue = ""
            encodingPopup.selectItem(at: 0)
        }
        caseButton.state = (Self.defaults.object(forKey: Self.caseSensitiveKey) as? Bool ?? false) ? .on : .off
        updateCaseButtonEnabled()
        refreshHistoryItems()
        // Focus the field and select the prefilled text so typing replaces it.
        if window != nil {
            patternCombo.selectText(nil)
        }
    }

    private func refreshHistoryItems() {
        let text = patternCombo.stringValue
        patternCombo.removeAllItems()
        patternCombo.addItems(withObjectValues: FindHistoryStore.recent.map(Self.historyTitle(for:)))
        patternCombo.stringValue = text
        deselectPatternCombo()
    }

    /// Clears the combo's selection so a later Return in the field isn't
    /// mistaken for a pick. `selectItem(at: -1)` crashes (it indexes the item
    /// array at -1) and `deselectItem(at:)` only accepts a valid index, so
    /// deselect exactly the current selection when there is one.
    private func deselectPatternCombo() {
        if patternCombo.indexOfSelectedItem >= 0 {
            patternCombo.deselectItem(at: patternCombo.indexOfSelectedItem)
        }
    }

    /// Restores first responder to the pattern field after a search run from the
    /// bar, so a subsequent Enter keeps re-searching instead of landing on the
    /// hex view (§11).
    func focusPatternField() {
        window?.makeFirstResponder(patternCombo)
    }

    // MARK: - Actions

    /// The combo's action fires on Return (submit). A picked history item is
    /// handled by `patternSelectionChanged` (the popup pick does not fire the
    /// action on an editable combo), so by the time the action runs the pick has
    /// already deselected itself and the field holds the bare pattern (§11).
    @objc private func patternComboAction() {
        if patternCombo.indexOfSelectedItem >= 0 {
            selectHistoryItem(at: patternCombo.indexOfSelectedItem)
            return
        }
        runSearch(.forward)
    }

    /// The popup selection changed — the user picked a history item. The
    /// notification fires in the MIDDLE of the combo's own selection handling,
    /// so touching the selection or text here corrupts that in-flight state
    /// (e.g. `selectItem(at:)` re-entrantly posting the notification crashes on
    /// an index-out-of-bounds). Defer the load to the next runloop turn, when
    /// the combo has settled.
    @objc private func patternSelectionChanged() {
        let index = patternCombo.indexOfSelectedItem
        guard index >= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.selectHistoryItem(at: index)
        }
    }

    @objc private func encodingChanged() {
        updateCaseButtonEnabled()
    }

    @objc private func caseToggled() {
        Self.defaults.set(caseButton.state == .on, forKey: Self.caseSensitiveKey)
    }

    @objc private func prevPressed() {
        runSearch(.backward)
    }

    @objc private func nextPressed() {
        runSearch(.forward)
    }

    @objc private func donePressed() {
        onClose?()
    }

    @objc private func findAllPressed() {
        runSearchAll()
    }

    /// Esc can also reach the bar through the responder chain (e.g. when the
    /// combo is mid-edit and the field editor consumes the key equivalent).
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    // MARK: - Search

    private func runSearch(_ direction: SearchDirection) {
        guard let pattern = parsedPattern() else { return }  // onError fired inside
        // Remember this search (pattern + encoding + case flag) so the next
        // open offers it and lists it in the combo's history (§11).
        FindHistoryStore.record(pattern: patternCombo.stringValue, encoding: pattern.encoding,
                                caseSensitive: isCaseSensitive)
        refreshHistoryItems()
        onSearch?(pattern, direction, isCaseSensitive)
    }

    /// Runs a Search All: the same parse + history bookkeeping as a plain
    /// search, but every occurrence is collected instead of moving the caret.
    private func runSearchAll() {
        guard let pattern = parsedPattern() else { return }  // onError fired inside
        FindHistoryStore.record(pattern: patternCombo.stringValue, encoding: pattern.encoding,
                                caseSensitive: isCaseSensitive)
        refreshHistoryItems()
        onSearchAll?(pattern, isCaseSensitive)
    }

    private func parsedPattern() -> SearchPattern? {
        do {
            return try SearchEngine.parsePattern(patternCombo.stringValue, encoding: currentEncoding())
        } catch {
            onError?(Self.errorText(for: error))
            return nil
        }
    }

    private func currentEncoding() -> SearchEncoding {
        let index = max(0, encodingPopup.indexOfSelectedItem)
        return SearchEncoding.allCases[min(index, SearchEncoding.allCases.count - 1)]
    }

    /// A history item was picked from the list: load its pattern and its
    /// encoding into the form together (§11). The dropdown lists each search as
    /// "pattern — encoding", so the same pattern under two encodings shows as
    /// two items; the field keeps just the pattern while the popup carries the
    /// encoding.
    private func selectHistoryItem(at index: Int) {
        let entries = FindHistoryStore.recent
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]

        // The dropdown labels each item "pattern — encoding", so a pick fills
        // the field with that whole label. Rewrite the field to hold just the
        // pattern, and route the encoding to its popup. The write must go
        // through the live field editor when there is one — an active editor
        // ignores `stringValue` until it commits (§11).
        deselectPatternCombo()
        if let editor = patternCombo.currentEditor() {
            editor.string = entry.pattern
        }
        patternCombo.stringValue = entry.pattern

        if let encodingIndex = SearchEncoding.allCases.firstIndex(of: entry.encoding) {
            encodingPopup.selectItem(at: encodingIndex)
            updateCaseButtonEnabled()
        }

        // Restore the search's case-sensitivity (text encodings only): the
        // toggle follows the picked entry and the persisted default is updated
        // so a later reopen keeps the same state. Hex is always byte-exact —
        // its flag is recorded true but never shown or restored (§11).
        if entry.encoding != .hex {
            caseButton.state = entry.caseSensitive ? .on : .off
            Self.defaults.set(entry.caseSensitive, forKey: Self.caseSensitiveKey)
        }
    }

    private func updateCaseButtonEnabled() {
        // Case sensitivity is meaningful only for text encodings; hex digits
        // are already parsed case-insensitively, so the toggle is disabled.
        caseButton.isEnabled = currentEncoding() != .hex
    }

    // MARK: - Display

    private static func title(for encoding: SearchEncoding) -> String {
        switch encoding {
        case .hex: return "Hex bytes"
        case .ascii: return "Text — ASCII"
        case .utf8: return "Text — UTF-8"
        case .utf16LE: return "Text — UTF-16 LE"
        case .utf16BE: return "Text — UTF-16 BE"
        }
    }

    /// The pattern-combo dropdown label for a history entry: the search text
    /// plus its encoding, so "abcd" as ASCII and "abcd" as hex read as two
    /// distinct items. A "(CS)" suffix marks a case-sensitive search; hex is
    /// always byte-exact, so its recorded flag (true) never shows here (§11).
    private static func historyTitle(for entry: FindHistoryStore.Entry) -> String {
        let suffix = (entry.caseSensitive && entry.encoding != .hex) ? " (CS)" : ""
        return "\(entry.pattern) — \(shortTitle(for: entry.encoding))\(suffix)"
    }

    private static func shortTitle(for encoding: SearchEncoding) -> String {
        switch encoding {
        case .hex: return "Hex"
        case .ascii: return "ASCII"
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
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
}
