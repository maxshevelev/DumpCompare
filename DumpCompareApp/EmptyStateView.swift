import Cocoa

/// Placeholder shown in empty mode (§3.1): a large system icon that opens the
/// file picker on click, a "Drop files here" headline, the up-to-two-files
/// hint, and drag-and-drop support (§4.3 empty mode).
final class EmptyStateView: NSView {
    /// Fired with the dropped file URLs; the view controller applies §4.3 rules.
    var onOpenFiles: (([URL]) -> Void)?

    /// The muted grey shared by the icon and the headline — softer than the
    /// regular secondary text, so the landing screen reads as a hint, not a
    /// primary control.
    private static let iconColor = NSColor.tertiaryLabelColor

    /// The icon is a third of the window's shorter side, capped so a huge
    /// window doesn't blow it up past this point.
    private static let maxIconSize: CGFloat = 400

    /// Fixed vertical distance (points) between the icon's visible bottom edge
    /// and the headline — constant no matter the icon size.
    private static let headlineGap: CGFloat = 48

    private let openButton = NSButton()

    /// The vertical stack holding the icon, headline and hint — kept so
    /// `updateIconSize()` can adjust the icon–headline gap per size.
    private var contentStack: NSStackView?

    init() {
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 4

        // The icon doubles as the Open File button — clicking it opens the
        // picker through the same responder-chain action the old button used.
        openButton.target = nil
        openButton.action = #selector(MainViewController.presentOpenPanel)
        openButton.isBordered = false
        openButton.imagePosition = .imageOnly
        // No `setButtonType`: the default momentary push-in dims the icon while
        // it is held. `.momentaryChange` would swap in `alternateImage`, which
        // this button does not have, so a press showed nothing.
        openButton.contentTintColor = Self.iconColor
        openButton.setAccessibilityLabel("Open File")  // §15

        let titleLabel = NSTextField(labelWithString: "Drop files here")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = Self.iconColor

        let hintLabel = NSTextField(labelWithString:
            "Up to two files can be compared side by side."
        )
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: 13)

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(openButton)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(hintLabel)
        addSubview(stackView)
        contentStack = stackView

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Sets the icon image and the icon–headline gap (which depends on the
        // symbol's built-in padding).
        updateIconSize()

        registerForDraggedTypes([.fileURL, .fileNames])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The window size is only known once the view is in a window; rescale
        // the icon for the real window the view lands in.
        updateIconSize()
    }

    override func layout() {
        super.layout()
        // Resizing the window changes its shorter side, so the icon must scale
        // along with it.
        updateIconSize()
    }

    private var currentIconSize: CGFloat = 0

    /// Sizes the icon to a third of the window's shorter side, capped at
    /// `maxIconSize`. Falls back to a fixed 96pt when there's no window yet
    /// (e.g. in headless tests).
    private func updateIconSize() {
        let windowSize = window?.frame.size
        let shortSide = windowSize.map { min($0.width, $0.height) } ?? 0
        let size = shortSide > 0 ? min(shortSide / 3, Self.maxIconSize) : 96
        guard size != currentIconSize else { return }
        currentIconSize = size
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .light)
        guard let image = NSImage(systemSymbolName: "plus.viewfinder", accessibilityDescription: "Open File")?
            .withSymbolConfiguration(config) else { return }
        openButton.image = image
        // SF Symbol glyphs sit inside their image with built-in padding that
        // scales with the size, so a fixed stack spacing would drift the gap
        // between the *visible* icon and the headline. Add the glyph's bottom
        // inset back so the visible gap stays `headlineGap` exactly.
        contentStack?.setCustomSpacing(Self.headlineGap + Self.visibleBottomInset(of: image), after: openButton)
    }

    /// The glyph's bottom inset (in points) inside its image. SF Symbols draw
    /// the viewfinder frame with built-in padding, so the image's bottom edge
    /// isn't the icon's visible bottom. Measured by rendering the image and
    /// scanning upward from the bottom for the first opaque pixel.
    private static func visibleBottomInset(of image: NSImage) -> CGFloat {
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: width * 4, bitsPerPixel: 32) else { return 0 }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return 0 }
        let bytesPerRow = rep.bytesPerRow
        // Row 0 is the top; the distance from the lowest opaque row to the
        // image's bottom edge is the glyph's bottom padding.
        for row in stride(from: height - 1, through: 0, by: -1) {
            let base = row * bytesPerRow
            for col in 0..<width where data[base + col * 4 + 3] > 0 {
                return CGFloat(height - 1 - row)
            }
        }
        return 0
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = highlighted ? 3 : 0
    }
}

// NSView already conforms to NSDraggingDestination (empty defaults); we override
// the members. Only registered destination views receive drag callbacks.
extension EmptyStateView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        setDropHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        let urls = sender.draggingPasteboard.droppedFileURLs
        if !urls.isEmpty {
            onOpenFiles?(urls)
        }
        return true
    }
}
