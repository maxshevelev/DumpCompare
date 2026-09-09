import Foundation

/// One label/value row of a node's detail list — the panel's lower pane, the
/// same shape as `UEFIDetailField` in the UEFI tool-module.
public struct MEAField: Sendable, Equatable, Hashable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A row of the ME panel's curated tree (`Design`-less by design: this is the
/// pure target's word for what a real ME dump's structures are, built from the
/// `FirmwareAnalysis` the engine returned).
///
/// The tree is *curated* rather than a raw reflection of the model: each
/// present top-level structure of the analysis becomes a group with a readable
/// name and, where the model carries a byte offset and size, rows that stand
/// for real bytes in the file — the thing the panel reveals and zones. A new
/// top-level field of `FirmwareAnalysis` is surfaced here by adding one node
/// builder, which is the accepted cost of a hand-named tree over a model that
/// grows additively.
///
/// A node is a value, built once per parse and carrying everything the panel
/// can say about it: its title and hex subtitle, its detail rows, and — when it
/// stands for bytes — its absolute file `range`. `children` are the rows under
/// a group. `path` is the node's position in the tree (`[root][child]…`), the
/// identity a parked session keeps and the focus the dump's zone answers to.
public struct MEANode: Sendable, Equatable, Hashable, Identifiable {
    /// Position in the presented tree: an index per level, `[0]` is the first
    /// root. Stable across re-parses of the same file — what a parked selection
    /// and a zone id are made from.
    public var path: [Int]
    /// What the row is called. Empty only for a node that has nothing to name.
    public var title: String
    /// A short second line of the same row — usually the hex `offset · size`
    /// the row stands for. Empty when there is none.
    public var subtitle: String
    /// The byte range the row stands for in the open file, or nil when the model
    /// gives no reliable range (a manifest has an offset but no length). Only
    /// non-nil ranges are revealed and zoned.
    public var range: Range<UInt64>?
    /// The detail list shown when the row is selected.
    public var fields: [MEAField]
    /// Rows under a group node. Empty for a leaf.
    public var children: [MEANode]

    public var id: [Int] { path }

    /// True when a deeper selection can pick something: the node has rows of
    /// its own or stands for bytes worth revealing even without them.
    public var isExpandable: Bool { !children.isEmpty }
    public var hasBytes: Bool { range != nil }

    public init(
        path: [Int],
        title: String,
        subtitle: String = "",
        range: Range<UInt64>? = nil,
        fields: [MEAField] = [],
        children: [MEANode] = []
    ) {
        self.path = path
        self.title = title
        self.subtitle = subtitle
        self.range = range
        self.fields = fields
        self.children = children
    }
}

/// Walking a presented tree by `path` — the identity a parked session keeps and
/// a selection is re-found after a re-parse. `MEANode.path` records the index
/// per level, so re-finding is pure index descent into `children` (no name
/// matching), which stays correct even when titles drift between parses.
public enum MEATree {
    /// The node at `path` in `roots`, or nil when the path leads past the end of
    /// the tree (the file shrank, the tree changed shape). An empty path asks
    /// for a root the caller names differently, so nil too.
    public static func node(at path: [Int], in roots: [MEANode]) -> MEANode? {
        guard let head = path.first else { return nil }
        guard roots.indices.contains(head) else { return nil }
        let root = roots[head]
        let rest = Array(path.dropFirst())
        guard !rest.isEmpty else { return root }
        return node(at: rest, in: root.children)
    }
}
