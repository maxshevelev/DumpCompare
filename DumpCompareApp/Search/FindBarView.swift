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
final class FindBarView: NSView, NSComboBoxDelegate {
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

    /// Fired when the pattern in the field is edited, so the session it no
    /// longer describes can be dropped — the greys and the count with it.
    var onPatternEdited: (() -> Void)?

    /// The point size every icon control on the bar draws its symbol at, so the
    /// chevrons, the list glyph and the "Aa" line up (§11).
    static let iconPointSize: CGFloat = 13

    /// UserDefaults key for the persisted case-sensitive toggle.
    static let caseSensitiveKey = "FindCaseSensitive"

    /// The defaults domain the case toggle lives in. Swappable so tests run
    /// against an isolated store instead of the real app's `UserDefaults.standard`
    /// (§11).
    static var defaults: UserDefaults = .standard

    private let patternCombo = NSComboBox()
    private let encodingPopup = NSPopUpButton()
    /// The "Aa" case toggle. Internal so a test can read the control itself: the
    /// bug this guards against was in its appearance, not in the flag it feeds.
    private(set) var caseButton = NSButton()
    /// The joined `<` `>` navigation: two chevron buttons inside one rounded,
    /// bordered block split by a hairline (§11). Each button centres its own
    /// icon (AppKit does this for `NSButton`), and there is no selected-segment
    /// highlight — the pair reads as two commands, not one 2-state control.
    /// The ‹ › pair: a real two-segment `NSSegmentedControl` in momentary
    /// tracking, which is what Xcode's find bar uses and what makes the block
    /// look native — it was a pair of borderless buttons inside a hand-drawn
    /// bordered container, and the container had to imitate a bezel, a corner
    /// radius and a divider that the control draws itself (§11). Internal so a
    /// test can press a segment: there is no button to click any more.
    private(set) var navControl = NSSegmentedControl()
    /// The 1px rule between the bar and the pane below. A property (not a local)
    /// so `viewDidChangeEffectiveAppearance` can re-resolve its dynamic colour
    /// on a theme switch — a layer background baked in `setUp` would otherwise
    /// keep the launch theme's pixels (§3.1).
    /// The count: "3 of 128", "Not found", or nothing at all before a search
    /// (§11). Monospaced digits so a climbing number never shuffles the
    /// controls beside it.
    private let countLabel = NSTextField(labelWithString: "")
    /// Shown only when something is being withheld — too many matches to list,
    /// or too many to highlight — carrying the reason as its tooltip.
    private let warningView = NSImageView()

    private let separator = NSView()
    private let doneButton = NSButton()
    /// The Search All button: lists every occurrence of the pattern in the
    /// active pane's results panel (§11).
    private let findAllButton = NSButton()

    /// Whether this search matches bytes exactly. Only the encodings whose case
    /// rules a *byte* fold can model are ever matched case-insensitively; for the
    /// rest this is always true, because the toggle's remembered state (off by
    /// default = case-insensitive, like TextEdit) would otherwise leak in and
    /// fold bytes that must not fold (§11).
    var isCaseSensitive: Bool {
        guard Self.supportsCaseFolding(currentEncoding()) else { return true }
        return caseButton.state == .on
    }

    /// Whether case-insensitive matching is meaningful for `encoding`.
    ///
    /// Everywhere text is text — ASCII, UTF-8 and UTF-16 in both byte orders —
    /// and the engine picks the fold that fits: letter bytes for the single-byte
    /// encodings, whole code units for UTF-16 (`CaseFolding`). Only **hex** is
    /// left out, and not as a simplification: hex input is bytes, and bytes have
    /// no case. (The parser reads `de ad` and `DE AD` as the same input — that is
    /// the input, not the comparison.)
        static func supportsCaseFolding(_ encoding: SearchEncoding) -> Bool {
        switch encoding {
        case .ascii, .utf8, .utf16LE, .utf16BE: return true
        case .hex: return false
        }
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
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        let findLabel = NSTextField(labelWithString: "Find")
        findLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        setUpPatternCombo()
        setUpEncodingPopup()
        setUpCaseButton()
        setUpCountLabel()
        setUpNavControl()
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
        // After the query it describes, before the stepper that walks it —
        // where the platform's own find bar puts it (§11).
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(warningView)
        stack.addArrangedSubview(navControl)
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
        // No height constraint: a segmented control knows its own metrics, and
        // pinning it to the toggle's height was only ever needed because the
        // hand-drawn container had none.

        // Give everything except the pattern a high hugging priority so only it
        // expands when the window is resized (§11).
        for view in [findLabel, encodingPopup, caseButton, countLabel, warningView,
                     navControl, findAllButton, doneButton] {
            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        patternCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        patternCombo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// Layer colors are resolved once when they are assigned: the
    /// `controlBackgroundColor`/`separatorColor` CGColors baked in `setUp` are
    /// captured before the bar is in a window, so a later switch to dark mode
    /// leaves the bar white. Re-resolve every dynamic layer color here, where
    /// the effective appearance is authoritative (§3.1).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
            // The case toggle's fill is a CGColor too (§11).
            syncCaseButtonAppearance()
        }
    }

    private func setUpPatternCombo() {
        patternCombo.isEditable = true
        patternCombo.completes = false
        patternCombo.setAccessibilityLabel("Find")
        patternCombo.target = self
        patternCombo.action = #selector(patternComboAction)
        // Editing the pattern ends the search it no longer describes: the count
        // and the highlighting belong to what is in the field (§11).
        patternCombo.delegate = self
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
        // Order matters, and it is the whole of the bug this shape fixes: a
        // button's type is stored as its cell's highlight/state masks, and
        // assigning `bezelStyle` re-derives those masks for the new bezel. Set
        // the type first — as this did — and the cell reverts to momentary as
        // soon as it is laid out in a real window: the click stopped sticking,
        // the toggle never looked on, and every search stayed case-insensitive.
        // A view with no window never displays, so the old order looked correct
        // in isolation, which is why the tests for it must go through a window.
        // Borderless, and nothing is drawn behind it: the state is the glyph's
        // own colour and weight, which is the platform's language for an inline
        // text-attribute toggle (Xcode's find bar says case-sensitivity exactly
        // this way). A bezel would fight it — `contentTintColor` is ignored for
        // a template image on a bordered button, which is how both states came
        // out accent-blue and the toggle looked stuck on.
        caseButton.isBordered = false
        caseButton.imagePosition = .imageOnly
        caseButton.image = NSImage(systemSymbolName: "textformat",
                                   accessibilityDescription: "Case Sensitive")
        // Push-on/push-off rather than `.toggle`: the same button type the
        // toolbar's insert-mode toggle uses (§24.2), which draws a lit platter
        // in the on state. `.toggle` swaps `image` for `alternateImage`, and
        // with no alternate image there was nothing to see either way.
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.setAccessibilityLabel("Case Sensitive")
        caseButton.toolTip = "Case Sensitive"
        caseButton.target = self
        caseButton.action = #selector(caseToggled)
        syncCaseButtonAppearance()
    }

    /// Paints the toggle to match its state (§11).
    ///
    /// The bezel is what carries it: **accent-filled means on**, plain means off.
    /// A push-on button's own on-state fill is a pale grey that reads as "hovered"
    /// rather than "selected", and `contentTintColor` cannot help — AppKit tints a
    /// template image on a bordered button with the accent colour itself and
    /// ignores the property, so the glyph is blue in both states. Colouring the
    /// bezel is the one cue that survives that, and it is the platform's own
    /// convention for a selected toggle.
    /// Paints the toggle to match its state (§11): **accent-blue and semibold
    /// means on**, quiet grey and regular means off. Two cues, colour and
    /// weight, so the state survives a colour-blind reader and a glance — the
    /// §3.2 rule, and the same pair Xcode's own "Aa" uses. The tooltip says it
    /// in words as well.
    private func syncCaseButtonAppearance() {
        let on = caseButton.state == .on
        caseButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        caseButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: on ? .semibold : .regular)
        // Only ever seen while the toggle is on the bar, so it names the two
        // states and nothing else (§11).
        caseButton.toolTip = on
            ? "Case Sensitive — matching exactly"
            : "Case Sensitive — off, upper and lower case match"
    }

    private func setUpCountLabel() {
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setAccessibilityLabel("Matches")
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        // Nothing to show until a search says otherwise; `show(count:)` brings
        // the label back and takes it away again (§11).
        countLabel.isHidden = true

        // A floor wide enough for four digits either side of "of", measured
        // from a template rather than from the value: the count changes with
        // every step, and a label that resizes drags the stepper with it (§11,
        // the same trick the results panel sizes its columns with). It holds
        // only while the label is shown — a hidden one is out of the layout.
        let template = "8888 of 8888" as NSString
        let width = template.size(withAttributes: [.font: countLabel.font!]).width
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(width)).isActive = true

        warningView.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                    accessibilityDescription: "Warning")
        warningView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: .regular)
        warningView.contentTintColor = .secondaryLabelColor
        warningView.isHidden = true
        warningView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Shows what the search found, or nothing when there is no search
    /// (§11). At zero the stepper and Find All go dead: there is nothing to
    /// step through and nothing to list.
    ///
    /// With nothing to say the label leaves the bar rather than holding its
    /// template's width open: an empty reserved slot beside the pattern field
    /// reads as a control that failed to draw. The stack detaches a hidden
    /// arranged view, so the stepper closes up against the field — the same
    /// move the case toggle makes when the encoding is hex.
    func show(count: FindCount?) {
        countLabel.stringValue = count?.text ?? ""
        countLabel.isHidden = count == nil
        countLabel.toolTip = count?.warning
        warningView.toolTip = count?.warning
        warningView.isHidden = count?.warning == nil
        // No search yet is not "no matches": the stepper is how a search is
        // started, so it stays live until a scan has actually come back empty.
        let live = count?.hasMatches ?? true
        navControl.isEnabled = live
        findAllButton.isEnabled = live
    }

    /// Reflects whether the pane's results panel is open: the button is a
    /// toggle now, not a search (§11). Accent while the panel is up, the bar's
    /// quiet grey otherwise — the same "on" language the case toggle uses.
    func setResultsShown(_ shown: Bool) {
        resultsShown = shown
        findAllButton.contentTintColor = shown ? .controlAccentColor : .secondaryLabelColor
        findAllButton.toolTip = shown ? "Hide Search Results" : "Show Search Results"
    }

    private var resultsShown = false
    var resultsShownForTests: Bool { resultsShown }

    /// What the count label reads, for tests.
    var countTextForTests: String { countLabel.stringValue }
    /// Whether the count occupies any of the bar at all, for tests.
    var countShownForTests: Bool { !countLabel.isHidden }
    /// The warning glyph's sentence, or nil when it is not shown.
    var countWarningForTests: String? { warningView.isHidden ? nil : warningView.toolTip }
    /// Where the stepper sits in the bar, for the test that the count's width
    /// does not move it.
    var navControlFrameForTests: NSRect { navControl.frame }
    /// The pattern field's width, for the test that the count's slot is real
    /// and that the field is what gets it back.
    var patternFieldWidthForTests: CGFloat { patternCombo.frame.width }
    var navControlEnabledForTests: Bool { navControl.isEnabled }
    var findAllEnabledForTests: Bool { findAllButton.isEnabled }

    private func setUpNavControl() {
        // Two momentary segments: pressing one runs a search, neither stays
        // selected. `.separated` would split them into two pills; the default
        // style is the joined block the platform draws everywhere else.
        let chevron: (String, String) -> NSImage = { name, description in
            NSImage(systemSymbolName: name, accessibilityDescription: description)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(
                    pointSize: Self.iconPointSize, weight: .regular))
                ?? NSImage()
        }
        navControl = NSSegmentedControl(
            images: [chevron("chevron.left", "Find Previous"),
                     chevron("chevron.right", "Find Next")],
            trackingMode: .momentary,
            target: self,
            action: #selector(navPressed(_:))
        )
        navControl.segmentStyle = .automatic
        navControl.setToolTip("Find Previous", forSegment: Self.previousSegment)
        navControl.setToolTip("Find Next", forSegment: Self.nextSegment)
        // The segments' own accessibility comes from the images' descriptions;
        // the control needs a name of its own for the group (§15).
        navControl.setAccessibilityLabel("Find Previous / Find Next")
        navControl.translatesAutoresizingMaskIntoConstraints = false
    }

    static let previousSegment = 0
    static let nextSegment = 1

    private func setUpFindAllButton() {
        // Borderless and quiet grey, like every other icon control on the bar:
        // one style, so nothing here reads as "selected" except the case
        // toggle when it is on. No `setButtonType`: the default momentary
        // push-in dims the icon while it is held.
        findAllButton.isBordered = false
        findAllButton.imagePosition = .imageOnly
        findAllButton.contentTintColor = .secondaryLabelColor
        findAllButton.image = NSImage(systemSymbolName: "list.bullet",
                                      accessibilityDescription: "Find All")
        findAllButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: .regular)
        findAllButton.setAccessibilityLabel("Search Results")
        findAllButton.toolTip = "Show Search Results"
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

    // MARK: - Test seams

    /// Selects `encoding` the way a click on the popup would, action included —
    /// the case toggle's enabled state follows the encoding (§11).
    func selectEncodingForTests(_ encoding: SearchEncoding) {
        guard let index = SearchEncoding.allCases.firstIndex(of: encoding) else { return }
        encodingPopup.selectItem(at: index)
        encodingChanged()
    }

    /// Sets the case toggle the way a click on it would, action included. A
    /// click cannot be synthesized reliably in a headless host, and what the
    /// tests are about is what the button then shows and reports.
    func setCaseSensitiveForTests(_ on: Bool) {
        caseButton.state = on ? .on : .off
        caseToggled()
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
        syncCaseButtonAppearance()
        updateCaseButtonVisibility()
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
    /// Typing in the pattern field ends the search that was running: the count
    /// clears, and the controller drops the pane's matches, so nothing on
    /// screen claims to describe a pattern that is no longer in the field.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSComboBox) === patternCombo else { return }
        show(count: nil)
        onPatternEdited?()
    }

    @objc private func patternSelectionChanged() {
        let index = patternCombo.indexOfSelectedItem
        guard index >= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.selectHistoryItem(at: index)
        }
    }

    @objc private func encodingChanged() {
        updateCaseButtonVisibility()
    }

    @objc private func caseToggled() {
        Self.defaults.set(caseButton.state == .on, forKey: Self.caseSensitiveKey)
        syncCaseButtonAppearance()
    }

    @objc private func navPressed(_ sender: NSSegmentedControl) {
        press(segment: sender.selectedSegment)
    }

    private func press(segment: Int) {
        runSearch(segment == Self.previousSegment ? .backward : .forward)
    }

    /// Presses one of the ‹ › segments the way a click would, mapping included.
    /// A momentary segmented control reports `selectedSegment` only for the
    /// duration of a real click, so a test cannot set it and send the action.
    func pressFindForTests(_ direction: SearchDirection) {
        press(segment: direction == .backward ? Self.previousSegment : Self.nextSegment)
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
        // open offers it and lists it in the combo's history (§11). The item
        // list is rebuilt only when the history moved: every press of ‹ ›
        // records the pair that is already at the front, and reloading a
        // dropdown nobody opened on each press is work for nothing.
        if FindHistoryStore.record(pattern: patternCombo.stringValue, encoding: pattern.encoding,
                                   caseSensitive: isCaseSensitive) {
            refreshHistoryItems()
        }
        onSearch?(pattern, direction, isCaseSensitive)
    }

    /// Runs a Search All: the same parse + history bookkeeping as a plain
    /// search, but every occurrence is collected instead of moving the caret.
    private func runSearchAll() {
        guard let pattern = parsedPattern() else { return }  // onError fired inside
        if FindHistoryStore.record(pattern: patternCombo.stringValue, encoding: pattern.encoding,
                                   caseSensitive: isCaseSensitive) {
            refreshHistoryItems()
        }
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
            updateCaseButtonVisibility()
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

    /// Shows or hides the case toggle for the current encoding (§11).
    ///
    /// Where a byte fold cannot model the encoding's case rules the toggle has
    /// nothing to mean — hex digits are bytes, and folding a UTF-16 code unit's
    /// high byte would match unrelated characters — so matching is always exact
    /// there and the control leaves the bar entirely. It used to stay, greyed
    /// out and showing "off", which read as "case is ignored" while the search
    /// was in fact exact: the one state the bar must never be in. The stack view
    /// collapses the gap, and the user's own preference is untouched — it comes
    /// back with the next foldable encoding.
    private func updateCaseButtonVisibility() {
        let foldable = Self.supportsCaseFolding(currentEncoding())
        caseButton.isHidden = !foldable
        caseButton.isEnabled = foldable
        syncCaseButtonAppearance()
    }

    // MARK: - Display

    /// The encoding popup's label — the same name the history dropdown uses,
    /// so one encoding reads as one thing wherever it appears.
    ///
    /// No "Text — " prefix in front of four of the five: the names carry
    /// themselves for anyone who reads dumps, and the prefix spent the bar's
    /// width saying what `UTF-8` already says. `Hex bytes` keeps its noun in
    /// the popup, where it is the one item that is not a text encoding — the
    /// shorter `Hex` reads as a display radix rather than as what the pattern
    /// is made of, which is the distinction the popup exists to make.
    private static func title(for encoding: SearchEncoding) -> String {
        encoding == .hex ? "Hex bytes" : shortTitle(for: encoding)
    }

    /// The pattern-combo dropdown label for a history entry: the search text
    /// plus its encoding, so "abcd" as ASCII and "abcd" as hex read as two
    /// distinct items. A "(CS)" suffix marks a case-sensitive search; hex is
    /// always byte-exact, so its recorded flag (true) never shows here (§11).
    private static func historyTitle(for entry: FindHistoryStore.Entry) -> String {
        let suffix = (entry.caseSensitive && entry.encoding != .hex) ? " (CS)" : ""
        return "\(entry.pattern) — \(shortTitle(for: entry.encoding))\(suffix)"
    }

    /// The encoding's bare name, for a history entry's label — where it sits
    /// after the pattern it describes and only has to tell two entries apart.
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
