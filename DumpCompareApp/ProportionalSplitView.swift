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
/// The ratio is kept per pane layout (§3.3): side-by-side and stacked each
/// remember their own divider position, so toggling the arrangement restores
/// the other layout's proportion instead of carrying the dragged one over.
///
/// The panes' edges are bound with constraints, not just frames (§3.3):
///
/// - the first pane's trailing edge (vertical) / bottom edge (stacked) is tied
///   to the divider position via `dividerConstraint` — "left pane's right edge
///   is bound to the divider";
/// - the second pane's trailing edge (vertical) / top edge (stacked) is pinned
///   to this view's trailing/top edge by NSSplitView's own `Edge.Trailing`
///   constraint — "right pane's right edge is bound to the window's right
///   edge";
/// - neither pane width is fixed: both follow divider position + available
///   space, so a resize redistributes proportionally.
///
/// The divider-position constraint sits just below required (999): it is
/// strong enough to beat NSSplitView's preferred-size hints and re-solve to
/// the same proportional frames `layout()` computes, but it yields to the
/// panes' content minimum instead of breaking their layout if a drag or a
/// degenerate first layout would squeeze a pane below usable size.
///
/// The divider drag is handled here as well, not left to NSSplitView:
/// NSSplitView's built-in drag tracks the mouse through its own internal
/// path and then runs its content-based layout on top of it, which fights
/// the proportional frames and snaps the divider back on mouse-up. Intercepting
/// `mouseDown`/`mouseDragged`/`mouseUp` on the divider lets the drag update the
/// ratio directly and re-apply it — no interference.
///
/// `layout()` is overridden (not `adjustSubviews`): on modern macOS NSSplitView
/// arranges its Auto Layout subviews through `layout()`, and `super.layout()`
/// would re-impose the content-based distribution on top of the divider
/// position, so the proportional frames are set here directly instead.
///
/// The divider-range overrides compensate for NSSplitView reporting a
/// degenerate range (min > max, pinned around the current position) for Auto
/// Layout subviews in a stacked split, which clamped a programmatic divider move
/// to a no-op.
final class ProportionalSplitView: NSSplitView {
    /// Fraction (0...1) of the split axis given to the first pane, stored per
    /// pane layout (§3.3): side-by-side (vertical) and stacked (horizontal) each
    /// keep their own divider proportion, so dragging the divider in one
    /// arrangement never changes the other's. 0.5 until a divider drag or
    /// a 50/50 reset changes it; resizes never touch it.
    private var verticalFraction: CGFloat = 0.5
    private var horizontalFraction: CGFloat = 0.5

    /// The fraction for the CURRENT layout: `isVertical` picks which slot to
    /// read or write, so every existing read/write in the layout, drag and
    /// animation paths already targets the active arrangement.
    private var fraction: CGFloat {
        get { isVertical ? verticalFraction : horizontalFraction }
        set { if isVertical { verticalFraction = newValue } else { horizontalFraction = newValue } }
    }

    /// Called whenever the divider fraction changes — a drag, an animation tick,
    /// the 50/50 reset, a fit-to-content move. The minimap uses it to keep its
    /// stacked divider line glued to the panes' divider.
    var onFractionChanged: (() -> Void)?

    /// The current split fraction of the first pane along the split axis
    /// (0...1), read by the minimap so its stacked divider mirrors the panes'.
    var currentFraction: CGFloat { fraction }

    /// Binds the first pane's trailing/bottom edge to the divider position
    /// (§3.3). Kept in sync with the frames `layout()` sets, so the layout
    /// engine and the drag agree about where the divider sits.
    private var dividerConstraint: NSLayoutConstraint?
    /// The axis `dividerConstraint` was built for; rebuilt when it flips.
    private var constraintOrientation: NSUserInterfaceLayoutOrientation?

    /// Window frame captured when the orientation flips, so `layout()` can
    /// restore it: NSSplitView re-fits the window to the content's fitting
    /// size on an orientation change (stacked collapses to one pane wide,
    /// vertical to the content's minimum height), which must not move the
    /// window the user sized.
    private var windowFrameToRestore: NSRect?

    // Custom divider-drag state. `mouseDown` on a divider sets these instead of
    // letting NSSplitView start its own (incompatible) tracking loop.
    private var isDraggingDivider = false
    /// Mouse position along the split axis when the drag started.
    private var dragStartMouseAxis: CGFloat = 0
    /// First pane's thickness when the drag started.
    private var dragStartThickness: CGFloat = 0

    /// How far (in points) from a divider a click still counts as a divider
    /// grab. NSSplitView's thin divider needs a more generous hit target.
    private static let dividerHitSlop: CGFloat = 6

    /// The divider is drawn as a solid strip at this thickness (§3.3): a 1pt
    /// hairline is too faint next to a dense hex grid. The value feeds the
    /// pane layout (frames skip the divider) and the divider drawing, and is
    /// reused by the launch-frame width calculation (§3.1).
    static let dividerThicknessValue: CGFloat = 6

    /// A pale grey that reads against the panes' `textBackgroundColor` (white
    /// in light, near-black in dark) without stealing attention from the hex
    /// content — just enough to mark the pane split.
    private static let dividerFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.32, alpha: 1)
            : NSColor(white: 0.80, alpha: 1)
    }

    override var dividerThickness: CGFloat { Self.dividerThicknessValue }

    /// Replaces NSSplitView's hairline with a solid strip of `dividerFill`.
    override func drawDivider(in rect: NSRect) {
        Self.dividerFill.setFill()
        rect.fill()
    }

    override var isVertical: Bool {
        didSet {
            guard isVertical != oldValue else { return }
            // The orientation flip makes NSSplitView re-fit the window to the
            // content's fitting size on the next layout pass, collapsing it.
            // Save the user's frame so layout() can restore it.
            windowFrameToRestore = window?.frame
        }
    }

    override func layout() {
        // NSSplitView shrank the window to the content's degenerate fitting
        // size during the orientation change; put it back before positioning
        // the panes, so the panes lay out at the real window size.
        restoreWindowFrame()
        let arranged = arrangedSubviews
        guard arranged.count >= 2 else {
            super.layout()
            return
        }

        // Capture the divider's current strip before the panes move, so the
        // vacated region can be repainted afterwards. Nothing else invalidates
        // it: the panes' frames are set directly here, bypassing NSSplitView's
        // own divider bookkeeping, and the panes' headers/status bars are
        // transparent — so without this the old strip's pixels would linger on
        // them after a drag (§3.3).
        let previousDividerRect = dividerRect(forDividerAt: firstPaneThickness())

        // The divider binding and the frames are derived from the capped axis
        // length, not the raw bounds: when a band is dragged to zero width the
        // pane's content minimum inflates the bounds (see `dividerAxisAvailable`),
        // and feeding that back would re-assert the balloon on every pass.
        let dividerAvailable = dividerAxisAvailable()

        // Rebuild the divider binding when the axis flips (View > Toggle Pane
        // Layout) or on the first pass, then point it at the current divider.
        // The binding is only created once the axis has a real size: at the
        // degenerate zero-size first layout (panes added before the split view
        // is in the window) it would pin a pane to zero thickness and fight
        // the pane's content for no purpose.

        if dividerAvailable >= 1, dividerConstraint == nil || constraintOrientation != currentOrientation {
            rebuildDividerConstraint()
        }
        dividerConstraint?.constant = dividerConstant(available: dividerAvailable)

        let first = dividerAvailable * fraction
        let second = max(0, dividerAvailable - first)
        let width = bounds.width
        let height = bounds.height

        if isVertical {
            arranged[0].frame = NSRect(x: 0, y: 0, width: first, height: height)
            arranged[1].frame = NSRect(x: first + dividerThickness, y: 0, width: second, height: height)
        } else {
            // Stacked split. NSSplitView is flipped (isFlipped == true), so the
            // y axis grows downward: the first pane occupies the TOP of the
            // bounds (y == 0) and the second pane sits below the divider.
            arranged[0].frame = NSRect(x: 0, y: 0, width: width, height: first)
            arranged[1].frame = NSRect(x: 0, y: first + dividerThickness, width: width, height: second)
        }

        // Repaint the vacated strip (old divider position) and the new strip.
        // The panes have moved over both, so without the explicit invalidation
        // the old divider's pixels show through the panes' transparent header
        // and status bar (§3.3).
        setNeedsDisplay(previousDividerRect)
        setNeedsDisplay(dividerRect(forDividerAt: first))

        // Divider positions moved; refresh the resize-cursor hover rects.
        window?.invalidateCursorRects(for: self)
    }

    /// Restores the window frame captured when the orientation flipped. If the
    /// frame moved (NSSplitView re-fit it to the content's fitting size), put
    /// it back and re-run layout at the real size.
    private func restoreWindowFrame() {
        guard let saved = windowFrameToRestore, let window else { return }
        windowFrameToRestore = nil
        guard window.frame != saved else { return }
        window.setFrame(saved, display: true)
        needsLayout = true
    }

    // MARK: - Divider binding (§3.3)

    private var currentOrientation: NSUserInterfaceLayoutOrientation {
        isVertical ? .vertical : .horizontal
    }

    /// Below the content's required (1000) min-size constraints but above
    /// NSSplitView's preferred-size hints (250). At a real window size the
    /// divider binding is satisfied and wins; if a drag (or a degenerate first
    /// layout) would squeeze a pane below its content's minimum, the engine
    /// lets this constraint yield to the content instead of breaking the
    /// pane's own layout.
    private static let dividerConstraintPriority = NSLayoutConstraint.Priority(999)

    private func rebuildDividerConstraint() {
        dividerConstraint?.isActive = false
        dividerConstraint = nil
        guard let first = arrangedSubviews.first else { return }
        // Set the constant before activating so the engine never sees the
        // constraint at 0 (which would pin the first pane to zero width and
        // conflict with its content).
        let constant = dividerConstant(available: axisAvailable())
        let constraint: NSLayoutConstraint
        if isVertical {
            // firstPane.trailing == self.leading + dividerPosition
            constraint = first.trailingAnchor.constraint(equalTo: leadingAnchor, constant: constant)
        } else {
            // firstPane.bottom == self.top + dividerPosition. In this flipped
            // view the top anchor sits at y == 0 and the top pane's bottom edge
            // (the divider) is at y == dividerPosition, so the constant is
            // positive — the same sign as the vertical case.
            constraint = first.bottomAnchor.constraint(equalTo: topAnchor, constant: constant)
        }
        constraint.priority = Self.dividerConstraintPriority
        constraint.isActive = true
        dividerConstraint = constraint
        constraintOrientation = currentOrientation
    }

    /// The constant that places the divider at `fraction` of the usable axis,
    /// measured from the axis origin (leading edge, or top edge when stacked).
    /// In both orientations the first pane grows from that origin toward the
    /// second, so the constant is the divider position itself: the split view
    /// is flipped, and the divider edge's coordinate equals the first pane's
    /// thickness along the axis.
    private func dividerConstant(available: CGFloat) -> CGFloat {
        let position = fraction * available
        return position
    }

    // MARK: - Divider drag (handled here, not by NSSplitView)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard dividerIndex(at: point) != nil else {
            super.mouseDown(with: event)
            return
        }
        // A double-click on the divider resets it to a 50/50 split (§3.3),
        // replacing NSSplitView's default double-click behavior (collapsing a
        // pane, which this app never uses).
        if event.clickCount == 2 {
            resetToHalf()
            return
        }
        guard event.clickCount == 1 else { return }
        // The user is grabbing the divider: cancel any running fraction animation.
        fractionTimer?.invalidate()
        fractionTimer = nil
        isDraggingDivider = true
        dragStartMouseAxis = axisValue(point)
        dragStartThickness = firstPaneThickness()
        (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let available = axisAvailable()
        guard available > 0 else { return }
        let delta = axisValue(point) - dragStartMouseAxis
        let newFirst = min(max(dragStartThickness + delta, 0), available)
        // Through `setFraction`, so the drag reports the new proportion like
        // every other divider move does: the minimap's stacked divider line is
        // glued to this one via `onFractionChanged` (§19), and a hand-rolled
        // "assign, re-lay out" here left it behind while the panes moved.
        setFraction(newFirst / available)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseUp(with: event)
            return
        }
        isDraggingDivider = false
        NSCursor.pop()
    }

    // MARK: - Fraction animation (§3.3)

    /// Duration of an animated divider move: the 50/50 reset on a divider
    /// double-click and the fit-content-width move on a header double-click.
    private static let fractionAnimationDuration: TimeInterval = 0.2
    /// Drives the animation; invalidated if the user grabs the divider again
    /// before it finishes.
    private var fractionTimer: Timer?
    /// Fraction at the moment the animation started.
    private var fractionStartValue: CGFloat = 0.5
    /// Wall-clock time the animation started.
    private var fractionStartTime: TimeInterval = 0

    /// Resets the divider to a 50/50 split (divider double-click).
    private func resetToHalf() {
        animateFraction(to: 0.5)
    }

    /// Animates the split fraction to `target` (clamped to 0...1) unless the
    /// user prefers reduced motion, in which case it snaps instantly. A running
    /// animation is superseded; grabbing the divider cancels it.
    func animateFraction(to target: CGFloat) {
        let target = min(max(target, 0), 1)
        guard fraction != target else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setFraction(target)
            return
        }
        fractionTimer?.invalidate()
        fractionStartValue = fraction
        fractionStartTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.tickFractionAnimation(to: target)
        }
        RunLoop.main.add(timer, forMode: .common)
        fractionTimer = timer
        tickFractionAnimation(to: target)
    }

    private func tickFractionAnimation(to target: CGFloat) {
        let elapsed = ProcessInfo.processInfo.systemUptime - fractionStartTime
        let t = min(1, elapsed / Self.fractionAnimationDuration)
        // Cubic ease-out: quick start, soft landing.
        let u = 1 - t
        let eased = 1 - u * u * u
        setFraction(fractionStartValue + (target - fractionStartValue) * eased)
        if t >= 1 {
            setFraction(target)
            fractionTimer?.invalidate()
            fractionTimer = nil
        }
    }

    /// Moves the divider so pane `index` (0 or 1) gets at least `minimumWidth`
    /// along the split axis, if the available space allows. Only meaningful in
    /// side-by-side mode; a stacked split's panes are already full-width (§3.3).
    func fitPane(_ index: Int, minimumWidth: CGFloat) {
        guard isVertical, minimumWidth > 0 else { return }
        let available = axisAvailable()
        guard available > 0 else { return }
        let target: CGFloat
        if index == 0 {
            target = min(max(minimumWidth / available, 0), 1)
        } else {
            target = min(max((available - minimumWidth) / available, 0), 1)
        }
        animateFraction(to: target)
    }

    /// Sets the split fraction and re-lays the panes out immediately.
    private func setFraction(_ newFraction: CGFloat) {
        fraction = newFraction
        needsLayout = true
        layout()
        onFractionChanged?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let arranged = arrangedSubviews
        guard arranged.count >= 2 else { return }
        let slop = Self.dividerHitSlop
        if isVertical {
            for i in 0..<(arranged.count - 1) {
                let x = arranged[i].frame.maxX
                addCursorRect(NSRect(x: x - slop, y: 0, width: slop * 2, height: bounds.height),
                              cursor: .resizeLeftRight)
            }
        } else {
            for i in 0..<(arranged.count - 1) {
                let y = arranged[i].frame.maxY
                addCursorRect(NSRect(x: 0, y: y - slop, width: bounds.width, height: slop * 2),
                              cursor: .resizeUpDown)
            }
        }
    }

    /// Returns the index of the divider under `point` (in this view's coords),
    /// or nil. `dividerIndex` refers to the divider between arranged subviews
    /// `index` and `index + 1`.
    private func dividerIndex(at point: NSPoint) -> Int? {
        let arranged = arrangedSubviews
        guard arranged.count >= 2 else { return nil }
        let slop = Self.dividerHitSlop
        if isVertical {
            for i in 0..<(arranged.count - 1) {
                if abs(point.x - arranged[i].frame.maxX) <= slop { return i }
            }
        } else {
            // Stacked, flipped coordinates: the pane above a divider is the one
            // whose lower edge (maxY) borders the next pane.
            for i in 0..<(arranged.count - 1) {
                if abs(point.y - arranged[i].frame.maxY) <= slop { return i }
            }
        }
        return nil
    }

    private func firstPaneThickness() -> CGFloat {
        guard let first = arrangedSubviews.first else { return 0 }
        return isVertical ? first.frame.width : first.frame.height
    }

    private func axisValue(_ point: NSPoint) -> CGFloat {
        isVertical ? point.x : point.y
    }

    /// The strip this split view paints for a divider at `position` — the
    /// first pane's thickness along the split axis. Runs the full cross-axis
    /// extent (the whole pane height when side-by-side), so the region includes
    /// the panes' header and status bar.
    private func dividerRect(forDividerAt position: CGFloat) -> NSRect {
        if isVertical {
            return NSRect(x: position, y: 0, width: dividerThickness, height: bounds.height)
        } else {
            // Stacked, flipped coordinates: the divider's y is the first
            // (top) pane's height.
            return NSRect(x: 0, y: position, width: bounds.width, height: dividerThickness)
        }
    }

    private func axisAvailable() -> CGFloat {
        let total = isVertical ? bounds.width : bounds.height
        let dividerTotal = dividerThickness * CGFloat(max(0, arrangedSubviews.count - 1))
        return max(0, total - dividerTotal)
    }

    /// The axis length used to derive the divider binding's constant.
    ///
    /// Normally this is `axisAvailable()` (the split view's own bounds). But
    /// when a band is dragged to zero width the band's pane keeps a content
    /// minimum, the Auto Layout engine inflates the split view's fitting size
    /// to honour it, and the enclosing window's content view follows — so
    /// `bounds` reports a width far larger than the window the user actually
    /// sized. Feeding that inflated width back into the divider constant
    /// (`fraction × available`) pins the first band to the inflated edge and
    /// re-asserts the balloon on every layout pass, a self-sustaining loop.
    ///
    /// Capping at the window's content size breaks the loop: the constant is
    /// derived from the width the user asked for, the fitting size stops
    /// growing, and the content view settles back to the window's width.
    private func dividerAxisAvailable() -> CGFloat {
        let available = axisAvailable()
        guard let window else { return available }
        // The window's frame is the ground truth for the axis length: the
        // content view (and this view's bounds) can be inflated by the loop
        // above, but the frame the user sized is not. For a titled window the
        // content width equals the frame width (the title bar sits above, not
        // to the side), so the frame width is the content width.
        let windowAxis = isVertical ? window.frame.width : window.frame.height
        return min(available, max(0, windowAxis - dividerThickness * CGFloat(max(0, arrangedSubviews.count - 1))))
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
