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
}
