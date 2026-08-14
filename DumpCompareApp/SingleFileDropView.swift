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
        replaceTarget.alphaValue = 1
        addTarget.alphaValue = 1
    }

    private func hideTargets() {
        replaceTarget.setHighlighted(false)
        addTarget.setHighlighted(false)
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
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        label.stringValue = title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setHighlighted(_ highlighted: Bool) {
        wantsLayer = true
        layer?.backgroundColor = (highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.25)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.9)).cgColor
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = highlighted ? 2 : 1
        label.textColor = highlighted ? .labelColor : .secondaryLabelColor
    }
}
