import Cocoa

/// The pane's title bar (file name, dirty/read-only state, close button).
///
/// Besides showing the title it recognizes a double-click anywhere on the bar —
/// except on the close button — and reports it via `onDoubleClick`. In
/// side-by-side mode that tells ComparisonView to expand this pane so its hex
/// content fits by width (§3.3).
final class PaneHeaderView: NSView {
    /// Fired on a double-click in the header (not on the close button).
    var onDoubleClick: (() -> Void)?

    /// Fired once the pointer has moved far enough from the mouse-down for the
    /// gesture to mean a drag rather than a click, carrying the event the drag
    /// should begin from.
    var onDragThresholdPassed: ((NSEvent) -> Void)?

    /// The hairline along the header's bottom edge, which together with the
    /// header's own fill draws the line between the window's chrome and the
    /// dump.
    private let bottomSeparator = NSView()

    /// How strong the header's bottom rule is, as a fraction of `separatorColor`.
    ///
    /// Half. At full strength it read heavier than the system's own rule under
    /// the tab bar, which sits a few points above it — two lines doing the same
    /// job in different weights, which looks like a mistake because it is one.
    /// The tab bar's rule is AppKit's and its colour is not exposed, so this is
    /// matched by eye; it is a single constant so the next eye can adjust it.
    static let separatorStrength: CGFloat = 0.5

    /// `separatorColor` at `separatorStrength` of its own opacity.
    ///
    /// Scaled, not assigned. `withAlphaComponent` **replaces** the alpha rather
    /// than scaling it, and `separatorColor` is already translucent — 9.8 % —
    /// so asking for 0.5 made the rule five times stronger instead of half, and
    /// a hairline at 50 % black reads as a black line.
    ///
    /// Resolved through sRGB inside the caller's drawing appearance, because a
    /// catalog colour has no components to scale until it is.
    private static func headerRuleColor() -> NSColor {
        let separator = NSColor.separatorColor
        guard let resolved = separator.usingColorSpace(.sRGB) else { return separator }
        return resolved.withAlphaComponent(resolved.alphaComponent * separatorStrength)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The header is a strip of chrome, not part of the document: the dump
        // and the column header above it both draw `textBackgroundColor`, so
        // without a fill of its own the header dissolved into them and the pane
        // read as one flat sheet from the tab bar down, with no visible edge on
        // the strip that is meant to be grabbed (§3.4).
        //
        // A system fill rather than `windowBackgroundColor`, which was the
        // obvious choice and is the wrong one: measured on this OS,
        // `windowBackgroundColor`, `controlBackgroundColor` and
        // `textBackgroundColor` are the *same colour* in both appearances —
        // white on white in light, 0.118 grey on itself in dark — so a header
        // filled with it would have been exactly as flat as no fill at all. A
        // system fill is translucent by design and made to sit over content, and
        // adapts on its own: black over light, white over dark.
        //
        // The tertiary weight (4.7 %) rather than the secondary (7.8 %), which
        // read as a heavy bar. Most of the delineating is done by the hairline
        // below, so the fill only has to say "not the document" — the lightest
        // touch that does is the right one. `quaternarySystemFill` (2.7 %) is
        // the step below if even this reads as too much.
        wantsLayer = true
        layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        bottomSeparator.wantsLayer = true
        bottomSeparator.layer?.backgroundColor = Self.headerRuleColor().cgColor
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomSeparator)
        NSLayoutConstraint.activate([
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A layer colour is resolved once, when it is assigned — and these are
    /// assigned before the header is in a window, so a later switch to dark mode
    /// would leave the strip light. Re-resolved here, where the effective
    /// appearance is authoritative (§3.2), the same way the find bar does it.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
            bottomSeparator.layer?.backgroundColor = Self.headerRuleColor().cgColor
        }
    }

    /// How far the pointer travels before a press on the header becomes a drag
    /// (`Design/PANE_DRAG_PLAN.md`).
    ///
    /// The header is not free: it already answers a double-click (fit the pane
    /// to its content width, §3.3) and a right-click (the pane's File menu). A
    /// drag that began on the first stray pixel would steal the clicks meant for
    /// those. Same shape as `HexView.bookmarkDragHysteresis`, same reason.
    static let dragThreshold: CGFloat = 4

    /// Where the press started, while it could still turn into a drag.
    private var pressOrigin: NSPoint?

    /// Routes every click in the bar to the bar itself — the title/lock labels
    /// are plain text and must not swallow the gesture. The close button keeps
    /// its clicks. Points outside the bar pass through untouched.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton { return hit }
        // The name field, while a name is being edited, and the field editor
        // that does the editing. Routing their clicks to the bar would leave a
        // field nobody can put a caret in — the labels are text to look at, but
        // this one is text to work on.
        if hit is NSTextView { return hit }
        if let field = hit as? NSTextField, field.isEditable { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        pressOrigin = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, onDragThresholdPassed != nil else {
            super.mouseDragged(with: event)
            return
        }
        let moved = hypot(event.locationInWindow.x - origin.x,
                          event.locationInWindow.y - origin.y)
        guard moved >= Self.dragThreshold else { return }
        // One drag per press: the session takes the mouse from here.
        pressOrigin = nil
        onDragThresholdPassed?(event)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        super.mouseUp(with: event)
    }

    /// Right-click pops the pane's File menu (assigned via `menu`), acting on
    /// this pane — not the active pane. The close button keeps its own clicks.
    override func rightMouseDown(with event: NSEvent) {
        if let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}
