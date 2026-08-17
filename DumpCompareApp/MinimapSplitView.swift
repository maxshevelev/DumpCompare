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

/// The minimap panel's chrome (§19.2): a header carrying the Local/Overview
/// switch, the map below it, and a status bar that reports a full overview
/// rebuild.
///
/// The chrome is what lines the map up with the bytes it mirrors. A pane puts a
/// title bar and a column header above its dump and a status bar below it
/// (§3.4), so a bare map started higher and ended lower than the dump beside it
/// and the two never quite read as the same file. The heights are therefore not
/// constants here: the controller measures the pane's own dump area and hands
/// them over (`setChromeHeights`).
///
/// The mode switch is in the header because the choice is one a reader makes
/// constantly — a local map to read the bytes around the caret, an overview to
/// find the region to go to — and a menu item alone (§15) hides it.
final class MinimapPanelView: NSView {
    let mapView: MinimapView

    /// Local ⇄ Overview (§19.4). Internal so tests can click it.
    let modeSwitch = MinimapModeSwitch()

    /// The status bar's progress bar and its caption, shown only while a rebuild
    /// is running (§19.9).
    let progressBar = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")

    /// Fired when the user picks a mode in the header.
    var onModeChange: ((MinimapView.RenderMode) -> Void)?

    private let header = NSView()
    private let statusBar = NSView()
    private var headerHeight: NSLayoutConstraint!
    private var statusBarHeight: NSLayoutConstraint!

    init(mapView: MinimapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        // Set here rather than by the owner: the chrome's own constraints are
        // activated below, and a moment spent in autoresizing mode with a zero
        // frame makes them unsatisfiable.
        translatesAutoresizingMaskIntoConstraints = false
        modeSwitch.onChange = { [weak self] mode in self?.onModeChange?(mode) }
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        // A narrow panel must be allowed to squeeze the labels rather than push
        // the panel wider than its clamp (§19.2).
        modeSwitch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .systemFont(ofSize: 10)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.isHidden = true
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        mapView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(modeSwitch)
        statusBar.addSubview(progressLabel)
        statusBar.addSubview(progressBar)
        addSubview(header)
        addSubview(mapView)
        addSubview(statusBar)

        // Breakable, like the side insets: the split view sizes this panel by
        // frame — including a degenerate frame during a toggle — and a chrome
        // that insisted on its height would be reported as unsatisfiable each
        // time. At any real height the constraints hold exactly.
        headerHeight = breakable(header.heightAnchor.constraint(
            equalToConstant: Self.defaultHeaderHeight))
        statusBarHeight = breakable(statusBar.heightAnchor.constraint(
            equalToConstant: Self.defaultStatusBarHeight))
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,
            // The switch sits in the header's top band, level with the panes'
            // file names, rather than in the middle of a header that is as tall
            // as a title bar plus a column header.
            modeSwitch.centerYAnchor.constraint(equalTo: header.topAnchor,
                                                constant: Self.switchBandHeight / 2),
            // Breakable: a hidden panel is zero points wide (§19.1), which no
            // side inset can survive, and a conflict logged on every toggle is
            // noise that hides real ones.
            breakable(modeSwitch.leadingAnchor.constraint(equalTo: header.leadingAnchor,
                                                          constant: 8)),
            breakable(modeSwitch.trailingAnchor.constraint(equalTo: header.trailingAnchor,
                                                           constant: -8)),
            breakable(modeSwitch.heightAnchor.constraint(
                equalToConstant: MinimapModeSwitch.height)),

            mapView.topAnchor.constraint(equalTo: header.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBarHeight,
            breakable(progressLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor,
                                                             constant: 8)),
            progressLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            breakable(progressBar.leadingAnchor.constraint(equalTo: progressLabel.trailingAnchor,
                                                           constant: 6)),
            breakable(progressBar.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor,
                                                            constant: -8)),
            progressBar.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    /// Lets a constraint yield instead of being reported as unsatisfiable.
    private func breakable(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = .defaultHigh
        return constraint
    }

    /// The band the mode switch is centred in — a pane's title bar, so the
    /// switch lines up with the file names beside it.
    static let switchBandHeight = FilePaneView.headerHeight

    /// Used until the panes report their own geometry: a title bar plus a
    /// column header of a default row.
    static let defaultHeaderHeight = FilePaneView.headerHeight + 21
    static let defaultStatusBarHeight = FilePaneView.statusBarHeight

    /// The map never gives up more than this to the chrome.
    static let minimumMapHeight: CGFloat = 60

    /// Where the dump this map mirrors currently sits, in window coordinates.
    /// Supplied by the controller, which owns the panes, and asked on every
    /// layout pass — so the chrome follows the bytes without the controller
    /// having to notice each separate thing that moves them.
    var dumpAreaInWindow: (() -> NSRect?)?

    override func layout() {
        alignChromeToDump()
        super.layout()
    }

    /// Derives the chrome heights from the dump's own rectangle: the map's top
    /// and bottom edges then land on the dump's, whatever the pane put above
    /// them (§19.2).
    private func alignChromeToDump() {
        guard window != nil, let dump = dumpAreaInWindow?() else { return }
        let panel = convert(bounds, to: nil)
        guard panel.height > 0, dump.height > 0 else { return }
        setChromeHeights(top: panel.maxY - dump.maxY, bottom: dump.minY - panel.minY)
    }

    /// Matches the chrome to the panes', so the map starts and ends exactly
    /// where the dump does. The header never shrinks below the band the switch
    /// lives in.
    func setChromeHeights(top: CGFloat, bottom: CGFloat) {
        var top = max(Self.switchBandHeight, top)
        var bottom = max(0, bottom)
        // The map comes first: a Search All panel (§11) can take most of the
        // pane's height, and matching it exactly would leave no map at all.
        let available = bounds.height
        if available > 0, top + bottom > available - Self.minimumMapHeight {
            let spare = max(0, available - Self.minimumMapHeight - top)
            bottom = min(bottom, spare)
            top = min(top, max(Self.switchBandHeight, available - Self.minimumMapHeight))
        }
        guard abs(headerHeight.constant - top) > 0.5
            || abs(statusBarHeight.constant - bottom) > 0.5 else { return }
        headerHeight.constant = top
        statusBarHeight.constant = bottom
    }

    /// Reflects the mode the map is actually in, without reporting a change back.
    func showMode(_ mode: MinimapView.RenderMode) {
        modeSwitch.showMode(mode)
    }

    /// Shows a rebuild's progress, or hides the status bar's contents when there
    /// is nothing running. `fraction` is nil while idle.
    func setRebuildProgress(_ fraction: Double?) {
        guard let fraction else {
            progressBar.isHidden = true
            progressLabel.isHidden = true
            return
        }
        progressLabel.stringValue = "Building"
        progressBar.doubleValue = min(1, max(0, fraction))
        progressBar.isHidden = false
        progressLabel.isHidden = false
    }

}

/// The minimap's Local ⇄ Overview switch (§19.4), drawn rather than assembled
/// from an `NSSegmentedControl`.
///
/// A stock segmented control did not appear in the panel at all: on this macOS
/// its artwork is drawn by an internal SwiftUI hosting view, and while every
/// check from inside the process said the control was laid out, enabled, on top
/// at its own centre and had its text layers, nothing of it reached the screen.
/// This app draws its own hex grid, column header and minimap already, so a
/// drawn switch is both in keeping and free of that indirection — and, unlike a
/// hosted control, it can be verified by sampling pixels in a test.
final class MinimapModeSwitch: NSView {
    /// Fired when the user picks a mode; not fired by `showMode`.
    var onChange: ((MinimapView.RenderMode) -> Void)?

    private(set) var mode: MinimapView.RenderMode = .detail

    /// The two halves, in order.
    private static let modes: [(mode: MinimapView.RenderMode, title: String)] =
        [(.detail, "Local"), (.overview, "Overview")]

    private static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let cornerRadius: CGFloat = 5
    static let height: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Minimap mode")
        toolTip = "Whether the minimap shows the bytes around the caret or the whole file"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    override var isFlipped: Bool { true }

    /// Adopts a mode without reporting it back — for reflecting the map's state
    /// when something else (the View menu, a file that defaults to overview)
    /// changed it.
    func showMode(_ mode: MinimapView.RenderMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        setAccessibilityValue(title(of: mode))
        needsDisplay = true
    }

    private func title(of mode: MinimapView.RenderMode) -> String {
        Self.modes.first { $0.mode == mode }?.title ?? ""
    }

    /// The half a mode occupies.
    private func rect(of mode: MinimapView.RenderMode) -> NSRect {
        let index = Self.modes.firstIndex { $0.mode == mode } ?? 0
        let width = bounds.width / CGFloat(Self.modes.count)
        return NSRect(x: bounds.minX + width * CGFloat(index), y: bounds.minY,
                      width: width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 4, bounds.height > 4 else { return }
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.controlColor.setFill()
        track.fill()
        NSColor.separatorColor.setStroke()
        track.lineWidth = 1
        track.stroke()

        // The selected half is a filled pill in the accent colour: on a panel
        // this narrow the selection has to be unmistakable at a glance.
        let selected = rect(of: mode).insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: selected, xRadius: Self.cornerRadius - 1,
                     yRadius: Self.cornerRadius - 1).fill()

        for (mode, title) in Self.modes {
            let isSelected = mode == self.mode
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: isSelected ? NSColor.white : NSColor.secondaryLabelColor,
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            let half = rect(of: mode)
            // Clipped to its own half, so a narrow panel truncates a label
            // instead of letting the two collide.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: half).setClip()
            (title as NSString).draw(
                at: NSPoint(x: half.midX - size.width / 2, y: half.midY - size.height / 2),
                withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let index = point.x < bounds.midX ? 0 : 1
        let picked = Self.modes[index].mode
        guard picked != mode else { return }
        showMode(picked)
        onChange?(picked)
    }

    /// Keyboard and VoiceOver reach the same choice through the View menu (§15),
    /// so the switch itself is not a focus stop — but it must still describe
    /// itself to a reader.
    override func isAccessibilityElement() -> Bool { true }
}
