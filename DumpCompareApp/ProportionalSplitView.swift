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
/// Layout subviews in a stacked split, which made `setPosition` clamp to a
/// no-op.
final class ProportionalSplitView: NSSplitView {
    /// Fraction (0...1) of the split axis given to the first pane. 0.5 until a
    /// divider drag or `setPosition` changes it; resizes never touch it.
    private var fraction: CGFloat = 0.5

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

        let available = axisAvailable()

        // Rebuild the divider binding when the axis flips (View > Toggle Pane
        // Layout) or on the first pass, then point it at the current divider.
        // The binding is only created once the axis has a real size: at the
        // degenerate zero-size first layout (panes added before the split view
        // is in the window) it would pin a pane to zero thickness and fight
        // the pane's content for no purpose.
        if available >= 1, dividerConstraint == nil || constraintOrientation != currentOrientation {
            rebuildDividerConstraint()
        }
        dividerConstraint?.constant = dividerConstant(available: available)

        let first = available * fraction
        let second = max(0, available - first)
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
        // The user is grabbing the divider: cancel any running reset animation.
        resetTimer?.invalidate()
        resetTimer = nil
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
        fraction = newFirst / available
        needsLayout = true
        layout()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseUp(with: event)
            return
        }
        isDraggingDivider = false
        NSCursor.pop()
    }

    /// Programmatic divider moves (used by tests) update the ratio too.
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        resetTimer?.invalidate()
        resetTimer = nil
        let available = axisAvailable()
        guard available > 0 else {
            super.setPosition(position, ofDividerAt: dividerIndex)
            return
        }
        setFraction(min(max(position / available, 0), 1))
    }

    // MARK: - Reset to 50/50 (§3.3)

    /// Duration of the animated 50/50 reset triggered by a divider double-click.
    private static let resetDuration: TimeInterval = 0.2
    /// Drives the reset animation; invalidated if the user grabs the divider
    /// again before it finishes.
    private var resetTimer: Timer?
    /// Fraction at the moment the reset animation started.
    private var resetStartFraction: CGFloat = 0.5
    /// Wall-clock time the reset animation started.
    private var resetStartTime: TimeInterval = 0

    /// Resets the divider to a 50/50 split. Animates the fraction over
    /// `resetDuration` unless the user prefers reduced motion, in which case it
    /// snaps instantly.
    private func resetToHalf() {
        guard fraction != 0.5 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setFraction(0.5)
            return
        }
        resetTimer?.invalidate()
        resetStartFraction = fraction
        resetStartTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.tickResetAnimation()
        }
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
        tickResetAnimation()
    }

    private func tickResetAnimation() {
        let elapsed = ProcessInfo.processInfo.systemUptime - resetStartTime
        let t = min(1, elapsed / Self.resetDuration)
        // Cubic ease-out: quick start, soft landing.
        let u = 1 - t
        let eased = 1 - u * u * u
        setFraction(resetStartFraction + (0.5 - resetStartFraction) * eased)
        if t >= 1 {
            setFraction(0.5)
            resetTimer?.invalidate()
            resetTimer = nil
        }
    }

    /// Sets the split fraction and re-lays the panes out immediately.
    private func setFraction(_ newFraction: CGFloat) {
        fraction = newFraction
        needsLayout = true
        layout()
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

    private func axisAvailable() -> CGFloat {
        let total = isVertical ? bounds.width : bounds.height
        let dividerTotal = dividerThickness * CGFloat(max(0, arrangedSubviews.count - 1))
        return max(0, total - dividerTotal)
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
