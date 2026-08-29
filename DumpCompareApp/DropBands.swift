import Cocoa

/// One targeted drop zone's visual: a quiet milky plate at idle, flooded with a
/// translucent accent-blue fill on hover, and a caption on its own frosted-glass
/// plate so the label stays readable wherever the fill and the file content
/// behind it are busy (§4.3). Purely visual — the drop handling lives in the
/// owning region view.
final class DropTargetView: NSView {
    private let plate = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        // While idle the zone is a quiet milky plate; the blue fill appears on
        // hover only (§4.3). The caption sits on its own frosted plate, so
        // neither fill ever bleeds into the text.
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        // The frosted plate: the standard popover material, rounded, hugging
        // the caption. It is a dynamic material — it adapts to the theme and
        // window state on its own, with no layer colour to re-resolve on an
        // appearance change (§3.1).
        plate.material = .popover
        plate.blendingMode = .withinWindow
        plate.state = .active
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 6
        plate.layer?.masksToBounds = true
        plate.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center
        // On the frosted plate the label always reads at full strength; the
        // colour follows the theme through the material.
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(label)

        addSubview(plate)
        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: centerXAnchor),
            plate.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Keep the plate inside the zone even if it gets narrow: the plate
            // still hugs the caption, just clamped to the zone's edges.
            plate.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            plate.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            // The label may truncate (not pin the plate to its full width) so a
            // zero-width zone — a collapsed drop band — doesn't force a minimum
            // width up through the band into the split view's fitting size.
            label.leadingAnchor.constraint(greaterThanOrEqualTo: plate.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: plate.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: plate.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Renames the zone. A pane drop means different things in different places
    /// (`Design/PANE_DRAG_PLAN.md`), and one plate says whichever it is.
    func setTitle(_ title: String) {
        label.stringValue = title
    }

    func setHighlighted(_ highlighted: Bool) {
        // Hover floods the zone with a translucent accent-blue fill; idle keeps
        // the quiet milky plate. Hover is also signalled by the accent border
        // and a thicker stroke. The caption's frosted plate is untouched — its
        // material and label adapt on their own (§4.3).
        layer?.backgroundColor = (highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.25)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.9)).cgColor
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = highlighted ? 2 : 1
    }
}

/// The "second file" half's visual in single-file mode (§4.3): a quiet plate
/// that appears only for the drag's lifetime. Purely visual — it is never
/// hit-testable, so the hex dump behind it keeps the mouse; the owning
/// `SingleFileDropView` receives the file drag (it is the drop destination) and
/// shows/hides this plate for the drag's lifetime.
final class DropZoneView: NSView {
    private let target: DropTargetView
    private var dragActive = false

    init(title: String) {
        self.target = DropTargetView(title: title)
        super.init(frame: .zero)
        target.translatesAutoresizingMaskIntoConstraints = false
        addSubview(target)
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: leadingAnchor),
            target.trailingAnchor.constraint(equalTo: trailingAnchor),
            target.topAnchor.constraint(equalTo: topAnchor),
            target.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Purely visual: never a hit-test target, so mouse events fall through to
    /// the hex dump behind this plate (§4.3). The file drag is owned by the
    /// parent `SingleFileDropView`, which is the registered drop destination.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setDragActive(_ active: Bool) {
        dragActive = active
        if active {
            target.isHidden = false
            target.alphaValue = 1
        } else {
            target.setHighlighted(false)
            target.isHidden = true
            target.alphaValue = 0
        }
    }

    func setHighlighted(_ highlighted: Bool) {
        target.setHighlighted(highlighted)
    }

    private func hide() {
        target.isHidden = true
        target.alphaValue = 0
    }
}

/// The three-band drop overlay for a pane that has a file (§22.4): the two join
/// strips at the top and bottom, and the replace band in the middle. The bands
/// are horizontal (stacked top to bottom) and span the view's full width; the
/// view's height is the region the bands divide (the "this file" half in
/// single-file mode, the full pane in comparison mode). Always present and
/// transparent so it receives file drags; the bands show only for the drag's
/// lifetime, so they never swallow clicks over the hex dump.
final class PaneDropBandsView: NSView {
    /// Fired when the user drops on one of the three bands.
    var onDrop: ((SingleFileDropTarget, [URL]) -> Void)?

    /// Asks what dropping the dragged pane on *this* pane would do. The overlay
    /// accepts the drag only when the answer is something, so a landing with no
    /// meaning is refused by the cursor rather than swallowed and ignored.
    var paneDropOutcome: ((_ draggedPaneID: UUID) -> PaneDrop.Outcome)?

    /// Fired when a dragged pane is let go on this one.
    var onPaneDropped: ((_ draggedPaneID: UUID) -> Void)?

    /// Fired when a drag *session* starts over this overlay and when it ends —
    /// not when it merely leaves, which is a different thing entirely.
    ///
    /// The window raises its New Tab strip on this, and the distinction is the
    /// whole point. Leaving this overlay is exactly what moving towards the
    /// strip looks like, so hiding the strip then takes the target away at the
    /// moment it is being aimed at. Worse, while the strip changed the layout it
    /// made a loop: hide the strip, the panes move up, the pointer is back over
    /// an overlay, show the strip, the panes move down, and the pointer is out
    /// again.
    var onDragSessionChanged: ((Bool) -> Void)?

    /// How much of this overlay's top the window's New Tab strip covers. The
    /// bands divide what is left, so the two never claim the same points
    /// (`Design/PANE_DRAG_PLAN.md`).
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            needsLayout = true
        }
    }

    /// The pane this overlay covers, when the view owns it (comparison mode
    /// wraps each pane). Nil in single-file mode, where the pane sits behind
    /// the overlay in the parent `SingleFileDropView`.
    let paneView: FilePaneView?

    private let insertTarget = DropTargetView(title: SingleFileDropTarget.insertAtStart.title)
    private let replaceTarget = DropTargetView(title: SingleFileDropTarget.replace.title)
    private let appendTarget = DropTargetView(title: SingleFileDropTarget.appendAtEnd.title)
    /// The single plate a *pane* drag gets, covering the whole pane: a pane is
    /// not joined at one end or the other, so the three file bands say nothing
    /// about it. Its caption names the outcome, which differs by where the pane
    /// came from.
    private let paneTarget = DropTargetView(title: "")
    private var dragActive = false
    /// What the pane drag in flight would do here, or nil when the drag in
    /// flight is not a pane.
    private var paneOutcome: PaneDrop.Outcome?

    init(paneView: FilePaneView? = nil) {
        self.paneView = paneView
        super.init(frame: .zero)
        if let paneView {
            // The wrapped pane fills the view and sits behind the bands.
            paneView.translatesAutoresizingMaskIntoConstraints = false
            // The pane's content (header, status bar) has a minimum width;
            // without a low compression resistance the pane refuses to shrink
            // below it, and a band dragged to zero width balloons the whole
            // split view (and the window) to honour the pane's minimum. The
            // bands are flexible (set in ComparisonView); the panes must be
            // too, so a collapsed band can squeeze its pane to nothing (§3.3).
            paneView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            paneView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(paneView)
            NSLayoutConstraint.activate([
                paneView.topAnchor.constraint(equalTo: topAnchor),
                paneView.bottomAnchor.constraint(equalTo: bottomAnchor),
                paneView.leadingAnchor.constraint(equalTo: leadingAnchor),
                paneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        for target in [insertTarget, replaceTarget, appendTarget, paneTarget] {
            // Laid out manually in `layout()`: the strip heights depend on the
            // view's height, which changes on resize.
            target.translatesAutoresizingMaskIntoConstraints = true
            addSubview(target)
        }
        hideBands()
        // Only the comparison-mode overlay (which wraps a pane) is a drop
        // destination. In single-file mode the parent `SingleFileDropView` owns
        // the drop, so this overlay must NOT register: AppKit resolves the drop
        // destination by frame among registered views (not via the `hitTest:`
        // override), and a registered overlay here would be picked as the
        // deepest destination and steal the drop — whose `onDrop` is nil in
        // single-file mode, so the file would be silently discarded.
        if paneView != nil {
            registerForDraggedTypes([.fileURL, .fileNames, .pane])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// In single-file mode this overlay sits ON TOP of the pane as a sibling
    /// (§4.3), so it must pass mouse events through to the hex dump behind it —
    /// otherwise it swallows every click and drag over the dump. In comparison
    /// mode it WRAPS the pane, so the normal hit-test (which descends into the
    /// pane's hex view) applies and the overlay stays the drag destination.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard paneView == nil else { return super.hitTest(point) }
        return nil
    }

    /// Lays the three bands out for the current height: the two join strips at
    /// the top and bottom (each `DropBandLayout.stripHeight` tall) and the
    /// replace band filling the middle. This view is not flipped, so top-down
    /// y is converted to bottom-up here.
    override func layout() {
        super.layout()
        let h = bounds.height
        let layout = DropBandLayout(halfHeight: h, topInset: topInset)
        let strip = layout.stripHeight
        // Top-down in the layout, bottom-up on screen: the bands start below the
        // New Tab strip's share, which is measured from the top.
        let bandsTop = h - topInset
        insertTarget.frame = NSRect(x: 0, y: bandsTop - strip, width: bounds.width, height: strip)
        appendTarget.frame = NSRect(x: 0, y: 0, width: bounds.width, height: strip)
        // The replace band runs from the top strip's bottom edge to the bottom
        // strip's top edge; it collapses to zero in a very short view.
        replaceTarget.frame = NSRect(x: 0, y: strip, width: bounds.width,
                                     height: max(0, bandsTop - 2 * strip))
        // A pane drop is about the whole pane, so its plate is the whole pane.
        paneTarget.frame = bounds
    }

    // MARK: - Drag targeting

    /// Shows or hides the bands for the drag's lifetime. A transparent view
    /// still hit-tests, so the bands must be truly hidden while idle —
    /// otherwise they swallow every click over the pane (§4.3).
    func setDragActive(_ active: Bool) {
        dragActive = active
        if active {
            showBands()
        } else {
            hideBands()
        }
    }

    private func showBands() {
        for target in [insertTarget, replaceTarget, appendTarget] {
            target.isHidden = false
            target.alphaValue = 1
        }
    }

    private func hideBands() {
        for target in [insertTarget, replaceTarget, appendTarget, paneTarget] {
            target.setHighlighted(false)
            target.isHidden = true
            target.alphaValue = 0
        }
        paneOutcome = nil
    }

    /// Shows the pane plate, captioned with what letting go here would do.
    private func showPanePlate(_ outcome: PaneDrop.Outcome) {
        paneOutcome = outcome
        paneTarget.setTitle(Self.paneDropTitle(for: outcome))
        paneTarget.isHidden = false
        paneTarget.alphaValue = 1
        // A single plate has nothing to choose between, so it is lit as soon as
        // it appears: the drag is already on it.
        paneTarget.setHighlighted(true)
    }

    /// What a plate says for each outcome that can land on a pane.
    static func paneDropTitle(for outcome: PaneDrop.Outcome) -> String {
        switch outcome {
        case .swap: return "Swap Panes"
        case .move: return "Move Here"
        case .tearOff, .none: return ""
        }
    }

    /// Highlights whichever band the drag is currently over.
    func updateHover(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let topDownY = bounds.height - point.y
        let band = DropBandLayout(halfHeight: bounds.height, topInset: topInset)
            .band(atTopDownY: topDownY)
        insertTarget.setHighlighted(band == .insertAtStart)
        replaceTarget.setHighlighted(band == .replace)
        appendTarget.setHighlighted(band == .appendAtEnd)
    }

    /// Clears the hover highlight on all three bands.
    func clearHover() {
        insertTarget.setHighlighted(false)
        replaceTarget.setHighlighted(false)
        appendTarget.setHighlighted(false)
    }

    /// The band under the window point, or nil when the point is outside the
    /// view (a drop outside any band changes nothing, §22.4).
    func band(at windowPoint: NSPoint) -> SingleFileDropTarget? {
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { return nil }
        return DropBandLayout(halfHeight: bounds.height, topInset: topInset)
            .band(atTopDownY: bounds.height - point.y)
    }
}

extension PaneDropBandsView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A pane first: its own type is unambiguous, and a pane drag carries no
        // file URLs for the bands to misread.
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            let outcome = paneDropOutcome?(paneID) ?? .none
            // Refused rather than accepted-and-ignored, so the cursor says no
            // before the mouse comes up.
            guard outcome != .none else { return [] }
            showPanePlate(outcome)
            return .move
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        onDragSessionChanged?(true)
        setDragActive(true)
        updateHover(at: sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if paneOutcome != nil { return .move }
        guard dragActive else { return [] }
        updateHover(at: sender.draggingLocation)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // This overlay's own bands go — the pointer is no longer choosing among
        // them — but the session is not over, so the strip stays up.
        setDragActive(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDragActive(false)
        onDragSessionChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragSessionChanged?(false)
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            setDragActive(false)
            onPaneDropped?(paneID)
            return true
        }
        setDragActive(false)
        let urls = sender.draggingPasteboard.droppedFileURLs
        guard !urls.isEmpty else { return true }
        // No band, no act. The points above the bands belong to the New Tab
        // strip, and falling back to Replace there would answer a question this
        // overlay was not asked — the worst shape a drop can take (§4.3).
        guard let band = band(at: sender.draggingLocation) else { return true }
        onDrop?(band, urls)
        return true
    }
}

/// The strip along the top of the window's content: drop a file here to open it
/// in a tab of its own (`Design/PANE_DRAG_PLAN.md`).
///
/// It sits where it does because the system tab bar cannot be a drop target —
/// that is AppKit's own view inside the title bar, and `NSWindowTab` offers a
/// title, a tooltip and an accessory view, none of them a destination. Pressed
/// against the underside of the bar is as close as a target of ours can get, and
/// close enough to read as "up there, into a tab".
///
/// It spans the whole content rather than one pane because it is a window-level
/// target: which pane the pointer happens to be over says nothing about a file
/// that is going somewhere else entirely.
///
/// Like the bands, it shows only for a drag's lifetime, and it is never a
/// hit-test target — the dump behind it keeps the mouse. Being registered is
/// what makes it a drop destination; AppKit resolves those by frame rather than
/// through `hitTest:`, which is also why the pane overlays below inset their
/// bands by this height instead of both claiming the same points.
final class NewTabDropStrip: NSView {
    /// How much of the content's top the strip takes. Deep enough to be aimed
    /// at without care, shallow enough to leave the pane's own bands room.
    static let height: CGFloat = 44

    /// Fired when files are dropped on the strip.
    var onDropFiles: (([URL]) -> Void)?

    private let target = DropTargetView(title: "Open in New Tab")
    private var dragActive = false

    init() {
        super.init(frame: .zero)
        target.translatesAutoresizingMaskIntoConstraints = false
        addSubview(target)
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            target.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            target.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            target.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        registerForDraggedTypes([.fileURL, .fileNames])
        setDragActive(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Never takes the mouse: the strip lies over the dump, and a click there is
    /// the dump's (§4.3).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shown for the drag's lifetime. The window's overlays raise this as soon
    /// as a drag enters any of them, so the strip is on screen before the
    /// pointer reaches it — a target nobody can see is a target nobody uses.
    func setDragActive(_ active: Bool) {
        dragActive = active
        target.isHidden = !active
        target.alphaValue = active ? 1 : 0
        if !active { target.setHighlighted(false) }
    }
}

extension NewTabDropStrip {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        setDragActive(true)
        target.setHighlighted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragActive ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Left the strip, not the window: the plate stays up, unlit, because the
        // drag may well come back to it.
        target.setHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDragActive(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDragActive(false)
        let urls = sender.draggingPasteboard.droppedFileURLs
        guard !urls.isEmpty else { return true }
        onDropFiles?(urls)
        return true
    }
}
