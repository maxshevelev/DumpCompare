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
final class FindBarView: NSView, NSSearchFieldDelegate, NSMenuItemValidation {
    /// What the field is asking for (§11).
    ///
    /// The bar says which of the two questions it is and nothing more. Where
    /// the encoding is the user's choice it hands over the pattern that choice
    /// makes; where it is not, it hands over the text — deciding what to try,
    /// and in what order, is the model's job (`SmartSearch`), and the bar's job
    /// is to show what came back.
    enum Request: Equatable {
        case pattern(SearchPattern, folding: CaseFolding)
        /// `preferring` is the encoding the field's contents came *with*, when
        /// they came from the history rather than from the keyboard: Smart
        /// Search tries it first and then falls back to its own order (§11).
        case smart(text: String, caseSensitive: Bool, preferring: SearchEncoding?)
    }

    /// Fired when the user runs a search (Enter, `<` or `>`).
    var onSearch: ((Request, SearchDirection) -> Void)?
    /// Fired when the pattern fails to parse (shown as a transient status; no
    /// search is run).
    var onError: ((String) -> Void)?
    /// Fired by **Add to Favorites** with what the field describes. The owner
    /// asks for a name and stores it: a sheet belongs to a window, not to a
    /// bar (§11).
    var onAddToFavorites: ((SearchPatternEntry) -> Void)?

    /// Fired by **Manage Favorites…** — the owner opens the form.
    var onManageFavorites: (() -> Void)?

    /// Fired when the user closes the bar (Done or Esc).
    var onClose: (() -> Void)?
    /// Fired when the user runs Search All (§11): the same request.
    var onSearchAll: ((Request) -> Void)?

    /// Fired when the pattern in the field is edited, so the session it no
    /// longer describes can be dropped — the greys and the count with it.
    var onPatternEdited: (() -> Void)?

    /// The point size every icon control on the bar draws its symbol at, so the
    /// chevrons, the list glyph and the "Aa" line up (§11).
    static let iconPointSize: CGFloat = 13
    /// The pattern menu's type sizes: rows and commands a size below the
    /// system menu's 13pt — these are a list to scan rather than commands to
    /// read one at a time — and the flags a size below that again (§11).
    static let menuRowSize: CGFloat = 12
    static let menuFlagSize: CGFloat = 11

    /// UserDefaults key for the persisted case-sensitive toggle.
    static let caseSensitiveKey = "FindCaseSensitive"
    /// Whether Smart Search is on. Remembered like the case toggle, and **on**
    /// until the user says otherwise: a reader who knows what they are looking
    /// for and not how it is stored is the common case (§11).
    static let smartSearchKey = "FindSmartSearch"

    /// The defaults domain the case toggle lives in. Swappable so tests run
    /// against an isolated store instead of the real app's `UserDefaults.standard`
    /// (§11).
    static var defaults: UserDefaults = .standard

    /// The pattern field: a search field, whose magnifier drops the menu with
    /// the two lists (§11, `Design/PATTERN_LIBRARY_IDEA.md`). A combo box until
    /// the library needed sections — a combo's list is flat, and a header in it
    /// is a selectable row pretending not to be. The field also brings the ⊗
    /// that gives Escape a job other than closing the bar.
    private let patternField = NSSearchField()
    private let encodingPopup = NSPopUpButton()
    /// The "Aa" case toggle. Internal so a test can read the control itself: the
    /// bug this guards against was in its appearance, not in the flag it feeds.
    private(set) var caseButton = NSButton()
    /// The Smart Search toggle, beside the encoding it makes a result rather
    /// than an instruction (§11).
    private(set) var smartButton = NSButton()
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
    ///
    /// That override is about the encoding *this search runs in* — so with
    /// Smart Search on it must not be applied here at all. The popup then
    /// names a result rather than the search, and each attempt derives its own
    /// folding from its own encoding (`CaseFolding(encoding:caseSensitive:)`
    /// forces hex exact by itself). Reading the popup here is what made a
    /// search for `root` right after a hex search come back empty on a dump
    /// that plainly holds `Root`: the popup still said `Hex bytes`, so every
    /// text attempt was built case-*sensitive* and folded nothing.
    var isCaseSensitive: Bool {
        guard !isSmartSearchEnabled else { return caseButton.state == .on }
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

        setUpPatternField()
        setUpEncodingPopup()
        setUpCaseButton()
        setUpSmartButton()
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
        stack.addArrangedSubview(patternField)
        stack.addArrangedSubview(encodingPopup)
        // Next to the encoding, because that is what it takes over: with it on,
        // the popup stops being the question and becomes the answer (§11).
        stack.addArrangedSubview(smartButton)
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
            patternField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
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
        for view in [findLabel, encodingPopup, smartButton, caseButton, countLabel, warningView,
                     navControl, findAllButton, doneButton] {
            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        patternField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        patternField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    private func setUpPatternField() {
        patternField.setAccessibilityLabel("Find")
        patternField.target = self
        patternField.action = #selector(patternFieldAction)
        // Return searches; typing does not. A search is a scan of the file,
        // and one per keystroke is not what was asked for.
        patternField.sendsWholeSearchString = true
        patternField.sendsSearchStringImmediately = false
        // Editing the pattern ends the search it no longer describes: the count
        // and the highlighting belong to what is in the field (§11).
        patternField.delegate = self
        // The menu is a *template*: the field copies it on every click, so it
        // has to be rebuilt whenever either list changes — a search records a
        // recent, the form edits the favourites.
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildPatternMenu),
            name: FavoritePatternStore.didChangeNotification, object: nil)
        rebuildPatternMenu()
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

    /// The Smart Search toggle: the same borderless glyph the case toggle is,
    /// in the same two states — accent and semibold when on, quiet grey and
    /// regular when off — because it is the same kind of thing, an attribute of
    /// how the field is read (§3.2, §11).
    private func setUpSmartButton() {
        smartButton.isBordered = false
        smartButton.imagePosition = .imageOnly
        smartButton.image = NSImage(systemSymbolName: "wand.and.sparkles",
                                    accessibilityDescription: "Smart Search")
        smartButton.setButtonType(.pushOnPushOff)
        smartButton.setAccessibilityLabel("Smart Search")
        smartButton.target = self
        smartButton.action = #selector(smartToggled)
        smartButton.state = Self.storedSmartSearch ? .on : .off
        syncSmartButtonAppearance()
    }

    /// On unless the user has turned it off.
    static var storedSmartSearch: Bool {
        defaults.object(forKey: smartSearchKey) as? Bool ?? true
    }

    /// Whether the encoding is a result rather than an instruction (§11).
    var isSmartSearchEnabled: Bool { smartButton.state == .on }

    private func syncSmartButtonAppearance() {
        let on = isSmartSearchEnabled
        smartButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        smartButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: on ? .semibold : .regular)
        smartButton.toolTip = on
            ? "Smart Search — the encoding is whichever one finds a match"
            : "Smart Search — off, searching the chosen encoding only"
    }

    @objc private func smartToggled() {
        Self.defaults.set(isSmartSearchEnabled, forKey: Self.smartSearchKey)
        syncSmartButtonAppearance()
        // The field means something else now: with Smart Search on it is read
        // in every encoding, so a complaint about the chosen one no longer
        // stands, and the case toggle is offered because a text scan will
        // happen whatever the popup says.
        show(patternError: nil)
        updateCaseButtonVisibility()
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
        self.count = count
        applyCountLabel()
    }

    /// What the field holds is not a pattern at all — `DE A` in hex, a
    /// character the chosen encoding cannot encode (§11).
    ///
    /// Reported in the count's place, in red. The two are answers to the same
    /// question — what does the field describe? — so only one of them can be
    /// true at a time, and the one place the eye already goes for that answer
    /// is beside the field. `detail` says what is wrong in full, as the
    /// label's tooltip; the label itself has to stay short enough to sit in a
    /// bar.
    func show(patternError message: String?, detail: String? = nil) {
        patternError = message.map { (label: $0, detail: detail ?? $0) }
        applyCountLabel()
    }

    private var count: FindCount?
    private var patternError: (label: String, detail: String)?

    private func applyCountLabel() {
        // The error outranks the count: a count belongs to a search, and there
        // is no search for something that is not a pattern.
        if let patternError {
            countLabel.stringValue = patternError.label
            countLabel.textColor = .systemRed
            countLabel.toolTip = patternError.detail
            countLabel.isHidden = false
            warningView.isHidden = true
            warningView.toolTip = nil
            return
        }
        countLabel.textColor = .secondaryLabelColor
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

    /// What the bar reads off the pane it describes (§11).
    ///
    /// The bar is one strip serving whichever pane is in front, and everything
    /// on it that describes a *search* describes that pane's search — in
    /// comparison mode the two panes have their own sets and their own results
    /// panels. So those readings travel together as one context, handed over
    /// whenever the active pane changes or its search does. A reading that
    /// arrives later becomes a field here, rather than another call the
    /// controller has to remember in each of the places a pane can change —
    /// which is how the results button came to keep the previous pane's state.
    ///
    /// What is *not* here: the pattern, the encoding, the case rule and Smart
    /// Search. Those are the user's standing choices, app-wide by design, and
    /// they do not change because another pane came forward.
    struct PaneContext: Equatable {
        /// The count region's reading: "3 of 128", "Not found", or nothing at
        /// all while no search of that pane's has come back.
        var count: FindCount?
        /// Whether that pane's results panel is on screen — what makes the
        /// results button read as on, since it is a toggle over that panel.
        var resultsShown: Bool
    }

    /// Points the bar at a pane, by handing it everything it reads off one.
    func apply(_ context: PaneContext) {
        show(count: context.count)
        setResultsShown(context.resultsShown)
    }

    /// Reflects whether the pane's results panel is open: the button is a
    /// toggle now, not a search (§11). Accent while the panel is up, the bar's
    /// quiet grey otherwise — the same "on" language the case toggle uses.
    private func setResultsShown(_ shown: Bool) {
        resultsShown = shown
        findAllButton.contentTintColor = shown ? .controlAccentColor : .secondaryLabelColor
        findAllButton.toolTip = shown ? "Hide Search Results" : "Show Search Results"
    }

    private var resultsShown = false
    var resultsShownForTests: Bool { resultsShown }

    /// What the count label reads, for tests.
    var countTextForTests: String { countLabel.stringValue }
    /// The field's menu, for tests: what the two lists hold, and what picking
    /// a row does.
    var patternMenuForTests: NSMenu? { patternField.searchMenuTemplate }
    /// Picks the menu row whose title starts with `prefix` — a favourite's
    /// name, or a recent's quoted pattern. Returns false when no row does.
    @discardableResult
    func pickPatternRowForTests(startingWith prefix: String) -> Bool {
        guard let item = patternMenuForTests?.items.first(where: {
            $0.representedObject != nil && ($0.attributedTitle?.string ?? $0.title)
                .hasPrefix(prefix)
        }), let action = item.action else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }
    /// The rows of the field's menu as they read, for the test that the two
    /// lists are one format apart.
    var patternMenuRowsForTests: [String] {
        (patternMenuForTests?.items ?? []).map { $0.attributedTitle?.string ?? $0.title }
    }
    /// Picks the menu's command with this title — the two lists' rows are
    /// picked by `pickPatternRowForTests`.
    @discardableResult
    func pickCommandForTests(_ title: String) -> Bool {
        guard let item = patternMenuForTests?.items.first(where: {
            $0.representedObject == nil && ($0.attributedTitle?.string ?? $0.title) == title
        }), let action = item.action else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }
    /// What the field holds, and what the popup names — for tests that assert
    /// a pick loaded all three.
    var patternTextForTests: String { patternField.stringValue }
    var encodingForTests: SearchEncoding { currentEncoding() }
    func setPatternForTests(_ text: String) { patternField.stringValue = text }
    func setEncodingForTests(_ encoding: SearchEncoding) {
        guard let index = SearchEncoding.allCases.firstIndex(of: encoding) else { return }
        encodingPopup.selectItem(at: index)
        encodingChanged()
    }

    /// Whether Smart Search reads as on, for tests.
    var smartSearchOnForTests: Bool { isSmartSearchEnabled }
    /// The encoding a picked entry (or a hand-chosen popup) left behind, for
    /// tests.
    var preferredEncodingForTests: SearchEncoding? { pickedEncoding }
    /// Its colour, for the test that an invalid pattern reads as an error.
    var countColorForTests: NSColor { countLabel.textColor ?? .labelColor }
    /// The label's tooltip — the count's withheld reason, or the full sentence
    /// behind a short "Invalid pattern".
    var countTooltipForTests: String? { countLabel.toolTip }
    /// Whether the count occupies any of the bar at all, for tests.
    var countShownForTests: Bool { !countLabel.isHidden }
    /// The warning glyph's sentence, or nil when it is not shown.
    var countWarningForTests: String? { warningView.isHidden ? nil : warningView.toolTip }
    /// Where the stepper sits in the bar, for the test that the count's width
    /// does not move it.
    var navControlFrameForTests: NSRect { navControl.frame }
    /// The pattern field's width, for the test that the count's slot is real
    /// and that the field is what gets it back.
    var patternFieldWidthForTests: CGFloat { patternField.frame.width }
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
        // Escape is *not* wired here any more. It belongs to the pattern
        // field: the first press closes the field's menu, the second clears
        // the field — which ends the search, since clearing is a text change
        // (§11). A find bar that takes Escape as its way out is one with no
        // clear control; this one has the field's ⊗, so Escape has an obvious
        // job that is not closing, and `Done` and the ⊗ are the exits
        // (`Design/PATTERN_LIBRARY_IDEA.md`).
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
        show(patternError: nil)
        if let mostRecent = FindHistoryStore.mostRecent {
            patternField.stringValue = mostRecent.pattern
            if let encodingIndex = SearchEncoding.allCases.firstIndex(of: mostRecent.encoding) {
                encodingPopup.selectItem(at: encodingIndex)
            }
            // The bar opens on the last search — pattern *and* the encoding it
            // was found in — which is the same pairing a pick out of the list
            // gives, so a Smart Search of it starts there (§11).
            pickedEncoding = mostRecent.encoding
        } else {
            patternField.stringValue = ""
            encodingPopup.selectItem(at: 0)
        }
        smartButton.state = Self.storedSmartSearch ? .on : .off
        syncSmartButtonAppearance()
        caseButton.state = (Self.defaults.object(forKey: Self.caseSensitiveKey) as? Bool ?? false) ? .on : .off
        syncCaseButtonAppearance()
        updateCaseButtonVisibility()
        rebuildPatternMenu()
        // Focus the field and select the prefilled text so typing replaces it.
        if window != nil {
            patternField.selectText(nil)
        }
    }

    /// Rebuilds the field's menu: the two lists and the commands that belong to
    /// each (§11, `Design/PATTERN_LIBRARY_IDEA.md`).
    ///
    /// A *template*: `NSSearchField` copies it on every click, so the menu is
    /// rebuilt whenever a list changes rather than mutated in place.
    @objc private func rebuildPatternMenu() {
        let menu = NSMenu()
        let recents = FindHistoryStore.recent
        if !recents.isEmpty {
            menu.addItem(Self.menuHeader("Recent Queries", symbol: "clock"))
            for entry in recents { menu.addItem(patternItem(for: entry)) }
            menu.addItem(.separator())
        }
        menu.addItem(command("Add to Favorites", #selector(addToFavorites)))
        if !recents.isEmpty {
            menu.addItem(command("Clear Recents", #selector(clearRecents)))
        }
        let favorites = FavoritePatternStore.favorites
        if !favorites.isEmpty {
            menu.addItem(.separator())
            menu.addItem(Self.menuHeader("Favorites", symbol: "star.fill"))
            for entry in favorites { menu.addItem(patternItem(for: entry)) }
        }
        menu.addItem(.separator())
        menu.addItem(command("Manage Favorites…", #selector(manageFavorites)))
        patternField.searchMenuTemplate = menu
    }

    /// A section header carrying an icon. Built by hand because
    /// `NSMenuItem.sectionHeader(title:)` takes only a title — a disabled item
    /// with the symbol as its image reads as a header just as well.
    private static func menuHeader(_ title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: menuFlagSize, weight: .semibold))
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: menuFlagSize, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    /// One row of either list: `Name: "pattern"  flags` for a favourite,
    /// `"pattern"  flags` for a recent — one renderer, because a favourite is a
    /// recent with a name (§11).
    ///
    /// The flags are grey and a size down: they say how the pattern is
    /// searched, not what is searched for. The case rule is stated either way,
    /// because "ignore case" is a fact and not the absence of one — except for
    /// hex, where bytes have no case and there is nothing to state.
    private func patternItem(for entry: SearchPatternEntry) -> NSMenuItem {
        let item = command(entry.name.isEmpty ? entry.pattern : entry.name,
                           #selector(patternPicked(_:)))
        item.representedObject = entry.storedValue
        let row: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.menuRowSize),
        ]
        let title = NSMutableAttributedString()
        if !entry.name.isEmpty {
            title.append(NSAttributedString(string: "\(entry.name): ", attributes: row))
        }
        title.append(NSAttributedString(string: "\"\(entry.pattern)\"", attributes: row))
        let flags = entry.encoding == .hex
            ? entry.encoding.displayName
            : "\(entry.encoding.displayName), "
                + (entry.caseSensitive ? "match case" : "ignore case")
        title.append(NSAttributedString(
            string: "  \(flags)",
            attributes: [.font: NSFont.systemFont(ofSize: Self.menuFlagSize),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        if !entry.isUsable {
            // A pattern that no longer parses can only have been hand-edited
            // into the store. It stays pickable — the pick puts it in the field
            // and the bar says what is wrong with it (§11) — and says so here.
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                 accessibilityDescription: "Invalid pattern")
        }
        return item
    }

    /// A menu row with a target and an action. Without both, `autoenablesItems`
    /// draws it dimmed.
    private func command(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: Self.menuRowSize)])
        return item
    }

    /// Writes `text` into the field without it counting as typing.
    ///
    /// The write goes through the live field editor when there is one: an
    /// active editor ignores `stringValue` until it commits. The caret lands at
    /// the end, because every caller is replacing the whole text rather than
    /// editing it.
    private func setPatternText(_ text: String) {
        if let editor = patternField.currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        patternField.stringValue = text
    }

    /// Writes a hex pattern back in the form a dump prints it — `deadbeef`
    /// becomes `DE AD BE EF` (§11).
    ///
    /// Only on a search, never while typing: it is the answer to "this is what
    /// I looked for", and a field that regrouped bytes under the caret would be
    /// unusable. The text is derived from the bytes, so it says exactly what
    /// was searched for — and because the history records what the field holds,
    /// the recents keep the same form. Text encodings are left alone: there the
    /// field holds the string itself, not a transcription of bytes.
    private func normalizeHexText(of pattern: SearchPattern) {
        guard pattern.encoding == .hex else { return }
        let text = pattern.hexText
        guard text != patternField.stringValue else { return }
        setPatternText(text)
    }

    /// ⌘F on a bar that is already open: the field takes focus and its text is
    /// selected, so typing replaces it — and nothing is rewritten (§11).
    ///
    /// The bar prefills from the history when it *opens*, which is the right
    /// reading of "the bar opens on the last search" and the wrong one for a
    /// bar already on screen: the user pressed ⌘F to correct the pattern in
    /// front of them, and a pattern that found nothing is not in the history to
    /// be prefilled from — nothing was found, so no encoding was adopted, so
    /// nothing was recorded.
    func focusForEditing() {
        window?.makeFirstResponder(patternField)
        patternField.selectText(nil)
    }

    /// Restores first responder to the pattern field after a search run from the
    /// bar, so a subsequent Enter keeps re-searching instead of landing on the
    /// hex view (§11).
    func focusPatternField() {
        window?.makeFirstResponder(patternField)
    }

    // MARK: - Actions

    /// The field's action fires on Return, which is a search. Nothing else
    /// reaches it: what used to arrive here as a picked list item is now a
    /// menu item with its own action (§11).
    @objc private func patternFieldAction() {
        runSearch(.forward)
    }

    /// A row of either list was picked: it fills the field — pattern, encoding
    /// and case rule — and runs the search. An entry is chosen deliberately,
    /// and the Return that would follow it never means anything else (§11).
    ///
    /// It records nothing in the history: the history is what was *typed*, and
    /// spending its ten slots on things already kept elsewhere is the problem
    /// the favourites exist to solve.
    @objc private func patternPicked(_ sender: NSMenuItem) {
        guard let stored = sender.representedObject as? [String: Any],
              let entry = SearchPatternEntry(stored: stored) else { return }
        apply(entry)
        runSearch(.forward, recordingHistory: false)
    }

    /// With an empty field there is nothing to keep, so the command is dimmed
    /// rather than absent — the same reading the stepper gives at zero matches
    /// (§11). Asked at menu-open time, which is the only moment the answer is
    /// wanted: the field's text moves with every keystroke and the menu is a
    /// template built far less often.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(addToFavorites) else { return true }
        return !patternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keeps what is in the field. The owner asks for a name and stores it —
    /// the bar has the pattern, the encoding and the case rule, and nothing
    /// else about a sheet (§11).
    @objc private func addToFavorites() {
        onAddToFavorites?(entryForField())
    }

    @objc private func clearRecents() {
        FindHistoryStore.clear()
        rebuildPatternMenu()
    }

    @objc private func manageFavorites() {
        onManageFavorites?()
    }

    /// What the field currently describes, as an entry: what "keep this one"
    /// keeps, and what the owner checks against the favourites already there.
    /// The encoding is the popup's, which after a Smart Search is the one that
    /// *worked* (§11).
    func entryForField() -> SearchPatternEntry {
        SearchPatternEntry(pattern: patternField.stringValue,
                           encoding: currentEncoding(),
                           caseSensitive: isCaseSensitive)
    }

    /// Typing in the pattern field ends the search that was running: the count
    /// clears, and the controller drops the pane's matches, so nothing on
    /// screen claims to describe a pattern that is no longer in the field.
    ///
    /// Clearing the field — by Escape, or by the ⊗ — arrives here too, which is
    /// how "Escape cancels the current search" needs no rule of its own (§11).
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === patternField else { return }
        // Typed over: whatever encoding a picked entry brought with it is not
        // about this text (§11).
        pickedEncoding = nil
        // Whatever the field said a moment ago — a count or a complaint about
        // it — was about the text that was there (§11).
        show(patternError: nil)
        show(count: nil)
        onPatternEdited?()
    }

    @objc private func encodingChanged() {
        updateCaseButtonVisibility()
        // Chosen by hand: with Smart Search off this *is* the search, and with
        // it on the choice replaces whatever a picked entry brought.
        pickedEncoding = currentEncoding()
        // The same text means something else now — `DE A` is not hex and is
        // perfectly good ASCII — so a complaint about it no longer stands.
        show(patternError: nil)
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

    /// Presses Find All the way a click does. The button is disabled until a
    /// search is live, so a test cannot click it into a first search.
    func pressFindAllForTests() {
        runSearchAll()
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

    private func runSearch(_ direction: SearchDirection, recordingHistory: Bool = true) {
        guard let request = searchRequest() else { return }  // reported inside
        if case .pattern(let pattern, _) = request { normalizeHexText(of: pattern) }
        noteSearchStarted(recording: recordingHistory)
        onSearch?(request, direction)
    }

    /// What the field is asking for, or nil when it is asking for nothing —
    /// which is reported where the count goes, or, for an empty field, by the
    /// owner, where "Not found" is said (§11).
    private func searchRequest() -> Request? {
        guard isSmartSearchEnabled else {
            guard let pattern = parsedPattern() else { return nil }
            return .pattern(pattern,
                            folding: CaseFolding(encoding: pattern.encoding,
                                                 caseSensitive: isCaseSensitive))
        }
        let text = patternField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onError?(Self.errorText(for: SearchError.emptyPattern))
            return nil
        }
        // With Smart Search on there is nothing here to validate: whether the
        // text can be read at all is a question about encodings, and the model
        // answers it — `reportNoUsablePattern()` is how it says no.
        show(patternError: nil)
        return .smart(text: text, caseSensitive: isCaseSensitive, preferring: pickedEncoding)
    }

    /// The encoding the field's contents arrived with, when they arrived from
    /// the history: a picked entry records the pattern *and* the encoding it
    /// was found in, and that pairing is the user's own knowledge — Smart
    /// Search tries it before its own guesses (§11).
    ///
    /// Cleared by any keystroke in the field: from then on the text is the
    /// user's and the encoding is the app's to work out. Also cleared when the
    /// popup is used by hand, which is a statement of its own that the
    /// non-smart path already acts on.
    private var pickedEncoding: SearchEncoding?

    /// The model found no encoding that can read what is in the field (§11).
    func reportNoUsablePattern() {
        show(patternError: "Invalid pattern",
             detail: "No encoding in the list can read that pattern.")
    }

    /// What was typed, at the moment a search was started, waiting to be
    /// remembered (§11).
    ///
    /// **The history is the searches that found something.** A pattern that
    /// occurs nowhere is not worth a slot in a list of ten, and the answer to
    /// "does it occur" is not in when the key is pressed: a Smart Search does
    /// not even know which encoding it is asking about yet, and the results
    /// button starts an index that answers later still. So the press keeps what
    /// was typed here, and the answer decides whether it is written down.
    ///
    /// Kept rather than read back off the field when the answer comes, because
    /// by then the user may be typing the next pattern.
    private var searchToRecord: (text: String, caseSensitive: Bool)?

    private func noteSearchStarted(recording: Bool) {
        // A row picked out of the menu records nothing: the history is what was
        // *typed*, and spending its ten slots on things already kept elsewhere
        // is the problem the favourites exist to solve (§11).
        searchToRecord = recording ? (patternField.stringValue, isCaseSensitive) : nil
    }

    /// The search that was started found something, in `encoding` — so it is
    /// worth offering again (§11).
    ///
    /// The pattern, the encoding it was found in and the case flag are what the
    /// next open offers and what the menu lists. The menu is rebuilt only when
    /// the history actually moved: a press of ‹ › within a search re-records
    /// the pair already at the front, and rebuilding a menu nobody opened is
    /// work for nothing.
    func recordFoundSearch(encoding: SearchEncoding) {
        guard let started = searchToRecord else { return }
        searchToRecord = nil
        if FindHistoryStore.record(pattern: started.text, encoding: encoding,
                                   caseSensitive: started.caseSensitive) {
            rebuildPatternMenu()
        }
    }

    /// The encoding a Smart Search settled on (§11): shown in the popup, so the
    /// bar says how the match was found, and recorded with the pattern, so the
    /// next search for it starts from the answer instead of hunting again.
    func adopt(encoding: SearchEncoding) {
        if let index = SearchEncoding.allCases.firstIndex(of: encoding) {
            encodingPopup.selectItem(at: index)
        }
        // What worked replaces what was asked for. Leaving the asked-for one
        // standing meant the next press started another pass from it — trying
        // UTF-16 BE and ASCII again before landing on the LE the search had
        // *already* settled on — instead of stepping the index it now has.
        pickedEncoding = encoding
        updateCaseButtonVisibility()
        // A pass that landed on hex found *bytes*, so the field says so the way
        // a dump does — and what is remembered says it too (§11).
        if encoding == .hex,
           let pattern = try? SearchEngine.parsePattern(patternField.stringValue,
                                                        encoding: encoding) {
            normalizeHexText(of: pattern)
            searchToRecord?.text = pattern.hexText
        }
    }

    /// Runs a Search All: the same parse + history bookkeeping as a plain
    /// search, but every occurrence is collected instead of moving the caret.
    private func runSearchAll() {
        guard let request = searchRequest() else { return }  // reported inside
        if case .pattern(let pattern, _) = request { normalizeHexText(of: pattern) }
        noteSearchStarted(recording: true)
        onSearchAll?(request)
    }

    private func parsedPattern() -> SearchPattern? {
        do {
            let pattern = try SearchEngine.parsePattern(patternField.stringValue,
                                                        encoding: currentEncoding())
            show(patternError: nil)
            return pattern
        } catch {
            // An empty field is not a bad pattern, it is no pattern — whatever
            // the parser threw about it (an empty hex string is "invalid hex").
            // There is nothing to report where the count goes, so it goes to
            // the owner, which says it the way it says "Not found".
            guard !patternField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                show(patternError: nil)
                onError?(Self.errorText(for: SearchError.emptyPattern))
                return nil
            }
            show(patternError: Self.errorLabel(for: error),
                 detail: Self.errorText(for: error))
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
    /// Loads a picked entry into the bar: the pattern, the encoding, and the
    /// case rule — all three, or the row was lying about what it searches (§11).
    ///
    /// The write goes through the live field editor when there is one: an
    /// active editor ignores `stringValue` until it commits.
    private func apply(_ entry: SearchPatternEntry) {
        setPatternText(entry.pattern)

        if let index = SearchEncoding.allCases.firstIndex(of: entry.encoding) {
            encodingPopup.selectItem(at: index)
        }
        // The pick names an encoding, so it is where a Smart Search starts
        // (§11) — the same statement choosing the popup by hand makes.
        pickedEncoding = entry.encoding
        // Hex is always byte-exact: its flag is recorded but never shown or
        // restored (§11).
        if entry.encoding != .hex {
            caseButton.state = entry.caseSensitive ? .on : .off
            Self.defaults.set(entry.caseSensitive, forKey: Self.caseSensitiveKey)
        }
        syncCaseButtonAppearance()
        updateCaseButtonVisibility()
        show(patternError: nil)
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
        // Smart Search will try the text encodings whatever the popup says, so
        // case is a live question even while the popup reads `Hex bytes` (§11).
        let foldable = isSmartSearchEnabled || Self.supportsCaseFolding(currentEncoding())
        caseButton.isHidden = !foldable
        caseButton.isEnabled = foldable
        syncCaseButtonAppearance()
    }

    // MARK: - Display

    /// The encoding popup's label — `SearchEncoding.displayName`, the same name
    /// the history dropdown and Smart Search's notice use, so one encoding
    /// reads as one thing wherever it appears.
    ///
    /// No "Text — " prefix in front of four of the five: the names carry
    /// themselves for anyone who reads dumps, and the prefix spent the bar's
    /// width saying what `UTF-8` already says. `Hex bytes` keeps its noun in
    /// the popup, where it is the one item that is not a text encoding — the
    /// shorter `Hex` reads as a display radix rather than as what the pattern
    /// is made of, which is the distinction the popup exists to make.
    private static func title(for encoding: SearchEncoding) -> String {
        encoding.displayName
    }

    /// The short form shown where the count goes. One wording for every way a
    /// pattern can fail to be one: the bar has room for a verdict, and the
    /// sentence that says which failure it was rides along as the tooltip.
    private static func errorLabel(for error: Error) -> String { "Invalid pattern" }

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
