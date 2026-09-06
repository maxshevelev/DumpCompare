import Cocoa
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
        guard let module = activeModule else {
            panel.setContent(nil)
            setPanelVisible(false, animated: animated)
            return
        }
        panel.setTitle(module.title, fileName: owner?.windowModel.activePane.status.fileName ?? "")
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
