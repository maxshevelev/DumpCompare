import Cocoa
import DumpCompareCore

/// Whether each diff-navigation action currently has a block to go to (§10.3).
/// A false value means the command is disabled — wrong mode, index still
/// building, or the block doesn't exist in that direction from the caret.
struct DiffNavigationState: Equatable {
    var previousDifference = false
    var nextDifference = false
    var previousSameBlock = false
    var nextSameBlock = false
}

final class MainViewController: NSViewController {
    private(set) var mode: WindowMode = .empty
    /// Whether a toolbar sync is already queued for the next run-loop turn.
    private var diffToolbarSyncScheduled = false

    /// Current diff-navigation availability. Recomputed on every mode, index,
    /// and caret change; the menu items read it via `validateMenuItem` (§10.3).
    private(set) var diffNavigationState = DiffNavigationState()
    let windowModel = WindowViewModel()
    private weak var activeFilePane: FilePaneView?
    private weak var comparisonView: ComparisonView?

    /// The non-modal Find bar shown at the top on Cmd+F (§11). It lives above
    /// the content area and pushes it down while visible; when hidden the
    /// content fills the window again.
    private let findBar = FindBarView()
    /// Host for the mode content (`setContentView` swaps what's inside).
    private let contentContainer = NSView()
    /// The left pane of the minimap split — the mode's content lives here, so
    /// the minimap panel can share the content area to its right (§19).
    private let contentHost = NSView()
    /// The right-hand minimap panel (hidden by default, toggled by the toolbar
    /// button). Internal so tests can assert its visibility (§19).
    let minimapView = MinimapView()

    /// The map plus its chrome — the header's mode switch and the status bar's
    /// rebuild progress (§19.2).
    private(set) lazy var minimapPanel = MinimapPanelView(mapView: minimapView)
    /// The vertical split sharing the content area between the panes and the
    /// minimap. Internal so tests can toggle it and drive the divider (§19).
    let minimapSplit = MinimapSplitView()
    private var contentTopToView: NSLayoutConstraint!
    private var contentTopToFindBar: NSLayoutConstraint!
    private var findTask: Task<Void, Never>?
    /// The active search operation, surfaced in the active pane's status bar
    /// while a search runs (§14.4).
    private var findOperation: BackgroundOperation?
    /// The in-flight segment write (Save All / Save Segment, §21.5), surfaced in
    /// the active pane's status bar while it runs, like a search (§14.4).
    private var segmentWriteTask: Task<Void, Never>?
    private var segmentWriteOperation: BackgroundOperation?

    // MARK: - Segment save seams (§21.5)

    /// Where the Save All directory panel goes, so a test can drive it instead:
    /// a modal panel has no one to click it under XCTest. Called with the panel
    /// (already configured for directory mode); returns the chosen directory or
    /// nil when the user cancelled.
    var segmentDirectoryPanel: ((NSOpenPanel) -> URL?)?
    /// Where the Save Segment panel goes; the same shape, for one file.
    var segmentSavePanel: ((NSSavePanel) -> URL?)?
    /// Where the Replace Segment from File… open panel goes; the same shape as
    /// the save panel, for one file (§21.6).
    var segmentOpenPanel: ((NSOpenPanel) -> URL?)?
    /// Where the join's open panel goes (Append File… / Insert File at Start…,
    /// §22); the same shape as the replace panel, for one file.
    var joinOpenPanel: ((NSOpenPanel) -> URL?)?
    /// Where the join's dirty-pane confirmation goes: the test captures the
    /// alert (its title and its two buttons — the operation's verb and Cancel)
    /// and decides. Returns the alert's response (§22.2).
    var joinConfirm: ((NSAlert) -> NSApplication.ModalResponse)?
    /// Where the Save All confirmation goes: the test captures the alert (its
    /// preview names every part, and it names every file that would be replaced)
    /// and decides. Returns the alert's response.
    var segmentWriteConfirm: ((NSAlert) -> NSApplication.ModalResponse)?
    /// How the write runs. In production it is a background Task with a
    /// `BackgroundOperation` (status-bar progress and cancel, §14.4); a test
    /// replaces it with an inline run so it can assert on the written bytes
    /// without waiting on a task.
    var segmentWriteRunner: (([SegmentWriter.Part], any ByteStorage, URL) -> Void)?
    /// Monotonic token identifying the current Search All. Each new search
    /// bumps it; a running search compares its captured token against the live
    /// one before touching the results panel, so a superseded search can never
    /// clobber the results of a newer one (§11).
    private var searchAllGeneration = 0
    /// The pane the in-flight Search All targets — the owner of the panel whose
    /// × must stop that search. Nil once the Search All task ends, so closing a
    /// stale panel (an already-completed search, or the other pane's) never
    /// cancels an unrelated search (§11).
    private weak var searchAllPane: FilePaneView?
    /// Reacts to the Layout settings tab changing the default direction: an open
    /// comparison re-lays out live, like the Word Size/Appearance settings (§6).
    private var layoutSettingsObserver: NSObjectProtocol?
    private var comparisonSettingsObserver: NSObjectProtocol?

    /// Builds the background block index for comparison mode. The provider
    /// returns the current storages on every start/rebuild, so a revert that
    /// swaps a document's storage is always re-read.
    private lazy var comparisonCoordinator: ComparisonCoordinator = {
        ComparisonCoordinator { [weak self] in
            guard let self, self.mode == .comparison else { return nil }
            guard let left = self.windowModel.pane1.byteStorage,
                  let right = self.windowModel.pane2.byteStorage else { return nil }
            return (left, right)
        }
    }()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireExternalChangeDetection()
        // A bookmark changed: the panes have already repainted their row, and
        // what is left for the window is the edit popover, which must not
        // outlive the mark it is editing (§20.3), the open form's list, which has
        // to show what the store holds (§20.5), and the minimap's margins, where
        // the same list is marked (§19.4.3).
        windowModel.onBookmarksChanged = { [weak self] row in
            self?.dismissEditPopoverIfItsMarkIsGone(row: row)
            self?.openGoToForm?.reloadBookmarks()
            self?.syncMinimapBookmarks()
        }
        // Apply the Layout settings tab's direction change to an open comparison
        // immediately; outside comparison mode the value is stored and the next
        // comparison opens with it (§6).
        layoutSettingsObserver = NotificationCenter.default.addObserver(
            forName: LayoutSettings.layoutDirectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.mode == .comparison else { return }
            self.comparisonView?.setLayout(vertical: LayoutSettings.isVertical)
            // The pane arrangement changed (View menu or the Settings tab), so
            // the minimap's internal split flips with it (§19).
            self.updateMinimapLayout()
        }
        // The Comparison settings tab's grouping distance decides what counts as
        // one change for diff navigation (§10.3.1). Applied live: the coordinator
        // re-groups the blocks it already has, without rescanning the files.
        comparisonSettingsObserver = NotificationCenter.default.addObserver(
            forName: ComparisonSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer runs on the main queue, but the closure is not
            // statically main-actor isolated.
            MainActor.assumeIsolated {
                self?.comparisonCoordinator.groupingGap = ComparisonSettings.groupingGap
            }
        }
        // Re-evaluate navigation availability on every index-state transition
        // (build starts/completes/cancels/stops, edits applied) (§10.3). The
        // minimap is not in this path: it reads difference state per byte from
        // the panes, the same live comparison they paint with, so the background
        // index never feeds it (§19).
        comparisonCoordinator.onStateChanged = { [weak self] in
            self?.refreshDiffNavigation()
            // Detail reads difference state per byte from the panes, but the
            // overview takes it from this index — one query per block beats
            // re-reading both files (§19.4).
            self?.overviewFollowIndexChange()
        }

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true  // shown by Cmd+F (§11)
        findBar.onSearch = { [weak self] pattern, direction, caseSensitive in
            self?.runSearch(pattern: pattern, direction: direction, caseSensitive: caseSensitive)
        }
        findBar.onSearchAll = { [weak self] pattern, caseSensitive in
            self?.runSearchAll(pattern: pattern, caseSensitive: caseSensitive)
        }
        findBar.onError = { [weak self] message in
            self?.showFindMessage(message)
        }
        findBar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        view.addSubview(findBar)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        contentTopToView = contentContainer.topAnchor.constraint(equalTo: view.topAnchor)
        contentTopToFindBar = contentContainer.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: view.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentTopToView,
        ])

        // The minimap split fills the content container: the mode content on
        // the left, the minimap panel on the right. The panel starts collapsed
        // (the minimap is hidden on launch); the toolbar button toggles it (§
        // N). The delegate owns the divider's min/max clamping and persists the
        // panel width whenever the divider moves.
        minimapSplit.translatesAutoresizingMaskIntoConstraints = false
        minimapSplit.isVertical = true
        minimapSplit.dividerStyle = .thin
        minimapSplit.delegate = self
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        minimapPanel.translatesAutoresizingMaskIntoConstraints = false
        minimapSplit.addArrangedSubview(contentHost)
        // The panel, not the bare map: its header carries the mode switch and
        // its status bar the rebuild's progress, and together they align the map
        // with the dump beside it (§19.2).
        minimapSplit.addArrangedSubview(minimapPanel)
        contentContainer.addSubview(minimapSplit)
        NSLayoutConstraint.activate([
            minimapSplit.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            minimapSplit.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            minimapSplit.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            minimapSplit.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        // The map is virtualized: it pulls the bytes of its visible window as it
        // draws, and a drag or a wheel over it scrolls the panes (§19).
        minimapView.byteStates = { [weak self] mapIndex, range in
            self?.minimapByteStates(mapIndex: mapIndex, range: range) ?? []
        }
        minimapView.onScrollToOffset = { [weak self] offset in
            self?.scrollPanesToOffset(offset)
        }
        minimapView.onSelectOffset = { [weak self] mapIndex, offset in
            self?.selectMinimapOffset(mapIndex: mapIndex, offset: offset)
        }
        // The segment strip's legend answers (§19.4.4, §21.3): the piece's
        // current name (asked for at hover time, since the store fires no
        // invalidation for a rename), and the right-click menu that acts on the
        // piece under the pointer — the same menu the form's row offers.
        minimapView.segmentPieceName = { [weak self] mapIndex, pieceIndex in
            self?.minimapSegmentName(mapIndex: mapIndex, pieceIndex: pieceIndex) ?? ""
        }
        minimapView.segmentStripMenu = { [weak self] mapIndex, pieceIndex, point in
            self?.makeMinimapSegmentMenu(mapIndex: mapIndex, pieceIndex: pieceIndex, point: point)
        }
        // The overview bins the file into one row per pixel, so a resize changes
        // the bins and the summary has to be recomputed (§19.4).
        minimapView.onOverviewRowCountChanged = { [weak self] in
            self?.scheduleOverviewRebuild()
        }
        // A panel tall enough to magnify the open file takes the Overview choice
        // away, and gives it back when it shrinks again (§19.4).
        minimapView.onOverviewUsefulnessChanged = { [weak self] in
            self?.updateOverviewAvailability()
        }
        minimapPanel.onModeChange = { [weak self] mode in
            self?.setMinimapRenderMode(mode)
        }
        // The panel aligns its own chrome with the dump, and asks where the dump
        // is on every layout pass (§19.2).
        minimapPanel.dumpAreaInWindow = { [weak self] in
            guard let self else { return nil }
            let panes: [FilePaneView]
            if let comparison = self.comparisonView {
                panes = [comparison.paneView1, comparison.paneView2]
            } else if let pane = self.activeFilePane {
                panes = [pane]
            } else {
                panes = []
            }
            let areas = panes.compactMap(\.dumpAreaInWindow)
            guard let first = areas.first else { return nil }
            // The maps span every dump: stacked panes (§3.3) put one above the
            // other, and the panel's two maps cover both, so the span the chrome
            // has to match is their union — not the first pane's dump, which
            // ends halfway down the window.
            return areas.dropFirst().reduce(first) { $0.union($1) }
        }
        // Showing the panel needs the current picture: while hidden it drew
        // nothing, so its maps and viewport are stale (§19).
        minimapSplit.onPanelVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            if visible {
                self.updateMinimapLayout()
                self.refreshMinimapMaps()
                // The mode was decided when the file opened, panel or no panel
                // (§19.4) — showing the panel must not undo a choice made in it,
                // only settle whether overview is on offer now that it has a height.
                self.updateOverviewAvailability()
                self.updateMinimapViewports()
                self.rebuildOverview()
            }
            // The window grows or shrinks by the panel's width so the hex
            // content area keeps its width (§19). The resize is instant; the
            // panel's own divider animation then settles the content.
            self.resizeWindowForMinimap(visible: visible)
        }

        apply(mode: .empty)
    }

    /// Swaps the content area for the given window mode (§3 of REQUIREMENTS.md).
    func apply(mode: WindowMode) {
        self.mode = mode
        syncDiffNavigationToolbarItem()
        unwireComparison()
        // The strip beside each map mirrors the pane's partition (§19.4.4): a
        // cut, a removal, a moved cut, or a content edit that shifts one all
        // repaint it. The pane fires this on every partition change, so it is
        // set here — once per mode apply, on both panes — rather than where the
        // form happens to be open. It reloads the form when it is open and syncs
        // the strip whether or not it is.
        windowModel.pane1.onSegmentsChanged = { [weak self] in
            self?.openSegmentsForm?.reloadSegments()
            self?.syncMinimapSegments()
        }
        windowModel.pane2.onSegmentsChanged = { [weak self] in
            self?.openSegmentsForm?.reloadSegments()
            self?.syncMinimapSegments()
        }
        // The panes are about to be rebuilt, so an in-flight Search All would
        // stream into an orphaned view (and its × would be gone). Stop it here:
        // `hideFindBar` deliberately leaves a Search All running (§11).
        if searchAllPane != nil {
            findTask?.cancel()
            findOperation?.finish()
            searchAllPane = nil
        }
        // Panes are rebuilt on every apply, so the viewport mirrors must start
        // empty and fill in as the new panes report their visible ranges (§19).
        minimapViewports.removeAll()
        minimapView.setViewports([])

        switch mode {
        case .empty:
            activeFilePane = nil
            comparisonView = nil
            comparisonCoordinator.stop()
            // Returning to the launch state must also dismiss the find bar —
            // nothing is left to search (§11).
            hideFindBar()
            let emptyView = EmptyStateView()
            emptyView.onOpenFiles = { [weak self] urls in
                self?.handleEmptyDrop(urls)
            }
            setContentView(emptyView)

        case .singleFile:
            let paneModel = windowModel.pane1
            let pane = FilePaneView(viewModel: paneModel)
            // Header right-click menu: acts on THIS pane (§4/§5).
            pane.paneMenu = makePaneMenu(for: paneModel)
            // Offset-column right-click menu ("Select Block from Here at «address»", §10.2).
            pane.offsetMenuProvider = { [weak self] offset in
                self?.makeOffsetMenu(for: paneModel, offset: offset) ?? NSMenu()
            }
            wireBookmarkDoubleClick(pane, for: paneModel)
            // Close button: closing the last file returns to empty mode (§3.5).
            pane.onClose = { [weak self] in self?.closePane(at: 0) }
            // Closing the Search All panel stops the in-flight search (§11).
            pane.onSearchResultsClose = { [weak self] pane in
                self?.cancelSearchAll(from: pane)
            }
            // The minimap's single map mirrors this pane: edits rebuild its
            // cells, a moved caret moves the selection overlay, and scrolling
            // moves the viewport rectangle (§19).
            trackMinimapViewport(for: pane)
            paneModel.onEdit = { [weak self] edit in
                self?.repaintMinimap(after: edit, mapIndex: 0)
            }
            paneModel.onFullInvalidation = { [weak self] in
                self?.minimapView.invalidateCells()
                self?.refreshMinimapMaps()
            }
            // A save moves the on-disk reference, so the map's red cells have to
            // clear even though no byte changed (§19).
            paneModel.onSavedStateChanged = { [weak self] in
                self?.minimapView.invalidateCells()
                self?.refreshMinimapMaps()
            }
            paneModel.onCaretChanged = { [weak self] in
                self?.updateMinimapSelections()
            }
            // Wrap in the drop-target split view (§4.3 single-file mode). The
            // pane itself is NOT drop-registered here so the outer view wins.
            let dropView = SingleFileDropView(paneView: pane)
            dropView.onDrop = { [weak self] target, urls in
                self?.handleSingleFileDrop(target: target, urls: urls)
            }
            activeFilePane = pane
            comparisonView = nil
            comparisonCoordinator.stop()
            setContentView(dropView)
            pane.focusHexView()

        case .comparison:
            wireComparison()
            let pane1 = windowModel.pane1
            let pane2 = windowModel.pane2
            let pane1View = FilePaneView(viewModel: pane1)
            let pane2View = FilePaneView(viewModel: pane2)
            // Header right-click menus act on their own pane (§4/§5).
            pane1View.paneMenu = makePaneMenu(for: pane1)
            pane2View.paneMenu = makePaneMenu(for: pane2)
            // Offset-column right-click menus ("Select Block from Here at «address»", §10.2).
            pane1View.offsetMenuProvider = { [weak self] offset in
                self?.makeOffsetMenu(for: pane1, offset: offset) ?? NSMenu()
            }
            pane2View.offsetMenuProvider = { [weak self] offset in
                self?.makeOffsetMenu(for: pane2, offset: offset) ?? NSMenu()
            }
            // A double click on an address marks that row, in whichever pane
            // was clicked (§20.3).
            wireBookmarkDoubleClick(pane1View, for: pane1)
            wireBookmarkDoubleClick(pane2View, for: pane2)
            // Each map's viewport rectangle mirrors its pane's visible slice (§19).
            trackMinimapViewport(for: pane1View)
            trackMinimapViewport(for: pane2View)
            let view = ComparisonView(
                coordinator: comparisonCoordinator,
                paneView1: pane1View,
                paneView2: pane2View
            )
            view.onPaneActivated = { [weak self] index in
                self?.activatePane(at: index)
            }
            // Comparison-mode drops target the hovered pane's bands (§22.4):
            // the three bands (insert / replace / append) are the drop targets,
            // so the panes themselves are not drop-registered.
            view.bands1.onDrop = { [weak self] target, urls in
                self?.handleComparisonBandDrop(targetPane: 0, target: target, urls: urls)
            }
            view.bands2.onDrop = { [weak self] target, urls in
                self?.handleComparisonBandDrop(targetPane: 1, target: target, urls: urls)
            }
            pane1View.onClose = { [weak self] in self?.closePane(at: 0) }
            pane2View.onClose = { [weak self] in self?.closePane(at: 1) }
            // Closing a pane's Search All panel stops that search (§11).
            pane1View.onSearchResultsClose = { [weak self] pane in
                self?.cancelSearchAll(from: pane)
            }
            pane2View.onSearchResultsClose = { [weak self] pane in
                self?.cancelSearchAll(from: pane)
            }

            activeFilePane = windowModel.activePaneIndex == 0 ? pane1View : pane2View
            comparisonView = view
            setContentView(view)
            view.setActive(windowModel.activePaneIndex)
            // The minimap's stacked divider mirrors the panes' divider position,
            // so keep it glued whenever the panes' divider moves (§19).
            view.splitView.onFractionChanged = { [weak self] in
                self?.updateMinimapLayout()
            }
            comparisonCoordinator.start()
            activeFilePane?.focusHexView()
        }
        updateMinimapLayout()
        refreshMinimapMaps()
        // A different file can call for a different mode — a dump too large for
        // the detail window opens in overview (§19.4).
        applyPreferredMinimapMode()
        refreshDiffNavigation()
    }

    /// Wires companion panes and coordinator callbacks for comparison mode.
    /// Runs on every comparison apply — pane objects are swapped by Swap Panels
    /// and close-promotion, so the callbacks must target the CURRENT panes.
    private func wireComparison() {
        windowModel.pane1.companion = windowModel.pane2
        windowModel.pane2.companion = windowModel.pane1
        windowModel.pane1.onEdit = { [weak self] edit in
            self?.comparisonCoordinator.record(edit: edit)
            self?.repaintMinimap(after: edit, mapIndex: 0)
        }
        windowModel.pane2.onEdit = { [weak self] edit in
            self?.comparisonCoordinator.record(edit: edit)
            self?.repaintMinimap(after: edit, mapIndex: 1)
        }
        windowModel.pane1.onFullInvalidation = { [weak self] in
            self?.comparisonCoordinator.rebuild()
            self?.minimapView.invalidateCells()
            self?.refreshMinimapMaps()
        }
        windowModel.pane2.onFullInvalidation = { [weak self] in
            self?.comparisonCoordinator.rebuild()
            self?.minimapView.invalidateCells()
            self?.refreshMinimapMaps()
        }
        // A save clears modified state without changing a byte, so the minimap's
        // red cells have to go even though the bytes stayed put (§19).
        windowModel.pane1.onSavedStateChanged = { [weak self] in
            self?.minimapView.invalidateCells()
            self?.refreshMinimapMaps()
        }
        windowModel.pane2.onSavedStateChanged = { [weak self] in
            self?.minimapView.invalidateCells()
            self?.refreshMinimapMaps()
        }
        // A moved caret changes whether a next/previous block still exists from
        // the new position, so navigation enablement follows it (§10.3); the
        // selection overlay on the minimap follows the caret too (§19).
        windowModel.pane1.onCaretChanged = { [weak self] in
            self?.refreshDiffNavigation()
            self?.updateMinimapSelections()
        }
        windowModel.pane2.onCaretChanged = { [weak self] in
            self?.refreshDiffNavigation()
            self?.updateMinimapSelections()
        }
    }

    private func unwireComparison() {
        windowModel.pane1.companion = nil
        windowModel.pane2.companion = nil
        windowModel.pane1.onEdit = nil
        windowModel.pane2.onEdit = nil
        windowModel.pane1.onFullInvalidation = nil
        windowModel.pane2.onFullInvalidation = nil
        windowModel.pane1.onSavedStateChanged = nil
        windowModel.pane2.onSavedStateChanged = nil
    }

    private func setContentView(_ newView: NSView) {
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        newView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            newView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            newView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
    }

    // MARK: - Minimap (§19)

    /// Toggles the right-hand minimap panel (the toolbar button). The panel is
    /// hidden by default and animated in/out; the split's divider keeps the
    /// user's chosen width between shows.
    @objc func toggleMinimap() {
        minimapSplit.togglePanel(animated: true)
    }

    /// Grows or shrinks the window by the minimap panel's width so the hex
    /// content area keeps its width when the panel is shown or hidden (§19).
    /// The window grows or shrinks from the right edge; the left edge stays put.
    private func resizeWindowForMinimap(visible: Bool) {
        guard let window = view.window else { return }
        let delta = minimapSplit.preferredPanelWidth + minimapSplit.dividerThickness
        var frame = window.frame
        frame.size.width = visible ? frame.size.width + delta : max(0, frame.size.width - delta)
        // Keep the window on the visible screen: when growing, the right edge
        // must not run off-screen; when shrinking, the left edge stays put.
        if let visibleFrame = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX),
                                 visibleFrame.maxX - frame.size.width)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    /// Recomputes the minimap's internal map split from the current window mode
    /// and pane arrangement (§19): one map in single-file mode, two maps with a
    /// centered vertical line for side-by-side panes, two maps with a
    /// horizontal line mirroring the panes' divider for stacked panes.
    private func updateMinimapLayout() {
        switch mode {
        case .empty, .singleFile:
            minimapView.setMapLayout(.single)
        case .comparison:
            guard let split = comparisonView?.splitView else { return }
            if split.isVertical {
                minimapView.setMapLayout(.sideBySide)
            } else {
                minimapView.setMapLayout(.stacked(fraction: split.currentFraction))
            }
        }
    }

    /// Makes pane `index` the active one: the window model, the active-pane
    /// pointer, the comparison view's chrome, and the focus all follow (§3.3).
    /// Driven by a header click and by a click on that pane's minimap.
    private func activatePane(at index: Int) {
        guard let comparisonView else { return }
        windowModel.setActivePane(index)
        activeFilePane = index == 0 ? comparisonView.paneView1 : comparisonView.paneView2
        comparisonView.setActive(index)
        // Focus follows activation (e.g. a header click), so typing and the
        // active-pane pointer stay aligned (§3.3).
        activeFilePane?.focusHexView()
        // Navigation anchors on the active pane's caret — a pane switch can
        // change whether a next/previous block exists (§10.3).
        refreshDiffNavigation()
    }

    // MARK: - Minimap overview (§19.4)

    /// The debounce waiting to start a pass, and the pass itself. Separate
    /// handles because they are cancelled for different reasons: a request that
    /// arrives while a pass runs must not kill it (see `scheduleOverviewRebuild`).
    private var overviewDebounceTask: Task<Void, Never>?
    private var overviewPassTask: Task<Void, Never>?
    /// The row count the running pass is binning for — a diagnostic seam for the
    /// tests, and what a future decision about a pass's usefulness would read.
    private(set) var overviewPassRowCount = 0
    /// Edited ranges whose difference marks are still waiting for the comparison
    /// index to absorb them (§19.9).
    private var overviewRowsAwaitingIndex: [Range<UInt64>] = []
    /// The index build this controller's overview was derived from.
    private var overviewIndexBuildCount = 0
    /// How many full overview passes and how many row patches have run — the
    /// seam for "an edit does not walk the file" (§19.9).
    private(set) var overviewRebuilds = 0
    private(set) var overviewPatches = 0
    /// Full passes that finished and published their picture.
    private(set) var overviewRebuildsCompleted = 0

    /// One pane's inputs for an overview summary, snapshotted on the main thread
    /// before the background pass reads anything. Internal so a test can drive
    /// the row engine directly.
    struct OverviewSource: Sendable {
        let storage: (any ByteStorage)?
        let saved: (any ByteStorage)?
        let size: UInt64
        /// Where the edit overlay has written — the only offsets a modified byte
        /// can sit at.
        let edited: [Range<UInt64>]
        let isUntitled: Bool
        /// The comparison index, kept whole rather than flattened into a list of
        /// differing ranges: the rows being computed ask it for the blocks in
        /// their own window (§8). Flattening it here walked every block in the
        /// index on every keystroke — a third of the main thread on a 16 MB
        /// comparison, and the sticking that came with it. Nil in single-file
        /// mode and before the first index lands.
        let differences: DiffBlockIndex?
    }

    /// The mode the file(s) now open call for: detail for a file small enough
    /// that it is the more informative view, overview for a dump detail could
    /// only ever show a sliver of (§19.4). Nothing is remembered — every open
    /// decides afresh, because the answer is a property of the file, not a
    /// preference; a toggle by the user holds only until the open files change.
    private func preferredMinimapMode() -> MinimapView.RenderMode {
        let size = [windowModel.pane1, windowModel.pane2]
            .compactMap { $0.isOpen ? $0.status.fileSize : nil }
            .max() ?? 0
        return size <= MinimapView.detailPreferredMaxSize ? .detail : .overview
    }

    /// Puts the minimap in the mode the current file calls for. Called whenever
    /// the open files change.
    private func applyPreferredMinimapMode() {
        setMinimapRenderMode(preferredMinimapMode())
        updateOverviewAvailability()
    }

    /// Keeps the Overview control in step with what the overview could say about
    /// the open file, and leaves the mode if it has nothing left to say — the
    /// panel is never parked in a view its own switch refuses to offer (§19.4).
    private func updateOverviewAvailability() {
        let available = minimapView.overviewIsInformative()
        minimapPanel.setOverviewAvailable(available)
        if !available, minimapView.renderMode == .overview {
            setMinimapRenderMode(.detail)
        }
    }

    /// Switches the minimap's mode and reflects it in the header switch.
    private func setMinimapRenderMode(_ mode: MinimapView.RenderMode) {
        // The switch reflects the map's state whatever changed it — the menu
        // item (§15), a file that calls for overview, or the switch itself.
        minimapPanel.showMode(mode)
        guard minimapView.renderMode != mode else { return }
        minimapView.setRenderMode(mode)
        if mode == .overview {
            scheduleOverviewRebuild()
        } else {
            cancelOverviewWork()
            reportOverviewProgress(nil)
        }
    }

    /// Runs a full overview pass now, so a test can compare a patched picture
    /// against the one a full pass builds.
    func rebuildOverviewForTesting() {
        rebuildOverview()
    }

    /// Puts the minimap in `mode`, the way the header switch does. Exposed
    /// (internal) so tests can exercise a mode directly.
    func setMinimapRenderModeForTesting(_ mode: MinimapView.RenderMode) {
        setMinimapRenderMode(mode)
    }

    /// Toggles between the whole-file overview and the detail window. The choice
    /// holds until the open files change, which decides afresh (§19.4).
    @objc func toggleMinimapOverview() {
        guard minimapView.renderMode == .overview || minimapView.overviewIsInformative() else { return }
        setMinimapRenderMode(minimapView.renderMode == .overview ? .detail : .overview)
    }

    /// Recomputes the overview after a change that alters what it shows. Every
    /// row of an overview is on screen at once, so unlike the detail window it
    /// cannot be pulled per repaint — it is computed in the background and
    /// debounced, so a burst of edits costs one pass (§19.4).
    /// The pass waits for the edits to stop: each request restarts the delay, so
    /// a burst of keystrokes — auto-repeat is thirty a second — costs one pass
    /// after it, not one per keystroke. A pass over two 16 MB dumps reads both
    /// files whole; doing that thirty times a second starves the main thread of
    /// the very cache it draws from, which is felt as the typing sticking.
    ///
    /// Waiting is only acceptable because the map does not go silent while it
    /// waits: a shifting edit marks its tail immediately and for free
    /// (`markShiftedTailModified`), and the picture in hand is stretched rather
    /// than dropped. What the pass adds is exactness.
    ///
    /// A pass in flight is cancelled: something changed under it, so whatever it
    /// is halfway through computing is already the wrong picture, and finishing
    /// it costs the reads that make the typing stick. The request that cancelled
    /// it starts the wait again.
    private func scheduleOverviewRebuild() {
        guard minimapSplit.panelVisible, minimapView.renderMode == .overview else { return }
        overviewPassTask?.cancel()
        overviewPassTask = nil
        reportOverviewProgress(nil)
        overviewDebounceTask?.cancel()
        overviewDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.overviewDebounceTask = nil
            self?.rebuildOverview()
        }
    }

    /// Cancels whatever the overview has in flight — a waiting debounce and a
    /// running pass — and forgets any queued request.
    private func cancelOverviewWork() {
        overviewDebounceTask?.cancel()
        overviewDebounceTask = nil
        overviewPassTask?.cancel()
        overviewPassTask = nil
    }

    private func rebuildOverview() {
        guard minimapSplit.panelVisible, minimapView.renderMode == .overview else { return }
        let rowCount = minimapView.overviewRowCount()
        let sources = overviewSources()
        let extent = sources.map(\.size).max() ?? 0
        guard rowCount > 0, extent > 0, !sources.isEmpty else {
            minimapView.setOverviewSummaries([])
            return
        }
        overviewPassTask?.cancel()
        overviewPassRowCount = rowCount
        overviewRebuilds += 1
        beginOverviewProgress()
        let progress = OverviewProgressSink(total: rowCount * sources.count) { [weak self] fraction in
            self?.reportOverviewProgress(fraction)
        }
        // Deliberately below the interface's priority: the picture is worth
        // waiting a little longer for, and nothing about it is worth competing
        // with the keystroke being typed. The two files are independent passes
        // and run together, which halves the wait on a comparison.
        overviewPassTask = Task.detached(priority: .utility) { [weak self] in
            let summaries = await withTaskGroup(
                of: (Int, MinimapView.OverviewSummary).self
            ) { group -> [MinimapView.OverviewSummary] in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        (index, Self.overviewSummary(source: source, extent: extent,
                                                     rowCount: rowCount,
                                                     shouldCancel: { Task.isCancelled },
                                                     rowsDone: { progress.advance($0) }))
                    }
                }
                var built: [(Int, MinimapView.OverviewSummary)] = []
                for await pair in group { built.append(pair) }
                return built.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reportOverviewProgress(nil)
                self.overviewPassTask = nil
                guard !Task.isCancelled, self.minimapView.renderMode == .overview else { return }
                self.minimapView.setOverviewSummaries(summaries)
                self.overviewRebuildsCompleted += 1
            }
        }
    }

    /// Adds up what the concurrent passes have finished and reports it to the
    /// panel's status bar, in twentieths: a progress bar told about every one of
    /// a thousand rows would cost more than the pass it measures.
    private final class OverviewProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int
        private var done = 0
        private var reportedStep = -1
        // The callback is always invoked on the main actor — `advance` hops there
        // before firing it — so it is declared main-actor isolated; otherwise a
        // caller updating the panel from it would warn.
        private let onChange: @Sendable @MainActor (Double) -> Void

        init(total: Int, onChange: @escaping @Sendable @MainActor (Double) -> Void) {
            self.total = max(1, total)
            self.onChange = onChange
        }

        func advance(_ rows: Int) {
            lock.lock()
            done += rows
            let fraction = min(1, Double(done) / Double(total))
            let step = Int(fraction * 20)
            let changed = step != reportedStep
            if changed { reportedStep = step }
            lock.unlock()
            guard changed else { return }
            Task { @MainActor in onChange(fraction) }
        }
    }

    /// How long a rebuild has to run before its progress is worth showing. A
    /// small dump is binned in a few milliseconds, and a bar that appeared for
    /// one frame would read as a glitch rather than as progress.
    /// Injectable so a test can pin the policy instead of racing a real pass.
    static var overviewProgressDelay: Duration = .milliseconds(80)

    /// Once the bar is up it stays up this long, even if the pass finishes
    /// first. Binning two 16 MB dumps takes ~150 ms, so hiding the bar the
    /// instant the pass ended made it flash for a few frames — visible as a
    /// flicker, unreadable as progress.
    static var overviewProgressMinimumVisible: Duration = .milliseconds(300)

    /// The rebuild's latest progress, or nil when nothing is running.
    private var overviewProgress: Double?
    private var overviewProgressReveal: Task<Void, Never>?
    private var overviewProgressHide: Task<Void, Never>?
    private var overviewProgressShown: ContinuousClock.Instant?

    /// Starts watching a rebuild: the bar appears only if the pass is still
    /// going when the delay is up.
    private func beginOverviewProgress() {
        overviewProgress = 0
        overviewProgressHide?.cancel()
        overviewProgressHide = nil
        overviewProgressReveal?.cancel()
        overviewProgressReveal = Task { [weak self] in
            try? await Task.sleep(for: Self.overviewProgressDelay)
            guard !Task.isCancelled, let self, let fraction = self.overviewProgress else { return }
            self.overviewProgressShown = .now
            self.minimapPanel.setRebuildProgress(fraction)
        }
    }

    /// Moves the bar, or clears the status bar when the rebuild is over (nil).
    private func reportOverviewProgress(_ fraction: Double?) {
        overviewProgress = fraction
        guard let fraction else {
            overviewProgressReveal?.cancel()
            overviewProgressReveal = nil
            hideOverviewProgress()
            return
        }
        // Only move a bar that is already up; whether it appears at all is the
        // reveal task's decision.
        guard !minimapPanel.progressBar.isHidden else { return }
        minimapPanel.setRebuildProgress(fraction)
    }

    /// Takes the bar down, holding it for the rest of its minimum showing.
    private func hideOverviewProgress() {
        guard let shown = overviewProgressShown else {
            minimapPanel.setRebuildProgress(nil)
            return
        }
        let remaining = Self.overviewProgressMinimumVisible - shown.duration(to: .now)
        guard remaining > .zero else {
            overviewProgressShown = nil
            minimapPanel.setRebuildProgress(nil)
            return
        }
        // Finish the bar off at 100 % while it waits out its minimum.
        minimapPanel.setRebuildProgress(1)
        overviewProgressHide?.cancel()
        overviewProgressHide = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled, let self else { return }
            self.overviewProgressShown = nil
            self.overviewProgressHide = nil
            self.minimapPanel.setRebuildProgress(nil)
        }
    }

    /// Re-aligns the panel's chrome with the dump (§19.2). The panel measures the
    /// dump itself on every layout pass; this is for the changes that move the
    /// bytes without touching the panel's own frame — a new pane layout, an
    /// opened Find bar (§11), a taller row (§6).
    private func updateMinimapChrome() {
        minimapPanel.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateMinimapChrome()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The toolbar can only be reconfigured once it is up, which is not the
        // case while the window controller is still building (§10.3).
        syncDiffNavigationToolbarItem()
    }

    private func overviewSource(_ pane: PaneViewModel) -> OverviewSource {
        OverviewSource(storage: pane.byteStorage, saved: pane.savedStorage, size: pane.fileSize,
                       edited: pane.editedRanges, isUntitled: pane.isUntitled,
                       differences: comparisonCoordinator.index)
    }

    /// How many of `buffer[from..<to]` are neither 0x00 nor 0xFF — how "full"
    /// a cell's slice of the file is.
    ///
    /// The pass walks the whole file — every byte of a 16 MB dump, twice over for
    /// a comparison — so it counts eight bytes at a time instead of one, over a
    /// raw buffer. Through `Array`'s bounds-checked subscript, one byte at a
    /// time, this took 1.9 s per file in a debug build: the overview arrived
    /// seconds after it was asked for.
    nonisolated static func significantByteCount(
        _ buffer: UnsafeBufferPointer<UInt8>, from: Int, to: Int
    ) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        let word = 8
        var index = from
        var count = 0
        while index + word <= to {
            let bits = UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self)
            count += word - fillByteFlags(bits).nonzeroBitCount
            index += word
        }
        while index < to {
            if base[index] != 0x00, base[index] != 0xFF { count += 1 }
            index += 1
        }
        return count
    }

    /// One bit per byte of `word` that is a 0x00/0xFF fill — the byte's high bit,
    /// so `nonzeroBitCount` is the number of fill bytes in the word.
    ///
    /// `(b & 0x7F) + 0x7F` sets a byte's high bit exactly when `b` has any low bit
    /// set, and cannot carry into the next byte (0x7F + 0x7F = 0xFE); OR-ing `b`
    /// back in contributes its own high bit. So the high bit of each byte of that
    /// expression is set iff the byte is non-zero — inverted, iff it is 0x00. The
    /// same test on `~word` finds the 0xFF bytes, and no byte can be both.
    nonisolated private static func fillByteFlags(_ word: UInt64) -> UInt64 {
        let low: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        let high: UInt64 = 0x8080_8080_8080_8080
        let zeros = ~(((word & low) &+ low) | word) & high
        let inverted = ~word
        let ones = ~(((inverted & low) &+ low) | inverted) & high
        return zeros | ones
    }

    /// Bins one file into `rowCount` rows of 16 cells: how full each cell's slice
    /// of bytes is, and which cells hold a modified or differing byte.
    ///
    /// Rows are binned over `extent` — the longest open file — so the same row
    /// means the same absolute offset on both maps (§9); rows past this file's
    /// own end stay empty. One read per row keeps the pass sequential and bounded
    /// by the file's size.
    nonisolated private static func overviewSummary(
        source: OverviewSource, extent: UInt64, rowCount: Int,
        shouldCancel: () -> Bool,
        rowsDone: (Int) -> Void = { _ in }
    ) -> MinimapView.OverviewSummary {
        let columns = Int(MinimapView.bytesPerRow)
        let rows = max(0, rowCount)
        let empty = MinimapView.OverviewSummary(
            extent: extent, rowCount: rowCount,
            density: [UInt8](repeating: 0, count: rows * columns),
            modified: [UInt16](repeating: 0, count: rows),
            different: [UInt16](repeating: 0, count: rows)
        )
        guard rowCount > 0, extent > 0,
              let all = overviewRows(source: source, extent: extent, rowCount: rowCount,
                                     rows: 0...(rowCount - 1),
                                     shouldCancel: shouldCancel, rowsDone: rowsDone)
        else { return empty }
        return MinimapView.OverviewSummary(extent: extent, rowCount: rowCount,
                                          density: all.density, modified: all.modified,
                                          different: all.different)
    }

    /// The overview's values for `rows` alone: the density of their cells and
    /// their modified/difference bits. A whole picture is this over every row; a
    /// byte edit is this over the one or two rows it lands in, which is why the
    /// engine takes a row range rather than always walking the file (§19.9).
    ///
    /// Returns nil when cancelled or when `rows` is not inside the picture.
    nonisolated static func overviewRows(
        source: OverviewSource, extent: UInt64, rowCount: Int, rows: ClosedRange<Int>,
        shouldCancel: () -> Bool = { false },
        rowsDone: (Int) -> Void = { _ in }
    ) -> (density: [UInt8], modified: [UInt16], different: [UInt16])? {
        let columns = Int(MinimapView.bytesPerRow)
        guard rowCount > 0, extent > 0, rows.lowerBound >= 0, rows.upperBound < rowCount else {
            return nil
        }
        var density = [UInt8](repeating: 0, count: rows.count * columns)
        var modified = [UInt16](repeating: 0, count: rows.count)
        var different = [UInt16](repeating: 0, count: rows.count)
        guard let storage = source.storage else { return (density, modified, different) }

        /// The first byte of a row's slice of the file.
        func start(ofRow row: Int) -> UInt64 { extent * UInt64(row) / UInt64(rowCount) }

        /// The cells one byte of a row's slice occupies, when the slice is
        /// thinner than the row's 16 cells: the byte is stretched over the cells
        /// it covers, so `index` 0 of a one-byte slice fills the row.
        ///
        /// A row covers fewer bytes than it has cells whenever the file is
        /// smaller than 16 bytes per pixel row — under ~25 KB on a full-height
        /// panel — and covers a *fraction* of a byte once the file is smaller
        /// than the panel has rows. Slicing per cell there gave every cell but
        /// the last an empty byte range: the picture came out a pale field with
        /// the whole file collapsed into a stripe down its right edge (§19.4.2).
        func stretchedColumns(forByteAt index: UInt64, ofSpan span: UInt64) -> ClosedRange<Int> {
            let effective = max(span, 1)
            let clamped = min(index, effective - 1)
            let first = Int(clamped * UInt64(columns) / effective)
            let last = Int((clamped + 1) * UInt64(columns) / effective) - 1
            return first...max(first, min(columns - 1, last))
        }

        /// The row a byte offset falls in, and the cells it occupies there.
        func cells(of offset: UInt64) -> (row: Int, columns: ClosedRange<Int>)? {
            guard offset < extent else { return nil }
            let row = Int(offset * UInt64(rowCount) / extent)
            guard rows.contains(row) else { return nil }
            let rowStart = start(ofRow: row)
            let span = start(ofRow: row + 1) - rowStart
            guard span >= UInt64(columns) else {
                let index = offset > rowStart ? offset - rowStart : 0
                return (row, stretchedColumns(forByteAt: index, ofSpan: span))
            }
            let column = Int(min(UInt64(columns - 1), (offset - rowStart) * UInt64(columns) / span))
            return (row, column...column)
        }

        // The byte range these rows cover, so the passes below read and scan
        // only what belongs to them.
        let windowStart = start(ofRow: rows.lowerBound)
        let windowEnd = start(ofRow: rows.upperBound + 1)

        // Density: one read per row, counting the bytes that are not a fill.
        // Progress is reported in blocks of rows, which is granular enough for a
        // bar and rare enough not to matter to the pass.
        var reportedRow = rows.lowerBound
        for row in rows {
            if shouldCancel() { return nil }
            if row - reportedRow >= 64 {
                rowsDone(row - reportedRow)
                reportedRow = row
            }
            let rowStart = start(ofRow: row)
            let rowEnd = start(ofRow: row + 1)
            let span = rowEnd - rowStart
            // A row whose slice is thinner than a byte still stands for the byte
            // its position falls in — read that one, rather than leaving the row
            // blank as it used to be.
            let readEnd = min(max(rowEnd, rowStart + 1), source.size)
            guard rowStart < readEnd else { continue }
            guard let bytes = try? storage.read(at: rowStart, length: Int(readEnd - rowStart)),
                  !bytes.isEmpty else { continue }
            let base = (row - rows.lowerBound) * columns
            bytes.withUnsafeBufferPointer { buffer in
                guard span >= UInt64(columns) else {
                    // Fewer bytes than cells: each byte fills the cells it
                    // covers, so the row reads as a coarse picture of those
                    // bytes instead of one inked cell at its right edge.
                    let count = min(buffer.count, Int(max(span, 1)))
                    for index in 0..<count {
                        guard significantByteCount(buffer, from: index, to: index + 1) > 0 else { continue }
                        for column in stretchedColumns(forByteAt: UInt64(index), ofSpan: span) {
                            density[base + column] = 255
                        }
                    }
                    return
                }
                for column in 0..<columns {
                    let sliceStart = rowStart + span * UInt64(column) / UInt64(columns)
                    let sliceEnd = rowStart + span * UInt64(column + 1) / UInt64(columns)
                    let from = Int(sliceStart - rowStart)
                    let to = Int(min(sliceEnd, readEnd) - rowStart)
                    guard from < to, to <= buffer.count else { continue }
                    let significant = significantByteCount(buffer, from: from, to: to)
                    guard significant > 0 else { continue }
                    density[base + column] =
                        UInt8(min(255, max(1, significant * 255 / (to - from))))
                }
            }
        }

        rowsDone(rows.upperBound + 1 - reportedRow)

        // Modified: where the byte differs from the saved copy — the same rule
        // the panes paint by — inside the rows an edit can have reached.
        //
        // Row by row, cell by cell, comparing whole slices rather than bytes: an
        // insert or a delete shifts every byte after it, so `source.edited`
        // covers the file's whole tail and a per-byte loop over it took seconds.
        // Bytes outside the edited ranges cannot differ from the saved copy, so
        // comparing a cell whole is safe: the untouched part of it compares
        // equal and contributes nothing.
        if !source.isUntitled, !source.edited.isEmpty {
            let savedSize = source.saved?.size ?? 0
            for row in rows {
                if shouldCancel() { return nil }
                let rowStart = start(ofRow: row)
                let rowEnd = start(ofRow: row + 1)
                let span = rowEnd - rowStart
                let readEnd = min(max(rowEnd, rowStart + 1), source.size)
                guard rowStart < readEnd else { continue }
                // Rows no edit can have reached are skipped, so a clean file
                // costs nothing here and a small edit costs one row.
                guard source.edited.contains(where: {
                    $0.lowerBound < readEnd && $0.upperBound > rowStart
                }) else { continue }
                guard let bytes = try? storage.read(at: rowStart, length: Int(readEnd - rowStart)),
                      !bytes.isEmpty else { continue }
                let savedBytes = source.saved
                    .flatMap { try? $0.read(at: rowStart, length: Int(readEnd - rowStart)) } ?? []
                let index = row - rows.lowerBound

                guard span >= UInt64(columns) else {
                    // Fewer bytes than cells: compare the handful of bytes and
                    // stretch each one over the cells it covers.
                    for offsetInRow in 0..<bytes.count {
                        let absolute = rowStart + UInt64(offsetInRow)
                        let changed = absolute >= savedSize
                            || (savedBytes.indices.contains(offsetInRow)
                                ? savedBytes[offsetInRow] != bytes[offsetInRow] : true)
                        guard changed else { continue }
                        for column in stretchedColumns(forByteAt: UInt64(offsetInRow), ofSpan: span) {
                            modified[index] |= UInt16(1) << UInt16(column)
                        }
                    }
                    continue
                }

                for column in 0..<columns {
                    let sliceStart = rowStart + span * UInt64(column) / UInt64(columns)
                    let sliceEnd = rowStart + span * UInt64(column + 1) / UInt64(columns)
                    let from = Int(sliceStart - rowStart)
                    let to = Int(min(sliceEnd, readEnd) - rowStart)
                    guard from < to, to <= bytes.count else { continue }
                    // Bytes past the saved file's end are new by definition.
                    if sliceStart + UInt64(to - from) > savedSize {
                        modified[index] |= UInt16(1) << UInt16(column)
                        continue
                    }
                    guard savedBytes.count >= to else {
                        modified[index] |= UInt16(1) << UInt16(column)
                        continue
                    }
                    let differs = bytes.withUnsafeBufferPointer { current in
                        savedBytes.withUnsafeBufferPointer { saved in
                            memcmp(current.baseAddress! + from, saved.baseAddress! + from, to - from) != 0
                        }
                    }
                    if differs { modified[index] |= UInt16(1) << UInt16(column) }
                }
            }
        }

        // Differences: the index's differing blocks that touch these rows, found
        // by binary search rather than by flattening the index. A block spanning
        // whole rows marks every column of them.
        for block in source.differences?.blocks(in: windowStart..<windowEnd) ?? []
        where block.kind == .different {
            if shouldCancel() { return nil }
            let range = block.range
            let lower = max(range.lowerBound, windowStart)
            let upper = min(range.upperBound, min(windowEnd, extent))
            guard lower < upper, let first = cells(of: lower), let last = cells(of: upper - 1)
            else { continue }
            if first.row == last.row {
                let from = min(first.columns.lowerBound, last.columns.lowerBound)
                let to = max(first.columns.upperBound, last.columns.upperBound)
                for column in from...to {
                    different[first.row - rows.lowerBound] |= UInt16(1) << UInt16(column)
                }
                continue
            }
            for column in first.columns.lowerBound..<columns {
                different[first.row - rows.lowerBound] |= UInt16(1) << UInt16(column)
            }
            if last.row > first.row + 1 {
                for row in (first.row + 1)..<last.row { different[row - rows.lowerBound] = .max }
            }
            for column in 0...last.columns.upperBound {
                different[last.row - rows.lowerBound] |= UInt16(1) << UInt16(column)
            }
        }

        // A cell past this file's own end holds none of its bytes, so it can
        // neither differ nor be modified — whatever the comparison index says.
        // The index is built over the *union* of the two files (§9), so every
        // byte past the shorter file's end counts as a difference there; drawn
        // as such it painted the shorter map's empty tail solid. The tail is
        // empty, exactly as it is in detail mode.
        for row in rows {
            let slot = row - rows.lowerBound
            guard modified[slot] != 0 || different[slot] != 0 else { continue }
            var covered: UInt16 = 0
            let rowStart = start(ofRow: row)
            let span = start(ofRow: row + 1) - rowStart
            for column in 0..<columns
            where rowStart + span * UInt64(column) / UInt64(columns) < source.size {
                covered |= UInt16(1) << UInt16(column)
            }
            modified[slot] &= covered
            different[slot] &= covered
        }

        return (density, modified, different)
    }

    // MARK: - Minimap data (§19)

    /// Feeds the minimap the per-byte state of the rows it is showing.
    ///
    /// The map is virtualized: it asks for the byte range of its visible window
    /// on each repaint and stores nothing, so this reads a couple of thousand
    /// bytes however large the file is. It is also the very call the panes make
    /// to paint their own rows, which is what keeps the map's colours — modified,
    /// difference — identical to theirs instead of a background approximation
    /// that lags behind them.
    private func minimapByteStates(mapIndex: Int, range: Range<UInt64>) -> [HexByteState] {
        let pane: PaneViewModel?
        switch mode {
        case .singleFile:
            pane = mapIndex == 0 ? windowModel.pane1 : nil
        case .comparison:
            pane = mapIndex == 0 ? windowModel.pane1 : (mapIndex == 1 ? windowModel.pane2 : nil)
        case .empty:
            pane = nil
        }
        return pane?.hexByteStates(in: range) ?? []
    }

    /// Hands the minimap the window's bookmarks (§19.4.3). The store is the one
    /// list both maps mark, so this is a straight copy — which rows a given map
    /// actually shows is the minimap's own geometry to decide, and the names come
    /// along because hovering a mark names it.
    private func syncMinimapBookmarks() {
        minimapView.setBookmarks(windowModel.bookmarkStore.bookmarks)
    }

    /// Hands the minimap the open panes' segment partitions, so the strip beside
    /// each map paints the dump's pieces (§19.4.4). The tint is by *position* —
    /// the piece's index into the partition — the same rule the dump's row tint
    /// uses, so the strip and the dump are one legend. A pane with a single piece
    /// hands its lone block; the minimap draws no strip for it, and the strip
    /// appears the moment a cut makes a second piece.
    private func syncMinimapSegments() {
        let panes: [PaneViewModel?]
        switch mode {
        case .empty:
            panes = []
        case .singleFile:
            panes = [windowModel.pane1]
        case .comparison:
            panes = [windowModel.pane1, windowModel.pane2]
        }
        let blocks: [[MinimapView.SegmentBlock]] = panes.map { pane in
            guard let pane, pane.isOpen else { return [] }
            return pane.segmentStore.segments.map {
                MinimapView.SegmentBlock(range: $0.range,
                                         colorIndex: $0.index % HexTheme.segmentTints.count)
            }
        }
        minimapView.setSegmentBlocks(blocks)
    }

    /// Hands the minimap the open files' sizes. That is all it needs to lay its
    /// maps out — everything it draws it pulls per repaint.
    private func refreshMinimapMaps() {
        minimapView.setMaps(currentFileSizes().map { MinimapView.Map(fileSize: $0) })
        updateMinimapSelections()
        // The maps were just rebuilt, so the marks have to be handed over again
        // — and a file that grew or shrank changes which of them are drawn (§9).
        syncMinimapBookmarks()
        // A content edit moves the cuts with the bytes (§21.2), so the strip's
        // partition follows — and a file that opened or closed changes which
        // panes have a partition at all.
        syncMinimapSegments()
        // An insert or a delete can carry the file across the line where the
        // overview stops magnifying it, so the offer follows the size as well as
        // the panel's height (§19.4). The *mode* is deliberately not re-decided
        // here: this runs on every edit, and the choice belongs where the open
        // files change.
        updateOverviewAvailability()
        // The bytes moved, so an overview summary of them is stale.
        scheduleOverviewRebuild()
    }

    /// The bytes under the maps changed. An overwrite names a bounded range, so
    /// both modes update in place and at once: detail repaints the rows that draw
    /// it (its cells are pulled from the panes as it draws), and overview
    /// recomputes those rows of its picture instead of walking the file again —
    /// a typed byte moves one row of a thousand (§19.9).
    ///
    /// Both maps, because a byte edited in one file changes the difference state
    /// the other one paints at that same offset (§9).
    /// `mapIndex` is the map of the pane the edit happened in — the maps mirror
    /// the panes (§19). Only that map's rows can have moved: a shift in one file
    /// says nothing about the other, which is what painting both of them red
    /// wrongly claimed.
    private func repaintMinimap(after edit: DiffEdit, mapIndex: Int) {
        switch edit {
        case .overwrite(let range):
            // Typing past EOF grows the file, which re-bins the overview: that is
            // a new picture, not a patch.
            guard minimapView.maps.map(\.fileSize) == currentFileSizes() else {
                minimapView.invalidateCells()
                refreshMinimapMaps()
                return
            }
            minimapView.invalidateBytes(in: range)
            patchOverviewRows(covering: range)
            // The difference marks come from the comparison index, which absorbs
            // the edit in the background: these rows are patched again when it
            // does, instead of the whole picture being rebuilt (§19.9).
            if mode == .comparison { overviewRowsAwaitingIndex.append(range) }
        case .insert, .delete:
            // Every byte after the change moved, so no range describes it: the
            // exact picture is a full pass, and that pass waits for the typing to
            // settle. Until it lands the map keeps the picture it has — a byte
            // or two out of date, which at a row per 13 KB is invisible.
            //
            // Marking the shifted tail red in the meantime was tried and is
            // wrong: from an edit near the start of a file that paints the whole
            // map red, which is not "the old picture, slightly stale" but a new
            // and much worse one.
            minimapView.invalidateCells()
            refreshMinimapMaps()
        }
    }

    /// Recomputes the overview rows that `range` falls in, on every map, and
    /// leaves the rest of the picture untouched. Falls back to a full rebuild
    /// when the picture on screen was binned differently from what these rows
    /// would be (a resize or a new file landed in between).
    private func patchOverviewRows(covering range: Range<UInt64>) {
        guard minimapSplit.panelVisible, minimapView.renderMode == .overview else { return }
        let summaries = minimapView.overviewSummaries
        let sources = overviewSources()
        guard !summaries.isEmpty, summaries.count == sources.count,
              let extent = summaries.first?.extent, extent > 0,
              let rowCount = summaries.first?.rowCount, rowCount > 0,
              summaries.allSatisfy({ $0.extent == extent && $0.rowCount == rowCount }),
              rowCount == minimapView.overviewRowCount(),
              extent == sources.map(\.size).max() ?? 0 else {
            scheduleOverviewRebuild()
            return
        }
        let last = min(range.upperBound &- 1, extent - 1)
        guard range.lowerBound <= last else { return }
        let firstRow = Int(range.lowerBound * UInt64(rowCount) / extent)
        let lastRow = min(rowCount - 1, Int(last * UInt64(rowCount) / extent))
        guard firstRow <= lastRow else { return }
        let rows = firstRow...lastRow
        for (index, source) in sources.enumerated() {
            guard let patch = Self.overviewRows(source: source, extent: extent,
                                                rowCount: rowCount, rows: rows) else { continue }
            minimapView.updateOverviewRows(rows, density: patch.density, modified: patch.modified,
                                           different: patch.different, forMapAt: index)
        }
        overviewPatches += 1
    }

    /// The open files' sizes, in map order.
    private func currentFileSizes() -> [UInt64] {
        switch mode {
        case .singleFile: return [windowModel.pane1.fileSize]
        case .comparison: return [windowModel.pane1.fileSize, windowModel.pane2.fileSize]
        case .empty: return []
        }
    }

    /// One snapshot per map, in map order.
    private func overviewSources() -> [OverviewSource] {
        switch mode {
        case .singleFile: return [overviewSource(windowModel.pane1)]
        case .comparison: return [overviewSource(windowModel.pane1), overviewSource(windowModel.pane2)]
        case .empty: return []
        }
    }

    /// The comparison index changed. When what changed is the edits this
    /// controller recorded, the overview patches their rows; anything else — a
    /// fresh index, a build starting, a cancel — means the derived picture is
    /// stale as a whole and is rebuilt (§19.9).
    private func overviewFollowIndexChange() {
        guard minimapSplit.panelVisible, minimapView.renderMode == .overview else {
            overviewRowsAwaitingIndex.removeAll()
            return
        }
        let build = comparisonCoordinator.indexBuildCount
        guard build == overviewIndexBuildCount else {
            overviewIndexBuildCount = build
            overviewRowsAwaitingIndex.removeAll()
            scheduleOverviewRebuild()
            return
        }
        guard !overviewRowsAwaitingIndex.isEmpty else {
            scheduleOverviewRebuild()
            return
        }
        let ranges = overviewRowsAwaitingIndex
        overviewRowsAwaitingIndex.removeAll()
        for range in ranges { patchOverviewRows(covering: range) }
    }

    /// Moves the caret to the byte clicked on a map and centres the pane on it.
    /// In comparison mode the click also makes that pane active, so the caret it
    /// just moved is the one the keyboard and the navigation commands act on.
    private func selectMinimapOffset(mapIndex: Int, offset: UInt64) {
        let pane: PaneViewModel
        switch mode {
        case .empty:
            return
        case .singleFile:
            guard mapIndex == 0 else { return }
            pane = windowModel.pane1
        case .comparison:
            guard mapIndex == 0 || mapIndex == 1 else { return }
            if mapIndex != windowModel.activePaneIndex { activatePane(at: mapIndex) }
            pane = mapIndex == 0 ? windowModel.pane1 : windowModel.pane2
        }
        guard pane.isOpen else { return }
        pane.moveCaret(to: offset)
        filePaneView(for: pane)?.revealOffsetCentered(offset)
    }

    // MARK: - The segment strip's legend (§19.4.4, §21.3)

    /// The pane a minimap map stands for, by map index — the strip's menu and
    /// hover both act through it. Nil in empty mode or for an index the mode
    /// does not use.
    private func minimapPane(at mapIndex: Int) -> PaneViewModel? {
        switch mode {
        case .empty:
            return nil
        case .singleFile:
            return mapIndex == 0 ? windowModel.pane1 : nil
        case .comparison:
            return mapIndex == 0 ? windowModel.pane1 : (mapIndex == 1 ? windowModel.pane2 : nil)
        }
    }

    /// The current name of the piece the strip's hover text names — asked for at
    /// hover time, not stored, because the store fires no invalidation for a
    /// rename (§21.3).
    private func minimapSegmentName(mapIndex: Int, pieceIndex: Int) -> String {
        guard let pane = minimapPane(at: mapIndex), pane.isOpen,
              pieceIndex < pane.segmentStore.segments.count else { return "" }
        return pane.segmentStore.segments[pieceIndex].name
    }

    /// The piece a strip-menu item acts on, carried in the item's
    /// `representedObject` — the way the offset menu carries its target.
    /// Internal so a test can verify the piece an item carries.
    final class SegmentMenuTarget: NSObject {
        let mapIndex: Int
        let pieceIndex: Int
        /// The pointer's own spot on the strip when the menu was opened, in the
        /// minimap's coordinates — the anchor the Edit popover points at, so it
        /// opens where the menu did rather than at the piece's whole block
        /// (§21.4).
        let point: NSPoint
        init(mapIndex: Int, pieceIndex: Int, point: NSPoint) {
            self.mapIndex = mapIndex
            self.pieceIndex = pieceIndex
            self.point = point
        }
    }

    /// The right-click menu the segment strip offers for a piece: what acts on
    /// the piece under the pointer (§21.3) — the form's row menu with the strip's
    /// own Select. Each item carries the piece it acts on in its
    /// `representedObject`, the way the offset menu carries its target.
    private func makeMinimapSegmentMenu(mapIndex: Int, pieceIndex: Int, point: NSPoint) -> NSMenu? {
        guard let pane = minimapPane(at: mapIndex), pane.isOpen,
              pieceIndex < pane.segmentStore.segments.count else { return nil }
        let target = SegmentMenuTarget(mapIndex: mapIndex, pieceIndex: pieceIndex, point: point)
        // The piece's label names it in every item, so the menu says what it will
        // act on — "Select Segment S1", not a bare "Select Segment" (§21.3).
        let label = pane.segmentStore.segments[pieceIndex].label
        let menu = NSMenu()

        // Save Segment… writes one piece to a file (§21.5).
        let save = menu.addItem(withTitle: "Save Segment \(label)…",
                                action: #selector(minimapMenuSaveSegment(_:)), keyEquivalent: "")
        save.target = self
        save.representedObject = target

        // Replace Segment from File… reads one piece from a file (§21.6): the
        // donor-region swap, the inverse of Save Segment.
        let replace = menu.addItem(withTitle: "Replace Segment \(label) from File…",
                                   action: #selector(minimapMenuReplaceSegment(_:)), keyEquivalent: "")
        replace.target = self
        replace.representedObject = target

        menu.addItem(.separator())

        // Select Segment: the whole piece is selected — its full range, not a
        // caret at its start (§21.3).
        let select = menu.addItem(withTitle: "Select Segment \(label)",
                                  action: #selector(minimapMenuSelectSegment(_:)), keyEquivalent: "")
        select.target = self
        select.representedObject = target

        // Edit Segment: the popover that edits this piece — its offset and its
        // name — anchored where the menu opened, not the form with the table of
        // all segments (§21.4).
        let edit = menu.addItem(withTitle: "Edit Segment \(label)",
                                action: #selector(minimapMenuEditSegment(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = target

        // Merge: the piece's bytes merge into a neighbour that keeps its name
        // (§21.3) — the same act as the form's row menu. The title names both
        // the piece and the neighbour it merges into, so the menu says what it
        // will do without a second look.
        let remove = menu.addItem(withTitle: Segment.mergeTitle(for: pieceIndex),
                                  action: #selector(minimapMenuRemoveSegment(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = target
        return menu
    }

    /// Save Segment… from the strip's menu: the piece under the click, written to
    /// a file (§21.5) — the same act as the form's row menu.
    @objc private func minimapMenuSaveSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = minimapPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        savePiece(pane.segmentStore.segments[target.pieceIndex], of: pane)
    }

    /// Replace Segment from File… from the strip's menu (§21.6): the piece under
    /// the click, its bytes replaced from a file — the same act as the form's row
    /// menu.
    @objc private func minimapMenuReplaceSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = minimapPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        replacePiece(pane.segmentStore.segments[target.pieceIndex], of: pane)
    }

    /// Select Segment from the strip's menu: the whole piece is selected — its
    /// full range, not a caret at its start (§21.3). The reveal puts the
    /// selection's start in view so the selection is seen to begin.
    @objc private func minimapMenuSelectSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = minimapPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        let piece = pane.segmentStore.segments[target.pieceIndex]
        pane.select(range: piece.range)
        filePaneView(for: pane)?.revealOffsetCentered(piece.range.lowerBound)
    }

    /// Edit… from the strip's menu: the popover that edits this piece — its
    /// offset (movable within the interval the cut bounds, locked to 0 for S0)
    /// and its name — anchored to the piece's own block on the strip (§21.4).
    /// Not the form with the table of all segments.
    @objc private func minimapMenuEditSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = minimapPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        let index = target.pieceIndex
        let segment = pane.segmentStore.segments[index]
        let store = pane.segmentStore
        let validate: (UInt64) -> Bool
        if index == 0 {
            // S0 has no cut to move: the offset is the file start, locked to 0,
            // so the editor renames the piece and nothing else.
            validate = { $0 == 0 }
        } else {
            // The cut at the piece's start bounds (the previous cut, the next cut
            // or the file's end); moving inside it keeps the partition whole
            // (§21.2). The current offset is legal, so the field opens not red.
            let lower = store.segments[index - 1].range.lowerBound
            let upper = index + 1 < store.segments.count
                ? store.segments[index + 1].range.lowerBound
                : store.contentSize
            validate = { offset in offset > lower && offset < upper }
        }
        let from = segment.range.lowerBound
        // The piece's label and range, above the two fields — "S1: 0001000-0600000"
        // — so the popover says what it is for before the offset is read (§21.4).
        let header = "\(segment.label): \(segment.range.lowerBound.bareAddress)-\(segment.range.lastByte.bareAddress)"
        let controller = CutEditPopoverController(
            prefillOffset: from, validate: validate,
            // The piece's current name, so editing a named piece opens with the
            // name to be changed rather than blank (§21.4).
            prefillDescription: segment.name,
            header: header,
            onCommit: { [weak pane] offset, name in
                guard let pane else { return }
                // Moving the cut and renaming the piece are one act: the piece
                // that opened at `from` is the one the description names, and its
                // name travels with the boundary (§21.2).
                if offset != from {
                    pane.segmentStore.moveCut(from: from, to: offset)
                }
                pane.segmentStore.rename(index, to: name)
            },
            onCancel: nil
        )
        // Anchor the popover at the pointer's own spot on the strip, so it opens
        // where the menu was opened — not at the piece's whole block (§21.4).
        // The point was captured when the menu was built and stored in the
        // target, so it is still here when the action fires.
        let anchor = NSRect(origin: target.point, size: .zero)
        controller.show(relativeTo: anchor, of: self.minimapView)
    }

    /// Merge from the strip's menu: the piece's bytes merge into a neighbour
    /// that keeps its name (§21.3) — the same act as the form's row menu, on
    /// the piece under the pointer.
    @objc private func minimapMenuRemoveSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = minimapPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        pane.segmentStore.removePiece(at: target.pieceIndex)
    }

    /// Scrolls the panes so `offset`'s hex row sits at the top of the pane —
    /// what the minimap's drag and wheel ask for. In comparison mode scrolling
    /// one pane syncs the other (§9), so driving the active pane is enough.
    private func scrollPanesToOffset(_ offset: UInt64) {
        switch mode {
        case .empty:
            break
        case .singleFile:
            activeFilePane?.scrollRowToTop(containing: offset)
        case .comparison:
            (activeFilePane ?? comparisonView?.paneView1)?.scrollRowToTop(containing: offset)
        }
    }

    /// Moves each map's selection overlay to its pane's current selection.
    /// Cheap (an overlay repaint), so it rides the caret-changed callbacks.
    private func updateMinimapSelections() {
        let selections: [Range<UInt64>?]
        switch mode {
        case .singleFile:
            selections = [minimapSelectionRange(windowModel.pane1)]
        case .comparison:
            selections = [minimapSelectionRange(windowModel.pane1),
                          minimapSelectionRange(windowModel.pane2)]
        case .empty:
            selections = []
        }
        for (index, selection) in selections.enumerated() {
            minimapView.updateSelection(selection, forMapAt: index)
        }
    }

    private func minimapSelectionRange(_ pane: PaneViewModel) -> Range<UInt64>? {
        let selection = pane.hexSelection()
        guard !selection.isEmpty else { return nil }
        return selection.start..<selection.end
    }

    /// The panes' latest visible byte ranges, keyed by pane identity, so a
    /// scroll in either pane rebuilds the minimap's viewport array without
    /// waiting for the other pane to re-report. Cleared on every apply(mode:) —
    /// panes are rebuilt and re-keyed.
    private var minimapViewports: [ObjectIdentifier: Range<UInt64>] = [:]

    /// Wires a pane's viewport scrolls into the minimap: every visible-range
    /// change moves the grey viewport band and slides the map's own window,
    /// since the window is derived from the panes (§19).
    private func trackMinimapViewport(for pane: FilePaneView) {
        pane.onHexViewportChanged = { [weak self, weak pane] range in
            guard let self, let pane else { return }
            self.minimapViewports[ObjectIdentifier(pane)] = range
            self.updateMinimapViewports()
        }
    }

    /// Moves each map's viewport band to its pane's visible byte range, which
    /// also re-derives the shared window. Cheap — no file pass — so it rides the
    /// scroll and resize notifications.
    private func updateMinimapViewports() {
        let viewports: [Range<UInt64>?]
        switch mode {
        case .singleFile:
            if let pane = activeFilePane {
                viewports = [minimapViewports[ObjectIdentifier(pane)]]
            } else {
                viewports = []
            }
        case .comparison:
            let pane1 = comparisonView?.paneView1
            let pane2 = comparisonView?.paneView2
            viewports = [pane1.flatMap { minimapViewports[ObjectIdentifier($0)] },
                         pane2.flatMap { minimapViewports[ObjectIdentifier($0)] }]
        case .empty:
            viewports = []
        }
        minimapView.setViewports(viewports)
    }

    // MARK: - Helpers

    private var activePane: PaneViewModel { windowModel.activePane }

    private func focusActiveHexView() {
        activeFilePane?.focusHexView()
    }

    private func refreshMode() {
        let mode: WindowMode = windowModel.openPaneCount == 0 ? .empty : (windowModel.openPaneCount == 1 ? .singleFile : .comparison)
        // A drop that joins into the current pane (append / insert at start)
        // does not change the mode, and the join has already refreshed the pane
        // and centred the seam (§10.4, §22.5). Re-applying the same mode would
        // rebuild the pane from scratch, and the new pane's init follows the
        // caret to the top of the viewport, undoing the centring. Skip the
        // rebuild when the mode is unchanged: the operation that triggered this
        // has already updated the pane through its own channels.
        guard mode != self.mode else { return }
        apply(mode: mode)
    }

    // MARK: - File > Open (§4.1)

    @objc func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.openFiles(panel.urls)
        }
    }

    private func openFiles(_ urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }

        // §4.1 rules 1–3, decided against the pre-open occupancy.
        let pane1WasOpen = windowModel.pane1.isOpen
        let pane2WasOpen = windowModel.pane2.isOpen
        let plan = OpenPlacement.plan(
            activePaneIndex: windowModel.activePaneIndex,
            pane1Open: pane1WasOpen,
            pane2Open: pane2WasOpen,
            fileCount: files.count
        )

        if let target = plan.firstFilePane {
            guard openIntoPane(index: target, url: first) else { return }
        }
        if plan.openSecond, files.count >= 2 {
            _ = openIntoPane(index: 1, url: files[1])
        }

        // Active pane follows the rule that decided placement.
        if !pane1WasOpen {
            windowModel.setActivePane(0)
        } else if !pane2WasOpen {
            windowModel.setActivePane(1)
        }

        if plan.ignoredCount > 0 {
            notifyIgnored(count: plan.ignoredCount)
        }
        refreshMode()
    }

    // MARK: - Drop handlers (§4.3)

    /// Empty-mode drop: first two files → panes 1/2, extras ignored (§4.3).
    private func handleEmptyDrop(_ urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: 0, url: first) else { return }
        if files.count >= 2 {
            _ = openIntoPane(index: 1, url: files[1])
        }
        windowModel.setActivePane(0)
        let ignored = max(0, files.count - 2)
        if ignored > 0 { notifyIgnored(count: ignored) }
        refreshMode()
    }

    /// Comparison-mode drop: first file → hovered pane; second file → other pane
    /// only if that pane is empty; extras (and an unplaceable second) ignored.
    private func handleComparisonDrop(targetPane: Int, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: targetPane, url: first) else { return }

        let otherIndex = 1 - targetPane
        let otherPane = otherIndex == 0 ? windowModel.pane1 : windowModel.pane2
        var ignored = max(0, files.count - 2)
        if files.count >= 2 {
            if otherPane.isOpen {
                ignored += 1  // the second file can't open — treated as ignored
            } else {
                _ = openIntoPane(index: otherIndex, url: files[1])
            }
        }
        windowModel.setActivePane(targetPane)
        if ignored > 0 { notifyIgnored(count: ignored) }
        refreshMode()
    }

    /// Comparison-mode drop onto one of a pane's three bands (§22.4): the
    /// replace band uses the existing comparison replace behaviour, and the two
    /// join bands join the first file into that pane (the rest ignored).
    /// Internal (not private) so a test can drive the routing directly.
    func handleComparisonBandDrop(targetPane: Int, target: SingleFileDropTarget, urls: [URL]) {
        switch target {
        case .replace, .addSecond:
            // The replace band (and the defensive addSecond — comparison mode
            // has no second-file target) use the existing replace behaviour.
            handleComparisonDrop(targetPane: targetPane, urls: urls)
        case .insertAtStart, .appendAtEnd:
            let files = openableFiles(from: urls)
            guard let first = files.first else { return }
            let pane = targetPane == 0 ? windowModel.pane1 : windowModel.pane2
            let position: JoinPosition = (target == .insertAtStart) ? .start : .end
            join(url: first, at: position, in: pane)
            let ignored = max(0, files.count - 1)
            if ignored > 0 { notifyJoinIgnored(count: ignored) }
            refreshMode()
        }
    }

    /// Single-file-mode drop onto one of the targets or bands (§4.3, §22.4).
    /// Internal (not private) so a test can drive the routing directly.
    func handleSingleFileDrop(target: SingleFileDropTarget, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        switch target {
        case .replace:
            // First replaces the current file; a second (if any) opens as pane 2.
            guard openIntoPane(index: 0, url: first) else { return }
            if files.count >= 2 {
                _ = openIntoPane(index: 1, url: files[1])
            }
            windowModel.setActivePane(0)
            let ignored = max(0, files.count - 2)
            if ignored > 0 { notifyIgnored(count: ignored) }
        case .addSecond:
            // First opens as pane 2; all additional files are ignored.
            guard openIntoPane(index: 1, url: first) else { return }
            windowModel.setActivePane(1)
            let ignored = max(0, files.count - 1)
            if ignored > 0 { notifyIgnored(count: ignored) }
        case .insertAtStart, .appendAtEnd:
            // First joins into the "this file" pane (pane 0 in single-file
            // mode); the rest are ignored — joining a list in one gesture is
            // deliberately not this (§22.4).
            let position: JoinPosition = (target == .insertAtStart) ? .start : .end
            join(url: first, at: position, in: windowModel.pane1)
            let ignored = max(0, files.count - 1)
            if ignored > 0 { notifyJoinIgnored(count: ignored) }
        }
        refreshMode()
    }

    private func openableFiles(from urls: [URL]) -> [URL] {
        let files = urls.filter(isOpenableFile)
        if files.count < urls.count {
            presentAlert(title: "Some files could not be opened",
                         message: "Directories and packages are not supported.")
        }
        return files
    }

    private func notifyIgnored(count: Int) {
        let noun = count == 1 ? "file was" : "files were"
        presentAlert(title: "Additional files ignored",
                     message: "\(count) \(noun) not opened because only two files can be compared at once.")
    }

    /// The join-band variant of the ignored-files notice (§22.4): a join takes
    /// one file, so the extras are not joined, not opened.
    private func notifyJoinIgnored(count: Int) {
        let noun = count == 1 ? "file was" : "files were"
        presentAlert(title: "Additional files ignored",
                     message: "\(count) \(noun) not joined because only one file can be joined at a time.")
    }

    /// Opens `url` into the pane at `index`, enforcing §4.1 rules 4–6 (dirty
    /// replacement confirmation, same-file reload, no same file in both panes).
    /// Returns false when the open was refused or failed.
    private func openIntoPane(index: Int, url: URL) -> Bool {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2
        let other = index == 0 ? windowModel.pane2 : windowModel.pane1

        // Rule 6: same file already open in the other pane.
        if other.isOpen, FileIdentity(url: url) == other.document?.identity {
            presentAlert(title: "File already open",
                         message: "“\(url.lastPathComponent)” is already open in the other pane and cannot be opened twice.")
            return false
        }

        // Rule 5: same file already open in the target pane → reload/no-op.
        if pane.isOpen, FileIdentity(url: url) == pane.document?.identity {
            if pane.status.isDirty {
                let response = confirmAlert(title: "Reload file?",
                                            message: "“\(url.lastPathComponent)” has unsaved changes. Reload and discard them?",
                                            confirmTitle: "Reload",
                                            destructive: true)
                guard response == .alertFirstButtonReturn else { return false }
            }
            do {
                try pane.revert()
                return true
            } catch {
                presentError("Could not reload file.", error)
                return false
            }
        }

        // Rule 4: replacing a dirty pane requires confirmation. A dirty
        // untitled pane has no file yet, so Save As runs first and the open
        // re-continues once it completes.
        guard confirmReplaceDirtyPane(pane, onSaved: { [weak self] in
            _ = self?.openIntoPane(index: index, url: url)
        }) else { return false }

        do {
            try pane.open(url: url)
            SandboxBookmarkStore.shared.record(url)
            return true
        } catch {
            presentFileError("Could not open file.", error, url: url)
            return false
        }
    }

    /// §4.1 rule 4: replacing a dirty pane requires confirmation. Returns true
    /// when the replacement may proceed (the pane was saved or its changes were
    /// discarded). A dirty untitled pane cannot save inline — Save As runs as a
    /// sheet and `onSaved` is called when it completes, with false returned so
    /// the pending replacement re-runs via the callback.
    private func confirmReplaceDirtyPane(_ pane: PaneViewModel, onSaved: (() -> Void)? = nil) -> Bool {
        guard pane.isOpen, pane.status.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace unsaved changes?"
        alert.informativeText = "“\(pane.status.fileName)” has unsaved changes. Save and replace, or replace without saving?"
        alert.addButton(withTitle: "Save and Replace")
        alert.addButton(withTitle: "Replace Without Saving")
        alert.addButton(withTitle: "Cancel")
        switch Self.presentModal(alert, defaultInTest: .alertThirdButtonReturn) {  // Cancel in tests
        case .alertFirstButtonReturn:  // Save and Replace
            if pane.isUntitled {
                presentSaveAs(for: pane, onSaved: onSaved)
                return false
            }
            do {
                try pane.save()
                return true
            } catch {
                presentError("Save failed.", error)
                return false
            }
        case .alertSecondButtonReturn:  // Replace Without Saving
            return true
        default:
            return false
        }
    }

    private func isOpenableFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == false && values?.isPackage != true
    }

    // MARK: - File > Append File… / Insert File at Start… (§22)

    /// File > Append File…: joins the chosen file's bytes after the active
    /// pane's content (§22.1).
    @objc func appendFile() {
        joinFile(at: .end, in: activePane)
    }

    /// File > Insert File at Start…: joins the chosen file's bytes before the
    /// active pane's content (§22.1).
    @objc func insertFileAtStart() {
        joinFile(at: .start, in: activePane)
    }

    /// The pane-menu twins: the same join, acting on the pane the menu was built
    /// for (§22.1) rather than the active one.
    @objc func appendFileInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        joinFile(at: .end, in: pane)
    }

    @objc func insertFileAtStartInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        joinFile(at: .start, in: pane)
    }

    /// The join command, shared by the File-menu and pane-menu items (§22).
    /// Opens the one file, then joins it.
    private func joinFile(at position: JoinPosition, in pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let verb = (position == .start) ? "Insert" : "Append"

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = verb
        panel.message = "Choose the file to \(position == .start ? "insert at the start of" : "append to") the pane's content."
        let url: URL?
        if let joinOpenPanel {
            url = joinOpenPanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return }
        join(url: url, at: position, in: pane)
    }

    /// Joins the file at `url` into `pane`: the dirty-pane warning (Cancel and
    /// the operation's verb — §22.2), the join, and the transient status line.
    /// Shared by the menu commands (after the open panel) and the drop bands
    /// (§22.4), which already have the URL. An untitled dirty pane is joined
    /// without a warning: there is no saved state to diverge from.
    private func join(url: URL, at position: JoinPosition, in pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let verb = (position == .start) ? "Insert" : "Append"

        // §22.2: a dirty pane is warned about, with two buttons — Cancel and
        // the operation's verb. An untitled dirty pane gets no alert: there is
        // no saved state to diverge from.
        if pane.status.isDirty && !pane.isUntitled {
            let alert = NSAlert()
            alert.messageText = "Join with unsaved changes?"
            alert.informativeText = "“\(pane.status.fileName)” has unsaved changes. They travel into the joined image; the file on disk keeps its saved bytes."
            alert.addButton(withTitle: verb)
            alert.addButton(withTitle: "Cancel")
            let response: NSApplication.ModalResponse
            if let joinConfirm {
                response = joinConfirm(alert)
            } else {
                response = Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)  // Cancel in tests
            }
            guard response == .alertFirstButtonReturn else { return }
        }

        // The name the pane's content carries now, remembered before the join
        // detaches the document — the status line names both sources (§22.2).
        let originalName = pane.status.fileName

        do {
            try pane.join(contentsOf: url, at: position)
        } catch let error as JoinError {
            switch error {
            case .emptySource:
                presentAlert(title: "File is empty",
                             message: "“\(url.lastPathComponent)” has no bytes to join.")
            }
            return
        } catch {
            presentFileError("Could not join file.", error, url: url)
            return
        }

        // The seam (the caret, at the start of the added part) is centred in the
        // pane by the join's own `notify(centerCaret: true)` (§10.4, §22.5).

        // §22.2: the transient status line names both sources and the total
        // size, the way the app reports a search result, then yields back.
        let total = pane.fileSize
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        let message = (position == .start)
            ? "Inserted \(url.lastPathComponent) before \(originalName). Total: \(size)."
            : "Appended \(url.lastPathComponent) after \(originalName). Total: \(size)."
        filePaneView(for: pane)?.showTransientMessage(message)
    }

    // MARK: - File > New File

    /// File > New File (Cmd+N): opens a brand-new, empty document in memory into
    /// a pane, using the same placement rules as Open (§4.1) — an empty pane
    /// first, otherwise the active pane, with the standard dirty-replacement
    /// confirmation. Nothing is written to disk until the first Save / Save As;
    /// the pane header shows "Untitled" with a plus-badge glyph until then.
    @objc func newDocument() {
        newUntitledDocument()
    }

    /// Creates an untitled in-memory document and places it into a pane
    /// following the Open placement rules (§4.1). Split from `newDocument()` so
    /// tests can drive the whole flow without the menu.
    func newUntitledDocument() {
        let pane1WasOpen = windowModel.pane1.isOpen
        let pane2WasOpen = windowModel.pane2.isOpen
        let plan = OpenPlacement.plan(
            activePaneIndex: windowModel.activePaneIndex,
            pane1Open: pane1WasOpen,
            pane2Open: pane2WasOpen,
            fileCount: 1
        )
        guard let target = plan.firstFilePane else { return }
        guard newUntitledIntoPane(index: target) else { return }

        // Active pane follows the rule that decided placement.
        if !pane1WasOpen {
            windowModel.setActivePane(0)
        } else if !pane2WasOpen {
            windowModel.setActivePane(1)
        }
        refreshMode()
    }

    /// Opens an untitled document into the pane at `index`, applying §4.1 rule 4
    /// (dirty-replacement confirmation). Returns false when refused.
    private func newUntitledIntoPane(index: Int) -> Bool {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2
        guard confirmReplaceDirtyPane(pane, onSaved: { [weak self] in
            _ = self?.newUntitledIntoPane(index: index)
        }) else { return false }
        pane.openUntitled()
        return true
    }

    // MARK: - Save / Save As / Revert (§5)

    @objc func saveDocument() {
        saveDocumentOfPane(activePane)
    }

    /// Saves the pane that owns the menu item — the header context menu's Save
    /// routes here so it always targets its own pane, never the active one
    /// (§4/§5). Both the menu bar and the context menu share
    /// `saveDocumentOfPane(_:)`.
    @objc func savePaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        saveDocumentOfPane(pane)
    }

    private func saveDocumentOfPane(_ pane: PaneViewModel) {
        guard pane.isOpen else { return }
        // An untitled document has no file to save to — Cmd+S is a Save As.
        if pane.isUntitled {
            presentSaveAs(for: pane)
            return
        }
        do {
            try pane.save()
        } catch DocumentError.fileIsReadOnly {
            presentSaveAs(for: pane)  // §5.4: read-only file auto-redirects to Save As
        } catch {
            presentFileError("Save failed.", error, url: pane.document?.url)
        }
    }

    @objc func saveDocumentAs() {
        presentSaveAs(for: activePane)
    }

    @objc func savePaneDocumentAs(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        presentSaveAs(for: pane)
    }

    /// Runs a Save As sheet for the given pane (active pane, or a specific pane
    /// from an external-change conflict or a deferred untitled save, §5.5).
    /// `onSaved` fires after a successful save — it continues a flow that had
    /// to wait for the untitled document to get a location.
    private func presentSaveAs(for pane: PaneViewModel, onSaved: (() -> Void)? = nil) {
        guard pane.isOpen else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pane.status.fileName
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: view.window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try pane.saveAs(to: url)
                SandboxBookmarkStore.shared.record(url)
                onSaved?()
            } catch {
                self.presentFileError("Save As failed.", error, url: url)
            }
        }
    }

    /// Saves `pane` to disk, routing untitled documents (which have no file
    /// yet) through a Save As sheet. Returns true when the save happened inline
    /// (and `onSaved` has run); false when it is deferred to a sheet (the
    /// completion will call `onSaved`) or failed (error already shown).
    @discardableResult
    private func savePane(_ pane: PaneViewModel, onSaved: @escaping () -> Void) -> Bool {
        if pane.isUntitled {
            presentSaveAs(for: pane, onSaved: onSaved)
            return false
        }
        do {
            try pane.save()
            onSaved()
            return true
        } catch {
            presentFileError("Save failed.", error, url: pane.document?.url)
            return false
        }
    }

    /// Saves `panes` one at a time; each untitled pane goes through its own Save
    /// As sheet, then the next saves, then `then` runs. Stops on the first
    /// failure (the error has already been shown).
    private func saveAllThen(_ panes: [PaneViewModel], then: @escaping () -> Void) {
        guard let first = panes.first else { then(); return }
        savePane(first, onSaved: { [weak self] in
            self?.saveAllThen(Array(panes.dropFirst()), then: then)
        })
    }

    @objc func revertDocument() {
        revertDocumentOfPane(activePane)
    }

    /// Reverts the pane that owns the menu item — the header context menu's
    /// Revert routes here so it always targets its own pane (§4/§5). Both the
    /// menu bar and the context menu share `revertDocumentOfPane(_:)`.
    @objc func revertPaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        revertDocumentOfPane(pane)
    }

    private func revertDocumentOfPane(_ pane: PaneViewModel) {
        guard pane.isOpen, !pane.isUntitled else { return }  // nothing on disk to revert to
        if pane.status.isDirty {
            let response = confirmAlert(
                title: "Revert to saved version?",
                message: "All unsaved changes will be discarded.",
                confirmTitle: "Revert",
                destructive: true
            )
            guard response == .alertFirstButtonReturn else { return }
        }
        do {
            try pane.revert()
        } catch {
            presentFileError("Revert failed.", error, url: pane.document?.url)
        }
    }

    /// Reveals the right-clicked pane's file in the Finder (header context
    /// menu). Resolves the pane the menu item was built for — so it shows the
    /// file even when another pane is active — and needs a real file on disk:
    /// an empty pane has nothing, and an untitled document has no URL to reveal.
    @objc func showPaneInFinder(_ sender: Any?) {
        guard let pane = pane(from: sender),
              pane.isOpen,
              !pane.isUntitled,
              let url = pane.document?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - External change detection (§5.5)

    /// Wires each pane's watcher to the conflict prompt. Closures capture the
    /// specific pane objects, not indices, because closing pane 1 swaps the
    /// pane1/pane2 objects in WindowViewModel.
    private func wireExternalChangeDetection() {
        let pane1 = windowModel.pane1
        let pane2 = windowModel.pane2
        // Capture the pane objects weakly: the closures live on the panes, so a
        // strong capture would be a retain cycle. Weak keeps them equal-lifetime.
        pane1.onExternalChange = { [weak self, weak pane1] in
            guard let pane1 else { return }
            self?.presentExternalChange(for: pane1)
        }
        pane2.onExternalChange = { [weak self, weak pane2] in
            guard let pane2 else { return }
            self?.presentExternalChange(for: pane2)
        }
    }

    /// Prompt for a file that changed on disk (§5.5): reload/keep when clean;
    /// reload-and-discard / keep / save-as when dirty. In test mode the prompt
    /// resolves to "keep" (never reload) so a stray watcher event cannot mutate
    /// a pane mid-test. Exposed (internal) so tests can pin that contract.
    func presentExternalChange(for pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let name = pane.status.fileName
        if pane.status.isDirty {
            let alert = NSAlert()
            alert.messageText = "File changed on disk"
            alert.informativeText = "“\(name)” has been changed by another program and has unsaved local changes."
            alert.addButton(withTitle: "Reload and Discard Changes")
            alert.addButton(withTitle: "Keep Local Changes")
            alert.addButton(withTitle: "Save As…")
            switch Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn) {  // Keep Local Changes in tests
            case .alertFirstButtonReturn:
                do {
                    try pane.revert()
                } catch {
                    presentFileError("Reload failed.", error, url: pane.document?.url)
                }
            case .alertThirdButtonReturn:
                presentSaveAs(for: pane)
            default:
                break  // keep local changes
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "File changed on disk"
            alert.informativeText = "“\(name)” has been changed by another program. Reload to see the latest version?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep Current Contents")
            if Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn) == .alertFirstButtonReturn {  // Keep in tests
                do {
                    try pane.revert()
                } catch {
                    presentFileError("Reload failed.", error, url: pane.document?.url)
                }
            }
        }
    }

    // MARK: - Pane / window closing (§3.5/3.6)

    /// File > Close (Cmd+W, "close document"): the active pane is the
    /// document, so it closes — in comparison mode this returns to single-file
    /// mode (with pane 2 promoted when pane 1 closes); closing the last pane
    /// returns to empty mode. With no panes open there is nothing to close, so
    /// the window closes instead.
    @objc func closeDocument() {
        guard windowModel.hasOpenFile else {
            view.window?.performClose(nil)
            return
        }
        closePane(at: windowModel.activePaneIndex)
    }

    /// Closes the pane at `index` after the standard dirty prompt. An untitled
    /// pane's "Save" picks a location first (Save As sheet); the pane closes
    /// once that completes.
    func closePane(at index: Int) {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2
        guard pane.isOpen else { return }
        if pane.status.isDirty {
            switch confirmSaveDiscardCancel() {
            case .alertFirstButtonReturn:  // Save
                savePane(pane, onSaved: { [weak self] in
                    self?.performClosePane(at: index)
                })
                return  // closes now or after the Save As sheet
            case .alertSecondButtonReturn:  // Don't Save
                break
            default:  // Cancel
                return
            }
        }
        performClosePane(at: index)
    }

    /// Performs the pane close after the dirty prompt succeeded.
    private func performClosePane(at index: Int) {
        windowModel.closePane(index)
        refreshMode()
        if mode == .singleFile {
            activeFilePane?.focusHexView()
        }
    }

    // MARK: - Pane header context menu (§4/§5)

    /// Builds the right-click menu for a pane's header. It carries the same
    /// items as the menu bar's File submenu (plus the header-only Show in
    /// Finder), and every item's action resolves the pane captured here (via
    /// `representedObject`) — so New, Open, Save and Close always act on the
    /// header that was right-clicked, even when another pane is active or only
    /// one pane is open. A final separate block holds Swap Panels, which is
    /// mode-scoped (comparison only) and so carries no `representedObject`.
    func makePaneMenu(for pane: PaneViewModel) -> NSMenu {
        let menu = NSMenu(title: "File")
        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.representedObject = pane
        }
        add("New File", #selector(newDocumentInPane(_:)), "n")
        add("Open…", #selector(openInPane(_:)), "o")
        menu.addItem(.separator())
        add("Save", #selector(savePaneDocument(_:)), "s")
        add("Save As…", #selector(savePaneDocumentAs(_:)), "S")
        add("Revert to Saved", #selector(revertPaneDocument(_:)), "")
        // The join twins (§22.1): beside the file-scoped commands, acting on
        // THIS pane (the menu's representedObject) rather than the active one.
        add("Append File…", #selector(appendFileInPane(_:)), "")
        add("Insert File at Start…", #selector(insertFileAtStartInPane(_:)), "")
        // Show in Finder is header-only: it reveals THIS pane's file in the
        // Finder, which is a per-pane act, so the menu bar's File submenu
        // (active-pane) doesn't duplicate it.
        add("Show in Finder", #selector(showPaneInFinder(_:)), "")
        menu.addItem(.separator())
        add("Close", #selector(closePaneDocument(_:)), "w")
        // Swap Panels is a comparison-mode command, not a per-pane File action,
        // so it gets its own block and targets `swapPanes` directly.
        menu.addItem(.separator())
        let swapItem = menu.addItem(withTitle: "Swap Panels",
                                    action: #selector(swapPanes),
                                    keyEquivalent: "")
        swapItem.target = self
        return menu
    }

    /// Builds the context menu for a right-clicked address in the Offset column:
    /// "Copy offset" (copies the hex offset to the clipboard), then "Select Block
    /// from Here at «address»", both resolving THIS pane (the header-menu pattern of
    /// §4/§5) and the clicked offset (§10.2). When the clicked byte lies inside
    /// the pane's current selection, the menu instead leads with selection-scoped
    /// actions — Copy, Fill Selection with…, Delete Bytes — that act on the
    /// right-clicked pane's selection, never the active pane's (§10.2).
    func makeOffsetMenu(for pane: PaneViewModel, offset: UInt64) -> NSMenu {
        let menu = NSMenu(title: "Offset")
        let selection = pane.hexSelection()
        if !selection.isEmpty, offset >= selection.start, offset < selection.end {
            addSelectionMenuItems(to: menu, for: pane, offset: offset)
            menu.addItem(.separator())
        }
        let copy = menu.addItem(withTitle: "Copy offset",
                                action: #selector(copyOffset(_:)),
                                keyEquivalent: "")
        copy.target = self
        copy.representedObject = OffsetContextTarget(pane: pane, offset: offset)
        menu.addItem(.separator())
        let select = menu.addItem(withTitle: "Select Block from Here at \(offset.bareAddress)",
                                  action: #selector(selectBlockFromHere(_:)),
                                  keyEquivalent: "")
        select.target = self
        select.representedObject = OffsetContextTarget(pane: pane, offset: offset)
        // The segment block (§21.3): the commands that shape the file's
        // partition, set off from the address-scoped commands above and the
        // bookmark commands below by their own separators.
        menu.addItem(.separator())
        addSegmentMenuItems(to: menu, for: pane, offset: offset)
        menu.addItem(.separator())
        addBookmarkMenuItems(to: menu, for: pane, offset: offset)
        return menu
    }

    /// The segment block of the offset context menu (§21.3): *Split Here at «address»* opens
    /// the Add Cut popover pre-filled with the right-clicked byte or address,
    /// and *Merge* merges the piece that position sits into its neighbour. Both
    /// act on the right-clicked position — the thing the menu was opened on.
    /// The Merge item's title is renamed by validation to name the piece and its
    /// neighbour ("Merge S1 into S0").
    private func addSegmentMenuItems(to menu: NSMenu, for pane: PaneViewModel, offset: UInt64) {
        let target = OffsetContextTarget(pane: pane, offset: offset)
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
        }
        add("Split Here at \(offset.bareAddress)", #selector(splitHere(_:)))
        add("Merge", #selector(removeSegment(_:)))
    }

    /// The bookmark block of the offset context menu (§20.3). One item marks and
    /// unmarks — *Toggle Bookmark at «address»*, the same command ⌘D is, so there
    /// is one thing to learn — and a marked row is offered *Edit Bookmark…*
    /// besides. The address is the ROW's, not the clicked byte's: a right-click on
    /// a byte marks its row (§20.1), and the title is what says so.
    private func addBookmarkMenuItems(to menu: NSMenu, for pane: PaneViewModel, offset: UInt64) {
        let target = OffsetContextTarget(pane: pane, offset: offset)
        let address = BookmarkStore.row(containing: offset).bareAddress
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
        }
        add("Toggle Bookmark at \(address)", #selector(toggleBookmarkAtOffset(_:)))
        if windowModel.bookmarkStore.bookmark(atRowContaining: offset) != nil {
            add("Edit Bookmark…", #selector(editBookmarkAtOffset(_:)))
        }
    }

    /// The three selection-scoped context-menu items (§10.2). Each carries the
    /// right-clicked pane (plus offset) so its action resolves THIS pane's
    /// selection, exactly as the offset items below resolve the pane.
    private func addSelectionMenuItems(to menu: NSMenu, for pane: PaneViewModel, offset: UInt64) {
        let target = OffsetContextTarget(pane: pane, offset: offset)
        let copy = menu.addItem(withTitle: "Copy",
                                action: #selector(copyPaneSelection(_:)),
                                keyEquivalent: "")
        copy.target = self
        copy.representedObject = target
        let fill = menu.addItem(withTitle: "Fill Selection with…",
                                action: #selector(fillPaneSelection(_:)),
                                keyEquivalent: "")
        fill.target = self
        fill.representedObject = target
        let delete = menu.addItem(withTitle: "Delete Bytes…",
                                  action: #selector(deletePaneSelection(_:)),
                                  keyEquivalent: "")
        delete.target = self
        delete.representedObject = target
    }

    /// The pane carried by a context-menu item (`representedObject`), or nil for
    /// menu-bar items, which act on the active pane instead.
    private func pane(from sender: Any?) -> PaneViewModel? {
        (sender as? NSMenuItem)?.representedObject as? PaneViewModel
    }

    /// The offset-context target carried by a right-click menu item, or nil.
    private func offsetContextTarget(from sender: Any?) -> OffsetContextTarget? {
        (sender as? NSMenuItem)?.representedObject as? OffsetContextTarget
    }

    /// The window-model index of `pane` (0 or 1). The pane objects are swapped
    /// by Swap Panels / pane-1 close promotion, so the comparison is by identity
    /// at action time, never a captured index.
    private func paneIndex(_ pane: PaneViewModel) -> Int {
        pane === windowModel.pane1 ? 0 : 1
    }

    /// The `FilePaneView` hosting `pane`, or nil when the pane has no view right
    /// now. Used to scroll the right-clicked pane's dump, which may not be the
    /// active one (§10.2).
    private func filePaneView(for pane: PaneViewModel) -> FilePaneView? {
        if pane === windowModel.pane1 { return comparisonView?.paneView1 ?? activeFilePane }
        return comparisonView?.paneView2
    }

    /// Offset context menu > Select Block from Here at «address»: opens the Select Block
    /// sheet for the pane that was right-clicked — Start pre-filled with the
    /// clicked address, the Length option active, and the cursor in the Length
    /// field (§10.2).
    @objc func selectBlockFromHere(_ sender: Any?) {
        guard let target = (sender as? NSMenuItem)?.representedObject as? OffsetContextTarget,
              target.pane.isOpen else { return }
        let pane = target.pane
        let sheet = SelectBlockSheetController(fileSize: pane.fileSize, presetStart: target.offset) { [weak self] selection in
            pane.setSelection(selection)
            // §10.2: show the block's START mid-pane — in the pane that was
            // right-clicked, not the active one.
            self?.filePaneView(for: pane)?.revealOffsetCentered(selection.start)
        }
        presentAsSheet(sheet)
    }

    /// Offset context menu > Copy offset: copies the right-clicked offset to
    /// the clipboard as bare hex digits ("10", not "0x10"). The offset fields
    /// already carry a "0x" prefix with the caret right after it, so pasting a
    /// prefixed value would double it ("0x0x10"); bare digits paste straight
    /// into Go To Position / Select Block / Find (§10.2).
    @objc func copyOffset(_ sender: Any?) {
        guard let target = (sender as? NSMenuItem)?.representedObject as? OffsetContextTarget else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(format: "%X", target.offset), forType: .string)
    }

    /// Header context menu > New File: a brand-new untitled document lands in
    /// THIS pane — not a placement-chosen one — and the pane becomes active.
    @objc func newDocumentInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        let index = paneIndex(pane)
        guard newUntitledIntoPane(index: index) else { return }
        // The pane that received the new file becomes active, so focus follows
        // (§3.3). A dirty pane defers through its Save As sheet and re-enters
        // `newUntitledIntoPane` once that completes.
        windowModel.setActivePane(index)
        refreshMode()
    }

    /// Header context menu > Open…: opens into THIS pane, even when only one
    /// pane is open (single-file mode replaces the current file).
    @objc func openInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        let index = paneIndex(pane)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.openFiles(into: index, urls: panel.urls)
        }
    }

    /// Opens the first chosen file into the pane at `index` (its header's pane),
    /// a second into the other pane only when that one is empty; extras (and an
    /// unplaceable second) are ignored. Mirrors the drop rules of §4.3.
    private func openFiles(into index: Int, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: index, url: first) else { return }

        let otherIndex = 1 - index
        let otherPane = otherIndex == 0 ? windowModel.pane1 : windowModel.pane2
        var ignored = max(0, files.count - 2)
        if files.count >= 2 {
            if otherPane.isOpen {
                ignored += 1  // the second file can't open — treated as ignored
            } else {
                _ = openIntoPane(index: otherIndex, url: files[1])
            }
        }
        windowModel.setActivePane(index)
        if ignored > 0 { notifyIgnored(count: ignored) }
        refreshMode()
    }

    /// Header context menu > Close: closes THIS pane (the active-pane Close in
    /// the menu bar keeps its own behavior).
    @objc func closePaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender), pane.isOpen else { return }
        closePane(at: paneIndex(pane))
    }

    // MARK: - Edit commands (§7, §12)

    @objc func undoEdit() {
        _ = try? activePane.undo()
    }

    @objc func redoEdit() {
        _ = try? activePane.redo()
    }

    @objc func selectAllBytes() {
        activePane.selectAll()
        focusActiveHexView()
    }

    /// Edit > Copy (⌘C): copies the ACTIVE pane's selection.
    @objc func copySelection() {
        copySelectionBytes(of: activePane)
    }

    /// Context menu > Copy: copies the RIGHT-CLICKED pane's selection (§10.2).
    @objc func copyPaneSelection(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender), target.pane.isOpen else { return }
        copySelectionBytes(of: target.pane)
    }

    /// Copies `pane`'s selection to the clipboard: raw bytes (primary, §12.1)
    /// plus uppercase hex text.
    private func copySelectionBytes(of pane: PaneViewModel) {
        guard let doc = pane.document, !doc.selection.isEmpty else { return }
        let range = doc.selection.start..<doc.selection.end
        guard let bytes = try? doc.read(at: range.lowerBound, length: Int(range.count)) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data(bytes), forType: .rawBytes)  // raw bytes: primary (§12.1)
        pasteboard.setString(ClipboardCodec.hexText(from: bytes), forType: .string)
    }

    /// The standard "Paste" menu item (⌘V → `paste:`) dispatches through the
    /// responder chain (§11). A focused text field's editor implements
    /// `paste:` and pastes text, so the message only reaches this controller
    /// when the first responder has no text-paste of its own — i.e. the hex
    /// view. Paste-write into the dump therefore happens only while a hex
    /// pane holds focus; everywhere else ⌘V is the standard system paste.
    @objc func paste(_ sender: Any?) {
        guard view.window?.firstResponder is HexView, activePane.isOpen else { return }
        pasteWrite()
    }

    @objc func pasteWrite() {
        let pane = activePane
        guard pane.isOpen else { return }
        do {
            let bytes = try pasteboardBytes()
            try pane.pasteWrite(bytes)
        } catch {
            presentError("Paste", error)
        }
    }

    @objc func pasteInsert() {
        let pane = activePane
        guard pane.isOpen else { return }
        let bytes: [UInt8]
        do {
            bytes = try pasteboardBytes()
        } catch {
            presentError("Paste Insert", error)
            return
        }
        guard !bytes.isEmpty else { return }
        let offset = pane.caretOffset
        let response = confirmAlert(
            title: "Paste Insert?",
            message: "Insert \(bytes.count) byte(s) at offset \(String(format: "0x%X", offset)). Existing bytes from this offset on will shift.",
            confirmTitle: "Insert",
            destructive: true,
            suppressible: true
        )
        guard response == .alertFirstButtonReturn else { return }
        do {
            try pane.pasteInsert(bytes)
        } catch {
            presentError("Paste Insert failed.", error)
        }
    }

    /// Edit > Fill Selection with…: fills the ACTIVE pane's selection.
    @objc func fillSelectionWithBytes() {
        presentFillSheet(for: activePane)
    }

    /// Context menu > Fill Selection with…: fills the RIGHT-CLICKED pane's
    /// selection (§10.2). The sheet's completion captures that pane directly, so
    /// a selection in a non-active pane is still the one that gets filled.
    @objc func fillPaneSelection(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender), target.pane.isOpen else { return }
        presentFillSheet(for: target.pane)
    }

    private func presentFillSheet(for pane: PaneViewModel) {
        guard pane.isOpen, !pane.hexSelection().isEmpty else { return }
        let sheet = FillSheetController(selectionCount: pane.hexSelection().count) { pattern in
            pane.fillSelection(with: pattern)
        }
        presentAsSheet(sheet)
    }

    /// Edit > Delete Bytes…: deletes the ACTIVE pane's selection, or the caret
    /// byte when the selection is empty.
    @objc func deleteBytes() {
        deleteSelectionOrCaret(in: activePane)
    }

    /// Context menu > Delete Bytes…: deletes the RIGHT-CLICKED pane's selection
    /// (§10.2). Only offered when the selection is non-empty, so the single-byte
    /// caret fallback never applies here.
    @objc func deletePaneSelection(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender), target.pane.isOpen else { return }
        deleteSelectionOrCaret(in: target.pane)
    }

    private func deleteSelectionOrCaret(in pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let selection = pane.hexSelection()
        let start = selection.start
        let count = selection.isEmpty ? 1 : selection.count
        let response = confirmAlert(
            title: "Delete \(count) byte(s)?",
            message: "Bytes from offset \(String(format: "0x%X", start)) will be removed. Subsequent offsets will shift — the file structure may be affected.",
            confirmTitle: "Delete",
            destructive: true,
            suppressible: true
        )
        guard response == .alertFirstButtonReturn else { return }
        do {
            try pane.deleteBytes(in: start..<(start + count))
        } catch {
            presentError("Delete failed.", error)
        }
    }

    /// Edit > Insert Mode: flips the typing mode of the ACTIVE pane. The mode is
    /// per pane and never persisted — one file can be typed into while the other
    /// is being read, and each pane's status bar says which mode it is in (§7.6).
    ///
    /// When on, typing inserts a byte at the caret and shifts the tail right; the
    /// caret becomes a red vertical line at the byte boundary. The one-time
    /// "this shifts the file" warning is injected here rather than at pane
    /// creation, which guarantees the callback exists before any insert-mode
    /// keystroke; it is mode-independent, so re-enabling after a toggle-off never
    /// re-arms it within the same file.
    @objc func toggleInsertMode(_ sender: Any?) {
        let pane = activePane
        pane.isInsertMode.toggle()
        pane.confirmInsertModeWarning = { [weak self, weak pane] in
            guard let self, let pane else { return true }
            let offset = pane.caretOffset
            let response = self.confirmAlert(
                title: "Insert?",
                message: "Inserting at offset \(String(format: "0x%X", offset)) shifts every byte from here on — the file structure may be affected.",
                confirmTitle: "Insert",
                destructive: true,
                suppressible: true
            )
            return response == .alertFirstButtonReturn
        }
    }

    /// Adds or removes the toolbar's Prev/Next Difference block to match the
    /// mode. Difference navigation exists only with two files open, and a block
    /// of buttons that can never do anything is worse than no block: disabled
    /// they still read as something the window offers (§10.3). The menu items
    /// stay, disabled — a menu is a list of what exists, and it says why.
    ///
    /// Called on every mode change and once the toolbar exists (the window
    /// controller builds it after the view is loaded).
    func syncDiffNavigationToolbarItem() {
        // Deferred by a run-loop turn, and coalesced. Called from `apply(mode:)`
        // this would land while AppKit is still reconfiguring the toolbar from
        // the previous change, and mutating it then raises on the item index.
        guard !diffToolbarSyncScheduled else { return }
        diffToolbarSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.diffToolbarSyncScheduled = false
            self?.applyDiffNavigationToolbarItem()
        }
    }

    private func applyDiffNavigationToolbarItem() {
        // Only a toolbar on screen can be reconfigured: before the window is
        // shown, `items` reports the configured identifiers while the toolbar's
        // own list is still empty. A window that appears later syncs from
        // `viewDidAppear`.
        guard let window = viewIfLoaded?.window, window.isVisible,
              let toolbar = window.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .diffNavigation }
        switch (mode == .comparison, index) {
        case (true, nil):
            // Before the standard space, so the block keeps its place between
            // the flexible space and the minimap toggle (§19).
            let insertAt = toolbar.items.firstIndex { $0.itemIdentifier == .space }
                ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .diffNavigation, at: insertAt)
            // A freshly inserted item starts enabled — AppKit's default
            // validation only asks whether the target responds to the action —
            // so it would offer a live-looking Prev Diff until the next
            // validation pass (§10.3).
            toolbar.validateVisibleItems()
        case (false, let index?):
            toolbar.removeItem(at: index)
        default:
            break
        }
    }

    // MARK: - Comparison navigation (§10.3)

    @objc func nextDifference() { navigateBlock(kind: .different, direction: .forward) }
    @objc func previousDifference() { navigateBlock(kind: .different, direction: .backward) }
    @objc func nextSameBlock() { navigateBlock(kind: .same, direction: .forward) }
    @objc func previousSameBlock() { navigateBlock(kind: .same, direction: .backward) }

    /// Recomputes `diffNavigationState` from the current mode, index build
    /// state, and active caret — the same `from` and search rules
    /// `navigateBlock` uses, so a menu item is enabled exactly when the action
    /// would find a block. Fired on mode changes, index transitions, pane
    /// switches, and caret moves; the menu items read the result via
    /// `validateMenuItem` (§10.3).
    private func refreshDiffNavigation() {
        var state = DiffNavigationState()
        if mode == .comparison, !comparisonCoordinator.isBuilding {
            // Ask through the coordinator, so enablement and the action itself
            // agree on the unit they step by — grouped hunks (§10.3.1).
            let from = windowModel.activePane.caretOffset
            func exists(_ kind: DiffBlock.Kind, _ direction: SearchDirection) -> Bool {
                comparisonCoordinator.findBlock(kind: kind, direction: direction, from: from) != nil
            }
            state.previousDifference = exists(.different, .backward)
            state.nextDifference = exists(.different, .forward)
            state.previousSameBlock = exists(.same, .backward)
            state.nextSameBlock = exists(.same, .forward)
        }
        guard state != diffNavigationState else { return }
        diffNavigationState = state
        // Menu items are validated when the menu opens, but the toolbar's arrows
        // are on screen the whole time: AppKit revalidates them on its own idle
        // schedule, so ask for it here and they follow the caret at once (§10.3).
        viewIfLoaded?.window?.toolbar?.validateVisibleItems()
    }

    private func navigateBlock(kind: DiffBlock.Kind, direction: SearchDirection) {
        guard mode == .comparison else { return }
        let from = windowModel.activePane.caretOffset
        Task {
            guard let block = comparisonCoordinator.findBlock(kind: kind, direction: direction, from: from) else {
                let what = kind == .different ? "difference" : "same block"
                NSSound.beep()
                comparisonView?.showNavigationMessage("No more \(what)")
                return
            }
            // Forward navigation lands on the block start; backward navigation
            // lands on the block's LAST byte (not the byte past it), so a
            // repeated previous press skips the current block and finds the one
            // before it — landing past the block would re-find it (§10.3).
            let target = direction == .backward ? block.range.upperBound - 1 : block.range.lowerBound
            windowModel.pane1.moveCaret(to: target)
            windowModel.pane2.moveCaret(to: target)
            comparisonView?.refreshComparisonInfo()
            // Show the block start mid-pane, the way the Find bar centres a
            // match; the panes' synchronized scroll (§9) centres both (§10.3).
            activeFilePane?.revealSelectionCentered()
            focusActiveHexView()
        }
    }

    /// View > Toggle Pane Layout (§3.3).
    @objc func togglePaneLayout() {
        guard mode == .comparison else { return }
        comparisonView?.toggleLayout()
    }

    /// View > Swap Panels: exchanges pane 1 and pane 2 (comparison mode). The
    /// active pane follows its document, so the file the user was working on
    /// stays active. Re-applying the mode rebuilds both panes and the diff
    /// index against the swapped storages.
    @objc func swapPanes() {
        guard mode == .comparison else { return }
        windowModel.swapPanes()
        refreshMode()
    }

    /// View > Word Size (§6): re-groups the hex dump into words of this size.
    @objc func setWordSize(_ sender: Any?) {
        guard let size = (sender as? NSMenuItem).flatMap({ WordSize(rawValue: $0.tag) }) else { return }
        WordSize.set(size)
    }

    // MARK: - Bookmarks (§20)

    /// Edit > Toggle Bookmark (⌘D), and the offset menu's item: toggles the mark
    /// on `pane`'s row containing `offset` (§20.3). A bookmark marks a row, not a
    /// byte — the offset is rounded down to its row — and the list is shared by
    /// both panes, so the same row is marked in both panes of a comparison.
    ///
    /// Marking a row opens the naming popover on the new mark: Return saves it
    /// (unnamed if nothing was typed), Esc removes it again. That is what makes
    /// **⌘D, Return** the whole gesture for "mark this row" and ⌘D, a name,
    /// Return the one for "mark it and call it this". A row that is already
    /// marked is unmarked on the spot, with no popover to dismiss.
    private func toggleBookmarkInPane(_ pane: PaneViewModel, rowContaining offset: UInt64) {
        guard pane.isOpen else { return }
        if windowModel.bookmarkStore.remove(rowContaining: offset) { return }
        markAndNameBookmark(in: pane, rowContaining: offset)
    }

    /// Marks the row containing `offset` and opens the naming popover on the new
    /// mark. The mark is made first, so it is visible while its name is typed —
    /// and `existingName: nil` is what tells the popover it is naming a mark that
    /// was just made, so its Esc removes it rather than keeping a name (§20.3).
    private func markAndNameBookmark(in pane: PaneViewModel, rowContaining offset: UInt64) {
        let store = windowModel.bookmarkStore
        let row = BookmarkStore.row(containing: offset)
        store.add(rowContaining: row)
        presentBookmarkEditPopover(
            in: pane, row: row, existingName: nil,
            onCommit: { [weak self] target, name in
                self?.applyBookmarkEdit(from: row, to: target, name: name)
            },
            onCancel: { store.remove(rowContaining: row) }
        )
    }

    /// A double click on an address opens the edit popover on that row: it marks
    /// the row first when it carries no mark, so the gesture is ⌘D's with the
    /// mouse, and it edits the mark that is there otherwise — a double click on
    /// a mark is how a mark is opened everywhere else in the app (§20.5's list
    /// does the same on a name).
    ///
    /// What it never does is unmark: the pointer covers the mark it is aimed at,
    /// so a toggle here would silently take an existing bookmark away on a click
    /// landing a row off.
    func handleOffsetDoubleClick(in pane: PaneViewModel, rowContaining offset: UInt64) {
        guard pane.isOpen else { return }
        if windowModel.bookmarkStore.bookmark(atRowContaining: offset) != nil {
            editBookmarkInPane(pane, rowContaining: offset)
        } else {
            markAndNameBookmark(in: pane, rowContaining: offset)
        }
    }

    /// Wires a pane view's Offset-column double click to the bookmark gesture, so
    /// it resolves THIS pane even when it is not the active one (§20.3).
    func wireBookmarkDoubleClick(_ paneView: FilePaneView, for pane: PaneViewModel) {
        paneView.onOffsetDoubleClick = { [weak self] offset in
            self?.handleOffsetDoubleClick(in: pane, rowContaining: offset)
        }
    }

    /// Edits the mark on `pane`'s row containing `offset` — its address and its
    /// name — in the same popover (§20.3). Only for a row that carries one: Esc
    /// leaves the bookmark exactly as it was.
    private func editBookmarkInPane(_ pane: PaneViewModel, rowContaining offset: UInt64) {
        guard pane.isOpen,
              let existing = windowModel.bookmarkStore.bookmark(atRowContaining: offset) else { return }
        let store = windowModel.bookmarkStore
        presentBookmarkEditPopover(
            in: pane, row: existing.row, existingName: existing.name,
            onCommit: { [weak self] target, name in
                self?.applyBookmarkEdit(from: existing.row, to: target, name: name)
            },
            onCancel: {},
            // Removing is offered only here, on a bookmark that already exists:
            // a mark still being named is taken away by its Esc (§20.3).
            onDelete: { store.remove(rowContaining: existing.row) }
        )
    }

    /// Applies what the popover was edited to: the name, and the address when it
    /// changed. A moved bookmark is the same bookmark — it leaves the old row and
    /// arrives on the new one named, rather than being removed and re-made, so
    /// nothing in between sees a bookmark without its name (§20.3).
    private func applyBookmarkEdit(from row: UInt64, to target: UInt64, name: String) {
        windowModel.bookmarkStore.edit(rowContaining: row, to: target, name: name)
    }

    /// A request to edit a bookmark: which row, in which pane, the name it
    /// starts with (nil when the mark was just created, which is what makes Esc
    /// remove it), and what the two keys do. `commit` takes the row the popover
    /// was edited to, which is not always the row it opened on (§20.3).
    struct BookmarkEditRequest {
        let pane: PaneViewModel
        let row: UInt64
        let existingName: String?
        let commit: (UInt64, String) -> Void
        let cancel: () -> Void
        /// Removes the bookmark — nil for a mark that was just made, whose Esc
        /// already does that (§20.3).
        let delete: (() -> Void)?
    }

    /// Where an edit request goes, returning how to dismiss what it presented.
    /// Nil means the real popover on the pane's mark; a test replaces it to
    /// capture the request instead, because a popover anchored in a window that
    /// is never on screen closes the instant it opens — the commands' own
    /// behaviour is what those tests are about.
    var bookmarkEditPresenter: ((BookmarkEditRequest) -> () -> Void)?

    /// The editing session on screen: the row it is about, and how to close it
    /// without saving. Held because it must not outlive its mark (§20.3).
    private var openEditing: (row: UInt64, dismiss: () -> Void)?

    /// The row an edit popover is open for, if any.
    var editingRow: UInt64? { openEditing?.row }

    /// Presents the edit popover on `pane`'s mark (§20.3), replacing any session
    /// already on screen — ⌘D on another row while one is open would otherwise
    /// leave two panels up, one of them about a row the user has moved on from.
    private func presentBookmarkEditPopover(
        in pane: PaneViewModel, row: UInt64, existingName: String?,
        onCommit: @escaping (UInt64, String) -> Void, onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        openEditing?.dismiss()
        openEditing = nil
        let request = BookmarkEditRequest(
            pane: pane, row: row, existingName: existingName,
            commit: { [weak self] target, name in
                self?.openEditing = nil
                onCommit(target, name)
            },
            cancel: { [weak self] in
                self?.openEditing = nil
                onCancel()
            },
            delete: onDelete.map { delete in
                { [weak self] in
                    self?.openEditing = nil
                    delete()
                }
            }
        )
        if let bookmarkEditPresenter {
            openEditing = (row, bookmarkEditPresenter(request))
            return
        }
        guard let paneView = filePaneView(for: pane) else { return }
        let store = windowModel.bookmarkStore
        let controller = paneView.presentBookmarkEditPopover(
            rowContaining: row, existingName: existingName,
            // One row holds one bookmark (§20.1), so an address already marked is
            // not an address this bookmark can be given.
            rowIsFree: { store.bookmark(atRowContaining: $0) == nil },
            onCommit: request.commit, onCancel: request.cancel, onDelete: request.delete
        )
        openEditing = (row, { controller.abandon() })
    }

    /// Closes the edit popover when the mark it is editing disappears. Every
    /// removal arrives here through the window's bookmark signal — ⌘D (whose key
    /// equivalent reaches the menu through an open popover), the context menu,
    /// and the form's list — so no removal path has to remember to do this
    /// (§20.3).
    private func dismissEditPopoverIfItsMarkIsGone(row: UInt64) {
        guard let openEditing, openEditing.row == row,
              windowModel.bookmarkStore.bookmark(atRowContaining: row) == nil else { return }
        self.openEditing = nil
        openEditing.dismiss()
    }

    /// ⌘D: the active pane's caret row.
    @objc func toggleBookmark() {
        toggleBookmarkInPane(activePane, rowContaining: activePane.hexSelection().start)
    }

    /// ⇧⌘D: edits the mark on the active pane's caret row — its address and its
    /// name. Enabled only when that row carries one: ⌘D is how a mark is made,
    /// and it opens the same popover, so this command only ever edits (§20.3).
    @objc func editBookmark() {
        editBookmarkInPane(activePane, rowContaining: activePane.hexSelection().start)
    }

    /// Offset context menu > Toggle Bookmark: the same act on the row that was
    /// right-clicked rather than the caret's, in the pane that was right-clicked.
    @objc func toggleBookmarkAtOffset(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender) else { return }
        toggleBookmarkInPane(target.pane, rowContaining: target.offset)
    }

    /// Offset context menu > Edit Bookmark…: the edit popover for the
    /// right-clicked row's existing mark.
    @objc func editBookmarkAtOffset(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender) else { return }
        editBookmarkInPane(target.pane, rowContaining: target.offset)
    }

    // MARK: - Segments (§21)

    /// The cut edit request: the pane, the offset the field starts at, where the
    /// popover anchors, and what committing means.
    struct CutEditRequest {
        let pane: PaneViewModel
        let prefillOffset: UInt64
        let anchoredToOffset: Bool
        let commit: (UInt64, String) -> Void
    }

    /// Where a cut edit request goes. Nil means the real popover on the caret's
    /// cell; a test replaces it to capture the request instead, because a
    /// popover anchored in a window that is never on screen closes the instant
    /// it opens — the commands' own behaviour is what those tests are about.
    var cutEditPresenter: ((CutEditRequest) -> Void)?

    /// Edit ▸ Add Cut…: the caret's offset, in a popover with a description —
    /// the cut for an offset you know as a number rather than as a position
    /// (§21.3). No key equivalent: a deliberate act reached from the menu. The
    /// popover is centred in the pane, not anchored to the caret: it is a dialog
    /// pre-filled with a number, not a pointer at a byte.
    @objc func addCut() {
        let pane = activePane
        presentCutEditPopover(in: pane, prefill: pane.caretOffset, anchoredToOffset: false)
    }

    /// Merge: merges the piece a position sits in into its neighbour (§21.3). It
    /// acts on a position *inside* a piece — the caret's, from the Edit menu; the
    /// right-clicked byte or address, from the context menu — not on a cut point.
    /// The bytes are untouched: merging a piece changes how the file is read, not
    /// the file. The menu title names the piece and the neighbour it merges into
    /// ("Merge S1 into S0"), so it is never confused with deleting data.
    @objc func removeSegment(_ sender: Any?) {
        let (pane, position): (PaneViewModel, UInt64)
        if let target = offsetContextTarget(from: sender) {
            (pane, position) = (target.pane, target.offset)
        } else {
            pane = activePane
            position = pane.caretOffset
        }
        guard let piece = pane.segmentStore.segment(containing: position) else { return }
        pane.segmentStore.removePiece(at: piece.index)
    }

    /// Offset context menu ▸ Split Here at «address»: the Add Cut popover, opened on the
    /// right-clicked byte or address and pre-filled with it (§21.3) — the same
    /// dialog as Edit ▸ Add Cut…, so a cut made from the menu and one made from
    /// the bar are the same act. This is how a cut normally gets made.
    @objc func splitHere(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender) else { return }
        presentCutEditPopover(in: target.pane, prefill: target.offset)
    }

    /// Presents the cut popover for `pane` (§21.3). The offset starts at
    /// `prefill` (the caret's, or the right-clicked byte's) and is validated as
    /// it is typed; committing makes the cut and names the piece that starts
    /// there. With `anchoredToOffset` the popover hangs off that byte; without
    /// it (Add Cut…) it is centred in the pane's visible area.
    private func presentCutEditPopover(in pane: PaneViewModel, prefill: UInt64,
                                       anchoredToOffset: Bool = true) {
        let request = CutEditRequest(
            pane: pane, prefillOffset: prefill, anchoredToOffset: anchoredToOffset,
            commit: { offset, name in
                guard pane.segmentStore.addCut(at: offset) else { return }
                // The cut splits the piece at `offset`; the new piece is the one
                // that *starts* there, so it is the one the description names.
                if let piece = pane.segmentStore.segment(containing: offset) {
                    pane.segmentStore.rename(piece.index, to: name)
                }
            }
        )
        if let cutEditPresenter {
            cutEditPresenter(request)
            return
        }
        guard let paneView = filePaneView(for: pane) else { return }
        paneView.presentCutEditPopover(
            prefillOffset: prefill, fileSize: pane.fileSize,
            isAlreadyACut: { pane.segmentStore.cuts.contains($0) },
            onCommit: request.commit, anchoredToOffset: anchoredToOffset
        )
    }

    // MARK: - Dialogs (§10)

    /// ⌘L: the Go To / Bookmarks form with the offset field focused — the fast
    /// path is unchanged, ⌘L, type, Return (§10.1). Tab moves the keyboard to
    /// the bookmark list, the other half of the same window (§20.5).
    @objc func goToPosition() {
        presentGoToForm(focus: .offsetField)
    }

    /// Where the form goes, so a test can drive it instead: it is presented in a
    /// modal window, and a modal window has no one to dismiss it under XCTest.
    var goToFormPresenter: ((GoToBookmarksController) -> Void)?

    /// The form on screen, so a bookmark changed under it (from its own list, or
    /// from anywhere the store is touched) refreshes what it shows (§20.2).
    private weak var openGoToForm: GoToBookmarksController?

    private func presentGoToForm(focus: GoToBookmarksController.Focus) {
        guard activePane.isOpen else { return }
        let form = GoToBookmarksController(
            store: windowModel.bookmarkStore, focus: focus,
            rowBytes: { [weak self] row in self?.bookmarkRowBytes(row) },
            onGo: { [weak self] offset in self?.goTo(offset: offset) }
        )
        openGoToForm = form
        if let goToFormPresenter {
            goToFormPresenter(form)
            return
        }
        // A window, not a sheet: it holds a list the user manages, and it is
        // centred over the window it navigates.
        presentAsModalWindow(form)
    }

    /// Segments…: the partition's own form — the pieces in a table with a row
    /// editor, a +/− footer, and the Save All button (§21.4). Presented like
    /// the Go To form: a modal window that follows the pane's store, so a cut
    /// made under it from the dump's own context menu is seen in the list.
    @objc func showSegments() {
        presentSegmentsForm()
    }

    /// Where the form goes, so a test can drive it instead: it is presented in
    /// a modal window, and a modal window has no one to dismiss it under XCTest.
    var segmentsFormPresenter: ((SegmentsFormController) -> Void)?

    /// The form on screen, so a cut made under it (from the dump's context
    /// menu, or from the form's own +/−) refreshes what it shows (§21.4).
    private weak var openSegmentsForm: SegmentsFormController?

    private func presentSegmentsForm(pane: PaneViewModel? = nil, selecting pieceIndex: Int? = nil) {
        let pane = pane ?? activePane
        guard pane.isOpen else { return }
        let form = SegmentsFormController(
            pane: pane,
            // The app's own jump (§10.1): both panes in comparison mode, the
            // row revealed, the hex view focused — the same act as the Go To
            // form's Return.
            onGo: { [weak self] offset in self?.goTo(offset: offset) }
        )
        // The save actions live here, not in the form (§21.5): the form is
        // modal and has no status bar of its own, so the panels, the overwrite
        // confirmation and the write's progress all run from the window.
        form.saveAll = { [weak self] in self?.saveAllPieces(of: pane) ?? false }
        form.savePiece = { [weak self] piece in self?.savePiece(piece, of: pane) ?? false }
        form.replacePiece = { [weak self] piece in self?.replacePiece(piece, of: pane) ?? false }
        // The pane's `onSegmentsChanged` is set once per mode apply (§19.4.4):
        // it reloads this form when it is open and syncs the minimap's strip
        // whether or not it is, so a cut made here repaints the legend too.
        openSegmentsForm = form
        if let segmentsFormPresenter {
            segmentsFormPresenter(form)
        } else {
            // A window, not a sheet: it holds a list the user manages, and it is
            // centred over the window it edits.
            presentAsModalWindow(form)
        }
        // The strip's Edit… opens the form on the piece under the pointer.
        if let pieceIndex {
            form.selectSegment(atIndex: pieceIndex)
        }
    }

    // MARK: - Writing pieces out (§21.5)

    /// Save All as Separate Files…: writes the whole partition out as its pieces.
    /// The directory is chosen in directory mode (a save panel grants access to
    /// one file and this writes N — the sandbox would refuse the rest), the base
    /// name comes from the document, and one confirmation previews what will be
    /// written and names every file that would be replaced, before anything is
    /// written. Returns whether the write actually started — the form closes on
    /// true and stays open when the user cancelled a panel.
    private func saveAllPieces(of pane: PaneViewModel) -> Bool {
        guard pane.isOpen, let storage = pane.byteStorage else { return false }
        let segments = pane.segmentStore.segments
        guard !segments.isEmpty else { return false }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder the segments will be written to."
        let directory: URL?
        if let segmentDirectoryPanel {
            directory = segmentDirectoryPanel(panel)
        } else {
            directory = panel.runModal() == .OK ? panel.url : nil
        }
        guard let directory else { return false }

        // One file per piece, named for the document: `bios_S0.bin`, `bios_S1.bin`, …
        let baseName = pane.document?.url.lastPathComponent ?? "Untitled"
        let parts = segments.map {
            SegmentWriter.Part(range: $0.range, name: "\(baseName)_\($0.label).bin")
        }

        guard confirmSegmentWrite(parts: parts, in: directory) else { return false }
        runSegmentWrite(parts: parts, from: storage, to: directory)
        return true
    }

    /// Save Segment…: writes the one piece under the click to a file — the
    /// ordinary save panel, one file. The panel's own replace confirmation covers
    /// the overwrite, so there is no separate one here. Returns whether the write
    /// actually started.
    private func savePiece(_ piece: Segment, of pane: PaneViewModel) -> Bool {
        guard pane.isOpen, let storage = pane.byteStorage else { return false }
        let baseName = pane.document?.url.lastPathComponent ?? "Untitled"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName)_\(piece.label).bin"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        let url: URL?
        if let segmentSavePanel {
            url = segmentSavePanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return false }

        let part = SegmentWriter.Part(range: piece.range, name: url.lastPathComponent)
        runSegmentWrite(parts: [part], from: storage, to: url.deletingLastPathComponent())
        return true
    }

    /// Replace Segment from File…: reads the one piece under the click from a
    /// file (§21.6) — the ordinary open panel, one file, replacing the piece's
    /// bytes. The file must match the piece's length; a mismatch is refused with
    /// both sizes named, because making it an insert-and-shift is a decision, not
    /// a default. Returns whether the swap actually started.
    private func replacePiece(_ piece: Segment, of pane: PaneViewModel) -> Bool {
        guard pane.isOpen else { return false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Replace"
        panel.message = "Choose the file whose bytes replace \(piece.label)."
        let url: URL?
        if let segmentOpenPanel {
            url = segmentOpenPanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return false }

        do {
            try pane.replaceSegment(piece, withContentsOf: url)
            return true
        } catch let error as SegmentReplaceError {
            switch error {
            case .lengthMismatch(let pieceLength, let donorLength):
                presentAlert(
                    title: "File size does not match the segment",
                    message: "\(piece.label) is \(FilePaneView.friendlySize(pieceLength)) bytes, "
                        + "but the file is \(FilePaneView.friendlySize(donorLength)). "
                        + "The file must be exactly the same length to replace the piece."
                )
            }
            return false
        } catch {
            presentFileError("Replacing the segment failed.", error, url: url)
            return false
        }
    }

    /// The one confirmation before a Save All writes (§21.5): a preview of every
    /// part — `S0 → bios_S0.bin (4 MB)` — and, when any of the target files
    /// already exist, the names of the ones that would be replaced. Shown before
    /// anything is written.
    private func confirmSegmentWrite(parts: [SegmentWriter.Part], in directory: URL) -> Bool {
        let fileManager = FileManager.default
        // The parts are in file order (S0, S1, …), so the position is the label.
        let lines = parts.enumerated().map { index, part in
            "\(Segment.label(for: index)) → \(part.name) (\(FilePaneView.friendlySize(UInt64(part.range.count))))"
        }
        let existing = parts.filter {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0.name).path)
        }
        let alert = NSAlert()
        alert.messageText = "Save \(parts.count) Segment\(parts.count == 1 ? "" : "s")?"
        var informative = lines.joined(separator: "\n")
        if !existing.isEmpty {
            informative += "\n\nThese files will be replaced:\n"
                + existing.map(\.name).joined(separator: "\n")
        }
        alert.informativeText = informative
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let segmentWriteConfirm {
            response = segmentWriteConfirm(alert)
        } else {
            response = Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)  // Cancel in tests
        }
        return response == .alertFirstButtonReturn
    }

    /// Runs the write off the main thread, with the name, progress and (×) in the
    /// active pane's status bar while it runs (§14.4). A new write cancels any
    /// in-flight one. The write is all or nothing (§21.5): a failure or a cancel
    /// publishes nothing and leaves the directory as it was.
    private func runSegmentWrite(parts: [SegmentWriter.Part], from storage: any ByteStorage,
                                 to directory: URL) {
        if let segmentWriteRunner {
            segmentWriteRunner(parts, storage, directory)
            return
        }
        segmentWriteTask?.cancel()
        segmentWriteOperation?.finish()
        let operation = BackgroundOperation(name: "Writing \(parts.count) segment\(parts.count == 1 ? "" : "s")…") { [weak self] in
            self?.segmentWriteTask?.cancel()
        }
        segmentWriteOperation = operation
        activeFilePane?.beginOperation(operation)
        segmentWriteTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SegmentWriter.write(
                        parts, from: storage, to: directory,
                        shouldCancel: { Task.isCancelled },
                        progress: { operation.report($0) }
                    )
                }.value
                operation.finish()
            } catch is CancellationError {
                operation.finish()
            } catch {
                operation.finish()
                self?.presentFileError("Saving segments failed.", error, url: directory)
            }
        }
    }

    /// The bytes on a bookmarked row of the ACTIVE pane, for the list to show
    /// where an unnamed bookmark's name would be (§20.5). Nil when the row is
    /// past that pane's end: a bookmark is an absolute address and stays in the
    /// list even where the file does not reach (§9). Read live, per row, so the
    /// list shows the pane's current content, edits included.
    private func bookmarkRowBytes(_ row: UInt64) -> [UInt8]? {
        let pane = activePane
        guard pane.isOpen, row < pane.fileSize, let storage = pane.byteStorage else { return nil }
        let length = Int(min(UInt64(HexLayout.bytesPerRow), pane.fileSize - row))
        return (try? storage.read(at: row, length: length)) ?? []
    }

    /// The jump itself (§10.1) — the same act whether the offset was typed or
    /// picked from the bookmark list.
    private func goTo(offset: UInt64) {
        let largerSize = max(windowModel.pane1.fileSize, windowModel.pane2.fileSize)
        if offset > largerSize {
            presentAlert(
                title: "Offset beyond end of file",
                message: "Offset \(String(format: "0x%X", offset)) is beyond the end of the file(s) (\(String(format: "0x%X", largerSize)) bytes). Moved to the end."
            )
        }
        let target = min(offset, largerSize)
        if mode == .comparison {
            // §10.1: move both panes; each clamps to its own EOF.
            windowModel.pane1.moveCaret(to: target)
            windowModel.pane2.moveCaret(to: target)
        } else {
            activePane.moveCaret(to: target)
        }
        // The row has to be where the user is looking, not wherever it happened
        // to be before the jump (§10.1).
        activeFilePane?.revealOffsetCentered(target)
        focusActiveHexView()
    }

    @objc func selectBlock() {
        let pane = activePane
        guard pane.isOpen else { return }
        let sheet = SelectBlockSheetController(fileSize: pane.fileSize) { [weak self] selection in
            pane.setSelection(selection)
            // §10.2: show the block's START mid-pane, the way the Find bar
            // centres a match — the block begins where the user looks.
            self?.activeFilePane?.revealOffsetCentered(selection.start)
        }
        presentAsSheet(sheet)
    }

    /// Edit > Find (Cmd+F): shows the non-modal Find bar at the top of the
    /// window (§11).
    @objc func findPattern() {
        let pane = activePane
        guard pane.isOpen else { return }
        showFindBar()
    }

    private func showFindBar() {
        contentTopToView.isActive = false
        contentTopToFindBar.isActive = true
        findBar.isHidden = false
        view.layoutSubtreeIfNeeded()
        findBar.prepareForShow()
    }

    private func hideFindBar() {
        findBar.isHidden = true
        contentTopToFindBar.isActive = false
        contentTopToView.isActive = true
        // A Search All outlives the bar: its results live in the pane's own
        // panel, with its own × to stop it, so dismissing the bar must not wipe
        // them (§11). A single find has nothing to leave behind, so it stops.
        if searchAllPane == nil {
            findTask?.cancel()
            findOperation?.finish()
        }
        focusActiveHexView()
    }

    /// Launches a background search from the find bar. A new search cancels any
    /// in-flight one (rapid < > presses), and the bar stays open — only the
    /// selection moves (§11). The search runs as a `BackgroundOperation`, so
    /// its name, progress and (×) appear in the active pane's status bar while
    /// it runs and it can be cancelled (§14.4).
    private func runSearch(pattern: SearchPattern, direction: SearchDirection, caseSensitive: Bool) {
        findTask?.cancel()
        findOperation?.finish()
        let operation = BackgroundOperation(name: "Searching…") { [weak self] in
            self?.findTask?.cancel()
        }
        findOperation = operation
        activeFilePane?.beginOperation(operation)
        findTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.performFind(pattern: pattern, direction: direction,
                                               caseSensitive: caseSensitive, operation: operation)
            operation.finish()
            guard !Task.isCancelled else { return }
            if !found {
                // The scan is directional and does not wrap, so say which way it
                // looked — "No match found." left the user unable to tell an
                // empty file from a caret past the last match (§11).
                self.showFindMessage(direction == .forward
                    ? "No matches after the cursor."
                    : "No matches before the cursor.")
            }
        }
    }

    /// Runs a search off the main thread and, on a match, selects it in the
    /// active pane (§13.8, §14.4, §18 #10). `operation` receives the search's
    /// progress so the status bar advances as the scan covers the file.
    private func performFind(pattern: SearchPattern, direction: SearchDirection, caseSensitive: Bool,
                             operation: BackgroundOperation) async -> Bool {
        let pane = activePane
        guard pane.isOpen, let storage = pane.document?.storage else { return false }
        // Find Next starts after the current selection (so it never re-selects
        // the match just found); Find Previous starts at the selection's start
        // (so it moves back). With no selection both anchor on the caret.
        let selection = pane.hexSelection()
        let from = selection.isEmpty ? pane.caretOffset
            : direction == .forward ? selection.end : selection.start
        let background = Task.detached(priority: .userInitiated) {
            do {
                return try SearchEngine.find(pattern: pattern.bytes, in: storage, from: from, direction: direction,
                                             caseSensitive: caseSensitive,
                                             chunkSize: Self.searchChunkSize,
                                             shouldCancel: { Task.isCancelled },
                                             progress: { operation.report($0) })
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }
        let range = await withTaskCancellationHandler(
            operation: { await background.value },
            onCancel: { background.cancel() }
        )
        guard !Task.isCancelled, let range, pane.isOpen else { return false }
        pane.select(range: range)
        // Show the match mid-pane: a plain reveal only scrolls the found row to
        // the nearest edge (bottom after Find Next, top after Find Previous) (§11).
        activeFilePane?.revealSelectionCentered()
        // A search launched from the find bar must leave focus in the pattern
        // field so a subsequent Enter re-searches; only when the bar is hidden
        // does the search hand focus to the hex view.
        if findBar.isHidden {
            focusActiveHexView()
        } else {
            findBar.focusPatternField()
        }
        return true
    }

    /// Launches a Search All from the find bar (§11): the results panel opens
    /// immediately at its default height, and every occurrence of the pattern is
    /// found in the background and streamed into the table as the scan runs, so
    /// the table and its count fill live while a large file is still being
    /// searched. Runs as a `BackgroundOperation` like a single search, so the
    /// strip (name + progress + ×) appears in the status bar and it can be
    /// cancelled (§14.4).
    ///
    /// The pane active when the search started is captured up front so the
    /// results land in the right hosting view even if the active pane changes
    /// while scanning. Each search captures a `searchAllGeneration` token and
    /// checks it against the live one before touching the panel, so a
    /// superseded search can never clobber the results of a newer one (§11).
    private func runSearchAll(pattern: SearchPattern, caseSensitive: Bool) {
        findTask?.cancel()
        findOperation?.finish()
        let operation = BackgroundOperation(name: "Finding all…") { [weak self] in
            self?.findTask?.cancel()
        }
        findOperation = operation
        let pane = activePane
        let paneView = filePaneView(for: pane)
        searchAllPane = paneView
        // Open the panel empty before any scanning; matches stream in below.
        paneView?.showSearchResults(matches: [], matchLength: pattern.bytes.count)
        paneView?.searchResultsView.setSearching(true)
        activeFilePane?.beginOperation(operation)
        searchAllGeneration += 1
        let generation = searchAllGeneration

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await self.streamFindAll(pattern: pattern, caseSensitive: caseSensitive,
                                                         operation: operation, into: paneView)
                // The scan completed: settle the header's count (drop the "…"),
                // or — when there turned out to be more matches than the panel
                // shows — say the search returned too many results instead of a
                // final count (§11). The scan is asked for one match beyond the
                // display cap precisely so this is exact: a file with exactly
                // `defaultMaxResults` matches used to be labelled "too many".
                if self.searchAllGeneration == generation, let paneView {
                    let view = paneView.searchResultsView
                    if count > SearchEngine.defaultMaxResults {
                        view.setTruncated(true)
                    }
                    view.setSearching(false)
                }
            } catch is CancellationError {
                // The × button, the status-strip stop, or a newer search ended
                // this one. End it, hiding its panel only when that cannot
                // clobber a newer search's live results (§11).
                self.endSearchAllTask(generation: generation, paneView: paneView)
            } catch {
                // A scan error (e.g. a storage read failure) aborts the search.
                self.endSearchAllTask(generation: generation, paneView: paneView)
            }
            operation.finish()
            // This search is over (completed, cancelled, or superseded); a later
            // close of a results panel must not cancel anything else. Guarded by
            // the generation like every other write here: a *superseded* search
            // reaches this line after the newer one has already claimed
            // `searchAllPane`, and clearing it then would leave the newer
            // search's panel unable to cancel it (its × checks this pointer).
            if self.searchAllGeneration == generation {
                self.searchAllPane = nil
            }
        }
        findTask = task
    }

    /// Stops the in-flight Search All when the user closes its results panel
    /// (the ×): cancels the scan and dismisses its status strip. Only acts if
    /// the closing panel belongs to the current Search All — a stale panel (a
    /// search that already finished, or the other pane's panel) must not cancel
    /// an unrelated search.
    private func cancelSearchAll(from pane: FilePaneView?) {
        guard searchAllPane === pane else { return }
        findTask?.cancel()
        findOperation?.finish()
    }

    /// Ends a Search All that did not complete (cancelled or errored). When it
    /// is still the current search, its results panel is hidden (the handle is
    /// cleared later, at the task's end). When a newer search superseded it,
    /// the newer search's panel is left alone — but this task's own panel, in a
    /// different pane, is still collapsed so it is not left behind with a
    /// forever-hanging "…" count (§11).
    private func endSearchAllTask(generation: Int, paneView: FilePaneView?) {
        if searchAllGeneration == generation {
            paneView?.hideSearchResults()
        } else if let paneView, paneView !== searchAllPane {
            paneView.hideSearchResults()
        }
    }

    /// Streams every match of `pattern` from the pane's live storage into the
    /// given results panel, one row at a time, as the detached scan finds them —
    /// the first occurrence appears the moment it is found, not when the scan
    /// completes (§11). `operation` receives the scan's progress so the status
    /// bar advances. Returns how many matches were delivered (at most
    /// `SearchEngine.defaultMaxResults`), so the caller can tell a capped scan
    /// from one that fully completed.
    ///
    /// When the surrounding task is cancelled the scan stops and the loop ends;
    /// this method then rethrows `CancellationError` so the caller can tell a
    /// cancelled search from a completed one (throws immediately, too, when the
    /// pane has no storage to scan).
    private func streamFindAll(pattern: SearchPattern, caseSensitive: Bool,
                               operation: BackgroundOperation, into paneView: FilePaneView?) async throws -> Int {
        guard let paneView, let storage = paneView.viewModel.byteStorage else {
            throw CancellationError()
        }
        // One past the display cap: the extra match is never shown, it only
        // proves there were more, so "too many results" is exact rather than
        // inferred from hitting the cap.
        let displayCap = SearchEngine.defaultMaxResults
        let stream = SearchEngine.findAllStream(
            pattern: pattern.bytes, in: storage, caseSensitive: caseSensitive,
            chunkSize: Self.searchChunkSize,
            maxResults: displayCap + 1,
            shouldCancel: { Task.isCancelled },
            progress: { operation.report($0) }
        )
        var count = 0
        for try await match in stream {
            count += 1
            guard count <= displayCap else { break }
            paneView.searchResultsView.append(matches: [match])
        }
        // Distinguish a finished scan from a cancelled one: on this platform a
        // cancelled task's `next()` can return nil (a normal end) instead of
        // throwing, so check explicitly — a cancelled Search All must hide its
        // panel, not leave partial results with a settled count.
        if Task.isCancelled {
            throw CancellationError()
        }
        return count
    }

    /// Beeps and flashes `message` in the active pane's status bar (used for
    /// parse errors and empty search results from the Find bar, §11).
    private func showFindMessage(_ message: String) {
        NSSound.beep()
        activeFilePane?.showTransientMessage(message)
    }

    // MARK: - Test mode

    /// True when the app runs inside the XCTest runner (a test host). A modal
    /// alert has no human to click it there, so every blocking prompt must
    /// short-circuit to a conservative default — otherwise a stray prompt (the
    /// file-changed Reload/Keep alert, an error) hangs the test suite forever.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    /// Presents `alert` modally, or returns `defaultInTest` immediately when
    /// running under XCTest. Callers pick a response that leaves the document
    /// untouched (Cancel / Keep Current Contents) so a stray alert can never
    /// discard edits or reload a file mid-test. Exposed (internal) so a test
    /// can pin the suppression contract.
    @discardableResult
    static func presentModal(_ alert: NSAlert, defaultInTest: NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        guard !isRunningTests else { return defaultInTest }
        return alert.runModal()
    }

    // MARK: - Alerts

    @discardableResult
    private func confirmAlert(title: String, message: String, confirmTitle: String,
                              destructive: Bool = false,
                              suppressible: Bool = false) -> NSApplication.ModalResponse {
        // A suppressible confirmation is one of the §7.2 shifting-edit warnings.
        // With the warnings switched off it does not appear at all and the edit
        // proceeds: the user has said, once, that they know what these edits do.
        if suppressible, !EditingSettings.warnsBeforeShiftingEdits {
            return .alertFirstButtonReturn
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if destructive {
            alert.buttons.first?.hasDestructiveAction = true
        }
        if suppressible {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
        }
        let response = Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)  // Cancel in tests
        if suppressible { Self.applySuppression(of: alert) }
        return response
    }

    /// Honours an alert's "Do not ask again" checkbox by switching the
    /// shifting-edit warnings off — the same switch as Settings ▸ Editing.
    /// Whichever button dismissed the alert: ticking the box and then cancelling
    /// still means "stop asking me". Internal so a test can pin the wiring,
    /// which is otherwise unreachable (a test never shows the alert).
    static func applySuppression(of alert: NSAlert) {
        guard alert.suppressionButton?.state == .on else { return }
        EditingSettings.set(warnsBeforeShiftingEdits: false)
    }

    @discardableResult
    private func confirmSaveDiscardCancel() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Do you want to save the changes you made?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        return Self.presentModal(alert, defaultInTest: .alertThirdButtonReturn)  // Cancel in tests
    }

    /// The title of the last informational alert. A modal alert is
    /// short-circuited under XCTest (see `presentModal`), so this is the only
    /// trace it leaves — and some of it is behaviour worth pinning, like the
    /// past-EOF warning a Go To leaves behind (§10.1).
    private(set) var lastAlertTitle: String?

    private func presentAlert(title: String, message: String) {
        lastAlertTitle = title
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        Self.presentModal(alert, defaultInTest: .alertFirstButtonReturn)  // OK in tests, result ignored
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        Self.presentModal(alert, defaultInTest: .alertFirstButtonReturn)  // OK in tests, result ignored
    }

    /// Shows a file-operation error, upgrading sandbox/permission denials to a
    /// clear "grant access" prompt (§16 sandbox access denied).
    private func presentFileError(_ title: String, _ error: Error, url: URL?) {
        if isSandboxAccessDenied(error) {
            let name = url?.lastPathComponent ?? "the file"
            presentAlert(title: "Access denied",
                         message: "DumpCompare cannot access “\(name)”. Choose it again with File > Open to grant access.")
        } else {
            presentError(title, error)
        }
    }

    private func isSandboxAccessDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == EACCES {
            return true
        }
        return false
    }

    /// How much of the file one scan step reads (§11). The default is the
    /// engine's own; a `var` so a test can make a search take a while without
    /// writing a gigabyte to disk to do it — the property under test is that a
    /// long scan keeps the main thread responsive, and chunk count is what makes
    /// a scan long.
    static var searchChunkSize = SearchEngine.defaultChunkSize

    // MARK: - Zoom-to-fit (§3.1)

    /// The content width the launch window fits to (§3.1): **one** hex grid at
    /// the saved word size, whatever the saved pane arrangement. The window
    /// opens empty, and it opens on one file far more often than on two, so
    /// fitting two grids would make every single-file session start too wide;
    /// opening a second file is what asks for the extra width, and Window > Zoom
    /// gives it from the real content. No file is open yet at launch, so the
    /// offset column uses its default width. The window controller uses this for
    /// the launch frame.
    static func launchContentWidth() -> CGFloat {
        let font = AppearanceSettings.font(size: 13)
        let charWidth = AppearanceSettings.charWidth(for: font)
        let layout = HexLayout(charWidth: charWidth, rowHeight: 0, wordSize: WordSize.current.rawValue)
        return layout.contentWidth + FilePaneView.contentFitSlack
    }

    /// Ideal content width the window should be when zoomed (double-click on the
    /// title bar / Window > Zoom): the hex grid width for a single pane, or
    /// both grids plus the splitter divider for a left/right comparison. A
    /// stacked comparison keeps the wider of the two panes' grids.
    private func standardContentWidth() -> CGFloat {
        switch mode {
        case .singleFile:
            return activeFilePane?.contentFitWidth ?? 0
        case .comparison:
            guard let comparisonView else { return 0 }
            let w1 = comparisonView.paneView1.contentFitWidth
            let w2 = comparisonView.paneView2.contentFitWidth
            // Same source of truth as ComparisonView's layout toggle (§3.3).
            let isVertical = LayoutSettings.isVertical
            return isVertical ? w1 + w2 + comparisonView.splitView.dividerThickness : max(w1, w2)
        case .empty:
            return 0
        }
    }

    /// Ideal content height the window should be when zoomed (double-click on
    /// the title bar / Window > Zoom): the taller pane's full hex content plus
    /// its header and status bar — the height needed to show the biggest loaded
    /// file without scrolling. The empty state has no content, so the default
    /// zoom frame is kept.
    private func standardContentHeight() -> CGFloat {
        switch mode {
        case .singleFile:
            return activeFilePane?.contentFitHeight ?? 0
        case .comparison:
            guard let comparisonView else { return 0 }
            return max(comparisonView.paneView1.contentFitHeight,
                       comparisonView.paneView2.contentFitHeight)
        case .empty:
            return 0
        }
    }
}

// MARK: - Window closing (§3.6)

extension MainViewController: NSWindowDelegate {
    /// Double-click on the title bar / Window > Zoom sizes the window to the
    /// hex content instead of the default zoom-to-max: the width fits the hex
    /// grid(s), and the height stretches to show the taller loaded file's hex
    /// grid without scrolling — both capped at the screen's visible size when
    /// the content is larger (§3.1). The top edge stays put so the window grows
    /// or shrinks from the bottom. In the empty state there is no hex content,
    /// so the default zoom frame is kept.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let contentWidth = standardContentWidth()
        let contentHeight = standardContentHeight()
        guard contentWidth > 0, contentHeight > 0 else { return defaultFrame }

        // A visible minimap panel shares the content area, so the fitted window
        // must make room for it on top of the hex grids: the hex panes keep
        // their fitted width and the panel takes its preferred width (plus the
        // divider) beside them. A hidden panel adds nothing.
        let minimapWidth = minimapSplit.panelVisible
            ? minimapSplit.preferredPanelWidth + minimapSplit.dividerThickness
            : 0
        let fitWidth = contentWidth + minimapWidth

        var frame = window.frame
        let oldTop = frame.origin.y + frame.height
        let screen = window.screen ?? NSScreen.main
        // Convert the needed content height to a window-frame height (adds the
        // title bar, the only chrome outside the pane itself).
        let frameHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: contentHeight)).height
        frame.size.width = min(fitWidth, screen?.visibleFrame.width ?? fitWidth)
        frame.size.height = min(frameHeight, screen?.visibleFrame.height ?? frameHeight)
        // Anchor the top edge and keep the window fully on the visible screen.
        frame.origin.y = oldTop - frame.size.height
        if let screen {
            frame.origin.y = min(max(frame.origin.y, screen.visibleFrame.minY),
                                 screen.visibleFrame.maxY - frame.size.height)
        }
        return frame
    }

    /// Combined dirty prompt on window close: list every modified file, offer
    /// Save / Don't Save / Cancel. Aborts the close when a save fails so no
    /// change is ever lost silently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let panes = [windowModel.pane1, windowModel.pane2]
        let dirty = panes.filter { $0.isOpen && $0.status.isDirty }
        guard !dirty.isEmpty else { return true }

        let names = dirty.map { "“\($0.status.fileName)”" }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "The following files have unsaved changes: \(names)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch Self.presentModal(alert, defaultInTest: .alertThirdButtonReturn) {  // Cancel in tests (abort close)
        case .alertFirstButtonReturn:
            // Untitled panes have no file yet, so their "Save" runs a Save As
            // sheet; the window closes once every pane is on disk. When every
            // save can happen inline, close right away.
            if dirty.contains(where: { $0.isUntitled }) {
                saveAllThen(dirty, then: { [weak sender] in sender?.close() })
                return false
            }
            for pane in dirty {
                do {
                    try pane.save()
                } catch {
                    presentFileError("Could not save “\(pane.status.fileName)”.", error, url: pane.document?.url)
                    return false
                }
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

// MARK: - Toolbar validation

extension MainViewController: NSToolbarItemValidation {
    /// The toolbar's Prev/Next Difference arrows follow the menu items they
    /// mirror (§10.3).
    ///
    /// Pushing `isEnabled` onto the items from our own state does not work:
    /// AppKit revalidates every visible item on each run-loop pass, and the
    /// default validation sets the state back to "the target responds to the
    /// action" — always true here. The state has to be answered where validation
    /// asks for it.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(nextDifference):
            return diffNavigationState.nextDifference
        case #selector(previousDifference):
            return diffNavigationState.previousDifference
        default:
            return true
        }
    }
}

// MARK: - Menu validation

extension MainViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMinimapOverview):
            // A check, because both modes are a minimap. Disabled for a file the
            // overview could only magnify — the same rule that greys out the
            // header switch's Overview half (§19.4).
            menuItem.state = minimapView.renderMode == .overview ? .on : .off
            return minimapView.renderMode == .overview || minimapView.overviewIsInformative()
        case #selector(toggleMinimap):
            // A Show/Hide item names what it will do, so the title flips with
            // the panel's state (§19). Always enabled: the minimap works with
            // no file open too (it just has nothing to draw).
            menuItem.title = minimapSplit.panelVisible ? "Hide Minimap" : "Show Minimap"
            return true
        case #selector(toggleInsertMode):
            // A checked toggle reading the ACTIVE pane's mode: the mode is per
            // pane (§7.6), so the checkmark follows the pane the keys go to.
            // Always enabled — it is a mode switch, meaningful even with no file
            // open.
            menuItem.state = activePane.isInsertMode ? .on : .off
            return true
        case #selector(saveDocument),
             #selector(saveDocumentAs),
             #selector(undoEdit),
             #selector(redoEdit),
             #selector(pasteInsert),
             #selector(deleteBytes),
             #selector(selectBlock),
             #selector(goToPosition),
             #selector(findPattern),
             #selector(selectAllBytes),
             #selector(toggleBookmark):
            return activePane.isOpen
        case #selector(editBookmark):
            // There is nothing to edit on a row that carries no mark, and ⌘D is
            // what makes one (§20.3).
            return activePane.isOpen
                && windowModel.bookmarkStore.bookmark(atRowContaining: activePane.hexSelection().start) != nil
        case #selector(addCut):
            // A cut needs bytes to split: an empty pane has none (§21.3).
            return activePane.isOpen && activePane.fileSize > 0
        case #selector(removeSegment(_:)):
            // A piece can be removed only when there is a neighbour to merge it
            // into (§21.3) — the first piece into the one below, any other into
            // the one above. The position is the right-clicked one from the
            // context menu, or the caret from the Edit menu.
            let (pane, position): (PaneViewModel, UInt64)
            if let target = menuItem.representedObject as? OffsetContextTarget {
                (pane, position) = (target.pane, target.offset)
            } else {
                pane = activePane
                position = pane.caretOffset
            }
            guard pane.isOpen else { return false }
            let piece = pane.segmentStore.segment(containing: position)
            // Name the piece and the neighbour it merges into, so the menu says
            // what it will do (§21.3) — "Merge S1 into S0", not a bare "Merge".
            menuItem.title = piece.map { $0.mergeTitle } ?? "Merge"
            return piece != nil && pane.segmentStore.current.pieces.count > 1
        case #selector(revertDocument):
            // Nothing on disk to revert an untitled document to.
            return activePane.isOpen && !activePane.isUntitled
        case #selector(appendFile),
             #selector(insertFileAtStart):
            // A join needs content to join into: an empty pane has nothing
            // (§22.1). The File-menu items act on the active pane.
            return activePane.isOpen
        case #selector(appendFileInPane(_:)),
             #selector(insertFileAtStartInPane(_:)):
            // Context-menu items act on the pane they were built for.
            return pane(from: menuItem)?.isOpen ?? false
        case #selector(savePaneDocument(_:)),
             #selector(savePaneDocumentAs(_:)):
            // Context-menu items act on the pane they were built for.
            return pane(from: menuItem)?.isOpen ?? false
        case #selector(revertPaneDocument(_:)):
            guard let pane = pane(from: menuItem) else { return false }
            return pane.isOpen && !pane.isUntitled
        case #selector(showPaneInFinder(_:)):
            // A file must be on disk to reveal it in the Finder — an empty pane
            // has nothing, and an untitled document has no URL.
            guard let pane = pane(from: menuItem) else { return false }
            return pane.isOpen && !pane.isUntitled
        case #selector(copyPaneSelection(_:)),
             #selector(fillPaneSelection(_:)),
             #selector(deletePaneSelection(_:)):
            // Right-click selection actions act on the pane they were built for.
            return (menuItem.representedObject as? OffsetContextTarget)?.pane.isOpen ?? false
        case #selector(splitHere(_:)):
            // Split Here at «address» opens the Add Cut popover pre-filled with the
            // right-clicked offset; the popover validates the offset as it is
            // typed, so a file is all the menu item needs (§21.3).
            guard let target = menuItem.representedObject as? OffsetContextTarget,
                  target.pane.isOpen else { return false }
            return target.pane.fileSize > 0
        case #selector(fillSelectionWithBytes):
            let pane = activePane
            return pane.isOpen && !pane.hexSelection().isEmpty
        case #selector(copySelection):
            let pane = activePane
            return pane.isOpen && !pane.hexSelection().isEmpty
        case #selector(NSText.paste(_:)):
            // ⌘V pastes text into a focused field editor (standard system
            // paste) or, when the hex dump holds focus, writes bytes into
            // the active pane via HexView.paste(_:) (§11). Everywhere else
            // the item is disabled, so paste never fires on the wrong target.
            if viewIfLoaded?.window?.firstResponder is NSTextView { return true }
            if viewIfLoaded?.window?.firstResponder is HexView { return activePane.isOpen }
            return false
        case #selector(nextDifference):
            return diffNavigationState.nextDifference
        case #selector(previousDifference):
            return diffNavigationState.previousDifference
        case #selector(nextSameBlock):
            return diffNavigationState.nextSameBlock
        case #selector(previousSameBlock):
            return diffNavigationState.previousSameBlock
        case #selector(togglePaneLayout),
             #selector(swapPanes):
            // Layout and swap depend only on comparison mode, not the index.
            return mode == .comparison
        case #selector(setWordSize(_:)):
            // Radio state: check the item matching the current word size (§6).
            menuItem.state = menuItem.tag == WordSize.current.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }
}

// MARK: - Clipboard

enum PasteError: LocalizedError {
    case noClipboardData

    var errorDescription: String? {
        switch self {
        case .noClipboardData:
            return "The clipboard does not contain raw bytes or a valid hex byte sequence."
        }
    }
}

/// Custom pasteboard type carrying raw bytes (§12.1). `public.data` is not a
/// defined PasteboardType member, and system types like `public.utf8-plain-text`
/// are interpreted by other apps as text, not bytes.
extension NSPasteboard.PasteboardType {
    static let rawBytes = NSPasteboard.PasteboardType("dev.maxik.DumpCompare.rawBytes")
}

private func pasteboardBytes() throws -> [UInt8] {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: .rawBytes) {
        return [UInt8](data)
    }
    if let text = pasteboard.string(forType: .string) {
        return try ClipboardCodec.bytes(fromHexText: text)
    }
    throw PasteError.noClipboardData
}

/// Boxes the pane and clicked offset carried by a "Select Block from Here at «address»"
/// menu item — `NSMenuItem.representedObject` can't hold a tuple (§10.2).
private final class OffsetContextTarget: NSObject {
    let pane: PaneViewModel
    let offset: UInt64

    init(pane: PaneViewModel, offset: UInt64) {
        self.pane = pane
        self.offset = offset
    }
}

// MARK: - Minimap split divider (§19)

extension MainViewController: NSSplitViewDelegate {
    /// The minimap divider's legal range. While the panel is shown, a drag (or
    /// a resize) never shrinks the minimap below its minimum nor grows it
    /// beyond a quarter of the screen; while hidden, both bounds pin the
    /// divider to the right edge so the panel collapses to zero width.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === minimapSplit else { return proposedMinimumPosition }
        guard minimapSplit.panelVisible else { return 0 }
        let total = splitView.bounds.width
        let maxPanel = min(MinimapSplitView.maxPanelWidth, max(0, total - splitView.dividerThickness))
        return max(0, total - maxPanel - splitView.dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === minimapSplit else { return proposedMaximumPosition }
        guard minimapSplit.panelVisible else {
            return splitView.bounds.width - splitView.dividerThickness
        }
        return max(0, splitView.bounds.width - MinimapSplitView.minPanelWidth - splitView.dividerThickness)
    }

    /// The divider moved — a drag, a programmatic `setPosition`, or a resize —
    /// so the panel's new width becomes the user's preferred width for the
    /// next show. Only persisted while the panel is shown and within the legal
    /// range: NSSplitView can report transient layouts (e.g. mid-animation)
    /// whose panel width is absurd, and persisting those would poison the next
    /// reveal.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView, split === minimapSplit else { return }
        guard minimapSplit.panelVisible, split.arrangedSubviews.count == 2 else { return }
        let contentWidth = split.arrangedSubviews[0].frame.width
        let panelWidth = split.bounds.width - contentWidth - split.dividerThickness
        guard panelWidth >= MinimapSplitView.minPanelWidth,
              panelWidth <= MinimapSplitView.maxPanelWidth else { return }
        MinimapSplitView.defaults.set(panelWidth, forKey: MinimapSplitView.widthDefaultsKey)
    }
}
