import Foundation

/// What a tool-module reaches to get at the one shared, per-pane lazy tree,
/// without depending on the app that owns it or on another tool-module.
/// `UEFIImage` has no package dependencies by design; this protocol is what
/// lets `PaneToolHost` (in the app) and a tool-module's session agree on a
/// shared object without either depending on the other's concrete type.
@MainActor
public protocol UEFITreeProviding: AnyObject {
    /// The shared tree for the file this provider is about, created on first
    /// use and torn down on file-swap/`.reloaded` — see `PaneUEFIState` in
    /// the app. Nil when there is no open file / no bytes to parse.
    func uefiTree() -> LazyUEFITree?

    /// Which rows a UEFI panel had open, kept with the file rather than with
    /// the panel.
    ///
    /// A tool-module session — and the view controller under it — is built
    /// fresh on every activation, so the outline's own memory of what was open
    /// goes with the old one. The tree it was reading does not: it belongs to
    /// the file. A reader who opens three volumes, goes to the FIT panel and
    /// comes back expects to find the tree as they left it, and the branches
    /// are still read, so putting them back costs nothing.
    func openUEFIRows() -> Set<NodeID>
    func setOpenUEFIRows(_ rows: Set<NodeID>)
}
