import Foundation
import ToolModuleKit

/// The zones the panel publishes while a tree row is selected — one focused
/// zone for the row's byte range, `.empty` when the row (or nothing) is picked.
/// A row without a range (a manifest, a group, an MFS file — no reliable
/// bytes) never zones; only rows that stand for real file bytes do.
public enum MEAZones {
    /// The zone map for `focus`: a single zone whose id is the node's path (the
    /// same identity a parked selection keeps). `.empty` when the node has no
    /// byte range.
    public static func build(focus: MEANode?) -> ZoneMap {
        guard let node = focus, let range = node.range else {
            return .empty
        }
        let id = node.path.map(String.init).joined(separator: "/")
        let zone = Zone(id: id, name: node.title.isEmpty ? "(unnamed)" : node.title,
                        range: range)
        return ZoneMap(zones: [zone], focus: id)
    }

    /// The zone-map identity of a row — its tree path as one id string. What a
    /// parked session stores to re-find a selection after a re-parse.
    public static func id(of node: MEANode) -> String {
        node.path.map(String.init).joined(separator: "/")
    }
}
