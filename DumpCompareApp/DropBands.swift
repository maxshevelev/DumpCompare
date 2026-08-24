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

            label.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: plate.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

/// A self-contained single-target drop region (§4.3): the "second file" half in
/// single-file mode. Always present and transparent so it receives file drags,
/// it shows its caption plate only for the drag's lifetime and fires `onDrop`
/// with the dropped URLs.
final class DropZoneView: NSView {
    /// Fired with the dropped URLs when the user drops on this region.
    var onDrop: (([URL]) -> Void)?

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
        registerForDraggedTypes([.fileURL, .fileNames])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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

extension DropZoneView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        setDragActive(true)
        setHighlighted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragActive else { return [] }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragActive(false)
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
        onDrop?(urls)
        return true
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

    /// The pane this overlay covers, when the view owns it (comparison mode
    /// wraps each pane). Nil in single-file mode, where the pane sits behind
    /// the overlay in the parent `SingleFileDropView`.
    let paneView: FilePaneView?

    private let insertTarget = DropTargetView(title: SingleFileDropTarget.insertAtStart.title)
    private let replaceTarget = DropTargetView(title: SingleFileDropTarget.replace.title)
    private let appendTarget = DropTargetView(title: SingleFileDropTarget.appendAtEnd.title)
    private var dragActive = false

    init(paneView: FilePaneView? = nil) {
        self.paneView = paneView
        super.init(frame: .zero)
        if let paneView {
            // The wrapped pane fills the view and sits behind the bands.
            paneView.translatesAutoresizingMaskIntoConstraints = false
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
        registerForDraggedTypes([.fileURL, .fileNames])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Lays the three bands out for the current height: the two join strips at
    /// the top and bottom (each `DropBandLayout.stripHeight` tall) and the
    /// replace band filling the middle. This view is not flipped, so top-down
    /// y is converted to bottom-up here.
    override func layout() {
        super.layout()
        let h = bounds.height
        let strip = DropBandLayout(halfHeight: h).stripHeight
        insertTarget.frame = NSRect(x: 0, y: h - strip, width: bounds.width, height: strip)
        appendTarget.frame = NSRect(x: 0, y: 0, width: bounds.width, height: strip)
        // The replace band runs from the top strip's bottom edge to the bottom
        // strip's top edge; it collapses to zero in a very short view.
        replaceTarget.frame = NSRect(x: 0, y: strip, width: bounds.width,
                                     height: max(0, h - 2 * strip))
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
    }

    /// Highlights whichever band the drag is currently over.
    func updateHover(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let topDownY = bounds.height - point.y
        let band = DropBandLayout(halfHeight: bounds.height).band(atTopDownY: topDownY)
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
        return DropBandLayout(halfHeight: bounds.height).band(atTopDownY: bounds.height - point.y)
    }
}

extension PaneDropBandsView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        setDragActive(true)
        updateHover(at: sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragActive else { return [] }
        updateHover(at: sender.draggingLocation)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragActive(false)
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
        onDrop?(band(at: sender.draggingLocation) ?? .replace, urls)
        return true
    }
}
