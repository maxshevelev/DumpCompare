import AppKit

/// One tool-module, running against one open file.
///
/// The session is where a tool-module's state lives: its parse, its selection,
/// whatever the user has half-filled in. It is bound to the pane it was opened
/// for and never re-points at the other one — what the panel's header names is
/// where the writes go — and it is owned by the window, which is what decides
/// its end: a pane moved to another tab leaves the panel behind, the same way
/// it leaves that window's bookmarks behind (§20).
///
/// The view controller is the tool-module's own, and it is expected to be thin:
/// the pure target underneath it is where a tool-module's decisions are made
/// and where they are tested without a window.
@MainActor public protocol ToolSession: AnyObject {
    var viewController: NSViewController { get }

    /// The panel is on screen and the file can be read. The first read belongs
    /// here rather than in `makeSession`, so a slow parse starts against a
    /// panel the user can already see.
    func start()

    /// The content changed under the session. What to do about it is the
    /// tool-module's: a small overwrite inside a table it already knows may be
    /// a patch, and anything else is a reason to read again.
    func contentChanged(_ change: ToolContentChange)

    /// The session is over — the user picked another tool-module or None, the
    /// file closed, the pane left, or the tab did. Nothing about it is kept.
    func stop()
}

/// Why what the session read is no longer what the file holds.
public enum ToolContentChange: Equatable, Sendable {
    /// An edit landed: what it covered afterwards, and how the file's length
    /// moved. `sizeDelta` is zero for the overwrites that make up nearly all
    /// editing here, and non-zero for an insert or a delete — which moves every
    /// offset after `range` and therefore invalidates a map wholesale rather
    /// than in part.
    case edited(Range<UInt64>, sizeDelta: Int64)
    /// The content was replaced under the session: a revert, a change made
    /// outside the app, a file joined onto this one. Nothing that was read
    /// before can be relied on.
    case reloaded
}
