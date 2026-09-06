import Cocoa
import DumpCompareCore
import ToolModuleKit

/// The tool-module side of one tab: which one is active, and everything that
/// follows from that (`Design/TOOL_MODULES_PLAN.md`).
///
/// It lives here rather than in `MainViewController` for the ordinary reason —
/// that file is six thousand lines — and for a specific one: a tool-module's
/// state is a self-contained thing with a lifecycle of its own, and the
/// controller's part in it is one stored property and two forwarding methods.
///
/// One per tab, because one tool-module is active per tab. The session it will
/// own is bound to a pane but the *choice* belongs to the window, which is why
/// it is held here and not on `PaneViewModel`: a pane moved to another tab
/// leaves the panel behind, exactly as it leaves that window's bookmarks behind
/// (§20).
@MainActor final class ToolController {
    /// The tab this belongs to. Weak: the controller owns this, not the other
    /// way round.
    weak var owner: MainViewController?

    /// The active tool-module's identifier, or nil for None. Kept as an
    /// identifier rather than a type so a choice can outlive a build in which
    /// that tool-module was removed — it resolves through the registry, and an
    /// identifier nothing answers to reads as None.
    private(set) var activeIdentifier: String?

    /// The active tool-module, if the registry still holds one by that name.
    var activeModule: (any ToolModule.Type)? {
        activeIdentifier.flatMap(ToolRegistry.module(identified:))
    }

    // MARK: - The session

    /// The running tool-module, or nil when the tab is on None.
    private(set) var session: (any ToolSession)?

    /// The pane the session reads and writes. Bound when the session starts and
    /// never re-pointed: clicking the other pane does not re-target a
    /// tool-module, because what the panel's header names is where its writes
    /// go, and a map that re-parsed under a click would be a map you cannot
    /// trust.
    private(set) weak var boundPane: PaneViewModel?

    private var host: PaneToolHost?

    /// What the session last asked the dump to show. Drawn in stage 5; kept
    /// here from the start because it is the session's state, not the view's.
    private(set) var zones: ZoneMap = .empty

    /// How long a change is held before the session hears about it. Typing
    /// lands one edit per keystroke and a parse per keystroke is not work, it
    /// is heat — but the wait has to stay below the point where the panel looks
    /// stale. A `var` so a test does not have to sleep through it.
    static var changeDelay: TimeInterval = 0.15

    private var pendingChange: ToolContentChange?
    private var deliveryTask: Task<Void, Never>?

    /// Starts `module` against `pane`: the host, the session, its view in the
    /// panel, and the first read.
    ///
    /// `start()` is called after the view is in the panel rather than inside
    /// `makeSession`, so a slow first parse runs against a panel the user can
    /// already see.
    private func startSession(_ module: any ToolModule.Type, on pane: PaneViewModel) {
        guard let owner else { return }
        let host = PaneToolHost(pane: pane, owner: owner, tools: self)
        let session = module.makeSession(host: host)
        self.host = host
        self.session = session
        boundPane = pane
        zones = .empty
        panel.setTitle(module.title, fileName: pane.status.fileName)
        panel.setContent(session.viewController.view)
        owner.addChild(session.viewController)
        session.start()
    }

    /// Ends the running session, whatever ended it — another tool-module, None,
    /// the file closing, the pane leaving, the tab going.
    private func endSession() {
        deliveryTask?.cancel()
        deliveryTask = nil
        pendingChange = nil
        session?.stop()
        if let controller = session?.viewController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        panel.setContent(nil)
        // The map goes with the session that authored it: nothing else draws
        // zones, so a dump left carrying them would be showing a tool-module's
        // reading of a file after that tool-module has gone.
        boundPane?.setZones(ZoneMap.empty)
        session = nil
        host = nil
        boundPane = nil
        zones = .empty
    }

    /// What the dump should draw, from the session that is running now. A
    /// publish from a host that has been replaced is dropped rather than
    /// applied: a parse finishing after its session ended must not repaint the
    /// dump for a tool-module that is no longer open.
    func publish(_ map: ZoneMap, from host: PaneToolHost) {
        guard host === self.host else { return }
        let previousFocus = zones.focus
        zones = map.normalized(contentSize: host.contentSize)
        boundPane?.setZones(zones)
        // A zone the tool-module has just put in focus is a zone the user is
        // being shown, so the dump goes to it — the scroll only, and only when
        // it is not on screen already. Every tool-module gets this rather than
        // each remembering to ask, and a republish that focuses the same zone
        // scrolls nothing.
        guard let focus = zones.focus, focus != previousFocus,
              let zone = zones.zones.first(where: { $0.id == focus }),
              let pane = boundPane else { return }
        owner?.showZoneStartForTool(zone.range.lowerBound, in: pane)
    }

    // MARK: - What happens to the session

    /// An edit landed in some pane. The session hears about it only for its own
    /// pane, and only after the changes stop coming.
    func paneEdited(_ pane: PaneViewModel, _ edit: DiffEdit) {
        guard pane === boundPane else { return }
        let change: ToolContentChange
        switch edit {
        case .overwrite(let range):
            change = .edited(range, sizeDelta: 0)
        case .insert(let at, let length):
            change = .edited(at..<(at &+ length), sizeDelta: Int64(length))
        case .delete(let range):
            change = .edited(range.lowerBound..<range.lowerBound,
                             sizeDelta: -Int64(range.count))
        }
        schedule(change)
    }

    /// The content was replaced under the session: a revert, a change made
    /// outside the app, a file joined on.
    func paneReloaded(_ pane: PaneViewModel) {
        guard pane === boundPane else { return }
        schedule(.reloaded)
    }

    /// The bound file was closed: there is nothing left for the tool-module to
    /// work on, so the session ends and the panel closes.
    func paneClosed(_ pane: PaneViewModel) {
        guard pane === boundPane else { return }
        activate(nil)
    }

    /// The bound pane left this tab. The session belongs to the window — the
    /// same side of the line as bookmarks (§20) — so it stays behind and ends,
    /// and the destination keeps whatever it had.
    func paneLeft(_ pane: PaneViewModel) {
        guard pane === boundPane else { return }
        activate(nil)
    }

    /// Holds `change` briefly, merging it with whatever was already waiting,
    /// then hands the one change to the session.
    private func schedule(_ change: ToolContentChange) {
        pendingChange = pendingChange.map { $0.merged(with: change) } ?? change
        deliveryTask?.cancel()
        let delay = Self.changeDelay
        deliveryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.deliverPendingChange()
        }
    }

    /// Hands the held change over, and refreshes the header — a Save As or a
    /// rename changes what the file is called under a running session.
    private func deliverPendingChange() {
        guard let change = pendingChange, let session else { return }
        pendingChange = nil
        deliveryTask = nil
        if let module = activeModule, let pane = boundPane {
            panel.setTitle(module.title, fileName: pane.status.fileName)
        }
        session.contentChanged(change)
    }

    /// Delivers anything held, now. The seam a test uses instead of sleeping
    /// through `changeDelay`.
    func flushPendingChangeForTesting() {
        deliveryTask?.cancel()
        deliveryTask = nil
        deliverPendingChange()
    }

    // MARK: - The panel

    /// The panel itself — the split's leading pane, present from the start and
    /// collapsed to zero width, exactly as the minimap panel is (§19.1). A
    /// pane that exists only when it is shown would have to be added to the
    /// split mid-life, which is the one thing that makes the divider indices
    /// move under everything that holds one.
    let panel = ToolPanelView()

    /// Whether the panel is open. Drives the divider clamp: while it is closed
    /// the divider is pinned to the leading edge, so a drag cannot open a panel
    /// that has no tool-module in it.
    private(set) var isPanelVisible = false

    /// Where the panel's width is remembered — one key per tool-module, since
    /// a FIT table wants twice what a structure tree does and one shared width
    /// would be wrong for both. Swappable so the suite does not write into the
    /// user's own preferences.
    static var defaults: UserDefaults = .standard
    static func widthDefaultsKey(for identifier: String) -> String {
        "ToolPanelWidth.\(identifier)"
    }

    /// The panel is never narrower than this: below it a table of offsets and
    /// names stops being readable and starts being a column of ellipses.
    static let minPanelWidth: CGFloat = 220
    /// Nor wider than this — it is a panel beside the dump, not a second
    /// document.
    static let maxPanelWidth: CGFloat = 720
    /// What the dump keeps whatever the panel asks for. The panel gives way
    /// first: the file is what the window is for.
    static let minContentWidth: CGFloat = 320

    /// The width the panel opens at for `module`: the user's own, if they have
    /// dragged one for this tool-module, else what the tool-module asked for —
    /// clamped either way, so a stored width from a wider window or a silly
    /// `preferredPanelWidth` cannot open a panel that swallows the dump.
    func preferredWidth(for module: any ToolModule.Type) -> CGFloat {
        let stored = Self.defaults.object(forKey: Self.widthDefaultsKey(for: module.identifier))
        let width = (stored as? NSNumber).map { CGFloat($0.doubleValue) } ?? module.preferredPanelWidth
        return min(max(width, Self.minPanelWidth), Self.maxPanelWidth)
    }

    /// Where the divider between the panel and the dump may land, in the
    /// split's own leading-edge coordinates — which for the first divider is
    /// the panel's width.
    ///
    /// Closed, it is pinned to zero: only the menu opens the panel, never a
    /// drag on the seam of something that is not there. Open, it stays between
    /// the panel's minimum and the point where the dump would fall below its
    /// own — so on a narrow window the panel stops growing rather than the dump
    /// disappearing.
    func clampPanelDivider(_ position: CGFloat, total: CGFloat, dividers: CGFloat,
                           minimapWidth: CGFloat) -> CGFloat {
        guard isPanelVisible else { return 0 }
        let roomForPanel = max(0, total - dividers - minimapWidth - Self.minContentWidth)
        let upper = min(Self.maxPanelWidth, roomForPanel)
        return min(max(position, min(Self.minPanelWidth, upper)), max(0, upper))
    }

    /// Remembers the panel's width for the tool-module that is open, so the
    /// next time that one is picked it opens where the user left it. Only while
    /// the panel is shown and only a width inside the legal band: a transient
    /// layout mid-animation would otherwise poison the next reveal.
    func persistPanelWidth(_ width: CGFloat) {
        guard isPanelVisible, let identifier = activeIdentifier else { return }
        guard width >= Self.minPanelWidth, width <= Self.maxPanelWidth else { return }
        Self.defaults.set(width, forKey: Self.widthDefaultsKey(for: identifier))
    }

    /// Makes `identifier` the tab's tool-module, or closes the current one when
    /// it is nil. Picking the one already active is not a toggle: the menu is a
    /// radio group, and choosing the checked row means "yes, this one".
    func activate(_ identifier: String?, animated: Bool = true) {
        let resolved = identifier.flatMap { ToolRegistry.module(identified: $0) == nil ? nil : $0 }
        guard resolved != activeIdentifier else { return }
        activeIdentifier = resolved
        endSession()
        guard let module = activeModule, let pane = owner?.windowModel.activePane, pane.isOpen else {
            activeIdentifier = nil
            setPanelVisible(false, animated: animated)
            return
        }
        startSession(module, on: pane)
        isPanelVisible = true
        setPanelWidth(preferredWidth(for: module), animated: animated)
    }

    /// Opens or closes the panel, moving the window's leading edge with it so
    /// the dump keeps the width it had — the mirror of what showing the minimap
    /// does on the trailing edge (§19).
    func setPanelVisible(_ visible: Bool, animated: Bool = true, width: CGFloat? = nil) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        setPanelWidth(visible ? (width ?? Self.minPanelWidth) : 0, animated: animated)
    }

    /// Takes the panel to `width`, moving the window's leading edge by exactly
    /// what the panel gained or gave up.
    ///
    /// One path for all three ways the width changes — opening, closing, and
    /// switching to a tool-module that wants a different width — so the dump
    /// keeps the width it had in every one of them rather than in the case
    /// somebody remembered to write.
    private func setPanelWidth(_ width: CGFloat, animated: Bool) {
        guard let owner else { return }
        let current = owner.toolPanelWidth()
        owner.setToolPanelWidth(width, animated: animated,
                                windowResize: owner.toolPanelWindowResize(delta: width - current))
    }

    /// Whether the menu item for `identifier` should be available, and with
    /// which mark. A tool-module reads and writes the open file, so it needs
    /// one; None stays available always, since it is how the panel is closed
    /// and closing it must never be the thing that is greyed out.
    func menuState(for identifier: String?, fileIsOpen: Bool) -> (enabled: Bool, state: NSControl.StateValue) {
        (enabled: identifier == nil || fileIsOpen,
         state: identifier == activeIdentifier ? .on : .off)
    }
}
