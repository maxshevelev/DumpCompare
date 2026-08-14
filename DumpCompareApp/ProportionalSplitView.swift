import Cocoa

/// An `NSSplitView` that divides its axis proportionally (§3.3).
///
/// NSSplitView's own layout sizes each pane from its content, which pins a
/// pane to the width of its header (a long file name makes a pane ~370pt wide)
/// and hands every window resize to the other pane. This subclass ignores
/// content sizes entirely and splits by a single ratio:
///
/// - a fresh comparison starts at 50/50;
/// - dragging the divider re-derives the ratio from where it actually lands;
/// - window resizes re-apply that same ratio to the new available space.
///
/// The ratio is recovered from the panes' current frames divided by the axis
/// size those frames were laid out against (`lastAvailable`), so a resize
/// cannot drift the ratio the way dividing by the *new* size would.
///
/// `layout()` is overridden (not `adjustSubviews`): on modern macOS NSSplitView
/// arranges its Auto Layout subviews through `layout()`, and `super.layout()`
/// would re-impose the content-based distribution on top of the divider
/// position, so the proportional frames are set here directly instead.
///
/// The divider-range overrides compensate for NSSplitView reporting a
/// degenerate range (min > max, pinned around the current position) for Auto
/// Layout subviews in a stacked split, which made `setPosition` clamp to a
/// no-op.
final class ProportionalSplitView: NSSplitView {
    /// Fraction (0...1) of the split axis given to the first pane.
    private var fraction: CGFloat = 0.5
    /// The axis size the panes' current frames were computed for. 0 until the
    /// first layout, which makes the initial split 50/50.
    private var lastAvailable: CGFloat = 0

    override func layout() {
        let arranged = arrangedSubviews
        guard arranged.count >= 2 else {
            super.layout()
            return
        }

        let total = isVertical ? bounds.width : bounds.height
        let dividerTotal = dividerThickness * CGFloat(arranged.count - 1)
        let available = max(0, total - dividerTotal)

        // The first pane's frame was produced against lastAvailable — either by
        // a divider drag (same available size) or by a previous proportional
        // layout. Recover its fraction so a resize preserves the ratio instead
        // of recomputing it against the new size.
        let firstThickness = isVertical ? arranged[0].frame.width : arranged[0].frame.height
        if lastAvailable > 0, firstThickness > 0 {
            fraction = min(max(firstThickness / lastAvailable, 0), 1)
        }
        lastAvailable = available

        let first = available * fraction
        let second = max(0, available - first)
        let width = bounds.width
        let height = bounds.height

        if isVertical {
            arranged[0].frame = NSRect(x: 0, y: 0, width: first, height: height)
            arranged[1].frame = NSRect(x: first + dividerThickness, y: 0, width: second, height: height)
        } else {
            // Stacked split: the first pane sits on top (AppKit coordinates
            // grow upward, so it occupies the top of the bounds).
            arranged[0].frame = NSRect(x: 0, y: height - first, width: width, height: first)
            arranged[1].frame = NSRect(x: 0, y: 0, width: width, height: second)
        }
    }

    // MARK: - Divider range

    override func minPossiblePositionOfDivider(at dividerIndex: Int) -> CGFloat {
        0
    }

    override func maxPossiblePositionOfDivider(at dividerIndex: Int) -> CGFloat {
        let total = isVertical ? bounds.width : bounds.height
        let dividerTotal = dividerThickness * CGFloat(max(0, arrangedSubviews.count - 1))
        return max(0, total - dividerTotal)
    }
}
