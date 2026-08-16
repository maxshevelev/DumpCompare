import Cocoa
import DumpCompareCore

/// The Search All results panel shown at the bottom of a pane (§11): a header
/// ("Search results (NNN)" + a ×) above a scrollable table listing every match
/// of the pattern — one row per occurrence with its offset, a hex excerpt of the
/// surrounding bytes grouped like the hex dump, and the decoded-text excerpt.
/// The matched bytes are drawn bold in both excerpts. Clicking a row reports the
/// match's range so the pane can select it in the hex dump, exactly as a single
/// Find result would.
///
/// The table is virtualized by `NSTableView` (views only for visible rows) and
/// reads bytes lazily per visible row through `byteProvider`, so even a Search
/// All with thousands of matches renders and scrolls without materializing every
/// excerpt.
final class SearchResultsView: NSView {
    /// Fired when the user clicks a result row, with the match's byte range.
    var onSelect: ((Range<UInt64>) -> Void)?

    /// Fired when the user closes the panel (the ×).
    var onClose: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// The results table. Internal so tests can drive row clicks and inspect
    /// the excerpt cells.
    let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// The matches to show, in file order.
    private var matches: [Range<UInt64>] = []
    /// Whether a Search All is still scanning; while true the header's count
    /// gains a trailing "…" so a running search reads differently from a
    /// completed one (§11).
    private(set) var isSearching = false
    /// Whether the last Search All stopped at the match cap (the scan found
    /// `maxResults` occurrences and halted); the header then says so instead of
    /// presenting the count as final (§11).
    private(set) var isTruncated = false
    /// Reads `length` bytes at `offset` from the pane's live storage (clamped
    /// to EOF) for the row excerpts.
    private var byteProvider: ((UInt64, Int) -> [UInt8])?
    /// Decodes the excerpt bytes into the same characters the hex dump shows.
    private var textDecoder: (any TextDecoder)?
    /// The pane's file size, for clamping excerpt windows.
    private var fileSize: UInt64 = 0

    /// How many leading/trailing bytes an excerpt adds around a match.
    private static let excerptPadding: UInt64 = 8
    /// Default height of the panel when visible; the user's chosen height (a
    /// divider drag or the stored preference) overrides it (§11).
    static let panelHeight: CGFloat = 160

    /// The same monospaced font the hex dump uses (and its same-width bold
    /// variant), so the results table reads as part of the same document. Read
    /// live so a font-family change in Settings applies to the next Search All
    /// (§3.2). Regular and bold share the advance width, so bolding the match
    /// never shifts its neighbours — the bold reads as emphasis, not a layout
    /// change.
    private var regularFont: NSFont { AppearanceSettings.font(size: 13) }
    private var boldFont: NSFont { AppearanceSettings.boldFont(size: 13) }

    private enum ColumnID {
        static let offset = NSUserInterfaceItemIdentifier("offset")
        static let hex = NSUserInterfaceItemIdentifier("hex")
        static let text = NSUserInterfaceItemIdentifier("text")
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
        // The panel is a frame-managed pane of the native NSSplitView: the split
        // sizes it by setting its frame (the panel keeps the default
        // translatesAutoresizingMaskIntoConstraints == true), so the internal
        // constraints below solve within whatever height the divider gives it.

        // A background so the panel reads as a distinct strip between the hex
        // dump and the status bar; the 1px rule above it is drawn by the native
        // split divider.
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        // When the panel is hidden, the split gives it zero height; clipping to
        // the bounds keeps the (unsized) header and table from painting over
        // the status bar beneath the split.
        layer?.masksToBounds = true

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close search results")
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("Close search results")
        closeButton.toolTip = "Close search results"
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        setUpTable()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        addSubview(headerLabel)
        addSubview(closeButton)
        addSubview(scrollView)

        let scrollTop = scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4)
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        // The bottom pin is preferred rather than required: when the panel is
        // hidden (zero height) the table cannot fit, and a required bottom pin
        // would make every collapsed layout emit "unable to satisfy
        // constraints" warnings. At normal heights the pin holds and the table
        // fills the panel; the `height >= 0` keeps it from overrunning the
        // panel's bottom edge in the collapsed state.
        scrollBottom.priority = .defaultHigh
        // The title's gap to the × button is also preferred: a transient
        // zero-width layout (the split sizing the collapsed panel) cannot fit
        // the title and the button in negative space, and a required gap would
        // warn on every such pass. At normal widths it holds.
        let titleToButton = headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6)
        titleToButton.priority = .defaultHigh
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleToButton,

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            scrollTop,
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollBottom,
        ])
    }

    /// The panel's background layer bakes `controlBackgroundColor` when `setUp`
    /// runs — before the view is in a window — so switching to dark mode left
    /// the panel white. Re-resolve the dynamic color here, where the effective
    /// appearance is authoritative (§3.1).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private func setUpTable() {
        let offsetColumn = NSTableColumn(identifier: ColumnID.offset)
        offsetColumn.title = "Offset"
        offsetColumn.width = 90
        offsetColumn.minWidth = 70
        let hexColumn = NSTableColumn(identifier: ColumnID.hex)
        hexColumn.title = "Excerpt Hex"
        hexColumn.width = 300
        hexColumn.minWidth = 160
        let textColumn = NSTableColumn(identifier: ColumnID.text)
        textColumn.title = "Excerpt Text"
        textColumn.width = 200
        textColumn.minWidth = 80
        tableView.addTableColumn(offsetColumn)
        tableView.addTableColumn(hexColumn)
        tableView.addTableColumn(textColumn)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Single-click a row to jump to its match (§11).
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.setAccessibilityLabel("Search results")

        scrollView.documentView = tableView
    }

    // MARK: - Content

    /// Shows `matches` for the current search: updates the header's count and
    /// reloads the table. `byteProvider` reads the pane's live storage and
    /// `textDecoder` decodes the excerpt the same way the dump does.
    func configure(matches: [Range<UInt64>],
                   byteProvider: @escaping (UInt64, Int) -> [UInt8],
                   textDecoder: any TextDecoder,
                   fileSize: UInt64) {
        self.matches = matches
        self.byteProvider = byteProvider
        self.textDecoder = textDecoder
        self.fileSize = fileSize
        isSearching = false
        isTruncated = false
        updateHeader()
        tableView.reloadData()
    }

    /// Appends a freshly found batch of matches to the table and updates the
    /// header's count. Called repeatedly as a background Search All streams its
    /// results, so the table fills while the scan is still running (§11).
    func append(matches newMatches: [Range<UInt64>]) {
        guard !newMatches.isEmpty else { return }
        matches.append(contentsOf: newMatches)
        updateHeader()
        tableView.reloadData()
    }

    /// Marks whether a Search All is still scanning. While true the header's
    /// count keeps its trailing "…"; a completed search drops it, so the count
    /// reads as final (§11).
    func setSearching(_ searching: Bool) {
        guard isSearching != searching else { return }
        isSearching = searching
        updateHeader()
    }

    /// Marks whether the last Search All stopped at the match cap (the scan
    /// found `maxResults` occurrences and halted instead of completing). The
    /// header then reports the search returned too many results (§11).
    func setTruncated(_ truncated: Bool) {
        guard isTruncated != truncated else { return }
        isTruncated = truncated
        updateHeader()
    }

    private func updateHeader() {
        let count = matches.count
        if isSearching {
            headerLabel.stringValue = "Search results (\(count)…)"
        } else if isTruncated {
            headerLabel.stringValue = "Search results (\(count)) — too many results"
        } else {
            headerLabel.stringValue = "Search results (\(count))"
        }
    }

    /// Forgets the current results (used when hiding the panel).
    func clear() {
        matches = []
        byteProvider = nil
        textDecoder = nil
        isSearching = false
        isTruncated = false
        updateHeader()
        tableView.reloadData()
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func rowClicked() {
        // A real click sets `clickedRow`; fall back to the selection so a
        // programmatic selection (tests, keyboard) reaches the same path.
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < matches.count else { return }
        onSelect?(matches[row])
    }

    // MARK: - Excerpts

    /// The byte window an excerpt covers (8 bytes either side of the match,
    /// clamped to the file) and the match's local range within it — the run
    /// that must be drawn bold.
    private func excerptWindow(for match: Range<UInt64>)
        -> (window: Range<UInt64>, matchLocal: Range<Int>) {
        let start = match.lowerBound > Self.excerptPadding ? match.lowerBound - Self.excerptPadding : 0
        let end = min(match.upperBound + Self.excerptPadding, fileSize)
        let window = start..<end
        let matchLocal = Int(match.lowerBound - start)..<Int(match.upperBound - start)
        return (window, matchLocal)
    }

    /// The hex excerpt as one attributed string: "AB CD EF", a single
    /// space-separated block with no word grouping, the matched bytes bold.
    private func hexExcerpt(bytes: [UInt8], matchLocal: Range<Int>) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, byte) in bytes.enumerated() {
            let font = matchLocal.contains(index) ? boldFont : regularFont
            result.append(NSAttributedString(string: String(format: "%02X", byte),
                                             attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            if index < bytes.count - 1 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
        }
        return result
    }

    /// The decoded-text excerpt as one attributed string, the matched bytes
    /// bold and non-displayable placeholders dimmed — the same treatment the
    /// dump's text column gives them.
    private func textExcerpt(bytes: [UInt8], matchLocal: Range<Int>, decoder: any TextDecoder) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, byte) in bytes.enumerated() {
            let font = matchLocal.contains(index) ? boldFont : regularFont
            let color = decoder.isDisplayable(byte) ? NSColor.labelColor : NSColor.secondaryLabelColor
            result.append(NSAttributedString(string: String(decoder.decode(byte)),
                                             attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }

    /// Renders an excerpt truncated to `maxWidth` around the match: when the
    /// whole excerpt doesn't fit, keep the match and as much context as fits,
    /// marking the dropped bytes with "… " on the left and " …" on the right —
    /// the significant middle stays visible, not the ends. `cellsPerByte` is
    /// the glyph cells one byte occupies (3 for the hex column — "XX " — and 1
    /// for the text column); the budget reserves two "… " markers and rounds
    /// down, so the result never overflows the cell.
    private func truncatedExcerpt(bytes: [UInt8], matchLocal: Range<Int>,
                                  cellsPerByte: CGFloat, maxWidth: CGFloat,
                                  render: ([UInt8], Range<Int>) -> NSAttributedString) -> NSAttributedString {
        let n = bytes.count
        guard n > 0 else { return NSAttributedString() }
        let full = render(bytes, matchLocal)
        guard full.size().width > maxWidth else { return full }

        // Cells available for content after reserving the two markers; the
        // last byte has no trailing separator, hence the "+1".
        let charWidth = AppearanceSettings.charWidth(for: regularFont)
        let available = maxWidth / charWidth - 4
        let maxBytes = max(Int((available + 1) / cellsPerByte), 0)
        let budget = max(maxBytes, matchLocal.count)

        // A `budget`-byte window centred on the match, slid so it always
        // covers the whole match.
        var start = max(0, matchLocal.lowerBound - (budget - matchLocal.count) / 2)
        var end = min(n, start + budget)
        if matchLocal.lowerBound < start { start = matchLocal.lowerBound }
        if matchLocal.upperBound > end { end = matchLocal.upperBound }

        let shown = Array(bytes[start..<end])
        let shownMatch = (matchLocal.lowerBound - start)..<(matchLocal.upperBound - start)
        let result = NSMutableAttributedString()
        if start > 0 {
            result.append(NSAttributedString(string: "… ",
                                             attributes: [.font: regularFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        result.append(render(shown, shownMatch))
        if end < n {
            result.append(NSAttributedString(string: " …",
                                             attributes: [.font: regularFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return result
    }

    /// The match's start as padded uppercase hex — the same shape as the dump's
    /// offset column, which shows the row address in ink blue (§6).
    private func offsetText(_ offset: UInt64) -> NSAttributedString {
        let digits = max(8, String(fileSize, radix: 16).count)
        let text = String(offset, radix: 16, uppercase: true).leftPadded(to: digits, with: "0")
        return NSAttributedString(string: text, attributes: [
            .font: regularFont, .foregroundColor: HexTheme.inkBlue,
        ])
    }
}

// MARK: - Table data source / delegate

extension SearchResultsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < matches.count else { return nil }
        let match = matches[row]
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SearchResultCellView)
            ?? SearchResultCellView(identifier: identifier)

        // Available text width: the column's width minus the cell's padding.
        let maxWidth = max(tableColumn.width - 8, 0)
        switch identifier {
        case ColumnID.offset:
            cell.attributedText = offsetText(match.lowerBound)
        case ColumnID.hex:
            let (window, matchLocal) = excerptWindow(for: match)
            let bytes = byteProvider?(window.lowerBound, Int(window.count)) ?? []
            cell.attributedText = truncatedExcerpt(
                bytes: bytes, matchLocal: matchLocal, cellsPerByte: 3, maxWidth: maxWidth) { bytes, matchLocal in
                hexExcerpt(bytes: bytes, matchLocal: matchLocal)
            }
        case ColumnID.text:
            let (window, matchLocal) = excerptWindow(for: match)
            let bytes = byteProvider?(window.lowerBound, Int(window.count)) ?? []
            if let decoder = textDecoder {
                cell.attributedText = truncatedExcerpt(
                    bytes: bytes, matchLocal: matchLocal, cellsPerByte: 1, maxWidth: maxWidth) { bytes, matchLocal in
                    textExcerpt(bytes: bytes, matchLocal: matchLocal, decoder: decoder)
                }
            }
        default:
            break
        }
        return cell
    }
}

/// One table cell: a label that fills the cell and is updated per column on
/// reuse. The excerpt is pre-truncated around the match before it reaches the
/// label; the label's own tail truncation is only a safety net, so it never
/// wraps onto a second line.
final class SearchResultCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = AppearanceSettings.font(size: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var attributedText: NSAttributedString {
        get { label.attributedStringValue }
        set { label.attributedStringValue = newValue }
    }
}
