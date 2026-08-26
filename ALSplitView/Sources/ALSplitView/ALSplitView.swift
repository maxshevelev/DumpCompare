import Cocoa

/// A split view: panes arranged along one axis, separated by draggable
/// dividers.
///
/// Unlike `NSSplitView`, which sizes its panes from their content and
/// manages arranged subviews through autoresizing masks (which translate
/// into required-priority fixed-size constraints that fight Auto Layout
/// pins), `ALSplitView` is a plain `NSView` that owns each pane's
/// placement directly: `layout()` computes the pane sizes from the
/// policies and sets each pane's and divider's frame. The panes carry no
/// Auto Layout constraints of their own, so the solver never sees their
/// sizes and a resize can't feed back into the enclosing window's
/// constraint layout (the "balloon").
///
/// The dividers are real subviews (layer-backed, painted with the divider
/// colour) positioned by `layout()`, not drawn in `draw(_:)` — so they
/// render in the normal subview order and never show through a pane's
/// chrome.
///
/// ## Layout
///
/// The panes and dividers are placed in order along the axis:
///
/// ```
/// pane0 ── divider0 ── pane1 ── divider1 ── … ── paneN
/// ```
///
/// `layout()` walks the panes in order, giving each its policy-derived
/// size and the following divider its thickness, accumulating the offset
/// until the last pane reaches the split's trailing/bottom edge. Every
/// pane and divider spans the full cross extent.
///
/// ## Layout policy
///
/// Each pane carries a `PaneLayout` describing how it takes its share of
/// the free axis (the axis length minus all dividers):
///
/// - `.proportional(f)` — `f` of the free axis;
/// - `.fixed(s)` — exactly `s` points;
/// - `.fill` — splits the remainder evenly with the other `.fill` panes.
///
/// `layout()` re-derives the pane placements from the policies on every
/// pass, so a window resize redistributes by policy: a proportional pair
/// keeps its ratio, a fixed pane keeps its size while the `.fill` pane
/// absorbs the delta.
///
/// ## Divider position
///
/// A divider's position — the combined thickness of the panes above it,
/// along the axis — is derived from the policies. `setDividerPosition(_:at:)`
/// is the programmatic setter and the same code path a divider drag takes:
/// it clamps the requested position (the consumer's
/// `clampDividerPosition` first, then the free axis), rewrites the policy
/// of the pane the divider borders so the position survives the next
/// layout pass, lays out immediately, and fires `onDividerMoved`.
///
/// ## Drag and double-click
///
/// The drag is handled by the view itself: a `mouseDown` on a divider
/// records the grab, `mouseDragged` moves the divider one-to-one with the
/// mouse, and `mouseUp` releases it. A double-click fires
/// `onDividerDoubleClicked` — what it does (reset to half, collapse a
/// pane, …) is the consumer's, the same way an app decides what
/// `NSSplitView`'s double-click means.
///
/// ## Cursor
///
/// Like a native split view, the dividers show the resize cursor on hover
/// (via `resetCursorRects`, with a little slop around the thin strip) and
/// push it for the whole drag.
public final class ALSplitView: NSView {
    // MARK: - Configuration

    /// `true` for side-by-side panes (a vertical divider), `false` for
    /// stacked panes (a horizontal divider). The view is flipped, so in a
    /// stacked layout pane 0 is the TOP pane — the same arrangement
    /// `NSSplitView` uses.
    public var isVertical: Bool = true {
        didSet {
            guard isVertical != oldValue else { return }
            needsLayout = true
        }
    }

    /// The dividers' thickness along the axis.
    public var dividerThickness: CGFloat = 1 {
        didSet {
            guard dividerThickness != oldValue else { return }
            needsLayout = true
        }
    }

    /// The colour the divider strips are filled in. `nil` uses the default
    /// adaptive grey (a pale strip that reads against both light and dark
    /// backgrounds without stealing attention).
    public var dividerColor: NSColor? {
        didSet { updateDividerColor() }
    }

    /// How far (in points) from a divider's edge a click still counts as
    /// grabbing it. A thin divider needs a more generous hit target.
    public var dividerHitSlop: CGFloat = 6

    // MARK: - Panes and dividers

    /// The panes in layout order.
    private(set) public var panes: [NSView] = []

    /// The divider subviews, one between each pair of panes. The dividers
    /// are real subviews (layer-backed, painted with the divider colour)
    /// positioned by `layout()`, not drawn in `draw(_:)` — so they render
    /// in the normal subview order and never show through a pane's chrome.
    private var dividers: [NSView] = []

    /// The default divider colour: a pale grey that reads against both a
    /// light and a dark background without stealing attention.
    private static let defaultDividerColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.32, alpha: 1)
            : NSColor(white: 0.80, alpha: 1)
    }

    /// Adds `pane` as the next pane. The split view owns the pane's
    /// position and size (set directly in `layout()`), so the pane must not
    /// carry an autoresizing mask — one would translate into a fixed-size
    /// constraint that fights the layout. A divider subview is inserted
    /// before the pane (except for the first pane).
    public func addPane(_ pane: NSView) {
        pane.translatesAutoresizingMaskIntoConstraints = false
        panes.append(pane)
        paneLayouts.append(.fill)

        // Insert a divider before this pane (except for the first pane).
        // The divider is a layer-backed subview painted with the divider
        // colour; `layout()` positions it between the panes.
        if panes.count > 1 {
            let divider = NSView()
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.wantsLayer = true
            divider.layer?.backgroundColor = (dividerColor ?? Self.defaultDividerColor).cgColor
            dividers.append(divider)
            addSubview(divider)
        }

        addSubview(pane)
        needsLayout = true
    }

    /// Applies the current `dividerColor` to all divider subviews.
    private func updateDividerColor() {
        let color = dividerColor ?? Self.defaultDividerColor
        for divider in dividers {
            divider.wantsLayer = true
            divider.layer?.backgroundColor = color.cgColor
        }
    }

    // MARK: - Layout policy

    /// How a pane takes its share of the free axis.
    public enum PaneLayout: Equatable {
        /// `fraction` of the free axis (the axis length minus all dividers).
        case proportional(CGFloat)
        /// Exactly `size` points along the axis.
        case fixed(CGFloat)
        /// Splits the remainder evenly with the other `.fill` panes.
        case fill
    }

    /// The per-pane policies. A pane added via `addPane` starts as `.fill`.
    public private(set) var paneLayouts: [PaneLayout] = []

    /// Sets the layout policy of the pane at `index` and re-lays the panes
    /// out immediately.
    public func setPaneLayout(_ newLayout: PaneLayout, at index: Int) {
        guard paneLayouts.indices.contains(index) else { return }
        paneLayouts[index] = newLayout
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: - Divider position

    /// The position of the divider between panes `index` and `index + 1`,
    /// measured from the axis origin (the leading edge, or the top edge
    /// when stacked): the combined thickness of the panes above it.
    public func dividerPosition(at index: Int) -> CGFloat {
        guard index >= 0, index < panes.count - 1 else { return 0 }
        let sizes = paneSizes(available: axisAvailable())
        var position: CGFloat = 0
        for i in 0...index {
            position += sizes[i]
            position += dividerThickness
        }
        return position - dividerThickness
    }

    /// A consumer-imposed clamp on a divider position: a drag or a
    /// programmatic move asks for `position` and this returns where the
    /// divider may actually land — e.g. keeping both panes above their
    /// minimum sizes, or pinning the divider to the edge while a panel is
    /// collapsed. Called before the hard clamp to the free axis.
    public var clampDividerPosition: ((Int, CGFloat) -> CGFloat)?

    /// Fired after a divider moved — a drag, a programmatic
    /// `setDividerPosition`, or an animation tick — with the divider's
    /// index and its new position. The consumer updates its policies (and
    /// persists them) from here.
    public var onDividerMoved: ((Int, CGFloat) -> Void)?

    /// Fired on a double-click of the divider at `index`.
    public var onDividerDoubleClicked: ((Int) -> Void)?

    /// Moves the divider at `index` to `position` (clamped by
    /// `clampDividerPosition`, then to the free axis), rewrites the policy
    /// of the pane the divider borders so the position survives the next
    /// layout pass, lays out immediately, and fires `onDividerMoved`. This
    /// is the same code path a divider drag takes, so programmatic sizing
    /// and user dragging behave identically.
    public func setDividerPosition(_ position: CGFloat, at index: Int = 0) {
        guard index >= 0, index < panes.count - 1 else { return }
        let available = axisAvailable()
        guard available > 0 else { return }
        var target = clampDividerPosition?(index, position) ?? position
        target = min(max(0, target), available)
        guard abs(target - dividerPosition(at: index)) > 0.01 else { return }
        applyDividerPosition(target, at: index)
        onDividerMoved?(index, target)
    }

    /// Rewrites the policy of the pane the divider at `index` borders so
    /// the next layout pass lands the divider at `position`, then lays out.
    private func applyDividerPosition(_ position: CGFloat, at index: Int) {
        let available = axisAvailable()
        guard available > 0 else { return }
        let above = index
        let below = index + 1
        switch paneLayouts[above] {
        case .proportional:
            setPaneLayout(.proportional(position / available), at: above)
        case .fixed:
            setPaneLayout(.fixed(position), at: above)
        case .fill:
            let sizes = paneSizes(available: available)
            let furtherBelow = sizes.suffix(from: below + 1).reduce(0, +)
            let belowSize = max(0, available - position - furtherBelow)
            switch paneLayouts[below] {
            case .proportional:
                setPaneLayout(.proportional(belowSize / available), at: below)
            default:
                setPaneLayout(.fixed(belowSize), at: below)
            }
        }
    }

    // MARK: - Animation

    /// Whether a divider animation is currently running.
    public private(set) var isAnimatingDivider = false

    /// The divider's animation timer; grabbing the divider invalidates it.
    private var animationTimer: Timer?
    /// The divider the animation is moving.
    private var animationIndex = 0
    /// Position at the moment the animation started.
    private var animationStart: CGFloat = 0
    /// Position the animation is heading to.
    private var animationTarget: CGFloat = 0
    /// Wall-clock time the animation started.
    private var animationStartTime: TimeInterval = 0

    /// Animates the divider at `index` to `position` with a cubic ease-out
    /// over `duration`, unless the user prefers reduced motion (then it
    /// snaps). A running animation is superseded; grabbing the divider
    /// cancels it.
    public func animateDividerPosition(to position: CGFloat, at index: Int = 0,
                                       duration: TimeInterval = 0.2) {
        guard index >= 0, index < panes.count - 1 else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimatingDivider = false
        let available = axisAvailable()
        guard available > 0 else { return }
        let target = min(max(0, position), available)
        let start = dividerPosition(at: index)
        guard abs(start - target) > 0.5 else {
            setDividerPosition(target, at: index)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setDividerPosition(target, at: index)
            return
        }
        animationIndex = index
        animationStart = start
        animationTarget = target
        animationStartTime = ProcessInfo.processInfo.systemUptime
        isAnimatingDivider = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.tickAnimation(to: target, after: duration)
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        tickAnimation(to: target, after: duration)
    }

    /// One animation tick: eases the divider's position and places it.
    private func tickAnimation(to target: CGFloat, after duration: TimeInterval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - animationStartTime
        let t = min(1, elapsed / max(duration, 0.001))
        let u = 1 - t
        let eased = 1 - u * u * u
        setDividerPosition(animationStart + (animationTarget - animationStart) * eased, at: animationIndex)
        if t >= 1 {
            setDividerPosition(target, at: animationIndex)
            animationTimer?.invalidate()
            animationTimer = nil
            isAnimatingDivider = false
        }
    }

    /// The last pane's current thickness along the split axis, derived from
    /// the policies (the pane's frame is one layout pass behind them).
    private func trailingPaneSize() -> CGFloat {
        guard !panes.isEmpty else { return 0 }
        return paneSizes(available: axisAvailable()).last ?? 0
    }

    /// Places the divider so the last pane gets `size` points along the axis.
    private func setTrailingPaneSize(_ size: CGFloat) {
        let available = axisAvailable()
        guard available > 0 else { return }
        setDividerPosition(available - min(max(0, size), available))
    }

    /// Animates the LAST pane's thickness along the split axis to `size`.
    public func animateTrailingPaneSize(to size: CGFloat, duration: TimeInterval = 0.2) {
        guard !panes.isEmpty else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimatingDivider = false
        let available = axisAvailable()
        guard available > 0 else { return }
        let target = min(max(0, size), available)
        let start = trailingPaneSize()
        guard abs(start - target) > 0.5 else {
            setTrailingPaneSize(target)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setTrailingPaneSize(target)
            return
        }
        animationStart = start
        animationTarget = target
        animationStartTime = ProcessInfo.processInfo.systemUptime
        isAnimatingDivider = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.tickTrailingPaneSizeAnimation(after: duration)
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        tickTrailingPaneSizeAnimation(after: duration)
    }

    /// One tick of the trailing-pane size animation.
    private func tickTrailingPaneSizeAnimation(after duration: TimeInterval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - animationStartTime
        let t = min(1, elapsed / max(duration, 0.001))
        let u = 1 - t
        let eased = 1 - u * u * u
        setTrailingPaneSize(animationStart + (animationTarget - animationStart) * eased)
        if t >= 1 {
            setTrailingPaneSize(animationTarget)
            animationTimer?.invalidate()
            animationTimer = nil
            isAnimatingDivider = false
        }
    }

    // MARK: - Layout

    /// Flipped, like `NSSplitView`: in a stacked layout the first pane sits
    /// at the TOP of the bounds (y == 0) and the axis grows downward.
    override public var isFlipped: Bool { true }

    override public func layout() {
        let count = panes.count
        guard count > 0 else { return }
        // Derive the per-pane sizes from the policies, then place the panes
        // and dividers directly along the axis. Direct frame setting (rather
        // than Auto Layout constraints) keeps the split self-contained: the
        // solver never sees the panes' sizes, so a resize can't feed back
        // into the enclosing window's constraint layout (the "balloon").
        let available = axisAvailable()
        let sizes = paneSizes(available: available)
        NSLog("DBG ALSplitView layout: bounds=\(bounds) isVertical=\(isVertical) available=\(available) sizes=\(sizes)")
        var offset: CGFloat = 0
        for (i, pane) in panes.enumerated() {
            let size = sizes[i]
            pane.frame = isVertical
                ? NSRect(x: offset, y: 0, width: size, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: size)
            // Force the pane to re-lay out its own subviews against the new
            // frame: the pane's content is constraint-based, and a direct frame
            // set from here does not by itself re-run the pane's Auto Layout
            // pass in the same cycle.
            pane.needsLayout = true
            offset += size
            if i < count - 1 {
                let divider = dividers[i]
                divider.frame = isVertical
                    ? NSRect(x: offset, y: 0, width: dividerThickness, height: bounds.height)
                    : NSRect(x: 0, y: offset, width: bounds.width, height: dividerThickness)
                offset += dividerThickness
            }
        }
        // Debug: log the panes' frames after setting them.
        for (i, pane) in panes.enumerated() {
            NSLog("DBG ALSplitView pane[\(i)] frame=\(pane.frame) class=\(type(of: pane))")
        }
    }

    /// Computes the per-pane sizes for a free axis of `available` points,
    /// derived from the policies: proportional panes take their fraction of
    /// the whole, fixed panes their size, and the `.fill` panes split
    /// whatever is left (never negative).
    private func paneSizes(available: CGFloat) -> [CGFloat] {
        var sizes = [CGFloat](repeating: 0, count: panes.count)
        var assigned: CGFloat = 0
        var fillCount = 0
        for (i, layout) in paneLayouts.enumerated() {
            switch layout {
            case .fixed(let size):
                sizes[i] = min(max(0, size), available)
            case .proportional(let fraction):
                sizes[i] = min(max(0, fraction), 1) * available
            case .fill:
                fillCount += 1
            }
            assigned += sizes[i]
        }
        if fillCount > 0 {
            let share = max(0, available - assigned) / CGFloat(fillCount)
            for i in paneLayouts.indices where paneLayouts[i] == .fill {
                sizes[i] = share
            }
        }
        return sizes
    }

    // MARK: - Cursor

    /// The resize cursor over each divider, with a little slop around the
    /// strip — the native split view's hover behaviour.
    override public func resetCursorRects() {
        super.resetCursorRects()
        let count = panes.count
        guard count >= 2 else { return }
        let slop = dividerHitSlop
        for i in 0..<(count - 1) {
            let position = dividerPosition(at: i)
            let rect: NSRect
            if isVertical {
                rect = NSRect(x: position - slop, y: 0, width: dividerThickness + slop * 2, height: bounds.height)
            } else {
                rect = NSRect(x: 0, y: position - slop, width: bounds.width, height: dividerThickness + slop * 2)
            }
            addCursorRect(rect, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    // MARK: - Divider drag

    /// Custom divider-drag state.
    private var isDraggingDivider = false
    /// The divider being dragged.
    private var draggedDividerIndex = 0
    /// Mouse position along the split axis when the drag started.
    private var dragStartMouseAxis: CGFloat = 0
    /// The divider's position when the drag started.
    private var dragStartPosition: CGFloat = 0

    /// The index of the divider under `point` (in this view's coordinates),
    /// or nil. A click within `dividerHitSlop` of a divider's strip counts.
    private func dividerIndex(at point: NSPoint) -> Int? {
        let count = panes.count
        guard count >= 2 else { return nil }
        let slop = dividerHitSlop
        for i in 0..<(count - 1) {
            let position = dividerPosition(at: i)
            let extent = dividerThickness + slop * 2
            let value = isVertical ? point.x : point.y
            if abs(value - (position + dividerThickness / 2)) <= extent / 2 { return i }
        }
        return nil
    }

    /// A click in a divider's grab area (the strip plus its slop) belongs to
    /// the split view, even when it lands over a pane's scroller or other
    /// subview at the pane's edge: subviews are hit-tested before the
    /// superview, so without this a scroller sitting under the grab area would
    /// swallow the click and turn a divider drag into a scroll. Points outside
    /// every grab area pass through to the normal hit test.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if bounds.contains(local), dividerIndex(at: local) != nil {
            return self
        }
        return super.hitTest(point)
    }

    override public func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividerIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            onDividerDoubleClicked?(index)
            return
        }
        guard event.clickCount == 1 else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimatingDivider = false
        isDraggingDivider = true
        draggedDividerIndex = index
        dragStartMouseAxis = isVertical ? point.x : point.y
        dragStartPosition = dividerPosition(at: index)
        (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
    }

    override public func mouseDragged(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let axis = isVertical ? point.x : point.y
        let delta = axis - dragStartMouseAxis
        setDividerPosition(dragStartPosition + delta, at: draggedDividerIndex)
    }

    override public func mouseUp(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseUp(with: event)
            return
        }
        isDraggingDivider = false
        NSCursor.pop()
    }

    // MARK: - Axis math

    /// The free axis length: the bounds' axis minus all the dividers.
    public func axisAvailable() -> CGFloat {
        let total = isVertical ? bounds.width : bounds.height
        let dividers = dividerThickness * CGFloat(max(0, panes.count - 1))
        return max(0, total - dividers)
    }

    deinit {
        animationTimer?.invalidate()
    }
}
