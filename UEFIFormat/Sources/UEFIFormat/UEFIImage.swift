import Foundation

/// A parsed image: the tree, what was wrong with it, and — once the second pass
/// has run — where in memory it lands.
///
/// The value a tool-module keeps and the value it slices zones out of. It is
/// deliberately not the app's business: the host never sees one
/// (`Design/TOOL_MODULES_PLAN.md`), because a tree of thousands of nodes is the
/// tool-module's model and the handful of ranges worth drawing is all that
/// crosses the seam.
public struct UEFIImage: Sendable {
    /// The size the image had when it was parsed. An edit that changes the
    /// file's size makes the whole tree stale — which is why a tool-module
    /// re-parses on `contentChanged` rather than shifting what it has.
    public let size: UInt64
    public let roots: [UEFINode]
    public let diagnostics: [UEFIDiagnostic]
    /// `address = offset + addressDiff`, worked out from the Volume Top File
    /// (§5.7). Nil means the VTF was missing or compressed, and then every
    /// address in the image is unknowable — not zero, not a guess.
    public let addressDiff: UInt64?
    /// The image's own statement of where it is loaded, when the second pass
    /// got far enough to read it (§5.7).
    public let resetVector: ResetVector?

    public init(
        size: UInt64,
        roots: [UEFINode],
        diagnostics: [UEFIDiagnostic] = [],
        addressDiff: UInt64? = nil,
        resetVector: ResetVector? = nil
    ) {
        self.size = size
        self.roots = UEFIImage.stampingIDs(roots, under: NodeID())
        self.diagnostics = diagnostics
        self.addressDiff = addressDiff
        self.resetVector = resetVector
    }

    /// Ids are stamped here, at the end, rather than threaded through the
    /// parser: a node's place in the tree is not known until its parent has
    /// decided to keep it, and a parser carrying counters is a parser that gets
    /// them wrong on the paths where it gives up early.
    private static func stampingIDs(_ nodes: [UEFINode], under parent: NodeID) -> [UEFINode] {
        nodes.enumerated().map { index, node in
            var stamped = node
            stamped.id = parent.child(index)
            stamped.children = stampingIDs(node.children, under: stamped.id)
            return stamped
        }
    }

    /// Every node, outermost first.
    public var allNodes: [UEFINode] {
        roots.flatMap(\.flattened)
    }

    public func node(_ id: NodeID) -> UEFINode? {
        var nodes = roots
        var found: UEFINode?
        for index in id.path {
            guard index >= 0, index < nodes.count else { return nil }
            found = nodes[index]
            nodes = nodes[index].children
        }
        return found
    }

    /// The chain of nodes covering `offset`, outermost first — a volume, then
    /// the file in it, then the section in that. Empty when the offset falls in
    /// a gap nothing claimed, which after a full parse should not happen:
    /// everything unparsed is still padding (§11).
    public func nodes(containing offset: UInt64) -> [UEFINode] {
        var chain: [UEFINode] = []
        var nodes = roots
        while let node = nodes.first(where: { $0.range.contains(offset) }) {
            chain.append(node)
            nodes = node.children
        }
        return chain
    }

    /// The innermost node covering `offset` — what a click in the dump means.
    public func innermostNode(containing offset: UInt64) -> UEFINode? {
        nodes(containing: offset).last
    }

    public func firstNode(where matches: (UEFINode) -> Bool) -> UEFINode? {
        allNodes.first(where: matches)
    }

    /// The physical address this offset is mapped at, or nil if the image never
    /// told us (§5.7). Compressed nodes have no meaningful address at all, so
    /// callers holding a node should check `isCompressed` before asking.
    public func address(forOffset offset: UInt64) -> UInt64? {
        guard let addressDiff, offset < size else { return nil }
        let (address, overflowed) = offset.addingReportingOverflow(addressDiff)
        return overflowed ? nil : address
    }

    /// Where a physical address — a FIT entry's, a reset vector's — lands in
    /// the file. Nil when addresses are unknown or when the address is outside
    /// this image, which for a FIT entry is the post-mortem §11 of
    /// `FIT_TABLE_FORMAT.md` is about.
    public func offset(forAddress address: UInt64) -> UInt64? {
        guard let addressDiff, address >= addressDiff else { return nil }
        let offset = address - addressDiff
        return offset < size ? offset : nil
    }
}
