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

    /// The single plate a dragged pane gets, over the whole view.
    private let paneTarget = DropTargetView(title: "Open as Second Pane")
    private var paneDragActive = false

    private func showPanePlate() {
        paneTarget.frame = bounds
        paneTarget.isHidden = false
        paneTarget.alphaValue = 1
        paneTarget.setHighlighted(true)
    }

    private func hidePanePlate() {
        paneDragActive = false
        paneTarget.setHighlighted(false)
        paneTarget.isHidden = true
        paneTarget.alphaValue = 0
    }

    /// Asks what letting the dragged pane go here would do. A single-file window
    /// has a free second pane, so the answer is normally "move it in beside this
    /// one" — but it is the controller's to give, and it says no to a pane from
    /// this very window, which has nowhere else to be.
    var paneDropOutcome: ((_ draggedPaneID: UUID) -> PaneDrop.Outcome)?

    /// Fired when a dragged pane is let go here.
    var onPaneDropped: ((_ draggedPaneID: UUID) -> Void)?

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
        // In front of both halves, and laid out by frame: a pane drop is about
        // the whole window, so its plate covers the whole of it.
        paneTarget.translatesAutoresizingMaskIntoConstraints = true
        addSubview(paneTarget)
        hidePanePlate()

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

        registerForDraggedTypes([.fileURL, .fileNames])
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
            guard paneDropOutcome?(paneID) ?? .none != .none else { return [] }
            paneDragActive = true
            showPanePlate()
            return .move
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        onDragSessionChanged?(true)
        updateDragTarget(at: sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if paneDragActive { return .move }
        updateDragTarget(at: sender.draggingLocation)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hidePanePlate()
        clearDragTarget()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragSessionChanged?(false)
        hidePanePlate()
        clearDragTarget()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            hidePanePlate()
            onPaneDropped?(paneID)
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
