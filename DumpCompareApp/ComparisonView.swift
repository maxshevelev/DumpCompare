import Cocoa
import DumpCompareCore

/// The comparison-mode content view (§3.3, §9): two `FilePaneView`s inside a
/// draggable `NSSplitView`, with:
/// - a left/right ⇄ top/bottom toggle (View menu) persisted in `UserDefaults`;
/// - synchronized scrolling by absolute offset (same row layout ⇒ same y);
/// - the comparison coordinator's progress and diff counts mirrored into the
///   panes' status bars.
final class ComparisonView: NSView {
    let coordinator: ComparisonCoordinator
    let paneView1: FilePaneView
    let paneView2: FilePaneView

    /// Fired when the user clicks a pane so MainViewController can re-point the
    /// active pane (§3.3).
    var onPaneActivated: ((Int) -> Void)?

    private let splitView = NSSplitView()
    private var scrollObservers: [NSObjectProtocol] = []
    private var isSynchronizingScroll = false

    private static let layoutKey = "ComparisonPaneLayoutIsVertical"
    private static let splitAutosaveName = "ComparisonSplit"

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
        splitView.autosaveName = Self.splitAutosaveName
        addSubview(splitView)

        // Let the splitter distribute evenly on first layout.
        paneView1.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paneView1.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        paneView2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paneView2.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        splitView.addArrangedSubview(paneView1)
        splitView.addArrangedSubview(paneView2)

        paneView1.onActivate = { [weak self] in self?.onPaneActivated?(0) }
        paneView2.onActivate = { [weak self] in self?.onPaneActivated?(1) }

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

    /// Highlights `index` as the active pane.
    func setActive(_ index: Int) {
        paneView1.setActive(index == 0)
        paneView2.setActive(index == 1)
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
        coordinator.onProgress = { [weak self] _ in
            self?.refreshComparisonInfo()
        }
        coordinator.onIndexChanged = { [weak self] _ in
            self?.refreshComparisonInfo()
        }
    }

    func refreshComparisonInfo() {
        let text: String
        if coordinator.isBuilding {
            text = "Indexing… \(Int(coordinator.progress * 100))%"
        } else if let index = coordinator.index {
            var diffBytes: UInt64 = 0
            var sameBytes: UInt64 = 0
            for block in index.blocks {
                if block.kind == .different { diffBytes += block.count } else { sameBytes += block.count }
            }
            text = "\(diffBytes) differing · \(sameBytes) same"
        } else {
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
