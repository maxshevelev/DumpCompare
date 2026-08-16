import Cocoa

/// Single-file mode's content view (§4.3): wraps the `FilePaneView` and, while a
/// file drag is over the window, overlays two targeted drop destinations —
/// "Replace Current File" and "Open as Second File" — split along the current or
/// default pane layout (left/right ⇄ top/bottom). Dropping outside a drag, or
/// leaving the window, restores the normal pane with no change.
final class SingleFileDropView: NSView {
    /// Fired when the user drops on one of the targets.
    var onDrop: ((SingleFileDropTarget, [URL]) -> Void)?

    let paneView: FilePaneView

    private let replaceTarget = DropTargetView(title: SingleFileDropTarget.replace.title)
    private let addTarget = DropTargetView(title: SingleFileDropTarget.addSecond.title)
    private var dragActive = false

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

        // Split the two targets along the current/default layout: isVertical
        // (left/right) ⇒ targets side by side; top/bottom ⇒ stacked (§4.3).
        let isVertical = UserDefaults.standard.object(forKey: Self.layoutKey) as? Bool ?? true
        replaceTarget.translatesAutoresizingMaskIntoConstraints = false
        addTarget.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replaceTarget)
        addSubview(addTarget)

        if isVertical {
            replaceTarget.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            replaceTarget.topAnchor.constraint(equalTo: topAnchor).isActive = true
            replaceTarget.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            replaceTarget.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5).isActive = true
            addTarget.leadingAnchor.constraint(equalTo: replaceTarget.trailingAnchor).isActive = true
            addTarget.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            addTarget.topAnchor.constraint(equalTo: topAnchor).isActive = true
            addTarget.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        } else {
            replaceTarget.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            replaceTarget.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            replaceTarget.topAnchor.constraint(equalTo: topAnchor).isActive = true
            replaceTarget.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5).isActive = true
            addTarget.topAnchor.constraint(equalTo: replaceTarget.bottomAnchor).isActive = true
            addTarget.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            addTarget.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            addTarget.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }

        hideTargets()
        registerForDraggedTypes([.fileURL, .fileNames])
    }

    // MARK: - Drag targeting

    private func showTargets() {
        // A transparent view still hit-tests, so the overlays must be truly
        // hidden while idle — otherwise they swallow every click over the pane
        // (the hex dump and the Search All results table) in single-file mode.
        replaceTarget.isHidden = false
        addTarget.isHidden = false
        replaceTarget.alphaValue = 1
        addTarget.alphaValue = 1
    }

    private func hideTargets() {
        replaceTarget.setHighlighted(false)
        addTarget.setHighlighted(false)
        replaceTarget.isHidden = true
        addTarget.isHidden = true
        replaceTarget.alphaValue = 0
        addTarget.alphaValue = 0
    }

    /// Highlights whichever target the drag is currently over.
    private func updateTargetHover(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        replaceTarget.setHighlighted(replaceTarget.frame.contains(point))
        addTarget.setHighlighted(addTarget.frame.contains(point))
    }

    private func hoveredTarget(at windowPoint: NSPoint) -> SingleFileDropTarget {
        let point = convert(windowPoint, from: nil)
        return replaceTarget.frame.contains(point) ? .replace : .addSecond
    }
}

extension SingleFileDropView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        dragActive = true
        showTargets()
        updateTargetHover(at: sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragActive else { return [] }
        updateTargetHover(at: sender.draggingLocation)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragActive = false
        hideTargets()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragActive = false
        hideTargets()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragActive = false
        hideTargets()
        let urls = sender.draggingPasteboard.droppedFileURLs
        guard !urls.isEmpty else { return true }
        onDrop?(hoveredTarget(at: sender.draggingLocation), urls)
        return true
    }
}

/// One of the two targeted drop zones shown during a drag.
private final class DropTargetView: NSView {
    /// The caption's frosted-glass plate — like an Xcode message bubble — so
    /// the label stays readable wherever the zone's blue fill and the file
    /// content behind it are busy (§4.3).
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
