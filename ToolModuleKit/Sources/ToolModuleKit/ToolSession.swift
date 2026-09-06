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
    /// file closed, the pane left, or the tab did.
    func stop()

    /// What this session wants handed back if the user returns to this
    /// tool-module on this file, or nil to start afresh every time.
    ///
    /// Read as the session ends and before `stop()`, so a session that lets go
    /// of its model in `stop()` still hands back something whole. The host
    /// keeps it in a box it cannot see into and gives it back to the next
    /// session of the same tool-module on the same pane — which is what makes
    /// the panel switchable rather than a thing you lose your place in.
    ///
    /// *What* is worth keeping is the tool-module's judgement, and the same
    /// judgement as for zones: park what is cheap and re-derive what is not. A
    /// selection, an expanded row, a half-typed field are worth a few bytes; a
    /// parsed tree of ten thousand nodes is worth parsing again, and parking
    /// one per tool-module per tab is how an app comes to hold four copies of
    /// an image it is not showing.
    ///
    /// It is a *hint*, never a truth: the file can be edited while a
    /// tool-module is parked — by hand, by another tool-module — so a restored
    /// state describes bytes that may have moved or gone. Restore what
    /// survives re-reading and drop the rest.
    var parkedState: (any ToolSessionState)? { get }

    /// Hands back what an earlier session of this tool-module parked, before
    /// `start()` and before the view is on screen. A state of another
    /// tool-module's type — from a build where this one meant something else —
    /// is for the session to refuse rather than for the host to police.
    func restore(_ state: any ToolSessionState)
}

public extension ToolSession {
    /// The default is to keep nothing, which is right for a tool-module whose
    /// panel is a function of the file and holds no decision of the user's.
    var parkedState: (any ToolSessionState)? { nil }
    func restore(_ state: any ToolSessionState) {}
}

/// A tool-module's own state, kept by the host while that tool-module is not
/// the one on screen (`ToolSession.parkedState`).
///
/// Deliberately empty: the host stores it, hands it back, and never looks
/// inside — the same rule as everywhere else on this seam, where the
/// tool-module decides what crosses it. `Sendable` because what belongs here is
/// a value; a live object with a view or a host in it is a session, and a
/// session is what just ended.
public protocol ToolSessionState: Sendable {}

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

    /// This change and `next` as one, for a host that holds a change back
    /// briefly rather than waking a parse per keystroke.
    ///
    /// A reload swallows everything: once the content has been replaced there
    /// is nothing left to be precise about. Two edits become the stretch from
    /// the earlier start to the later end, with the length changes added up —
    /// deliberately generous, because after a length change the second edit's
    /// offsets are already measured in a file the first one moved, and the
    /// number a tool-module can act on is where the damage *starts*.
    public func merged(with next: ToolContentChange) -> ToolContentChange {
        guard case .edited(let mine, let myDelta) = self,
              case .edited(let theirs, let theirDelta) = next else { return .reloaded }
        let range = min(mine.lowerBound, theirs.lowerBound)..<max(mine.upperBound, theirs.upperBound)
        return .edited(range, sizeDelta: myDelta + theirDelta)
    }

    /// Where the content stopped being what the tool-module last read. Nil for
    /// a reload, which invalidates all of it.
    public var earliestAffectedOffset: UInt64? {
        guard case .edited(let range, _) = self else { return nil }
        return range.lowerBound
    }
}
