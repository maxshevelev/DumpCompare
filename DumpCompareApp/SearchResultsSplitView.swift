import Cocoa

/// The stacked `NSSplitView` that shares the pane between the hex dump and the
/// Search All results panel (§11).
///
/// The divider drag, the min/max clamping, and the collapse are the native
/// NSSplitView behavior, driven through the delegate (`FilePaneView`) and
/// `setPosition` — no custom drag or layout code. The panel is always an
/// arranged subview (never `isHidden`); hidden just means the divider sits at
/// the very bottom so the panel is zero-height and natively collapsed.
///
/// The overrides are `setPanelHeight`, the fitting-size properties, and a one
/// shot initial-layout pin. `setPanelHeight` is the programmatic height setter
/// the pane (and tests) use: it moves the divider to give the panel `height`
/// points, clamped to the pane's room by the delegate. The fitting-size
/// overrides report no intrinsic size because a plain stacked NSSplitView
/// computes a concrete fitting height from its panes' content (the results
/// table has none), which would let the pane's first layout collapse this split
/// to a sliver instead of stretching it to the leftover height between the
/// column header and the status bar. The pin is needed because NSSplitView's
/// default initial distribution ignores the delegate's clamp and would give
/// the panel roughly half the pane.
final class SearchResultsSplitView: NSSplitView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var fittingSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Whether the Search All results panel is shown. Drives the split
    /// delegate's divider range: while hidden, both bounds pin the divider to
    /// the bottom so the panel sits at zero height and the dump reclaims the
    /// pane (§11).
    var resultsPanelVisible = false

    /// True after the first real layout pinned the divider. The pin is the
    /// initial hidden state: NSSplitView distributes new panes ignoring the
    /// delegate's clamp, so without it the panel would open at roughly half the
    /// pane instead of collapsed (§11).
    private var didPinInitialLayout = false

    override func layout() {
        super.layout()
        // Pin only the very first layout that has room, and only while the
        // panel should be collapsed. A show that ran before any layout already
        // placed the divider, so leave it in place.
        guard !didPinInitialLayout, bounds.height > 0, !resultsPanelVisible else { return }
        didPinInitialLayout = true
        setPanelHeight(0)
    }

    /// Moves the divider so the results panel gets `height` points (clamped to
    /// the pane's room by the delegate). The native `setPosition` is the same
    /// call a divider drag makes, so programmatic sizing and user dragging go
    /// through one code path.
    func setPanelHeight(_ height: CGFloat) {
        let total = bounds.height
        guard total > 0 else { return }
        setPosition(max(0, total - height - dividerThickness), ofDividerAt: 0)
    }
}
