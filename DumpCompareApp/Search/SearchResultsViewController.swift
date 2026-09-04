import Cocoa
import DumpCompareCore

/// The Search All results panel (§11): a header ("Search results (NNN)" + a ×)
/// above a scrollable table listing every match of the pattern — one row per
/// occurrence with its offset, a hex excerpt of the surrounding bytes grouped
/// like the hex dump, and the decoded-text excerpt. The matched bytes are drawn
/// bold in both. Clicking a row reports the match's range so the pane can select
/// it in the dump, exactly as a single Find result would.
///
/// A controller rather than a bare view because *where* the panel appears is a
/// choice, not a property of the panel: today it shares the pane through a split
/// view, and the same panel should be able to go in a window of its own without
/// restructuring anything around it. Every presentation contract on macOS is
/// written in terms of a view controller — `contentViewController` for a window,
/// `addChild` for an embedded one, `presentAsSheet`, a popover's content — and a
/// bare `NSView` can only be assigned to `window.contentView`, which leaves
/// nobody owning its lifecycle and keeps it out of the responder chain.
///
/// There is no view subclass under it: the panel needed none. A subclass earns
/// its place when something must draw, handle events, lay out or accept drags —
/// and the composition here is a label, a button and a table in constraints,
/// which a controller assembles in `loadView` just as well.
///
/// What belongs here is the panel's content: the matches, how a row reads the
/// pane's live bytes, and what choosing one means. What deliberately does not is
/// how tall the panel is and where its divider sits — that is the pane's
/// arrangement of its own chrome (§11), and a panel in a window would size
/// itself differently.
///
/// The table is virtualized by `NSTableView` (views only for visible rows) and
/// reads bytes lazily per visible row, so a Search All with thousands of matches
/// renders and scrolls without materializing every excerpt.
@MainActor
final class SearchResultsViewController: NSViewController {
    /// What the panel is showing (§11) — derived from the pane's set on every
    /// read, never a copy of it.
    enum Content: Equatable {
        /// The pane's matches, as rows.
        case matches(total: Int)
        /// Too many to list: the count and the reason instead of rows. A list of
        /// four thousand rows looks exactly like a list of forty until you
        /// scroll to the end, so it would impersonate a tool.
        case tooMany(total: Int)
        /// The scan is still running and has found nothing so far. Distinct
        /// from `empty`: "no matches" is a verdict, and a search that has read
        /// a tenth of the file has not reached one.
        case searching
        /// Nothing to list: the search being shown found nothing — or the
        /// panel is hidden, where nobody reads it either way.
        case empty
    }

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

    /// Whether the panel is presenting the pane's search. Cleared by `clear()`,
    /// so a hidden panel lists nothing even where the pane's set outlives it.
    private var isPresenting = false

    /// The set the rows come from: the pane's own, read live. Not a copy — the
    /// scan behind the dump's highlighting is the one this lists, and a second
    /// copy is a second thing to keep in step (§11).
    private var matchSet: MatchSet? { isPresenting ? pane.matchSet : nil }

    /// The matches the table lists, in file order — none past the listing
    /// limit, and none for a set whose positions were never kept.
    private var listedCount: Int {
        guard let set = matchSet, set.isListable, set.isHighlightable else { return 0 }
        return set.total
    }

    /// The match a table row stands for, read out of the set on demand — the
    /// table asks only for the rows it draws.
    private func match(atRow row: Int) -> Range<UInt64>? {
        guard row >= 0, row < listedCount else { return nil }
        return matchSet?.range(at: row)
    }

    /// The bytes an excerpt shows, read from the pane's live storage.
    private func bytes(in window: Range<UInt64>) -> [UInt8] {
        guard let storage = pane.byteStorage else { return [] }
        return (try? storage.read(at: window.lowerBound, length: Int(window.count))) ?? []
    }

    /// The matches the table is listing. For tests: the rows are read from the
    /// pane's set one at a time, so there is no array to inspect.
    var listedMatchesForTesting: [Range<UInt64>] {
        (0..<listedCount).compactMap { match(atRow: $0) }
    }

    /// What the panel is showing — rows, or a count and the reason there are no
    /// rows (§11).
    private(set) var content: Content = .empty
    /// Shown instead of the table past the listing limit.
    private let messageLabel = NSTextField(labelWithString: "")

    /// The pattern's length in bytes for the search being shown. Every excerpt
    /// covers `2 * excerptPadding + matchLength` bytes, so it fixes the widest
    /// value each column can hold.
    private var matchLength: Int { matchSet?.patternLength ?? 1 }

    /// The pane's current file size, read live rather than snapshotted: the
    /// panel stays open across edits, and a size taken once would clamp the
    /// excerpt windows (and size the offset column) against a length the file
    /// no longer has (§11).
    private var fileSize: UInt64 { pane.fileSize }

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
    private var regularFont: NSFont { AppearanceSettings.font() }
    private var boldFont: NSFont { AppearanceSettings.boldFont() }

    private enum ColumnID {
        static let offset = NSUserInterfaceItemIdentifier("offset")
        static let hex = NSUserInterfaceItemIdentifier("hex")
        static let text = NSUserInterfaceItemIdentifier("text")
    }
    /// The panel's fill. An `NSBox` rather than a colour baked into a layer: a
    /// `CGColor` is resolved once, and the panel is built before it is in a
    /// window, so a later switch to dark mode used to leave it white — which is
    /// what the `viewDidChangeEffectiveAppearance` override existed for, and the
    /// only thing that kept this a view subclass. A box draws an `NSColor` and
    /// AppKit re-resolves it on its own (§3.1) — the move `DropTargetView`
    /// already makes with its material.
    private let background = NSBox()

    /// The document the rows are read from. Held for the panel's lifetime: the
    /// panel is made with its pane and discarded with it, and every row it draws
    /// is bytes read from here *live*, so an edit since the scan shows in the
    /// excerpt (§11).
    private let pane: PaneViewModel

    init(pane: PaneViewModel) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - The panel

    /// Builds the panel. Required rather than optional: `NSViewController`'s own
    /// implementation looks for a nib and raises when there is none, unlike
    /// UIKit's, which hands back an empty view.
    override func loadView() {
        // The panel is a frame-managed pane of the split view: the split sizes
        // it by setting its frame (`ALSplitView.addPane` turns off
        // `translatesAutoresizingMaskIntoConstraints`), so the constraints below
        // solve within whatever height the divider gives it.
        let panel = NSView()
        // Collapsed, the split gives the panel zero height; clipping keeps the
        // (unsized) header and table from painting over the status bar beneath.
        panel.wantsLayer = true
        panel.layer?.masksToBounds = true

        // A fill so the panel reads as a distinct strip between the dump and the
        // status bar; the 1px rule above it is drawn by the split's divider.
        background.boxType = .custom
        background.borderWidth = 0
        background.fillColor = .controlBackgroundColor
        // A box is a titled container by default, and it insets its content view
        // by 5 points on every side. Both are furniture this one does not want —
        // it is a fill, nothing else — and the inset is a required constraint
        // pair inside the box, which does not fit while the panel is collapsed
        // to zero width and says so on every layout pass.
        background.titlePosition = .noTitle
        background.contentViewMargins = .zero
        background.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(background)

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "Close search results")
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

        // Shown in the table's place past the listing limit (§11).
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(headerLabel)
        panel.addSubview(closeButton)
        panel.addSubview(scrollView)
        panel.addSubview(messageLabel)

        let scrollTop = scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor,
                                                        constant: 4)
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        // The bottom pin is preferred rather than required: collapsed to zero
        // height the table cannot fit, and a required pin would make every such
        // layout emit "unable to satisfy constraints". At normal heights it holds
        // and the table fills the panel; `height >= 0` keeps it from overrunning
        // the bottom edge while collapsed.
        scrollBottom.priority = .defaultHigh
        // The message's own trailing inset is preferred for the same reason as
        // the title's below: the panel is a frame-managed pane of the split
        // view and passes through a zero width — collapsed, and again while a
        // second pane is being added to a narrow window — where 12 points of
        // inset on each side do not fit. The leading pin stays required, so the
        // text keeps its left margin.
        let messageTrailing = messageLabel.trailingAnchor.constraint(
            equalTo: panel.trailingAnchor, constant: -12)
        messageTrailing.priority = .defaultHigh
        // The title's gap to the × is preferred for the same reason: a transient
        // zero-width layout cannot fit both in negative space.
        let titleToButton = headerLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6)
        titleToButton.priority = .defaultHigh
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: panel.topAnchor),
            background.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            headerLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            headerLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 5),
            titleToButton,

            closeButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            scrollTop,
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollBottom,

            messageLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            messageTrailing,
            messageLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
        ])
        view = panel
    }

    // MARK: - What the panel is showing (§11)

    /// Shows the pane's completed search (§11).
    ///
    /// There is no streaming any more, and nothing to hand in: the set already
    /// exists by the time the panel opens, because the scan that produced it is
    /// the one feeding the dump's highlighting
    /// (`Design/FIND_HIGHLIGHT_PLAN.md`), and it is the pane that holds it.
    /// Past the listing limit the panel says the count and why, instead of
    /// listing.
    ///
    /// The row wiring lives here rather than being handed in by the pane's
    /// view: what a row reads is the panel's business, and a panel presented
    /// some other way would need exactly the same answer.
    func show() {
        isPresenting = true
        reload()
    }

    /// Re-reads the pane's set, which a new search has replaced: the rows, the
    /// column widths and the header all come from it, so the panel and the dump
    /// can never be listing and highlighting two different searches (§11).
    ///
    /// Called only when the set itself changed — `PaneViewModel` keeps that on
    /// a channel of its own. A stepped indicator never gets here: this rebuilds
    /// the table, and rebuilding it drops the selection, so the row the user
    /// picked would stop being selected at the moment picking it moved the
    /// plate.
    func reload() {
        guard isPresenting else { return }
        content = Self.content(of: matchSet)
        sizeColumnsToContent()
        applyContent()
    }

    /// What a set reads as: rows, a count and a refusal, or nothing at all.
    private static func content(of set: MatchSet?) -> Content {
        guard let set else { return .empty }
        guard set.total > 0 else { return set.isComplete ? .empty : .searching }
        guard set.isListable, set.isHighlightable else { return .tooMany(total: set.total) }
        return .matches(total: set.total)
    }

    private func setUpTable() {
        // The widths here are placeholders: `configure` sizes every column to
        // the widest value it can actually hold for the search being shown
        // (§11). `minWidth` is only a floor for the user's own dragging, and it
        // is lowered when the content turns out narrower than it.
        let offsetColumn = NSTableColumn(identifier: ColumnID.offset)
        offsetColumn.title = "Offset"
        offsetColumn.width = 90
        offsetColumn.minWidth = 40
        let hexColumn = NSTableColumn(identifier: ColumnID.hex)
        hexColumn.title = "Excerpt Hex"
        hexColumn.width = 300
        hexColumn.minWidth = 60
        let textColumn = NSTableColumn(identifier: ColumnID.text)
        textColumn.title = "Excerpt Text"
        textColumn.width = 200
        textColumn.minWidth = 40
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

    /// Switches between the table and the message, and refreshes the header.
    private func applyContent() {
        switch content {
        case .matches:
            messageLabel.isHidden = true
            scrollView.isHidden = false
        case .tooMany(let total):
            messageLabel.stringValue = "\(Self.grouped(total)) matches — too many to list. "
                + "Refine the pattern."
            messageLabel.isHidden = false
            scrollView.isHidden = true
        case .empty:
            // A search that replaced the panel's rows with nothing says so
            // where the rows were. An empty table would read as a panel that
            // failed to load rather than as a pattern that occurs nowhere.
            messageLabel.stringValue = "No matches."
            messageLabel.isHidden = false
            scrollView.isHidden = true
        case .searching:
            messageLabel.stringValue = "Searching…"
            messageLabel.isHidden = false
            scrollView.isHidden = true
        }
        updateHeader()
        tableView.reloadData()
    }

    /// Sets each column's width to the widest value it can hold for this search.
    ///
    /// No row is measured. The value font is monospaced and every value has a
    /// known length: the offset is zero-padded to a fixed number of hex digits,
    /// and an excerpt covers at most `2 * excerptPadding + matchLength` bytes —
    /// "FF FF …" in the hex column, one glyph per byte in the text one. So the
    /// widest value per column is a template string, measured once (§11).
    ///
    /// The text column is exact for ASCII-ish decodings; a decoder that yields
    /// wide glyphs (CJK) can still overflow, and those values truncate with "…"
    /// as they always did. A total wider than the panel gets a horizontal
    /// scroller rather than clipping.
    private func sizeColumnsToContent() {
        let bytes = Int(Self.excerptPadding) * 2 + max(1, matchLength)
        let offsetDigits = max(8, String(fileSize, radix: 16).count)
        let templates: [NSUserInterfaceItemIdentifier: String] = [
            ColumnID.offset: String(repeating: "0", count: offsetDigits),
            ColumnID.hex: [String](repeating: "FF", count: bytes).joined(separator: " "),
            ColumnID.text: String(repeating: "W", count: bytes),
        ]
        let font = regularFont
        for column in tableView.tableColumns {
            guard let template = templates[column.identifier] else { continue }
            let value = (template as NSString).size(withAttributes: [.font: font]).width
            // For a short pattern the header title can be the wider of the two.
            let header = column.headerCell.attributedStringValue.size().width
            let width = ceil(max(value, header)) + 2 * SearchResultCellView.labelInset + 1
            // `width` is clamped to `minWidth`, so a column whose content is
            // narrower than its hand-picked floor needs the floor lowered.
            column.minWidth = min(column.minWidth, width)
            column.width = width
        }
    }

    private func updateHeader() {
        // While the index is still filling the count is "so far", and the
        // header says so rather than presenting a number that will grow (§11).
        let searching = !(matchSet?.isComplete ?? true)
        switch content {
        case .matches(let total), .tooMany(let total):
            let count = searching ? "\(Self.grouped(total)), searching…" : Self.grouped(total)
            headerLabel.stringValue = "Search results (\(count))"
        case .searching:
            headerLabel.stringValue = "Search results (searching…)"
        case .empty:
            headerLabel.stringValue = "Search results (0)"
        }
    }

    /// A count in the reader's region format — the same shape the Find bar's
    /// count uses.
    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Stops presenting (used when hiding the panel). The pane's set is not
    /// touched: hiding a list is not the end of the search it listed (§11).
    func clear() {
        isPresenting = false
        content = .empty
        applyContent()
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func rowClicked() {
        // A real click sets `clickedRow`; fall back to the selection so a
        // programmatic selection (tests, keyboard) reaches the same path.
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let match = match(atRow: row) else { return }
        onSelect?(match)
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

extension SearchResultsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        listedCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let match = match(atRow: row) else { return nil }
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SearchResultCellView)
            ?? SearchResultCellView(identifier: identifier)

        // The full excerpt is handed to the cell untruncated; the cell's
        // single-line label truncates it at the tail with "…" against whatever
        // width the column currently has, re-truncating automatically as the
        // user resizes the column (§11).
        switch identifier {
        case ColumnID.offset:
            cell.attributedText = offsetText(match.lowerBound)
        case ColumnID.hex:
            let (window, matchLocal) = excerptWindow(for: match)
            let bytes = bytes(in: window)
            cell.attributedText = hexExcerpt(bytes: bytes, matchLocal: matchLocal)
        case ColumnID.text:
            let (window, matchLocal) = excerptWindow(for: match)
            cell.attributedText = textExcerpt(bytes: bytes(in: window), matchLocal: matchLocal,
                                              decoder: pane.textDecoder)
        default:
            break
        }
        return cell
    }
}
