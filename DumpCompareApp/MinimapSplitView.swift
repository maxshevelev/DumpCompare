import Cocoa

/// The vertical `NSSplitView` that shares the content area between the hex
/// panes (left) and the minimap panel (right).
///
/// Mirrors the Search All results split (§11) with the axis rotated: the
/// divider drag, the min/max clamping, and the collapse are native
/// `NSSplitView` behavior, driven through the delegate (`MainViewController`)
/// and `setPosition`. The panel is always an arranged subview (never
/// `isHidden`); hidden just means the divider sits at the right edge so the
/// panel is zero-width and natively collapsed.
///
/// The additions on top of the plain split are the width setter, the show/hide
/// animation, a one-shot initial-layout pin, and a resize override.
/// `setPanelWidth` is the programmatic width setter the controller (and tests)
/// use: it moves the divider to give the panel `width` points, clamped by the
/// delegate. The show/hide animation is a manual timer easing the divider from
/// its current position to the target, so a toggle glides instead of snapping —
/// the same pattern `ProportionalSplitView` uses for its fraction animation
/// (§3.3). The fitting-size overrides report no intrinsic size because a plain
/// vertical NSSplitView computes a concrete fitting width from its panes'
/// content (the empty minimap has none), which would let the first layout
/// collapse this split to a sliver. The pin is needed because NSSplitView's
/// default initial distribution ignores the delegate's clamp and would give the
/// minimap roughly half the content area. The resize override is needed for the
/// same reason one step later: the delegate's clamp governs a divider *drag*
/// only, so the default proportional resize carried the panel past its maximum
/// on a wide window.
final class MinimapSplitView: NSSplitView {
    /// The minimap keeps at least this width when shown (§19).
    static let minPanelWidth: CGFloat = 120

    /// The minimap never grows beyond this width (§19), so it stays a compact
    /// overview column beside the hex panes no matter how wide the window gets.
    static let maxPanelWidth: CGFloat = 240

    /// `UserDefaults` key for the user's chosen minimap width (§19).
    static let widthDefaultsKey = "MinimapPanelWidth"
    /// The store the panel width is read from and persisted to. Injectable so
    /// tests can point it at an isolated suite instead of the app's defaults.
    static var defaults: UserDefaults = .standard

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var fittingSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Whether the minimap panel is shown. Drives the split delegate's divider
    /// range: while hidden, both bounds pin the divider to the right edge so
    /// the panel sits at zero width and the hex panes reclaim the content area.
    private(set) var panelVisible = false

    /// Invoked whenever the panel is shown or hidden, with the new state. While
    /// hidden the panel draws nothing, so its maps and viewport are stale by the
    /// time it reappears; the controller refreshes them on a show (§19).
    var onPanelVisibilityChanged: ((Bool) -> Void)?

    /// True after the first real layout pinned the divider. The pin is the
    /// initial hidden state: NSSplitView distributes new panes ignoring the
    /// delegate's clamp, so without it the panel would open at roughly half
    /// the content area instead of collapsed (the minimap is hidden on launch).
    private var didPinInitialLayout = false

    /// A width asked for before the split had any bounds to place a divider in.
    /// `setPanelWidth` cannot act on a zero-width split, so it parks the value
    /// here and the first real layout applies it — otherwise a show that lands
    /// before the first layout leaves NSSplitView's default ~50/50 split in
    /// place and the panel opens at half the content area.
    private var pendingPanelWidth: CGFloat?

    /// Duration of a show/hide toggle's divider animation.
    private static let animationDuration: TimeInterval = 0.2
    /// Drives the animation; invalidated if the user grabs the divider again
    /// before it finishes.
    private var panelWidthTimer: Timer?
    /// Panel width at the moment the animation started.
    private var panelWidthStart: CGFloat = 0
    /// Panel width the animation is heading to.
    private var panelWidthTarget: CGFloat = 0
    /// Wall-clock time the animation started.
    private var panelWidthStartTime: TimeInterval = 0

    override func layout() {
        super.layout()
        // Pin the very first layout that has room: NSSplitView distributes new
        // panes ignoring the delegate's clamp. Normally that means collapsing
        // the panel (the minimap is hidden on launch); a show that ran before
        // any layout parked its width in `pendingPanelWidth` and lands here.
        guard !didPinInitialLayout, bounds.width > 0 else { return }
        didPinInitialLayout = true
        setPanelWidthDirect(pendingPanelWidth ?? (panelVisible ? preferredPanelWidth : 0))
        pendingPanelWidth = nil
    }

    /// Keeps the panel's width across a window resize instead of letting it
    /// grow with the window: the hex panes absorb the whole delta.
    ///
    /// NSSplitView's default distribution is proportional, and
    /// `constrainMin/MaxCoordinate` only govern a divider *drag* — so on a wide
    /// window the default carried the panel far past `maxPanelWidth` (a 2600 pt
    /// window opened it to ~390 pt). Re-clamping here is what actually holds
    /// the documented [min, max] band. Mid-animation frames are left alone so a
    /// show/hide glide is not snapped to its end state.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard isVertical, arrangedSubviews.count == 2 else {
            super.resizeSubviews(withOldSize: oldSize)
            return
        }
        // The width the panel had before this pass — what it should keep.
        let previousPanelWidth = arrangedSubviews[1].frame.width
        // Let the split do its own work first (heights, divider bookkeeping);
        // only the widths are then put back.
        super.resizeSubviews(withOldSize: oldSize)
        guard bounds.width > 0, panelWidthTimer == nil else { return }  // mid-toggle: leave the glide alone
        let content = arrangedSubviews[0]
        let panel = arrangedSubviews[1]
        let room = max(0, bounds.width - dividerThickness)
        let target = panelVisible
            ? min(min(max(previousPanelWidth, Self.minPanelWidth), Self.maxPanelWidth), room)
            : 0
        guard abs(panel.frame.width - target) > 0.5 else { return }
        let contentWidth = max(0, bounds.width - target - dividerThickness)
        content.frame = NSRect(x: 0, y: content.frame.minY,
                               width: contentWidth, height: content.frame.height)
        panel.frame = NSRect(x: contentWidth + dividerThickness, y: panel.frame.minY,
                             width: target, height: panel.frame.height)
    }

    /// The panel width the user last chose (or the built-in minimum), clamped
    /// to the legal [min, max] band. The caller is responsible for clamping to
    /// what the split can actually hold (`setPanelWidth` already does), so this
    /// also serves zoom-to-fit, which wants the preferred width regardless of
    /// how small the window is right now.
    var preferredPanelWidth: CGFloat {
        let stored = Self.defaults.object(forKey: Self.widthDefaultsKey) as? NSNumber
        let preferred = stored.map { CGFloat($0.doubleValue) } ?? Self.minPanelWidth
        return min(max(preferred, Self.minPanelWidth), Self.maxPanelWidth)
    }

    /// Shows or hides the panel, animating the divider unless the user prefers
    /// reduced motion (then it snaps).
    func setPanelVisible(_ visible: Bool, animated: Bool = true) {
        let changed = panelVisible != visible
        panelVisible = visible
        setPanelWidth(visible ? preferredPanelWidth : 0, animated: animated)
        if changed { onPanelVisibilityChanged?(visible) }
    }

    /// Toggles the panel's visibility (§19).
    func togglePanel(animated: Bool = true) {
        setPanelVisible(!panelVisible, animated: animated)
    }

    /// Moves the divider so the panel gets `width` points (clamped to the
    /// split's room by the delegate), animating unless reduced motion or the
    /// distance is a snap.
    func setPanelWidth(_ width: CGFloat, animated: Bool = false) {
        panelWidthTimer?.invalidate()
        panelWidthTimer = nil
        let total = bounds.width
        // No bounds yet: park the width for the first layout to apply.
        guard total > 0 else {
            pendingPanelWidth = max(0, width)
            return
        }
        let target = max(0, min(width, total - dividerThickness))
        let start = currentPanelWidth()
        if animated, window != nil,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           abs(start - target) > 0.5 {
            panelWidthStart = start
            panelWidthTarget = target
            panelWidthStartTime = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tickPanelWidthAnimation()
            }
            RunLoop.main.add(timer, forMode: .common)
            panelWidthTimer = timer
            tickPanelWidthAnimation()
        } else {
            setPanelWidthDirect(target)
        }
    }

    /// One animation tick: eases the panel width from its start to its target
    /// and places the divider. The native `setPosition` is the same call a
    /// divider drag makes, so programmatic sizing, animation, and user dragging
    /// go through one code path.
    private func tickPanelWidthAnimation() {
        let elapsed = ProcessInfo.processInfo.systemUptime - panelWidthStartTime
        let t = min(1, elapsed / Self.animationDuration)
        // Cubic ease-out: quick start, soft landing.
        let u = 1 - t
        let eased = 1 - u * u * u
        setPanelWidthDirect(panelWidthStart + (panelWidthTarget - panelWidthStart) * eased)
        if t >= 1 {
            setPanelWidthDirect(panelWidthTarget)
            panelWidthTimer?.invalidate()
            panelWidthTimer = nil
        }
    }

    private func setPanelWidthDirect(_ width: CGFloat) {
        let total = bounds.width
        guard total > 0 else { return }
        setPosition(max(0, total - width - dividerThickness), ofDividerAt: 0)
    }

    /// The panel's current width (right pane's thickness along the split axis).
    private func currentPanelWidth() -> CGFloat {
        guard arrangedSubviews.count == 2 else { return 0 }
        return max(0, bounds.width - arrangedSubviews[0].frame.width - dividerThickness)
    }

    deinit {
        panelWidthTimer?.invalidate()
    }
}
