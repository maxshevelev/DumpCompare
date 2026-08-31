import Cocoa

/// The owner of the Search All results panel (§11).
///
/// A controller rather than a bare view because *where* the panel appears is a
/// choice, not a property of the panel: today it shares the pane through a
/// split view, and it should be possible to put the same panel in a window of
/// its own without restructuring anything around it. Every presentation
/// contract on macOS is written in terms of a view controller —
/// `contentViewController` for a window, `addChild` for an embedded one,
/// `presentAsSheet`, a popover's content — and a bare `NSView` can only be
/// assigned to `window.contentView`, which leaves nobody owning its lifecycle
/// and keeps it out of the responder chain.
///
/// What belongs here is the panel's *content*: the matches, how a row is read
/// from the pane's live bytes, and what selecting one means. What deliberately
/// does not is how tall the panel is and where its divider sits — that is the
/// pane's arrangement of its own chrome (§11), and a panel in a window would
/// size itself differently.
@MainActor
final class SearchResultsViewController: NSViewController {
    /// The panel's view. Still a `SearchResultsView` for now: the table, the
    /// header and the row cells live there, and moving that composition into
    /// this controller is a separate step from giving it an owner.
    let resultsView = SearchResultsView()

    /// The document the rows are read from. Held for the panel's lifetime: the
    /// panel is made with its pane and discarded with it, and every row it
    /// draws is bytes read from here *live*, so an edit since the scan shows in
    /// the excerpt (§11).
    private let pane: PaneViewModel

    init(pane: PaneViewModel) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether a scan is still feeding the panel — the header's "…" count.
    var isSearching: Bool { resultsView.isSearching }

    /// Fired when a result row is chosen — the pane selects the range and
    /// scrolls to it (§11).
    var onSelect: ((Range<UInt64>) -> Void)? {
        get { resultsView.onSelect }
        set { resultsView.onSelect = newValue }
    }

    /// Fired when the panel's × is clicked. Closing the panel also stops the
    /// search feeding it, which is the pane's business to arrange.
    var onClose: (() -> Void)? {
        get { resultsView.onClose }
        set { resultsView.onClose = newValue }
    }

    /// The view is built in code, not loaded from a nib — so this override is
    /// required rather than optional: `NSViewController`'s own implementation
    /// looks for a nib and raises when there is none, unlike UIKit's, which
    /// hands back an empty view.
    override func loadView() {
        view = resultsView
    }

    // MARK: - What the panel is showing (§11)

    /// Opens the panel for a scan that is about to start: no rows yet, the
    /// header counting with a "…", and every row it will draw wired to the
    /// pane's live bytes.
    ///
    /// The wiring lives here rather than in the pane's view, which used to hand
    /// it in: what a row reads is the panel's business, and a panel presented
    /// some other way would need exactly the same answer.
    func beginSearch(matchLength: Int) {
        let pane = self.pane
        resultsView.configure(
            matches: [],
            byteProvider: { [weak pane] offset, length in
                guard let storage = pane?.byteStorage else { return [] }
                return (try? storage.read(at: offset, length: length)) ?? []
            },
            textDecoder: pane.textDecoder,
            fileSize: { [weak pane] in pane?.fileSize ?? 0 },
            matchLength: matchLength)
        resultsView.setSearching(true)
    }

    /// A batch of matches the running scan just found. Called as they arrive, so
    /// the first row appears when it is found rather than when the scan ends.
    func append(_ matches: [Range<UInt64>]) {
        resultsView.append(matches: matches)
    }

    /// The scan finished: the count settles (the "…" goes). `truncated` says
    /// there were more matches than the panel shows, in which case it says so
    /// instead of giving a count that would be a lie.
    func finishSearch(truncated: Bool) {
        if truncated { resultsView.setTruncated(true) }
        resultsView.setSearching(false)
    }

    /// The panel goes empty and quiet — the ×, a cancelled scan, or a
    /// structural edit that moved every offset out from under the results.
    func clear() {
        resultsView.clear()
    }
}
