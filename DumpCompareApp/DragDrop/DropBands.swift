import Cocoa

/// One targeted drop zone's visual: a quiet milky plate at idle, flooded with a
/// translucent accent-blue fill on hover, and a caption on its own frosted-glass
/// plate so the label stays readable wherever the fill and the file content
/// behind it are busy (§4.3). Purely visual — the drop handling lives in the
/// owning region view.
final class DropTargetView: NSView {
    private let plate = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let refusalIcon = NSImageView()
    /// Held so the plate can be squared for a refusal and let go for a caption.
    private var plateSquareWidth: NSLayoutConstraint?
    private var plateSquareHeight: NSLayoutConstraint?

    /// The side of the square plate a refusal wears.
    static let refusalPlateSide: CGFloat = 56

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

        // Shown in the label's place when the zone refuses what is being
        // carried. A caption would have to find words for "nothing"; the symbol
        // says it without any, and an empty plate says nothing at all — which is
        // what the middle band looked like when a pane was dragged over its own
        // slot.
        refusalIcon.translatesAutoresizingMaskIntoConstraints = false
        refusalIcon.image = NSImage(systemSymbolName: "nosign",
                                    accessibilityDescription: "Not allowed here")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold))
        refusalIcon.contentTintColor = .secondaryLabelColor
        refusalIcon.isHidden = true
        plate.addSubview(refusalIcon)

        addSubview(plate)
        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: centerXAnchor),
            plate.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The label may truncate (not pin the plate to its full width) so a
            // zero-width zone — a collapsed drop band — doesn't force a minimum
            // width up through the band into the split view's fitting size.
            label.leadingAnchor.constraint(greaterThanOrEqualTo: plate.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: plate.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: plate.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -5),

            refusalIcon.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            refusalIcon.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])

        // Keep the plate inside the zone even when the zone gets narrow: it
        // still hugs the caption, just clamped to the zone's edges. Breakable,
        // because a band can be squeezed past narrow to *zero* — a pane dragged
        // to nothing (§3.3), or the collapsed strip above — and 8 points of
        // inset either side of nothing is not a width a solver can find.
        for clamp in [plate.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                     constant: 8),
                      plate.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                      constant: -8)] {
            clamp.priority = .defaultHigh
            clamp.isActive = true
        }

        // A refusal is a symbol, not a sentence, so its plate is a square rather
        // than the lozenge a caption needs.
        plateSquareWidth = plate.widthAnchor.constraint(equalToConstant: Self.refusalPlateSide)
        plateSquareHeight = plate.heightAnchor.constraint(equalToConstant: Self.refusalPlateSide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Renames the zone. A pane drop means different things in different places
    /// (`Design/PANE_DRAG_PLAN.md`), and one plate says whichever it is.
    func setTitle(_ title: String) {
        label.stringValue = title
        label.isHidden = false
        refusalIcon.isHidden = true
        plateSquareWidth?.isActive = false
        plateSquareHeight?.isActive = false
    }

    /// Marks the zone as one that will not take what is being carried: a
    /// no-entry symbol in place of a caption.
    func setRefused() {
        label.isHidden = true
        refusalIcon.isHidden = false
        plateSquareWidth?.isActive = true
        plateSquareHeight?.isActive = true
    }

    /// Whether the zone is showing its refusal symbol (for tests).
    var isShowingRefusal: Bool { !refusalIcon.isHidden }

    /// The caption the zone is showing (for tests).
    var titleForTesting: String { label.stringValue }

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

    /// Renames the zone. What lands here can be a file or a pane, and the two
    /// are worth different words.
    func setTitle(_ title: String) {
        target.setTitle(title)
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
    var paneDropOutcome: ((_ draggedPaneID: UUID, _ band: SingleFileDropTarget,
                           _ copying: Bool) -> PaneDrop.Outcome)?

    /// Fired when a dragged pane is let go on this one, in the band it landed in.
    var onPaneDropped: ((_ draggedPaneID: UUID, _ band: SingleFileDropTarget,
                        _ copying: Bool) -> Void)?

    /// Whether the drag in flight is asking to copy. Held between updates so the
    /// captions can be recomputed without the dragging info to hand.
    private var draggedPaneIsCopying = false

    /// Fired when Option goes down or up over this overlay, which is the only
    /// place the news arrives: AppKit sends `draggingUpdated` to the destination
    /// under the pointer and to no other. The window passes it on to the zones
    /// that cannot hear it (`setPaneDragCopying`).
    var onCopyModifierChanged: ((Bool) -> Void)?

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
    private var dragActive = false
    /// The pane being dragged over this overlay, or nil when what is in flight
    /// is not a pane. A pane gets the same three bands a file does: a pane holds
    /// a dump, so the ends mean what they always meant — join this at the front,
    /// join it at the back — and only the middle differs.
    private var draggedPaneID: UUID?

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
        for target in [insertTarget, replaceTarget, appendTarget] {
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
        for target in [insertTarget, replaceTarget, appendTarget] {
            target.setHighlighted(false)
            target.isHidden = true
            target.alphaValue = 0
        }
        retitleBandsForFile()
    }

    /// A pane drag arriving over a band, the way `draggingEntered` does — the
    /// only step that learns which pane is in flight.
    func paneDragEnteredForTesting(_ paneID: UUID, at band: SingleFileDropTarget,
                                   copying: Bool = false) -> NSDragOperation {
        draggedPaneID = paneID
        // Through the same note-and-report the real entry uses, so a test drives
        // the reporting rather than a shortcut past it.
        notePaneDragCopying(copying)
        return paneOperation(forBand: band)
    }

    /// The pane drag moving to another band, the way `draggingUpdated` does —
    /// which knows nothing but what the entry remembered.
    func paneDragMovedForTesting(to band: SingleFileDropTarget) -> NSDragOperation {
        paneOperation(forBand: band)
    }

    /// Records the modifier and tells the window when it changed, so the zones
    /// that are not under the pointer can be re-captioned too.
    private func notePaneDragCopying(_ copying: Bool) {
        guard draggedPaneIsCopying != copying else { return }
        draggedPaneIsCopying = copying
        onCopyModifierChanged?(copying)
    }

    /// Takes a modifier change heard by another zone and re-captions these bands
    /// from it. Silent when no pane is in flight over this overlay: its bands
    /// are down, and a caption written now would be the one showing when the
    /// next drag arrives. Never fires `onCopyModifierChanged` — this is the news
    /// arriving, not being made, and answering it would be a loop.
    func setPaneDragCopying(_ copying: Bool) {
        guard let paneID = draggedPaneID, draggedPaneIsCopying != copying else { return }
        draggedPaneIsCopying = copying
        guard dragActive else { return }
        retitleBands(forPane: paneID) { [weak self] band in
            guard let self else { return .none }
            return self.paneDropOutcome?(paneID, band, self.draggedPaneIsCopying) ?? .none
        }
    }

    /// Forgets what is in flight. Only when the drag has actually gone — a
    /// hidden band is not a finished drag. Clearing this whenever the bands went
    /// away meant that crossing the one zone with nothing to offer (the middle
    /// band of the pane's own slot) made the overlay forget the pane, and every
    /// band after that answered "no" for the rest of the drag: entering from
    /// outside worked, moving out of the middle did not.
    private func forgetDraggedPane() {
        draggedPaneID = nil
    }

    /// Puts the file captions back on the bands.
    func retitleBandsForFile() {
        insertTarget.setTitle(SingleFileDropTarget.insertAtStart.title)
        replaceTarget.setTitle(SingleFileDropTarget.replace.title)
        appendTarget.setTitle(SingleFileDropTarget.appendAtEnd.title)
    }

    /// Captions every band from **its own** outcome, not from the one under the
    /// pointer.
    ///
    /// Asking once for the hovered band and using that answer for all three left
    /// the others captioned for something they do not do — the middle band went
    /// blank, an empty grey plate saying nothing, whenever an end band was
    /// hovered over a pane's own slot. A band that will not take what is carried
    /// now says so with the refusal symbol instead of saying nothing.
    /// `outcomeForBand` is passed in rather than read from this view's own
    /// `paneDropOutcome`, which is not always the one that knows: in single-file
    /// mode the container owns the provider and this overlay's is nil, so asking
    /// itself returned "nothing" for every band and put the refusal symbol on
    /// all three.
    func retitleBands(forPane paneID: UUID,
                      outcomeForBand: (SingleFileDropTarget) -> PaneDrop.Outcome) {
        for (band, target) in [(SingleFileDropTarget.insertAtStart, insertTarget),
                               (.replace, replaceTarget),
                               (.appendAtEnd, appendTarget)] {
            if let title = Self.paneBandTitle(for: outcomeForBand(band)) {
                target.setTitle(title)
            } else {
                target.setRefused()
            }
        }
    }

    /// One band's plate, so a test can read what it is showing.
    func bandForTesting(_ band: SingleFileDropTarget) -> DropTargetView {
        switch band {
        case .insertAtStart: return insertTarget
        case .appendAtEnd: return appendTarget
        case .replace, .addSecond: return replaceTarget
        }
    }

    /// What a band says for the outcome it would produce, or nil when it would
    /// produce nothing and should show the refusal symbol instead.
    ///
    /// The ends read exactly as they do for a file, and take their words from
    /// the same place: it is the same operation — `join(contentsOf:at:)` either
    /// way — and two sets of words for it would only invite the reader to look
    /// for a difference that is not there.
    static func paneBandTitle(for outcome: PaneDrop.Outcome) -> String? {
        switch outcome {
        case .join(_, let position):
            return position == .start
                ? SingleFileDropTarget.insertAtStart.title
                : SingleFileDropTarget.appendAtEnd.title
        case .swap: return "Swap Panes"
        case .move: return "Move Here"
        case .duplicate: return "Duplicate Here"
        case .none, .tearOff: return nil
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
            draggedPaneID = paneID
            notePaneDragCopying(sender.isCopyRequested)
            return paneOperation(at: sender.draggingLocation)
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        onDragSessionChanged?(true)
        setDragActive(true)
        updateHover(at: sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedPaneID != nil {
            // Re-read every update: Option pressed or released mid-drag arrives
            // as one of these, and the zones re-label themselves from it — these
            // bands here, and the rest through the window.
            notePaneDragCopying(sender.isCopyRequested)
            return paneOperation(at: sender.draggingLocation)
        }
        guard dragActive else { return [] }
        updateHover(at: sender.draggingLocation)
        return .copy
    }

    /// Lights the band under the pointer and reports what letting go there would
    /// mean. A join is a **copy** — the pane it came from is left as it was, so
    /// the cursor carries the + that says so — while the middle band moves.
    private func paneOperation(at windowPoint: NSPoint) -> NSDragOperation {
        let operation = paneOperation(forBand: band(at: windowPoint) ?? .replace)
        if operation != [] { updateHover(at: windowPoint) }
        return operation
    }

    private func paneOperation(forBand band: SingleFileDropTarget) -> NSDragOperation {
        guard let paneID = draggedPaneID else { return [] }
        let outcome = paneDropOutcome?(paneID, band, draggedPaneIsCopying) ?? .none
        // Nothing to offer, so nothing is shown. The zones are the offer: a
        // pane over the one band with no meaning is refused by the cursor, and
        // lighting the bands anyway would put a choice on screen that does not
        // exist. What is *not* forgotten here is the pane itself — the drag is
        // still in flight, and the next band may well have something to offer.
        guard outcome != .none else {
            setDragActive(false)
            return []
        }
        setDragActive(true)
        retitleBands(forPane: paneID) { [weak self] band in
            guard let self else { return .none }
            return self.paneDropOutcome?(paneID, band, self.draggedPaneIsCopying) ?? .none
        }
        switch outcome {
        // A join and a duplicate both copy — the pane they came from is left
        // as it was — so the cursor carries the + that says so.
        case .join, .duplicate: return .copy
        case .swap, .move: return .move
        case .none, .tearOff: return []
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // This overlay's own bands go — the pointer is no longer choosing among
        // them — but the session is not over, so the strip stays up.
        setDragActive(false)
        forgetDraggedPane()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDragActive(false)
        forgetDraggedPane()
        onDragSessionChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragSessionChanged?(false)
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            let band = band(at: sender.draggingLocation) ?? .replace
            let copying = sender.isCopyRequested
            setDragActive(false)
            forgetDraggedPane()
            onPaneDropped?(paneID, band, copying)
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

    /// Fired when a dragged pane is let go on the strip: it goes to a tab of its
    /// own, moved or copied there.
    var onPaneDropped: ((_ draggedPaneID: UUID, _ copying: Bool) -> Void)?

    /// Fired when Option goes down or up while the pointer is over the strip —
    /// the pane overlays cannot hear it then, and their bands would go on
    /// promising a move. See `PaneDropBandsView.onCopyModifierChanged`.
    var onCopyModifierChanged: ((Bool) -> Void)?

    private let target = DropTargetView(title: "Open in New Tab")
    private var dragActive = false
    /// What the strip is captioned for: a pane says "Move to New Tab", a file
    /// "Open in New Tab", and only the pane's caption answers the modifier.
    private var dragIsPane = false
    private var paneDragIsCopying = false

    init() {
        super.init(frame: .zero)
        target.translatesAutoresizingMaskIntoConstraints = false
        addSubview(target)
        // The strip's height is 0 while no drag is in flight and animates to
        // `height` when one starts, so the vertical inset cannot be required:
        // 4 + a plate + 4 does not fit in nothing, and the solver said so on
        // every launch. The bottom pin yields — which is the one AppKit was
        // breaking anyway — and at any real height both hold exactly. Same
        // shape as the pane header's breakable chain (§3.4), same reason.
        let bottomInset = target.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        bottomInset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            target.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            target.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bottomInset,
        ])
        // Both payloads mean the same thing here — this goes into a tab of its
        // own — which is why one strip serves a file and a pane alike.
        registerForDraggedTypes([.fileURL, .fileNames, .pane])
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
    /// Raised for a drag's lifetime, captioned for what is being carried.
    ///
    /// The caption is set here, when the strip goes up, and not only when a drag
    /// reaches it: the strip is raised by the window's other destinations at the
    /// start of the session, so a caption left from the previous drag would be
    /// on screen the whole time the pointer was on its way over — a file drag
    /// reading "Move to New Tab" because the last thing dragged was a pane.
    func setDragActive(_ active: Bool, forPane isPane: Bool = false, copying: Bool = false) {
        dragActive = active
        dragIsPane = isPane
        paneDragIsCopying = copying
        setTitle(forPane: isPane, copying: copying)
        target.isHidden = !active
        target.alphaValue = active ? 1 : 0
        if !active { target.setHighlighted(false) }
    }

    /// The caption, which differs by what is being carried: a file is opened in
    /// a new tab, a pane moves into one.
    func setTitle(forPane isPane: Bool, copying: Bool = false) {
        guard isPane else {
            target.setTitle("Open in New Tab")
            return
        }
        target.setTitle(copying ? "Duplicate to New Tab" : "Move to New Tab")
    }

    /// The strip's caption, so a test can read what it is promising.
    var titleForTesting: String { target.titleForTesting }

    /// Takes a modifier change heard by a zone elsewhere in the window and
    /// re-captions the strip from it, so what it promises and what the band
    /// under the pointer promises are the same drop. Only while it is up for a
    /// pane: a file is opened in a new tab either way.
    func setPaneDragCopying(_ copying: Bool) {
        guard dragActive, dragIsPane, paneDragIsCopying != copying else { return }
        paneDragIsCopying = copying
        setTitle(forPane: true, copying: copying)
    }
}

extension NewTabDropStrip {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.draggedPaneID != nil {
            let copying = sender.isCopyRequested
            let changed = !dragActive || !dragIsPane || paneDragIsCopying != copying
            setDragActive(true, forPane: true, copying: copying)
            if changed { onCopyModifierChanged?(copying) }
            target.setHighlighted(true)
            return copying ? .copy : .move
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        setDragActive(true, forPane: false)
        target.setHighlighted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragActive else { return [] }
        guard sender.draggingPasteboard.draggedPaneID != nil else { return .copy }
        // Re-read and re-caption on every update: Option pressed or released
        // mid-drag arrives as one of these, and the strip has to say which of
        // the two it will do.
        let copying = sender.isCopyRequested
        guard paneDragIsCopying != copying else { return copying ? .copy : .move }
        paneDragIsCopying = copying
        setTitle(forPane: true, copying: copying)
        // The pane overlays are not under the pointer and hear nothing; the
        // window passes this on to them.
        onCopyModifierChanged?(copying)
        return copying ? .copy : .move
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
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            onPaneDropped?(paneID, sender.isCopyRequested)
            return true
        }
        let urls = sender.draggingPasteboard.droppedFileURLs
        guard !urls.isEmpty else { return true }
        onDropFiles?(urls)
        return true
    }
}
