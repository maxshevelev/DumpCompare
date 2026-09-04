import Cocoa

/// A short-lived notice over the window: a rounded frosted plate with a glyph
/// and a few lines, which fades in, holds, and fades out on its own.
///
/// For an answer that is about a *whole* operation rather than about the place
/// the user is looking — "Smart search tried these five encodings and none of
/// them found anything" (§11). The pane's status bar is the wrong place for
/// that: it is a strip beside the file's own numbers, sized for one line, and
/// the report here is a list. The plate is the shape the platform already uses
/// for exactly this — Xcode's build and test results — so it needs no
/// explaining.
///
/// Deliberately not interactive: it reports and leaves. `hitTest` returns nil,
/// so a click on the dump underneath goes to the dump and the notice is never
/// something to dismiss.
final class TransientNoticeView: NSVisualEffectView {
    /// How long the plate holds before it fades. A `var` so a test can shorten
    /// it instead of sleeping through it.
    static var holdDuration: TimeInterval = 4
    static let fadeInDuration: TimeInterval = 0.15
    static let fadeOutDuration: TimeInterval = 0.3
    /// The plate's own metrics.
    static let cornerRadius: CGFloat = 14
    static let symbolPointSize: CGFloat = 28

    private let symbolView = NSImageView()
    private let textStack = NSStackView()
    private var dismissWorkItem: DispatchWorkItem?

    /// What the plate says, for tests.
    private(set) var lines: [String] = []

    init(symbol: String, lines: [String]) {
        super.init(frame: .zero)
        material = .hudWindow
        // Within the window, not behind it: the plate frosts the dump it sits
        // over, which is what makes it read as being *in* the document rather
        // than as another window.
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0

        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.symbolPointSize, weight: .regular)
        symbolView.contentTintColor = .labelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        self.lines = lines
        for (index, line) in lines.enumerated() {
            let label = NSTextField(labelWithString: line)
            // The first line names the operation, the rest are its findings —
            // one heading, then a list.
            label.font = index == 0
                ? .systemFont(ofSize: 13, weight: .semibold)
                : .systemFont(ofSize: 12)
            label.textColor = index == 0 ? .labelColor : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(label)
        }

        addSubview(symbolView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(lines.joined(separator: " "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A click here belongs to whatever is underneath: the notice is a report,
    /// not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fades in, holds, and fades out — then removes itself, so nothing owns
    /// it but the window it was shown in.
    func present() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced {
            alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
        }
        let dismiss = DispatchWorkItem { [weak self] in self?.dismiss(animated: !reduced) }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: dismiss)
    }

    func dismiss(animated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard animated else {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
        }
    }
}
