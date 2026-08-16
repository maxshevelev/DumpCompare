import Cocoa

/// The minimap panel shown to the right of the hex panes (§ N).
///
/// Stage 2 lays the panel out: one file = one map, so single-file mode shows a
/// single map over the whole panel; side-by-side comparison splits the panel
/// with a vertical divider at its exact center (one map per pane); stacked
/// comparison splits it with a horizontal divider that mirrors the panes'
/// draggable divider — the line moves as the panes' divider moves. The maps
/// themselves are still empty; stage 3 fills them with the byte-conditional
/// lines.
final class MinimapView: NSView {
    /// How the panel is divided into maps for the open file(s).
    enum MapLayout {
        /// One map over the whole panel (single-file mode, or nothing open).
        case single
        /// Comparison, side-by-side panes: two maps split by a vertical line
        /// at the panel's exact center.
        case sideBySide
        /// Comparison, stacked panes: two maps split by a horizontal line at
        /// the same proportion as the panes' divider (top = pane 1).
        case stacked(fraction: CGFloat)
    }

    private(set) var mapLayout: MapLayout = .single

    /// Adopts a new map split, redrawing the divider lines only when the split
    /// actually changed (a stacked fraction can move by a hair on every pane
    /// divider tick, so compare with tolerance).
    func setMapLayout(_ layout: MapLayout) {
        guard !mapLayout.equivalent(to: layout) else { return }
        mapLayout = layout
        needsDisplay = true
    }

    /// The panel's quiet background — the same paper the hex dumps sit on, so
    /// the panel reads as part of the content area while idle.
    private static let background = NSColor.textBackgroundColor

    /// The divider between two maps — the same grey the pane split uses, so
    /// the minimap's internal split reads as an echo of the pane layout.
    private static let dividerFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.32, alpha: 1)
            : NSColor(white: 0.80, alpha: 1)
    }

    /// The maps draw top-down, matching the stacked panes' flipped coordinates
    /// (first pane on top), so a stacked divider lands at the same y as the
    /// panes' divider.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // A resize re-derives the divider's position from the new bounds (the
        // centered vertical line, or the fraction × new height), so repaint.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch mapLayout {
        case .single:
            break
        case .sideBySide:
            drawVerticalDivider(at: bounds.midX, in: dirtyRect)
        case .stacked(let fraction):
            let y = min(max(fraction, 0), 1) * bounds.height
            drawHorizontalDivider(at: y, in: dirtyRect)
        }
    }

    private func drawVerticalDivider(at x: CGFloat, in dirtyRect: NSRect) {
        guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { return }
        Self.dividerFill.setFill()
        let top = min(dirtyRect.maxY, bounds.maxY)
        let bottom = max(dirtyRect.minY, bounds.minY)
        guard top > bottom else { return }
        NSRect(x: x, y: bottom, width: 1, height: top - bottom).fill()
    }

    private func drawHorizontalDivider(at y: CGFloat, in dirtyRect: NSRect) {
        guard y >= dirtyRect.minY - 1, y <= dirtyRect.maxY + 1 else { return }
        Self.dividerFill.setFill()
        let right = min(dirtyRect.maxX, bounds.maxX)
        let left = max(dirtyRect.minX, bounds.minX)
        guard right > left else { return }
        NSRect(x: left, y: y, width: right - left, height: 1).fill()
    }
}

private extension MinimapView.MapLayout {
    /// Whether two layouts draw the same divider (a stacked fraction equal to
    /// within a hair counts as unchanged).
    func equivalent(to other: MinimapView.MapLayout) -> Bool {
        switch (self, other) {
        case (.single, .single), (.sideBySide, .sideBySide):
            return true
        case (.stacked(let a), .stacked(let b)):
            return abs(a - b) < 0.0001
        default:
            return false
        }
    }
}
