import Cocoa

/// Single-file mode's content view (§4.3, amended by §22.4): wraps the
/// `FilePaneView` and splits the window into two targeted drop regions along
/// the current or default pane layout (left/right ⇄ top/bottom). The "this
/// file" half is divided into three horizontal bands — Insert at Start (top),
/// Replace Current File (middle), Append at End (bottom) — and the "second
/// file" half is the single Open-as-Second target.
///
/// This view is a plain container: it is NOT drop-registered. Each half is a
/// self-contained drop region (`PaneDropBandsView` and `DropZoneView`) that is
/// always present and transparent, shows its visuals only for the drag's
/// lifetime, and fires its own `onDrop`. Dropping outside a drag, or leaving
/// the window, restores the normal pane with no change.
final class SingleFileDropView: NSView {
    /// Fired when the user drops on one of the targets or bands.
    var onDrop: ((SingleFileDropTarget, [URL]) -> Void)?

    /// The pane being dragged over this view, or nil when what is in flight is
    /// not a pane.
    ///
    /// A pane gets the **same four zones a file gets** — the three bands over
    /// this file and the second-pane half beside them — because they mean the
    /// same four things. A pane holds a dump: joining it at either end is the
    /// two-chip round trip (§22), replacing puts it in this pane's place, and
    /// the far half opens it as the second pane, which is the comparison.
    private var draggedPaneID: UUID?

    /// Asks what letting the dragged pane go here would do. A single-file window
    /// has a free second pane, so the answer is normally "move it in beside this
    /// one" — but it is the controller's to give, and it says no to a pane from
    /// this very window, which has nowhere else to be.
    var paneDropOutcome: ((_ draggedPaneID: UUID, _ target: SingleFileDropTarget)
                          -> PaneDrop.Outcome)?

    /// Fired when a dragged pane is let go here, in the zone it landed in.
    var onPaneDropped: ((_ draggedPaneID: UUID, _ target: SingleFileDropTarget) -> Void)?

    /// Fired when a drag session starts here and when it ends — never when it
    /// merely leaves. See `PaneDropBandsView.onDragSessionChanged`: leaving is
    /// what aiming at the New Tab strip looks like from here.
    var onDragSessionChanged: ((Bool) -> Void)?

    let paneView: FilePaneView

    /// The three bands of the "this file" half — a self-contained drop region.
    /// The three-band overlay over the pane's own half. Internal so the window
    /// can inset its bands by the New Tab strip's share, the way it does for the
    /// comparison's two overlays (`Design/PANE_DRAG_PLAN.md`).
    let thisFileBands = PaneDropBandsView()
    /// The "second file" half — a self-contained single-target drop region.
    private let addTarget = DropZoneView(title: SingleFileDropTarget.addSecond.title)

    private static let layoutKey = "ComparisonPaneLayoutIsVertical"

    init(paneView: FilePaneView) {
        self.paneView = paneView
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        addSubview(paneView)
        paneView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: topAnchor),
            paneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            paneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Split the two regions along the current/default layout: isVertical
        // (left/right) ⇒ regions side by side; top/bottom ⇒ stacked (§4.3).
        // The "this file" half holds the three bands; the "second file" half
        // holds the single Open-as-Second target.
        let isVertical = UserDefaults.standard.object(forKey: Self.layoutKey) as? Bool ?? true
        thisFileBands.translatesAutoresizingMaskIntoConstraints = false
        addTarget.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thisFileBands)
        addSubview(addTarget)

        if isVertical {
            thisFileBands.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            thisFileBands.topAnchor.constraint(equalTo: topAnchor).isActive = true
            thisFileBands.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            thisFileBands.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5).isActive = true
            addTarget.leadingAnchor.constraint(equalTo: thisFileBands.trailingAnchor).isActive = true
            addTarget.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            addTarget.topAnchor.constraint(equalTo: topAnchor).isActive = true
            addTarget.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        } else {
            thisFileBands.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            thisFileBands.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            thisFileBands.topAnchor.constraint(equalTo: topAnchor).isActive = true
            thisFileBands.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5).isActive = true
            addTarget.topAnchor.constraint(equalTo: thisFileBands.bottomAnchor).isActive = true
            addTarget.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            addTarget.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            addTarget.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }

        // `.pane` as well as the file types: a pane dragged here goes into the
        // free second pane, which is the comparison the gesture was for. Handling
        // it without registering for it is silent — AppKit simply never delivers
        // the drag, and the zone never appears (`Design/PANE_DRAG_PLAN.md`).
        registerForDraggedTypes([.fileURL, .fileNames, .pane])
    }

    // MARK: - Drag targeting (§4.3)

    /// The drop destination for the whole single-file content area. The two
    /// overlay halves (`thisFileBands`, `addTarget`) are purely visual and pass
    /// mouse events through to the hex dump; the file drag is owned here, by the
    /// always-present container that is the hex view's ancestor, so the drag
    /// system reaches it by walking up from the hex view (§4.3).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A pane, unlike a file, is not joined at one end or the other: there is
        // one free pane in a single-file window and that is where it goes, so
        // the whole view is one target rather than the file bands.
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            draggedPaneID = paneID
            return paneOperation(at: sender.draggingLocation)
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        onDragSessionChanged?(true)
        updateDragTarget(at: sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedPaneID != nil { return paneOperation(at: sender.draggingLocation) }
        updateDragTarget(at: sender.draggingLocation)
        return .copy
    }

    /// Lights the zone under the pointer and reports what letting go there would
    /// mean. A join is a copy — the pane it came from is left as it was — while
    /// replacing and opening as the second pane move it.
    private func paneOperation(at windowPoint: NSPoint) -> NSDragOperation {
        guard let paneID = draggedPaneID else { return [] }
        let target = dropTarget(at: windowPoint) ?? .addSecond
        let outcome = paneDropOutcome?(paneID, target) ?? .none
        // Nothing to offer, so nothing is shown — a window's own pane has
        // nowhere to go here, and lighting the zones for it would offer a
        // choice that does not exist.
        guard outcome != .none else {
            clearDragTarget()
            return []
        }
        thisFileBands.retitleBands(forPane: true,
                                  middle: PaneDropBandsView.paneMiddleTitle(for: outcome))
        addTarget.setTitle("Open as Second Pane")
        updateDragTarget(at: windowPoint)
        switch outcome {
        case .join: return .copy
        case .swap, .move: return .move
        case .none, .tearOff: return []
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endPaneDrag()
        clearDragTarget()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragSessionChanged?(false)
        endPaneDrag()
        clearDragTarget()
    }

    /// Forgets the pane in flight and puts the zones' captions back to the ones
    /// a file gets, so the next file drag does not read as a join of panes.
    private func endPaneDrag() {
        draggedPaneID = nil
        thisFileBands.retitleBands(forPane: false)
        addTarget.setTitle(SingleFileDropTarget.addSecond.title)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            let target = dropTarget(at: sender.draggingLocation) ?? .addSecond
            endPaneDrag()
            clearDragTarget()
            onPaneDropped?(paneID, target)
            return true
        }
        let urls = sender.draggingPasteboard.droppedFileURLs
        onDragSessionChanged?(false)
        clearDragTarget()
        guard !urls.isEmpty else { return true }
        let target = dropTarget(at: sender.draggingLocation) ?? .addSecond
        onDrop?(target, urls)
        return true
    }

    /// The drop target under the window point: one of the three bands when the
    /// pointer is in the "this file" half, or the Open-as-Second target when it
    /// is in the "second file" half.
    private func dropTarget(at windowPoint: NSPoint) -> SingleFileDropTarget? {
        if let band = thisFileBands.band(at: windowPoint) { return band }
        // The pointer is in the "second file" half (outside the bands' bounds).
        return .addSecond
    }

    /// Shows the overlay for the half under the pointer and highlights the
    /// specific band or target; the other half is hidden.
    private func updateDragTarget(at windowPoint: NSPoint) {
        if thisFileBands.band(at: windowPoint) != nil {
            thisFileBands.setDragActive(true)
            thisFileBands.updateHover(at: windowPoint)
            addTarget.setDragActive(false)
        } else {
            thisFileBands.setDragActive(false)
            thisFileBands.clearHover()
            addTarget.setDragActive(true)
            addTarget.setHighlighted(true)
        }
    }

    private func clearDragTarget() {
        thisFileBands.setDragActive(false)
        thisFileBands.clearHover()
        addTarget.setDragActive(false)
        addTarget.setHighlighted(false)
    }
}
