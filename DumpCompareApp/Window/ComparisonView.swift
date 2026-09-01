import Cocoa
import DumpCompareCore
import ALSplitView

/// The comparison-mode content view (§3.3, §9): two `FilePaneView`s inside a
/// draggable `ALSplitView`, with:
/// - a left/right ⇄ top/bottom toggle (View menu) persisted in `UserDefaults`;
/// - synchronized scrolling by absolute offset (same row layout ⇒ same y);
/// - the comparison coordinator's diff counts mirrored into the panes' status
///   bars, and its build operation shown in the ACTIVE pane's status bar.
final class ComparisonView: NSView {
    let coordinator: ComparisonCoordinator
    let paneView1: FilePaneView
    let paneView2: FilePaneView

    /// Each pane's three-band drop overlay (§22.4): the split view's panes,
    /// wrapping the panes. The bands are the drop targets; the panes show
    /// through them. Held so the owner can wire each band's `onDrop`.
    private(set) var bands1: PaneDropBandsView!
    private(set) var bands2: PaneDropBandsView!

    /// Fired when the user clicks a pane so MainViewController can re-point the
    /// active pane (§3.3).
    var onPaneActivated: ((Int) -> Void)?

    let splitView = ALSplitView()

    // MARK: - Proportional split (§3.3)

    /// Fraction (0...1) of the split axis given to the first pane, stored per
    /// pane layout (§3.3): side-by-side (vertical) and stacked (horizontal) each
    /// keep their own divider proportion, so dragging the divider in one
    /// arrangement never changes the other's. 0.5 until a divider drag or a
    /// 50/50 reset changes it; resizes never touch it.
    private var verticalFraction: CGFloat = 0.5
    private var horizontalFraction: CGFloat = 0.5

    /// The fraction for the CURRENT layout: `isVertical` picks which slot to
    /// read or write, so every read/write in the drag and animation paths
    /// targets the active arrangement.
    private var fraction: CGFloat {
        get { splitView.isVertical ? verticalFraction : horizontalFraction }
        set { if splitView.isVertical { verticalFraction = newValue } else { horizontalFraction = newValue } }
    }

    /// Called whenever the divider fraction changes — a drag or the 50/50
    /// reset. The minimap uses it to keep its stacked divider line glued to the
    /// panes' divider (§19).
    var onFractionChanged: (() -> Void)?

    /// The current split fraction of the first pane along the split axis
    /// (0...1), read by the minimap so its stacked divider mirrors the panes'.
    var currentFraction: CGFloat { fraction }

    /// The divider is drawn as a solid strip at this thickness (§3.3): a 1pt
    /// hairline is too faint next to a dense hex grid. The value feeds the
    /// pane layout and is reused by the launch-frame width calculation (§3.1).
    static let dividerThicknessValue: CGFloat = 6

    private var scrollObservers: [NSObjectProtocol] = []
    private var isSynchronizingScroll = false
    /// Whether scroll sync is live. It stays off until the first layout, so the
    /// second pane's initial layout can't drag the first pane (the first pane is
    /// the scroll source of truth on entry — the second adjusts to it, §9).
    private var isSyncArmed = false

    /// The coordinator operation currently presented; moved between panes as
    /// the active pane changes (§14.4).
    private var currentOperation: BackgroundOperation?

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
        splitView.dividerThickness = Self.dividerThicknessValue
        splitView.isVertical = LayoutSettings.isVertical
        addSubview(splitView)

        // Each pane is wrapped in a three-band drop overlay (§22.4): the bands
        // are the drop targets, and the pane shows through them. The wrappers
        // are the splitter's panes; the panes fill them (the wrapper's init
        // lays the pane out).
        bands1 = PaneDropBandsView(paneView: paneView1)
        bands2 = PaneDropBandsView(paneView: paneView2)
        splitView.addPane(bands1)
        splitView.addPane(bands2)

        // §3.3: the split defaults to 50/50 (a fresh ComparisonView — e.g. the
        // one built when the second file opens), the divider can be dragged to
        // any ratio, and window resizes keep that ratio proportionally. The
        // first pane is proportional and the second fills the remainder, so a
        // resize redistributes by the stored fraction. No autosave: opening a
        // second file always starts at 50/50 rather than restoring a stale
        // divider position.
        splitView.setPaneLayout(.proportional(fraction), at: 0)
        splitView.setPaneLayout(.fill, at: 1)

        // §3.3: neither pane may be squeezed out of existence. Every way the
        // divider moves — a drag, the header's double-click fit, the divider's
        // own double-click, a window resize — goes through this clamp
        // (`ALSplitView` applies it in `setDividerPosition`, which the drag and
        // each animation tick both call), so the rule is stated once here rather
        // than at each of those call sites.
        //
        // Stacked panes get the same treatment on their own axis, where the
        // least that says "this pane is here" is its header.
        splitView.clampDividerPosition = { [weak self] _, position in
            guard let self else { return position }
            let available = self.splitView.axisAvailable()
            let minimum = self.splitView.isVertical
                ? FilePaneView.minPaneWidth
                : FilePaneView.headerHeight
            // In a window too small for both minimums there is nothing to
            // enforce: clamping would fight itself, so the position stands.
            guard available >= 2 * minimum else { return position }
            // The position *is* pane 0's size, and the remainder is pane 1's, so
            // one interval covers both.
            return min(max(position, minimum), available - minimum)
        }

        // A divider drag re-derives the ratio from where the divider lands and
        // reports it: the minimap's stacked divider line is glued to this one
        // via onFractionChanged (§19).
        splitView.onDividerMoved = { [weak self] _, position in
            guard let self else { return }
            let available = self.splitView.axisAvailable()
            guard available > 0 else { return }
            self.fraction = position / available
            self.onFractionChanged?()
        }

        // §3.3: a double-click on the divider resets it to a 50/50 split,
        // replacing NSSplitView's default double-click behavior (collapsing a
        // pane, which this app never uses).
        splitView.onDividerDoubleClicked = { [weak self] _ in
            guard let self else { return }
            self.splitView.animateDividerPosition(to: self.splitView.axisAvailable() / 2)
        }

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

    /// Sets the pane arrangement (§3.3: left/right ⇄ top/bottom), persisting it
    /// as the default a new comparison opens with (§6 Layout settings). A no-op
    /// when the orientation already matches — `setLayout` is also the re-entry
    /// point for the Layout settings tab's live-apply, so this guard also stops
    /// the persist→notify→apply loop.
    func setLayout(vertical: Bool) {
        guard splitView.isVertical != vertical else { return }
        splitView.isVertical = vertical
        // The policies are shared across orientations, so re-apply the
        // proportion stored for the arrangement we just switched TO: pane 0
        // takes that fraction, pane 1 fills the remainder.
        splitView.setPaneLayout(.proportional(fraction), at: 0)
        LayoutSettings.set(isVertical: vertical)
    }

    /// Toggles the pane arrangement (§3.3: left/right ⇄ top/bottom).
    func toggleLayout() {
        setLayout(vertical: !splitView.isVertical)
    }

    /// Expands pane `index` so its hex content fits by width, animating the
    /// divider there if the pane is currently too narrow. No-op in stacked mode,
    /// where the panes are already full-width (§3.3).
    func fitContentWidth(of index: Int) {
        let pane = index == 0 ? paneView1 : paneView2
        guard pane.frame.width < pane.contentFitWidth else { return }
        guard splitView.isVertical else { return }
        let available = splitView.axisAvailable()
        // The divider position that gives the pane exactly its content width:
        // pane 0's width IS the position; pane 1's width is the remainder.
        let target = index == 0
            ? pane.contentFitWidth
            : available - pane.contentFitWidth
        splitView.animateDividerPosition(to: min(max(0, target), available))
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
        guard isSyncArmed, !isSynchronizingScroll else { return }
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

    /// On the first layout, arm scroll sync and align the second pane to the
    /// first — the first pane is the scroll source of truth on entry, so the
    /// comparison opens in lock-step from the first pane's position (§9). Until
    /// this runs, `isSyncArmed` is off and the second pane's own initial layout
    /// can't drag the first pane. After it, the panes track each other on the
    /// user's scrolls.
    override func layout() {
        super.layout()
        guard !isSyncArmed else { return }
        isSyncArmed = true
        syncScroll(from: paneView1.scrollView, to: paneView2.scrollView)
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
