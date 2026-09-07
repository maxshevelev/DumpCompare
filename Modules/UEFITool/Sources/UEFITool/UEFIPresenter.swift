import Foundation
import ToolModuleKit
import UEFIFormat

/// The decisions the UEFI structure panel makes, built and tested without a
/// window (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// The panel is a tree of thousands of nodes and a detail for the one in focus.
/// What crosses the seam to the dump is a single zone — the node the user is
/// looking at — and what the detail says comes from the node's header, read
/// through the reader the parse used. Both of those are decided here.
public enum UEFIPresenter {
    /// The zone a selected node publishes: the node's range, named by its path,
    /// and focused. Nil is "nothing selected yet" — the honest state before a
    /// choice, and the one a re-parse that lost the node lands on.
    ///
    /// One zone, not the node with its children: a UEFI parse is a tree of
    /// thousands of nodes and drawing them all is how the hex view stops being
    /// readable. What is worth drawing is the node the user is looking at, and
    /// that changes with the selection.
    public static func zones(for node: UEFINode?) -> ZoneMap {
        guard let node else { return .empty }
        let id = zoneID(for: node.id)
        return ZoneMap(zones: [Zone(id: id, name: node.name, range: node.range)], focus: id)
    }

    /// A node's path as a zone id: `1.2.0`. Stable across a re-parse of the same
    /// image — which is what lets a selection survive the re-read an edit causes
    /// — and the route a diagnostic about a node three levels down needs.
    public static func zoneID(for id: NodeID) -> String { id.description }

    /// The trip back: the user picked a zone in the dump and the panel has to
    /// expand to the node it came from. Nil for an id this module did not make.
    public static func nodeID(ofZone id: String) -> NodeID? {
        guard !id.isEmpty else { return nil }
        let fields = id.split(separator: ".", omittingEmptySubsequences: false)
        let path = fields.compactMap { Int($0) }
        guard path.count == fields.count else { return nil }
        return NodeID(path)
    }
}
