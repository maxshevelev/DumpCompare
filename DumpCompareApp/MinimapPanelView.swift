import Cocoa

/// The minimap panel's chrome (§19.2): a header carrying the Local/Overview
/// switch, the map below it, and a status bar that reports a full overview
/// rebuild.
///
/// The chrome is what lines the map up with the bytes it mirrors. A pane puts a
/// title bar and a column header above its dump and a status bar below it
/// (§3.4), so a bare map started higher and ended lower than the dump beside it
/// and the two never quite read as the same file. The heights are therefore not
/// constants here: the controller measures the pane's own dump area and hands
/// them over (`setChromeHeights`).
///
/// The mode switch is in the header because the choice is one a reader makes
/// constantly — a local map to read the bytes around the caret, an overview to
/// find the region to go to — and a menu item alone (§15) hides it.
final class MinimapPanelView: NSView {
    let mapView: MinimapView

    /// Local ⇄ Overview (§19.4). Internal so tests can click it.
    let modeSwitch = NSSegmentedControl(labels: ["Local", "Overview"],
                                       trackingMode: .selectOne, target: nil, action: nil)

    /// The status bar's progress bar and its caption, shown only while a rebuild
    /// is running (§19.9).
    let progressBar = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")

    /// Fired when the user picks a mode in the header.
    var onModeChange: ((MinimapView.RenderMode) -> Void)?

    private let header = NSView()
    private let statusBar = NSView()
    private var headerHeight: NSLayoutConstraint!
    private var statusBarHeight: NSLayoutConstraint!

    init(mapView: MinimapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        // Set here rather than by the owner: the chrome's own constraints are
        // activated below, and a moment spent in autoresizing mode with a zero
        // frame makes them unsatisfiable.
        translatesAutoresizingMaskIntoConstraints = false
        // A hidden panel is a zero-width pane (§19.1), not a hidden view, and
        // the chrome's side insets are breakable so that width is reachable
        // without a logged conflict. Breaking them leaves the mode switch with
        // no horizontal constraint at all, so it lays out at its intrinsic
        // width — and an `NSView` does not clip its subviews, so it would paint
        // over the file pane beside the panel (the blue switch floating in the
        // pane's top-right corner). Masking the panel's layer keeps every piece
        // of chrome inside the panel's bounds, whatever the solver does with the
        // broken insets. The header strip clips itself the same way, but in
        // `draw(_:)` — it paints its own labels rather than hosting subviews.
        wantsLayer = true
        layer?.masksToBounds = true
        modeSwitch.controlSize = .small
        modeSwitch.segmentDistribution = .fillEqually
        modeSwitch.font = .systemFont(ofSize: 10)
        modeSwitch.target = self
        modeSwitch.action = #selector(modeChanged)
        modeSwitch.selectedSegment = 0
        modeSwitch.setAccessibilityLabel("Minimap mode")
        modeSwitch.toolTip = "Whether the minimap shows the bytes around the caret or the whole file"
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        // A narrow panel must be allowed to squeeze the labels rather than push
        // the panel wider than its clamp (§19.2).
        modeSwitch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .systemFont(ofSize: 10)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.isHidden = true
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        mapView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(modeSwitch)
        statusBar.addSubview(progressLabel)
        statusBar.addSubview(progressBar)
        addSubview(header)
        addSubview(mapView)
        addSubview(statusBar)

        // Breakable, like the side insets: the split view sizes this panel by
        // frame — including a degenerate frame during a toggle — and a chrome
        // that insisted on its height would be reported as unsatisfiable each
        // time. At any real height the constraints hold exactly.
        headerHeight = breakable(header.heightAnchor.constraint(
            equalToConstant: Self.defaultHeaderHeight))
        statusBarHeight = breakable(statusBar.heightAnchor.constraint(
            equalToConstant: Self.defaultStatusBarHeight))
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,
            // The switch sits in the header's top band, level with the panes'
            // file names, rather than in the middle of a header that is as tall
            // as a title bar plus a column header.
            modeSwitch.centerYAnchor.constraint(equalTo: header.topAnchor,
                                                constant: Self.switchBandHeight / 2),
            // Breakable: a hidden panel is zero points wide (§19.1), which no
            // side inset can survive, and a conflict logged on every toggle is
            // noise that hides real ones.
            breakable(modeSwitch.leadingAnchor.constraint(equalTo: header.leadingAnchor,
                                                          constant: 8)),
            breakable(modeSwitch.trailingAnchor.constraint(equalTo: header.trailingAnchor,
                                                           constant: -8)),

            mapView.topAnchor.constraint(equalTo: header.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBarHeight,
            breakable(progressLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor,
                                                             constant: 8)),
            progressLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            breakable(progressBar.leadingAnchor.constraint(equalTo: progressLabel.trailingAnchor,
                                                            constant: 6)),
            // The bar has no intrinsic width, so it takes what the caption
            // leaves: without the trailing pin it lays out at zero.
            breakable(progressBar.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor,
                                                            constant: -8)),
            progressBar.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    /// Lets a constraint yield instead of being reported as unsatisfiable.
    private func breakable(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = .defaultHigh
        return constraint
    }

    /// The band the mode switch is centred in — a pane's title bar, so the
    /// switch lines up with the file names beside it.
    static let switchBandHeight = FilePaneView.headerHeight

    /// Used until the panes report their own geometry: a title bar plus a
    /// column header of a default row.
    static let defaultHeaderHeight = FilePaneView.headerHeight + 21
    static let defaultStatusBarHeight = FilePaneView.statusBarHeight

    /// The map never gives up more than this to the chrome.
    static let minimumMapHeight: CGFloat = 60

    /// Where the dump this map mirrors currently sits, in window coordinates.
    /// Supplied by the controller, which owns the panes, and asked on every
    /// layout pass — so the chrome follows the bytes without the controller
    /// having to notice each separate thing that moves them.
    var dumpAreaInWindow: (() -> NSRect?)?

    override func layout() {
        alignChromeToDump()
        super.layout()
    }

    /// Derives the chrome heights from the dump's own rectangle: the map's top
    /// and bottom edges then land on the dump's, whatever the pane put above
    /// them (§19.2).
    private func alignChromeToDump() {
        guard window != nil, let dump = dumpAreaInWindow?() else { return }
        let panel = convert(bounds, to: nil)
        guard panel.height > 0, dump.height > 0 else { return }
        setChromeHeights(top: panel.maxY - dump.maxY, bottom: dump.minY - panel.minY)
    }

    /// Matches the chrome to the panes', so the map starts and ends exactly
    /// where the dump does. The header never shrinks below the band the switch
    /// lives in.
    func setChromeHeights(top: CGFloat, bottom: CGFloat) {
        var top = max(Self.switchBandHeight, top)
        var bottom = max(0, bottom)
        // The map comes first: a Search All panel (§11) can take most of the
        // pane's height, and matching it exactly would leave no map at all.
        let available = bounds.height
        if available > 0, top + bottom > available - Self.minimumMapHeight {
            let spare = max(0, available - Self.minimumMapHeight - top)
            bottom = min(bottom, spare)
            top = min(top, max(Self.switchBandHeight, available - Self.minimumMapHeight))
        }
        guard abs(headerHeight.constant - top) > 0.5
            || abs(statusBarHeight.constant - bottom) > 0.5 else { return }
        headerHeight.constant = top
        statusBarHeight.constant = bottom
    }

    /// Reflects the mode the map is actually in, without reporting a change back.
    func showMode(_ mode: MinimapView.RenderMode) {
        let segment = mode == .overview ? 1 : 0
        guard modeSwitch.selectedSegment != segment else { return }
        modeSwitch.selectedSegment = segment
    }

    /// Greys out the Overview half of the switch for a file the overview could
    /// only magnify (§19.4): the choice is not offered where it would say less
    /// than the map already shows, rather than offered and then disappointing.
    func setOverviewAvailable(_ available: Bool) {
        guard modeSwitch.isEnabled(forSegment: 1) != available else { return }
        modeSwitch.setEnabled(available, forSegment: 1)
    }

    /// Shows a rebuild's progress, or hides the status bar's contents when there
    /// is nothing running. `fraction` is nil while idle.
    func setRebuildProgress(_ fraction: Double?) {
        guard let fraction else {
            progressBar.isHidden = true
            progressLabel.isHidden = true
            return
        }
        progressLabel.stringValue = "Building"
        progressBar.doubleValue = min(1, max(0, fraction))
        progressBar.isHidden = false
        progressLabel.isHidden = false
    }

    @objc private func modeChanged() {
        onModeChange?(modeSwitch.selectedSegment == 1 ? .overview : .detail)
    }
}
