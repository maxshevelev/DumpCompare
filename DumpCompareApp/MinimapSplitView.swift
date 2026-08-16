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
/// The additions on top of the plain split are the width setter, the
/// show/hide animation, and a one-shot initial-layout pin. `setPanelWidth` is
/// the programmatic width setter the controller (and tests) use: it moves the
/// divider to give the panel `width` points, clamped by the delegate. The
/// show/hide animation is a manual timer easing the divider from its current
/// position to the target, so a toggle glides instead of snapping — the same
/// pattern `ProportionalSplitView` uses for its fraction animation (§3.3). The
/// fitting-size overrides report no intrinsic size because a plain vertical
/// NSSplitView computes a concrete fitting width from its panes' content (the
/// empty minimap has none), which would let the first layout collapse this
/// split to a sliver. The pin is needed because NSSplitView's default initial
/// distribution ignores the delegate's clamp and would give the minimap
/// roughly half the content area.
final class MinimapSplitView: NSSplitView {
    /// The minimap keeps at least this width when shown (§ N).
    static let minPanelWidth: CGFloat = 80

    /// The minimap never grows beyond a quarter of the screen's visible width
    /// (§ N), so the hex dump keeps at least three quarters of the screen even
    /// at a huge divider drag. In a headless test host there is no screen; the
    /// generous fallback keeps the divider draggable there.
    static var maxPanelWidth: CGFloat {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 0
        guard screenWidth > 0 else { return 2000 }
        return screenWidth / 4
    }

    /// `UserDefaults` key for the user's chosen minimap width (§ N).
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

    /// True after the first real layout pinned the divider. The pin is the
    /// initial hidden state: NSSplitView distributes new panes ignoring the
    /// delegate's clamp, so without it the panel would open at roughly half
    /// the content area instead of collapsed (the minimap is hidden on launch).
    private var didPinInitialLayout = false

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
        // Pin only the very first layout that has room, and only while the
        // panel should be collapsed. A show that ran before any layout already
        // placed the divider, so leave it in place.
        guard !didPinInitialLayout, bounds.width > 0, !panelVisible else { return }
        didPinInitialLayout = true
        setPanelWidthDirect(0)
    }

    /// The panel width the user last chose (or the built-in minimum), clamped
    /// to what the current split can actually hold — the panel can never be
    /// wider than the content area, so a width persisted from a wider window
    /// shrinks to fit.
    var preferredPanelWidth: CGFloat {
        let total = bounds.width
        let stored = Self.defaults.object(forKey: Self.widthDefaultsKey) as? NSNumber
        let preferred = stored.map { CGFloat($0.doubleValue) } ?? Self.minPanelWidth
        return min(max(preferred, Self.minPanelWidth), max(0, total - dividerThickness))
    }

    /// Shows or hides the panel, animating the divider unless the user prefers
    /// reduced motion (then it snaps).
    func setPanelVisible(_ visible: Bool, animated: Bool = true) {
        panelVisible = visible
        setPanelWidth(visible ? preferredPanelWidth : 0, animated: animated)
    }

    /// Toggles the panel's visibility (§ N).
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
        guard total > 0 else { return }
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
