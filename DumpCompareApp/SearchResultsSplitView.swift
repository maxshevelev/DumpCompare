import Cocoa

/// The stacked `NSSplitView` that shares the pane between the hex dump and the
/// Search All results panel (§11).
///
/// The divider drag, the min/max clamping, and the collapse are the native
/// NSSplitView behavior, driven through the delegate (`FilePaneView`) and
/// `setPosition` — no custom drag or layout code.
///
/// The only overrides are `setPanelHeight` and the fitting-size properties.
/// `setPanelHeight` is the programmatic height setter the pane (and tests) use:
/// it records the panel's preferred height (which becomes its intrinsic size,
/// so the split sizes the panel to it natively) and moves the divider to match.
/// The fitting-size overrides report no intrinsic size because a plain stacked
/// NSSplitView computes a concrete fitting height from its panes' content (the
/// results table has none), which would let the pane's first layout collapse
/// this split to a sliver instead of stretching it to the leftover height
/// between the column header and the status bar.
final class SearchResultsSplitView: NSSplitView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var fittingSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
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
