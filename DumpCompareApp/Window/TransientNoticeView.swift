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
    /// How long a plate with something to read holds before it fades. A `var`
    /// so a test can shorten it instead of sleeping through it.
    static var holdDuration: TimeInterval = 4
    /// How long a plate that is only a glyph holds. Shorter, because it is
    /// taken in at a glance and there is nothing to read: a wrap says "you are
    /// back at the top", and by the time it is understood it has done its job.
    static var glyphHoldDuration: TimeInterval = 0.9
    static let fadeInDuration: TimeInterval = 0.15
    static let fadeOutDuration: TimeInterval = 0.3
    /// The plate's own metrics.
    static let cornerRadius: CGFloat = 14
    static let symbolPointSize: CGFloat = 28
    /// The glyph on a plate that is nothing but the glyph — big enough to read
    /// as a sign rather than as an icon beside missing text.
    static let glyphPointSize: CGFloat = 44

    private let symbolView = NSImageView()
    private let textStack = NSStackView()
    private var dismissWorkItem: DispatchWorkItem?

    /// What the plate says, for tests.
    private(set) var lines: [String] = []

    /// A plate that is one large glyph and nothing else — a sign rather than a
    /// report (§11: a search that wrapped).
    convenience init(glyph symbol: String) {
        self.init(symbol: symbol, lines: [])
    }

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
            pointSize: lines.isEmpty ? Self.glyphPointSize : Self.symbolPointSize,
            weight: .regular)
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
        if lines.isEmpty {
            // Nothing to sit beside: the glyph is the plate, padded evenly so
            // it comes out square.
            let inset: CGFloat = 22
            NSLayoutConstraint.activate([
                symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                symbolView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                symbolView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
                symbolView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ])
        } else {
            addSubview(textStack)
            NSLayoutConstraint.activate([
                symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
                symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),

                textStack.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor,
                                                   constant: 14),
                textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                textStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
                textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            ])
        }
        setAccessibilityRole(.staticText)
        // A glyph-only plate still has to say something to a reader who cannot
        // see it, and what it says is the thing it stands for.
        setAccessibilityLabel(lines.isEmpty ? symbol : lines.joined(separator: " "))
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
    func present(holdingFor hold: TimeInterval? = nil) {
        let duration = hold ?? (lines.isEmpty ? Self.glyphHoldDuration : Self.holdDuration)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
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

/// Shows transient notices in a view, one at a time (§11).
///
/// The one place that decides where a plate of this kind goes, how it arrives
/// and leaves, and that a new one replaces the last rather than piling onto
/// it. Every such report — a Smart Search that found nothing, a search that
/// came round the end of the file — is shown through here, so they cannot
/// drift apart into two conventions.
@MainActor
final class TransientNoticePresenter {
    /// Where a plate's middle sits, as a fraction of the host's height **up
    /// from the bottom**: the lower third.
    ///
    /// Out of the way of the bytes being read, which are at the top of the
    /// window where the caret was left, and of the find bar above them — and
    /// still inside the window rather than at its edge, so it reads as the
    /// app's own answer and not as a system alert.
    static let verticalFraction: CGFloat = 1.0 / 3
    /// How close a plate may come to the host's bottom edge on a window too
    /// short for the fraction to clear it.
    static let minimumBottomInset: CGFloat = 12
    /// How much of the host's width a plate may take.
    static let horizontalInset: CGFloat = 40

    private weak var host: NSView?
    /// The plate on screen, if any. Internal so tests can read what it says.
    private(set) var current: TransientNoticeView?

    init(host: NSView) {
        self.host = host
    }

    /// A plate with something to read: a glyph and a few lines.
    func show(symbol: String, lines: [String]) {
        show(TransientNoticeView(symbol: symbol, lines: lines))
    }

    /// A plate that is one large glyph and nothing else — a sign rather than a
    /// report.
    func show(glyph symbol: String) {
        show(TransientNoticeView(glyph: symbol))
    }

    func dismiss() {
        current?.dismiss(animated: false)
        current = nil
    }

    private func show(_ notice: TransientNoticeView) {
        guard let host else { return }
        current?.dismiss(animated: false)
        host.addSubview(notice)
        // A fraction of the height, not a fixed inset: the plate sits in the
        // same place on a short window and a tall one. The multiplier form is
        // the only one that can say that — anchors take constants — and it
        // measures from the top, so the lower third is what is left of the
        // height above it.
        let placement = NSLayoutConstraint(item: notice, attribute: .centerY, relatedBy: .equal,
                                           toItem: host, attribute: .bottom,
                                           multiplier: 1 - Self.verticalFraction, constant: 0)
        // On a window too short for the fraction to clear the bottom, the plate
        // stops rather than hanging off it. Preferred, so the fraction wins
        // wherever it fits.
        let clearsBottom = notice.bottomAnchor.constraint(
            lessThanOrEqualTo: host.bottomAnchor, constant: -Self.minimumBottomInset)
        clearsBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            placement,
            clearsBottom,
            notice.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor,
                                          constant: -Self.horizontalInset),
        ])
        current = notice
        notice.present()
    }
}
