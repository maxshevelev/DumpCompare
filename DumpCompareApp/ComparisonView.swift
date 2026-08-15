import Cocoa
import DumpCompareCore

/// The comparison-mode content view (§3.3, §9): two `FilePaneView`s inside a
/// draggable `NSSplitView`, with:
/// - a left/right ⇄ top/bottom toggle (View menu) persisted in `UserDefaults`;
/// - synchronized scrolling by absolute offset (same row layout ⇒ same y);
/// - the comparison coordinator's diff counts mirrored into the panes' status
///   bars, and its build operation shown in the ACTIVE pane's status bar.
final class ComparisonView: NSView {
    let coordinator: ComparisonCoordinator
    let paneView1: FilePaneView
    let paneView2: FilePaneView

    /// Fired when the user clicks a pane so MainViewController can re-point the
    /// active pane (§3.3).
    var onPaneActivated: ((Int) -> Void)?

    let splitView = ProportionalSplitView()
    private var scrollObservers: [NSObjectProtocol] = []
    private var isSynchronizingScroll = false

    /// The coordinator operation currently presented; moved between panes as
    /// the active pane changes (§14.4).
    private var currentOperation: BackgroundOperation?

    private static let layoutKey = "ComparisonPaneLayoutIsVertical"

    init(coordinator: ComparisonCoordinator, paneView1: FilePaneView, paneView2: FilePaneView) {
        self.coordinator = coordinator
        self.paneView1 = paneView1
        self.paneView2 = paneView2
        super.init(frame: .zero)
        setUp()
        bindCoordinator()
        refreshComparisonInfo()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func setUp() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.dividerStyle = .thin
        splitView.isVertical = UserDefaults.standard.object(forKey: Self.layoutKey) as? Bool ?? true
        addSubview(splitView)

        // Let the splitter treat both panes as flexible.
        paneView1.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paneView1.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        paneView2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paneView2.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The panes are Auto Layout subviews of the splitter; Proportional-
        // SplitView's `layout()` override positions them proportionally (§3.3).
        // Keeping `translatesAutoresizingMaskIntoConstraints` off avoids the
        // autoresizing "width == 0" constraint that NSSplitView otherwise adds
        // to zero-frame subviews.
        paneView1.translatesAutoresizingMaskIntoConstraints = false
        paneView2.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(paneView1)
        splitView.addArrangedSubview(paneView2)

        // §3.3: the split defaults to 50/50 (a fresh ComparisonView — e.g. the
        // one built when the second file opens), the divider can be dragged to
        // any ratio, and window resizes keep that ratio proportionally.
        // No autosaveName: opening a second file always starts at 50/50 rather
        // than restoring a stale divider position.

        paneView1.onActivate = { [weak self] in self?.onPaneActivated?(0) }
        paneView2.onActivate = { [weak self] in self?.onPaneActivated?(1) }

        // §3.3: double-clicking a header in side-by-side mode expands that pane
        // so its hex content fits by width.
        paneView1.onHeaderDoubleClick = { [weak self] in self?.fitContentWidth(of: 0) }
        paneView2.onHeaderDoubleClick = { [weak self] in self?.fitContentWidth(of: 1) }

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        observeScroll()
    }

    /// Toggles the pane arrangement (§3.3: left/right ⇄ top/bottom).
    func toggleLayout() {
        splitView.isVertical.toggle()
        UserDefaults.standard.set(splitView.isVertical, forKey: Self.layoutKey)
    }

    /// Expands pane `index` so its hex content fits by width, animating the
    /// divider there if the pane is currently too narrow. No-op in stacked mode,
    /// where the panes are already full-width (§3.3).
    func fitContentWidth(of index: Int) {
        let pane = index == 0 ? paneView1 : paneView2
        guard pane.frame.width < pane.contentFitWidth else { return }
        splitView.fitPane(index, minimumWidth: pane.contentFitWidth)
    }

    /// Highlights `index` as the active pane. The operation indicator follows
    /// the active pane: if an operation is running it is moved onto the pane
    /// that just became active (revealed immediately — it is already past the
    /// debounce, so re-debouncing would blink it off and on).
    func setActive(_ index: Int) {
        paneView1.setActive(index == 0)
        paneView2.setActive(index == 1)
        if let currentOperation, currentOperation.isActive {
            paneView1.endOperation()
            paneView2.endOperation()
            activePaneView().beginOperation(currentOperation, revealImmediately: true)
        }
    }

    // MARK: - Scroll synchronization (§9)

    private func observeScroll() {
        for (scroller, other) in [(paneView1.scrollView, paneView2.scrollView),
                                  (paneView2.scrollView, paneView1.scrollView)] {
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroller.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.syncScroll(from: scroller, to: other)
            }
            scrollObservers.append(token)
        }
    }

    private func syncScroll(from scroller: NSScrollView, to other: NSScrollView) {
        guard !isSynchronizingScroll else { return }
        isSynchronizingScroll = true
        defer { isSynchronizingScroll = false }

        var origin = scroller.contentView.bounds.origin
        // Clamp to the other pane's scrollable extent so a shorter file can't be
        // scrolled into blank space (§9: shorter pane shows EOF/missing area).
        let otherMaxY = max(0, (other.documentView?.frame.height ?? 0) - other.contentSize.height)
        origin.y = min(origin.y, otherMaxY)
        origin.x = max(0, min(origin.x, max(0, (other.documentView?.frame.width ?? 0) - other.contentSize.width)))

        other.contentView.scroll(to: origin)
        other.reflectScrolledClipView(other.contentView)
    }

    deinit {
        for token in scrollObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Coordinator → status bar

    private func bindCoordinator() {
        coordinator.onOperation = { [weak self] op in
            self?.presentOperation(op)
        }
        coordinator.onIndexChanged = { [weak self] _ in
            self?.refreshComparisonInfo()
        }
    }

    /// Shows a coordinator build operation in the ACTIVE pane's status bar,
    /// replacing whatever operation was shown before (in both panes). The
    /// indicator is a single instance presented on the pane the user is
    /// looking at; switching the active pane moves it (see `setActive`).
    func presentOperation(_ op: BackgroundOperation) {
        paneView1.endOperation()
        paneView2.endOperation()
        currentOperation = op
        activePaneView().beginOperation(op)
    }

    private func activePaneView() -> FilePaneView {
        paneView1.isActive ? paneView1 : paneView2
    }

    func refreshComparisonInfo() {
        let text: String
        if let index = coordinator.index {
            var diffBytes: UInt64 = 0
            var sameBytes: UInt64 = 0
            for block in index.blocks {
                if block.kind == .different { diffBytes += block.count } else { sameBytes += block.count }
            }
            text = "\(diffBytes) differing · \(sameBytes) same"
        } else {
            // While building, the progress bar (not text) shows the status; the
            // summary only appears once the index is ready (§14.4).
            text = ""
        }
        paneView1.comparisonInfo = text
        paneView2.comparisonInfo = text
    }

    /// Replaces the diff summary with a transient navigation message (e.g.
    /// "No more differences"). Overwritten by the next coordinator refresh.
    func showNavigationMessage(_ message: String) {
        paneView1.comparisonInfo = message
        paneView2.comparisonInfo = message
    }
}
