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

    /// Makes `identifier` the tab's tool-module, or closes the current one when
    /// it is nil. Picking the one already active is not a toggle: the menu is a
    /// radio group, and choosing the checked row means "yes, this one".
    func activate(_ identifier: String?) {
        guard identifier != activeIdentifier else { return }
        activeIdentifier = identifier.flatMap { ToolRegistry.module(identified: $0) == nil ? nil : $0 }
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
